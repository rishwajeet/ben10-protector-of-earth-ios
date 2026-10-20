#!/usr/bin/env python3
"""Offline, source-hashed comparison of freely available restoration weights.

Outputs are private game-derived assets and must remain outside the checkout.
RGB-only first lane; alpha-bearing textures require a separate treatment.
Metrics measure drift, not reconstruction accuracy (no high-resolution truth).
"""
from __future__ import annotations

import argparse
from collections import OrderedDict
import hashlib
import importlib.metadata
import json
from pathlib import Path
import time

from PIL import Image, ImageDraw


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_image_model(weights: Path, device: str):
    """Load trusted, separately hash-verified weights without arbitrary pickle."""
    import torch
    from safetensors.torch import load_file
    from spandrel import ImageModelDescriptor, ModelLoader

    if weights.suffix == ".safetensors":
        state = load_file(str(weights))
    else:
        with torch.serialization.safe_globals([(OrderedDict, "typing.OrderedDict")]):
            state = torch.load(weights, map_location="cpu", weights_only=True)
    for key in ("model_state_dict", "state_dict", "params_ema", "params", "model", "net"):
        if key in state and isinstance(state[key], dict):
            state = state[key]
            break
    model = ModelLoader().load_from_state_dict(state)
    if not isinstance(model, ImageModelDescriptor) or model.input_channels != 3 or model.output_channels != 3:
        raise ValueError("Expected a three-channel image restoration model")
    return model.eval().to(device)


def destination(path: Path, manifest: Path) -> Path:
    path = path.resolve()
    repo = Path(__file__).resolve().parents[1]
    if path.is_relative_to(repo) or path.is_relative_to(manifest.parent):
        raise ValueError("Use a new external output directory, outside original sources.")
    path.mkdir(parents=True, exist_ok=False)
    return path


def gallery(manifest: Path, output: Path) -> None:
    data = json.loads(manifest.read_text())
    entries = [(k, v) for k, v in data["textures"].items()
               if v["width"] >= 128 and v["height"] >= 64
               and v["alpha"]["nonopaque_pixels"] == 0]
    sheet = Image.new("RGB", (6 * 200, ((len(entries) + 5) // 6) * 220), "#202126")
    draw = ImageDraw.Draw(sheet)
    for i, (key, value) in enumerate(entries):
        picture = Image.open(manifest.parent / value["png"]).convert("RGB")
        picture.thumbnail((192, 188))
        x, y = (i % 6) * 200, (i // 6) * 220
        sheet.paste(picture, (x, y))
        draw.text((x, y + 190), f"{i}: {key[:25]}", fill="white")
    sheet.save(output / "gallery.jpg", quality=94)
    (output / "index.json").write_text(json.dumps([k for k, _ in entries], indent=2))
    print(output / "gallery.jpg", flush=True)


def benchmark(manifest: Path, recipe: Path, output: Path, device: str) -> None:
    import numpy as np
    import torch

    data = json.loads(manifest.read_text())
    config = json.loads(recipe.read_text())
    report = {"schema": "protector-native.upscale-benchmark/v1", "device": device,
              "torch": torch.__version__, "spandrel": importlib.metadata.version("spandrel"),
              "source_manifest": str(manifest), "source_manifest_sha256": sha(manifest),
              "recipe": config, "precision": "float32", "results": [],
              "metric_note": "Source roundtrip/color drift only; not quality ground truth.",
              "acceptance": "candidate; requires visual and in-game review"}

    for candidate in config["models"]:
        weights = Path(candidate["weights"]).expanduser().resolve()
        model_report = {"model": candidate["name"], "weights_sha256": sha(weights),
                        "source_url": candidate["source_url"], "license": candidate["license"],
                        "samples": []}
        report["results"].append(model_report)
        try:
            model = load_image_model(weights, device)
            model_report.update(architecture=model.architecture.id, scale=model.scale)
            model_dir = output / candidate["name"]
            model_dir.mkdir()
            for sample in config["samples"]:
                key = sample["source"]
                entry = data["textures"][key]
                source = manifest.parent / entry["png"]
                if sha(source) != entry["png_sha256"]:
                    raise ValueError("Source PNG hash changed")
                rgba = Image.open(source).convert("RGBA")
                if hashlib.sha256(rgba.tobytes()).hexdigest() != entry["rgba8_sha256"]:
                    raise ValueError("Decoded source hash changed")
                if rgba.getchannel("A").getextrema() != (255, 255):
                    raise ValueError("Alpha-bearing sample requires separate restoration")
                src = np.asarray(rgba.convert("RGB"), dtype=np.float32) / 255.0
                # Evaluate texture edges in their original sampler context. All
                # repeats use periodic padding; clamp and mirror use matching
                # continuation. This does not invent seamlessness in the source.
                padded = src
                wraps = []
                for axis, field in ((0, "wrap_t"), (1, "wrap_s")):
                    modes = {item[field] for item in entry["occurrences"]}
                    if len(modes) != 1:
                        raise ValueError("Sample has mixed sampler modes; select one explicitly")
                    wrap = modes.pop()
                    wraps.append(wrap)
                    pad = [(0, 0)] * 3
                    pad[axis] = (32, 32)
                    padded = np.pad(padded, pad, mode={"repeat": "wrap", "clamp": "edge",
                                                     "mirror": "reflect"}[wrap])
                tensor = torch.from_numpy(padded.transpose(2, 0, 1).copy())[None].to(device)
                if device == "mps":
                    torch.mps.synchronize()
                started = time.perf_counter()
                with torch.inference_mode():
                    result = model(tensor)
                if device == "mps":
                    torch.mps.synchronize()
                elapsed = time.perf_counter() - started
                s = model.scale
                result = result[0, :, 32*s:(32+src.shape[0])*s,
                                32*s:(32+src.shape[1])*s].clamp(0, 1)
                result = result.cpu().numpy().transpose(1, 2, 0)
                image = Image.fromarray(np.rint(result * 255).astype(np.uint8))
                target = model_dir / f"{sample['name']}.png"
                image.save(target)
                roundtrip = np.asarray(image.resize(rgba.size, Image.Resampling.LANCZOS),
                                       dtype=np.float32) / 255
                record = {"name": sample["name"], "source": key, "png": str(target),
                          "png_sha256": sha(target), "width": image.width,
                          "height": image.height, "seconds": elapsed, "padding": 32,
                          "wrap_t_s": wraps,
                          "source_roundtrip_mae_255": float(np.abs(roundtrip-src).mean()*255),
                          "mean_rgb_delta_255": ((roundtrip-src).mean(axis=(0, 1))*255).tolist()}
                model_report["samples"].append(record)
                print(json.dumps({"model": candidate["name"], **record}), flush=True)
                (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                del result, tensor
            del model
            if device == "mps":
                torch.mps.empty_cache()
        except Exception as error:
            model_report["error"] = f"{type(error).__name__}: {error}"
            print(json.dumps(model_report), flush=True)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    # Exact 512-pixel output crops; nearest enlarged original for an honest
    # before. No resizing of model outputs within the comparison crops.
    good = [r for r in report["results"] if len(r["samples"]) == len(config["samples"])]
    sheet = Image.new("RGB", ((len(good)+1)*520, len(config["samples"])*564), "#202126")
    draw = ImageDraw.Draw(sheet)
    for row, sample in enumerate(config["samples"]):
        entry = data["textures"][sample["source"]]
        src = Image.open(manifest.parent / entry["png"]).convert("RGB")
        before = src.resize((src.width*4, src.height*4), Image.Resampling.NEAREST)
        images = [("Original / nearest 4x", before)]
        images += [(r["model"], Image.open(r["samples"][row]["png"])) for r in good]
        for col, (label, picture) in enumerate(images):
            x, y = col*520, row*564
            draw.text((x+4, y+4), sample["name"], fill="white")
            draw.text((x+4, y+20), label, fill="white")
            cx, cy = (picture.width-512)//2, (picture.height-512)//2
            sheet.paste(picture.crop((cx, cy, cx+512, cy+512)), (x+4, y+44))
    sheet.save(output / "comparison.png")
    print(output / "comparison.png", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--recipe", type=Path)
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    args = parser.parse_args()
    manifest = args.manifest.resolve()
    output = destination(args.output, manifest)
    if args.recipe:
        benchmark(manifest, args.recipe, output, args.device)
    else:
        gallery(manifest, output)


if __name__ == "__main__":
    main()

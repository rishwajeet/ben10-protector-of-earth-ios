#!/usr/bin/env python3
"""Restore an explicit, opaque texture selection with pinned local models.

One 4x RGB pass plus zero or more neutral 2x luma passes; no recursive detail
generation. Immutable source/weight hashes and per-asset receipts are required.
Outputs are private candidates, never automatic visual acceptance.
"""
from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import shutil
import sys
import time

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.benchmark_texture_restoration import load_image_model
from tools.build_texture_pack import read_png
from tools.finish_texture_neutral import enlarge
from tools.prepare_texture_restoration import DOL_SHA256


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned_file(base: Path, config: dict, field: str, hash_field: str) -> Path:
    path = (base / config[field]).resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{64}", str(config.get(hash_field, ""))) or sha(path) != config[hash_field]:
        raise ValueError(f"{field} hash changed or is missing")
    return path


def identifier(value) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", value):
        raise ValueError("a short lowercase identifier is required")
    return value


def plan(recipe_path: Path, output: Path) -> tuple[dict, dict, list[dict]]:
    recipe_path = recipe_path.resolve(strict=True)
    config = json.loads(recipe_path.read_text())
    if config.get("schema") != "protector-native.texture-restoration-batch/v1":
        raise ValueError("unsupported restoration batch")
    identifier(config.get("pack_id"))
    manifest = pinned_file(recipe_path.parent, config, "sources", "sources_sha256")
    sources = json.loads(manifest.read_text())
    if sources.get("schema") != "protector-native.texture-restoration-sources/v1" or sources.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("sources must match the pinned original title")
    destination = output.resolve()
    if output.is_symlink() or destination.exists() or any(destination.is_relative_to(p) for p in (
            ROOT, manifest.parent, Path(sources["source_data_root"]).resolve())):
        raise ValueError("use a new external output directory outside source artwork and the dump")
    entries = config.get("entries")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 16384:
        raise ValueError("a nonempty bounded selection is required")
    models = config.get("models", {})
    seen, names, planned = set(), set(), []
    verified_models, verified_finisher = set(), False
    for candidate in entries:
        key, name = candidate["source"], identifier(candidate["name"])
        if key in seen or name in names or key not in sources["textures"]:
            raise ValueError("duplicate name/source or unknown source")
        seen.add(key)
        names.add(name)
        source = sources["textures"][key]
        path = pinned_file(manifest.parent, source, "png", "png_sha256")
        if not path.is_relative_to(manifest.parent):
            raise ValueError("source artwork escapes its manifest")
        width, height, rgba = read_png(path)
        if (width, height, hashlib.sha256(rgba).hexdigest()) != (source["width"], source["height"], source["rgba8_sha256"]):
            raise ValueError("source pixel identity changed")
        if any(a != 255 for a in rgba[3::4]):
            raise ValueError("alpha-bearing textures require a separate treatment")
        wraps = []
        for field in ("wrap_t", "wrap_s"):
            modes = {o[field] for o in source["occurrences"]}
            if len(modes) != 1 or not modes <= {"repeat", "mirror", "clamp"}:
                raise ValueError("mixed or unknown sampler modes require a separate treatment")
            wraps.append(next(iter(modes)))
        target = candidate.get("target_long_edge")
        longest = max(width, height)
        if type(target) is not int or target > 4096 or target < longest*4 or target % (longest*4):
            raise ValueError("target requires a 4x source scale followed by exact 2x steps, at most 4096")
        factor = target // (longest*4)
        if factor & (factor - 1):
            raise ValueError("target must use power-of-two finishing steps")
        passes = factor.bit_length() - 1
        if "reuse" not in candidate:
            borders = inference_padding(height, width)
        else:
            borders = None
        planned_entry = {**candidate, "source_path": str(path), "source_png_sha256": source["png_sha256"],
            "source_rgba8_sha256": source["rgba8_sha256"], "source_dimensions": [width, height],
            "dimensions": [width*4*factor, height*4*factor], "wrap_t_s": wraps, "finishing_passes": passes,
            "first_pass_padding_t_s": borders}
        if ("reuse" in candidate) == ("model" in candidate):
            raise ValueError("select exactly one first-pass model or a pinned prior candidate")
        if "reuse" in candidate:
            reuse = candidate["reuse"]
            previous = pinned_file(recipe_path.parent, reuse, "png", "png_sha256")
            receipt = pinned_file(recipe_path.parent, reuse, "receipt", "receipt_sha256")
            evidence = json.loads(receipt.read_text())
            if evidence.get("source") != key or evidence.get("dimensions") != planned_entry["dimensions"]:
                raise ValueError("prior receipt does not identify this source and output size")
            if evidence.get("neutral", {}).get("sha256") != reuse["png_sha256"]:
                raise ValueError("prior receipt does not identify the reused output hash")
            pw, ph, pixels = read_png(previous)
            if [pw, ph] != planned_entry["dimensions"] or any(a != 255 for a in pixels[3::4]):
                raise ValueError("reused candidate dimensions/alpha changed")
            planned_entry["reuse_path"] = str(previous)
        else:
            model = models.get(candidate["model"])
            if not isinstance(model, dict) or not model.get("source_url") or not model.get("license"):
                raise ValueError("first-pass model source and license are required")
            if candidate["model"] not in verified_models:
                pinned_file(recipe_path.parent, model, "weights", "sha256")
                verified_models.add(candidate["model"])
            if passes and not verified_finisher:
                finisher = config.get("finisher", {})
                if not finisher.get("source_url") or not finisher.get("license"):
                    raise ValueError("finisher source and license are required")
                pinned_file(recipe_path.parent, finisher, "weights", "sha256")
                verified_finisher = True
        planned.append(planned_entry)
    return config, {"path": str(manifest), "sha256": sha(manifest)}, planned


def inference_padding(height: int, width: int) -> list[int]:
    """Keep source pixels unscaled; expand sampler-correct context to DAT's grid.

    Existing 64/128/256/512 inputs retain exactly their original 32-pixel border.
    Small sources need a larger border, not a preliminary image resize. A 64-wide
    model grid and symmetric per-axis borders keep the crop origin unambiguous.
    """
    sizes = (height, width)
    if any(type(size) is not int or size < 16 or size > 512 or size & (size-1) for size in sizes):
        raise ValueError("first-pass source dimensions must be powers of two from 16 through 512")
    return [32 + (-(size + 64) % 64)//2 for size in sizes]


def padded_source(rgb: np.ndarray, wraps: list[str], border: int | list[int] = 32) -> np.ndarray:
    if len(wraps) != 2 or any(w not in {"repeat", "mirror", "clamp"} for w in wraps):
        raise ValueError("explicit source T/S sampler modes are required")
    borders = [border, border] if type(border) is int else border
    if len(borders) != 2 or any(type(b) is not int or b < 0 for b in borders):
        raise ValueError("nonnegative integer T/S borders are required")
    for axis, wrap in enumerate(wraps):
        padding = [(0, 0)]*3
        padding[axis] = (borders[axis], borders[axis])
        rgb = np.pad(rgb, padding, mode={"repeat": "wrap", "mirror": "symmetric", "clamp": "edge"}[wrap])
    return rgb


def checked_pixels(pixels: np.ndarray, width: int, height: int) -> np.ndarray:
    if pixels.shape != (height, width, 3) or not np.isfinite(pixels).all():
        raise ValueError("restoration returned unexpected dimensions or nonfinite pixels")
    return pixels.clip(0, 1)


class LocalModels:
    def __init__(self, config: dict, base: Path, device: str, provider: str, dat_window_batch_size=0,
                 cpu_conv_output_rows=0):
        self.config, self.base, self.device, self.provider = config, base, device, provider
        self.model, self.name, self.session = None, None, None
        self.dat_window_batch_size = dat_window_batch_size
        self.cpu_conv_output_rows = cpu_conv_output_rows
        self.metadata = {"device": device, "precision": "float32", "models": {}}

    def first(self, name: str, rgb: np.ndarray, wraps: list[str]) -> np.ndarray:
        import torch
        # The two inference stages never run together. Do not retain the ONNX
        # allocator while loading the RGB model for the next texture.
        self.session = None
        if self.name != name:
            self.model = None
            if self.device == "mps":
                torch.mps.empty_cache()
            weights = pinned_file(self.base, self.config["models"][name], "weights", "sha256")
            self.model = load_image_model(weights, self.device)
            if self.dat_window_batch_size:
                from tools.dat_window_batches import install_window_batches
                self.metadata['dat_window_batching'] = install_window_batches(
                    self.model, self.dat_window_batch_size, release_cpu_cache=self.device == 'cpu')
            if self.cpu_conv_output_rows:
                from tools.dat_window_batches import install_cpu_convolution_batches
                self.metadata['cpu_convolution_batching'] = install_cpu_convolution_batches(
                    self.model, self.cpu_conv_output_rows)
            if self.model.scale != 4:
                raise ValueError("first-pass model must be exactly 4x")
            self.name = name
            self.metadata.update(torch=torch.__version__, spandrel=importlib.metadata.version("spandrel"))
            self.metadata["models"][name] = {**self.config["models"][name], "architecture": self.model.architecture.id}
        borders = inference_padding(rgb.shape[0], rgb.shape[1])
        padded = padded_source(rgb, wraps, borders)
        tensor = torch.from_numpy(padded.transpose(2, 0, 1).copy())[None].to(self.device)
        with torch.inference_mode():
            result = self.model(tensor)
        if tuple(result.shape) != (1, 3, padded.shape[0]*4, padded.shape[1]*4):
            raise ValueError("unexpected first-pass model shape")
        # Moving back to CPU also waits for MPS inference completion.
        top, left = (border*4 for border in borders)
        return result[0, :, top:top+rgb.shape[0]*4, left:left+rgb.shape[1]*4].cpu().numpy().transpose(1, 2, 0)

    def finish(self, rgb: np.ndarray, wraps: list[str]) -> np.ndarray:
        import onnxruntime as ort
        if self.model is not None:
            # first() has already copied/synchronized its output to CPU. Drop
            # model weights and cached GPU allocations before the luma stage.
            self.model, self.name = None, None
            gc.collect()
            if self.device == "mps":
                import torch
                torch.mps.empty_cache()
            elif self.device == "cpu" and sys.platform == 'darwin':
                from tools.dat_window_batches import release_cached_heap
                self.metadata['first_stage_released_heap_bytes'] = release_cached_heap()
        if self.session is None:
            providers = ["CPUExecutionProvider"]
            if self.provider == "coreml":
                if "CoreMLExecutionProvider" not in ort.get_available_providers():
                    raise ValueError("CoreML unavailable; use explicit --provider cpu for CPU-only execution")
                providers.insert(0, ("CoreMLExecutionProvider", {"MLComputeUnits": "CPUAndGPU", "ModelFormat": "MLProgram"}))
            weights = pinned_file(self.base, self.config["finisher"], "weights", "sha256")
            options = ort.SessionOptions()
            if self.provider == "cpu":
                # Bound convolution/thread workspaces; this changes scheduling,
                # not weights, tile context, precision or output resolution.
                options.intra_op_num_threads = 1
                options.inter_op_num_threads = 1
                options.enable_cpu_mem_arena = False
            self.session = ort.InferenceSession(str(weights), sess_options=options, providers=providers)
            descriptor = self.session.get_inputs()[0]
            if descriptor.type != "tensor(float)" or len(descriptor.shape) != 4 or descriptor.shape[1] != 1:
                raise ValueError("finisher must be an FP32 NCHW single-channel luma model")
            self.metadata["finisher"] = {**self.config["finisher"], "onnxruntime": ort.__version__,
                "requested_provider": self.provider, "registered_providers": self.session.get_providers(),
                "intra_op_num_threads": options.intra_op_num_threads,
                "inter_op_num_threads": options.inter_op_num_threads,
                "enable_cpu_mem_arena": options.enable_cpu_mem_arena}
        return enlarge(self.session, rgb, wraps, progress=lambda *a, **kw: None)


def run(recipe_path: Path, output: Path, device: str = "mps", provider: str = "coreml", *, engines=None) -> dict:
    config, manifest, planned = plan(recipe_path, output)
    if engines is None:
        engines = LocalModels(config, recipe_path.resolve().parent, device, provider)
    destination = output.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    (destination/"candidates").mkdir()
    (destination/"first-pass").mkdir()
    report = {"schema": "protector-native.texture-restoration-batch-receipt/v1", "status": "incomplete",
        "acceptance": "candidate only; visual and in-engine review required", "recipe": config,
        "recipe_sha256": sha(recipe_path), "sources": manifest, "results": [],
        "method": "one local 4x RGB restoration; neutral 2x BT.709 luma with sampler-aware bilinear chroma",
        "first_pass_minimum_padding": 32, "first_pass_alignment": 64, "mirror_padding": "symmetric",
        "metric_note": "source roundtrip/color drift, not reconstructed-detail accuracy"}
    pack_entries = []
    for entry in planned:
        source = Path(entry["source_path"])
        if sha(source) != entry["source_png_sha256"]:
            raise ValueError("source PNG changed after planning")
        with Image.open(source) as original:
            src = np.asarray(original.convert("RGB"), dtype=np.float32)/255
        target = destination/"candidates"/(entry["name"]+".png")
        started = time.perf_counter()
        record = {k: v for k, v in entry.items() if k not in {"reuse_path", "source_path"}}
        if "reuse" in entry:
            previous = Path(entry["reuse_path"])
            if sha(previous) != entry["reuse"]["png_sha256"]:
                raise ValueError("reused candidate changed after planning")
            shutil.copyfile(previous, target)
            with Image.open(target) as restored:
                picture = restored.convert("RGB")
            record["method"] = "reuse immutable previous candidate without changing pixels"
        else:
            pixels = checked_pixels(engines.first(entry["model"], src, entry["wrap_t_s"]), src.shape[1]*4, src.shape[0]*4)
            first = destination/"first-pass"/(entry["name"]+".png")
            first_picture = Image.fromarray(np.rint(pixels*255).astype(np.uint8))
            first_picture.save(first)
            pixels = np.asarray(first_picture, dtype=np.float32)/255
            record["first_pass"] = {"png": str(first.relative_to(destination)), "sha256": sha(first)}
            for _ in range(entry["finishing_passes"]):
                pixels = checked_pixels(engines.finish(pixels, entry["wrap_t_s"]), pixels.shape[1]*2, pixels.shape[0]*2)
            picture = Image.fromarray(np.rint(pixels*255).astype(np.uint8))
            picture.save(target)
            record["method"] = report["method"]
        if list(picture.size) != entry["dimensions"]:
            raise ValueError("final dimensions do not match the requested target")
        difference = np.asarray(picture.resize((src.shape[1], src.shape[0]), Image.Resampling.LANCZOS), dtype=np.float32)-src*255
        record.update(png=str(target.relative_to(destination)), png_sha256=sha(target), seconds=time.perf_counter()-started,
            source_roundtrip_mae_255=float(np.abs(difference).mean()), mean_rgb_delta_255=difference.mean(axis=(0, 1)).tolist())
        report["results"].append(record)
        report["runtime"] = engines.metadata
        (destination/"receipt.json").write_text(json.dumps(report, indent=2)+"\n")
        pack_entries.append({"source": entry["source"], "png": record["png"], "png_sha256": record["png_sha256"], "treatment": "restore",
            "provenance": {"method": record["method"], "batch_recipe_sha256": report["recipe_sha256"],
                "candidate_png_sha256": record["png_sha256"], "model": entry.get("model"),
                "models": config.get("models", {}), "finisher": config.get("finisher"),
                "reuse": entry.get("reuse"), "wrap_t_s": entry["wrap_t_s"], "finishing_passes": entry["finishing_passes"],
                "first_pass_padding_t_s": entry["first_pass_padding_t_s"]}})
        print(json.dumps({"name": entry["name"], "dimensions": entry["dimensions"], "seconds": record["seconds"]}), flush=True)
    report["status"] = "complete-candidates"
    (destination/"receipt.json").write_text(json.dumps(report, indent=2)+"\n")
    recipe = {"schema": "protector-native.texture-pack-recipe/v1", "pack_id": config["pack_id"],
        "sources": manifest["path"], "sources_sha256": manifest["sha256"], "entries": pack_entries}
    with (destination/"pack-recipe.json").open("x") as stream:
        stream.write(json.dumps(recipe, indent=2)+"\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    parser.add_argument("--provider", choices=("coreml", "cpu"), default="coreml")
    args = parser.parse_args()
    report = run(args.recipe, args.output, args.device, args.provider)
    print(json.dumps({"status": report["status"], "candidates": len(report["results"])}))


if __name__ == "__main__":
    main()

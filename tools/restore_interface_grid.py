#!/usr/bin/env python3
"""Restore a traced opaque interface grid as one canvas, then split exact tiles.

The model sees neighboring tiles at every internal join. Only the exterior
canvas boundary is clamped. No guest tint, UV, geometry, auxiliary coverage or
visibility is changed. Outputs remain private candidates pending visual review.
"""
from __future__ import annotations

import argparse
import importlib.metadata
import json
from pathlib import Path
import sys
import time

import numpy as np
from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from tools.assemble_interface_grid import no_links, report, sha
from tools.benchmark_texture_restoration import load_image_model
from tools.prepare_texture_restoration import DOL_SHA256
from tools.restore_texture_batch import LocalModels, checked_pixels, identifier, padded_source, pinned_file


def plan(recipe_path: Path, output: Path) -> tuple[dict, dict, np.ndarray]:
    recipe_path, recipe_bytes, config = report(recipe_path)
    if config.get("schema") not in ("protector-native.interface-grid-restoration/v1", "protector-native.interface-grid-restoration/v2"):
        raise ValueError("an explicit interface-grid restoration recipe is required")
    paired = config["schema"].endswith("/v2")
    identifier(config.get("pack_id"))
    grid_path = pinned_file(recipe_path.parent, config, "grid", "grid_sha256")
    grid_path, grid_bytes, grid = report(grid_path)
    if grid.get("schema") != "protector-native.interface-source-grid/"+("v2" if paired else "v1") or grid.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("a source-traced original-title grid is required")
    if grid.get("method") != "byte-exact row-major assembly; no resampling or restoration":
        raise ValueError("grid must contain unmodified original pixels")
    manifest_path, manifest_bytes, manifest = report(Path(grid["source_manifest"]))
    if sha(manifest_bytes) != grid["source_manifest_sha256"] or \
            manifest.get("schema") != "protector-native.texture-restoration-sources/"+("v2" if paired else "v1") or \
            manifest.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("original source inventory changed")
    # Recheck the live evidence supporting the grid, not just a freely edited
    # list of tiles. The PNG's hash and every tile's raw identity follow below.
    for name in ("audit", "trace"):
        path, data, _ = report(Path(grid[name]))
        if sha(data) != grid[name+"_sha256"]:
            raise ValueError("grid source evidence changed")
    png = no_links(grid_path.parent / grid["png"])
    if not png.is_relative_to(grid_path.parent) or sha(png.read_bytes()) != grid["png_sha256"]:
        raise ValueError("grid PNG changed or escapes its source directory")
    coverage = None
    if paired:
        info = grid.get("coverage", {})
        coverage_path = no_links(grid_path.parent / info.get("png", ""))
        if not coverage_path.is_relative_to(grid_path.parent) or not coverage_path.is_file() or \
                sha(coverage_path.read_bytes()) != info.get("png_sha256"):
            raise ValueError("grid coverage PNG changed or escapes its source directory")
        with Image.open(coverage_path) as image:
            if image.mode != "RGBA" or list(image.size) != grid["dimensions"]:
                raise ValueError("coverage canvas dimensions or format changed")
            coverage = image.copy()
        if sha(coverage.tobytes()) != info.get("rgba8_sha256") or coverage.getextrema()[3] != (255, 255):
            raise ValueError("coverage plane pixels changed or carry alpha")
    with Image.open(png) as original:
        if original.mode != "RGBA" or list(original.size) != grid["dimensions"] or \
                max(original.size) > 2048 or original.width*original.height > 2*1024*1024 or \
                min(original.size) < (16 if paired else 64) or any(size % (16 if paired else 64) for size in original.size):
            raise ValueError("whole-canvas restoration needs a bounded aligned RGBA grid")
        pixels = original.tobytes()
        if sha(pixels) != grid["rgba8_sha256"] or any(a != 255 for a in pixels[3::4]):
            raise ValueError("grid source pixels changed or carry alpha")
        rgb = np.asarray(original.convert("RGB"), dtype=np.float32)/255
        rows, columns = grid.get("rows"), grid.get("columns")
        if type(rows) is not int or type(columns) is not int or not 1 <= rows*columns <= 64 or \
                len(grid.get("tiles", [])) != rows*columns:
            raise ValueError("grid tile coverage is invalid")
        if paired:
            widths, heights = grid.get("column_widths"), grid.get("row_heights")
        else:
            tile_width, tile_height = grid["tile_dimensions"]
            widths, heights = [tile_width]*columns, [tile_height]*rows
        if not isinstance(widths, list) or not isinstance(heights, list) or \
                (len(widths), len(heights)) != (columns, rows) or \
                any(type(n) is not int or n < 1 for n in widths+heights) or \
                [sum(widths), sum(heights)] != grid["dimensions"]:
            raise ValueError("grid tile dimensions are invalid")
        seen = set()
        for i, tile in enumerate(grid["tiles"]):
            row, column = divmod(i, columns)
            tile_width, tile_height = widths[column], heights[row]
            x, y = sum(widths[:column]), sum(heights[:row])
            rect = [x, y, x+tile_width, y+tile_height]
            if tile.get("pixel_rect") != rect or (tile.get("row"), tile.get("column")) != (row, column):
                raise ValueError("grid tile order or bounds changed")
            key = tile["stage_keys"][0]
            if key in seen or key not in manifest["textures"] or \
                    key != f"{tile_width}x{tile_height}-"+sha(original.crop(tuple(rect)).tobytes()):
                raise ValueError("tile source identity changed or is duplicated")
            seen.add(key)
            if paired:
                keys = tile["stage_keys"]
                if len(keys) not in (1, 2):
                    raise ValueError("invalid source plane count")
                mask_bytes = coverage.crop(tuple(rect)).tobytes()
                if len(keys) == 2:
                    if keys[1] not in manifest["textures"] or keys[1] != f"{tile_width}x{tile_height}-"+sha(mask_bytes):
                        raise ValueError("coverage tile source identity changed")
                elif mask_bytes != bytes((0, 255, 0, 255))*tile_width*tile_height:
                    raise ValueError("implicit opaque coverage changed")
    model = config.get("model", {})
    if not model.get("source_url") or not model.get("license") or not model.get("name"):
        raise ValueError("model identity, original source and license are required")
    weights = pinned_file(recipe_path.parent, model, "weights", "sha256")
    scale = config.get("scale", 4)
    if type(scale) is not int or scale not in (4, 8, 16) or (not paired and scale != 4) or \
            max(grid["dimensions"])*scale > 8192 or (paired and max(grid["dimensions"])*scale > 4096):
        raise ValueError("use a bounded 4x restoration with zero, one or two neutral 2x finishing passes")
    if scale > 4:
        finisher = config.get("finisher", {})
        if not finisher.get("source_url") or not finisher.get("license"):
            raise ValueError("neutral finisher source and license are required")
        pinned_file(recipe_path.parent, finisher, "weights", "sha256")
    destination = no_links(output)
    if destination.exists() or any(destination.is_relative_to(parent) for parent in (
            ROOT, grid_path.parent, manifest_path.parent, Path(manifest["source_data_root"]).resolve())):
        raise ValueError("use a new external destination outside original sources")
    context = {"recipe": str(recipe_path), "recipe_sha256": sha(recipe_bytes), "grid": str(grid_path),
        "grid_sha256": sha(grid_bytes), "source_manifest": str(manifest_path),
        "source_manifest_sha256": sha(manifest_bytes), "weights": str(weights), "source_grid": grid,
        "scale": scale, "paired": paired, "coverage_path": str(coverage_path) if paired else None}
    return config, context, rgb


class CanvasModel:
    def __init__(self, weights: Path, device: str):
        import torch
        self.model = load_image_model(weights, device)
        if self.model.scale != 4:
            raise ValueError("whole-grid model must be exactly 4x")
        self.device = device
        self.metadata = {"architecture": self.model.architecture.id, "device": device,
            "torch": torch.__version__, "spandrel": importlib.metadata.version("spandrel"), "precision": "float32"}

    def __call__(self, rgb: np.ndarray) -> np.ndarray:
        import torch
        tensor = torch.from_numpy(rgb.transpose(2, 0, 1).copy())[None].to(self.device)
        with torch.inference_mode():
            result = self.model(tensor)
        if tuple(result.shape) != (1, 3, rgb.shape[0]*4, rgb.shape[1]*4):
            raise ValueError("model returned the wrong whole-canvas shape")
        return result[0].cpu().numpy().transpose(1, 2, 0)


def run(recipe_path: Path, output: Path, device: str = "mps", *, engine=None, finisher=None,
        provider: str = "cpu") -> dict:
    config, context, source = plan(recipe_path, output)
    if engine is None:
        engine = CanvasModel(Path(context["weights"]), device)
    # A single invocation, not independent tile upscales or blended patches.
    borders = [32 + (-(size+64) % 64)//2 for size in source.shape[:2]]
    padded = padded_source(source, ["clamp", "clamp"], borders)
    started = time.perf_counter()
    result = checked_pixels(engine(padded), padded.shape[1]*4, padded.shape[0]*4)
    top, left = [b*4 for b in borders]
    restored = result[top:top+source.shape[0]*4, left:left+source.shape[1]*4]
    if context["scale"] > 4:
        if finisher is None:
            neutral = LocalModels(config, recipe_path.parent, device, provider)
            finisher = neutral.finish
        for _ in range((context["scale"]//4).bit_length()-1):
            restored = checked_pixels(finisher(restored, ["clamp", "clamp"]),
                                      restored.shape[1]*2, restored.shape[0]*2)
    picture = Image.fromarray(np.rint(restored*255).astype(np.uint8))
    coverage = None
    if context["paired"]:
        with Image.open(context["coverage_path"]) as original_coverage:
            # Preserve all encoded RGB channels; TEV reads the green channel.
            # Never binarize soft glow coverage or invent a new alpha path.
            coverage = original_coverage.convert("RGB").resize(picture.size, Image.Resampling.BICUBIC)
    elapsed = time.perf_counter()-started
    if sha(Path(context["grid"]).read_bytes()) != context["grid_sha256"] or \
            sha(recipe_path.read_bytes()) != context["recipe_sha256"]:
        raise ValueError("recipe or grid changed during inference")
    # Revalidate every pinned source, mask and weight before publishing outputs.
    # A concurrent source edit must not yield a receipt for earlier bytes.
    plan(recipe_path, output)
    destination = no_links(output)
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "tiles").mkdir()
    boundary = f"clamp exterior only; source T/S borders {borders}; internal joins see neighboring pixels"
    origin = {"method": "one local 4x whole-canvas restoration of decoded original game artwork",
        "source_grid": context["grid"], "source_grid_sha256": context["grid_sha256"],
        "recipe_sha256": context["recipe_sha256"], "model": config["model"],
        "boundary": boundary, "scale": context["scale"], "finisher": config.get("finisher"),
        "acceptance": "candidate only; not source high-resolution ground truth"}
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("protector_origin", json.dumps(origin, sort_keys=True))
    metadata.add_text("impeccable:prompt", "Source origin (local restoration, no text prompt): "+json.dumps(origin, sort_keys=True))
    picture.save(destination / "restored-grid.png", pnginfo=metadata)
    if coverage is not None:
        mask_origin = {**origin, "method": "one whole-canvas bicubic coverage resample; no threshold or learned detail"}
        mask_metadata = PngImagePlugin.PngInfo()
        mask_metadata.add_text("protector_origin", json.dumps(mask_origin, sort_keys=True))
        mask_metadata.add_text("impeccable:prompt", "Source origin: "+json.dumps(mask_origin, sort_keys=True))
        coverage.save(destination / "restored-coverage.png", pnginfo=mask_metadata)
    difference = np.asarray(picture.resize((source.shape[1], source.shape[0]), Image.Resampling.LANCZOS), dtype=np.float32)-source*255
    receipt = {"schema": "protector-native.interface-grid-restoration-receipt/"+("v2" if context["paired"] else "v1"), "status": "complete-candidate",
        "acceptance": "candidate only; offline and in-engine review required", **{k: v for k, v in context.items() if k != "source_grid"},
        "model": config["model"], "runtime": getattr(engine, "metadata", {}),
        "finisher_runtime": getattr(getattr(finisher, "__self__", None), "metadata", {}), "dimensions": list(picture.size),
        "png": "restored-grid.png", "png_sha256": sha((destination / "restored-grid.png").read_bytes()),
        "rgb8_sha256": sha(picture.tobytes()), "seconds": elapsed,
        "method": "one 4x model invocation on the full connected canvas; optional neutral 2x finishing; exact tile crops",
        "boundary": boundary,
        "source_roundtrip_mae_255": float(np.abs(difference).mean()),
        "mean_rgb_delta_255": difference.mean(axis=(0, 1)).tolist(),
        "metric_note": "source drift, not reconstruction accuracy or artistic acceptance", "tiles": []}
    pack_entries = []
    if coverage is not None:
        receipt["coverage"] = {"png": "restored-coverage.png", "png_sha256": sha((destination / "restored-coverage.png").read_bytes()),
            "rgb8_sha256": sha(coverage.tobytes()), "method": mask_origin["method"]}
    for tile in context["source_grid"]["tiles"]:
        rect = [v*context["scale"] for v in tile["pixel_rect"]]
        relative = f"tiles/r{tile['row']:02}-c{tile['column']:02}.png"
        cropped = picture.crop(tuple(rect))
        metadata = PngImagePlugin.PngInfo()
        metadata.add_text("protector_origin", json.dumps({**origin, "source_key": tile["stage_keys"][0],
            "pixel_rect": rect, "restored_canvas_sha256": receipt["png_sha256"]}, sort_keys=True))
        metadata.add_text("impeccable:prompt", "Source origin (local restoration, no text prompt): "+json.dumps(
            {**origin, "source_key": tile["stage_keys"][0], "pixel_rect": rect}, sort_keys=True))
        cropped.save(destination / relative, pnginfo=metadata)
        entry = {"source": tile["stage_keys"][0], "png": relative,
            "png_sha256": sha((destination / relative).read_bytes()), "pixel_rect": rect,
            "dimensions": list(cropped.size), "rgb8_sha256": sha(cropped.tobytes()),
            "unchanged_auxiliary_keys": [] if context["paired"] else tile["stage_keys"][1:]}
        receipt["tiles"].append(entry)
        pack_entries.append({"source": entry["source"], "png": relative, "png_sha256": entry["png_sha256"],
            "treatment": "restore", "provenance": {"method": receipt["method"], "model": config["model"],
                "recipe_sha256": context["recipe_sha256"], "source_grid_sha256": context["grid_sha256"],
                "restored_canvas_sha256": receipt["png_sha256"], "pixel_rect": rect,
                "unchanged_auxiliary_keys": entry["unchanged_auxiliary_keys"], "boundary": receipt["boundary"]}})
        if context["paired"]:
            pack_entries[-1]["alpha_mode"] = "opaque"
            if len(tile["stage_keys"]) == 2:
                mask_key = tile["stage_keys"][1]
                mask_relative = f"tiles/r{tile['row']:02}-c{tile['column']:02}-coverage.png"
                cropped_coverage = coverage.crop(tuple(rect))
                tile_origin = {**mask_origin, "source_key": mask_key, "pixel_rect": rect,
                    "restored_canvas_sha256": receipt["coverage"]["png_sha256"]}
                tile_metadata = PngImagePlugin.PngInfo()
                tile_metadata.add_text("protector_origin", json.dumps(tile_origin, sort_keys=True))
                tile_metadata.add_text("impeccable:prompt", "Source origin: "+json.dumps(tile_origin, sort_keys=True))
                cropped_coverage.save(destination / mask_relative, pnginfo=tile_metadata)
                mask_entry = {"source": mask_key, "png": mask_relative,
                    "png_sha256": sha((destination / mask_relative).read_bytes()), "pixel_rect": rect,
                    "dimensions": list(cropped_coverage.size), "rgb8_sha256": sha(cropped_coverage.tobytes()),
                    "unchanged_auxiliary_keys": [], "plane": 1}
                # A shared coverage key cannot bind to different context-restored pixels.
                previous = next((e for e in receipt["tiles"] if e["source"] == mask_key), None)
                if previous is not None and previous["rgb8_sha256"] != mask_entry["rgb8_sha256"]:
                    raise ValueError("shared coverage identity has conflicting whole-canvas results")
                if previous is None:
                    receipt["tiles"].append(mask_entry)
                    pack_entries.append({"source": mask_key, "png": mask_relative,
                        "png_sha256": mask_entry["png_sha256"], "alpha_mode": "opaque", "treatment": "restore",
                        "provenance": tile_origin})
    (destination / "receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    pack_recipe = {"schema": "protector-native.texture-pack-recipe/"+("v2" if context["paired"] else "v1"), "pack_id": config["pack_id"],
        "sources": context["source_manifest"], "sources_sha256": context["source_manifest_sha256"], "entries": pack_entries}
    (destination / "pack-recipe.json").write_text(json.dumps(pack_recipe, indent=2)+"\n")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    parser.add_argument("--provider", choices=("coreml", "cpu"), default="cpu", help="Optional neutral finisher provider")
    args = parser.parse_args()
    receipt = run(args.recipe, args.output, args.device, provider=args.provider)
    print(json.dumps({k: receipt[k] for k in ("status", "dimensions", "seconds", "source_roundtrip_mae_255")}))


if __name__ == "__main__":
    main()

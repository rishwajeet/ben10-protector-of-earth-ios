#!/usr/bin/env python3
"""Finish one hash-verified 1K restoration with neutral 2x luma reconstruction.

ArtCNN's unsuffixed luma model predicts full-range brightness, not RGB. Color
differences are interpolated separately; the receipt names that choice. This
is an offline candidate tool, not a claim of recovered original 4K detail.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def luma(rgb: np.ndarray) -> np.ndarray:
    return rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def resize_plane(plane: np.ndarray, size: tuple[int, int], wraps: list[str]) -> np.ndarray:
    """Interpolate chroma with the same boundary conditions as neural luma."""
    height, width = plane.shape
    if len(wraps) != 2 or any(w not in {"repeat", "mirror", "clamp"} for w in wraps):
        raise ValueError("Explicit source T/S sampler modes are required")
    if size[0] % width or size[1] % height:
        raise ValueError("Chroma interpolation requires integer scale factors")
    sx, sy = size[0] // width, size[1] // height
    if sx < 1 or sy < 1:
        raise ValueError("Chroma interpolation may not reduce resolution")
    border = 2
    padded = plane
    for axis, wrap in enumerate(wraps):
        padding = [(0, 0), (0, 0)]
        padding[axis] = (border, border)
        padded = np.pad(padded, padding,
            mode={"repeat": "wrap", "mirror": "symmetric", "clamp": "edge"}[wrap])
    enlarged = np.asarray(Image.fromarray(padded).resize(
        ((width + 2*border)*sx, (height + 2*border)*sy), Image.Resampling.BILINEAR))
    return enlarged[border*sy:(border+height)*sy, border*sx:(border+width)*sx]


def combine_luma(rgb: np.ndarray, predicted: np.ndarray, wraps: list[str]) -> np.ndarray:
    size = (predicted.shape[1], predicted.shape[0])
    colors = np.stack([resize_plane(rgb[:, :, c], size, wraps) for c in range(3)], axis=-1)
    return (colors + (predicted - luma(colors))[:, :, None]).clip(0, 1)


def enlarge(session, rgb: np.ndarray, wraps: list[str], progress=print) -> np.ndarray:
    if rgb.ndim != 3 or rgb.shape[2] != 3 or min(rgb.shape[:2]) < 1 or not np.isfinite(rgb).all():
        raise ValueError("Nonempty finite RGB pixels are required")
    height, width = rgb.shape[:2]
    if len(wraps) != 2 or any(w not in {"repeat", "mirror", "clamp"} for w in wraps):
        raise ValueError("Explicit source T/S sampler modes are required")
    brightness = luma(rgb)
    border, core, scale = 40, 256, 2
    padded = brightness
    for axis, wrap in enumerate(wraps):
        padding = [(0, 0), (0, 0)]
        # Complete partial tiles with the same source sampler, not a prescale or
        # zero fill. Full-size tiles retain exactly the established input path.
        padding[axis] = (border, border + (-brightness.shape[axis] % core))
        padded = np.pad(padded, padding, mode={"repeat":"wrap", "mirror":"symmetric", "clamp":"edge"}[wrap])
    output = np.empty((height*scale, width*scale), dtype=np.float32)
    name = session.get_inputs()[0].name
    started = time.perf_counter()
    total = ((height+core-1)//core)*((width+core-1)//core)
    for index, (y, x) in enumerate((y, x) for y in range(0, height, core) for x in range(0, width, core)):
        tile = np.ascontiguousarray(padded[y:y+core+2*border, x:x+core+2*border][None, None])
        result = session.run(None, {name:tile})[0]
        expected = (1, 1, (core+2*border)*scale, (core+2*border)*scale)
        if result.shape != expected or not np.isfinite(result).all():
            raise ValueError("Unexpected ArtCNN output shape or nonfinite pixels")
        tile_height, tile_width = min(core,height-y), min(core,width-x)
        output[y*scale:(y+tile_height)*scale, x*scale:(x+tile_width)*scale] = result[0, 0,
            border*scale:(border+tile_height)*scale, border*scale:(border+tile_width)*scale]
        progress(f"{width} to {width*scale}: tile {index+1}/{total}, {time.perf_counter()-started:.1f}s", flush=True)
    return combine_luma(rgb, output, wraps)


def main() -> None:
    import onnxruntime as ort
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--first-model", required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--provider", choices=("coreml", "cpu"), default="coreml")
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    result = next(r for r in report["results"] if r["model"] == args.first_model)
    sample = next(s for s in result["samples"] if s["name"] == args.sample)
    source = Path(sample["png"]).resolve(strict=True)
    if digest(source) != sample["png_sha256"]:
        raise ValueError("First-pass pixels changed after the benchmark")
    with Image.open(source) as original:
        if original.size != (1024, 1024) or original.convert("RGBA").getextrema()[3] != (255, 255):
            raise ValueError("This candidate comparison requires opaque 1024-square first-pass pixels")
        source_image = original.convert("RGB")
    destination = args.output.resolve()
    if destination.is_relative_to(Path(__file__).resolve().parents[1]) or \
            destination.is_relative_to(args.report.resolve().parent) or \
            destination.is_relative_to(source.parent) or destination.exists() or args.output.is_symlink():
        raise ValueError("Use a new private output directory outside Git and input artwork")
    providers = ["CPUExecutionProvider"]
    if args.provider == "coreml":
        if "CoreMLExecutionProvider" not in ort.get_available_providers():
            raise ValueError("CoreML is unavailable; CPU fallback requires --provider cpu")
        providers.insert(0, ("CoreMLExecutionProvider", {"MLComputeUnits":"CPUAndGPU", "ModelFormat":"MLProgram"}))
    session = ort.InferenceSession(str(args.weights.resolve(strict=True)), providers=providers)
    descriptor = session.get_inputs()[0]
    if descriptor.type != "tensor(float)" or len(descriptor.shape) != 4 or descriptor.shape[1] != 1:
        raise ValueError("An FP32 NCHW single-channel 2x luma model is required")
    destination.mkdir(parents=True, exist_ok=False)
    pixels = np.asarray(source_image, dtype=np.float32)/255
    started = time.perf_counter()
    for _ in range(2):
        pixels = enlarge(session, pixels, sample["wrap_t_s"])
    elapsed = time.perf_counter()-started
    neutral = Image.fromarray(np.rint(pixels*255).astype(np.uint8))
    neutral.save(destination/"neutral-4k.png")
    baseline = source_image.resize((4096, 4096), Image.Resampling.LANCZOS)
    baseline.save(destination/"lanczos-4k.png")
    receipt = {"schema":"protector-native.texture-finishing-comparison/v1", "status":"candidate",
        "source":sample["source"], "first_pass":sample, "first_model":result["model"],
        "finishing_model":str(args.weights.resolve()), "model_sha256":digest(args.weights),
        "onnxruntime":ort.__version__, "providers":session.get_providers(),
        "provider_options":session.get_provider_options(), "passes":2, "scale_per_pass":2,
        "color":"full-range BT.709 luma reconstruction; sampler-aware bilinear chroma; clip each pass",
        "chroma_context_border":2,
        "tile_core":256, "context_border":40, "wrap_t_s":sample["wrap_t_s"],
        "finishing_seconds":elapsed, "dimensions":[4096,4096], "total_scale_from_source":16,
        "neutral":{"png":"neutral-4k.png", "sha256":digest(destination/"neutral-4k.png")},
        "lanczos":{"png":"lanczos-4k.png", "sha256":digest(destination/"lanczos-4k.png")}}
    (destination/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    sheet = Image.new("RGB", (1032,1100), "#202126")
    draw = ImageDraw.Draw(sheet)
    for col, (label, picture) in enumerate((("4K Lanczos finishing",baseline),("4K neutral luma finishing",neutral))):
        draw.text((col*516+4,5), label, fill="white")
        for row,(x,y) in enumerate(((1792,1792),(768,512))):
            sheet.paste(picture.crop((x,y,x+512,y+512)),(col*516+2,35+row*530))
    sheet.save(destination/"comparison.png")
    print(json.dumps(receipt), flush=True)


if __name__ == "__main__":
    main()

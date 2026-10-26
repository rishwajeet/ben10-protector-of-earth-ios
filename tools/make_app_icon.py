#!/usr/bin/env python3
"""Render the iOS app icon from the artwork bundle's Omnitrix vectors.

    uv run --no-project --with-requirements requirements-personal-vectors.lock python \\
        tools/make_app_icon.py --authored-inputs ../authored-inputs --output "$WORK/build/app-icon"

The icon is the closed Omnitrix face with its side panels lit, its four marker
lights and a procedural transformation-ooze backdrop. Both drawings come from
the bundle's vector family, so no icon artwork lives in this repository.
Writes an Assets.xcassets catalog (default, dark and tinted 1024-pixel PNGs);
`personal_build.py build --authored-inputs` runs this for you.
"""
from __future__ import annotations

import argparse
from io import BytesIO
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.personal_build import BuildError, outside_repo
from tools.export_personal_authored_inputs import checked_root, read_input

# Vector groups pinned by reference/personal_vector_recipes.json.
FACE_SHA256 = "9fd32e2cadc9c48f96608d1bc8cfbf1d09807a5fc4284d9b3458c47ac24c303c"  # closed face and housing
MARKERS_SHA256 = "19e062ed63b396b8ff2819dcb6a8655af13985b508eb0aa136cf56f2adc8f66e"  # four marker lights
S = 1024
LIME = np.array((150, 255, 60), np.float32)
YY, XX = np.mgrid[0:S, 0:S].astype(np.float32)
RADIUS = np.hypot(XX - S / 2, YY - S / 2)


def vector_dimensions():
    contract = json.loads((ROOT / "reference/personal_vector_recipes.json").read_text())
    return {group["vector_sha256"]: group["dimensions"] for group in contract["groups"].values()}


def rasterize(authored: Path, sha: str, dimensions) -> Image.Image:
    import resvg_py
    if resvg_py.__version__ != "0.5.0" or resvg_py.__resvg_version__ != "0.48.1":
        raise BuildError("Use the qualified resvg-py 0.5.0 / resvg 0.48.1 rasterizer")
    _, data, _ = read_input(authored / "vectors", sha, ".svg", dimensions)
    png = resvg_py.svg_to_bytes(svg_string=data.decode("utf-8"), skip_system_fonts=True, width=S, height=S)
    return Image.open(BytesIO(png)).convert("RGBA")


def ooze(seed: int, brightness: float) -> np.ndarray:
    """Lime field with black ooze blobs gathered toward the edges (the transformation backdrop)."""
    rng = np.random.default_rng(seed)
    t = np.clip(RADIUS / (S * .72), 0, 1)[..., None]
    field = (np.array((170, 255, 80)) * (1 - t) + np.array((30, 150, 25)) * t) * brightness
    mask = Image.new("L", (S, S), 0)
    draw = ImageDraw.Draw(mask)
    for _ in range(140):
        angle = rng.uniform(0, 2 * np.pi)
        dist = S * (.30 + rng.uniform(0, .45) ** .7)
        x, y = S / 2 + np.cos(angle) * dist, S / 2 + np.sin(angle) * dist
        r = rng.uniform(10, 55) * (dist / (S * .5))
        draw.ellipse((x - r, y - r, x + r, y + r), fill=255)
        for _ in range(rng.integers(0, 3)):
            ox, oy = rng.normal(0, r * 1.6, 2)
            rr = r * rng.uniform(.2, .45)
            draw.ellipse((x + ox - rr, y + oy - rr, x + ox + rr, y + oy + rr), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(9)).point(lambda v: 255 if v > 110 else 0).filter(ImageFilter.GaussianBlur(1.2))
    k = np.asarray(mask, np.float32)[..., None] / 255
    return field * (1 - k) + np.array((8, 14, 8)) * k


def lit_face(watch: Image.Image) -> Image.Image:
    """Light the closed face's two side panels lime; the hourglass and bezel keep their source shading."""
    a = np.asarray(watch, np.float32).copy()
    rgb, alpha = a[..., :3], a[..., 3]
    box = watch.getbbox()
    cx, cy, half = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, (box[2] - box[0]) / 2
    inside = np.hypot(XX - cx, YY - cy) < half * .73
    panel = (rgb.mean(2) > 55) & ((rgb.max(2) - rgb.min(2)) < 30) & (alpha > 0) & inside
    shade = (rgb.mean(2) / 255)[..., None]
    rgb[panel] = (LIME * (.55 + .6 * shade) + 40)[panel]
    a[..., :3] = rgb
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def lime_markers(markers: Image.Image) -> Image.Image:
    a = np.asarray(markers, np.float32).copy()
    a[..., :3] = np.maximum(a[..., :3], LIME * (a[..., 3:] > 0))
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def centred(layer: Image.Image, scale: float) -> Image.Image:
    crop = layer.crop(layer.getbbox())
    w = int(S * scale)
    crop = crop.resize((w, int(crop.height * w / crop.width)), Image.LANCZOS)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.alpha_composite(crop, ((S - crop.width) // 2, (S - crop.height) // 2))
    return out


def glow(layer: Image.Image, radius: float, strength: float) -> Image.Image:
    halo = Image.new("RGBA", (S, S), (40, 255, 40, 0))
    halo.putalpha(layer.getchannel("A").filter(ImageFilter.GaussianBlur(radius)).point(lambda v: int(min(255, v * strength))))
    return halo


def compose(background: np.ndarray, layers) -> Image.Image:
    base = Image.fromarray(np.clip(background, 0, 255).astype(np.uint8)).convert("RGBA")
    for layer in layers:
        base.alpha_composite(layer)
    return base.convert("RGB")


def write_catalog(authored: Path, output: Path) -> Path:
    authored, output = checked_root(authored), outside_repo(output)
    dimensions = vector_dimensions()
    face = centred(lit_face(rasterize(authored, FACE_SHA256, dimensions[FACE_SHA256])), .70)
    marks = centred(lime_markers(rasterize(authored, MARKERS_SHA256, dimensions[MARKERS_SHA256])), .80)
    catalog = output / "Assets.xcassets"
    icon_set = catalog / "AppIcon.appiconset"
    icon_set.mkdir(parents=True, exist_ok=True)
    default = compose(ooze(3, 1.0), [glow(face, 40, 2.2), marks, face])
    dark = compose(ooze(3, .32) * np.array((.55, .8, .55)), [glow(face, 40, 1.6), marks, face])
    tinted = compose(np.zeros((S, S, 3)), [marks, face]).convert("L").convert("RGB")
    for name, image in (("AppIcon.png", default), ("AppIcon-Dark.png", dark), ("AppIcon-Tinted.png", tinted)):
        image.save(icon_set / name, optimize=True)
    entry = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    contents = {"images": [dict(entry, filename="AppIcon.png"),
                           dict(entry, filename="AppIcon-Dark.png", appearances=[{"appearance": "luminosity", "value": "dark"}]),
                           dict(entry, filename="AppIcon-Tinted.png", appearances=[{"appearance": "luminosity", "value": "tinted"}])],
                "info": {"author": "xcode", "version": 1}}
    (icon_set / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    return catalog


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--authored-inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps({"catalog": str(write_catalog(args.authored_inputs, args.output))}, indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(2, f"App icon: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

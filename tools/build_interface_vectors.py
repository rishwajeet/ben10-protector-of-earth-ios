#!/usr/bin/env python3
"""Rasterize explicitly authored SVG HUD candidates into source-pinned GX planes.

The SVG owns colour and coverage in one coordinate system. A paired source
object receives separate opaque RGB and green-coverage planes, as the original
shader expects. This does not change geometry, UVs, TEV programs or animation.
All proprietary inputs and outputs must remain outside this repository.

Run with uv run --python 3.12 --with pillow --with resvg-py==0.5.0 --with scipy.
"""
from __future__ import annotations

import argparse
import hashlib
from io import BytesIO
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.prepare_texture_restoration import DOL_SHA256


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_vector(path: Path, width: int, height: int, *, max_bytes: int = 1024 * 1024) -> bytes:
    if max_bytes not in {1024 * 1024, 4 * 1024 * 1024}:
        raise ValueError("unsupported bounded vector size policy")
    data = path.read_bytes()
    if len(data) > max_bytes or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("vector exceeds its bound or contains XML entities")
    root = ET.fromstring(data)
    if root.tag != "{http://www.w3.org/2000/svg}svg":
        raise ValueError("a standalone SVG is required")
    try:
        bounds = [float(v) for v in root.attrib["viewBox"].replace(",", " ").split()]
    except (KeyError, ValueError) as exc:
        raise ValueError("SVG must have a source-coordinate viewBox") from exc
    if bounds != [0, 0, width, height]:
        raise ValueError("SVG viewBox must exactly retain the source canvas")
    allowed = {"svg", "g", "defs", "path", "circle", "ellipse", "rect", "line", "polyline",
               "polygon", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "title", "desc"}
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] not in allowed:
            raise ValueError("vector must contain only local paths, shapes, gradients and clips")
        if element.tag.rsplit("}", 1)[-1] == "clipPath" and any(
                child.tag.rsplit("}", 1)[-1] == "g" for child in element):
            raise ValueError("clip paths must use direct shapes with composed transforms")
        for name, value in element.attrib.items():
            if name.rsplit("}", 1)[-1].lower().startswith("on"):
                raise ValueError("SVG event attributes are forbidden")
            if "href" in name.lower() or "@import" in value.lower() or (
                    "url(" in value.lower() and not re.fullmatch(r"url\(#[A-Za-z][\w.-]*\)", value)):
                raise ValueError("SVG external or indirect resources are forbidden")
    return data


def split_planes(picture):
    """Convert straight RGBA artwork to two opaque planes without dark fringes."""
    import numpy as np
    from PIL import Image
    from scipy.ndimage import distance_transform_edt

    pixels = np.asarray(picture.convert("RGBA")).copy()
    alpha = pixels[:, :, 3].copy()
    if not np.any(alpha):
        raise ValueError("vector coverage is empty")
    # Extend the nearest vector colour beyond coverage. This is derived from
    # the new vector, never a resize or repaint of the extracted source bitmap.
    # Filtering RGB and coverage separately must not multiply a black fringe.
    empty = alpha == 0
    if np.any(empty):
        nearest = distance_transform_edt(empty, return_distances=False, return_indices=True)
        pixels[empty, :3] = pixels[nearest[0][empty], nearest[1][empty], :3]
    pixels[:, :, 3] = 255
    mask = np.zeros_like(pixels)
    mask[:, :, 1] = alpha
    mask[:, :, 3] = 255
    return Image.fromarray(pixels), Image.fromarray(mask)


def source_picture(root: Path, textures: dict, key: str, *, allow_alpha: bool = False):
    from PIL import Image
    record = textures.get(key)
    if not isinstance(record, dict) or key != f"{record['width']}x{record['height']}-{record['rgba8_sha256']}":
        raise ValueError("unknown or inconsistent source pixel identity")
    path = (root / record["png"]).resolve(strict=True)
    if not path.is_relative_to(root):
        raise ValueError("source pixels escape their manifest")
    data = path.read_bytes()
    if digest(data) != record["png_sha256"]:
        raise ValueError("source PNG changed")
    with Image.open(BytesIO(data)) as original:
        picture = original.convert("RGBA")
    if picture.size != (record["width"], record["height"]) or digest(picture.tobytes()) != record["rgba8_sha256"]:
        raise ValueError("source pixels changed")
    if not allow_alpha and picture.getchannel("A").getextrema() != (255, 255):
        raise ValueError("this vector lane requires opaque decoded GX planes")
    return picture


def paired_objects(textures: dict, colour: str, mask: str) -> list[tuple]:
    def identities(key, plane):
        return {(o["package"], o["resource_offset"]) for o in textures[key]["occurrences"]
                if type(o.get("plane")) is int and o["plane"] == plane}
    shared = identities(colour, 0) & identities(mask, 1)
    if not shared:
        raise ValueError("colour and coverage do not identify an ordered source-plane pair")
    return sorted(shared)


def coverage_metrics(original, rendered, channel: str = "G") -> dict:
    import numpy as np
    from PIL import Image
    old = np.asarray(original.getchannel(channel)) >= 128
    new = np.asarray(rendered.getchannel("A").resize(original.size, Image.Resampling.LANCZOS)) >= 128
    intersection, union = int(np.sum(old & new)), int(np.sum(old | new))
    return {"diagnostic_only": True, "source_covered_pixels": int(old.sum()),
        "candidate_covered_pixels_at_source_size": int(new.sum()),
        "threshold_128_iou": intersection / union if union else 1.0,
        "source_bbox": original.getchannel(channel).point(lambda v: 255 if v >= 128 else 0).getbbox(),
        "candidate_bbox": Image.fromarray(new.astype("uint8") * 255).getbbox()}


def build(recipe_path: Path, output: Path) -> dict:
    import resvg_py
    from PIL import Image, PngImagePlugin

    recipe_path = recipe_path.resolve(strict=True)
    recipe_data = recipe_path.read_bytes()
    recipe = json.loads(recipe_data)
    if recipe.get("schema") != "protector-native.interface-vector-recipe/v1":
        raise ValueError("an interface-vector recipe is required")
    pack_id = recipe.get("pack_id")
    if not isinstance(pack_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", pack_id):
        raise ValueError("a short lowercase pack id is required")
    manifest_path = (recipe_path.parent / recipe["sources"]).resolve(strict=True)
    manifest_data = manifest_path.read_bytes()
    if digest(manifest_data) != recipe.get("sources_sha256"):
        raise ValueError("source manifest pin changed or is missing")
    sources = json.loads(manifest_data)
    if sources.get("schema") != "protector-native.texture-restoration-sources/v2" or \
            sources.get("includes_auxiliary_planes") is not True or sources.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("plane-qualified sources from the pinned title are required")
    destination = output.resolve()
    if output.is_symlink() or destination.exists():
        raise ValueError("vector output must be new")
    protected = [ROOT, Path(sources["source_data_root"]).resolve(), manifest_path.parent, recipe_path.parent]
    if any(destination.is_relative_to(path) for path in protected) or recipe_path.is_relative_to(ROOT):
        raise ValueError("vectors and generated art must remain outside Git and source directories")
    jobs = recipe.get("jobs")
    if not isinstance(jobs, list) or not 1 <= len(jobs) <= 128:
        raise ValueError("a bounded nonempty vector job list is required")
    planned, seen = [], set()
    for job in jobs:
        name, kind, scale = job.get("name"), job.get("kind"), job.get("scale")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name) or \
                kind not in {"colour-and-mask", "mask-only", "opaque-plane", "straight-alpha"} or type(scale) is not int or not 2 <= scale <= 16:
            raise ValueError("invalid vector job name, kind or integer scale")
        if not isinstance(job.get("authorship"), str) or not job["authorship"].strip():
            raise ValueError("source-bound vector authorship is required")
        colour = job.get("colour_source")
        original = source_picture(manifest_path.parent, sources["textures"], colour,
            allow_alpha=kind == "straight-alpha")
        width, height = original.size
        if max(width, height) * scale > 4096:
            raise ValueError("vector raster exceeds the texture dimension bound")
        mask = job.get("mask_source")
        objects, original_mask = [], None
        if kind == "straight-alpha":
            if mask is not None or original.getchannel("A").getextrema() in {(255, 255), (0, 0)}:
                raise ValueError("straight-alpha vectors require a nonempty transparent source and no auxiliary mask")
            original_mask = original
            objects = sorted({(o["package"], o["resource_offset"]) for o in
                sources["textures"][colour]["occurrences"] if type(o.get("plane")) is int and o["plane"] == 0})
            if not objects:
                raise ValueError("straight-alpha vectors require a primary source plane")
        elif kind != "opaque-plane":
            original_mask = source_picture(manifest_path.parent, sources["textures"], mask)
            if original_mask.size != original.size:
                raise ValueError("paired planes must share dimensions")
            objects = paired_objects(sources["textures"], colour, mask)
            if kind == "mask-only" and original.getcolors(maxcolors=1) is None:
                raise ValueError("mask-only rebuilds require a retained constant colour plane")
        keys = [colour, mask] if kind == "colour-and-mask" else [mask if kind == "mask-only" else colour]
        if any(key in seen for key in keys):
            raise ValueError("multiple vector jobs replace the same source plane")
        seen.update(keys)
        vector_path = (recipe_path.parent / job["svg"]).resolve(strict=True)
        if vector_path.is_relative_to(ROOT) or not vector_path.is_relative_to(recipe_path.parent):
            raise ValueError("vector must remain inside its external recipe directory")
        # A complete glyph atlas has hundreds of glyph contours; its bounded
        # alpha lane permits 2 MiB, while small opaque HUD jobs retain 1 MiB.
        vector = read_vector(vector_path, width, height,
            max_bytes=(4 if kind == "straight-alpha" else 1) * 1024 * 1024)
        if digest(vector) != job.get("svg_sha256"):
            raise ValueError("vector pin changed or is missing")
        planned.append((job, keys, original_mask, objects, vector, vector_path, width, height))
    destination.mkdir(parents=True)
    entries, receipts = [], []
    for job, keys, original_mask, objects, vector, vector_path, width, height in planned:
        png = resvg_py.svg_to_bytes(svg_string=vector.decode("utf-8"), skip_system_fonts=True,
            width=width * job["scale"], height=height * job["scale"])
        rendered = Image.open(BytesIO(png)).convert("RGBA")
        if rendered.size != (width * job["scale"], height * job["scale"]):
            raise ValueError("SVG renderer did not retain the requested canvas dimensions")
        if job["kind"] == "opaque-plane":
            if rendered.getchannel("A").getextrema() != (255, 255):
                raise ValueError("opaque-plane vector must cover its entire source canvas")
            planes = [rendered]
        elif job["kind"] == "straight-alpha":
            colour, _ = split_planes(rendered)
            colour.putalpha(rendered.getchannel("A"))
            planes = [colour]
        else:
            colour, coverage = split_planes(rendered)
            planes = [colour, coverage] if job["kind"] == "colour-and-mask" else [coverage]
        provenance = {"method": "source-coordinate SVG rebuild", "vector": str(vector_path),
            "vector_sha256": digest(vector), "authorship": job["authorship"],
            "rasterizer": f"resvg-py {resvg_py.__version__}; resvg {resvg_py.__resvg_version__}",
            "source_objects": objects, "recipe_sha256": digest(recipe_data),
            "scope": "candidate vector-derived planes; no artistic or runtime acceptance inferred"}
        for key, picture in zip(keys, planes):
            relative = f"{job['name']}-{key.split('-')[1][:12]}.png"
            info = PngImagePlugin.PngInfo()
            info.add_text("protector_origin", json.dumps({**provenance, "source_key": key}, sort_keys=True))
            picture.save(destination / relative, pnginfo=info)
            entries.append({"source": key, "png": relative, "png_sha256": digest((destination / relative).read_bytes()),
                "treatment": "rebuild", "provenance": provenance})
            if job["kind"] == "straight-alpha":
                entries[-1]["alpha_mode"] = "straight"
        receipts.append({"name": job["name"], "kind": job["kind"], "sources": keys,
            "width": width * job["scale"], "height": height * job["scale"],
            "coverage": coverage_metrics(original_mask, rendered,
                "A" if job["kind"] == "straight-alpha" else "G") if original_mask else None,
            "provenance": provenance})
    pack_recipe = {"schema": "protector-native.texture-pack-recipe/v1", "pack_id": pack_id,
        "sources": str(manifest_path), "sources_sha256": digest(manifest_data), "entries": entries}
    if any(e.get("alpha_mode") == "straight" for e in entries):
        pack_recipe["schema"] = "protector-native.texture-pack-recipe/v2"
        for entry in entries:
            entry.setdefault("alpha_mode", "opaque")
    (destination / "pack-recipe.json").write_text(json.dumps(pack_recipe, indent=2, sort_keys=True) + "\n")
    report = {"schema": "protector-native.interface-vector-build/v1", "status": "candidate",
        "recipe": str(recipe_path), "recipe_sha256": digest(recipe_data), "jobs": receipts}
    (destination / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = build(args.recipe, args.output)
    print(json.dumps({"status": report["status"], "jobs": len(report["jobs"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

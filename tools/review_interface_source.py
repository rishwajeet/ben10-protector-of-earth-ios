#!/usr/bin/env python3
"""Render a bounded source-interface audit as hash-checked inspection sheets.

These are unchanged source pixels and diagnostic thumbnails, never replacement
art or semantic HUD admission. Proprietary pixels stay outside the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(r"([1-9][0-9]{0,3})x([1-9][0-9]{0,3})-([0-9a-f]{64})")


def review(audit_path: Path, output: Path) -> dict:
    audit_path = audit_path.resolve(strict=True)
    audit_bytes = audit_path.read_bytes()
    audit = json.loads(audit_bytes)
    if audit.get("schema") != "protector-native.interface-source-audit/v1":
        raise ValueError("an interface-source audit is required")
    destination = output.resolve()
    if output.is_symlink() or destination.exists() or destination.is_relative_to(ROOT):
        raise ValueError("use a new external output directory")
    draws = audit.get("draws")
    if not isinstance(draws, list) or len(draws) > 256:
        raise ValueError("audit draw list is missing or exceeds its bound")
    textures: dict[str, dict] = {}
    total = 0
    for draw in draws:
        stages = draw.get("textures")
        if not isinstance(stages, list) or len(stages) > 8:
            raise ValueError("audit texture stages are invalid")
        for stage in stages:
            key = stage.get("source_key")
            if not stage.get("pixels_included"):
                continue
            match = KEY.fullmatch(key) if isinstance(key, str) else None
            if not match:
                raise ValueError("invalid interface texture identity")
            width, height = int(match[1]), int(match[2])
            if width > 2048 or height > 2048 or (width, height) != (stage.get("width"), stage.get("height")):
                raise ValueError("texture dimensions do not match their identity")
            if key not in textures:
                path = audit_path.parent / f"{key}.rgba"
                if path.is_symlink() or path.stat().st_size != width * height * 4:
                    raise ValueError("texture source is a link or has the wrong byte length")
                pixels = path.read_bytes()
                if hashlib.sha256(pixels).hexdigest() != match[3]:
                    raise ValueError("texture pixel hash changed")
                total += len(pixels)
                if total > 64 * 1024 * 1024:
                    raise ValueError("audit exceeds its pixel bound")
                textures[key] = {"width": width, "height": height, "pixels": pixels,
                                 "draw_indices": set(), "roles": set(), "gx_formats": set()}
            entry = textures[key]
            entry["draw_indices"].add(draw["draw_index"])
            entry["roles"].add(draw["role"])
            entry["gx_formats"].add(stage["gx_format"])
    if len(textures) != audit.get("texture_count") or total != audit.get("texture_bytes"):
        raise ValueError("texture report totals do not match the included stages")
    if not textures:
        raise ValueError("audit has no included texture pixels")
    # All input validation precedes output creation.
    destination.mkdir(parents=True)
    (destination / "originals").mkdir()
    entries = []
    ordered = sorted(textures.items())
    for start in range(0, len(ordered), 30):
        group = ordered[start:start + 30]
        page = f"page-{start // 30 + 1:03}.png"
        sheet = Image.new("RGB", (1200, ((len(group) + 4) // 5) * 250), "#202126")
        pen = ImageDraw.Draw(sheet)
        for offset, (key, texture) in enumerate(group):
            number = start + offset
            picture = Image.frombytes("RGBA", (texture["width"], texture["height"]), texture["pixels"])
            original = f"originals/{key}.png"
            picture.save(destination / original)
            factor = min(224 / picture.width, 184 / picture.height)
            thumbnail = picture.resize((max(1, round(picture.width * factor)),
                                        max(1, round(picture.height * factor))), Image.Resampling.NEAREST)
            x, y = offset % 5 * 240, offset // 5 * 250
            for cy in range(y + 4, y + 188, 12):
                for cx in range(x + 4, x + 228, 12):
                    shade = "#888888" if ((cx - x) // 12 + (cy - y) // 12) % 2 else "#cccccc"
                    pen.rectangle((cx, cy, min(cx + 11, x + 227), min(cy + 11, y + 187)), fill=shade)
            sheet.paste(thumbnail, (x + 4, y + 4), thumbnail)
            indices = sorted(texture["draw_indices"])
            pen.text((x + 4, y + 194), f"{number}: {texture['width']}x{texture['height']} {key.split('-')[1][:12]}", fill="white")
            pen.text((x + 4, y + 209), "draws " + ", ".join(map(str, indices[:8])), fill="white")
            pen.text((x + 4, y + 224), ", ".join(sorted(texture["roles"])), fill="white")
            entries.append({"index": number, "source_key": key, "page": page, "source_png": original,
                "draw_indices": indices, "roles": sorted(texture["roles"]),
                "gx_formats": sorted(texture["gx_formats"]), "semantic_role": "unreviewed"})
        sheet.save(destination / page)
    receipt = {"schema": "protector-native.interface-source-review/v1", "audit": str(audit_path),
        "audit_sha256": hashlib.sha256(audit_bytes).hexdigest(), "frame_index": audit.get("frame_index"),
        "entries": entries, "display": "nearest-neighbor source thumbnails over checkerboard; not restoration"}
    with (destination / "index.json").open("x") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    receipt = review(args.audit, args.output)
    print(json.dumps({"frame": receipt["frame_index"], "textures": len(receipt["entries"]), "output": str(args.output)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Package explicitly selected restoration candidates without modifying pixels.

Run with `uv run --with pillow tools/build_texture_pack.py RECIPE OUTPUT`.
The recipe points to prepare_texture_restoration sources and candidate PNGs.
The runtime receives straight RGBA bytes, not a platform-dependent PNG decode.
This packages candidates; it never declares them artistically approved.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.prepare_texture_restoration import DOL_SHA256


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_png(path: Path) -> tuple[int, int, bytes]:
    from PIL import Image
    with Image.open(path) as image:
        if image.format != "PNG" or getattr(image, "n_frames", 1) != 1:
            raise ValueError("a single-frame PNG is required")
        if not (1 <= image.width <= 4096 and 1 <= image.height <= 4096):
            raise ValueError("texture dimensions must be between 1 and 4096")
        if image.getexif().get(274, 1) != 1:
            raise ValueError("texture orientation must already be top-left")
        return image.width, image.height, image.convert("RGBA").tobytes()


def build(recipe_path: Path, output: Path) -> dict:
    recipe_path = recipe_path.resolve(strict=True)
    recipe = json.loads(recipe_path.read_text())
    explicit_alpha = recipe.get("schema") == "protector-native.texture-pack-recipe/v2"
    if recipe.get("schema") not in {"protector-native.texture-pack-recipe/v1",
            "protector-native.texture-pack-recipe/v2"}:
        raise ValueError("unsupported texture recipe")
    pack_id = recipe.get("pack_id")
    if not isinstance(pack_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", pack_id):
        raise ValueError("pack_id must be a short lowercase identifier")
    manifest_path = (recipe_path.parent / recipe["sources"]).resolve(strict=True)
    if "sources_sha256" in recipe and digest(manifest_path.read_bytes()) != recipe["sources_sha256"]:
        raise ValueError("source manifest changed after candidate production")
    sources = json.loads(manifest_path.read_text())
    plane_qualified = sources.get("schema") == "protector-native.texture-restoration-sources/v2"
    if sources.get("schema") not in {"protector-native.texture-restoration-sources/v1",
            "protector-native.texture-restoration-sources/v2"} or \
            sources.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("candidate sources do not match the pinned title")
    if plane_qualified and sources.get("includes_auxiliary_planes") is not True:
        raise ValueError("v2 sources must explicitly identify their auxiliary planes")
    destination = output.resolve()
    source_data = Path(sources["source_data_root"]).resolve()
    if destination.is_relative_to(ROOT) or destination.is_relative_to(source_data) or \
            destination.is_relative_to(manifest_path.parent):
        raise ValueError("pack output must be outside Git, the dump and source artwork")
    if output.is_symlink() or destination.exists():
        raise ValueError("pack output must be new")
    entries = recipe.get("entries",[])
    if not isinstance(entries,list):
        raise ValueError("a bounded candidate list is required")
    entries = list(entries)
    includes = recipe.get("include_recipes",[])
    if not isinstance(includes,list) or len(includes) > 64:
        raise ValueError("included recipes must be a bounded list")
    for include in includes:
        included_path = (recipe_path.parent/include["path"]).resolve(strict=True)
        included_hash = digest(included_path.read_bytes())
        if included_hash != include.get("sha256"):
            raise ValueError("included recipe hash changed or is missing")
        included = json.loads(included_path.read_text())
        if (included.get("schema") != recipe["schema"] or
                included.get("include_recipes") or
                (included_path.parent/included["sources"]).resolve(strict=True) != manifest_path or
                included.get("sources_sha256") != digest(manifest_path.read_bytes()) or
                not isinstance(included.get("entries"),list)):
            raise ValueError("included recipes must be flat and share the pinned sources")
        excluded = include.get("exclude_sources", [])
        included_keys = [candidate["source"] for candidate in included["entries"]]
        if (not isinstance(excluded, list) or
                any(not isinstance(key, str) for key in excluded) or
                len(set(excluded)) != len(excluded) or
                len(set(included_keys)) != len(included_keys) or
                not set(excluded).issubset(included_keys)):
            raise ValueError("excluded sources must uniquely identify included candidates")
        excluded = set(excluded)
        for candidate in included["entries"]:
            if not candidate.get("png_sha256"):
                raise ValueError("included candidates require pinned PNG hashes")
            if candidate["source"] in excluded:
                continue
            entries.append({**candidate,"png":str((included_path.parent/candidate["png"]).resolve(strict=True)),
                "provenance":{**candidate.get("provenance",{}),"included_recipe_sha256":included_hash}})
            if len(entries) > 16384:
                raise ValueError("combined candidate list exceeds its bound")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 16384:
        raise ValueError("a nonempty bounded candidate list is required")
    seen = set()
    planned = []
    for candidate in entries:
        key = candidate["source"]
        if key in seen or key not in sources["textures"]:
            raise ValueError("duplicate or unknown source texture")
        seen.add(key)
        source = sources["textures"][key]
        if key != f"{source['width']}x{source['height']}-{source['rgba8_sha256']}":
            raise ValueError("source key does not match its pixel identity")
        if plane_qualified:
            occurrences = source.get("occurrences")
            if not isinstance(occurrences, list) or not 1 <= len(occurrences) <= 65536:
                raise ValueError("v2 sources require a bounded plane-qualified occurrence list")
            identities = set()
            for occurrence in occurrences:
                if (not isinstance(occurrence, dict) or type(occurrence.get("plane")) is not int or
                        occurrence["plane"] not in {0, 1} or
                        not isinstance(occurrence.get("package"), str) or
                        Path(occurrence["package"]).name != occurrence["package"] or
                        Path(occurrence["package"]).suffix not in {".gcm", ".gcs"} or
                        not isinstance(occurrence.get("resource_offset"), str) or
                        not re.fullmatch(r"0x[0-9a-f]{8}", occurrence["resource_offset"]) or
                        not isinstance(occurrence.get("level_table_offset"), str) or
                        not re.fullmatch(r"0x[0-9a-f]{8}", occurrence["level_table_offset"])):
                    raise ValueError("invalid plane-qualified source occurrence")
                identity = (occurrence["package"], occurrence["resource_offset"], occurrence["plane"])
                if identity in identities:
                    raise ValueError("duplicate plane-qualified source occurrence")
                identities.add(identity)
        original_path = (manifest_path.parent / source["png"]).resolve(strict=True)
        if not original_path.is_relative_to(manifest_path.parent):
            raise ValueError("source artwork path escapes its manifest")
        if digest(original_path.read_bytes()) != source["png_sha256"]:
            raise ValueError("source PNG changed after extraction")
        sw, sh, original = read_png(original_path)
        if (sw, sh, digest(original)) != (source["width"], source["height"], source["rgba8_sha256"]):
            raise ValueError("source pixel identity does not match the manifest")
        path = (recipe_path.parent / candidate["png"]).resolve(strict=True)
        if "png_sha256" in candidate and digest(path.read_bytes()) != candidate["png_sha256"]:
            raise ValueError("candidate PNG changed after production")
        width, height, rgba = read_png(path)
        if width * sh != height * sw or width < sw or height < sh:
            raise ValueError("candidate must retain aspect and not reduce source resolution")
        # v1 remains opaque. v2 explicitly opts each entry into opaque or
        # straight-alpha raw delivery; no ASTC opacity contract is relaxed.
        alpha_mode = candidate.get("alpha_mode") if explicit_alpha else "opaque"
        if alpha_mode not in {"opaque", "straight"}:
            raise ValueError("explicit alpha recipes require opaque or straight per entry")
        if alpha_mode == "opaque" and (any(a != 255 for a in original[3::4]) or
                any(a != 255 for a in rgba[3::4])):
            raise ValueError("this pack version admits opaque artwork only")
        treatment = candidate.get("treatment")
        provenance = candidate.get("provenance")
        if treatment not in {"restore", "replace", "rebuild"} or \
                not isinstance(provenance, dict) or not provenance.get("method"):
            raise ValueError("candidate treatment and production provenance are required")
        rgba_hash = digest(rgba)
        entry = {"source": {"width": sw, "height": sh,
            "rgba8_sha256": source["rgba8_sha256"]}, "replacement": {
                "path": f"textures/{rgba_hash}.rgba", "width": width, "height": height,
                "byte_length": len(rgba), "sha256": rgba_hash,
                "source_png_sha256": digest(path.read_bytes())},
            "treatment": treatment, "provenance": provenance,
            "source_occurrences": source["occurrences"]}
        if explicit_alpha:
            entry["replacement"].update({"format": "rgba8-unorm", "alpha_mode": alpha_mode})
            if alpha_mode == "straight":
                entry["replacement"]["mip_filter"] = "alpha-weighted-box-unorm-v1"
        planned.append((entry, path))
    # A whole library of 4K RGBA payloads can exceed RAM. Validate everything
    # first, retain only metadata/paths, then decode and revalidate one at a time.
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "textures").mkdir()
    written = set()
    for entry, path in planned:
        replacement = entry["replacement"]
        if digest(path.read_bytes()) != replacement["source_png_sha256"]:
            raise ValueError("candidate PNG changed between validation and packaging")
        width, height, rgba = read_png(path)
        if (width, height, len(rgba), digest(rgba)) != (replacement["width"],
                replacement["height"], replacement["byte_length"], replacement["sha256"]):
            raise ValueError("candidate pixels changed between validation and packaging")
        relative = entry["replacement"]["path"]
        if relative not in written:
            with (destination / relative).open("xb") as stream:
                stream.write(rgba)
            written.add(relative)
    report = {"schema": "protector-native.texture-pack/v4" if explicit_alpha else
            "protector-native.texture-pack/v1", "pack_id": pack_id,
        "title_dol_sha256": DOL_SHA256, "status": "candidate",
        "scope": "opaque artwork candidates; in-engine acceptance is separate",
        "sources_sha256": digest(manifest_path.read_bytes()),
        "recipe_sha256": digest(recipe_path.read_bytes()),
        "entries": [entry for entry, _ in planned]}
    if explicit_alpha:
        report["scope"] = "explicit opaque/straight-alpha raw candidates; in-engine acceptance is separate"
    with (destination / "pack.json").open("x") as stream:
        stream.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = build(args.recipe, args.output)
    print(json.dumps({"pack_id": report["pack_id"], "status": report["status"],
        "entries": len(report["entries"]), "dimensions": [
            [entry["replacement"]["width"], entry["replacement"]["height"]]
            for entry in report["entries"]]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

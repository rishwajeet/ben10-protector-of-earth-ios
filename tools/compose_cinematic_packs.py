#!/usr/bin/env python3
"""Combine pinned local cinematic masters without re-encoding or acceptance.

Every source entry and its provenance are retained unchanged. File-identity
checks do not replace each master recipe's frame/codec and visual review.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.assemble_interface_grid import no_links
from tools.prepare_texture_restoration import DOL_SHA256
from protector_native.cinematic_framing import master_dimensions


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def pinned_json(path: Path, expected: str | None = None) -> tuple[Path, str, dict]:
    path = no_links(path).resolve(strict=True)
    if not path.is_file() or path.stat().st_size > 2*1024*1024:
        raise ValueError("bounded regular metadata required")
    digest = sha(path)
    if expected is not None and (not valid_hash(expected) or digest != expected):
        raise ValueError("pinned manifest changed")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("metadata object required")
    return path, digest, value


def validate_entry(entry: dict, schema: str = "protector-native.cinematic-pack/v1") -> None:
    if not isinstance(entry, dict):
        raise ValueError("cinematic entry object required")
    for key, extension in (("movie", "bik"), ("video", "mp4")):
        name = entry.get(key)
        if not isinstance(name, str) or not 5 <= len(name) <= 95 or \
                re.fullmatch(r"[A-Za-z0-9_]+\."+extension, name) is None:
            raise ValueError("unique direct movie and video names required")
    ranges = {"source_width": (32,7680), "source_height": (32,4800),
        "frame_count": (1,1000000), "rate_numerator": (1,2147483647),
        "rate_denominator": (1,10000000),
        "video_bytes": (1,2*1024*1024*1024)}
    if any(not integer(entry.get(key), *limits) for key,limits in ranges.items()) or \
            not 1 <= entry["rate_numerator"]/entry["rate_denominator"] <= 120 or \
            any(not valid_hash(entry.get(key)) for key in ("source_sha256", "video_sha256")) or \
            not isinstance(entry.get("provenance"), dict) or not entry["provenance"]:
        raise ValueError("source, dimensions, timing, identity or provenance differs")
    if schema not in ("protector-native.cinematic-pack/v1", "protector-native.cinematic-pack/v2"):
        raise ValueError("unsupported cinematic pack schema")
    master_dimensions([entry.get("width"), entry.get("height")], full_picture=schema.endswith("/v2"))


def compose(recipe: Path, output: Path) -> dict:
    recipe, recipe_hash, config = pinned_json(recipe)
    if config.get("schema") != "protector-native.cinematic-composition/v1" or \
            not isinstance(config.get("pack_id"), str) or \
            re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", config["pack_id"]) is None or \
            not isinstance(config.get("packs"), list) or not 1 <= len(config["packs"]) <= 76:
        raise ValueError("bounded explicit cinematic composition recipe required")
    destination = no_links(output).resolve()
    if destination.exists() or destination.is_relative_to(ROOT):
        raise ValueError("new external output outside Git required")
    entries, payloads, origins = [], [], []
    full_picture = False
    movies, videos = set(), set()
    for reference in config["packs"]:
        if not isinstance(reference, dict) or not isinstance(reference.get("path"), str) or \
                not valid_hash(reference.get("sha256")):
            raise ValueError("each source manifest needs an explicit hash")
        path, digest, pack = pinned_json(recipe.parent/reference["path"], reference["sha256"])
        if destination.is_relative_to(path.parent):
            raise ValueError("output must be outside input packs")
        if pack.get("schema") not in ("protector-native.cinematic-pack/v1", "protector-native.cinematic-pack/v2") or \
                pack.get("title_dol_sha256") != DOL_SHA256 or \
                not isinstance(pack.get("pack_id"), str) or not pack["pack_id"] or \
                not isinstance(pack.get("entries"), list) or not 1 <= len(pack["entries"]) <= 76 or \
                not isinstance(pack.get("acceptance"), str) or not pack["acceptance"]:
            raise ValueError("source-bound cinematic manifest and acceptance boundary required")
        full_picture = full_picture or pack["schema"].endswith("/v2")
        for entry in pack["entries"]:
            validate_entry(entry, pack["schema"])
            # macOS/iOS may use case-insensitive file systems. Reject aliases.
            if entry["movie"].casefold() in movies or entry["video"].casefold() in videos:
                raise ValueError("duplicate movie or media across input packs")
            movies.add(entry["movie"].casefold())
            videos.add(entry["video"].casefold())
            video = no_links(path.parent/entry["video"])
            if not video.is_file() or video.stat().st_size != entry["video_bytes"] or sha(video) != entry["video_sha256"]:
                raise ValueError("master payload changed")
            payloads.append((video, entry))
            entries.append(entry)
        if len(entries) > 76:
            raise ValueError("combined movie count exceeds 76")
        origins.append({"manifest": str(path), "sha256": digest, "pack_id": pack["pack_id"],
                        "entries": len(pack["entries"]), "acceptance": pack["acceptance"]})
    destination.mkdir(parents=True)
    for path, entry in payloads:
        copied = destination/entry["video"]
        try:  # Masters are never modified after restoration; avoid a second UHD copy.
            os.link(path, copied)
        except OSError:
            shutil.copyfile(path, copied)
        if copied.stat().st_size != entry["video_bytes"] or sha(copied) != entry["video_sha256"]:
            raise ValueError("master changed during copy")
    if sha(recipe) != recipe_hash or any(sha(Path(origin["manifest"])) != origin["sha256"] for origin in origins):
        raise ValueError("input metadata changed during composition")
    result = {"schema": "protector-native.cinematic-pack/"+("v2" if full_picture else "v1"), "title_dol_sha256": DOL_SHA256,
              "pack_id": config["pack_id"], "entries": entries,
              "acceptance": "composed candidates; native and motion review remain per movie",
              "composition_recipe": str(recipe), "composition_recipe_sha256": recipe_hash,
              "composed_from": origins}
    (destination/"cinematics.json").write_text(json.dumps(result, indent=2)+"\n")
    receipt = {"schema": "protector-native.cinematic-composition-receipt/v1", "status": "pass",
        "manifest_sha256": sha(destination/"cinematics.json"), "movie_count": len(entries),
        "source_frames": sum(entry["frame_count"] for entry in entries),
        "composed_from": origins, "scope": "byte-identical media copies and unchanged entries; not new encode, quality or playback acceptance"}
    (destination/"composition-receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compose(args.recipe, args.output)
    print(json.dumps({"pack_id": result["pack_id"], "movies": len(result["entries"]),
                      "acceptance": result["acceptance"]}))

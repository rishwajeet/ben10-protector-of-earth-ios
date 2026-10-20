#!/usr/bin/env python3
"""Fingerprint and probe every inventoried source cinematic, optionally sample.

The output records exact original frame rates/counts and decoder cross-checks.
Unmodified source frames are review evidence, never restored/high-resolution
artwork or proof of a safe widescreen crop. All output stays outside the repo.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from protector_native.cinematics import bink_header, review_frame_indices, verify_probe
from tools.assemble_interface_grid import no_links
from tools.prepare_texture_restoration import DOL_SHA256


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_inventory(inventory: Path, output: Path, samples: bool = False) -> dict:
    inventory = no_links(inventory).resolve(strict=True)
    original_hash = sha(inventory)
    inputs = json.loads(inventory.read_text())
    if inputs.get("schema") != "protector-native.v1-asset-inventory/v1" or inputs.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("source-bound V1 asset inventory required")
    manifest = no_links(Path(inputs["source_manifest"])).resolve(strict=True)
    if sha(manifest) != inputs["source_manifest_sha256"]:
        raise ValueError("source manifest changed")
    source = no_links(Path(json.loads(manifest.read_text())["source_data_root"])).resolve(strict=True)
    if sha(source/"sys/main.dol") != DOL_SHA256:
        raise ValueError("source executable changed")
    destination = no_links(output)
    if destination.exists() or any(destination.is_relative_to(parent) for parent in (ROOT, source, inventory.parent, manifest.parent)):
        raise ValueError("use a new external output outside source data and inventories")
    movies = inputs.get("movies", [])
    names = [m.get("path") for m in movies]
    if not names or any(not isinstance(n, str) or Path(n).parts[:2] != ("files", "Movies") or
            len(Path(n).parts) != 3 or Path(n).suffix != ".bik" for n in names) or len(set(names)) != len(names):
        raise ValueError("movie paths must be unique direct source Movies/*.bik entries")
    actual = {str(p.relative_to(source)) for p in (source/"files/Movies").glob("*.bik")}
    if actual != set(names):
        raise ValueError("movie list differs from the source inventory")
    # Validate the entire inventory before producing any review material.
    for movie in movies:
        path = no_links(source/movie["path"])
        if path.stat().st_size != movie["bytes"] or sha(path) != movie["sha256"]:
            raise ValueError(f"source movie changed: {path.name}")
    destination.mkdir(parents=True)
    versions = {tool: subprocess.check_output([tool, "-version"], text=True).splitlines()[0]
                for tool in ("ffprobe", "ffmpeg")}
    result = {"schema": "protector-native.cinematic-source-inventory/v1", "title_dol_sha256": DOL_SHA256,
        "source_inventory": str(inventory), "source_inventory_sha256": original_hash,
        "source_root": str(source), "tools": versions, "movies": [],
        "scope": "source identities, exact timing and optional sampled original frames; not restoration or crop acceptance"}
    for i, movie in enumerate(movies):
        path = source/movie["path"]
        with path.open("rb") as stream:
            header = bink_header(stream.read(44), path.stat().st_size)
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
            "stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,duration_ts,duration,sample_aspect_ratio,display_aspect_ratio,sample_rate,channels",
            "-of", "json", str(path)], text=True))
        audio = verify_probe(header, probe)
        row = {**movie, **header, "decoder_crosscheck": "pass", "audio_streams": audio,
            "probe": probe, "sampled_frames": [], "framing_review": "pending", "restoration_status": "unmodified"}
        if samples:
            indices = review_frame_indices(header["frame_count"])
            directory = destination/path.stem
            directory.mkdir()
            select = "+".join(f"eq(n\\,{n})" for n in indices)
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                "-threads", "2", "-i", str(path), "-map", "0:v:0", "-an", "-vf", f"select={select}",
                "-fps_mode", "passthrough", "-frames:v", str(len(indices)), "-threads", "2",
                str(directory/"source-%02d.png")], check=True)
            for ordinal, frame in enumerate(indices, 1):
                picture = directory/f"source-{ordinal:02d}.png"
                row["sampled_frames"].append({"frame_zero_based": frame,
                    "seconds": frame*header["frame_rate_denominator"]/header["frame_rate_numerator"],
                    "png": str(picture.relative_to(destination)), "png_sha256": sha(picture),
                    "origin": "unmodified FFmpeg decoded source frame; no crop, scale, denoise or sharpening"})
        if sha(path) != movie["sha256"]:
            raise ValueError("movie changed during inspection")
        result["movies"].append(row)
        print(f"{i+1}/{len(movies)} {path.name}: {header['width']}x{header['height']} {header['frame_count']} frames @ {header['frame_rate']}", flush=True)
    if sha(inventory) != original_hash:
        raise ValueError("inventory changed during inspection")
    result["summary"] = {"movie_files": len(movies), "source_frames": sum(m["frame_count"] for m in result["movies"]),
        "duration_seconds": sum(m["duration_seconds"] for m in result["movies"]),
        "dimension_groups": dict(Counter(f"{m['width']}x{m['height']}" for m in result["movies"])),
        "frame_rate_groups": dict(Counter(m["frame_rate"] for m in result["movies"])),
        "sampled_original_frames": sum(len(m["sampled_frames"]) for m in result["movies"])}
    (destination/"inventory.json").write_text(json.dumps(result, indent=2)+"\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--samples", action="store_true")
    args = parser.parse_args()
    result = inspect_inventory(args.inventory, args.output, args.samples)
    print(json.dumps(result["summary"], indent=2))

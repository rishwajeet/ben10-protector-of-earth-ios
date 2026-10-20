#!/usr/bin/env python3
"""Make resumable local HEVC delivery candidates, without touching UHD masters.

Resolution and every source presentation timestamp are preserved. This does not
restore originals, replace audio, or establish visual-quality acceptance.
"""
from __future__ import annotations
import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file


def validate_video(path: Path, entry: dict) -> dict:
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-count_frames",
        "-show_streams", "-show_packets", "-of", "json", str(path)], text=True))
    streams = probe.get("streams", [])
    if len(streams) != 1:
        raise ValueError("Delivery must have exactly one video track and no audio")
    stream = streams[0]
    count, num, den = (entry[key] for key in ("frame_count", "rate_numerator", "rate_denominator"))
    required = {"codec_name": "hevc", "codec_tag_string": "hvc1", "codec_type": "video",
        "width": entry["width"], "height": entry["height"], "nb_read_frames": str(count),
        "time_base": f"1/{num}", "duration_ts": count * den, "sample_aspect_ratio": "1:1",
        "pix_fmt": "yuv420p", "color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709"}
    for key, expected in required.items():
        if stream.get(key) != expected:
            raise ValueError(f"Delivery {path.name}: {key} differs ({stream.get(key)!r} != {expected!r})")
    packets = probe.get("packets", [])
    if len(packets) != count or sorted(p["pts"] for p in packets) != [n * den for n in range(count)] or any(p.get("duration") != den for p in packets):
        raise ValueError("Delivery frames are missing, duplicated or retimed")
    return {"frames": count, "dimensions": [entry["width"], entry["height"]],
            "one_to_one_pts": True, "full_decode": True, "audio_tracks": 0}


def encode(manifest: Path, output: Path, bitrate: int, movies: list[str] | None):
    manifest = manifest.resolve(strict=True)
    output = output.resolve()
    if output.is_relative_to(ROOT) or output.is_relative_to(manifest.parent):
        raise ValueError("Use a new external delivery directory outside source masters")
    if not 4 <= bitrate <= 50:
        raise ValueError("Bitrate must be 4–50 Mb/s")
    original = json.loads(manifest.read_text())
    entries = original["entries"]
    if movies:
        wanted = set(movies)
        entries = [entry for entry in entries if entry["movie"] in wanted]
        if {entry["movie"] for entry in entries} != wanted:
            raise ValueError("Requested movie is not in the source manifest")
    owner = {"schema": "protector-native.cinematic-delivery/v1", "source_manifest_sha256": digest_file(manifest),
             "bitrate_mbps": bitrate, "movies": [entry["movie"] for entry in entries]}
    if output.exists():
        if json.loads((output / "delivery-plan.json").read_text()) != owner:
            raise ValueError("Existing delivery directory belongs to another plan")
    else:
        output.mkdir(parents=True, mode=0o700)
        (output / "delivery-plan.json").write_text(json.dumps(owner, indent=2) + "\n")
    estimated = sum(entry["frame_count"] * entry["rate_denominator"] / entry["rate_numerator"] for entry in entries) * bitrate * 125000
    existing = sum(p.stat().st_size for p in output.glob("*.mp4"))
    if shutil.disk_usage(output).free < max(0, estimated - existing) + 2 * 1024**3:
        raise ValueError("Insufficient delivery workspace headroom")
    completed = []
    for index, entry in enumerate(entries):
        if Path(entry["video"]).name != entry["video"]:
            raise ValueError("Only direct movie filenames are supported")
        source = manifest.parent / entry["video"]
        if source.is_symlink() or digest_file(source) != entry["video_sha256"]:
            raise ValueError("Source master identity changed")
        target = output / entry["video"]
        receipt_path = output / (entry["video"] + ".receipt.json")
        print(f"[{index + 1}/{len(entries)}] {entry['movie']}", flush=True)
        if receipt_path.exists():
            receipt = json.loads(receipt_path.read_text())
            if receipt["source_sha256"] != entry["video_sha256"] or digest_file(target) != receipt["sha256"]:
                raise ValueError("Completed delivery file changed")
        else:
            if target.exists():
                raise ValueError(f"Unreceipted output exists: {target}; inspect before retry")
            partial = output / (entry["video"] + ".partial.mp4")
            started = time.monotonic()
            command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                "-hwaccel", "videotoolbox", "-i", str(source), "-map", "0:v:0", "-an",
                "-vf", "format=yuv420p,setsar=1", "-fps_mode", "passthrough",
                "-c:v", "hevc_videotoolbox", "-allow_sw", "0", "-realtime", "0",
                "-b:v", f"{bitrate}M", "-g", "30", "-tag:v", "hvc1",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-color_range", "tv", "-video_track_timescale", str(entry["rate_numerator"]),
                "-movflags", "+faststart+write_colr", str(partial)]
            subprocess.run(command, check=True)
            remux = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", str(partial),
                "-map", "0:v:0", "-an", "-c:v", "copy", "-tag:v", "hvc1",
                "-bsf:v", "hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
                "-video_track_timescale", str(entry["rate_numerator"]), "-movflags", "+faststart+write_colr", str(target)]
            subprocess.run(remux, check=True)
            validation = validate_video(target, entry)
            receipt = {"source_sha256": entry["video_sha256"], "sha256": digest_file(target),
                "bytes": target.stat().st_size, "seconds": time.monotonic() - started,
                "validation": validation, "command": command, "remux": remux,
                "quality": "delivery candidate; needs representative visual review"}
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            partial.unlink() # only this encoder's duplicate temporary, after verified final
        row = copy.deepcopy(entry)
        row.update(video_sha256=receipt["sha256"], video_bytes=receipt["bytes"])
        row["provenance"]["delivery"] = {"master_sha256": entry["video_sha256"], "target_mbps": bitrate,
            "validation": receipt["validation"], "quality": receipt["quality"]}
        completed.append(row)
    pack = copy.deepcopy(original)
    pack["entries"] = completed
    pack["pack_id"] = f"cinematic-delivery-{bitrate}m-v1"
    pack["acceptance"] = "frame/timing verified delivery candidate; visual acceptance is separate"
    (output / "cinematics.json").write_text(json.dumps(pack, indent=2) + "\n")
    return {"movies": len(completed), "video_bytes": sum(e["video_bytes"] for e in completed), "output": str(output)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mbps", type=int, default=12)
    parser.add_argument("--movie", action="append")
    args = parser.parse_args()
    try:
        print(json.dumps(encode(args.manifest, args.output, args.mbps, args.movie), indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(2, f"Delivery encode: {exc}\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Restore a complete local movie to a silent UHD master at exact source timing.

Framing is explicit per shot. No generated frames, audio replacement, automatic
crop, or temporal blend. Source files remain unchanged and outside Git. The
output is a candidate until visual/motion review and actual native playback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

import numpy as np
from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from protector_native.cinematic_framing import master_dimensions, scan_filters, validate_shots, fitted_size, verify_extension_edges
from protector_native.cinematics import bink_header, review_frame_indices
from tools.assemble_interface_grid import no_links, report
from tools.inventory_cinematics import sha
from tools.prepare_texture_restoration import DOL_SHA256
from tools.restore_interface_grid import CanvasModel
from tools.restore_texture_batch import checked_pixels, identifier, padded_source, pinned_file


def plan(recipe: Path, output: Path, *, finalize: bool = False) -> tuple[dict, dict]:
    recipe, recipe_bytes, config = report(recipe)
    if config.get("schema") not in ("protector-native.cinematic-restoration/v1",
                                    "protector-native.cinematic-restoration/v2"):
        raise ValueError("explicit cinematic restoration recipe required")
    identifier(config.get("pack_id"))
    inventory_path = pinned_file(recipe.parent, config, "inventory", "inventory_sha256")
    inventory = json.loads(inventory_path.read_text())
    if inventory.get("schema") != "protector-native.cinematic-source-inventory/v1" or \
            inventory.get("title_dol_sha256") != DOL_SHA256:
        raise ValueError("original-title source movie inventory required")
    rows = [m for m in inventory["movies"] if m["path"] == "files/Movies/"+str(config.get("movie"))]
    if len(rows) != 1:
        raise ValueError("movie must resolve to exactly one inventoried source")
    row = rows[0]
    root = no_links(Path(inventory["source_root"])).resolve(strict=True)
    movie = no_links(root/row["path"]).resolve(strict=True)
    if not movie.is_relative_to(root) or sha(root/"sys/main.dol") != DOL_SHA256 or \
            sha(movie) != row["sha256"] or movie.stat().st_size != row["bytes"]:
        raise ValueError("original executable or movie changed")
    with movie.open("rb") as source:
        header = bink_header(source.read(44), movie.stat().st_size)
    if any(header[k] != row[k] for k in header):
        raise ValueError("source header and timing inventory disagree")
    full_picture = config["schema"].endswith("/v2")
    target = master_dimensions(config.get("output_dimensions"), full_picture=full_picture)
    scan_filters(config, row["frame_count"])
    validate_shots(config.get("shots"), row["width"], row["height"], row["frame_count"],
                   target=target, full_picture=full_picture)
    if target == (2880, 2160) and any(s["mode"] != "preserve" for s in config["shots"]):
        raise ValueError("4:3 masters must preserve the complete source, without crop or baked matte")
    model = config.get("model", {})
    if not all(isinstance(model.get(k), str) and model[k] for k in ("name", "source_url", "license")):
        raise ValueError("model identity, source and license are required")
    weights = pinned_file(recipe.parent, model, "weights", "sha256")
    destination = no_links(output).resolve()
    if (destination.exists() and not finalize) or (finalize and not destination.is_dir()) or \
            any(destination.is_relative_to(p) for p in (ROOT, root, inventory_path.parent)):
        raise ValueError("use a new external output outside source data, inventory and repository")
    return config, {"recipe": str(recipe), "recipe_sha256": hashlib.sha256(recipe_bytes).hexdigest(),
        "inventory": str(inventory_path), "inventory_sha256": config["inventory_sha256"],
        "source_path": str(movie), "source": row, "weights": str(weights)}


def verify_master(path: Path, source: dict, dimensions=(3840, 2160)) -> dict:
    width, height = master_dimensions(dimensions, full_picture=True)
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-count_frames",
        "-show_streams", "-show_packets", "-of", "json", str(path)], text=True))
    streams = probe.get("streams", [])
    if len(streams) != 1 or streams[0].get("codec_type") != "video":
        raise ValueError("restored movies must have only one video track; original audio owns playback")
    stream = streams[0]
    count, numerator, denominator = (source[k] for k in ("frame_count", "frame_rate_numerator", "frame_rate_denominator"))
    if (stream.get("codec_name"), stream.get("codec_tag_string"), stream.get("width"), stream.get("height"),
            stream.get("nb_read_frames"), stream.get("time_base"), stream.get("duration_ts")) != \
            ("hevc", "hvc1", width, height, str(count), f"1/{numerator}", count*denominator):
        raise ValueError("encoded master has incorrect codec, dimensions, frame count or rational timing")
    packets = probe.get("packets", [])
    if len(packets) != count or sorted(p.get("pts") for p in packets) != [n*denominator for n in range(count)] or \
            any(p.get("duration") != denominator for p in packets):
        raise ValueError("encoded master has missing, duplicated or retimed presentation frames")
    if stream.get("sample_aspect_ratio") != "1:1" or stream.get("pix_fmt") != "yuv420p" or \
            any(stream.get(k) != "bt709" for k in ("color_space", "color_transfer", "color_primaries")):
        raise ValueError("encoded master has unexpected aspect, pixel format or color tags")
    return {"frame_count": count, "dimensions": [width,height], "rate_numerator": numerator,
        "rate_denominator": denominator, "time_base": stream["time_base"], "duration_ticks": count*denominator,
        "one_to_one_pts": True, "audio_tracks": 0, "codec": "hevc", "pixel_format": "yuv420p",
        "color": "bt709 limited range", "full_decode": "pass"}


def read_frame(stream, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size-len(chunks))
        if not chunk:
            break
        chunks.extend(chunk)
    return bytes(chunks)


def finish_master(destination: Path, config: dict, context: dict, receipt: dict) -> None:
    source = context["source"]
    partial = destination/"movie.partial.mp4"
    tagged = destination/"movie.tagged.partial.mp4"
    # VideoToolbox rewrites its final extradata after the inline bitstream
    # filter has been initialized. A lossless remux after encoding reliably
    # labels both SPS and container; there is no second lossy video encode.
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", str(partial),
        "-map", "0:v:0", "-an", "-c:v", "copy", "-tag:v", "hvc1",
        "-bsf:v", "hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        "-video_track_timescale", str(source["frame_rate_numerator"]), "-movflags", "+faststart+write_colr", str(tagged)]
    subprocess.run(command, check=True)
    receipt["color_tag_remux_command"] = command
    receipt["master_validation"] = verify_master(tagged, source, config["output_dimensions"])
    movie_name = Path(config["movie"]).stem+".mp4"
    if (destination/movie_name).exists():
        raise ValueError("refusing to overwrite an existing final master")
    tagged.rename(destination/movie_name)
    receipt.update(status="complete-candidate", master=movie_name, master_sha256=sha(destination/movie_name),
        master_bytes=(destination/movie_name).stat().st_size)
    entry = {"movie": config["movie"], "source_sha256": source["sha256"],
        "source_width": source["width"], "source_height": source["height"], "frame_count": source["frame_count"],
        "rate_numerator": source["frame_rate_numerator"], "rate_denominator": source["frame_rate_denominator"],
        "video": movie_name, "video_sha256": receipt["master_sha256"], "video_bytes": receipt["master_bytes"],
        "width": config["output_dimensions"][0], "height": config["output_dimensions"][1], "provenance": receipt["origin"]}
    version = "v2" if config["schema"].endswith("/v2") else "v1"
    pack = {"schema": "protector-native.cinematic-pack/"+version, "title_dol_sha256": DOL_SHA256,
        "pack_id": config["pack_id"], "entries": [entry], "acceptance": "candidate; native and motion review required"}
    (destination/"cinematics.json").write_text(json.dumps(pack, indent=2)+"\n")


def finalize_candidate(recipe: Path, output: Path) -> dict:
    config, context = plan(recipe,output,finalize=True)
    path = output/"receipt.json"
    previous = path.read_bytes()
    receipt = json.loads(previous)
    if receipt.get("status") != "failed" or receipt.get("schema") != "protector-native.cinematic-restoration-receipt/v1" or \
            receipt.get("frames_done") != context["source"]["frame_count"] or \
            any(receipt.get(k) != v for k,v in context.items()) or \
            receipt.get("model") != config["model"] or receipt.get("shots") != config["shots"] or \
            (output/"receipt-before-finalize.json").exists():
        raise ValueError("only a complete, source-unchanged failed encode can be finalized once")
    (output/"receipt-before-finalize.json").write_bytes(previous)
    receipt["recovered_from_status"] = receipt.pop("error", "failed after full frame production")
    finish_master(output,config,context,receipt)
    path.write_text(json.dumps(receipt,indent=2)+"\n")
    return receipt


def run(recipe: Path, output: Path, device: str = "mps", *, engine=None) -> dict:
    config, context = plan(recipe, output)
    if engine is None:
        engine = CanvasModel(Path(context["weights"]), device)
    source = context["source"]
    destination = no_links(output).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    review = destination/"review"
    review.mkdir()
    rate = source["frame_rate"]
    decoder_args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "2",
        "-i", context["source_path"], "-map", "0:v:0", "-an"]
    filters = scan_filters(config, source["frame_count"])
    if filters:
        decoder_args += ["-vf", ",".join(filters)]
    decoder_args += ["-fps_mode", "passthrough", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]
    target = tuple(config["output_dimensions"])
    partial = destination/"movie.partial.mp4"
    encoder_args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{target[0]}x{target[1]}", "-framerate", rate,
        "-i", "pipe:0", "-an", "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1",
        "-c:v", "hevc_videotoolbox", "-allow_sw", "0", "-realtime", "0", "-b:v", "50M", "-g", "30",
        "-tag:v", "hvc1", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-color_range", "tv", "-video_track_timescale", str(source["frame_rate_numerator"]),
        "-movflags", "+faststart+write_colr", "-metadata", "comment=Local source-derived restoration; original frame timing; no audio",
        str(partial)]
    samples = set(review_frame_indices(source["frame_count"])) | {0, source["frame_count"]-1}
    origin = {"method": "local 4x spatial model restoration then aspect-preserving UHD composition",
        "source_movie_sha256": source["sha256"], "recipe_sha256": context["recipe_sha256"],
        "model": config["model"], "scan_treatment": config["deinterlace"],
        "output_dimensions": list(target),
        "frame_policy": "one output for each original frame; no motion interpolation or temporal averaging",
        "acceptance": "candidate; not native-original UHD or whole-library acceptance"}
    if "deinterlace_ranges" in config:
        origin["scan_ranges"] = config["deinterlace_ranges"]
    receipt = {"schema": "protector-native.cinematic-restoration-receipt/v1", "status": "running",
        "title_dol_sha256": DOL_SHA256, **context, "model": config["model"], "shots": config["shots"],
        "runtime": getattr(engine, "metadata", {}), "origin": origin, "frames_done": 0, "review_frames": [],
        "decoder_command": decoder_args, "encoder_command": encoder_args,
        "exact_duplicate_frames_reused": 0}
    decoder = encoder = None
    started = time.perf_counter()
    previous_key, previous_picture = None, None
    try:
        with (destination/"decoder.log").open("w") as dec_log, (destination/"encoder.log").open("w") as enc_log:
            decoder = subprocess.Popen(decoder_args, stdout=subprocess.PIPE, stderr=dec_log)
            encoder = subprocess.Popen(encoder_args, stdin=subprocess.PIPE, stderr=enc_log)
            shot_index = 0
            for frame in range(source["frame_count"]):
                raw = read_frame(decoder.stdout, source["width"]*source["height"]*3)
                if len(raw) != source["width"]*source["height"]*3:
                    raise ValueError(f"source decode ended before original frame {frame}")
                while frame >= config["shots"][shot_index]["end"]:
                    shot_index += 1
                shot = config["shots"][shot_index]
                original = Image.frombytes("RGB", (source["width"], source["height"]), raw)
                x,y,w,h = shot["crop"]
                cropped = original.crop((x,y,x+w,y+h))
                rgb = np.asarray(cropped)
                verify_extension_edges(rgb, shot)
                key = hashlib.sha256(raw).hexdigest(), shot_index
                if key == previous_key:
                    picture = previous_picture
                    receipt["exact_duplicate_frames_reused"] += 1
                else:
                    padded = padded_source(rgb.astype(np.float32)/255, ["clamp", "clamp"], 32)
                    result = checked_pixels(engine(padded), padded.shape[1]*4, padded.shape[0]*4)
                    restored = Image.fromarray(np.rint(result[128:128+h*4,128:128+w*4]*255).astype(np.uint8))
                    if shot["mode"] in ("crop", "preserve"):
                        picture = restored.resize(target, Image.Resampling.LANCZOS)
                    else:
                        size = fitted_size(w,h,target)
                        picture = Image.new("RGB", target, tuple(shot["matte_rgb"]))
                        picture.paste(restored.resize(size, Image.Resampling.LANCZOS),
                            ((target[0]-size[0])//2, (target[1]-size[1])//2))
                    previous_key, previous_picture = key, picture
                encoder.stdin.write(picture.tobytes())
                if frame in samples:
                    metadata = PngImagePlugin.PngInfo()
                    metadata.add_text("protector_origin", json.dumps({**origin, "frame_zero_based": frame}, sort_keys=True))
                    metadata.add_text("impeccable:prompt", "Source restoration, no text prompt: "+json.dumps(origin, sort_keys=True))
                    name = f"frame-{frame:06d}.png"
                    picture.save(review/name, pnginfo=metadata)
                    receipt["review_frames"].append({"frame_zero_based": frame, "png": "review/"+name,
                        "png_sha256": sha(review/name), "source_rgb8_sha256": key[0],
                        "master_rgb8_sha256": hashlib.sha256(picture.tobytes()).hexdigest()})
                receipt["frames_done"] = frame+1
                if frame % 30 == 0 or frame+1 == source["frame_count"]:
                    receipt["seconds"] = time.perf_counter()-started
                    (destination/"progress.json").write_text(json.dumps(receipt, indent=2)+"\n")
                    print(f"{config['movie']} {frame+1}/{source['frame_count']} frames ({receipt['seconds']:.1f}s)", flush=True)
            if decoder.stdout.read(1) or decoder.wait(timeout=30) != 0:
                raise ValueError("source decode count differs or decoder failed")
            encoder.stdin.close()
            encoder.stdin = None
            if encoder.wait(timeout=60) != 0:
                raise ValueError("master encoding failed; inspect encoder.log")
        if sha(Path(context["source_path"])) != source["sha256"] or sha(recipe) != context["recipe_sha256"] or \
                sha(Path(context["weights"])) != config["model"]["sha256"]:
            raise ValueError("movie, recipe or weights changed during restoration")
        finish_master(destination,config,context,receipt)
        receipt["seconds"] = time.perf_counter()-started
    except BaseException as error:
        receipt.update(status="failed", error=str(error), seconds=time.perf_counter()-started)
        raise
    finally:
        for process in (decoder,encoder):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        (destination/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=("cpu", "mps"), default="mps")
    parser.add_argument("--finalize", action="store_true", help="finalize a fully produced failed candidate without repeating inference")
    args = parser.parse_args()
    result = finalize_candidate(args.recipe,args.output) if args.finalize else run(args.recipe, args.output, args.device)
    print(json.dumps({k: result[k] for k in ("status", "frames_done", "seconds", "master", "master_sha256")}))

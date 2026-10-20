#!/usr/bin/env python3
"""Cook explicit straight-alpha artwork to bounded ASTC 4x4 mip chains.

Source coverage-weighted UNORM mip reduction matches the raw Metal path. Both
8-bit and floating-point decodes are measured, including compositing on black
and white. Codec admission is not aesthetic approval. All pixels stay external.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.cook_texture_pack import astc_blocks, digest, integer, mip_layout, read_source_pack

POLICY = "straight-alpha-composite-v1"
HYBRID_FORMAT = "astc-4x4-ldr-rgba8-tail"
TAIL_POLICY = "lossless-from-first-failed-mip-v1"
LIMITS = {"alpha_max_error": 48.0, "active_alpha_mae": 2.0,
    "active_composite_rmse": 4.0, "active_composite_p99_error": 16.0,
    "composite_max_error": 56.0}


def straight_mip(image):
    import numpy as np
    from PIL import Image
    values = np.asarray(image.convert("RGBA"), dtype=np.uint64)
    height, width = values.shape[:2]
    nh, nw = max(1, height // 2), max(1, width // 2)
    if width in (1, nw * 2) and height in (1, nh * 2):
        dy, dx = height // nh, width // nw
        shaped = values.reshape(nh, dy, nw, dx, 4)
        sums = shaped.sum(axis=(1, 3))
        weighted = (values[:, :, :3] * values[:, :, 3:4]).reshape(nh, dy, nw, dx, 3).sum(axis=(1, 3))
        a = sums[:, :, 3:4]
        divisor = dx * dy
        rgb = np.where(a != 0, (weighted + a // 2) // np.maximum(a, 1),
            (sums[:, :, :3] + divisor // 2) // divisor)
        alpha = (a + divisor // 2) // divisor
        return Image.fromarray(np.concatenate((rgb, alpha), axis=2).astype("uint8"))
    # Same integer area weights as PackStraightMip for odd source dimensions.
    output = np.zeros((nh, nw, 4), dtype=np.uint8)
    for y in range(nh):
        top, bottom = y * height, (y + 1) * height
        for x in range(nw):
            left, right = x * width, (x + 1) * width
            weight_sum = alpha_sum = 0
            weighted, hidden = [0, 0, 0], [0, 0, 0]
            for sy in range(top // nh, (bottom + nh - 1) // nh):
                wy = min((sy + 1) * nh, bottom) - max(sy * nh, top)
                for sx in range(left // nw, (right + nw - 1) // nw):
                    wx = min((sx + 1) * nw, right) - max(sx * nw, left)
                    w, p = wx * wy, values[sy, sx]
                    weight_sum += w
                    alpha_sum += int(p[3]) * w
                    for c in range(3):
                        weighted[c] += int(p[c]) * int(p[3]) * w
                        hidden[c] += int(p[c]) * w
            output[y, x, 3] = (alpha_sum + weight_sum // 2) // weight_sum
            for c in range(3):
                output[y, x, c] = ((weighted[c] + alpha_sum // 2) // alpha_sum if alpha_sum else
                    (hidden[c] + weight_sum // 2) // weight_sum)
    return Image.fromarray(output)


def measure(source, decoded) -> dict:
    import numpy as np
    old = np.asarray(source, dtype=np.float32) / 255
    new = np.asarray(decoded, dtype=np.float32)
    if new.shape != old.shape or not np.isfinite(new).all() or np.any(new < 0) or np.any(new > 1):
        raise ValueError("alpha decode dimensions/range are invalid")
    active = (old[:, :, 3] > 0) | (new[:, :, 3] > 0)
    # A completely clear last mip is still a valid straight-alpha image.
    if not active.any(): active = np.ones(active.shape, dtype=bool)
    alpha = np.abs(new[:, :, 3] - old[:, :, 3]) * 255
    composites = []
    for ground in (0, 1):
        original = old[:, :, :3] * old[:, :, 3:4] + ground * (1 - old[:, :, 3:4])
        candidate = new[:, :, :3] * new[:, :, 3:4] + ground * (1 - new[:, :, 3:4])
        composites.append(np.abs(candidate - original) * 255)
    delta = np.maximum(*composites)
    active_delta = delta[active]
    return {"alpha_max_error": float(alpha.max()), "active_alpha_mae": float(alpha[active].mean()),
        "active_composite_rmse": float(np.sqrt(np.mean(active_delta ** 2))),
        "active_composite_p99_error": float(np.percentile(active_delta, 99)),
        "composite_max_error": float(delta.max()), "active_texels": int(active.sum()),
        "fully_clear_became_nonclear": int(((old[:, :, 3] == 0) & (new[:, :, 3] > 1 / 255)).sum())}


def admitted(metric: dict) -> bool:
    import math
    return all(type(metric.get(key)) in (int, float) and math.isfinite(metric[key]) and
        0 <= metric[key] <= maximum for key, maximum in LIMITS.items())


def decode_astc(image, astc, encoder, work):
    import numpy as np
    import OpenEXR
    from PIL import Image
    decodes, hashes, planes = {}, {}, {}
    for mode, suffix in (("unorm8", "png"), ("float16", "exr")):
        output = work / ("decode." + suffix)
        subprocess.run([str(encoder), "-dl", str(astc), str(output), "-silent"],
            check=True, capture_output=True, timeout=120)
        if mode == "unorm8":
            with Image.open(output) as decoded: values = np.asarray(decoded.convert("RGBA"))
            hashes[mode] = digest(values.tobytes())
            values = values.astype(np.float32) / 255
        else:
            with OpenEXR.File(str(output), separate_channels=True) as decoded:
                channels = decoded.channels()
                if set(channels) != set("RGBA"): raise ValueError("float decode lacks RGBA")
                values = np.stack([channels[c].pixels for c in "RGBA"], axis=2)
            hashes[mode] = digest(values.astype("<f2").tobytes())
        decodes[mode], planes[mode] = measure(image, values), values
    return decodes, hashes, planes


def alpha_mip_layout(width, height, raw_tail_first_level=None):
    layout = mip_layout(width, height, 4)
    if raw_tail_first_level is None:
        return layout
    if not integer(raw_tail_first_level, 1, len(layout) - 1):
        raise ValueError("raw mip tail must follow at least one compressed level")
    offset = 0
    for level in layout:
        raw = level["level"] >= raw_tail_first_level
        level["format"] = "rgba8-unorm" if raw else "astc-4x4-ldr"
        level["offset"] = offset
        if raw: level["byte_length"] = level["width"] * level["height"] * 4
        offset += level["byte_length"]
    return layout


def encode(rgba, width, height, encoder, threads, work):
    from PIL import Image
    image = Image.frombytes("RGBA", (width, height), rgba)
    payload, metrics = bytearray(), []
    raw_tail = None
    for mip in mip_layout(width, height, 4):
        if image.size != (mip["width"], mip["height"]): image = straight_mip(image)
        rgba_hash = digest(image.tobytes())
        if raw_tail is not None:
            payload.extend(image.tobytes())
            metrics.append({"level": mip["level"], "format": "rgba8-unorm", "lossless": True,
                "input_rgba8_sha256": rgba_hash, "payload_sha256": rgba_hash})
            continue
        source, astc = [work / name for name in ("mip.png", "mip.astc")]
        image.save(source)
        attempts = []
        for quality, weight in (("thorough", 4), ("exhaustive", 4), ("exhaustive", 1), ("exhaustive", 16)):
            subprocess.run([str(encoder), "-cl", str(source), str(astc), "4x4", "-" + quality,
                "-cw", "1", "1", "1", str(weight), "-j", str(threads), "-silent"], check=True,
                capture_output=True, timeout=600)
            blocks = astc_blocks(astc.read_bytes(), mip["width"], mip["height"], 4)
            decodes, hashes, _ = decode_astc(image, astc, encoder, work)
            attempt = {"quality": quality, "alpha_component_weight": weight,
                "decodes": decodes, "codec_admitted": all(admitted(m) for m in decodes.values())}
            attempts.append(attempt)
            print(json.dumps({"level": mip["level"], **attempt}), flush=True)
            if attempt["codec_admitted"]: break
        else:
            if mip["level"] == 0:
                raise ValueError(f"base alpha codec failed fixed error limits: {decodes}")
            raw_tail = mip["level"]
            payload.extend(image.tobytes())
            metrics.append({"level": mip["level"], "format": "rgba8-unorm", "lossless": True,
                "input_rgba8_sha256": rgba_hash, "payload_sha256": rgba_hash,
                "rejected_astc_attempts": attempts})
            print(json.dumps({"raw_tail_first_level": raw_tail, "policy": TAIL_POLICY}), flush=True)
            continue
        row = {"level": mip["level"], "format": "astc-4x4-ldr", "input_rgba8_sha256": rgba_hash,
            "decoded_sha256": hashes, "decodes": decodes, "attempts": attempts,
            "codec_admitted": True}
        payload.extend(blocks)
        metrics.append(row)
    return bytes(payload), metrics, raw_tail


def cook(manifest: Path, output: Path, encoder: Path, threads=4):
    manifest, encoder = manifest.resolve(strict=True), encoder.resolve(strict=True)
    destination = output.resolve()
    if not integer(threads, 1, 16) or output.is_symlink() or destination.exists() or \
            destination.is_relative_to(ROOT) or destination.is_relative_to(manifest.parent):
        raise ValueError("alpha cook requires bounded threads and a new external output")
    source, planned = read_source_pack(manifest, allow_straight=True)
    if source["schema"] != "protector-native.texture-pack/v4" or any(
            e["replacement"]["alpha_mode"] != "straight" for e, _ in planned):
        raise ValueError("alpha cooking requires an explicit all-straight raw v4 pack")
    raw_hash, encoder_hash = digest(manifest.read_bytes()), digest(encoder.read_bytes())
    version = subprocess.run([str(encoder), "-version"], check=True, capture_output=True, text=True, timeout=10).stdout.strip()
    destination.mkdir(parents=True)
    (destination / "textures").mkdir()
    entries, receipts = [], []
    with tempfile.TemporaryDirectory(prefix="protector-alpha-astc-") as temporary:
        for entry, path in planned:
            old, raw = entry["replacement"], path.read_bytes()
            if digest(raw) != old["sha256"] or digest(encoder.read_bytes()) != encoder_hash:
                raise ValueError("source or encoder changed during cooking")
            payload, metrics, raw_tail = encode(raw, old["width"], old["height"], encoder, threads, Path(temporary))
            sha = digest(payload)
            relative = f"textures/{sha}.{'hybridmips' if raw_tail is not None else 'astcmips'}"
            target = destination / relative
            if not target.exists(): target.write_bytes(payload)
            result = deepcopy(entry)
            result["replacement"] = {"width": old["width"], "height": old["height"],
                "format": HYBRID_FORMAT if raw_tail is not None else "astc-4x4-ldr",
                "alpha_mode": "straight", "mip_filter": "alpha-weighted-box-unorm-v1",
                "alpha_codec_policy": POLICY, "byte_length": len(payload), "sha256": sha,
                "path": relative, "mip_levels": alpha_mip_layout(old["width"], old["height"], raw_tail),
                "uncompressed_rgba8_sha256": old["sha256"]}
            if raw_tail is not None: result["replacement"]["raw_tail_first_level"] = raw_tail
            entries.append(result)
            receipts.append({"source": entry["source"], "payload_sha256": sha, "levels": metrics})
    cooking = {"encoder": version, "encoder_sha256": encoder_hash, "block": 4,
        "quality": "thorough then bounded exhaustive retries", "alpha_component_weights": [4, 1, 16],
        "tail_policy": TAIL_POLICY,
        "mip_filter": "alpha-weighted-box-unorm-v1", "alpha_codec_policy": POLICY,
        "decode_modes": ["unorm8 PNG", "float16 EXR"], "limits": LIMITS}
    receipt = {"schema": "protector-native.texture-alpha-codec-receipt/v1", "cooking": cooking, "textures": receipts}
    receipt_path = destination / "codec-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n")
    result = {**source, "schema": "protector-native.texture-pack/v5", "entries": entries,
        "cooking": cooking, "raw_pack_sha256": raw_hash, "codec_receipt_sha256": digest(receipt_path.read_bytes()),
        "scope": "straight-alpha ASTC with lossless mip tail where required; codec admission is not artistic approval"}
    (destination / "pack.json").write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    result = cook(args.manifest, args.output, args.encoder, args.threads)
    print(json.dumps({"entries": len(result["entries"]),
        "payload_bytes": sum(e["replacement"]["byte_length"] for e in result["entries"])}))

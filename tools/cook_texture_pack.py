#!/usr/bin/env python3
"""Cook a raw candidate pack into offline ASTC mip chains, without approval claims.

Source RGBA and identity stay unchanged. Compression metrics describe codec loss,
not restoration quality. All game pixels, payloads and tool binaries stay external.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.prepare_texture_restoration import DOL_SHA256


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def integer(value, minimum: int, maximum: int) -> bool:
    return type(value) is int and minimum <= value <= maximum


def mip_layout(width: int, height: int, block: int) -> list[dict]:
    if not integer(width, 1, 4096) or not integer(height, 1, 4096) or block not in (4, 6):
        raise ValueError("invalid ASTC texture dimensions or block size")
    result, offset = [], 0
    while True:
        length = ((width + block - 1) // block) * ((height + block - 1) // block) * 16
        result.append({"level": len(result), "width": width, "height": height,
                       "offset": offset, "byte_length": length})
        offset += length
        if width == height == 1:
            return result
        width, height = max(1, width // 2), max(1, height // 2)


def astc_blocks(data: bytes, width: int, height: int, block: int) -> bytes:
    expected = ((width + block - 1) // block) * ((height + block - 1) // block) * 16
    if len(data) != expected + 16 or data[:4] != b"\x13\xab\xa1\x5c" or \
            data[4:7] != bytes((block, block, 1)) or \
            int.from_bytes(data[7:10], "little") != width or \
            int.from_bytes(data[10:13], "little") != height or \
            int.from_bytes(data[13:16], "little") != 1:
        raise ValueError("encoder returned an invalid ASTC header or payload size")
    return data[16:]


def read_source_pack(manifest: Path, *, allow_straight: bool = False) -> tuple[dict, list[tuple[dict, Path]]]:
    if manifest.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("input manifest exceeds 16 MiB")
    document = json.loads(manifest.read_text())
    explicit_alpha = allow_straight and document.get("schema") == "protector-native.texture-pack/v4"
    if (not explicit_alpha and document.get("schema") != "protector-native.texture-pack/v1") or \
            document.get("title_dol_sha256") != DOL_SHA256 or document.get("status") != "candidate":
        raise ValueError("cooking requires a source-bound RBNEG9 raw candidate pack")
    if not isinstance(document.get("pack_id"), str) or \
            not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", document["pack_id"]):
        raise ValueError("invalid pack identifier")
    entries = document.get("entries")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 16384:
        raise ValueError("a bounded nonempty texture list is required")
    validated, seen = [], set()
    for entry in entries:
        if "required_companion_sources" in entry:
            raise ValueError("companion scope must be applied by composition v5 after cooking")
        source, replacement = entry["source"], entry["replacement"]
        alpha_mode = replacement.get("alpha_mode") if explicit_alpha else "opaque"
        if explicit_alpha and (replacement.get("format") != "rgba8-unorm" or
                alpha_mode not in {"opaque", "straight"} or "mip_levels" in replacement or
                (alpha_mode == "straight" and
                 replacement.get("mip_filter") != "alpha-weighted-box-unorm-v1") or
                (alpha_mode == "opaque" and "mip_filter" in replacement)):
            raise ValueError("raw alpha delivery requires an explicit supported format and mip policy")
        sw, sh = source.get("width"), source.get("height")
        width, height = replacement.get("width"), replacement.get("height")
        source_hash, payload_hash = source.get("rgba8_sha256"), replacement.get("sha256")
        if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                   for value in (source_hash, payload_hash)) or \
                not integer(sw, 1, 1024) or not integer(sh, 1, 1024) or \
                not integer(width, sw, 4096) or not integer(height, sh, 4096) or \
                width * sh != height * sw or \
                replacement.get("byte_length") != width * height * 4:
            raise ValueError("invalid raw source identity or replacement dimensions")
        identity = (sw, sh, source_hash)
        if identity in seen:
            raise ValueError("duplicate source texture identity")
        seen.add(identity)
        relative = f"textures/{payload_hash}.rgba"
        if replacement.get("path") != relative:
            raise ValueError("raw payload must use its hash-addressed direct path")
        path = (manifest.parent / relative).resolve(strict=True)
        if not path.is_relative_to(manifest.parent):
            raise ValueError("raw payload escapes its pack")
        if path.stat().st_size != replacement["byte_length"]:
            raise ValueError("raw payload size changed")
        data = path.read_bytes()
        if digest(data) != payload_hash or (alpha_mode == "opaque" and
                any(alpha != 255 for alpha in data[3::4])):
            raise ValueError("raw payload hash changed or artwork is not opaque")
        validated.append((entry, path))
    return document, validated


def encode_mips(rgba: bytes, width: int, height: int, block: int,
                encoder: Path, quality: str, threads: int, work: Path,
                reused: tuple[bytes, list[dict]] | None = None) -> tuple[bytes, list[dict]]:
    from PIL import Image
    import numpy as np
    import OpenEXR

    level_image = Image.frombytes("RGBA", (width, height), rgba)
    output, measurements = bytearray(), []
    for mip in mip_layout(width, height, block):
        if level_image.size != (mip["width"], mip["height"]):
            # Match the existing UNORM sampling lane: no implicit sRGB conversion.
            # This v1 source lane is opaque; alpha-aware art has its own admission.
            level_image = level_image.resize((mip["width"], mip["height"]), Image.Resampling.BOX)
        source_path = work / "mip.png"
        astc_path = work / "mip.astc"
        decoded_path = work / "decoded.png"
        float_path = work / "decoded.exr"
        level_image.save(source_path)
        alpha_attempts = []
        # Opaque input can still select an RGBA endpoint mode with slight alpha
        # loss. Retry only that mip with stronger documented component weights;
        # do not repair decoded pixels or relax admission. Unaffected payloads
        # keep the original encoder invocation and remain byte-identical.
        previous_weight = reused[1][mip["level"]].get("alpha_component_weight", 1) if reused else 1
        if previous_weight not in (1, 4, 16, 64):
            raise ValueError("unsupported previous alpha component weight")
        weights = [w for w in (1, 4, 16, 64) if w >= previous_weight]
        for attempt, alpha_weight in enumerate(weights):
            extra = [] if alpha_weight == 1 else ["-cw", "1", "1", "1", str(alpha_weight)]
            reuse_attempt = reused is not None and attempt == 0
            if reuse_attempt:
                header = (b"\x13\xab\xa1\x5c" + bytes((block, block, 1)) +
                          mip["width"].to_bytes(3, "little") + mip["height"].to_bytes(3, "little") +
                          b"\1\0\0")
                astc_path.write_bytes(header + reused[0][mip["offset"]:mip["offset"]+mip["byte_length"]])
            else:
                subprocess.run([str(encoder), "-cl", str(source_path), str(astc_path),
                                f"{block}x{block}", f"-{quality}", "-j", str(threads),
                                *extra, "-silent"], check=True, capture_output=True, timeout=600)
            blocks = astc_blocks(astc_path.read_bytes(), mip["width"], mip["height"], block)
            subprocess.run([str(encoder), "-dl", str(astc_path), str(decoded_path), "-silent"],
                           check=True, capture_output=True, timeout=120)
            with Image.open(decoded_path) as decoded:
                if decoded.size != level_image.size:
                    raise ValueError("ASTC roundtrip changed dimensions")
                pixels = np.asarray(decoded.convert("RGBA"), dtype=np.int16)
            nonopaque = int(np.count_nonzero(pixels[:, :, 3] != 255))
            # PNG decoding selects ASTC's UNORM8 mode, which can hide alpha
            # loss that the default floating-point Metal decode exposes.
            subprocess.run([str(encoder), "-dl", str(astc_path), str(float_path), "-silent"],
                           check=True, capture_output=True, timeout=120)
            with OpenEXR.File(str(float_path), separate_channels=True) as decoded:
                channels = decoded.channels()
                if set(channels) != set("RGBA"):
                    raise ValueError("ASTC floating-point roundtrip lacks RGBA channels")
                for channel in channels.values():
                    values = channel.pixels
                    if values.shape != (mip["height"], mip["width"]):
                        raise ValueError("ASTC floating-point roundtrip changed dimensions")
                    if not np.isfinite(values).all() or np.any(values < 0) or np.any(values > 1):
                        raise ValueError("ASTC floating-point roundtrip has invalid values")
                alpha = channels["A"].pixels
                float_nonopaque = int(np.count_nonzero(alpha != 1))
                alpha_hash = digest(np.asarray(alpha, dtype="<f2").tobytes())
            alpha_attempts.append({"alpha_component_weight": alpha_weight,
                                   "reused_compressed_mip": reuse_attempt,
                                   "decoded_nonopaque_texels": nonopaque,
                                   "decoded_float_nonopaque_texels": float_nonopaque})
            if not nonopaque and not float_nonopaque:
                break
        else:
            raise ValueError(f"opaque artwork lost opaque alpha during compression at mip "
                             f"{mip['level']} after {len(alpha_attempts)} attempts")
        output.extend(blocks)
        original = np.asarray(level_image, dtype=np.int16)
        delta = pixels[:, :, :3].astype(np.float64) - original[:, :, :3]
        mse = float(np.mean(delta * delta))
        measurements.append({"level": mip["level"], "rmse_rgb": math.sqrt(mse),
            "psnr_rgb_db": 10 * math.log10(255**2 / mse) if mse else None,
            "max_absolute_rgb_error": int(np.max(np.abs(delta))), "alpha_exact": True,
            "alpha_component_weight": alpha_weight, "alpha_attempts": alpha_attempts,
            "decoded_alpha_float16_sha256": alpha_hash,
            "input_rgba8_sha256": digest(level_image.tobytes()),
            "decoded_rgba8_sha256": digest(pixels.astype(np.uint8).tobytes())})
    return bytes(output), measurements


def read_reuse_pack(path: Path, raw_manifest: Path, raw_entries: list, encoder_hash: str,
                    block: int, quality: str) -> tuple[list, str]:
    """Reuse only a complete, identity-matching cook; decode every mip again."""
    path = path.resolve(strict=True)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("reuse manifest exceeds 16 MiB")
    data = json.loads(path.read_text())
    if (data.get("schema") != "protector-native.texture-pack/v2" or
            data.get("title_dol_sha256") != DOL_SHA256 or data.get("status") != "candidate" or
            data.get("raw_pack_sha256") != digest(raw_manifest.read_bytes())):
        raise ValueError("reuse pack does not identify this exact raw pack")
    settings = data.get("cooking", {})
    if (settings.get("encoder_sha256"), settings.get("block"), settings.get("quality"),
            settings.get("mip_filter")) != (encoder_hash, block, quality, "BOX UNORM; opaque alpha"):
        raise ValueError("reuse encoder settings differ")
    receipt_path = (path.parent / "codec-receipt.json").resolve(strict=True)
    if not receipt_path.is_relative_to(path.parent) or receipt_path.stat().st_size > 64*1024*1024:
        raise ValueError("reuse receipt escapes its pack or exceeds the size bound")
    if digest(receipt_path.read_bytes()) != data.get("codec_receipt_sha256"):
        raise ValueError("reuse codec receipt changed")
    receipt = json.loads(receipt_path.read_text())
    entries, results = data.get("entries", []), receipt.get("textures", [])
    if receipt.get("schema") != "protector-native.texture-codec-receipt/v1" or \
            len(entries) != len(raw_entries) or len(results) != len(entries):
        raise ValueError("reuse pack/receipt coverage differs")
    reusable = []
    for (raw, _), entry, result in zip(raw_entries, entries, results):
        replacement = entry["replacement"]
        layout = mip_layout(raw["replacement"]["width"], raw["replacement"]["height"], block)
        payload_hash = replacement.get("sha256")
        if not isinstance(payload_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", payload_hash):
            raise ValueError("invalid reused payload hash")
        if (entry["source"] != raw["source"] or result["source"] != raw["source"] or
                result.get("payload_sha256") != payload_hash or
                replacement.get("uncompressed_rgba8_sha256") != raw["replacement"]["sha256"] or
                replacement.get("format") != f"astc-{block}x{block}-ldr" or
                replacement.get("alpha_mode") != "opaque" or replacement.get("mip_levels") != layout or
                [replacement.get("width"), replacement.get("height")] != [layout[0]["width"], layout[0]["height"]] or
                replacement.get("byte_length") != sum(m["byte_length"] for m in layout) or
                replacement.get("path") != f"textures/{payload_hash}.astcmips"):
            raise ValueError("reuse source/payload identity or mip layout differs")
        levels = result.get("levels", [])
        if len(levels) != len(layout) or any(m.get("level") != i or
                m.get("alpha_component_weight", 1) not in (1, 4, 16, 64) for i,m in enumerate(levels)):
            raise ValueError("reuse mip metrics differ")
        payload_path = (path.parent / replacement["path"]).resolve(strict=True)
        if not payload_path.is_relative_to(path.parent) or payload_path.stat().st_size != replacement["byte_length"]:
            raise ValueError("reused payload escapes pack or changed size")
        reusable.append((payload_path, payload_hash, levels))
    return reusable, digest(path.read_bytes())


def cook(manifest: Path, output: Path, encoder: Path, *, block: int = 4,
         quality: str = "thorough", threads: int = 4, reuse_cooked: Path | None = None) -> dict:
    manifest = manifest.resolve(strict=True)
    encoder = encoder.resolve(strict=True)
    if block not in (4, 6) or quality not in ("medium", "thorough") or not integer(threads, 1, 16):
        raise ValueError("unsupported encoder settings")
    destination = output.resolve()
    if output.is_symlink() or destination.exists() or destination.is_relative_to(ROOT) or \
            destination.is_relative_to(manifest.parent):
        raise ValueError("cooked output must be new and outside Git and the source pack")
    document, planned = read_source_pack(manifest, allow_straight=True)
    if any(entry["replacement"].get("alpha_mode", "opaque") != "opaque" for entry, _ in planned):
        raise ValueError("opaque cooking cannot admit straight-alpha artwork; use the separate alpha cooker")
    encoder_hash = digest(encoder.read_bytes())
    reusable, reuse_hash = [], None
    if reuse_cooked:
        if destination.is_relative_to(reuse_cooked.resolve(strict=True).parent):
            raise ValueError("output must be outside the reused pack")
        reusable, reuse_hash = read_reuse_pack(reuse_cooked, manifest, planned, encoder_hash, block, quality)
    version = subprocess.run([str(encoder), "-version"], check=True, capture_output=True,
                             text=True, timeout=10).stdout.strip()
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "textures").mkdir()
    cooked_entries, receipts = [], []
    with tempfile.TemporaryDirectory(prefix="protector-astc-") as temporary:
        for entry, path in planned:
            raw = path.read_bytes()
            old = entry["replacement"]
            if len(raw) != old["byte_length"] or digest(raw) != old["sha256"]:
                raise ValueError("raw payload changed after validation")
            if digest(encoder.read_bytes()) != encoder_hash:
                raise ValueError("encoder binary changed during cooking")
            reuse_argument = ()
            if reusable:
                reused_path, reused_hash, reused_metrics = reusable[len(cooked_entries)]
                reused_payload = reused_path.read_bytes()
                if digest(reused_payload) != reused_hash:
                    raise ValueError("reused compressed payload changed")
                reuse_argument = ((reused_payload, reused_metrics),)
            try:
                payload, metrics = encode_mips(raw, old["width"], old["height"], block,
                                              encoder, quality, threads, Path(temporary), *reuse_argument)
            except (ValueError, subprocess.SubprocessError) as error:
                raise ValueError(f"texture {len(cooked_entries) + 1}/{len(planned)} "
                                 f"({entry['source']['rgba8_sha256']}): {error}") from error
            payload_hash = digest(payload)
            relative = f"textures/{payload_hash}.astcmips"
            payload_path = destination / relative
            if not payload_path.exists():
                with payload_path.open("xb") as stream:
                    stream.write(payload)
            cooked = deepcopy(entry)
            cooked["replacement"] = {"width": old["width"], "height": old["height"],
                "format": f"astc-{block}x{block}-ldr", "alpha_mode": "opaque",
                "byte_length": len(payload), "sha256": payload_hash, "path": relative,
                "mip_levels": mip_layout(old["width"], old["height"], block),
                "uncompressed_rgba8_sha256": old["sha256"]}
            cooked_entries.append(cooked)
            receipts.append({"source": entry["source"], "payload_sha256": payload_hash,
                             "levels": metrics})
            print(f"Cooked {len(cooked_entries)}/{len(planned)}: {old['width']}x{old['height']} "
                  f"-> {len(payload)} compressed bytes", flush=True)
    report = {**document, "schema": "protector-native.texture-pack/v2",
        "scope": "opaque ASTC candidate artwork; codec metrics are not visual acceptance",
        "entries": cooked_entries, "raw_pack_sha256": digest(manifest.read_bytes()),
        "cooking": {"encoder": version, "encoder_sha256": encoder_hash,
            "encoder_origin": "https://github.com/ARM-software/astc-encoder",
            "quality": quality, "block": block, "mip_filter": "BOX UNORM; opaque alpha",
            "alpha_policy": "reject nonopaque UNORM8 or float16 decoded texels; retry mip alpha weights 4,16,64",
            "opacity_decode_modes": ["unorm8 PNG", "float16 EXR"],
            "runtime_pixel_format": f"ASTC_{block}x{block}_LDR"}}
    if reuse_hash:
        report["reused_cooked_pack_sha256"] = reuse_hash
    receipt = {"schema": "protector-native.texture-codec-receipt/v1",
               "cooking": report["cooking"], "textures": receipts}
    with (destination / "codec-receipt.json").open("x") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
    report["codec_receipt_sha256"] = digest((destination / "codec-receipt.json").read_bytes())
    with (destination / "pack.json").open("x") as stream:
        json.dump(report, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--block", type=int, choices=[4, 6], default=4)
    parser.add_argument("--quality", choices=["medium", "thorough"], default="thorough")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--reuse-cooked", type=Path, help="decode/revalidate matching completed payloads; recook failing mips only")
    args = parser.parse_args()
    report = cook(args.manifest, args.output, args.encoder, block=args.block,
                  quality=args.quality, threads=args.threads, reuse_cooked=args.reuse_cooked)
    print(json.dumps({"schema": report["schema"], "entries": len(report["entries"]),
                      "compressed_bytes": sum(e["replacement"]["byte_length"] for e in report["entries"])}))


if __name__ == "__main__":
    main()

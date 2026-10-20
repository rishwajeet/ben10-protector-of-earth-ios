#!/usr/bin/env python3
"""Compose pinned artwork packs without altering already-reviewed payloads.

This preserves per-pack codec evidence and candidate status. It neither encodes
pixels nor substitutes for GPU, art or motion acceptance of the combined pack.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from tools.cook_texture_pack import DOL_SHA256, digest, integer, mip_layout, read_source_pack
from tools.cook_alpha_texture_pack import (POLICY as ALPHA_POLICY, LIMITS as ALPHA_LIMITS,
    HYBRID_FORMAT, TAIL_POLICY, admitted as alpha_admitted, alpha_mip_layout)


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def read_pinned(path: Path, expected: str, limit: int) -> dict:
    if not valid_hash(expected) or path.stat().st_size > limit:
        raise ValueError("invalid hash or oversized metadata")
    data = path.read_bytes()
    if digest(data) != expected:
        raise ValueError("pinned metadata changed")
    result = json.loads(data)
    if not isinstance(result, dict):
        raise ValueError("metadata must be an object")
    return result


def scope_companions(entries: list[dict], pairs: object) -> None:
    """Apply reciprocal OR-neighbor guards, not global source-hash substitution."""
    if not isinstance(pairs, list) or not 1 <= len(pairs) <= 4096:
        raise ValueError("companion pairs must be a bounded nonempty list")
    by_key = {f"{e['source']['width']}x{e['source']['height']}-{e['source']['rgba8_sha256']}": e for e in entries}
    neighbors, seen = {}, set()
    for pair in pairs:
        if (not isinstance(pair, list) or len(pair) != 2 or
                any(not isinstance(key, str) or key not in by_key for key in pair) or pair[0] == pair[1]):
            raise ValueError("each companion pair needs two distinct sources present in the pack")
        edge = tuple(sorted(pair))
        if edge in seen:
            raise ValueError("duplicate companion pair")
        seen.add(edge)
        for key, other in (pair, pair[::-1]):
            neighbors.setdefault(key, set()).add(other)
            if len(neighbors[key]) > 8:
                raise ValueError("a source has more than eight companion alternatives")
    for key, required in neighbors.items():
        by_key[key]["required_companion_sources"] = sorted(required)


def write_payload(source: Path, target: Path, data: bytes, *, clone: bool = False) -> None:
    """Optionally use independent COW storage; never hard-link source artwork."""
    if target.exists() or target.is_symlink():
        raise FileExistsError(target)
    if clone:
        if sys.platform != "darwin" or source.stat().st_dev != target.parent.stat().st_dev:
            raise ValueError("payload clones require macOS and the same filesystem")
        subprocess.run(["/bin/cp", "-c", str(source), str(target)], check=True)
        if target.stat().st_size != len(data) or digest(target.read_bytes()) != digest(data):
            raise ValueError("cloned payload changed after preflight")
    else:
        with target.open("xb") as stream:
            stream.write(data)


def compose(recipe_path: Path, output: Path, *, clone_payloads: bool = False) -> dict:
    recipe_path = recipe_path.resolve(strict=True)
    if recipe_path.stat().st_size > 1024 * 1024:
        raise ValueError("composition recipe is oversized")
    recipe_bytes = recipe_path.read_bytes()
    recipe = json.loads(recipe_bytes)
    scoped = recipe.get("schema") == "protector-native.texture-pack-composition/v5"
    compressed_alpha = scoped or recipe.get("schema") == "protector-native.texture-pack-composition/v4"
    explicit_alpha = compressed_alpha or recipe.get("schema") == "protector-native.texture-pack-composition/v3"
    mixed = explicit_alpha or recipe.get("schema") == "protector-native.texture-pack-composition/v2"
    if (recipe.get("schema") not in {"protector-native.texture-pack-composition/v1",
            "protector-native.texture-pack-composition/v2", "protector-native.texture-pack-composition/v3",
            "protector-native.texture-pack-composition/v4", "protector-native.texture-pack-composition/v5"} or
            not isinstance(recipe.get("pack_id"), str) or
            not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", recipe["pack_id"]) or
            not isinstance(recipe.get("packs"), list) or not 1 <= len(recipe["packs"]) <= 64):
        raise ValueError("invalid bounded composition recipe")
    if not scoped and "companion_pairs" in recipe:
        raise ValueError("companion pairs require composition v5")
    destination = output.resolve()
    if output.is_symlink() or destination.exists() or destination.is_relative_to(ROOT):
        raise ValueError("output must be new and outside Git")
    entries, metrics, payloads, inputs = [], [], [], []
    seen = set()
    common_cooking = common_sources = None
    for reference in recipe["packs"]:
        path = (recipe_path.parent / reference["path"]).resolve(strict=True)
        if destination.is_relative_to(path.parent):
            raise ValueError("output must be outside every input pack")
        document = read_pinned(path, reference["sha256"], 32 * 1024 * 1024)
        # Flat source manifests + the complete pair graph are the authority.
        # Never accept a guarded composite through an older codec-only path.
        if any("required_companion_sources" in e for e in document.get("entries", [])):
            raise ValueError("guarded inputs require their flat manifests and complete companion pairs recipe")
        cooking = document.get("cooking", {})
        sources = document.get("sources_sha256")
        # v2 composition is an explicit heterogeneous-source/format lane. The
        # old v1 contract remains homogeneous ASTC with identical source pins.
        if mixed and (document.get("schema") == "protector-native.texture-pack/v1" or
                (explicit_alpha and document.get("schema") == "protector-native.texture-pack/v4")):
            if not valid_hash(sources):
                raise ValueError("raw input must retain its extraction manifest pin")
            raw_document, raw_entries = read_source_pack(path, allow_straight=explicit_alpha)
            if raw_document != document:
                raise ValueError("raw manifest changed during validation")
            for raw_entry, payload_path in raw_entries:
                source = raw_entry["source"]
                key = (source["width"], source["height"], source["rgba8_sha256"])
                if key in seen:
                    raise ValueError("duplicate source across composed packs")
                seen.add(key)
                replacement = {**raw_entry["replacement"], "format": "rgba8-unorm",
                    "alpha_mode": raw_entry["replacement"]["alpha_mode"] if
                        document["schema"] == "protector-native.texture-pack/v4" else "opaque"}
                replacement.pop("mip_levels", None)
                replacement.pop("_astc_block", None)
                entry = {**raw_entry, "replacement": replacement}
                entries.append(entry)
                metrics.append({"source": source, "format": "rgba8-unorm",
                    "payload_sha256": replacement["sha256"], "alpha_exact": True,
                    "mips": replacement.get("mip_filter", "generated by the existing Metal raw upload path")})
                payloads.append((payload_path, replacement))
                if len(entries) > 16384:
                    raise ValueError("combined texture count exceeds bound")
            inputs.append({"manifest": str(path), "sha256": reference["sha256"],
                "sources_sha256": sources, "schema": document["schema"],
                "pack_id": document["pack_id"], "entries": len(raw_entries)})
            continue
        alpha_input = compressed_alpha and document.get("schema") == "protector-native.texture-pack/v5"
        codec_settings_valid = (cooking.get("decode_modes") == ["unorm8 PNG", "float16 EXR"] and
            cooking.get("mip_filter") == "alpha-weighted-box-unorm-v1" and
            cooking.get("alpha_codec_policy") == ALPHA_POLICY and cooking.get("limits") == ALPHA_LIMITS and
            valid_hash(document.get("raw_pack_sha256")) and cooking.get("block") == 4) if alpha_input else (
            cooking.get("opacity_decode_modes") == ["unorm8 PNG", "float16 EXR"] and
            cooking.get("mip_filter") == "BOX UNORM; opaque alpha" and cooking.get("block") in (4, 6))
        if ((not alpha_input and document.get("schema") != "protector-native.texture-pack/v2") or
                document.get("title_dol_sha256") != DOL_SHA256 or
                document.get("status") != "candidate" or not valid_hash(sources) or
                not valid_hash(cooking.get("encoder_sha256")) or
                not codec_settings_valid):
            raise ValueError("composition requires source-bound dual-decode ASTC candidates with explicit policies")
        if common_cooking is None:
            common_cooking, common_sources = cooking, sources
        elif not mixed and (common_cooking != cooking or common_sources != sources):
            raise ValueError("input packs must share sources and codec settings")
        receipt_path = (path.parent / "codec-receipt.json").resolve(strict=True)
        if not receipt_path.is_relative_to(path.parent):
            raise ValueError("codec receipt escapes input pack")
        receipt = read_pinned(receipt_path, document.get("codec_receipt_sha256"), 64 * 1024 * 1024)
        pack_entries, pack_metrics = document.get("entries"), receipt.get("textures")
        receipt_schema = "protector-native.texture-alpha-codec-receipt/v1" if alpha_input else "protector-native.texture-codec-receipt/v1"
        if (receipt.get("schema") != receipt_schema or
                receipt.get("cooking") != cooking or not isinstance(pack_entries, list) or
                not 1 <= len(pack_entries) <= 16384 or not isinstance(pack_metrics, list) or
                len(pack_entries) != len(pack_metrics)):
            raise ValueError("codec receipt coverage/settings differ")
        for entry, metric in zip(pack_entries, pack_metrics):
            source, replacement = entry["source"], entry["replacement"]
            sw, sh = source.get("width"), source.get("height")
            w, h = replacement.get("width"), replacement.get("height")
            source_hash, payload_hash = source.get("rgba8_sha256"), replacement.get("sha256")
            if (not integer(sw, 1, 1024) or not integer(sh, 1, 1024) or
                    not integer(w, sw, 4096) or not integer(h, sh, 4096) or w * sh != h * sw or
                    not valid_hash(source_hash) or not valid_hash(payload_hash) or
                    not valid_hash(replacement.get("uncompressed_rgba8_sha256"))):
                raise ValueError("invalid source/replacement identity or dimensions")
            key = (sw, sh, source_hash)
            if key in seen:
                raise ValueError("duplicate source across composed packs")
            seen.add(key)
            hybrid = replacement.get("format") == HYBRID_FORMAT
            tail_first = replacement.get("raw_tail_first_level") if hybrid else None
            if (hybrid and (not alpha_input or cooking.get("tail_policy") != TAIL_POLICY or tail_first is None)) or \
                    (not hybrid and "raw_tail_first_level" in replacement):
                raise ValueError("hybrid mip tail requires explicit straight-alpha policy")
            layout = alpha_mip_layout(w, h, tail_first) if hybrid else mip_layout(w, h, cooking["block"])
            expected_path = f"textures/{payload_hash}.{'hybridmips' if hybrid else 'astcmips'}"
            if (replacement.get("format") != (HYBRID_FORMAT if hybrid else f"astc-{cooking['block']}x{cooking['block']}-ldr") or
                    replacement.get("alpha_mode") != ("straight" if alpha_input else "opaque") or
                    replacement.get("mip_levels") != layout or
                    replacement.get("byte_length") != sum(m["byte_length"] for m in layout) or
                    replacement.get("path") != expected_path or metric.get("source") != source or
                    metric.get("payload_sha256") != payload_hash):
                raise ValueError("compressed layout or codec identity differs")
            if alpha_input and (replacement.get("mip_filter") != "alpha-weighted-box-unorm-v1" or
                    replacement.get("alpha_codec_policy") != ALPHA_POLICY):
                raise ValueError("compressed alpha requires exact mip and codec policies")
            if not alpha_input and ("alpha_codec_policy" in replacement or "mip_filter" in replacement):
                raise ValueError("opaque ASTC must not declare alpha policies")
            levels = metric.get("levels", [])
            if alpha_input:
                if len(levels) != len(layout):
                    raise ValueError("alpha codec receipt lacks mip coverage")
                for i, (level, mip) in enumerate(zip(levels, layout)):
                    if hybrid and i >= tail_first:
                        if (level.get("level") != i or level.get("format") != "rgba8-unorm" or
                                level.get("lossless") is not True or
                                not valid_hash(level.get("input_rgba8_sha256")) or
                                level.get("payload_sha256") != level["input_rgba8_sha256"]):
                            raise ValueError("lossless alpha tail lacks exact per-mip identity")
                        continue
                    decodes, hashes, attempts = level.get("decodes", {}), level.get("decoded_sha256", {}), level.get("attempts", [])
                    if (level.get("level") != i or level.get("codec_admitted") is not True or
                            not valid_hash(level.get("input_rgba8_sha256")) or
                            set(decodes) != {"unorm8", "float16"} or set(hashes) != set(decodes) or
                            not all(valid_hash(h) for h in hashes.values()) or
                            not all(alpha_admitted(m) and
                                integer(m.get("active_texels"), 1, mip["width"] * mip["height"]) and
                                integer(m.get("fully_clear_became_nonclear"), 0, mip["width"] * mip["height"])
                                for m in decodes.values()) or not attempts or
                            attempts[-1].get("codec_admitted") is not True or attempts[-1].get("decodes") != decodes):
                        raise ValueError("alpha codec lacks admitted dual-decode evidence for every mip")
            elif (len(levels) != len(layout) or any(
                    m.get("level") != i or m.get("alpha_exact") is not True or
                    not valid_hash(m.get("decoded_alpha_float16_sha256")) or
                    not m.get("alpha_attempts") or
                    m["alpha_attempts"][-1].get("decoded_nonopaque_texels") != 0 or
                    m["alpha_attempts"][-1].get("decoded_float_nonopaque_texels") != 0
                    for i, m in enumerate(levels))):
                raise ValueError("codec receipt lacks exact opacity evidence for every mip")
            payload_path = (path.parent / expected_path).resolve(strict=True)
            if (not payload_path.is_relative_to(path.parent) or
                    payload_path.stat().st_size != replacement["byte_length"] or
                    digest(payload_path.read_bytes()) != payload_hash):
                raise ValueError("payload escaped its pack or changed identity")
            if hybrid:
                raw = payload_path.read_bytes()
                for level, mip in zip(levels[tail_first:], layout[tail_first:]):
                    offset = mip["offset"]
                    if digest(raw[offset:offset + mip["byte_length"]]) != level["input_rgba8_sha256"]:
                        raise ValueError("raw tail bytes differ from coverage-weighted source mip")
            entries.append(entry)
            metrics.append({**metric, "format": replacement["format"]} if mixed else metric)
            payloads.append((payload_path, replacement))
            if len(entries) > 16384:
                raise ValueError("combined texture count exceeds bound")
        inputs.append({"manifest": str(path), "sha256": reference["sha256"],
                       "codec_receipt_sha256": document["codec_receipt_sha256"],
                       "pack_id": document["pack_id"], "entries": len(pack_entries)})
        if mixed:
            inputs[-1].update({"sources_sha256": sources, "cooking": cooking, "schema": document["schema"]})
    if scoped:
        scope_companions(entries, recipe.get("companion_pairs"))
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "textures").mkdir()
    written = set()
    for path, replacement in payloads:
        data = path.read_bytes()
        if len(data) != replacement["byte_length"] or digest(data) != replacement["sha256"]:
            raise ValueError("payload changed after preflight")
        if replacement["path"] not in written:
            write_payload(path, destination / replacement["path"], data, clone=clone_payloads)
            written.add(replacement["path"])
    receipt = {"schema": "protector-native.texture-codec-receipt/v1",
               "cooking": common_cooking, "textures": metrics, "composed_from": inputs}
    report = {"schema": "protector-native.texture-pack/v2", "pack_id": recipe["pack_id"],
              "title_dol_sha256": DOL_SHA256, "status": "candidate", "entries": entries,
              "scope": "lossless composition of opaque ASTC candidates; actual-model acceptance is separate",
              "sources_sha256": common_sources, "cooking": common_cooking,
              "composition_recipe_sha256": digest(recipe_bytes), "composed_from": inputs}
    if mixed:
        receipt["schema"] = "protector-native.texture-mixed-receipt/v1"
        receipt.pop("cooking")
        report["schema"] = "protector-native.texture-pack/v3"
        report.pop("cooking")
        report.pop("sources_sha256")
        report["source_manifests_sha256"] = sorted({item["sources_sha256"] for item in inputs})
        report["scope"] = "lossless composition of opaque raw/ASTC candidates; per-plane artistic and runtime acceptance is separate"
        if explicit_alpha:
            report["schema"] = "protector-native.texture-pack/v4"
            report["scope"] = "lossless opaque ASTC/raw and explicit straight-alpha raw composition; art/runtime acceptance is separate"
        if compressed_alpha:
            report["schema"] = "protector-native.texture-pack/v5"
            report["scope"] = "lossless opaque and explicit straight-alpha raw/ASTC composition; art/runtime acceptance is separate"
        if scoped:
            report["schema"] = "protector-native.texture-pack/v6"
            report["scope"] = "lossless artwork composition with exact reciprocal same-material companion guards; art/runtime acceptance is separate"
            report["companion_pairs"] = sorted(sorted(pair) for pair in recipe["companion_pairs"])
    with (destination / "codec-receipt.json").open("x") as stream:
        stream.write(json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n")
    report["codec_receipt_sha256"] = digest((destination / "codec-receipt.json").read_bytes())
    with (destination / "pack.json").open("x") as stream:
        stream.write(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--clone-payloads", action="store_true",
                        help="Use verified macOS same-volume copy-on-write payloads")
    args = parser.parse_args()
    report = compose(args.recipe, args.output, clone_payloads=args.clone_payloads)
    print(json.dumps({"pack_id": report["pack_id"], "entries": len(report["entries"]),
                      "payload_bytes": sum(e["replacement"]["byte_length"] for e in report["entries"])}))

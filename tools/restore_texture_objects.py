#!/usr/bin/env python3
"""Restore explicit typed source objects, retaining every initialized GX plane.

Unlike interface-grid restoration this proves original object identity only:
there is no fabricated live draw, adjacency, layout or semantic-role evidence.
One pinned local RGB restoration treats the primary, or an explicit
`primary: source-bicubic` selects sampler-aware reconstruction without a model.
An explicitly selected bicubic pass resamples auxiliary RGB without learned detail.
Schema v2 can explicitly share identical plane treatments between complete
objects. It produces one candidate per source identity, never duplicate masks.
All outputs remain private candidates requiring offline and native review.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import time

import numpy as np
from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from protector_native.bigb import parse_relocation_commands
from protector_native.textures import decode_wii_texture_rgba
from tools.assemble_interface_grid import no_links, report, sha
from tools.audit_bigb import decode_package
from tools.build_texture_pack import read_png
from tools.prepare_texture_restoration import DOL_SHA256, source_planes
from tools.restore_texture_batch import (LocalModels, checked_pixels, identifier,
    inference_padding, padded_source, pinned_file)


def plan(recipe_path: Path, output: Path) -> tuple[dict, dict, list[dict]]:
    recipe_path, recipe_bytes, config = report(recipe_path)
    schema = config.get("schema")
    if schema not in {"protector-native.texture-object-restoration/v1",
            "protector-native.texture-object-restoration/v2"}:
        raise ValueError("an explicit texture-object recipe is required")
    shared = config.get("shared_planes")
    if schema.endswith("/v1"):
        if shared is not None or "shared_planes" in config:
            raise ValueError("shared planes require texture-object recipe v2")
        declared_shared = set()
    else:
        if not isinstance(shared, list) or not 1 <= len(shared) <= 128 or \
                any(not isinstance(key, str) or not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*-[0-9a-f]{64}", key)
                    for key in shared) or len(set(shared)) != len(shared):
            raise ValueError("v2 requires distinct exact shared plane identities")
        declared_shared = set(shared)
    identifier(config.get("pack_id"))
    manifest_path = pinned_file(recipe_path.parent, config, "sources", "sources_sha256")
    manifest_path, manifest_bytes, manifest = report(manifest_path)
    if manifest.get("schema") != "protector-native.texture-restoration-sources/v2" or \
            manifest.get("title_dol_sha256") != DOL_SHA256 or \
            manifest.get("includes_auxiliary_planes") is not True or manifest.get("failures"):
        raise ValueError("a complete plane-qualified original-title inventory is required")
    source = no_links(Path(manifest["source_data_root"]))
    if sha(no_links(source / "sys/main.dol").read_bytes()) != DOL_SHA256:
        raise ValueError("original executable changed")
    destination = no_links(output)
    if destination.exists() or any(destination.is_relative_to(parent) for parent in
            (ROOT, source, manifest_path.parent)):
        raise ValueError("use a new external destination outside original sources")
    entries = config.get("objects")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 128:
        raise ValueError("a bounded nonempty object selection is required")
    packages = {row["package"]: row for row in manifest.get("packages", [])}
    if len(packages) != len(manifest.get("packages", [])):
        raise ValueError("duplicate package identity")
    decoded, selected, names, keys, planned = {}, set(), set(), set(), []
    repeated_keys, treatments = set(), {}
    models_checked, finisher_checked = set(), False
    for entry in entries:
        name = identifier(entry.get("name"))
        package_name, offset_text = entry.get("package"), entry.get("resource_offset")
        if not isinstance(package_name, str) or Path(package_name).name != package_name or \
                Path(package_name).suffix not in {".gcm", ".gcs"} or package_name not in packages or \
                not isinstance(offset_text, str) or not re.fullmatch(r"0x[0-9a-f]{8}", offset_text):
            raise ValueError("select an inventoried package and exact resource offset")
        identity = (package_name, offset_text)
        if identity in selected or name in names:
            raise ValueError("duplicate object or name")
        selected.add(identity)
        names.add(name)
        if package_name not in decoded:
            path = no_links(source / "files" / package_name)
            package = decode_package(path)
            if package.header.magic != "BGIB" or package.header.endian != "big" or \
                    package.package_sha256 != packages[package_name]["sha256"] or \
                    sha(path.read_bytes()) != package.package_sha256:
                raise ValueError("original package identity changed")
            commands = parse_relocation_commands(package.relocation, "big",
                file_info_size=len(package.file_info))
            typed = {command.destination_offset for command in commands if command.name == "texture"}
            decoded[package_name] = (package, typed)
        package, typed = decoded[package_name]
        offset = int(offset_text, 16)
        if offset not in typed:
            raise ValueError("selection is not a typed texture object")
        planes = []
        for plane, texture in source_planes(package.file_info, offset, True):
            pixels = decode_wii_texture_rgba(package.file_info, texture)
            key = f"{texture.width}x{texture.height}-" + sha(pixels)
            if key not in manifest["textures"]:
                raise ValueError("unknown selected plane")
            if key in keys:
                if key not in declared_shared:
                    raise ValueError("shared selected plane requires explicit v2 shared treatment")
                repeated_keys.add(key)
            keys.add(key)
            record = manifest["textures"][key]
            png = no_links(manifest_path.parent / record["png"])
            if not png.is_relative_to(manifest_path.parent) or sha(png.read_bytes()) != record["png_sha256"]:
                raise ValueError("source PNG changed or escapes inventory")
            width, height, actual = read_png(png)
            if (width, height, actual) != (texture.width, texture.height, pixels) or \
                    (record["width"], record["height"], record["rgba8_sha256"]) != (width, height, sha(pixels)):
                raise ValueError("source pixels do not match original object")
            if any(alpha != 255 for alpha in pixels[3::4]):
                raise ValueError("alpha-bearing planes require a different treatment")
            occurrences = record.get("occurrences", [])
            matching = [row for row in occurrences if (row.get("package"), row.get("resource_offset"),
                row.get("plane")) == (package_name, offset_text, plane)]
            if len(matching) != 1:
                raise ValueError("missing or duplicate plane-qualified occurrence")
            expected = {"package_sha256": package.package_sha256, "format": texture.format_name,
                "format_code": texture.format_code, "wrap_s": texture.wrap_s, "wrap_t": texture.wrap_t,
                "mip_count": texture.payload_level_count, "encoded_level_sha256": texture.levels[0].sha256,
                "level_table_offset": f"0x{texture.level_table_offset:08x}"}
            if any(matching[0].get(field) != value for field, value in expected.items()):
                raise ValueError("source occurrence differs from original object")
            wraps = [texture.wrap_t, texture.wrap_s]
            if any(wrap not in {"repeat", "mirror", "clamp"} for wrap in wraps) or \
                    any([row.get("wrap_t"), row.get("wrap_s")] != wraps for row in occurrences):
                raise ValueError("mixed or unknown sampler modes require separate treatment")
            planes.append({"plane": plane, "source": key, "source_png": str(png),
                "source_png_sha256": record["png_sha256"], "dimensions": [width, height],
                "wrap_t_s": wraps, "occurrence": matching[0]})
        if entry.get("source_keys") != [plane["source"] for plane in planes]:
            raise ValueError("explicit ordered plane keys do not match complete source object")
        if len(planes) == 2 and entry.get("auxiliary") != "bicubic-rgb" or \
                len(planes) == 1 and entry.get("auxiliary") is not None:
            raise ValueError("explicit auxiliary RGB resampling required only for paired objects")
        dimensions = planes[0]["dimensions"]
        if any(plane["dimensions"] != dimensions for plane in planes):
            raise ValueError("paired source dimensions differ")
        primary_method = entry.get("primary", "learned")
        if not isinstance(primary_method, str) or primary_method not in {"learned", "source-bicubic"}:
            raise ValueError("primary treatment must be learned or source-bicubic")
        if primary_method == "learned":
            inference_padding(dimensions[1], dimensions[0])
        elif any(size < 1 or size > 512 or size & (size - 1) for size in dimensions):
            raise ValueError("source reconstruction requires power-of-two dimensions through 512")
        target = entry.get("target_long_edge")
        longest = max(dimensions)
        if type(target) is not int or target > 4096 or target < longest * 4 or target % (longest * 4):
            raise ValueError("target requires exact 4x then 2x steps, at most 4096")
        factor = target // (longest * 4)
        if factor & (factor - 1):
            raise ValueError("target requires power-of-two finishing steps")
        model_name = entry.get("model")
        model = config.get("models", {}).get(model_name, {})
        if primary_method == "learned" and (not model.get("source_url") or not model.get("license")):
            raise ValueError("model source and license are required")
        if primary_method == "learned" and model_name not in models_checked:
            no_links(pinned_file(recipe_path.parent, model, "weights", "sha256"))
            models_checked.add(model_name)
        if primary_method == "learned" and factor > 1 and not finisher_checked:
            finisher = config.get("finisher", {})
            if not finisher.get("source_url") or not finisher.get("license"):
                raise ValueError("finisher source and license are required")
            no_links(pinned_file(recipe_path.parent, finisher, "weights", "sha256"))
            finisher_checked = True
        for plane in planes:
            # A globally identified plane can have only one production result.
            # Primary/auxiliary roles are not interchangeable even when their
            # decoded pixels happen to be identical.
            treatment = (plane["plane"], tuple(plane["dimensions"]), tuple(plane["wrap_t_s"]),
                factor * 4, ((primary_method, model_name) if primary_method == "learned" else (primary_method, None))
                    if plane["plane"] == 0 else "bicubic-rgb")
            old = treatments.setdefault(plane["source"], treatment)
            if old != treatment:
                raise ValueError("shared plane has conflicting role, size, sampler or restoration treatment")
        planned.append({**entry, "planes": planes, "scale": factor * 4,
            "dimensions": [size * factor * 4 for size in dimensions],
            "finishing_passes": factor.bit_length() - 1})
    if repeated_keys != declared_shared:
        raise ValueError("shared plane declarations must match exactly the repeated selected identities")
    context = {"recipe": str(recipe_path), "recipe_sha256": sha(recipe_bytes),
        "sources": str(manifest_path), "sources_sha256": sha(manifest_bytes),
        "packages": [{"package": name, "sha256": value[0].package_sha256} for name, value in decoded.items()]}
    if declared_shared:
        context["shared_planes"] = sorted(declared_shared)
    return config, context, planned


def resample_auxiliary(rgb: np.ndarray, scale: int, wraps: list[str]) -> Image.Image:
    """Preserve all three channels and the initialized sampler, without thresholds."""
    border = 4  # More than the two-source-pixel bicubic filter radius.
    padded = padded_source(rgb, wraps, border)
    picture = Image.fromarray(np.rint(padded * 255).astype(np.uint8))
    picture = picture.resize((picture.width * scale, picture.height * scale), Image.Resampling.BICUBIC)
    return picture.crop((border * scale, border * scale,
        (border + rgb.shape[1]) * scale, (border + rgb.shape[0]) * scale))


def run(recipe_path: Path, output: Path, device: str = "mps", provider: str = "cpu", *, engines=None) -> dict:
    config, context, planned = plan(recipe_path, output)
    if engines is None and any(entry.get("primary", "learned") == "learned" for entry in planned):
        engines = LocalModels(config, Path(context["recipe"]).parent, device, provider)
    rendered, unique_pictures = [], {}
    for entry in planned:
        started, pictures = time.perf_counter(), []
        for plane in entry["planes"]:
            if plane["source"] in unique_pictures:
                pictures.append(unique_pictures[plane["source"]])
                continue
            with Image.open(plane["source_png"]) as image:
                rgb = np.asarray(image.convert("RGB"), dtype=np.float32) / 255
            if plane["plane"] == 0 and entry.get("primary", "learned") == "learned":
                pixels = checked_pixels(engines.first(entry["model"], rgb, plane["wrap_t_s"]),
                    rgb.shape[1] * 4, rgb.shape[0] * 4)
                for _ in range(entry["finishing_passes"]):
                    pixels = checked_pixels(engines.finish(pixels, plane["wrap_t_s"]),
                        pixels.shape[1] * 2, pixels.shape[0] * 2)
                picture = Image.fromarray(np.rint(pixels * 255).astype(np.uint8))
            else:
                picture = resample_auxiliary(rgb, entry["scale"], plane["wrap_t_s"])
            if list(picture.size) != entry["dimensions"]:
                raise ValueError("candidate dimensions differ from plan")
            unique_pictures[plane["source"]] = picture
            pictures.append(picture)
        rendered.append((entry, pictures, time.perf_counter() - started))
    # Nothing is published if sources, weights or recipe changed during inference.
    _, after, repeated = plan(recipe_path, output)
    if after != context or repeated != planned:
        raise ValueError("source or recipe changed during inference")
    destination = no_links(output)
    destination.mkdir(parents=True, exist_ok=False)
    result = {"schema": "protector-native.texture-object-restoration-receipt/v1",
        "status": "complete-candidates", "acceptance": "offline and native review required",
        "scope": "typed source-object identity only; no live draw, layout, adjacency or semantic-role proof",
        **context, "runtime": engines.metadata if engines is not None else
            {"method": "sampler-aware source reconstruction; no learned model loaded"}, "objects": []}
    pack_entries, candidates, selected_uses = [], {}, {}
    for entry in planned:
        for plane in entry["planes"]:
            selected_uses.setdefault(plane["source"], []).append({"name": entry["name"],
                "package": entry["package"], "resource_offset": entry["resource_offset"],
                "plane": plane["plane"], "source_occurrence": plane["occurrence"]})
    for entry, pictures, seconds in rendered:
        record = {"name": entry["name"], "package": entry["package"],
            "resource_offset": entry["resource_offset"], "dimensions": entry["dimensions"],
            "scale": entry["scale"], "seconds": seconds, "planes": []}
        for plane, picture in zip(entry["planes"], pictures, strict=True):
            if plane["source"] in candidates:
                record["planes"].append({**candidates[plane["source"]], "plane": plane["plane"],
                    "dimensions": entry["dimensions"], "reused_candidate": True,
                    "source_occurrence": plane["occurrence"]})
                continue
            learned = plane["plane"] == 0 and entry.get("primary", "learned") == "learned"
            method = ("one pinned local 4x RGB restoration and neutral 2x finishing steps"
                if learned else "sampler-aware bicubic source RGB resample; no threshold or learned detail"
                if plane["plane"] == 0 else "sampler-aware bicubic auxiliary RGB resample; no threshold or learned detail")
            origin = {"method": method, "recipe_sha256": context["recipe_sha256"],
                "source_key": plane["source"], "source_occurrence": plane["occurrence"],
                "source_manifest_sha256": context["sources_sha256"], "wrap_t_s": plane["wrap_t_s"],
                "scale": entry["scale"], "acceptance": result["acceptance"]}
            if learned:
                origin.update(model=config["models"][entry["model"]], finisher=config.get("finisher"),
                    finishing_passes=entry["finishing_passes"])
            if len(selected_uses[plane["source"]]) > 1:
                origin["shared_selected_objects"] = selected_uses[plane["source"]]
            metadata = PngImagePlugin.PngInfo()
            metadata.add_text("protector_origin", json.dumps(origin, sort_keys=True))
            metadata.add_text("impeccable:prompt", "Source origin (local restoration, no text prompt): " + json.dumps(origin, sort_keys=True))
            png = f"{entry['name']}-plane{plane['plane']}.png"
            picture.save(destination / png, pnginfo=metadata)
            candidate = {"source": plane["source"], "png": png, "png_sha256": sha((destination / png).read_bytes()),
                "treatment": "restore", "provenance": origin}
            candidates[plane["source"]] = candidate
            pack_entries.append(candidate)
            record["planes"].append({**candidate, "plane": plane["plane"], "dimensions": entry["dimensions"]})
        result["objects"].append(record)
        print(json.dumps({"name": record["name"], "dimensions": record["dimensions"], "planes": len(record["planes"]), "seconds": seconds}), flush=True)
    pack = {"schema": "protector-native.texture-pack-recipe/v1", "pack_id": config["pack_id"],
        "sources": context["sources"], "sources_sha256": context["sources_sha256"], "entries": pack_entries}
    for name, value in (("receipt.json", result), ("pack-recipe.json", pack)):
        with (destination / name).open("x") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    parser.add_argument("--provider", choices=("cpu", "coreml"), default="cpu")
    args = parser.parse_args()
    result = run(args.recipe, args.output, args.device, args.provider)
    print(json.dumps({"status": result["status"], "objects": len(result["objects"])}))


if __name__ == "__main__":
    main()

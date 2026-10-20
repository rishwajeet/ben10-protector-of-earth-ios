#!/usr/bin/env python3
"""Export source-hashed original textures for a non-destructive remaster pack.

This extracts artwork, not restored candidates. Originals and derived PNGs stay
outside Git. Repeated content has one PNG but retains every package occurrence.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from protector_native.bigb import parse_relocation_commands
from protector_native.textures import decode_wii_texture_rgba, encode_rgba_png, parse_wii_texture
from tools.audit_bigb import decode_package

DOL_SHA256 = "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_planes(file_info: bytes, offset: int, include_auxiliary: bool = False):
    """Enumerate initialized GX planes without interpreting their visual role.

    The source initializer uses +0x88 only for non-paletted textures. Do not
    confuse a shared constant primary plane with a unique complete image.
    """
    if type(offset) is not int or offset < 0:
        raise ValueError("texture resource offset must be a nonnegative integer")
    primary = parse_wii_texture(file_info, offset)
    result = [(0, primary)]
    if include_auxiliary and primary.format_code not in {8, 9} and \
            offset + 0x8C <= len(file_info) and struct.unpack_from(">I", file_info, offset + 0x88)[0]:
        result.append((1, parse_wii_texture(file_info, offset, plane=1)))
    return result


def prepare(data_root: Path, output: Path, packages: list[str] | None = None,
            *, include_auxiliary: bool = False) -> dict:
    source = data_root.resolve(strict=True)
    destination = output.resolve()
    if destination.is_relative_to(ROOT) or destination.is_relative_to(source):
        raise ValueError("texture output must be outside Git and the original dump")
    if output.is_symlink() or destination.exists():
        raise ValueError("texture output must be new; existing work is never overwritten")
    if digest((source / "sys/main.dol").read_bytes()) != DOL_SHA256:
        raise ValueError("texture restoration requires the pinned RBNEG9 dump")
    files = source / "files"
    if packages is None:
        inputs = sorted([*files.glob("*.gcm"), *files.glob("*.gcs")])
    else:
        if len(packages) != len(set(packages)):
            raise ValueError("duplicate package selection")
        if any(Path(name).name != name or Path(name).suffix not in {".gcm", ".gcs"}
               for name in packages):
            raise ValueError("package selections must be original .gcm/.gcs basenames")
        inputs = [files / name for name in packages]
    if not inputs or any(not path.is_file() for path in inputs):
        raise ValueError("no complete original package selection")
    destination.mkdir(parents=True)
    originals = destination / "originals"
    originals.mkdir()
    textures: dict[str, dict] = {}
    sources = []
    failures = []
    formats: Counter = Counter()
    for path in inputs:
        print(f"Extracting {path.name}", flush=True)
        try:
            package = decode_package(path)
            if package.header.magic != "BGIB" or package.header.endian != "big":
                raise ValueError("not a Wii BGIB package")
            commands = parse_relocation_commands(package.relocation, "big",
                file_info_size=len(package.file_info))
            offsets = sorted({c.destination_offset for c in commands if c.name == "texture"})
            records = []
            planes = [(offset, plane, texture) for offset in offsets
                      for plane, texture in source_planes(package.file_info, offset, include_auxiliary)]
            for offset, plane, texture in planes:
                rgba = decode_wii_texture_rgba(package.file_info, texture)
                pixel_hash = digest(rgba)
                key = f"{texture.width}x{texture.height}-{pixel_hash}"
                occurrence = {"package": path.name, "package_sha256": package.package_sha256,
                    "resource_offset": f"0x{offset:08x}", "format": texture.format_name,
                    "format_code": texture.format_code, "wrap_s": texture.wrap_s,
                    "wrap_t": texture.wrap_t, "mip_count": texture.payload_level_count,
                    "encoded_level_sha256": texture.levels[0].sha256}
                if include_auxiliary:
                    occurrence["plane"] = plane
                    occurrence["level_table_offset"] = f"0x{texture.level_table_offset:08x}"
                if key not in textures:
                    png = encode_rgba_png(texture.width, texture.height, rgba)
                    relative = f"originals/{key}.png"
                    with (destination / relative).open("xb") as stream:
                        stream.write(png)
                    alpha = rgba[3::4]
                    textures[key] = {"width": texture.width, "height": texture.height,
                        "rgba8_sha256": pixel_hash, "png": relative, "png_sha256": digest(png),
                        "alpha": {"min": min(alpha), "max": max(alpha),
                            "nonopaque_pixels": sum(a != 255 for a in alpha)},
                        "treatment": "unassigned", "occurrences": []}
                textures[key]["occurrences"].append(occurrence)
                formats[texture.format_name] += 1
                records.append(key)
            record = {"package": path.name, "sha256": package.package_sha256,
                "texture_count": len(records), "textures": records}
            if include_auxiliary:
                record["texture_object_count"] = len(offsets)
                record["texture_plane_count"] = len(records)
            sources.append(record)
        except (ValueError, OSError) as exc:
            failures.append({"package": path.name, "error": str(exc)})
    report = {"schema": "protector-native.texture-restoration-sources/v2" if include_auxiliary
            else "protector-native.texture-restoration-sources/v1",
        "title_dol_sha256": DOL_SHA256, "source_data_root": str(source),
        "scope": "original texture extraction; no restored or approved artwork",
        "package_count": len(inputs), "complete_packages": len(sources),
        "unique_texture_count": len(textures), "texture_occurrences": sum(formats.values()),
        "formats": dict(formats), "packages": sources, "textures": textures, "failures": failures}
    if include_auxiliary:
        report["scope"] = "original primary and initialized auxiliary GX planes; no semantic role or artwork approval inferred"
        report["includes_auxiliary_planes"] = True
    with (destination / "sources.json").open("x") as stream:
        stream.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--package", action="append", dest="packages")
    parser.add_argument("--include-auxiliary", action="store_true",
        help="Export initialized auxiliary GX planes with plane-qualified v2 occurrences")
    args = parser.parse_args()
    report = prepare(args.data_root, args.output, args.packages, include_auxiliary=args.include_auxiliary)
    print(json.dumps({key: report[key] for key in ("package_count", "complete_packages",
        "unique_texture_count", "texture_occurrences", "formats", "failures")}, indent=2))
    return int(bool(report["failures"]))


if __name__ == "__main__":
    raise SystemExit(main())

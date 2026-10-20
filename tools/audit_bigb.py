#!/usr/bin/env python3
"""Audit High Voltage BIGB/BGIB asset packages used by Protector of Earth.

The PS2 packages are little-endian BIGB files. Wii packages contain the same
container in big-endian BGIB form. This tool parses both, validates and expands
the two compressed metadata blocks, and optionally dumps those blocks outside
the source repository for further format research.

Format observations were independently cross-checked against public R4S
research by barncastle:
https://gist.github.com/barncastle/c418ab984e7588f43a453eeb10a038f0
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from protector_native.bigb import relocation_manifest

DESCRIPTION_SIZE = 0x40
AUTHOR_SIZE = 0x2C
BUILD_ARGS_SIZE = 0x104
SECTOR_SIZE = 0x800


@dataclass(frozen=True)
class Header:
    magic: str
    endian: str
    data_offset: int
    version: int
    header_flag: int
    description: str
    author: str
    audio_stream_size: int
    audio_file_size: int
    file_info_decompressed_size: int
    relocation_decompressed_size: int
    file_info_stored_size: int
    relocation_stored_size: int
    build_args: str
    memory_stream_size: int
    compressed_block_end_sector: int
    compressed_block_end_offset: int


@dataclass(frozen=True)
class DecodedPackage:
    header: Header
    file_info: bytes
    relocation: bytes
    memory_stream: bytes
    audio_stream: bytes
    audio_files: bytes
    metadata_decode_end: int
    meaningful_end: int
    package_size: int
    package_sha256: str


def decode_fixed_string(value: bytes) -> str:
    if value and value[0] < 0x20:
        value = value[1:]
    value = value.split(b"\0", 1)[0]
    return value.decode("utf-8", errors="replace")


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def read_u32(data: bytes, offset: int, endian: str) -> tuple[int, int]:
    if offset + 4 > len(data):
        raise ValueError(f"unexpected end of package at 0x{offset:x}")
    return struct.unpack_from(f"{endian}I", data, offset)[0], offset + 4


def parse_header(data: bytes) -> Header:
    if len(data) < 0x1A0:
        raise ValueError("package is too short for a BIGB header")

    raw_magic = data[:4]
    if raw_magic == b"BIGB":
        magic, endian = "BIGB", "<"
    elif raw_magic == b"BGIB":
        magic, endian = "BGIB", ">"
    else:
        raise ValueError(f"unsupported package magic: {raw_magic!r}")

    offset = 4
    data_offset, offset = read_u32(data, offset, endian)
    version, offset = read_u32(data, offset, endian)
    header_flag, offset = read_u32(data, offset, endian)

    description = decode_fixed_string(data[offset : offset + DESCRIPTION_SIZE])
    offset += DESCRIPTION_SIZE
    author = decode_fixed_string(data[offset : offset + AUTHOR_SIZE])
    offset += AUTHOR_SIZE

    audio_stream_size, offset = read_u32(data, offset, endian)
    audio_file_size, offset = read_u32(data, offset, endian)
    file_info_decompressed_size, offset = read_u32(data, offset, endian)
    relocation_decompressed_size, offset = read_u32(data, offset, endian)
    file_info_stored_size, offset = read_u32(data, offset, endian)
    relocation_stored_size, offset = read_u32(data, offset, endian)

    build_args = decode_fixed_string(data[offset : offset + BUILD_ARGS_SIZE])
    if not 0x100 <= data_offset <= len(data) - 16:
        raise ValueError(f"invalid data offset: 0x{data_offset:x}")

    offset = data_offset
    _, offset = read_u32(data, offset, endian)
    _, offset = read_u32(data, offset, endian)
    memory_stream_size, offset = read_u32(data, offset, endian)
    compressed_block_end_sector, offset = read_u32(data, offset, endian)
    compressed_block_end_offset = compressed_block_end_sector * SECTOR_SIZE

    if compressed_block_end_offset > len(data):
        raise ValueError(
            "compressed block end exceeds package: "
            f"0x{compressed_block_end_offset:x} > 0x{len(data):x}"
        )

    return Header(
        magic=magic,
        endian="little" if endian == "<" else "big",
        data_offset=data_offset,
        version=version,
        header_flag=header_flag,
        description=description,
        author=author,
        audio_stream_size=audio_stream_size,
        audio_file_size=audio_file_size,
        file_info_decompressed_size=file_info_decompressed_size,
        relocation_decompressed_size=relocation_decompressed_size,
        file_info_stored_size=file_info_stored_size,
        relocation_stored_size=relocation_stored_size,
        build_args=build_args,
        memory_stream_size=memory_stream_size,
        compressed_block_end_sector=compressed_block_end_sector,
        compressed_block_end_offset=compressed_block_end_offset,
    )


def decompress_block(
    data: bytes, offset: int, stored_size: int, output_size: int
) -> tuple[bytes, int]:
    if stored_size == 0:
        end = offset + output_size
        if end > len(data):
            raise ValueError("uncompressed metadata block exceeds package")
        return data[offset:end], end

    input_end = offset + stored_size
    if input_end > len(data):
        raise ValueError("compressed metadata block exceeds package")

    output = bytearray()
    cursor = offset
    while len(output) < output_size:
        if cursor >= input_end:
            raise ValueError("compressed metadata ended before output was complete")

        command = data[cursor]
        cursor += 1
        if command & 0x80:
            if cursor >= input_end:
                raise ValueError("truncated BIGB back-reference")
            temporary = data[cursor]
            cursor += 1
            count = (temporary & 0x0F) + 2
            distance = (((command << 4) | (temporary >> 4)) ^ 0xFFF) + 2
            if distance > len(output):
                raise ValueError(
                    f"invalid BIGB back-reference distance {distance} "
                    f"at output offset 0x{len(output):x}"
                )
            for _ in range(count):
                output.append(output[-distance])
        elif command & 0x40:
            if cursor >= input_end:
                raise ValueError("truncated BIGB run")
            value = data[cursor]
            cursor += 1
            output.extend([value] * ((command & 0x3F) + 2))
        else:
            count = (command & 0x3F) + 1
            if cursor + count > input_end:
                raise ValueError("truncated BIGB literal")
            output.extend(data[cursor : cursor + count])
            cursor += count

        if len(output) > output_size:
            raise ValueError("BIGB decompression exceeded declared output size")

    return bytes(output), input_end


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def scan_markers(value: bytes) -> dict[str, int]:
    markers = (
        b"RIFF",
        b"FFIR",
        b"WAVE",
        b"EVAW",
        b"WAVS",
        b"SVAW",
        b"geom",
        b"moeg",
        b"data",
        b"atad",
        b"mstr",
        b"rtsm",
        b"enva",
        b"avne",
    )
    return {
        marker.decode("ascii"): value.count(marker)
        for marker in markers
        if value.count(marker)
    }


def relocation_summary(value: bytes, endian: str) -> dict[str, object]:
    return relocation_manifest(value, endian)


def safe_write(destination: Path, value: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.partial")
    temporary.write_bytes(value)
    temporary.replace(destination)


def decode_package(package_path: Path) -> DecodedPackage:
    data = package_path.read_bytes()
    header = parse_header(data)

    cursor = header.data_offset + 16
    file_info, cursor = decompress_block(
        data,
        cursor,
        header.file_info_stored_size,
        header.file_info_decompressed_size,
    )
    relocation, cursor = decompress_block(
        data,
        cursor,
        header.relocation_stored_size,
        header.relocation_decompressed_size,
    )
    metadata_decode_end = cursor
    if cursor > header.compressed_block_end_offset:
        raise ValueError("compressed blocks extend beyond declared block end")

    cursor = header.compressed_block_end_offset
    memory_end = cursor + header.memory_stream_size
    memory_stream = data[cursor:memory_end]
    if len(memory_stream) != header.memory_stream_size:
        raise ValueError("truncated memory stream")

    cursor = align(memory_end, SECTOR_SIZE)
    audio_stream_end = cursor + header.audio_stream_size
    audio_stream = data[cursor:audio_stream_end]
    if len(audio_stream) != header.audio_stream_size:
        raise ValueError("truncated audio stream")

    cursor = align(audio_stream_end, SECTOR_SIZE)
    audio_file_end = cursor + header.audio_file_size
    audio_files = data[cursor:audio_file_end]
    if len(audio_files) != header.audio_file_size:
        raise ValueError("truncated audio-file stream")

    return DecodedPackage(
        header=header,
        file_info=file_info,
        relocation=relocation,
        memory_stream=memory_stream,
        audio_stream=audio_stream,
        audio_files=audio_files,
        metadata_decode_end=metadata_decode_end,
        meaningful_end=audio_file_end,
        package_size=len(data),
        package_sha256=sha256(data),
    )


def audit(package_path: Path, dump_dir: Path | None) -> dict[str, object]:
    package = decode_package(package_path)
    header = package.header
    file_info = package.file_info
    relocation = package.relocation
    memory_stream = package.memory_stream
    audio_stream = package.audio_stream
    audio_files = package.audio_files
    endian = "<" if header.endian == "little" else ">"

    if dump_dir:
        stem = package_path.name
        safe_write(dump_dir / f"{stem}.file_info.bin", file_info)
        safe_write(dump_dir / f"{stem}.relocation.bin", relocation)
        if memory_stream:
            safe_write(dump_dir / f"{stem}.memory_stream.bin", memory_stream)
        if audio_stream:
            safe_write(dump_dir / f"{stem}.audio_stream.bin", audio_stream)
        if audio_files:
            safe_write(dump_dir / f"{stem}.audio_files.bin", audio_files)

    return {
        "path": str(package_path.resolve()),
        "package_size": package.package_size,
        "package_sha256": package.package_sha256,
        "header": asdict(header),
        "blocks": {
            "file_info": {
                "size": len(file_info),
                "sha256": sha256(file_info),
                "markers": scan_markers(file_info),
            },
            "relocation": {
                "size": len(relocation),
                "sha256": sha256(relocation),
                **relocation_manifest(
                    relocation,
                    header.endian,
                    file_info_size=len(file_info),
                ),
            },
            "memory_stream": {
                "size": len(memory_stream),
                "sha256": sha256(memory_stream),
                "markers": scan_markers(memory_stream),
            },
            "audio_stream": {
                "size": len(audio_stream),
                "sha256": sha256(audio_stream),
            },
            "audio_files": {
                "size": len(audio_files),
                "sha256": sha256(audio_files),
                "markers": scan_markers(audio_files),
            },
        },
        "layout": {
            "metadata_cursor_after_decode": package.metadata_decode_end,
            "meaningful_end": package.meaningful_end,
            "package_padding": package.package_size - package.meaningful_end,
            "numeric_endian_prefix": endian,
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="Path to .psm/.pss/.gcm/.gcs")
    parser.add_argument(
        "--dump-dir",
        type=Path,
        help="Optional block output directory; keep outside the source repository",
    )
    parser.add_argument("--manifest", type=Path, help="Optional JSON manifest path")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    result = audit(args.package, args.dump_dir)
    if args.manifest:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

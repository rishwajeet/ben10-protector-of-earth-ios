"""Wii texture records and dependency-free preview output."""

from __future__ import annotations

import binascii
import hashlib
import struct
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path

TEXTURE_SCHEMA = "protector-native.texture/wii-v1"

GX_TEXTURE_FORMATS = {
    0: "I4",
    1: "I8",
    2: "IA4",
    3: "IA8",
    4: "RGB565",
    5: "RGB5A3",
    6: "RGBA8",
    8: "C4",
    9: "C8",
    10: "C14X2",
    14: "CMPR",
}

GX_WRAP_MODES = {
    0: "clamp",
    1: "repeat",
    2: "mirror",
}

GX_FILTER_MODES = {
    0: "nearest",
    1: "linear",
    2: "nearest_mipmap_nearest",
    3: "linear_mipmap_nearest",
    4: "nearest_mipmap_linear",
    5: "linear_mipmap_linear",
}


class TextureError(ValueError):
    """Raised when a serialized texture record is inconsistent."""


@dataclass(frozen=True)
class TextureLevel:
    level: int
    width: int
    height: int
    data_offset: int
    stored_size: int
    expected_size: int
    sha256: str


@dataclass(frozen=True)
class TexturePalette:
    format_code: int
    format_name: str
    entry_count: int
    data_offset: int
    stored_size: int
    sha256: str


@dataclass(frozen=True)
class WiiTexture:
    schema: str
    resource_offset: int
    width: int
    height: int
    format_code: int
    format_name: str
    wrap_s_code: int
    wrap_s: str
    wrap_t_code: int
    wrap_t: str
    table_entry_count: int
    payload_level_count: int
    min_filter_code: int
    min_filter: str
    mag_filter_code: int
    mag_filter: str
    lod_bias: float
    level_table_offset: int
    palette: TexturePalette | None
    levels: tuple[TextureLevel, ...]

    def to_dict(self) -> dict[str, object]:
        result = asdict(self)
        for key in ("resource_offset", "level_table_offset"):
            result[key] = f"0x{result[key]:08x}"
        for level in result["levels"]:
            level["data_offset"] = f"0x{level['data_offset']:08x}"
        if result["palette"] is not None:
            result["palette"]["data_offset"] = (
                f"0x{result['palette']['data_offset']:08x}"
            )
        return result


def _u16(value: bytes, offset: int) -> int:
    if offset + 2 > len(value):
        raise TextureError(f"texture field exceeds file-info at 0x{offset:x}")
    return struct.unpack_from(">H", value, offset)[0]


def _u32(value: bytes, offset: int) -> int:
    if offset + 4 > len(value):
        raise TextureError(f"texture field exceeds file-info at 0x{offset:x}")
    return struct.unpack_from(">I", value, offset)[0]


def _f32(value: bytes, offset: int) -> float:
    if offset + 4 > len(value):
        raise TextureError(f"texture field exceeds file-info at 0x{offset:x}")
    return struct.unpack_from(">f", value, offset)[0]


def _align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def expected_level_size(format_code: int, width: int, height: int) -> int:
    """Return the GX tiled storage size for one texture level."""

    if width < 1 or height < 1:
        raise TextureError(f"invalid texture dimensions: {width}x{height}")
    if format_code in {0, 8, 14}:
        return _align(width, 8) * _align(height, 8) // 2
    if format_code in {1, 2, 9}:
        return _align(width, 8) * _align(height, 4)
    if format_code in {3, 4, 5, 10}:
        return _align(width, 4) * _align(height, 4) * 2
    if format_code == 6:
        return _align(width, 4) * _align(height, 4) * 4
    raise TextureError(f"unsupported GX texture format: {format_code}")


def parse_wii_texture(file_info: bytes, resource_offset: int, *, plane: int = 0) -> WiiTexture:
    """Parse one GX plane from a relocated Wii texture object.

    RBNEG9's initializer at 0x80030D34 binds the primary table at +0x84 and,
    for non-paletted textures, an optional second table at +0x88. Both use
    the same dimensions, format, mip count and sampler. The shader determines
    whether the second plane is an alpha mask; its green pixels alone do not.
    Default plane zero preserves the existing source-export identities.
    """

    if type(plane) is not int or plane not in {0, 1}:
        raise TextureError("texture plane must be zero or one")
    if resource_offset % 4:
        raise TextureError(f"unaligned texture resource: 0x{resource_offset:x}")
    if resource_offset + 0x88 + plane * 4 > len(file_info):
        raise TextureError(f"texture header at 0x{resource_offset:x} exceeds file-info")

    width = _u32(file_info, resource_offset + 0x04)
    height = _u32(file_info, resource_offset + 0x08)
    format_code = _u32(file_info, resource_offset + 0x78)
    table_entry_count = _u16(file_info, resource_offset + 0x7C)
    min_filter_code = _u16(file_info, resource_offset + 0x7E)
    level_table_offset = _u32(file_info, resource_offset + 0x84 + plane * 4)
    wrap_s_code = _u32(file_info, resource_offset + 0x68)
    wrap_t_code = _u32(file_info, resource_offset + 0x6C)
    lod_bias = _f32(file_info, resource_offset + 0x80)

    if width > 8192 or height > 8192:
        raise TextureError(f"implausible texture dimensions: {width}x{height}")
    if format_code not in GX_TEXTURE_FORMATS:
        raise TextureError(f"unknown GX texture format: {format_code}")
    if plane and (not level_table_offset or format_code in {8, 9}):
        raise TextureError("texture has no initialized auxiliary GX plane")
    if table_entry_count < 1 or table_entry_count > 16:
        raise TextureError(f"implausible texture table count: {table_entry_count}")
    table_end = level_table_offset + table_entry_count * 8
    if level_table_offset % 4 or table_end > len(file_info):
        raise TextureError(
            f"texture level table 0x{level_table_offset:x}.."
            f"0x{table_end:x} exceeds file-info"
        )

    palette: TexturePalette | None = None
    if format_code in {8, 9}:
        palette_offset = _u32(file_info, resource_offset + 0x74)
        palette_count = 16 if format_code == 8 else 256
        palette_size = palette_count * 2
        palette_end = palette_offset + palette_size
        if palette_offset % 0x20 or palette_end > len(file_info):
            raise TextureError(
                f"texture palette 0x{palette_offset:x}..0x{palette_end:x} "
                "is unaligned or exceeds file-info"
            )
        palette = TexturePalette(
            format_code=2,
            format_name="RGB5A3",
            entry_count=palette_count,
            data_offset=palette_offset,
            stored_size=palette_size,
            sha256=hashlib.sha256(file_info[palette_offset:palette_end]).hexdigest(),
        )

    levels: list[TextureLevel] = []
    saw_zero_sentinel = False
    for level in range(table_entry_count):
        data_offset = _u32(file_info, level_table_offset + level * 8)
        stored_size = _u32(file_info, level_table_offset + level * 8 + 4)
        level_width = max(1, width >> level)
        level_height = max(1, height >> level)
        expected_size = expected_level_size(format_code, level_width, level_height)

        if stored_size == 0:
            if level != table_entry_count - 1:
                raise TextureError("zero-sized texture level is not final")
            saw_zero_sentinel = True
            digest = hashlib.sha256(b"").hexdigest()
        else:
            data_end = data_offset + stored_size
            if data_offset % 0x20 or data_end > len(file_info):
                raise TextureError(
                    f"texture payload 0x{data_offset:x}..0x{data_end:x} "
                    "is unaligned or exceeds file-info"
                )
            if stored_size != expected_size:
                raise TextureError(
                    f"texture level {level} has size 0x{stored_size:x}; "
                    f"expected 0x{expected_size:x}"
                )
            digest = hashlib.sha256(file_info[data_offset:data_end]).hexdigest()

        levels.append(
            TextureLevel(
                level=level,
                width=level_width,
                height=level_height,
                data_offset=data_offset,
                stored_size=stored_size,
                expected_size=expected_size,
                sha256=digest,
            )
        )

    payload_level_count = table_entry_count - int(saw_zero_sentinel)
    return WiiTexture(
        schema=TEXTURE_SCHEMA,
        resource_offset=resource_offset,
        width=width,
        height=height,
        format_code=format_code,
        format_name=GX_TEXTURE_FORMATS[format_code],
        wrap_s_code=wrap_s_code,
        wrap_s=GX_WRAP_MODES.get(wrap_s_code, f"unknown_{wrap_s_code}"),
        wrap_t_code=wrap_t_code,
        wrap_t=GX_WRAP_MODES.get(wrap_t_code, f"unknown_{wrap_t_code}"),
        table_entry_count=table_entry_count,
        payload_level_count=payload_level_count,
        min_filter_code=min_filter_code,
        min_filter=GX_FILTER_MODES.get(min_filter_code, f"unknown_{min_filter_code}"),
        mag_filter_code=1,
        mag_filter=GX_FILTER_MODES[1],
        lod_bias=lod_bias,
        level_table_offset=level_table_offset,
        palette=palette,
        levels=tuple(levels),
    )


def _rgb565(value: int) -> tuple[int, int, int]:
    red = (value >> 11) & 0x1F
    green = (value >> 5) & 0x3F
    blue = value & 0x1F
    return (
        (red << 3) | (red >> 2),
        (green << 2) | (green >> 4),
        (blue << 3) | (blue >> 2),
    )


def _mix(
    first: tuple[int, int, int], second: tuple[int, int, int], a: int, b: int
) -> tuple[int, int, int, int]:
    divisor = a + b
    return (
        (first[0] * a + second[0] * b) // divisor,
        (first[1] * a + second[1] * b) // divisor,
        (first[2] * a + second[2] * b) // divisor,
        255,
    )


def decode_cmpr(data: bytes, width: int, height: int) -> bytes:
    """Decode Nintendo GX CMPR tiles into row-major RGBA8 pixels."""

    expected = expected_level_size(14, width, height)
    if len(data) != expected:
        raise TextureError(
            f"CMPR payload size is 0x{len(data):x}; expected 0x{expected:x}"
        )

    output = bytearray(width * height * 4)
    cursor = 0
    for tile_y in range(0, _align(height, 8), 8):
        for tile_x in range(0, _align(width, 8), 8):
            for block_index in range(4):
                block = data[cursor : cursor + 8]
                cursor += 8
                color_zero, color_one = struct.unpack_from(">HH", block, 0)
                rgb_zero = _rgb565(color_zero)
                rgb_one = _rgb565(color_one)
                palette = [
                    (*rgb_zero, 255),
                    (*rgb_one, 255),
                ]
                if color_zero > color_one:
                    palette.extend(
                        [
                            _mix(rgb_zero, rgb_one, 2, 1),
                            _mix(rgb_zero, rgb_one, 1, 2),
                        ]
                    )
                else:
                    palette.extend(
                        [
                            _mix(rgb_zero, rgb_one, 1, 1),
                            (0, 0, 0, 0),
                        ]
                    )

                block_x = tile_x + (block_index & 1) * 4
                block_y = tile_y + (block_index >> 1) * 4
                for local_y in range(4):
                    indices = block[4 + local_y]
                    for local_x in range(4):
                        x = block_x + local_x
                        y = block_y + local_y
                        if x >= width or y >= height:
                            continue
                        palette_index = (indices >> (6 - local_x * 2)) & 3
                        destination = (y * width + x) * 4
                        output[destination : destination + 4] = bytes(
                            palette[palette_index]
                        )
    return bytes(output)


def _rgb5a3(value: int) -> tuple[int, int, int, int]:
    if value & 0x8000:
        red = (value >> 10) & 0x1F
        green = (value >> 5) & 0x1F
        blue = value & 0x1F
        return (
            (red << 3) | (red >> 2),
            (green << 3) | (green >> 2),
            (blue << 3) | (blue >> 2),
            255,
        )
    alpha = (value >> 12) & 0x7
    red = (value >> 8) & 0xF
    green = (value >> 4) & 0xF
    blue = value & 0xF
    return (
        (red << 4) | red,
        (green << 4) | green,
        (blue << 4) | blue,
        (alpha << 5) | (alpha << 2) | (alpha >> 1),
    )


def decode_direct(
    data: bytes,
    width: int,
    height: int,
    format_code: int,
) -> bytes:
    """Decode a non-paletted GX texture into row-major RGBA8 pixels."""

    if format_code not in {0, 1, 2, 3, 4, 5, 6}:
        raise TextureError(f"unsupported direct format: {format_code}")
    expected = expected_level_size(format_code, width, height)
    if len(data) != expected:
        raise TextureError(
            f"direct payload size is 0x{len(data):x}; expected 0x{expected:x}"
        )

    block_sizes = {
        0: (8, 8),
        1: (8, 4),
        2: (8, 4),
        3: (4, 4),
        4: (4, 4),
        5: (4, 4),
        6: (4, 4),
    }
    block_width, block_height = block_sizes[format_code]
    block_bytes = 64 if format_code == 6 else 32
    output = bytearray(width * height * 4)
    cursor = 0
    for tile_y in range(0, _align(height, block_height), block_height):
        for tile_x in range(0, _align(width, block_width), block_width):
            tile = data[cursor : cursor + block_bytes]
            cursor += block_bytes
            for local_y in range(block_height):
                for local_x in range(block_width):
                    pixel = local_y * block_width + local_x
                    if format_code == 0:
                        packed = tile[pixel // 2]
                        intensity = (
                            packed >> 4 if pixel % 2 == 0 else packed & 0xF
                        )
                        intensity = (intensity << 4) | intensity
                        rgba = (intensity, intensity, intensity, intensity)
                    elif format_code == 1:
                        intensity = tile[pixel]
                        rgba = (intensity, intensity, intensity, intensity)
                    elif format_code == 2:
                        packed = tile[pixel]
                        alpha = packed >> 4
                        intensity = packed & 0xF
                        rgba = (
                            (intensity << 4) | intensity,
                            (intensity << 4) | intensity,
                            (intensity << 4) | intensity,
                            (alpha << 4) | alpha,
                        )
                    elif format_code == 3:
                        alpha = tile[pixel * 2]
                        intensity = tile[pixel * 2 + 1]
                        rgba = (intensity, intensity, intensity, alpha)
                    elif format_code == 4:
                        rgba = (
                            *_rgb565(
                                struct.unpack_from(">H", tile, pixel * 2)[0]
                            ),
                            255,
                        )
                    elif format_code == 5:
                        rgba = _rgb5a3(
                            struct.unpack_from(">H", tile, pixel * 2)[0]
                        )
                    else:
                        alpha = tile[pixel * 2]
                        red = tile[pixel * 2 + 1]
                        green = tile[32 + pixel * 2]
                        blue = tile[32 + pixel * 2 + 1]
                        rgba = (red, green, blue, alpha)
                    x = tile_x + local_x
                    y = tile_y + local_y
                    if x >= width or y >= height:
                        continue
                    destination = (y * width + x) * 4
                    output[destination : destination + 4] = bytes(rgba)
    return bytes(output)


def decode_indexed(
    data: bytes,
    palette_data: bytes,
    width: int,
    height: int,
    format_code: int,
    palette_format: int = 2,
) -> bytes:
    if format_code not in {8, 9}:
        raise TextureError(f"unsupported indexed format: {format_code}")
    expected = expected_level_size(format_code, width, height)
    if len(data) != expected:
        raise TextureError(
            f"indexed payload size is 0x{len(data):x}; expected 0x{expected:x}"
        )
    entry_count = 16 if format_code == 8 else 256
    if len(palette_data) != entry_count * 2:
        raise TextureError("RGB5A3 palette has the wrong size")
    if palette_format not in {0, 1, 2}:
        raise TextureError(f"unsupported GX palette format: {palette_format}")
    palette: list[tuple[int, int, int, int]] = []
    for index in range(entry_count):
        value = struct.unpack_from(">H", palette_data, index * 2)[0]
        if palette_format == 0:
            alpha = value >> 8
            intensity = value & 0xFF
            palette.append((intensity, intensity, intensity, alpha))
        elif palette_format == 1:
            palette.append((*_rgb565(value), 255))
        else:
            palette.append(_rgb5a3(value))

    block_width, block_height = (8, 8) if format_code == 8 else (8, 4)
    output = bytearray(width * height * 4)
    cursor = 0
    for tile_y in range(0, _align(height, block_height), block_height):
        for tile_x in range(0, _align(width, block_width), block_width):
            tile = data[cursor : cursor + 32]
            cursor += 32
            for local_y in range(block_height):
                for local_x in range(block_width):
                    pixel = local_y * block_width + local_x
                    if format_code == 8:
                        packed = tile[pixel // 2]
                        palette_index = packed >> 4 if pixel % 2 == 0 else packed & 0xF
                    else:
                        palette_index = tile[pixel]
                    x = tile_x + local_x
                    y = tile_y + local_y
                    if x >= width or y >= height:
                        continue
                    destination = (y * width + x) * 4
                    output[destination : destination + 4] = bytes(
                        palette[palette_index]
                    )
    return bytes(output)


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    return (
        struct.pack(">I", len(payload))
        + body
        + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)
    )


def encode_rgba_png(width: int, height: int, rgba: bytes) -> bytes:
    if len(rgba) != width * height * 4:
        raise TextureError("RGBA payload does not match dimensions")
    scanlines = b"".join(
        b"\0" + rgba[row * width * 4 : (row + 1) * width * 4] for row in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + _png_chunk(b"IDAT", zlib.compress(scanlines, level=9))
        + _png_chunk(b"IEND", b"")
    )


def decode_wii_texture_rgba(
    file_info: bytes, texture: WiiTexture, *, level: int = 0
) -> bytes:
    """Decode one admitted level with the same RGBA semantics as live GX.

    I4/I8 put intensity in alpha as well as RGB. Keeping that channel is
    necessary for both faithful previews and content-addressed replacements.
    """
    if level < 0 or level >= texture.payload_level_count:
        raise TextureError(f"texture level is unavailable: {level}")
    selected = texture.levels[level]
    payload = file_info[
        selected.data_offset : selected.data_offset + selected.stored_size
    ]
    if texture.format_code == 14:
        return decode_cmpr(payload, selected.width, selected.height)
    elif texture.format_code in {8, 9}:
        if texture.palette is None:
            raise TextureError("indexed texture has no palette")
        palette_data = file_info[
            texture.palette.data_offset : texture.palette.data_offset
            + texture.palette.stored_size
        ]
        return decode_indexed(
            payload,
            palette_data,
            selected.width,
            selected.height,
            texture.format_code,
            texture.palette.format_code,
        )
    return decode_direct(payload, selected.width, selected.height, texture.format_code)


def export_wii_texture_png(
    file_info: bytes, texture: WiiTexture, destination: Path, *, level: int = 0
) -> None:
    rgba = decode_wii_texture_rgba(file_info, texture, level=level)
    selected = texture.levels[level]
    png = encode_rgba_png(selected.width, selected.height, rgba)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.partial")
    temporary.write_bytes(png)
    temporary.replace(destination)

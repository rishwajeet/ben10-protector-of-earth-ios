"""Wii timed texture sequences and UV-animation resources."""

from __future__ import annotations

import hashlib
import math
import struct
from collections.abc import Iterable
from dataclasses import asdict, dataclass

from protector_native.bigb import RelocationCommand

DYNAMIC_MATERIAL_SCHEMA = "protector-native.dynamic-material/wii-v1"
TEXTURE_FRAME_SEQUENCE_SIZE = 0x20
TEXTURE_UV_ANIMATION_SIZE = 0x98
TEXTURE_UV_TRACK_SIZE = 0x30


class DynamicMaterialError(ValueError):
    """Raised when a dynamic material violates the Wii executable layout."""


def _hex(value: int) -> str:
    return f"0x{value:08x}"


def _stable_id(package_sha256: str, kind: str, offset: int) -> str:
    return f"sha256:{package_sha256}/{kind}@0x{offset:08x}"


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or offset + size > len(value):
        raise DynamicMaterialError(
            f"{label} range 0x{offset:x}..0x{offset + size:x} "
            f"exceeds file-info size 0x{len(value):x}"
        )


def _u16(value: bytes, offset: int) -> int:
    _require_range(value, offset, 2, "u16")
    return struct.unpack_from(">H", value, offset)[0]


def _u32(value: bytes, offset: int) -> int:
    _require_range(value, offset, 4, "u32")
    return struct.unpack_from(">I", value, offset)[0]


def _f32(value: bytes, offset: int) -> float:
    _require_range(value, offset, 4, "f32")
    result = struct.unpack_from(">f", value, offset)[0]
    if not math.isfinite(result):
        raise DynamicMaterialError(f"non-finite dynamic-material float at 0x{offset:x}")
    return result


@dataclass(frozen=True)
class TextureFrame:
    index: int
    pointer_field: int
    texture_offset: int
    texture_identity: str

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["pointer_field"] = _hex(self.pointer_field)
        value["texture_offset"] = _hex(self.texture_offset)
        return value


@dataclass(frozen=True)
class TextureFrameSequence:
    offset: int
    identity: str
    header_offset: int
    frame_array_offset: int
    frames: tuple[TextureFrame, ...]
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "offset": _hex(self.offset),
            "identity": self.identity,
            "header_offset": _hex(self.header_offset),
            "frame_array_offset": _hex(self.frame_array_offset),
            "frame_count": len(self.frames),
            "frames": [frame.to_dict() for frame in self.frames],
            "raw_sha256": self.raw_sha256,
        }


@dataclass(frozen=True)
class TextureUVTrack:
    index: int
    offset: int
    texture_offset: int
    texture_identity: str
    u_amplitude: float
    v_amplitude: float
    word_0c: int
    word_10: int
    word_14: int
    u_mode: int
    v_mode: int
    coordinate_slot: int
    u_frequency: float
    v_frequency: float
    u_phase: float
    v_phase: float
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        for field in ("offset", "texture_offset", "word_0c", "word_10", "word_14"):
            value[field] = _hex(value[field])
        return value


@dataclass(frozen=True)
class TextureUVAnimation:
    offset: int
    identity: str
    track_array_offset: int
    tracks: tuple[TextureUVTrack, ...]
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "offset": _hex(self.offset),
            "identity": self.identity,
            "track_array_offset": _hex(self.track_array_offset),
            "track_count": len(self.tracks),
            "tracks": [track.to_dict() for track in self.tracks],
            "raw_sha256": self.raw_sha256,
        }


def parse_wii_dynamic_materials(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> tuple[tuple[TextureFrameSequence, ...], tuple[TextureUVAnimation, ...]]:
    """Parse resource slots 05 and 06 using their Wii vtable behavior."""

    command_list = tuple(commands)
    pointer_fields = {
        command.destination_offset
        for command in command_list
        if command.name == "file_info_pointer"
    }
    resource_targets = {
        command.destination_offset: command.name
        for command in command_list
        if command.kind == "resource_reference"
    }
    sequence_offsets = tuple(
        command.destination_offset
        for command in command_list
        if command.name == "texture_frame_sequence"
    )
    uv_offsets = tuple(
        command.destination_offset
        for command in command_list
        if command.name == "texture_uv_animation"
    )
    if any(offset is None for offset in sequence_offsets + uv_offsets):
        raise DynamicMaterialError("dynamic-material command lacks a destination")

    sequences: list[TextureFrameSequence] = []
    for offset_or_none in sequence_offsets:
        assert offset_or_none is not None
        offset = offset_or_none
        _require_range(
            file_info, offset, TEXTURE_FRAME_SEQUENCE_SIZE, "texture sequence"
        )
        header_field = offset + 0x18
        if header_field not in pointer_fields:
            raise DynamicMaterialError(
                f"texture sequence 0x{offset:x} lacks a header pointer"
            )
        header = _u32(file_info, header_field)
        _require_range(file_info, header, 0x10, "texture sequence header")
        frame_count = _u32(file_info, header)
        frame_array_field = header + 4
        if frame_array_field not in pointer_fields:
            raise DynamicMaterialError(
                f"texture sequence header 0x{header:x} lacks an array pointer"
            )
        frame_array = _u32(file_info, frame_array_field)
        _require_range(
            file_info, frame_array, frame_count * 4, "texture frame pointers"
        )
        frames: list[TextureFrame] = []
        for index in range(frame_count):
            field = frame_array + index * 4
            if field not in pointer_fields:
                raise DynamicMaterialError(
                    f"texture frame field 0x{field:x} lacks a relocation"
                )
            target = _u32(file_info, field)
            target_kind = resource_targets.get(target)
            if target_kind != "texture":
                raise DynamicMaterialError(
                    f"texture frame {index} targets {target_kind!r} at 0x{target:x}"
                )
            frames.append(
                TextureFrame(
                    index=index,
                    pointer_field=field,
                    texture_offset=target,
                    texture_identity=_stable_id(package_sha256, "texture", target),
                )
            )
        raw_end = frame_array + frame_count * 4
        sequences.append(
            TextureFrameSequence(
                offset=offset,
                identity=_stable_id(package_sha256, "texture-frame-sequence", offset),
                header_offset=header,
                frame_array_offset=frame_array,
                frames=tuple(frames),
                raw_sha256=hashlib.sha256(
                    file_info[offset : offset + TEXTURE_FRAME_SEQUENCE_SIZE]
                    + file_info[header:raw_end]
                ).hexdigest(),
            )
        )

    animations: list[TextureUVAnimation] = []
    allowed_targets = {"texture", "texture_frame_sequence"}
    for offset_or_none in uv_offsets:
        assert offset_or_none is not None
        offset = offset_or_none
        _require_range(file_info, offset, TEXTURE_UV_ANIMATION_SIZE, "UV animation")
        track_count = _u16(file_info, offset + 0x8C)
        if _u16(file_info, offset + 0x8E):
            raise DynamicMaterialError(
                f"UV animation 0x{offset:x} has a nonzero reserved halfword"
            )
        array_field = offset + 0x90
        if array_field not in pointer_fields:
            raise DynamicMaterialError(
                f"UV animation 0x{offset:x} lacks a track-array pointer"
            )
        track_array = _u32(file_info, array_field)
        _require_range(
            file_info,
            track_array,
            track_count * TEXTURE_UV_TRACK_SIZE,
            "UV animation tracks",
        )
        tracks: list[TextureUVTrack] = []
        for index in range(track_count):
            track = track_array + index * TEXTURE_UV_TRACK_SIZE
            if track not in pointer_fields:
                raise DynamicMaterialError(
                    f"UV track 0x{track:x} lacks a texture pointer relocation"
                )
            target = _u32(file_info, track)
            target_kind = resource_targets.get(target)
            if target_kind not in allowed_targets:
                raise DynamicMaterialError(
                    f"UV track {index} targets {target_kind!r} at 0x{target:x}"
                )
            u_mode = file_info[track + 0x16]
            v_mode = file_info[track + 0x17]
            if u_mode > 2 or v_mode > 2:
                raise DynamicMaterialError(
                    f"UV track {index} has unsupported modes {u_mode}/{v_mode}"
                )
            raw = file_info[track : track + TEXTURE_UV_TRACK_SIZE]
            tracks.append(
                TextureUVTrack(
                    index=index,
                    offset=track,
                    texture_offset=target,
                    texture_identity=_stable_id(package_sha256, target_kind, target),
                    u_amplitude=_f32(file_info, track + 0x04),
                    v_amplitude=_f32(file_info, track + 0x08),
                    word_0c=_u32(file_info, track + 0x0C),
                    word_10=_u32(file_info, track + 0x10),
                    word_14=_u32(file_info, track + 0x14),
                    u_mode=u_mode,
                    v_mode=v_mode,
                    coordinate_slot=file_info[track + 0x18],
                    u_frequency=_f32(file_info, track + 0x1C),
                    v_frequency=_f32(file_info, track + 0x20),
                    u_phase=_f32(file_info, track + 0x24),
                    v_phase=_f32(file_info, track + 0x28),
                    raw_sha256=hashlib.sha256(raw).hexdigest(),
                )
            )
        animations.append(
            TextureUVAnimation(
                offset=offset,
                identity=_stable_id(package_sha256, "texture-uv-animation", offset),
                track_array_offset=track_array,
                tracks=tuple(tracks),
                raw_sha256=hashlib.sha256(
                    file_info[
                        offset : track_array + track_count * TEXTURE_UV_TRACK_SIZE
                    ]
                ).hexdigest(),
            )
        )
    return tuple(sequences), tuple(animations)


def wii_dynamic_material_manifest(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> dict[str, object]:
    sequences, animations = parse_wii_dynamic_materials(
        file_info,
        commands,
        package_sha256=package_sha256,
    )
    dependencies: list[dict[str, str]] = []
    for sequence in sequences:
        dependencies.extend(
            {
                "from": sequence.identity,
                "to": frame.texture_identity,
                "relationship": "selects_frame_texture",
            }
            for frame in sequence.frames
        )
    for animation in animations:
        dependencies.extend(
            {
                "from": animation.identity,
                "to": track.texture_identity,
                "relationship": "animates_texture_coordinates",
            }
            for track in animation.tracks
        )
    return {
        "schema": DYNAMIC_MATERIAL_SCHEMA,
        "package_sha256": package_sha256,
        "texture_frame_sequence_count": len(sequences),
        "texture_frame_count": sum(len(sequence.frames) for sequence in sequences),
        "texture_uv_animation_count": len(animations),
        "texture_uv_track_count": sum(
            len(animation.tracks) for animation in animations
        ),
        "texture_frame_sequences": [sequence.to_dict() for sequence in sequences],
        "texture_uv_animations": [animation.to_dict() for animation in animations],
        "dependencies": dependencies,
    }

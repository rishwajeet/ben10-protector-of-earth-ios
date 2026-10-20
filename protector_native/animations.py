"""Executable-derived animation and skeleton decoding for Protector of Earth."""

from __future__ import annotations

import bisect
import hashlib
import itertools
import math
import struct
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from typing import Literal

from protector_native.bigb import RelocationCommand

ANIMATION_SCHEMA = "protector-native.animation/v1"
CLIP_HEADER_SIZE = 0x80
SKELETON_HEADER_SIZE = 0x10
SKELETON_MATRIX_SIZE = 0x40
SKELETON_BONE_SIZE = 0x40
CLIP_POINTER_FIELDS = (0x50, 0x58, 0x5C, 0x60, 0x64, 0x68, 0x6C, 0x70)


class AnimationError(ValueError):
    """Raised when animation data violates executable-derived invariants."""


def _prefix(endian: str) -> str:
    if endian == "little":
        return "<"
    if endian == "big":
        return ">"
    raise AnimationError(f"unsupported animation endian: {endian!r}")


def _stable_id(package_sha256: str, kind: str, offset: int) -> str:
    return f"sha256:{package_sha256}/{kind}@0x{offset:08x}"


def _hex(value: int) -> str:
    return f"0x{value:08x}"


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or offset + size > len(value):
        raise AnimationError(
            f"{label} range 0x{offset:x}..0x{offset + size:x} "
            f"exceeds file-info size 0x{len(value):x}"
        )


def _u16(value: bytes, offset: int, prefix: str) -> int:
    return struct.unpack_from(f"{prefix}H", value, offset)[0]


def _i16(value: bytes, offset: int, prefix: str) -> int:
    return struct.unpack_from(f"{prefix}h", value, offset)[0]


def _u32(value: bytes, offset: int, prefix: str) -> int:
    return struct.unpack_from(f"{prefix}I", value, offset)[0]


def _f32(value: bytes, offset: int, prefix: str) -> float:
    return struct.unpack_from(f"{prefix}f", value, offset)[0]


def _float_tuple(
    value: bytes, offset: int, count: int, prefix: str
) -> tuple[float, ...]:
    _require_range(value, offset, count * 4, "float array")
    return struct.unpack_from(f"{prefix}{count}f", value, offset)


def _pointer_targets(value: bytes, pointer_fields: set[int], prefix: str) -> set[int]:
    targets: set[int] = set()
    for field in pointer_fields:
        _require_range(value, field, 4, "pointer relocation")
        targets.add(_u32(value, field, prefix))
    return targets


def _padded_name(value: bytes, offset: int) -> str | None:
    if offset < 0 or offset + 0x20 > len(value):
        return None
    raw = value[offset : offset + 0x20]
    name, separator, tail = raw.partition(b"\x00")
    if (
        not separator
        or not name
        or any(character < 0x20 or character > 0x7E for character in name)
        or any(tail)
    ):
        return None
    return name.decode("ascii")


def _normalize_quaternion(
    value: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    length = math.sqrt(sum(component * component for component in value))
    if length == 0:
        raise AnimationError("zero-length decoded quaternion")
    return tuple(component / length for component in value)  # type: ignore[return-value]


def decode_quaternion_32(value: bytes, offset: int, endian: str) -> tuple[float, ...]:
    """Decode the 10-10-10-plus-index codec used by evaluator 0x8006A13C."""

    prefix = _prefix(endian)
    _require_range(value, offset, 4, "32-bit quaternion")
    packed = _u32(value, offset, prefix)
    omitted = packed & 0x3
    quantized = tuple((packed >> (2 + index * 10)) & 0x3FF for index in range(3))
    decoded = [math.sqrt(0.5) * (sample / 512.0 - 1.0) for sample in quantized]
    components: list[float] = []
    source = iter(decoded)
    for index in range(4):
        components.append(0.0 if index == omitted else next(source))
    components[omitted] = math.sqrt(
        max(0.0, 1.0 - sum(component * component for component in components))
    )
    return _normalize_quaternion(tuple(components))  # type: ignore[arg-type]


def decode_quaternion_48(value: bytes, offset: int, endian: str) -> tuple[float, ...]:
    """Decode the 15-15-15-plus-index codec used by evaluator 0x8006A13C."""

    _require_range(value, offset, 6, "48-bit quaternion")
    packed = int.from_bytes(
        value[offset : offset + 6],
        byteorder="big" if endian == "big" else "little",
    )
    omitted = packed & 0x3
    quantized = tuple((packed >> (2 + index * 15)) & 0x7FFF for index in range(3))
    decoded = [math.sqrt(0.5) * (sample / 16384.0 - 1.0) for sample in quantized]
    components: list[float] = []
    source = iter(decoded)
    for index in range(4):
        components.append(0.0 if index == omitted else next(source))
    components[omitted] = math.sqrt(
        max(0.0, 1.0 - sum(component * component for component in components))
    )
    return _normalize_quaternion(tuple(components))  # type: ignore[arg-type]


def _slerp(
    start: tuple[float, ...], end: tuple[float, ...], alpha: float
) -> tuple[float, float, float, float]:
    dot = sum(a * b for a, b in zip(start, end, strict=True))
    if dot < 0:
        end = tuple(-component for component in end)
        dot = -dot
    if dot > 0.9995:
        return _normalize_quaternion(
            tuple(a + alpha * (b - a) for a, b in zip(start, end, strict=True))
        )  # type: ignore[arg-type]
    theta = math.acos(max(-1.0, min(1.0, dot)))
    sine = math.sin(theta)
    left = math.sin((1.0 - alpha) * theta) / sine
    right = math.sin(alpha * theta) / sine
    return tuple(left * a + right * b for a, b in zip(start, end, strict=True))  # type: ignore[return-value]


def _interval(times: tuple[float, ...], time: float) -> tuple[int, float]:
    if len(times) < 2:
        return 0, 0.0
    time = max(times[0], min(times[-1], time))
    index = min(len(times) - 2, max(0, bisect.bisect_right(times, time) - 1))
    span = times[index + 1] - times[index]
    alpha = 0.0 if span == 0 else (time - times[index]) / span
    return index, alpha


@dataclass(frozen=True)
class AnimationEvent:
    name: str
    time: float
    argument: int


@dataclass(frozen=True)
class AnimationTrack:
    bone_index: int
    translation_mode: Literal["constant", "sampled"]
    rotation_mode: Literal["constant", "uniform", "variable"]
    rotation_times: tuple[float, ...]
    rotations: tuple[tuple[float, ...], ...]
    translations: tuple[tuple[float, float, float], ...]

    def sample(
        self, time: float
    ) -> tuple[tuple[float, ...], tuple[float, float, float]]:
        rotation_index, rotation_alpha = _interval(self.rotation_times, time)
        if len(self.rotations) == 1:
            rotation = self.rotations[0]
        else:
            rotation = _slerp(
                self.rotations[rotation_index],
                self.rotations[rotation_index + 1],
                rotation_alpha,
            )
        if len(self.translations) == 1:
            translation = self.translations[0]
        else:
            translation_index, translation_alpha = _interval(
                tuple(
                    index / (len(self.translations) - 1)
                    for index in range(len(self.translations))
                ),
                time,
            )
            start = self.translations[translation_index]
            end = self.translations[translation_index + 1]
            translation = tuple(
                a + translation_alpha * (b - a) for a, b in zip(start, end, strict=True)
            )
        return rotation, translation  # type: ignore[return-value]


@dataclass(frozen=True)
class AnimationClip:
    offset: int
    identity: str
    name: str
    bone_mask: int
    duration_seconds: float
    blend_in_seconds: float
    blend_out_seconds: float
    frame_count: int
    codec_bits: int
    root_track_index: int
    constant_rotation_count: int
    uniform_rotation_count: int
    variable_rotation_count: int
    events: tuple[AnimationEvent, ...]
    tracks: tuple[AnimationTrack, ...]
    raw_header_sha256: str

    def sample(
        self, normalized_time: float
    ) -> dict[int, tuple[tuple[float, ...], tuple[float, float, float]]]:
        return {
            track.bone_index: track.sample(normalized_time) for track in self.tracks
        }

    def to_dict(self) -> dict[str, object]:
        return {
            "offset": _hex(self.offset),
            "identity": self.identity,
            "name": self.name,
            "bone_mask": _hex(self.bone_mask),
            "duration_seconds": self.duration_seconds,
            "blend_in_seconds": self.blend_in_seconds,
            "blend_out_seconds": self.blend_out_seconds,
            "frame_count": self.frame_count,
            "codec_bits": self.codec_bits,
            "root_track_index": self.root_track_index,
            "rotation_counts": {
                "constant": self.constant_rotation_count,
                "uniform": self.uniform_rotation_count,
                "variable": self.variable_rotation_count,
            },
            "events": [asdict(event) for event in self.events],
            "tracks": [
                {
                    "bone_index": track.bone_index,
                    "translation_mode": track.translation_mode,
                    "rotation_mode": track.rotation_mode,
                    "rotation_key_count": len(track.rotations),
                    "translation_key_count": len(track.translations),
                }
                for track in self.tracks
            ],
            "raw_header_sha256": self.raw_header_sha256,
        }


@dataclass(frozen=True)
class SkeletonBone:
    index: int
    name: str
    parent_index: int
    first_child_index: int
    next_sibling_index: int
    bind_matrix: tuple[float, ...]
    inverse_bind_matrix: tuple[float, ...]

    @property
    def bind_position(self) -> tuple[float, float, float]:
        return self.bind_matrix[12:15]  # type: ignore[return-value]


@dataclass(frozen=True)
class Skeleton:
    offset: int
    identity: str
    root_motion_bone_index: int
    bones: tuple[SkeletonBone, ...]
    raw_header_sha256: str

    @property
    def signature(self) -> tuple[tuple[str, int, int, int], ...]:
        return tuple(
            (
                bone.name,
                bone.parent_index,
                bone.first_child_index,
                bone.next_sibling_index,
            )
            for bone in self.bones
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "offset": _hex(self.offset),
            "identity": self.identity,
            "root_motion_bone_index": self.root_motion_bone_index,
            "bone_count": len(self.bones),
            "bones": [
                {
                    "index": bone.index,
                    "name": bone.name,
                    "parent_index": bone.parent_index,
                    "first_child_index": bone.first_child_index,
                    "next_sibling_index": bone.next_sibling_index,
                    "bind_position": bone.bind_position,
                }
                for bone in self.bones
            ],
            "raw_header_sha256": self.raw_header_sha256,
        }


def _decode_quaternion_array(
    value: bytes, offset: int, count: int, codec: int, endian: str
) -> tuple[tuple[float, ...], ...]:
    if codec == 0:
        stride = 4
        decoder = decode_quaternion_32
    elif codec == 1:
        stride = 6
        decoder = decode_quaternion_48
    else:
        raise AnimationError(f"unsupported quaternion codec {codec}")
    _require_range(value, offset, count * stride, "quaternion array")
    return tuple(
        decoder(value, offset + index * stride, endian) for index in range(count)
    )


def _monotonic_normalized(times: tuple[float, ...]) -> bool:
    return (
        len(times) >= 2
        and abs(times[0]) <= 1e-5
        and abs(times[-1] - 1.0) <= 1e-5
        and all(math.isfinite(time) for time in times)
        and all(a < b for a, b in itertools.pairwise(times))
    )


def _parse_clip(
    value: bytes,
    offset: int,
    pointer_fields: set[int],
    endian: str,
    package_sha256: str,
) -> AnimationClip:
    prefix = _prefix(endian)
    _require_range(value, offset, CLIP_HEADER_SIZE, "animation clip header")
    name = _padded_name(value, offset)
    if name is None:
        raise AnimationError(f"invalid animation name at 0x{offset:x}")
    if not {offset + field for field in CLIP_POINTER_FIELDS} <= pointer_fields:
        raise AnimationError(f"clip {name!r} is missing pointer relocations")

    bone_mask = _u32(value, offset + 0x20, prefix)
    constant_count = value[offset + 0x44]
    uniform_count = value[offset + 0x45]
    variable_count = value[offset + 0x46]
    root_track_index = struct.unpack_from("b", value, offset + 0x47)[0]
    codec = value[offset + 0x48]
    event_count = _u16(value, offset + 0x4C, prefix)
    frame_count = _u32(value, offset + 0x54, prefix)
    track_count = constant_count + uniform_count + variable_count
    if track_count == 0 or track_count != bone_mask.bit_count():
        raise AnimationError(f"clip {name!r} has inconsistent track mask/count")
    if root_track_index != -1 and not 0 <= root_track_index < track_count:
        raise AnimationError(f"clip {name!r} has invalid root-track index")
    if codec not in {0, 1}:
        raise AnimationError(f"clip {name!r} has unsupported codec {codec}")
    if frame_count < 2 or frame_count > 100_000:
        raise AnimationError(f"clip {name!r} has invalid frame count {frame_count}")
    if event_count and offset + 0x74 not in pointer_fields:
        raise AnimationError(f"clip {name!r} event table is not relocated")

    pointer = lambda field: _u32(value, offset + field, prefix)
    remap_offset = pointer(0x50)
    _require_range(value, remap_offset, track_count, "bone remap")
    remap = struct.unpack_from(f"{track_count}b", value, remap_offset)
    bone_indices = tuple(~index if index < 0 else index for index in remap)
    expected_bones = {index for index in range(32) if bone_mask & (1 << index)}
    if set(bone_indices) != expected_bones or len(set(bone_indices)) != track_count:
        raise AnimationError(f"clip {name!r} bone remap does not match mask")

    global_times = _float_tuple(value, pointer(0x58), frame_count, prefix)
    if not _monotonic_normalized(global_times):
        raise AnimationError(f"clip {name!r} has invalid global times")

    stride = 4 if codec == 0 else 6
    variable_lengths_offset = pointer(0x68)
    variable_lengths = tuple(
        _u16(value, variable_lengths_offset + index * 2, prefix)
        for index in range(variable_count)
    )
    variable_time_offset = pointer(0x64)
    variable_rotation_offset = pointer(0x60)
    variable_tracks: list[tuple[tuple[float, ...], tuple[tuple[float, ...], ...]]] = []
    for length in variable_lengths:
        times = _float_tuple(value, variable_time_offset, length, prefix)
        if not _monotonic_normalized(times):
            raise AnimationError(f"clip {name!r} has invalid variable times")
        rotations = _decode_quaternion_array(
            value, variable_rotation_offset, length, codec, endian
        )
        variable_tracks.append((times, rotations))
        variable_time_offset += length * 4
        variable_rotation_offset += length * stride

    uniform_rotation_offset = pointer(0x5C)
    uniform_rotations = _decode_quaternion_array(
        value,
        uniform_rotation_offset,
        frame_count * uniform_count,
        codec,
        endian,
    )
    constant_rotations = _decode_quaternion_array(
        value, pointer(0x6C), constant_count, codec, endian
    )

    frame_pointer_offset = pointer(0x70)
    _require_range(value, frame_pointer_offset, frame_count * 4, "translation pointers")
    if (
        not {frame_pointer_offset + index * 4 for index in range(frame_count)}
        <= pointer_fields
    ):
        raise AnimationError(f"clip {name!r} translation table is not fully relocated")
    frame_pointers = tuple(
        _u32(value, frame_pointer_offset + index * 4, prefix)
        for index in range(frame_count)
    )
    dynamic_count = sum(index >= 0 for index in remap)
    _require_range(value, frame_pointers[0], track_count * 12, "base translations")
    for frame_pointer in frame_pointers[1:]:
        _require_range(value, frame_pointer, dynamic_count * 12, "sampled translations")
    base_translations = tuple(
        struct.unpack_from(f"{prefix}3f", value, frame_pointers[0] + index * 12)
        for index in range(track_count)
    )
    sampled_translations: dict[int, tuple[tuple[float, float, float], ...]] = {}
    dynamic_index = 0
    for track_index, remap_value in enumerate(remap):
        if remap_value < 0:
            sampled_translations[track_index] = (base_translations[track_index],)
            continue
        translations = [base_translations[track_index]]
        for frame_pointer in frame_pointers[1:]:
            translations.append(
                struct.unpack_from(
                    f"{prefix}3f", value, frame_pointer + dynamic_index * 12
                )
            )
        sampled_translations[track_index] = tuple(translations)
        dynamic_index += 1

    rotations_by_track: list[
        tuple[
            Literal["constant", "uniform", "variable"],
            tuple[float, ...],
            tuple[tuple[float, ...], ...],
        ]
    ] = []
    for times, rotations in variable_tracks:
        rotations_by_track.append(("variable", times, rotations))
    for index in range(uniform_count):
        rotations_by_track.append(
            (
                "uniform",
                global_times,
                tuple(
                    uniform_rotations[frame * uniform_count + index]
                    for frame in range(frame_count)
                ),
            )
        )
    for rotation in constant_rotations:
        rotations_by_track.append(("constant", (0.0,), (rotation,)))

    tracks = tuple(
        AnimationTrack(
            bone_index=bone_indices[index],
            translation_mode="constant" if remap[index] < 0 else "sampled",
            rotation_mode=rotations_by_track[index][0],
            rotation_times=rotations_by_track[index][1],
            rotations=rotations_by_track[index][2],
            translations=sampled_translations[index],
        )
        for index in range(track_count)
    )

    event_offset = pointer(0x74)
    _require_range(value, event_offset, event_count * 12, "animation events")
    events: list[AnimationEvent] = []
    for index in range(event_count):
        record = event_offset + index * 12
        if record not in pointer_fields:
            raise AnimationError(f"clip {name!r} event name is not relocated")
        event_name_offset = _u32(value, record, prefix)
        event_name = _padded_name(value, event_name_offset)
        if event_name is None:
            # Event strings are tightly packed, not 32-byte fields.
            end = value.find(b"\x00", event_name_offset)
            raw_name = value[event_name_offset:end] if end >= 0 else b""
            if not raw_name or any(
                character < 0x20 or character > 0x7E for character in raw_name
            ):
                raise AnimationError(f"clip {name!r} has invalid event name")
            event_name = raw_name.decode("ascii")
        event_time = _f32(value, record + 4, prefix)
        if not 0.0 <= event_time <= 1.0:
            raise AnimationError(f"clip {name!r} has invalid event time")
        events.append(
            AnimationEvent(
                name=event_name,
                time=event_time,
                argument=_u32(value, record + 8, prefix),
            )
        )

    return AnimationClip(
        offset=offset,
        identity=_stable_id(package_sha256, "animation-clip", offset),
        name=name,
        bone_mask=bone_mask,
        duration_seconds=_f32(value, offset + 0x38, prefix),
        blend_in_seconds=_f32(value, offset + 0x3C, prefix),
        blend_out_seconds=_f32(value, offset + 0x40, prefix),
        frame_count=frame_count,
        codec_bits=32 if codec == 0 else 48,
        root_track_index=root_track_index,
        constant_rotation_count=constant_count,
        uniform_rotation_count=uniform_count,
        variable_rotation_count=variable_count,
        events=tuple(events),
        tracks=tracks,
        raw_header_sha256=hashlib.sha256(
            value[offset : offset + CLIP_HEADER_SIZE]
        ).hexdigest(),
    )


def parse_animation_clips(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    endian: str,
    *,
    package_sha256: str,
) -> tuple[AnimationClip, ...]:
    """Discover clips by pointer-target and fixed relocation layout."""

    prefix = _prefix(endian)
    pointer_fields = {
        command.destination_offset
        for command in commands
        if command.name == "file_info_pointer"
        and command.destination_offset is not None
    }
    targets = _pointer_targets(file_info, pointer_fields, prefix)
    candidates = sorted(
        offset
        for offset in targets
        if _padded_name(file_info, offset) is not None
        and {offset + field for field in CLIP_POINTER_FIELDS} <= pointer_fields
    )
    clips: list[AnimationClip] = []
    for offset in candidates:
        try:
            clips.append(
                _parse_clip(
                    file_info,
                    offset,
                    pointer_fields,
                    endian,
                    package_sha256,
                )
            )
        except AnimationError:
            # Fixed relocation layout is the discovery signature; candidates
            # that fail the remaining invariants are unrelated named records.
            continue
    return tuple(clips)


def parse_skeletons(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    endian: str,
    *,
    package_sha256: str,
) -> tuple[Skeleton, ...]:
    """Discover skeletons from their three relocated parallel arrays."""

    prefix = _prefix(endian)
    pointer_fields = {
        command.destination_offset
        for command in commands
        if command.name == "file_info_pointer"
        and command.destination_offset is not None
    }
    skeletons: list[Skeleton] = []
    for offset in sorted(field - 4 for field in pointer_fields if field >= 4):
        if not {offset + 4, offset + 8, offset + 12} <= pointer_fields:
            continue
        if offset + SKELETON_HEADER_SIZE > len(file_info):
            continue
        bone_count = _u16(file_info, offset, prefix)
        root_index = _i16(file_info, offset + 2, prefix)
        if not 1 <= bone_count <= 255 or not -1 <= root_index < bone_count:
            continue
        matrix_offset = _u32(file_info, offset + 4, prefix)
        bone_offset = _u32(file_info, offset + 8, prefix)
        inverse_matrix_offset = _u32(file_info, offset + 12, prefix)
        if (
            bone_offset != matrix_offset + bone_count * SKELETON_MATRIX_SIZE
            or inverse_matrix_offset != bone_offset + bone_count * SKELETON_BONE_SIZE
        ):
            continue
        if inverse_matrix_offset + bone_count * SKELETON_MATRIX_SIZE > len(file_info):
            continue
        names = tuple(
            _padded_name(file_info, bone_offset + index * SKELETON_BONE_SIZE)
            for index in range(bone_count)
        )
        if any(name is None for name in names):
            continue
        bones: list[SkeletonBone] = []
        valid = True
        for index, name_or_none in enumerate(names):
            record = bone_offset + index * SKELETON_BONE_SIZE
            parent = _u32(file_info, record + 0x28, prefix)
            first_child = _u32(file_info, record + 0x2C, prefix)
            next_sibling = _u32(file_info, record + 0x30, prefix)
            if any(
                candidate >= bone_count
                for candidate in (parent, first_child, next_sibling)
            ):
                valid = False
                break
            bind = _float_tuple(
                file_info,
                matrix_offset + index * SKELETON_MATRIX_SIZE,
                16,
                prefix,
            )
            inverse = _float_tuple(
                file_info,
                inverse_matrix_offset + index * SKELETON_MATRIX_SIZE,
                16,
                prefix,
            )
            if not all(math.isfinite(component) for component in bind + inverse):
                valid = False
                break
            assert name_or_none is not None
            bones.append(
                SkeletonBone(
                    index=index,
                    name=name_or_none,
                    parent_index=parent,
                    first_child_index=first_child,
                    next_sibling_index=next_sibling,
                    bind_matrix=bind,
                    inverse_bind_matrix=inverse,
                )
            )
        if not valid:
            continue
        skeletons.append(
            Skeleton(
                offset=offset,
                identity=_stable_id(package_sha256, "skeleton", offset),
                root_motion_bone_index=root_index,
                bones=tuple(bones),
                raw_header_sha256=hashlib.sha256(
                    file_info[offset : offset + SKELETON_HEADER_SIZE]
                ).hexdigest(),
            )
        )
    return tuple(skeletons)


def animation_manifest(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    endian: str,
    *,
    package_sha256: str,
) -> dict[str, object]:
    command_list = tuple(commands)
    clips = parse_animation_clips(
        file_info,
        command_list,
        endian,
        package_sha256=package_sha256,
    )
    skeletons = parse_skeletons(
        file_info,
        command_list,
        endian,
        package_sha256=package_sha256,
    )
    unique_skeletons = {skeleton.signature for skeleton in skeletons}
    return {
        "schema": ANIMATION_SCHEMA,
        "clip_count": len(clips),
        "event_count": sum(len(clip.events) for clip in clips),
        "track_count": sum(len(clip.tracks) for clip in clips),
        "skeleton_count": len(skeletons),
        "unique_skeleton_count": len(unique_skeletons),
        "clips": [clip.to_dict() for clip in clips],
        "skeletons": [skeleton.to_dict() for skeleton in skeletons],
    }

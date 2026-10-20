"""Wii skinning palette resources and skeleton compatibility edges."""

from __future__ import annotations

import hashlib
import struct
from collections.abc import Iterable
from dataclasses import asdict, dataclass

from protector_native.animations import Skeleton, parse_skeletons
from protector_native.bigb import RelocationCommand

SKINNING_SCHEMA = "protector-native.skinning/wii-v1"
SKINNING_SET_SIZE = 0x14
SKINNING_BINDING_SIZE = 0x10


class SkinningError(ValueError):
    """Raised when a Wii skinning-palette resource is inconsistent."""


def _hex(value: int) -> str:
    return f"0x{value:08x}"


def _identity(package_sha256: str, kind: str, offset: int) -> str:
    return f"sha256:{package_sha256}/{kind}@0x{offset:08x}"


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or offset + size > len(value):
        raise SkinningError(
            f"{label} range 0x{offset:x}..0x{offset + size:x} "
            f"exceeds file-info size 0x{len(value):x}"
        )


def _u32(value: bytes, offset: int) -> int:
    _require_range(value, offset, 4, "u32")
    return struct.unpack_from(">I", value, offset)[0]


@dataclass(frozen=True)
class SkinningPalette:
    index: int
    offset: int
    identity: str
    palette_array_offset: int
    bone_indices: tuple[int, ...]
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["offset"] = _hex(self.offset)
        value["palette_array_offset"] = _hex(self.palette_array_offset)
        return value


@dataclass(frozen=True)
class SkinningPaletteSet:
    offset: int
    identity: str
    binding_array_offset: int
    palettes: tuple[SkinningPalette, ...]
    raw_header_sha256: str

    def to_dict(self) -> dict[str, object]:
        return {
            "offset": _hex(self.offset),
            "identity": self.identity,
            "binding_array_offset": _hex(self.binding_array_offset),
            "palette_count": len(self.palettes),
            "palettes": [palette.to_dict() for palette in self.palettes],
            "raw_header_sha256": self.raw_header_sha256,
        }


def parse_wii_skinning_palettes(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> tuple[SkinningPaletteSet, ...]:
    """Parse the slot-07 set/binding/palette layout used by Wii models."""

    command_list = tuple(commands)
    pointer_fields = {
        command.destination_offset
        for command in command_list
        if command.name == "file_info_pointer"
    }
    roots = tuple(
        command.destination_offset
        for command in command_list
        if command.name == "skinning_palette_set"
    )
    if any(root is None for root in roots):
        raise SkinningError("skinning-palette command lacks a destination")

    sets: list[SkinningPaletteSet] = []
    for root_or_none in roots:
        assert root_or_none is not None
        root = root_or_none
        _require_range(file_info, root, SKINNING_SET_SIZE, "skinning set")
        palette_count = _u32(file_info, root + 4)
        array_field = root + 8
        array_offset = _u32(file_info, array_field)
        if array_field not in pointer_fields:
            raise SkinningError(
                f"skinning set 0x{root:x} lacks a binding-array relocation"
            )
        if palette_count != 1:
            raise SkinningError(
                f"skinning set 0x{root:x} has {palette_count} bindings; expected 1"
            )
        if _u32(file_info, root + 0x0C) or _u32(file_info, root + 0x10):
            raise SkinningError(f"skinning set 0x{root:x} has nonzero reserved words")
        _require_range(
            file_info,
            array_offset,
            palette_count * SKINNING_BINDING_SIZE,
            "skinning bindings",
        )

        palettes: list[SkinningPalette] = []
        for index in range(palette_count):
            binding = array_offset + index * SKINNING_BINDING_SIZE
            bone_count = _u32(file_info, binding)
            palette_field = binding + 4
            palette_offset = _u32(file_info, palette_field)
            if palette_field not in pointer_fields:
                raise SkinningError(
                    f"skinning binding 0x{binding:x} lacks a palette relocation"
                )
            if _u32(file_info, binding + 8) or _u32(file_info, binding + 0x0C):
                raise SkinningError(
                    f"skinning binding 0x{binding:x} has nonzero reserved words"
                )
            _require_range(
                file_info,
                palette_offset,
                bone_count * 2,
                "skinning bone palette",
            )
            indices = struct.unpack_from(f">{bone_count}H", file_info, palette_offset)
            if not indices:
                raise SkinningError(f"skinning binding 0x{binding:x} is empty")
            if tuple(sorted(indices)) != indices or len(set(indices)) != len(indices):
                raise SkinningError(
                    f"skinning binding 0x{binding:x} has a noncanonical palette"
                )
            raw_end = palette_offset + bone_count * 2
            palettes.append(
                SkinningPalette(
                    index=index,
                    offset=binding,
                    identity=_identity(
                        package_sha256,
                        "skinning-palette",
                        binding,
                    ),
                    palette_array_offset=palette_offset,
                    bone_indices=indices,
                    raw_sha256=hashlib.sha256(
                        file_info[binding : binding + SKINNING_BINDING_SIZE]
                        + file_info[palette_offset:raw_end]
                    ).hexdigest(),
                )
            )
        sets.append(
            SkinningPaletteSet(
                offset=root,
                identity=_identity(
                    package_sha256,
                    "skinning-palette-set",
                    root,
                ),
                binding_array_offset=array_offset,
                palettes=tuple(palettes),
                raw_header_sha256=hashlib.sha256(
                    file_info[root : root + SKINNING_SET_SIZE]
                ).hexdigest(),
            )
        )
    return tuple(sets)


def _compatible_skeletons(
    palette: SkinningPalette,
    skeletons: Iterable[Skeleton],
) -> tuple[Skeleton, ...]:
    maximum = max(palette.bone_indices)
    return tuple(skeleton for skeleton in skeletons if maximum < len(skeleton.bones))


def wii_skinning_manifest(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> dict[str, object]:
    command_list = tuple(commands)
    sets = parse_wii_skinning_palettes(
        file_info,
        command_list,
        package_sha256=package_sha256,
    )
    skeletons = (
        parse_skeletons(
            file_info,
            command_list,
            "big",
            package_sha256=package_sha256,
        )
        if sets
        else ()
    )
    dependencies: list[dict[str, str]] = []
    compatibility_edges: list[dict[str, str]] = []
    for palette_set in sets:
        for palette in palette_set.palettes:
            dependencies.append(
                {
                    "from": palette_set.identity,
                    "to": palette.identity,
                    "relationship": "owns_skinning_palette",
                }
            )
            compatibility_edges.extend(
                {
                    "from": palette.identity,
                    "to": skeleton.identity,
                    "relationship": "indices_compatible_skeleton",
                }
                for skeleton in _compatible_skeletons(palette, skeletons)
            )
    return {
        "schema": SKINNING_SCHEMA,
        "package_sha256": package_sha256,
        "palette_set_count": len(sets),
        "palette_count": sum(len(value.palettes) for value in sets),
        "bone_index_count": sum(
            len(palette.bone_indices) for value in sets for palette in value.palettes
        ),
        "maximum_bone_index": max(
            (max(palette.bone_indices) for value in sets for palette in value.palettes),
            default=None,
        ),
        "palette_sets": [value.to_dict() for value in sets],
        "dependencies": dependencies,
        "skeleton_compatibility": compatibility_edges,
    }

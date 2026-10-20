"""Typed BIGB/BGIB relocation stream parsing.

The command grammar in this module is derived from Protector of Earth's Wii
loader at ``0x80013084``.  A relocation stream is not a flat list of offsets:
some opcodes consume a following operand.  Parsing the grammar first prevents
operands with their high bit set from being misclassified as commands.
"""

from __future__ import annotations

import struct
from collections import Counter
from dataclasses import asdict, dataclass
from typing import Literal

RELOCATION_SCHEMA = "protector-native.bigb.relocation/v1"
RESOURCE_REFERENCE_LIMIT = 0x80000028


class RelocationError(ValueError):
    """Raised when a relocation stream violates the executable's grammar."""


@dataclass(frozen=True)
class SpecialDefinition:
    name: str
    operand_kind: str
    operand_is_data_offset: bool = False


@dataclass(frozen=True)
class RelocationCommand:
    stream_offset: int
    opcode: int
    kind: Literal["pointer_fixup", "resource_reference", "special"]
    name: str
    operands: tuple[int, ...]
    operand_kind: str
    destination_offset: int | None
    confidence: Literal["executable", "cross_checked", "unknown"]

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        value["opcode"] = f"0x{self.opcode:08x}"
        value["operands"] = [f"0x{operand:08x}" for operand in self.operands]
        if self.destination_offset is not None:
            value["destination_offset"] = f"0x{self.destination_offset:08x}"
        return value


# Names for 0x80000000..0x80000027 are loader-registry slots.  Texture and
# facial-animation names have been independently cross-checked against public
# R4S research. Slot 08 is identified by the title's map layout: across every
# map package, its destinations exactly cover the declared 0x30-byte RTB node
# array. The remaining slots stay explicit rather than being guessed.
RESOURCE_REFERENCE_NAMES = {
    0x80000000: "null_resource",
    0x80000001: "texture",
    0x80000003: "material_state_variant_03",
    0x80000004: "material_state_variant_04",
    0x80000005: "texture_frame_sequence",
    0x80000006: "texture_uv_animation",
    0x80000007: "skinning_palette_set",
    0x80000008: "rtb_tree_node",
    0x80000021: "facial_animation",
}

RESOURCE_REFERENCE_CONFIDENCE = {
    0x80000001: "cross_checked",
    0x80000003: "cross_checked",
    0x80000004: "cross_checked",
    0x80000005: "executable",
    0x80000006: "executable",
    0x80000007: "cross_checked",
    0x80000008: "executable",
    0x80000021: "cross_checked",
}


# Every accepted branch in Protector of Earth's Wii jump table.  The absent
# values in the 0x10A..0x11A range branch to a fatal unhandled-special loop.
SPECIAL_DEFINITIONS = {
    0x8000010A: SpecialDefinition("rtb_node_adjust_accounting", "data_offset", True),
    0x8000010B: SpecialDefinition(
        "collision_manager_object", "constructor_data_offset", True
    ),
    0x8000010C: SpecialDefinition("map", "data_offset", True),
    0x8000010E: SpecialDefinition("strat_wad", "data_offset", True),
    0x80000113: SpecialDefinition("audio", "data_offset", True),
    0x80000115: SpecialDefinition("sound_control_param", "ignored_data_offset"),
    0x80000117: SpecialDefinition("dynamic_memory_allocation_size", "byte_count"),
    0x80000118: SpecialDefinition("string_table", "ignored_data_offset"),
    0x8000011A: SpecialDefinition("flash_movie", "unsupported_data_offset"),
}


def _unpack_words(value: bytes, endian: str) -> tuple[int, ...]:
    if len(value) % 4:
        raise RelocationError("relocation block size is not divisible by four")
    if endian not in {"little", "big"}:
        raise RelocationError(f"unsupported relocation endian: {endian!r}")
    prefix = "<" if endian == "little" else ">"
    return struct.unpack(f"{prefix}{len(value) // 4}I", value)


def _require_operand(words: tuple[int, ...], index: int, opcode: int) -> int:
    if index + 1 >= len(words):
        raise RelocationError(
            f"truncated operand after 0x{opcode:08x} "
            f"at relocation offset 0x{index * 4:x}"
        )
    return words[index + 1]


def _validate_data_offset(
    value: int, file_info_size: int | None, stream_offset: int
) -> None:
    if value % 4:
        raise RelocationError(
            f"unaligned data offset 0x{value:x} "
            f"at relocation offset 0x{stream_offset:x}"
        )
    if file_info_size is not None and value + 4 > file_info_size:
        raise RelocationError(
            f"data offset 0x{value:x} exceeds file-info size "
            f"0x{file_info_size:x} at relocation offset 0x{stream_offset:x}"
        )


def parse_relocation_commands(
    value: bytes, endian: str, *, file_info_size: int | None = None
) -> tuple[RelocationCommand, ...]:
    """Parse a relocation block using the title's executable command grammar."""

    words = _unpack_words(value, endian)
    commands: list[RelocationCommand] = []
    index = 0

    while index < len(words):
        opcode = words[index]
        stream_offset = index * 4

        if opcode < 0x80000000:
            _validate_data_offset(opcode, file_info_size, stream_offset)
            commands.append(
                RelocationCommand(
                    stream_offset=stream_offset,
                    opcode=opcode,
                    kind="pointer_fixup",
                    name="file_info_pointer",
                    operands=(opcode,),
                    operand_kind="destination_offset",
                    destination_offset=opcode,
                    confidence="executable",
                )
            )
            index += 1
            continue

        if opcode < RESOURCE_REFERENCE_LIMIT:
            destination = _require_operand(words, index, opcode)
            _validate_data_offset(destination, file_info_size, stream_offset)
            name = RESOURCE_REFERENCE_NAMES.get(
                opcode, f"resource_registry_slot_{opcode & 0xFF:02x}"
            )
            confidence = RESOURCE_REFERENCE_CONFIDENCE.get(opcode, "unknown")
            commands.append(
                RelocationCommand(
                    stream_offset=stream_offset,
                    opcode=opcode,
                    kind="resource_reference",
                    name=name,
                    operands=(destination,),
                    operand_kind="destination_offset",
                    destination_offset=destination,
                    confidence=confidence,
                )
            )
            index += 2
            continue

        definition = SPECIAL_DEFINITIONS.get(opcode)
        if definition is None:
            raise RelocationError(
                f"unhandled relocation special 0x{opcode:08x} "
                f"at relocation offset 0x{stream_offset:x}"
            )

        operand = _require_operand(words, index, opcode)
        if definition.operand_is_data_offset:
            _validate_data_offset(operand, file_info_size, stream_offset)
        commands.append(
            RelocationCommand(
                stream_offset=stream_offset,
                opcode=opcode,
                kind="special",
                name=definition.name,
                operands=(operand,),
                operand_kind=definition.operand_kind,
                destination_offset=operand
                if definition.operand_is_data_offset
                else None,
                confidence="executable",
            )
        )
        index += 2

    return tuple(commands)


def relocation_manifest(
    value: bytes, endian: str, *, file_info_size: int | None = None
) -> dict[str, object]:
    """Return a compact, versioned summary plus every typed command."""

    commands = parse_relocation_commands(value, endian, file_info_size=file_info_size)
    by_kind = Counter(command.kind for command in commands)
    by_name = Counter(command.name for command in commands)
    return {
        "schema": RELOCATION_SCHEMA,
        "command_count": len(commands),
        "word_count": len(value) // 4,
        "by_kind": dict(sorted(by_kind.items())),
        "by_name": dict(sorted(by_name.items())),
        "commands": [command.to_dict() for command in commands],
    }

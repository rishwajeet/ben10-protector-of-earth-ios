"""Typed map roots and RTB spatial-tree nodes for Protector of Earth."""

from __future__ import annotations

import hashlib
import struct
from collections.abc import Iterable
from dataclasses import asdict, dataclass

from protector_native.bigb import RelocationCommand

MAP_SCHEMA = "protector-native.map/v1"
MAP_ROOT_MINIMUM_SIZE = 0x94
RTB_NODE_SIZE = 0x30


class MapError(ValueError):
    """Raised when a map record violates catalog-proven structure."""


def _prefix(endian: str) -> str:
    if endian == "little":
        return "<"
    if endian == "big":
        return ">"
    raise MapError(f"unsupported map endian: {endian!r}")


def _stable_id(package_sha256: str, kind: str, offset: int) -> str:
    return f"sha256:{package_sha256}/{kind}@0x{offset:08x}"


def _hex(value: int) -> str:
    return f"0x{value:08x}"


@dataclass(frozen=True)
class RTBTreeNode:
    index: int
    resource_offset: int
    identity: str
    loader_placeholder: int
    constant_0c: int
    spatial_word_20: int
    spatial_word_24: int
    spatial_word_28: int
    payload_pointer_field: int
    payload_offset: int
    payload_identity: str
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        for name in (
            "resource_offset",
            "loader_placeholder",
            "constant_0c",
            "spatial_word_20",
            "spatial_word_24",
            "spatial_word_28",
            "payload_pointer_field",
            "payload_offset",
        ):
            value[name] = _hex(value[name])
        return value


@dataclass(frozen=True)
class MapResource:
    root_offset: int
    identity: str
    flag_80: int
    flag_81: int
    node_count: int
    node_array_pointer_field: int
    node_array_offset: int
    nodes: tuple[RTBTreeNode, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "root_offset": _hex(self.root_offset),
            "identity": self.identity,
            "flag_80": self.flag_80,
            "flag_81": self.flag_81,
            "node_count": self.node_count,
            "node_array_pointer_field": _hex(self.node_array_pointer_field),
            "node_array_offset": _hex(self.node_array_offset),
            "node_stride": RTB_NODE_SIZE,
            "nodes": [node.to_dict() for node in self.nodes],
        }


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or offset + size > len(value):
        raise MapError(
            f"{label} range 0x{offset:x}..0x{offset + size:x} "
            f"exceeds file-info size 0x{len(value):x}"
        )


def _u16(value: bytes, offset: int, prefix: str) -> int:
    return struct.unpack_from(f"{prefix}H", value, offset)[0]


def _u32(value: bytes, offset: int, prefix: str) -> int:
    return struct.unpack_from(f"{prefix}I", value, offset)[0]


def parse_map_resources(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    endian: str,
    *,
    package_sha256: str,
) -> tuple[MapResource, ...]:
    """Parse every map root and prove its RTB node dependencies.

    The node field names deliberately remain structural. Their spatial
    semantics have not yet been established, so this parser preserves the
    values without assigning guessed meanings.
    """

    prefix = _prefix(endian)
    command_list = tuple(commands)
    map_offsets = tuple(
        command.destination_offset for command in command_list if command.name == "map"
    )
    node_offsets = tuple(
        command.destination_offset
        for command in command_list
        if command.name == "rtb_tree_node"
    )
    pointer_fields = {
        command.destination_offset
        for command in command_list
        if command.name == "file_info_pointer"
    }

    if any(offset is None for offset in map_offsets + node_offsets):
        raise MapError("map or RTB node command is missing a destination")

    maps: list[MapResource] = []
    consumed_node_offsets: set[int] = set()
    for root_offset_or_none in map_offsets:
        assert root_offset_or_none is not None
        root_offset = root_offset_or_none
        _require_range(file_info, root_offset, MAP_ROOT_MINIMUM_SIZE, "map root")

        node_count = _u16(file_info, root_offset + 0x82, prefix)
        node_array_field = root_offset + 0x90
        node_array_offset = _u32(file_info, node_array_field, prefix)
        if node_array_field not in pointer_fields:
            raise MapError(
                f"map node-array field 0x{node_array_field:x} has no pointer relocation"
            )
        if node_array_offset % 4:
            raise MapError(f"unaligned RTB node array offset 0x{node_array_offset:x}")

        array_size = node_count * RTB_NODE_SIZE
        _require_range(file_info, node_array_offset, array_size, "RTB node array")
        expected_offsets = tuple(
            node_array_offset + index * RTB_NODE_SIZE for index in range(node_count)
        )
        available_offsets = tuple(
            offset
            for offset in node_offsets
            if offset is not None
            and node_array_offset <= offset < node_array_offset + array_size
        )
        if available_offsets != expected_offsets:
            raise MapError(
                "RTB resource references do not exactly cover the declared "
                f"node array at 0x{node_array_offset:x}: "
                f"expected {node_count}, found {len(available_offsets)}"
            )

        nodes: list[RTBTreeNode] = []
        for index, resource_offset in enumerate(expected_offsets):
            payload_pointer_field = resource_offset + 0x2C
            if payload_pointer_field not in pointer_fields:
                raise MapError(
                    f"RTB node {index} payload field "
                    f"0x{payload_pointer_field:x} has no pointer relocation"
                )
            payload_offset = _u32(file_info, payload_pointer_field, prefix)
            if payload_offset % 4:
                raise MapError(
                    f"RTB node {index} has unaligned payload 0x{payload_offset:x}"
                )
            _require_range(file_info, payload_offset, 4, f"RTB node {index} payload")
            raw = file_info[resource_offset : resource_offset + RTB_NODE_SIZE]
            nodes.append(
                RTBTreeNode(
                    index=index,
                    resource_offset=resource_offset,
                    identity=_stable_id(package_sha256, "rtb-node", resource_offset),
                    loader_placeholder=_u32(file_info, resource_offset, prefix),
                    constant_0c=_u32(file_info, resource_offset + 0x0C, prefix),
                    spatial_word_20=_u32(file_info, resource_offset + 0x20, prefix),
                    spatial_word_24=_u32(file_info, resource_offset + 0x24, prefix),
                    spatial_word_28=_u32(file_info, resource_offset + 0x28, prefix),
                    payload_pointer_field=payload_pointer_field,
                    payload_offset=payload_offset,
                    payload_identity=_stable_id(
                        package_sha256, "rtb-payload", payload_offset
                    ),
                    raw_sha256=hashlib.sha256(raw).hexdigest(),
                )
            )
            consumed_node_offsets.add(resource_offset)

        maps.append(
            MapResource(
                root_offset=root_offset,
                identity=_stable_id(package_sha256, "map", root_offset),
                flag_80=file_info[root_offset + 0x80],
                flag_81=file_info[root_offset + 0x81],
                node_count=node_count,
                node_array_pointer_field=node_array_field,
                node_array_offset=node_array_offset,
                nodes=tuple(nodes),
            )
        )

    unexpected = {
        offset for offset in node_offsets if offset is not None
    } - consumed_node_offsets
    if unexpected:
        first = min(unexpected)
        raise MapError(f"RTB node reference 0x{first:x} is not owned by a map root")

    return tuple(maps)


def map_manifest(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    endian: str,
    *,
    package_sha256: str,
) -> dict[str, object]:
    """Build a versioned map manifest and explicit dependency edges."""

    maps = parse_map_resources(
        file_info,
        commands,
        endian,
        package_sha256=package_sha256,
    )
    dependencies: list[dict[str, str]] = []
    for map_resource in maps:
        for node in map_resource.nodes:
            dependencies.append(
                {
                    "from": map_resource.identity,
                    "to": node.identity,
                    "relationship": "owns_spatial_node",
                }
            )
            dependencies.append(
                {
                    "from": node.identity,
                    "to": node.payload_identity,
                    "relationship": "references_payload",
                }
            )
    return {
        "schema": MAP_SCHEMA,
        "package_sha256": package_sha256,
        "map_count": len(maps),
        "node_count": sum(map_resource.node_count for map_resource in maps),
        "maps": [map_resource.to_dict() for map_resource in maps],
        "dependencies": dependencies,
    }

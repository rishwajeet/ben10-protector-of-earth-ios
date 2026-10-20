"""Wii map draw records, mesh buffers, and GX triangle-strip decoding."""

from __future__ import annotations

import hashlib
import math
import struct
from collections.abc import Iterable
from dataclasses import asdict, dataclass

from protector_native.bigb import RelocationCommand
from protector_native.maps import MapResource, parse_map_resources

WII_MESH_SCHEMA = "protector-native.mesh/wii-v1"
DRAW_RECORD_SIZE = 0x3C
MESH_DESCRIPTOR_SIZE = 0x30
GX_TRIANGLE_STRIP = 0x98


class MeshError(ValueError):
    """Raised when Wii geometry violates the executable-derived layout."""


def _hex(value: int) -> str:
    return f"0x{value:08x}"


def _stable_id(package_sha256: str, kind: str, offset: int) -> str:
    return f"sha256:{package_sha256}/{kind}@0x{offset:08x}"


def _align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or offset + size > len(value):
        raise MeshError(
            f"{label} range 0x{offset:x}..0x{offset + size:x} "
            f"exceeds file-info size 0x{len(value):x}"
        )


def _u32(value: bytes, offset: int) -> int:
    _require_range(value, offset, 4, "u32")
    return struct.unpack_from(">I", value, offset)[0]


def _f32(value: bytes, offset: int) -> float:
    _require_range(value, offset, 4, "f32")
    result = struct.unpack_from(">f", value, offset)[0]
    if not math.isfinite(result):
        raise MeshError(f"non-finite float at file-info offset 0x{offset:x}")
    return result


def _signed_byte(value: int) -> int:
    return value - 256 if value >= 128 else value


@dataclass(frozen=True)
class MeshVertex:
    position_index: int
    normal_index: int
    uv_index: int


@dataclass(frozen=True)
class WiiMesh:
    resource_offset: int
    identity: str
    gx_opcode: int
    gx_primitive: str
    gx_vertex_format: int
    vertex_count: int
    position_count: int
    normal_count: int
    uv_count: int
    attribute_count: int
    index_widths: tuple[int, int, int]
    display_list_offset: int
    display_list_allocated_size: int
    position_buffer_offset: int
    normal_buffer_offset: int
    uv_buffer_offset: int
    positions: tuple[tuple[float, float, float], ...]
    packed_normals: tuple[tuple[int, int, int, int], ...]
    raw_uvs: tuple[tuple[int, int], ...]
    vertices: tuple[MeshVertex, ...]
    descriptor_sha256: str
    display_list_sha256: str

    def triangle_vertex_indices(self) -> tuple[tuple[int, int, int], ...]:
        """Return non-degenerate indices into ``vertices`` for the strip."""

        triangles: list[tuple[int, int, int]] = []
        for index in range(2, len(self.vertices)):
            a, b, c = index - 2, index - 1, index
            if index % 2:
                a, b = b, a
            positions = {
                self.vertices[a].position_index,
                self.vertices[b].position_index,
                self.vertices[c].position_index,
            }
            if len(positions) == 3:
                triangles.append((a, b, c))
        return tuple(triangles)

    def bounds(self) -> dict[str, list[float]]:
        axes = tuple(zip(*self.positions))
        return {
            "minimum": [min(axis) for axis in axes],
            "maximum": [max(axis) for axis in axes],
        }

    def to_dict(self) -> dict[str, object]:
        return {
            "resource_offset": _hex(self.resource_offset),
            "identity": self.identity,
            "gx_opcode": f"0x{self.gx_opcode:02x}",
            "gx_primitive": self.gx_primitive,
            "gx_vertex_format": self.gx_vertex_format,
            "vertex_count": self.vertex_count,
            "triangle_count": len(self.triangle_vertex_indices()),
            "position_count": self.position_count,
            "normal_count": self.normal_count,
            "uv_count": self.uv_count,
            "attribute_count": self.attribute_count,
            "index_widths": list(self.index_widths),
            "display_list_offset": _hex(self.display_list_offset),
            "display_list_allocated_size": self.display_list_allocated_size,
            "position_buffer_offset": _hex(self.position_buffer_offset),
            "normal_buffer_offset": _hex(self.normal_buffer_offset),
            "uv_buffer_offset": _hex(self.uv_buffer_offset),
            "bounds": self.bounds(),
            "descriptor_sha256": self.descriptor_sha256,
            "display_list_sha256": self.display_list_sha256,
        }


@dataclass(frozen=True)
class WiiDrawRecord:
    node_index: int
    node_name: str
    list_kind: str
    list_index: int
    resource_offset: int
    identity: str
    material_offset: int
    material_identity: str
    material_target_offset: int
    material_target_kind: str
    material_target_identity: str | None
    material_state: tuple[int, int, int, int]
    material_color: tuple[int, int, int, int]
    material_scalar_18: float
    material_scalar_1c: float
    mesh: WiiMesh
    metric_0c: float
    metric_10: float
    word_24: int
    word_28: int
    word_2c: int
    word_30: int
    word_34: int
    word_38: int
    raw_sha256: str

    def to_dict(self) -> dict[str, object]:
        value = asdict(self)
        value.pop("mesh")
        for name in (
            "resource_offset",
            "material_offset",
            "material_target_offset",
            "word_24",
            "word_28",
            "word_2c",
            "word_30",
            "word_34",
            "word_38",
        ):
            value[name] = _hex(value[name])
        value["mesh"] = self.mesh.to_dict()
        return value


@dataclass(frozen=True)
class WiiMapGeometry:
    map_resource: MapResource
    draws: tuple[WiiDrawRecord, ...]

    def to_dict(self) -> dict[str, object]:
        return {
            "map_identity": self.map_resource.identity,
            "map_root_offset": _hex(self.map_resource.root_offset),
            "node_count": self.map_resource.node_count,
            "draw_count": len(self.draws),
            "mesh_count": len(self.draws),
            "vertex_count": sum(draw.mesh.vertex_count for draw in self.draws),
            "triangle_count": sum(
                len(draw.mesh.triangle_vertex_indices()) for draw in self.draws
            ),
            "draws": [draw.to_dict() for draw in self.draws],
        }


def _decode_name(value: bytes) -> str:
    return value.split(b"\0", 1)[0].decode("ascii", errors="replace")


def _decode_indices(
    file_info: bytes,
    display_list_offset: int,
    display_list_allocated_size: int,
    vertex_count: int,
    position_count: int,
    normal_count: int,
    uv_buffer_offset: int,
) -> tuple[tuple[MeshVertex, ...], tuple[int, int, int], int]:
    position_width = 2 if position_count > 0xFF else 1
    normal_width = 2 if normal_count > 0xFF else 1

    # The format uses the narrowest UV indices that satisfy the command and
    # buffer bounds. This resolves all catalog records; a single tiny triangle
    # is technically compatible with both widths, and the one-byte encoding is
    # confirmed by the non-zero UV followed by zero alignment padding.
    for uv_width in (1, 2):
        widths = (position_width, normal_width, uv_width)
        stride = sum(widths)
        command_size = 3 + vertex_count * stride
        if _align(command_size, 0x20) != display_list_allocated_size:
            continue
        _require_range(
            file_info,
            display_list_offset,
            command_size,
            "GX display list",
        )
        cursor = display_list_offset + 3
        vertices: list[MeshVertex] = []
        valid = True
        for _ in range(vertex_count):
            indices: list[int] = []
            for width in widths:
                indices.append(
                    int.from_bytes(file_info[cursor : cursor + width], "big")
                )
                cursor += width
            position_index, normal_index, uv_index = indices
            if position_index >= position_count or normal_index >= normal_count:
                valid = False
                break
            vertices.append(MeshVertex(position_index, normal_index, uv_index))
        if not valid:
            continue
        uv_count = max(vertex.uv_index for vertex in vertices) + 1
        if uv_buffer_offset + uv_count * 4 <= display_list_offset:
            return tuple(vertices), widths, uv_count

    raise MeshError(
        f"no valid GX index-width layout for display list at 0x{display_list_offset:x}"
    )


def _parse_mesh(
    file_info: bytes,
    offset: int,
    pointer_fields: set[int | None],
    package_sha256: str,
) -> WiiMesh:
    _require_range(file_info, offset, MESH_DESCRIPTOR_SIZE, "mesh descriptor")
    vertex_count = _u32(file_info, offset)
    position_count = _u32(file_info, offset + 0x04)
    attribute_count = _u32(file_info, offset + 0x08)
    display_list_allocated_size = _u32(file_info, offset + 0x0C)
    if vertex_count < 3 or position_count == 0:
        raise MeshError(
            f"invalid mesh counts at 0x{offset:x}: "
            f"{vertex_count} vertices, {position_count} positions"
        )
    if attribute_count != 3:
        raise MeshError(
            f"unsupported attribute count {attribute_count} at mesh 0x{offset:x}"
        )

    pointer_offsets = (0x10, 0x18, 0x20, 0x28)
    for relative in pointer_offsets:
        field = offset + relative
        if field not in pointer_fields:
            raise MeshError(f"mesh pointer field 0x{field:x} has no relocation")
    display_list_offset, position_offset, normal_offset, uv_offset = (
        _u32(file_info, offset + relative) for relative in pointer_offsets
    )
    if not (position_offset <= normal_offset <= uv_offset <= display_list_offset):
        raise MeshError(f"mesh buffers at 0x{offset:x} are not in structural order")
    if normal_offset - position_offset != position_count * 12:
        raise MeshError(f"position buffer size mismatch at mesh 0x{offset:x}")
    if (uv_offset - normal_offset) % 4:
        raise MeshError(f"packed-normal buffer is misaligned at 0x{offset:x}")
    normal_count = (uv_offset - normal_offset) // 4
    if normal_count == 0:
        raise MeshError(f"mesh 0x{offset:x} has no packed normals")

    _require_range(
        file_info,
        display_list_offset,
        display_list_allocated_size,
        "GX display-list allocation",
    )
    gx_opcode = file_info[display_list_offset]
    if gx_opcode & 0xF8 != GX_TRIANGLE_STRIP:
        raise MeshError(
            f"unsupported GX primitive 0x{gx_opcode:02x} at 0x{display_list_offset:x}"
        )
    command_vertex_count = struct.unpack_from(">H", file_info, display_list_offset + 1)[
        0
    ]
    if command_vertex_count != vertex_count:
        raise MeshError(
            f"GX count {command_vertex_count} does not match descriptor "
            f"count {vertex_count} at 0x{offset:x}"
        )

    vertices, index_widths, uv_count = _decode_indices(
        file_info,
        display_list_offset,
        display_list_allocated_size,
        vertex_count,
        position_count,
        normal_count,
        uv_offset,
    )
    _require_range(file_info, position_offset, position_count * 12, "position buffer")
    positions = tuple(
        (
            _f32(file_info, position_offset + index * 12),
            _f32(file_info, position_offset + index * 12 + 4),
            _f32(file_info, position_offset + index * 12 + 8),
        )
        for index in range(position_count)
    )
    packed_normals = tuple(
        tuple(
            _signed_byte(component)
            for component in file_info[
                normal_offset + index * 4 : normal_offset + index * 4 + 4
            ]
        )
        for index in range(normal_count)
    )
    _require_range(file_info, uv_offset, uv_count * 4, "UV buffer")
    raw_uvs = tuple(
        struct.unpack_from(">hh", file_info, uv_offset + index * 4)
        for index in range(uv_count)
    )
    command_size = 3 + vertex_count * sum(index_widths)
    descriptor = file_info[offset : offset + MESH_DESCRIPTOR_SIZE]
    display_list = file_info[display_list_offset : display_list_offset + command_size]
    return WiiMesh(
        resource_offset=offset,
        identity=_stable_id(package_sha256, "wii-mesh", offset),
        gx_opcode=gx_opcode,
        gx_primitive="triangle_strip",
        gx_vertex_format=gx_opcode & 0x07,
        vertex_count=vertex_count,
        position_count=position_count,
        normal_count=normal_count,
        uv_count=uv_count,
        attribute_count=attribute_count,
        index_widths=index_widths,
        display_list_offset=display_list_offset,
        display_list_allocated_size=display_list_allocated_size,
        position_buffer_offset=position_offset,
        normal_buffer_offset=normal_offset,
        uv_buffer_offset=uv_offset,
        positions=positions,
        packed_normals=packed_normals,
        raw_uvs=raw_uvs,
        vertices=vertices,
        descriptor_sha256=hashlib.sha256(descriptor).hexdigest(),
        display_list_sha256=hashlib.sha256(display_list).hexdigest(),
    )


def parse_wii_map_geometry(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> tuple[WiiMapGeometry, ...]:
    """Parse Wii map nodes into draw records and independent mesh buffers."""

    command_list = tuple(commands)
    pointer_fields = {
        command.destination_offset
        for command in command_list
        if command.name == "file_info_pointer"
    }
    resource_references = {
        command.destination_offset: command
        for command in command_list
        if command.kind == "resource_reference"
        and command.destination_offset is not None
    }
    maps = parse_map_resources(
        file_info,
        command_list,
        "big",
        package_sha256=package_sha256,
    )
    output: list[WiiMapGeometry] = []
    for map_resource in maps:
        draws: list[WiiDrawRecord] = []
        for node in map_resource.nodes:
            payload = node.payload_offset
            _require_range(file_info, payload, 0x30, "RTB render payload")
            for relative in (0, 4, 8):
                if payload + relative not in pointer_fields:
                    raise MeshError(
                        f"RTB payload pointer field "
                        f"0x{payload + relative:x} has no relocation"
                    )
            begin, split, end = (
                _u32(file_info, payload + relative) for relative in (0, 4, 8)
            )
            if not begin <= split <= end <= len(file_info):
                raise MeshError(
                    f"invalid draw ranges for node {node.index}: "
                    f"0x{begin:x}, 0x{split:x}, 0x{end:x}"
                )
            if (split - begin) % DRAW_RECORD_SIZE or (end - split) % DRAW_RECORD_SIZE:
                raise MeshError(
                    f"draw ranges for node {node.index} are not "
                    f"multiples of 0x{DRAW_RECORD_SIZE:x}"
                )
            node_name = _decode_name(file_info[payload + 0x20 : payload + 0x30])
            for list_kind, list_begin, list_end in (
                ("primary", begin, split),
                ("secondary", split, end),
            ):
                for list_index, draw_offset in enumerate(
                    range(list_begin, list_end, DRAW_RECORD_SIZE)
                ):
                    _require_range(
                        file_info,
                        draw_offset,
                        DRAW_RECORD_SIZE,
                        "draw record",
                    )
                    for relative in (0, 0x1C):
                        if draw_offset + relative not in pointer_fields:
                            raise MeshError(
                                f"draw pointer field "
                                f"0x{draw_offset + relative:x} "
                                "has no relocation"
                            )
                    material_offset = _u32(file_info, draw_offset)
                    mesh_offset = _u32(file_info, draw_offset + 0x1C)
                    _require_range(
                        file_info, material_offset, 0x20, "material resource"
                    )
                    material_target_offset = _u32(file_info, material_offset + 0x08)
                    if (
                        material_target_offset
                        and material_offset + 0x08 not in pointer_fields
                    ):
                        raise MeshError(
                            f"material target field "
                            f"0x{material_offset + 0x08:x} "
                            "has no pointer relocation"
                        )
                    target_command = resource_references.get(material_target_offset)
                    if material_target_offset and target_command is None:
                        raise MeshError(
                            f"material 0x{material_offset:x} target "
                            f"0x{material_target_offset:x} is not a "
                            "resource reference"
                        )
                    material_target_kind = (
                        target_command.name if target_command else "null"
                    )
                    material_target_identity = (
                        _stable_id(
                            package_sha256,
                            material_target_kind.replace("_", "-"),
                            material_target_offset,
                        )
                        if target_command
                        else None
                    )
                    mesh = _parse_mesh(
                        file_info,
                        mesh_offset,
                        pointer_fields,
                        package_sha256,
                    )
                    raw = file_info[draw_offset : draw_offset + DRAW_RECORD_SIZE]
                    draws.append(
                        WiiDrawRecord(
                            node_index=node.index,
                            node_name=node_name,
                            list_kind=list_kind,
                            list_index=list_index,
                            resource_offset=draw_offset,
                            identity=_stable_id(
                                package_sha256, "wii-draw", draw_offset
                            ),
                            material_offset=material_offset,
                            material_identity=_stable_id(
                                package_sha256,
                                "wii-material",
                                material_offset,
                            ),
                            material_target_offset=material_target_offset,
                            material_target_kind=material_target_kind,
                            material_target_identity=material_target_identity,
                            material_state=tuple(
                                file_info[
                                    material_offset + 0x0C : material_offset + 0x10
                                ]
                            ),
                            material_color=tuple(
                                file_info[
                                    material_offset + 0x14 : material_offset + 0x18
                                ]
                            ),
                            material_scalar_18=_f32(file_info, material_offset + 0x18),
                            material_scalar_1c=_f32(file_info, material_offset + 0x1C),
                            mesh=mesh,
                            metric_0c=_f32(file_info, draw_offset + 0x0C),
                            metric_10=_f32(file_info, draw_offset + 0x10),
                            word_24=_u32(file_info, draw_offset + 0x24),
                            word_28=_u32(file_info, draw_offset + 0x28),
                            word_2c=_u32(file_info, draw_offset + 0x2C),
                            word_30=_u32(file_info, draw_offset + 0x30),
                            word_34=_u32(file_info, draw_offset + 0x34),
                            word_38=_u32(file_info, draw_offset + 0x38),
                            raw_sha256=hashlib.sha256(raw).hexdigest(),
                        )
                    )
        output.append(WiiMapGeometry(map_resource, tuple(draws)))
    return tuple(output)


def wii_geometry_manifest(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
) -> dict[str, object]:
    geometries = parse_wii_map_geometry(
        file_info,
        commands,
        package_sha256=package_sha256,
    )
    dependencies: list[dict[str, str]] = []
    for geometry in geometries:
        for draw in geometry.draws:
            dependencies.extend(
                (
                    {
                        "from": draw.identity,
                        "to": draw.material_identity,
                        "relationship": "uses_material",
                    },
                    {
                        "from": draw.identity,
                        "to": draw.mesh.identity,
                        "relationship": "draws_mesh",
                    },
                )
            )
            if draw.material_target_identity is not None:
                dependencies.append(
                    {
                        "from": draw.material_identity,
                        "to": draw.material_target_identity,
                        "relationship": "samples_resource",
                    }
                )
    return {
        "schema": WII_MESH_SCHEMA,
        "package_sha256": package_sha256,
        "map_count": len(geometries),
        "node_count": sum(geometry.map_resource.node_count for geometry in geometries),
        "draw_count": sum(len(geometry.draws) for geometry in geometries),
        "mesh_count": sum(len(geometry.draws) for geometry in geometries),
        "vertex_count": sum(
            draw.mesh.vertex_count for geometry in geometries for draw in geometry.draws
        ),
        "triangle_count": sum(
            len(draw.mesh.triangle_vertex_indices())
            for geometry in geometries
            for draw in geometry.draws
        ),
        "dependencies": dependencies,
        "maps": [geometry.to_dict() for geometry in geometries],
    }

"""Typed Wii character skin, mesh, and CPU-skinning reconstruction."""

from __future__ import annotations

import hashlib
import math
import struct
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from protector_native.bigb import RelocationCommand
from protector_native.skinning import SkinningPalette, parse_wii_skinning_palettes

CHARACTER_SKIN_SCHEMA = "protector-native.character-skin/wii-v2"
DRAW_RECORD_SIZE = 0x3C
CHARACTER_MESH_SIZE = 0x38
WEIGHTS_PER_VERTEX = 3
WEIGHT_RECORD_SIZE = 4
GX_TRIANGLE_STRIP_VAT6 = 0x9E


class CharacterSkinError(ValueError):
    """Raised when a character skin violates the executable-derived layout."""


def _hex(value: int) -> str:
    return f"0x{value:08x}"


def _require_range(value: bytes, offset: int, size: int, label: str) -> None:
    if offset < 0 or size < 0 or offset + size > len(value):
        raise CharacterSkinError(
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
        raise CharacterSkinError(f"non-finite float at 0x{offset:x}")
    return result


@dataclass(frozen=True)
class BoneInfluence:
    bone_index: int
    weight_u16: int
    palette_index: int | None = None

    @property
    def weight(self) -> float:
        # fn_8002CB0C multiplies U16 weights by lbl_80309FB8.
        return self.weight_u16 / 65535.0


@dataclass(frozen=True)
class CharacterMeshVertex:
    position_index: int
    normal_index: int | None
    uv_index: int
    color_index: int | None = None


@dataclass(frozen=True)
class WiiCharacterMesh:
    offset: int
    display_list_offset: int
    display_list_allocated_size: int
    weight_buffer_offset: int
    position_buffer_offset: int
    normal_buffer_offset: int
    uv_buffer_offset: int
    vertex_count: int
    unique_vertex_count: int
    influences: tuple[tuple[BoneInfluence, ...], ...]
    positions: tuple[tuple[float, float, float], ...]
    normals: tuple[tuple[float, float, float], ...]
    vertices: tuple[CharacterMeshVertex, ...]
    display_list: bytes
    weights_sha256: str
    positions_sha256: str
    normals_sha256: str
    display_list_sha256: str
    index_widths: tuple[int, int, int]
    middle_attribute: str
    color_buffer_offset: int
    colors: tuple[tuple[int, int, int, int], ...]
    raw_uvs: tuple[tuple[int, int], ...]
    colors_sha256: str
    uvs_sha256: str
    source_anchor_prefix_bytes: int
    source_anchor_sha256: str

    def triangle_vertex_indices(self) -> tuple[tuple[int, int, int], ...]:
        triangles: list[tuple[int, int, int]] = []
        for index in range(2, len(self.vertices)):
            a, b, c = index - 2, index - 1, index
            if index % 2:
                a, b = b, a
            if len(
                {
                    self.vertices[a].position_index,
                    self.vertices[b].position_index,
                    self.vertices[c].position_index,
                }
            ) == 3:
                triangles.append((a, b, c))
        return tuple(triangles)


@dataclass(frozen=True)
class WiiCharacterSkin:
    package_sha256: str
    binding_offset: int
    model_offset: int
    model_name: str
    draw_index: int
    draw_offset: int
    draw_count: int
    material_offset: int
    palette_set_offset: int
    palette: SkinningPalette
    mesh: WiiCharacterMesh
    draw_sha256: str

    def to_dict(self) -> dict[str, object]:
        mesh = self.mesh
        weight_counts = [
            sum(1 for influence in influences if influence.weight_u16)
            for influences in mesh.influences
        ]
        used_bones = sorted(
            {
                influence.bone_index
                for influences in mesh.influences
                for influence in influences
                if influence.weight_u16
            }
        )
        return {
            "schema": CHARACTER_SKIN_SCHEMA,
            "package_sha256": self.package_sha256,
            "binding_offset": _hex(self.binding_offset),
            "model_offset": _hex(self.model_offset),
            "model_name": self.model_name,
            "draw_index": self.draw_index,
            "draw_offset": _hex(self.draw_offset),
            "draw_count": self.draw_count,
            "material_offset": _hex(self.material_offset),
            "palette_set_offset": _hex(self.palette_set_offset),
            "palette": self.palette.to_dict(),
            "mesh": {
                "offset": _hex(mesh.offset),
                "vertex_count": mesh.vertex_count,
                "unique_vertex_count": mesh.unique_vertex_count,
                "triangle_count": len(mesh.triangle_vertex_indices()),
                "display_list_offset": _hex(mesh.display_list_offset),
                "display_list_allocated_size": mesh.display_list_allocated_size,
                "weight_buffer_offset": _hex(mesh.weight_buffer_offset),
                "position_buffer_offset": _hex(mesh.position_buffer_offset),
                "normal_buffer_offset": _hex(mesh.normal_buffer_offset),
                "uv_buffer_offset": _hex(mesh.uv_buffer_offset),
                "color_buffer_offset": _hex(mesh.color_buffer_offset),
                "middle_attribute": mesh.middle_attribute,
                "index_widths": list(mesh.index_widths),
                "normal_count": len(mesh.normals),
                "color_count": len(mesh.colors),
                "uv_count": len(mesh.raw_uvs),
                "used_bone_indices": used_bones,
                "influence_count_minimum": min(weight_counts),
                "influence_count_maximum": max(weight_counts),
                "weights_sha256": mesh.weights_sha256,
                "positions_sha256": mesh.positions_sha256,
                "normals_sha256": mesh.normals_sha256,
                "colors_sha256": mesh.colors_sha256,
                "source_anchor_prefix_bytes": mesh.source_anchor_prefix_bytes,
                "source_anchor_sha256": mesh.source_anchor_sha256,
                "uvs_sha256": mesh.uvs_sha256,
                "display_list_sha256": mesh.display_list_sha256,
            },
            "draw_sha256": self.draw_sha256,
        }


def _parse_character_mesh(
    file_info: bytes,
    offset: int,
    pointer_fields: set[int],
    attributes: bytes,
    palette: SkinningPalette,
) -> WiiCharacterMesh:
    _require_range(file_info, offset, CHARACTER_MESH_SIZE, "character mesh")
    vertex_count = _u32(file_info, offset)
    unique_vertex_count = _u32(file_info, offset + 4)
    attribute_count = _u32(file_info, offset + 8)
    allocated_size = _u32(file_info, offset + 0x0C)
    if vertex_count < 3 or unique_vertex_count == 0:
        raise CharacterSkinError("character mesh has invalid vertex counts")
    if attribute_count != 3:
        raise CharacterSkinError(
            f"character mesh has unsupported attribute count {attribute_count}"
        )

    # fn_80021A34 binds +1c to GX_NRM and +20 to GX_CLR0. The
    # outline passes use colors, not a synthetic constant skinned normal.
    # fn_80021EF8..80021F3C passes the low two descriptor bits to GXSetVtxDesc:
    # 2 is INDEX8 and 3 is INDEX16. Do not guess width from buffer counts.
    normal_enabled = bool(attributes[2] & 3)
    color_enabled = bool(attributes[4] & 3)
    if normal_enabled == color_enabled or any(attributes[i] & 3 for i in (3, 5, *range(7, 14))):
        raise CharacterSkinError("unsupported character attribute combination")
    middle_slot = 2 if normal_enabled else 4
    slots = (1, middle_slot, 6)
    if any(attributes[i] & 3 not in (2, 3) for i in slots):
        raise CharacterSkinError("character attributes must use indexed GX data")
    expected_formats = (0x24, 0x08 if normal_enabled else 0x2C, 0x1C)
    if any(attributes[i] & 0x3C != expected for i, expected in zip(slots, expected_formats, strict=True)):
        raise CharacterSkinError("unsupported character position/normal/color/UV format")
    index_widths = tuple((attributes[i] & 3) - 1 for i in slots)
    pointer_relatives = (0x10, 0x14, 0x18, 0x1C if normal_enabled else 0x20, 0x28)
    for relative in pointer_relatives:
        if offset + relative not in pointer_fields:
            raise CharacterSkinError(
                f"character mesh pointer 0x{offset + relative:x} has no relocation"
            )
    (
        display_list_offset,
        weight_offset,
        position_offset,
        middle_offset,
        uv_offset,
    ) = tuple(_u32(file_info, offset + relative) for relative in pointer_relatives)

    weight_size = unique_vertex_count * WEIGHTS_PER_VERTEX * WEIGHT_RECORD_SIZE
    position_size = unique_vertex_count * 12
    normal_offset = middle_offset if normal_enabled else 0
    color_offset = 0 if normal_enabled else middle_offset
    normal_size = unique_vertex_count * 3 if normal_enabled else 0
    if weight_offset + weight_size != position_offset:
        raise CharacterSkinError("character weight buffer is not structurally bounded")
    if position_offset + position_size != middle_offset:
        raise CharacterSkinError(
            "character position buffer is not structurally bounded"
        )
    if normal_enabled:
        if (normal_offset + normal_size + 3) & ~3 != uv_offset:
            raise CharacterSkinError("character packed-normal buffer has invalid padding")
    elif uv_offset <= color_offset or (uv_offset - color_offset) % 4:
        raise CharacterSkinError("character RGBA8 color buffer is not structurally bounded")
    _require_range(file_info, weight_offset, weight_size, "character weights")
    _require_range(file_info, position_offset, position_size, "character positions")
    _require_range(file_info, normal_offset, normal_size, "character normals")
    _require_range(file_info, middle_offset, uv_offset - middle_offset, "character middle attribute")
    if uv_offset > display_list_offset:
        raise CharacterSkinError("character UV buffer follows its display list")

    influences: list[tuple[BoneInfluence, ...]] = []
    for vertex_index in range(unique_vertex_count):
        vertex_influences: list[BoneInfluence] = []
        reached_terminator = False
        for influence_index in range(WEIGHTS_PER_VERTEX):
            record = (
                weight_offset
                + (
                    vertex_index * WEIGHTS_PER_VERTEX + influence_index
                )
                * WEIGHT_RECORD_SIZE
            )
            palette_index, weight = struct.unpack_from(">HH", file_info, record)
            if weight:
                if reached_terminator:
                    raise CharacterSkinError(
                        f"vertex {vertex_index} resumes after a zero-weight terminator"
                    )
                # fn_8001AD24 builds the matrix-pointer table in palette order;
                # fn_8002CB0C indexes that table with this local U16 index.
                if palette_index >= len(palette.bone_indices):
                    raise CharacterSkinError(f"vertex {vertex_index} has an out-of-range palette index")
                vertex_influences.append(BoneInfluence(palette.bone_indices[palette_index], weight, palette_index))
            else:
                reached_terminator = True
        if not vertex_influences:
            raise CharacterSkinError(f"vertex {vertex_index} has no influences")
        if sum(item.weight_u16 for item in vertex_influences) not in {65534, 65535, 65536}:
            raise CharacterSkinError(
                f"vertex {vertex_index} has a noncanonical weight sum"
            )
        influences.append(tuple(vertex_influences))

    positions = tuple(
        (
            _f32(file_info, position_offset + index * 12),
            _f32(file_info, position_offset + index * 12 + 4),
            _f32(file_info, position_offset + index * 12 + 8),
        )
        for index in range(unique_vertex_count)
    )
    normals = tuple(
        tuple(
            int.from_bytes(
                file_info[
                    normal_offset + index * 3 + axis :
                    normal_offset + index * 3 + axis + 1
                ],
                "big",
                signed=True,
            )
            / 64.0
            for axis in range(3)
        )
        for index in range(unique_vertex_count if normal_enabled else 0)
    )
    colors = tuple(tuple(file_info[i:i + 4]) for i in range(color_offset, uv_offset, 4)) if color_enabled else ()
    command_size = 3 + vertex_count * sum(index_widths)
    if (command_size + 31) & ~31 != allocated_size:
        raise CharacterSkinError("character display-list allocation disagrees with its attribute widths")
    _require_range(
        file_info,
        display_list_offset,
        allocated_size,
        "character display list",
    )
    display_list = file_info[display_list_offset : display_list_offset + command_size]
    if display_list[0] != GX_TRIANGLE_STRIP_VAT6:
        raise CharacterSkinError(
            f"unsupported character GX opcode 0x{display_list[0]:02x}"
        )
    if int.from_bytes(display_list[1:3], "big") != vertex_count:
        raise CharacterSkinError("character GX vertex count disagrees with descriptor")
    vertices_list = []
    cursor = 3
    for _ in range(vertex_count):
        indices = []
        for width in index_widths:
            indices.append(int.from_bytes(display_list[cursor:cursor + width], "big"))
            cursor += width
        position, middle, uv = indices
        vertices_list.append(CharacterMeshVertex(position, middle if normal_enabled else None, uv,
                                                 middle if color_enabled else None))
    vertices = tuple(vertices_list)
    if max(vertex.position_index for vertex in vertices) >= unique_vertex_count:
        raise CharacterSkinError("character position index exceeds source buffer")
    if normal_enabled and max(vertex.normal_index for vertex in vertices) >= unique_vertex_count:
        raise CharacterSkinError("character normal index exceeds source buffer")
    if color_enabled and max(vertex.color_index for vertex in vertices) >= len(colors):
        raise CharacterSkinError("character color index exceeds source buffer")
    uv_count = max(vertex.uv_index for vertex in vertices) + 1
    if uv_offset + uv_count * 4 > (
        display_list_offset
    ):
        raise CharacterSkinError("character UV indices exceed source buffer")
    raw_uvs = tuple(struct.unpack_from(">hh", file_info, uv_offset + index * 4) for index in range(uv_count))

    return WiiCharacterMesh(
        offset=offset,
        display_list_offset=display_list_offset,
        display_list_allocated_size=allocated_size,
        weight_buffer_offset=weight_offset,
        position_buffer_offset=position_offset,
        normal_buffer_offset=normal_offset,
        uv_buffer_offset=uv_offset,
        vertex_count=vertex_count,
        unique_vertex_count=unique_vertex_count,
        influences=tuple(influences),
        positions=positions,
        normals=normals,
        vertices=vertices,
        display_list=display_list,
        weights_sha256=hashlib.sha256(
            file_info[weight_offset : weight_offset + weight_size]
        ).hexdigest(),
        positions_sha256=hashlib.sha256(
            file_info[position_offset : position_offset + position_size]
        ).hexdigest(),
        normals_sha256=hashlib.sha256(
            file_info[normal_offset : normal_offset + normal_size]
        ).hexdigest(),
        display_list_sha256=hashlib.sha256(display_list).hexdigest(),
        index_widths=index_widths,
        middle_attribute="normal" if normal_enabled else "color0",
        color_buffer_offset=color_offset,
        colors=colors,
        raw_uvs=raw_uvs,
        colors_sha256=hashlib.sha256(file_info[color_offset:uv_offset] if color_enabled else b"").hexdigest(),
        uvs_sha256=hashlib.sha256(file_info[uv_offset:uv_offset + uv_count * 4]).hexdigest(),
        source_anchor_prefix_bytes=uv_offset - weight_offset,
        source_anchor_sha256=hashlib.sha256(file_info[weight_offset:uv_offset + uv_count * 4]).hexdigest(),
    )


def parse_wii_character_skin(
    file_info: bytes,
    commands: Iterable[RelocationCommand],
    *,
    package_sha256: str,
    binding_offset: int,
    draw_index: int = 0,
) -> WiiCharacterSkin:
    """Parse one source-bound model/palette pair used by ``ass_SetSkin``."""

    command_list = tuple(commands)
    pointer_fields = {
        command.destination_offset
        for command in command_list
        if command.name == "file_info_pointer"
        and command.destination_offset is not None
    }
    for field in (binding_offset, binding_offset + 8):
        if field not in pointer_fields:
            raise CharacterSkinError(
                f"skin binding pointer 0x{field:x} has no relocation"
            )
    _require_range(file_info, binding_offset, 0x0C, "skin binding")
    model_offset = _u32(file_info, binding_offset)
    palette_set_offset = _u32(file_info, binding_offset + 8)

    palettes = parse_wii_skinning_palettes(
        file_info,
        command_list,
        package_sha256=package_sha256,
    )
    palette_set = next(
        (item for item in palettes if item.offset == palette_set_offset),
        None,
    )
    if palette_set is None:
        raise CharacterSkinError(
            f"skin binding references unknown palette set 0x{palette_set_offset:x}"
        )
    if len(palette_set.palettes) != 1:
        raise CharacterSkinError("character palette set is not singular")

    _require_range(file_info, model_offset, 0x54, "character model")
    if model_offset not in pointer_fields or model_offset + 4 not in pointer_fields:
        raise CharacterSkinError("character model draw range lacks relocations")
    draw_start = _u32(file_info, model_offset)
    draw_split = _u32(file_info, model_offset + 4)
    draw_end = _u32(file_info, model_offset + 8) if model_offset + 8 in pointer_fields else draw_split
    if not draw_start <= draw_split <= draw_end or (draw_split - draw_start) % DRAW_RECORD_SIZE or (draw_end - draw_split) % DRAW_RECORD_SIZE:
        raise CharacterSkinError("character model has an invalid draw range")
    _require_range(file_info, draw_start, draw_end - draw_start, "character draws")
    draw_count = (draw_end - draw_start) // DRAW_RECORD_SIZE
    if not 0 <= draw_index < draw_count:
        raise CharacterSkinError(
            f"draw index {draw_index} exceeds model draw count {draw_count}"
        )
    declared_draw_count = file_info[model_offset + 0x50]
    if declared_draw_count != draw_count:
        raise CharacterSkinError(
            f"model declares {declared_draw_count} draws, range contains {draw_count}"
        )
    raw_name = file_info[model_offset + 0x20 : model_offset + 0x30]
    model_name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="strict")

    draw_offset = draw_start + draw_index * DRAW_RECORD_SIZE
    _require_range(file_info, draw_offset, DRAW_RECORD_SIZE, "character draw")
    for field in (draw_offset, draw_offset + 0x1C):
        if field not in pointer_fields:
            raise CharacterSkinError(
                f"character draw pointer 0x{field:x} lacks relocation"
            )
    if int.from_bytes(
        file_info[draw_offset + 9 : draw_offset + 10],
        "big",
        signed=True,
    ) != -1:
        raise CharacterSkinError("selected character draw is not CPU-skinned")
    mesh_count = _u32(file_info, draw_offset + 0x24)
    if mesh_count != 1:
        raise CharacterSkinError(
            f"selected character draw has {mesh_count} meshes; expected 1"
        )
    material_offset = _u32(file_info, draw_offset)
    mesh_offset = _u32(file_info, draw_offset + 0x1C)
    mesh = _parse_character_mesh(file_info, mesh_offset, pointer_fields,
                                 file_info[draw_offset + 0x2C:draw_offset + 0x3C], palette_set.palettes[0])

    return WiiCharacterSkin(
        package_sha256=package_sha256,
        binding_offset=binding_offset,
        model_offset=model_offset,
        model_name=model_name,
        draw_index=draw_index,
        draw_offset=draw_offset,
        draw_count=draw_count,
        material_offset=material_offset,
        palette_set_offset=palette_set_offset,
        palette=palette_set.palettes[0],
        mesh=mesh,
        draw_sha256=hashlib.sha256(
            file_info[draw_offset : draw_offset + DRAW_RECORD_SIZE]
        ).hexdigest(),
    )


def skin_positions(
    positions: Sequence[Sequence[float]],
    influences: Sequence[Sequence[BoneInfluence]],
    matrices: dict[int, Sequence[Sequence[float]]],
) -> tuple[tuple[float, float, float], ...]:
    """Apply the executable's three-influence affine CPU skinning formula."""

    if len(positions) != len(influences):
        raise CharacterSkinError("position and influence counts differ")
    output: list[tuple[float, float, float]] = []
    for position, vertex_influences in zip(positions, influences, strict=True):
        if len(position) != 3:
            raise CharacterSkinError("source position is not float3")
        transformed = [0.0, 0.0, 0.0]
        x, y, z = position
        for influence in vertex_influences:
            matrix = matrices.get(influence.bone_index)
            if matrix is None or len(matrix) != 3 or any(len(row) != 4 for row in matrix):
                raise CharacterSkinError(
                    f"bone {influence.bone_index} has no affine float3x4 matrix"
                )
            weight = influence.weight
            for axis in range(3):
                row = matrix[axis]
                transformed[axis] += weight * (
                    row[0] * x + row[1] * y + row[2] * z + row[3]
                )
        output.append(tuple(transformed))
    return tuple(output)


def skin_normals(
    normals: Sequence[Sequence[float]],
    influences: Sequence[Sequence[BoneInfluence]],
    matrices: dict[int, Sequence[Sequence[float]]],
) -> tuple[tuple[float, float, float], ...]:
    """Apply the same weighted rotations, with no translation, to normals."""

    if len(normals) != len(influences):
        raise CharacterSkinError("normal and influence counts differ")
    output: list[tuple[float, float, float]] = []
    for normal, vertex_influences in zip(normals, influences, strict=True):
        if len(normal) != 3:
            raise CharacterSkinError("source normal is not float3")
        transformed = [0.0, 0.0, 0.0]
        x, y, z = normal
        for influence in vertex_influences:
            matrix = matrices.get(influence.bone_index)
            if matrix is None or len(matrix) != 3 or any(len(row) != 4 for row in matrix):
                raise CharacterSkinError(
                    f"bone {influence.bone_index} has no affine float3x4 matrix"
                )
            weight = influence.weight
            for axis in range(3):
                row = matrix[axis]
                transformed[axis] += weight * (
                    row[0] * x + row[1] * y + row[2] * z
                )
        output.append(tuple(transformed))
    return tuple(output)

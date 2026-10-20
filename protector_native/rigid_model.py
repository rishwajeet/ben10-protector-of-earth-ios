"""Descriptor-driven, non-skinned model geometry for render-only refinement.

The draw's GX descriptors, not buffer position or mesh name, distinguish normals
from RGBA colors. A rigid draw may still move with an original model matrix.
This module decodes immutable source geometry; it never authors game transforms,
collision, weights, or replacement animation.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
import struct

from protector_native.asset_inventory import discover_model_materials
from protector_native.character_skin import CharacterMeshVertex


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class WiiRigidMesh:
    offset: int
    vertex_count: int
    positions: tuple[tuple[float, float, float], ...]
    normals: tuple[tuple[float, float, float], ...]
    colors: tuple[tuple[int, int, int, int], ...]
    raw_uvs: tuple[tuple[int, int], ...]
    vertices: tuple[CharacterMeshVertex, ...]
    index_widths: tuple[int, int, int]
    middle_attribute: str
    display_list: bytes
    display_list_sha256: str
    positions_sha256: str
    normals_sha256: str
    colors_sha256: str
    uvs_sha256: str
    source_anchor_prefix_bytes: int
    source_anchor_sha256: str

    @property
    def influences(self) -> tuple[tuple, ...]:
        # Empty means unweighted. No synthetic skeleton/bone is introduced.
        return ((),) * len(self.positions)

    @property
    def weights_sha256(self) -> str:
        return _sha(b"")

    def triangle_vertex_indices(self) -> tuple[tuple[int, int, int], ...]:
        result = []
        for i in range(2, len(self.vertices)):
            triangle = (i - 1, i - 2, i) if i % 2 else (i - 2, i - 1, i)
            if len({self.vertices[j].position_index for j in triangle}) == 3:
                result.append(triangle)
        return tuple(result)


@dataclass(frozen=True)
class WiiRigidModelDraw:
    package_sha256: str
    source: dict
    mesh: WiiRigidMesh

    @property
    def source_rigid_arrays(self) -> dict[str, int]:
        return {"position_bytes": len(self.mesh.positions) * 12,
                "middle_bytes": len(self.mesh.normals) * 3 if self.mesh.normals else len(self.mesh.colors) * 4}

    def to_dict(self) -> dict:
        mesh = self.mesh
        return {**self.source, "package_sha256": self.package_sha256,
                "mesh": {"offset": f"0x{mesh.offset:08x}", "vertex_count": mesh.vertex_count,
                    "position_count": len(mesh.positions), "normal_count": len(mesh.normals),
                    "color_count": len(mesh.colors), "uv_count": len(mesh.raw_uvs),
                    "triangle_count": len(mesh.triangle_vertex_indices()),
                    "middle_attribute": mesh.middle_attribute, "index_widths": list(mesh.index_widths),
                    "display_list_sha256": mesh.display_list_sha256,
                    "positions_sha256": mesh.positions_sha256, "normals_sha256": mesh.normals_sha256,
                    "colors_sha256": mesh.colors_sha256, "uvs_sha256": mesh.uvs_sha256,
                    "source_anchor_prefix_bytes": mesh.source_anchor_prefix_bytes,
                    "source_anchor_sha256": mesh.source_anchor_sha256,
                    "source_rigid_arrays": self.source_rigid_arrays}}


def parse_wii_rigid_model_draw(file_info: bytes, commands, *, package_sha256: str,
                              model_offset: int, draw_index: int) -> WiiRigidModelDraw:
    """Decode one explicitly selected referenced model draw, or fail closed.

    Uses the original +0x2c GX attribute bytes and +0x1c normal / +0x20 color
    pointers. Weighted draws and unknown attributes are deliberately rejected.
    Normal indices are independent of position indices on rigid prop meshes.
    """
    commands = tuple(commands)
    matches = [row for row in discover_model_materials(file_info, commands)
               if int(row["model_offset"], 16) == model_offset and row["draw_index"] == draw_index]
    if len(matches) != 1:
        raise ValueError("rigid model draw is not uniquely source-referenced")
    source = matches[0]
    if source["declared_mesh_count"] != 1:
        raise ValueError("rigid model draw must contain exactly one mesh")
    fields = {c.destination_offset for c in commands if c.name == "file_info_pointer"}
    draw = int(source["draw_offset"], 16)
    offset = int(source["mesh_offset"], 16)

    def bounded(start, size):
        if start < 0 or size < 0 or start + size > len(file_info):
            raise ValueError("rigid model source range is out of bounds")
        return file_info[start:start + size]

    def word(start):
        return int.from_bytes(bounded(start, 4), "big")

    bounded(offset, 0x38)
    if word(offset + 0x14) != 0 or offset + 0x14 in fields:
        raise ValueError("weighted mesh is not rigid source geometry")
    attrs = bounded(draw + 0x2C, 16)
    normal, color = bool(attrs[2] & 3), bool(attrs[4] & 3)
    if normal == color or any(attrs[i] & 3 for i in (0, 3, 5, *range(7, 14))):
        raise ValueError("unsupported rigid model GX attribute combination")
    slots = (1, 2 if normal else 4, 6)
    formats = (0x24, 0x08 if normal else 0x2C, 0x1C)
    if any(attrs[i] & 3 not in (2, 3) or attrs[i] & 0x3C != fmt
           for i, fmt in zip(slots, formats, strict=True)):
        raise ValueError("unsupported rigid model GX attribute format")
    widths = tuple((attrs[i] & 3) - 1 for i in slots)
    vertex_count, position_count, attribute_count, allocated = (word(offset + i * 4) for i in range(4))
    if not 3 <= vertex_count <= 65535 or not 1 <= position_count <= 65535 or attribute_count != 3:
        raise ValueError("invalid rigid model mesh counts")
    relatives = (0x10, 0x18, 0x1C if normal else 0x20, 0x28)
    if any(offset + relative not in fields for relative in relatives):
        raise ValueError("rigid model buffer pointer lacks relocation")
    # An inactive middle pointer must not secretly describe a second attribute.
    inactive = offset + (0x20 if normal else 0x1C)
    if word(inactive) != 0 or inactive in fields:
        raise ValueError("rigid model has an unexpected inactive attribute buffer")
    display, positions_at, middle_at, uv_at = (word(offset + relative) for relative in relatives)
    if not positions_at < middle_at < uv_at <= display or middle_at - positions_at != position_count * 12:
        raise ValueError("rigid model buffers are not structurally bounded")
    command_size = 3 + vertex_count * sum(widths)
    if (command_size + 31) & ~31 != allocated:
        raise ValueError("rigid model display allocation disagrees with descriptors")
    bounded(display, allocated)
    display_list = bounded(display, command_size)
    if display_list[0] != 0x9E or int.from_bytes(display_list[1:3], "big") != vertex_count:
        raise ValueError("rigid model requires the source VAT6 triangle strip")
    vertices = []
    cursor = 3
    for _ in range(vertex_count):
        indices = []
        for width in widths:
            indices.append(int.from_bytes(display_list[cursor:cursor + width], "big"))
            cursor += width
        p, m, uv = indices
        if p >= position_count:
            raise ValueError("rigid model position index exceeds source buffer")
        vertices.append(CharacterMeshVertex(p, m if normal else None, uv, m if color else None))
    middle_count = max(v.normal_index if normal else v.color_index for v in vertices) + 1
    if normal:
        middle_size = middle_count * 3
        if (middle_size + 3) & ~3 != uv_at - middle_at:
            raise ValueError("rigid normal indices do not bound the packed-normal buffer")
    else:
        middle_size = uv_at - middle_at
        if middle_size % 4 or middle_count > middle_size // 4:
            raise ValueError("rigid color indices exceed the RGBA8 buffer")
        middle_count = middle_size // 4
    uv_count = max(v.uv_index for v in vertices) + 1
    if uv_at + uv_count * 4 > display:
        raise ValueError("rigid UV indices exceed source buffer")
    position_data = bounded(positions_at, position_count * 12)
    positions = tuple(struct.iter_unpack(">fff", position_data))
    if not all(math.isfinite(v) for p in positions for v in p):
        raise ValueError("nonfinite rigid model source position")
    middle_data = bounded(middle_at, middle_size)
    normals = tuple(tuple(v / 64.0 for v in n) for n in struct.iter_unpack("bbb", middle_data)) if normal else ()
    colors = tuple(struct.iter_unpack("BBBB", middle_data)) if color else ()
    uv_data = bounded(uv_at, uv_count * 4)
    mesh = WiiRigidMesh(offset=offset, vertex_count=vertex_count, positions=positions,
        normals=normals, colors=colors, raw_uvs=tuple(struct.iter_unpack(">hh", uv_data)),
        vertices=tuple(vertices), index_widths=widths, middle_attribute="normal" if normal else "color0",
        display_list=display_list, display_list_sha256=_sha(display_list), positions_sha256=_sha(position_data),
        normals_sha256=_sha(middle_data if normal else b""), colors_sha256=_sha(middle_data if color else b""),
        uvs_sha256=_sha(uv_data), source_anchor_prefix_bytes=uv_at - positions_at,
        source_anchor_sha256=_sha(bounded(positions_at, uv_at + len(uv_data) - positions_at)))
    return WiiRigidModelDraw(package_sha256, {**source,
        "geometry_decode": "descriptor-driven-unweighted-model/v1",
        "source_anchor": "original-positions-middle-through-UV/v1"}, mesh)

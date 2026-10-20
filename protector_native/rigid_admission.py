"""Exact immutable-array identity and selected-prop source-census helpers.

This is not a claim that every prop has been artistically reviewed or decoded.
Only runtime keys selected by the authoring caller are admitted; every matching
referenced model draw is typed again before being counted as the same geometry.
"""
from __future__ import annotations

import hashlib
import struct

from protector_native.asset_inventory import discover_model_materials
from protector_native.rigid_model import WiiRigidModelDraw, parse_wii_rigid_model_draw


def runtime_key(draw: WiiRigidModelDraw) -> tuple:
    mesh = draw.mesh
    return (mesh.display_list_sha256, mesh.uvs_sha256, mesh.source_anchor_sha256,
            mesh.source_anchor_prefix_bytes, mesh.middle_attribute, mesh.index_widths,
            tuple(sorted(draw.source_rigid_arrays.items())))


def source_identity(draw: WiiRigidModelDraw) -> tuple:
    mesh = draw.mesh
    return (mesh.positions_sha256, mesh.normals_sha256, mesh.colors_sha256,
            len(mesh.positions), len(mesh.normals), len(mesh.colors), len(mesh.raw_uvs))


def matching_occurrences(file_info: bytes, commands, package_sha256: str,
                         selected: list[WiiRigidModelDraw]) -> dict:
    """Census complete referenced model headers, decode selected primitive hits.

    Other topologies are not silently labelled supported rigid meshes. A hash
    hit with a changed descriptor/layout must decode successfully or be recorded
    explicitly as rejected, never counted as a matching source key.
    """
    records = discover_model_materials(file_info, commands)
    references = {c.destination_offset for c in commands if c.name == "file_info_pointer"}
    primitives = {}
    keys = {}
    for index, draw in enumerate(selected):
        key = runtime_key(draw)
        if key in keys:
            raise ValueError("selected rigid runtime keys must be distinct")
        keys[key] = (index, draw)
        primitives.setdefault(draw.mesh.display_list_sha256, draw)
    hits, rejected = [], []
    for record in records:
        mesh = int(record["mesh_offset"], 16)
        if record["declared_mesh_count"] != 1 or mesh + 0x14 > len(file_info) or mesh + 0x10 not in references:
            continue
        display = struct.unpack_from(">I", file_info, mesh + 0x10)[0]
        for primitive, original in primitives.items():
            size = len(original.mesh.display_list)
            if display + size > len(file_info) or file_info[display:display + 3] != original.mesh.display_list[:3] or \
                    hashlib.sha256(file_info[display:display + size]).hexdigest() != primitive:
                continue
            try:
                draw = parse_wii_rigid_model_draw(file_info, commands, package_sha256=package_sha256,
                    model_offset=int(record["model_offset"], 16), draw_index=record["draw_index"])
            except ValueError as error:
                rejected.append({"source": record, "primitive_sha256": primitive, "reason": str(error)})
                continue
            match = keys.get(runtime_key(draw))
            if match is not None and source_identity(draw) != source_identity(match[1]):
                raise ValueError("rigid runtime key admits differing source geometry")
            hits.append({"source": draw.to_dict(), "selected_key_match": match is not None,
                         "selected_key_index": None if match is None else match[0]})
    return {"referenced_model_draws": len(records), "primitive_hits": hits, "rejected_primitive_hits": rejected}

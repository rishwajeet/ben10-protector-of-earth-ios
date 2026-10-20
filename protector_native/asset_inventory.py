"""Conservative asset-use discovery for enhancement planning, not game mutation.

Only structurally validated links become roles. Unknown resources remain unknown;
an opaque pixel channel by itself does not make a texture safe to upscale.
"""
from __future__ import annotations

from collections import Counter
import struct

from protector_native.character_skin import parse_wii_character_skin
from protector_native.dynamic_materials import parse_wii_dynamic_materials
from protector_native.meshes import parse_wii_map_geometry


def texture_targets(offset: int, kinds: dict[int, str], sequences: dict, animations: dict,
                    visiting: frozenset[int] = frozenset()) -> set[int]:
    """Follow every animated frame/track, never only the initially visible one."""
    if offset == 0:
        return set()
    if offset in visiting or len(visiting) >= 32:
        raise ValueError("cyclic or excessive dynamic texture dependency")
    kind = kinds.get(offset)
    if kind == "texture":
        return {offset}
    if kind == "texture_frame_sequence" and offset in sequences:
        children = [frame.texture_offset for frame in sequences[offset].frames]
    elif kind == "texture_uv_animation" and offset in animations:
        children = [track.texture_offset for track in animations[offset].tracks]
    else:
        raise ValueError(f"unresolved material target {kind!r} at 0x{offset:08x}")
    if not children:
        raise ValueError("empty dynamic texture dependency")
    result = set()
    for child in children:
        result.update(texture_targets(child, kinds, sequences, animations, visiting | {offset}))
    return result


def skin_binding_candidates(file_info: bytes, commands) -> list[int]:
    """Find relocated model/palette pairs; callers must validate every model draw."""
    fields = {command.destination_offset for command in commands
              if command.name == "file_info_pointer" and command.destination_offset is not None}
    palettes = {command.destination_offset for command in commands
                if command.name == "skinning_palette_set"}
    candidates = set()
    for field in fields:
        if field >= 8 and field + 4 <= len(file_info) and field - 8 in fields:
            target = struct.unpack_from(">I", file_info, field)[0]
            if target in palettes:
                candidates.add(field - 8)
    return sorted(candidates)


def treatment_lane(texture: dict, roles: set[str]) -> str:
    # These are work queues, not quality approval or permission to alter alpha.
    if texture["alpha"]["nonopaque_pixels"]:
        return "alpha-preserving-review"
    if roles & {"skinned-model", "model-geometry"}:
        return "model-atlas-review"
    if roles & {"animated-sequence", "animated-uv"}:
        return "animated-material-review"
    if "map-geometry" in roles:
        return "environment-material-review"
    return "unclassified-review"


def model_draw_records(file_info: bytes, commands, binding: int) -> list[dict]:
    """Read the validated primary/secondary model draw lists without assuming
    all draws use CPU skinning or the same GX index width. These records identify
    material ownership; they do not claim fully decoded replacement geometry.
    """
    fields = {c.destination_offset for c in commands if c.name == "file_info_pointer"}

    def word(offset):
        if offset < 0 or offset + 4 > len(file_info):
            raise ValueError("model record is outside file-info")
        return struct.unpack_from(">I", file_info, offset)[0]

    if binding not in fields or binding + 8 not in fields:
        raise ValueError("model binding lacks pointer relocations")
    model = word(binding)
    return [{**row, "binding_offset": f"0x{binding:08x}"}
            for row in _model_header_draw_records(file_info, fields, model)]


def _model_header_draw_records(file_info: bytes, fields: set[int], model: int) -> list[dict]:
    """Validate the model's material links without presuming a skin binding."""
    def word(offset):
        if offset < 0 or offset + 4 > len(file_info):
            raise ValueError("model record is outside file-info")
        return struct.unpack_from(">I", file_info, offset)[0]

    if model < 0 or model + 0x54 > len(file_info) or not {model, model + 4} <= fields:
        raise ValueError("model header lacks bounded draw pointers")
    begin, split = word(model), word(model + 4)
    end = word(model + 8) if model + 8 in fields else split
    if not 0 <= begin <= split <= end <= len(file_info) or \
            (split - begin) % 0x3C or (end - split) % 0x3C:
        raise ValueError("model primary/secondary draw ranges are invalid")
    count = (end - begin) // 0x3C
    if not 1 <= count <= 255 or file_info[model + 0x50] != count:
        raise ValueError("model draw count does not match its two lists")
    name = file_info[model + 0x20:model + 0x30].split(b"\0", 1)[0]
    if not name or any(value < 32 or value > 126 for value in name):
        raise ValueError("model name is not a bounded printable source name")
    result = []
    for index, draw in enumerate(range(begin, end, 0x3C)):
        if not {draw, draw + 0x1C} <= fields:
            raise ValueError("model draw lacks material/mesh relocations")
        material, mesh = word(draw), word(draw + 0x1C)
        if material + 0x20 > len(file_info) or mesh + 0x30 > len(file_info):
            raise ValueError("model material or mesh is out of bounds")
        target = word(material + 8)
        if target and material + 8 not in fields:
            raise ValueError("model texture target lacks relocation")
        result.append({"model_name": name.decode("ascii"), "model_offset": f"0x{model:08x}",
            "draw_index": index,
            "draw_offset": f"0x{draw:08x}", "list_kind": "primary" if draw < split else "secondary",
            "material_offset": f"0x{material:08x}", "material_target_offset": f"0x{target:08x}",
            "mesh_offset": f"0x{mesh:08x}", "declared_mesh_count": word(draw + 0x24),
            "transform_byte": file_info[draw + 9],
            "geometry_decode": "not-implied-by-material-link"})
    return result


def discover_model_materials(file_info: bytes, commands) -> list[dict]:
    """Discover referenced model headers, including non-skinned effect models.

    These are structural source links, not typed skin bindings, fully decoded
    geometry, semantic effect identities or proof of runtime visibility. Require
    incoming relocated references, valid primary/secondary ranges and complete
    material/mesh pointer links. Ignore other pointer-rich records rather than
    treating every relocated field as a model.
    """
    fields = {c.destination_offset for c in commands
              if c.name == "file_info_pointer" and c.destination_offset is not None
              and 0 <= c.destination_offset <= len(file_info) - 4}
    incoming = {}
    for field in fields:
        target = struct.unpack_from(">I", file_info, field)[0]
        if target != field:
            incoming.setdefault(target, []).append(field)
    result = []
    for model in sorted(fields & incoming.keys()):
        if model + 4 not in fields:
            continue
        try:
            draws = _model_header_draw_records(file_info, fields, model)
        except (ValueError, struct.error):
            continue
        for draw in draws:
            draw["source_reference_fields"] = [f"0x{field:08x}" for field in sorted(incoming[model])]
            draw["discovery"] = "relocation-anchored-model-structure"
        result.extend(draws)
    return result


def inspect_package(file_info: bytes, commands, package_sha256: str) -> dict:
    command_list = tuple(commands)
    kinds = {c.destination_offset: c.name for c in command_list
             if c.kind == "resource_reference" and c.destination_offset is not None}
    fields = {c.destination_offset for c in command_list if c.name == "file_info_pointer"}
    result = {"resource_counts": dict(Counter(c.name for c in command_list
                  if c.kind != "pointer_fixup")), "texture_uses": [], "map_meshes": [],
              "model_draws": [], "skinned_meshes": [], "unresolved_bindings": [],
              "inspection_errors": []}
    sequences, animations = {}, {}
    try:
        sequence_values, animation_values = parse_wii_dynamic_materials(
            file_info, command_list, package_sha256=package_sha256)
        sequences = {v.offset: v for v in sequence_values}
        animations = {v.offset: v for v in animation_values}
    except ValueError as error:
        result["inspection_errors"].append({"class": "dynamic-material", "error": str(error)})

    def record_use(target, role, owner, owner_offset):
        try:
            for texture in sorted(texture_targets(target, kinds, sequences, animations)):
                result["texture_uses"].append({"texture_offset": f"0x{texture:08x}",
                    "role": role, "owner": owner, "owner_offset": f"0x{owner_offset:08x}",
                    "material_target_offset": f"0x{target:08x}", "evidence": "typed-source-link"})
        except ValueError as error:
            result["inspection_errors"].append({"class": "material-link", "owner": owner,
                "owner_offset": f"0x{owner_offset:08x}", "error": str(error)})

    for offset in sequences:
        record_use(offset, "animated-sequence", "texture frame sequence", offset)
    for offset in animations:
        record_use(offset, "animated-uv", "UV animation", offset)
    try:
        for geometry in parse_wii_map_geometry(file_info, command_list, package_sha256=package_sha256):
            for draw in geometry.draws:
                mesh = draw.mesh
                result["map_meshes"].append({"name": draw.node_name,
                    "draw_offset": f"0x{draw.resource_offset:08x}",
                    "mesh_offset": f"0x{mesh.resource_offset:08x}",
                    "position_count": mesh.position_count, "vertex_count": mesh.vertex_count,
                    "triangle_count": len(mesh.triangle_vertex_indices()),
                    "display_list_sha256": mesh.display_list_sha256,
                    "material_offset": f"0x{draw.material_offset:08x}",
                    "material_state": list(draw.material_state)})
                record_use(draw.material_target_offset, "map-geometry", draw.node_name, draw.resource_offset)
    except ValueError as error:
        result["inspection_errors"].append({"class": "map-geometry", "error": str(error)})

    # Several references may share a binding or model. Inspect each model/palette
    # pair once, and keep the exact accepted binding as provenance.
    seen = set()
    for binding in skin_binding_candidates(file_info, command_list):
        model = struct.unpack_from(">I", file_info, binding)[0]
        palette = struct.unpack_from(">I", file_info, binding + 8)[0]
        if (model, palette) in seen:
            continue
        seen.add((model, palette))
        try:
            model_draws = model_draw_records(file_info, command_list, binding)
        except (ValueError, struct.error) as error:
            result["unresolved_bindings"].append({"binding_offset": f"0x{binding:08x}",
                "model_offset": f"0x{model:08x}", "error": str(error)})
            continue
        result["model_draws"].extend(model_draws)
        for draw in model_draws:
            record_use(int(draw["material_target_offset"], 16), "model-geometry",
                       draw["model_name"], int(draw["draw_offset"], 16))
            if draw["transform_byte"] != 255:
                continue
            draw_index = draw["draw_index"]
            try:
                skin = parse_wii_character_skin(file_info, command_list,
                    package_sha256=package_sha256, binding_offset=binding, draw_index=draw_index)
                result["skinned_meshes"].append(skin.to_dict())
                target_field = skin.material_offset + 8
                if target_field + 4 > len(file_info):
                    raise ValueError("skinned material target is out of bounds")
                target = struct.unpack_from(">I", file_info, target_field)[0]
                if target and target_field not in fields:
                    raise ValueError("skinned material target lacks a bounded pointer relocation")
                record_use(target, "skinned-model", skin.model_name, skin.draw_offset)
            except (ValueError, struct.error) as error:
                result["inspection_errors"].append({"class": "skinned-draw", "draw_index": draw_index,
                    "binding_offset": f"0x{binding:08x}", "error": str(error)})
    return result

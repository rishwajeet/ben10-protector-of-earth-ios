"""Explicitly audited partial-shell refinement with immutable feature guards.

Some original character outlines include caps absent from the lit mesh, or omit
small lit details. This is NOT a fallback in the full-shell pairing path. An
author must inspect and explicitly supply the exact source correspondence audit.
All unmatched triangles and edges whose stencil touches their vertices stay
linear on both surfaces. No source vertex, triangle, UV or skin record is removed.

The default requires 90 percent matching triangles on each surface. The explicit
body-complete policy instead requires every body triangle to match, occurrence
for occurrence; additional outline caps remain guarded. This is not a relaxed
threshold or an automatic fallback, and it cannot admit a missing body face.
"""
from __future__ import annotations

from collections import Counter, defaultdict, deque
from copy import deepcopy
import hashlib
import json
from types import SimpleNamespace

import numpy as np

from protector_native.geometry_refinement import _correspondence_bound, _signature, apply_plan_positions, refinement_plan


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                   allow_nan=False).encode()).hexdigest()


def _identity(mesh):
    return {"display_list_sha256": mesh.display_list_sha256, "uvs_sha256": mesh.uvs_sha256,
            "positions_sha256": mesh.positions_sha256, "weights_sha256": mesh.weights_sha256,
            "normals_sha256": mesh.normals_sha256, "middle_attribute": mesh.middle_attribute,
            "vertex_count": mesh.vertex_count}


def _correspondence(bodies, outline, *, maximum_distance=None, coverage="balanced"):
    if coverage not in ("balanced", "body-complete"):
        raise ValueError("unknown partial shell coverage policy")
    if not 1 <= len(bodies) <= 8 or any(body.middle_attribute != "normal" for body in bodies) or \
            outline.middle_attribute != "color0":
        raise ValueError("partial shell audit requires one to eight normal bodies and one color outline")
    if len({body.display_list_sha256 for body in bodies}) != len(bodies):
        raise ValueError("duplicate body draw in partial shell audit")
    identities, points, skins, body_ids = {}, [], [], []
    for body in bodies:
        ids = []
        for i, point in enumerate(body.positions):
            key = (tuple(point), _signature(body, i))
            if key not in identities:
                identities[key] = len(points)
                points.append(point)
                skins.append(key[1])
            ids.append(identities[key])
        body_ids.append(ids)
    extent = float(np.ptp(np.asarray(points), axis=0).max())
    if not np.isfinite(extent) or extent <= 0:
        raise ValueError("partial shell body has no finite spatial extent")
    distance_bound = _correspondence_bound(extent, maximum_distance)
    shell_ids, rejected = [], []
    for i, point in enumerate(outline.positions):
        candidates = sorted((float(np.linalg.norm(np.asarray(point) - p)), j)
            for j, p in enumerate(points) if _signature(outline, i) == skins[j])
        reason = None
        if not candidates:
            reason = "no-exact-skin-candidate"
        elif candidates[0][0] > distance_bound:
            reason = "outside-distance-bound"
        elif len(candidates) > 1 and candidates[1][0] - candidates[0][0] < extent * 1e-7:
            reason = "ambiguous-nearest-position"
        shell_ids.append(None if reason else candidates[0][1])
        if reason:
            rejected.append({"position_index": i, "reason": reason,
                             "nearest_distance": candidates[0][0] if candidates else None})

    body_records, body_faces = [], []
    for part, (body, ids) in enumerate(zip(bodies, body_ids, strict=True)):
        for index, triangle in enumerate(body.triangle_vertex_indices()):
            face = tuple(sorted(ids[body.vertices[i].position_index] for i in triangle))
            body_faces.append(face)
            body_records.append((part, index, face))
    outline_triangles = outline.triangle_vertex_indices()
    shell_faces = []
    for triangle in outline_triangles:
        ids = [shell_ids[outline.vertices[i].position_index] for i in triangle]
        shell_faces.append(tuple(sorted(ids)) if None not in ids else None)
    available = defaultdict(deque)
    for index, face in enumerate(shell_faces):
        if face is not None:
            available[face].append(index)
    missing, matched = [], []
    for part, index, face in body_records:
        if available[face]:
            matched.append((part, index, available[face].popleft()))
        else:
            missing.append((part, index, face))
    matched_shell = {value[2] for value in matched}
    extra = [i for i in range(len(shell_faces)) if i not in matched_shell]
    if coverage == "body-complete" and (not body_faces or not shell_faces or missing):
        raise ValueError("body-complete shell audit requires every body triangle exactly once")
    if coverage == "balanced" and (not body_faces or not shell_faces or
            min(len(matched) / len(body_faces), len(matched) / len(shell_faces)) < 0.90):
        raise ValueError("partial shell audit requires at least 90 percent exact triangle coverage on each surface")
    shell_vertices = defaultdict(dict)
    for i, vertex in enumerate(outline.vertices):
        position = vertex.position_index
        if shell_ids[position] is not None:
            shell_vertices[shell_ids[position]].setdefault(tuple(outline.positions[position]), i)
    unsafe = {i for i in range(len(points)) if len(shell_vertices[i]) != 1}
    for _, _, face in missing:
        unsafe.update(face)
    for index in extra:
        unsafe.update(shell_ids[outline.vertices[i].position_index]
                      for i in outline_triangles[index]
                      if shell_ids[outline.vertices[i].position_index] is not None)
    audit = {"schema": "protector-native.partial-shell-audit/v1",
        "purpose": "explicit source pairing; not visual or motion acceptance",
        "method": "exact-skin-unique-bounded-correspondence-and-triangle-multiset/v1",
        "body_sources": [_identity(body) for body in bodies], "outline_source": _identity(outline),
        "maximum_correspondence_fraction": 0.015, "minimum_triangle_coverage": 0.90,
        "body_triangles": len(body_faces), "outline_triangles": len(shell_faces),
        "matched_triangles": len(matched), "matched_triangle_pairs_sha256": _digest(matched),
        "unmatched_body_triangles": [{"body_index": part, "triangle_index": index} for part, index, _ in missing],
        "unmatched_outline_triangles": extra, "rejected_outline_positions": rejected,
        "guarded_body_vertex_count": len(unsafe), "guarded_body_vertices_sha256": _digest(sorted(unsafe)),
        "preservation": "original corners and triangles retained; unmatched features and all dependent stencils linear"}
    if maximum_distance is not None:
        audit.pop("maximum_correspondence_fraction")
        audit["maximum_correspondence_distance"] = distance_bound
    if coverage == "body-complete":
        audit.pop("minimum_triangle_coverage")
        audit["coverage_policy"] = "complete-body-with-guarded-outline-extras/v1"
        audit["minimum_body_triangle_coverage"] = 1.0
    return audit, body_ids, shell_ids, shell_vertices, unsafe, extent


def partial_shell_audit(bodies, outline, *, maximum_distance=None, coverage="balanced"):
    """Return the exact report to inspect and pin before partial refinement."""
    return _correspondence(bodies, outline, maximum_distance=maximum_distance, coverage=coverage)[0]


def paired_partial_shell_plans(bodies, body_plans, outline, *, expected_audit, maximum_distance=None,
                               coverage="balanced"):
    audit, body_ids, shell_ids, shell_vertices, unsafe, extent = _correspondence(bodies, outline,
        maximum_distance=maximum_distance, coverage=coverage)
    if not isinstance(expected_audit, dict) or audit != expected_audit:
        raise ValueError("partial shell requires the exact inspected source audit")
    if len(body_plans) != len(bodies):
        raise ValueError("one refinement plan is required per audited body")
    for body, plan in zip(bodies, body_plans, strict=True):
        if any(plan.get(k) != v for k, v in {
            "source_display_list_sha256": body.display_list_sha256,
            "source_uvs_sha256": body.uvs_sha256,
            "source_vertex_count": body.vertex_count}.items()) or \
                any(plan["authoring"][f"source_{kind}_sha256"] != getattr(body, f"{kind}_sha256")
                    for kind in ("positions", "weights", "normals")):
            raise ValueError("partial shell plan does not belong to its audited body")
    parameters = ("strength", "crease_degrees", "maximum_displacement_fraction")
    if any(any(plan["authoring"][key] != body_plans[0]["authoring"][key] for key in parameters)
           for plan in body_plans):
        raise ValueError("partial shell bodies use different refinement parameters")

    def global_stencil(body, ids, value):
        stencil = defaultdict(float)
        for i, weight in value["position_stencil"]:
            stencil[ids[body.vertices[i].position_index]] += weight
        return dict(stencil)

    def global_edge(body, ids, value):
        return tuple(sorted(ids[body.vertices[i].position_index] for i in value["attributes"]))

    guarded, stencils = set(), {}
    for body, ids, plan in zip(bodies, body_ids, body_plans, strict=True):
        for value in plan["added_vertices"]:
            edge = global_edge(body, ids, value)
            stencil = global_stencil(body, ids, value)
            if unsafe.intersection(stencil) or unsafe.intersection(edge):
                guarded.add(edge)
            if edge in stencils and any(abs(stencils[edge].get(i, 0) - stencil.get(i, 0)) > 1e-8
                                       for i in stencils[edge].keys() | stencil.keys()):
                raise ValueError("audited body material seam has conflicting position stencils")
            stencils[edge] = stencil
    plans = deepcopy(body_plans)
    for body, ids, plan in zip(bodies, body_ids, plans, strict=True):
        source = np.asarray([body.positions[v.position_index] for v in body.vertices])
        local_guards, curved_guards = set(), set()
        for value in plan["added_vertices"]:
            edge = global_edge(body, ids, value)
            if edge in guarded:
                a, b = value["attributes"]
                previous = sum((source[i] * w for i, w in value["position_stencil"]), np.zeros(3))
                if np.linalg.norm(previous - (source[a] + source[b]) * 0.5) > extent * 1e-8:
                    curved_guards.add(edge)
                value["position_stencil"] = [[i, 0.5] for i in value["attributes"]]
                local_guards.add(edge)
            stencils[edge] = global_stencil(body, ids, value)
        plan["authoring"]["edge_decisions"]["curved"] = plan["authoring"]["edge_decisions"].get("curved", 0) - len(curved_guards)
        plan["authoring"]["edge_decisions"]["partial_shell_guard"] = len(curved_guards)
        plan["authoring"].update({"partial_shell_guarded_edges": len(local_guards),
            "partial_shell_audit_sha256": _digest(audit)})
        _update_displacement(body, plan)

    # The guide supplies only format context: strength zero cannot smooth the
    # shell independently. Each safe edge inherits its exact body's stencil.
    positions, influences = [], []
    for body in bodies:
        positions.extend(body.positions)
        influences.extend(body.influences)
    guide = SimpleNamespace(positions=positions, influences=influences, middle_attribute="normal")
    base = body_plans[0]["authoring"]
    result = refinement_plan(outline, normal_guide=guide, strength=0.0,
        crease_degrees=base["crease_degrees"], displacement_fraction=base["maximum_displacement_fraction"])
    inherited = 0
    for value in result["added_vertices"]:
        # Keep guarded/unmatched edges explicitly local to their own corners,
        # including texture-seam duplicates, not an equivalent welded alias.
        value["position_stencil"] = [[i, 0.5] for i in value["attributes"]]
        ids = [shell_ids[outline.vertices[i].position_index] for i in value["attributes"]]
        if None in ids:
            continue
        edge = tuple(sorted(ids))
        if edge in guarded or edge not in stencils:
            continue
        stencil = stencils[edge]
        if unsafe.intersection(stencil):
            raise ValueError("partial shell attempted to use guarded source support")
        value["position_stencil"] = [[next(iter(shell_vertices[i].values())), weight]
                                      for i, weight in stencil.items()]
        inherited += 1
    decisions = Counter()
    for plan in plans:
        decisions.update(plan["authoring"]["edge_decisions"])
    if decisions.get("curved", 0) <= 0:
        raise ValueError("partial shell guards leave no useful geometric refinement")
    result["authoring"].update({"method": "audited-partial-body-outline-affine-stencil/v1",
        "strength": base["strength"], "partial_shell_audit": audit,
        "partial_shell_audit_sha256": _digest(audit), "body_draw_count": len(bodies),
        "body_display_list_sha256s": [body.display_list_sha256 for body in bodies],
        "edge_decisions": dict(sorted(decisions.items())),
        "partial_shell_guarded_edges": len(guarded), "inherited_outline_attribute_edges": inherited})
    _update_displacement(outline, result)
    return plans, result


def _update_displacement(mesh, plan):
    source = np.asarray([mesh.positions[v.position_index] for v in mesh.vertices])
    refined = apply_plan_positions(mesh, plan)[mesh.vertex_count:]
    plan["authoring"]["maximum_bind_displacement"] = max((float(np.linalg.norm(p - (source[a] + source[b]) * 0.5))
        for p, (a, b) in zip(refined, (v["attributes"] for v in plan["added_vertices"]), strict=True)), default=0)

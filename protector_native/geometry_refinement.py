"""Source-bound, interpolating silhouette refinement; never simulation geometry.

Each new edge point is an affine stencil over original submitted vertices.
This keeps the native renderer independent of skeleton guesses and lets the
original animation deform the refined surface. UVs and lit colors interpolate
only along the original edge. Creases, open edges, and poorly conditioned
stencils remain linear. This is a candidate-authoring tool, not art approval.
"""
from __future__ import annotations

from collections import Counter, defaultdict
from copy import deepcopy
from dataclasses import replace
import hashlib
import itertools
import json
import math
from types import SimpleNamespace

import numpy as np
import networkx as nx

from protector_native.character_skin import WiiCharacterMesh


def _unit(value):
    norm = float(np.linalg.norm(value))
    return value / norm if norm > 1e-10 else np.zeros(3)


def _signature(mesh, index):
    return tuple((i.bone_index, i.weight_u16) for i in mesh.influences[index])


def _planar_edge_constraints(points, triangles, extent):
    """Protect actual planar patches, not the smooth shading normals on lids.

    Four or more connected coplanar triangles identify a plane. Two-triangle
    cylinder facets do not: their diagonals must still follow curved refinement.
    Displacements may round a patch boundary *within* its plane, never inflate
    the plane over an authored inset/overlay detail.
    """
    faces, edges = [], defaultdict(list)
    for a, b, c in triangles:
        normal = _unit(np.cross(points[b] - points[a], points[c] - points[a]))
        if not np.linalg.norm(normal):
            continue
        face = len(faces)
        faces.append(((a, b, c), normal))
        for edge in ((a, b), (b, c), (c, a)):
            edges[tuple(sorted(edge))].append(face)
    graph = nx.Graph()
    graph.add_nodes_from(range(len(faces)))
    for neighbors in edges.values():
        if len(neighbors) == 2 and float(faces[neighbors[0]][1] @ faces[neighbors[1]][1]) >= 1 - 1e-8:
            graph.add_edge(*neighbors)
    constraints, patches = defaultdict(list), 0
    for component in nx.connected_components(graph):
        if len(component) < 4:
            continue
        first = faces[min(component)]
        normal, origin = first[1], points[first[0][0]]
        vertices = {v for f in component for v in faces[f][0]}
        if max(abs(float((points[v] - origin) @ normal)) for v in vertices) > extent * 1e-6:
            continue
        patches += 1
        selected = {tuple(sorted(edge)) for f in component for edge in
            ((faces[f][0][0], faces[f][0][1]), (faces[f][0][1], faces[f][0][2]), (faces[f][0][2], faces[f][0][0]))}
        for edge in selected:
            constraints[edge].append(normal)
    return constraints, patches


def refinement_plan(mesh: WiiCharacterMesh, *, normal_guide: WiiCharacterMesh | None = None,
                    strength: float = 1.0, crease_degrees: float = 55.0,
                    displacement_fraction: float = 0.008, preserve_planar_regions: bool = False) -> dict:
    """Author four child triangles per source triangle, preserving its corners.

    The target edge midpoint is the midpoint of the cubic curve whose endpoint
    tangents lie in the two authored normal planes. A bounded least-norm affine
    stencil reproduces that bind-pose point using the local one-ring. Applying
    the same stencil to the original posed vertices is an approximation near
    changing joints; joint/crease guards and actual motion review are mandatory.
    """
    if not math.isfinite(strength) or not 0 <= strength <= 1 or not 0 < crease_degrees < 90:
        raise ValueError("invalid refinement strength or crease angle")
    if not math.isfinite(displacement_fraction) or not 0 < displacement_fraction <= 0.02:
        raise ValueError("invalid maximum silhouette displacement")
    positions = np.asarray(mesh.positions, dtype=np.float64)
    extent = float(np.ptp(positions, axis=0).max())
    if not extent > 0:
        raise ValueError("model has no spatial extent")
    # Exact positions and skin records weld texture seams, not unrelated limbs.
    identities, canonical, representatives = {}, [], []
    for index, point in enumerate(mesh.positions):
        key = (point, _signature(mesh, index))
        if key not in identities:
            identities[key] = len(representatives)
            representatives.append(index)
        canonical.append(identities[key])
    points = positions[representatives]
    display_for = {}
    normal_values = defaultdict(list)
    for index, vertex in enumerate(mesh.vertices):
        key = canonical[vertex.position_index]
        display_for.setdefault(key, index)
        if vertex.normal_index is not None:
            normal_values[key].append(_unit(np.asarray(mesh.normals[vertex.normal_index])))

    guide_matches = 0
    if mesh.middle_attribute == "color0":
        if normal_guide is None or normal_guide.middle_attribute != "normal":
            raise ValueError("outline refinement requires an explicit normal-bearing source guide")
        guide_by_skin = defaultdict(list)
        for i, point in enumerate(normal_guide.positions):
            guide_by_skin[_signature(normal_guide, i)].append(np.asarray(point))
        for key, original_index in enumerate(representatives):
            candidates = guide_by_skin.get(_signature(mesh, original_index), [])
            if not candidates:
                continue
            nearest = min(candidates, key=lambda p: float(np.linalg.norm(points[key] - p)))
            shell = points[key] - nearest
            distance = float(np.linalg.norm(shell))
            if extent * 0.0005 <= distance <= extent * 0.015:
                normal_values[key].append(_unit(shell))
                guide_matches += 1

    normals, creases = {}, set()
    threshold = math.cos(math.radians(crease_degrees))
    for key, values in normal_values.items():
        average = _unit(np.mean(values, axis=0))
        normals[key] = average
        if min(float(value @ average) for value in values) < threshold:
            creases.add(key)
    triangles = mesh.triangle_vertex_indices()
    adjacent, neighbors = defaultdict(list), defaultdict(set)
    for triangle in triangles:
        a, b, c = [canonical[mesh.vertices[i].position_index] for i in triangle]
        if len({a, b, c}) != 3:
            continue
        face_normal = _unit(np.cross(points[b] - points[a], points[c] - points[a]))
        for x, y, opposite in ((a, b, c), (b, c, a), (c, a, b)):
            adjacent[tuple(sorted((x, y)))].append((opposite, face_normal))
            neighbors[x].add(y)
            neighbors[y].add(x)

    edge_stencils = {}
    reasons = defaultdict(int)
    displacements = []
    constraints, planar_patches = _planar_edge_constraints(points,
        [tuple(canonical[mesh.vertices[i].position_index] for i in t) for t in triangles], extent) \
        if preserve_planar_regions else ({}, 0)
    planar_projected = 0
    for (a, b), faces in sorted(adjacent.items()):
        linear = [(display_for[a], 0.5), (display_for[b], 0.5)]
        edge_stencils[(a, b)] = linear
        if len(faces) != 2:
            reasons["open_or_nonmanifold"] += 1
            continue
        if a in creases or b in creases or a not in normals or b not in normals or \
                float(faces[0][1] @ faces[1][1]) < threshold:
            reasons["authored_crease_or_missing_normal"] += 1
            continue
        sa = dict(_signature(mesh, representatives[a]))
        sb = dict(_signature(mesh, representatives[b]))
        if sum(abs(sa.get(k, 0) - sb.get(k, 0)) for k in sa.keys() | sb.keys()) > 49152:
            reasons["joint_boundary"] += 1
            continue
        edge = points[b] - points[a]
        length = float(np.linalg.norm(edge))
        if length <= extent * 1e-8:
            reasons["zero_edge"] += 1
            continue
        displacement = strength * 0.125 * ((edge @ normals[b]) * normals[b] - (edge @ normals[a]) * normals[a])
        if (a, b) in constraints:
            planes = np.asarray(constraints[(a, b)])
            projection, _, _, _ = np.linalg.lstsq(planes, planes @ displacement, rcond=1e-8)
            if np.linalg.norm(projection) > extent * 1e-7:
                planar_projected += 1
            displacement -= projection
        norm = float(np.linalg.norm(displacement))
        if norm <= extent * 1e-7:
            reasons["flat"] += 1
            continue
        limit = min(displacement_fraction * extent, 0.15 * length)
        displacement *= min(1.0, limit / norm)
        midpoint = (points[a] + points[b]) * 0.5
        support = [a, b] + sorted((neighbors[a] | neighbors[b]) - {a, b},
            key=lambda i: (float(np.linalg.norm(points[i] - midpoint)), i))[:10]
        matrix = np.vstack(((points[support] - midpoint).T / length, np.ones(len(support))))
        delta, _, rank, _ = np.linalg.lstsq(matrix, np.append(displacement / length, 0.0), rcond=1e-5)
        coefficients = delta.copy()
        coefficients[:2] += 0.5
        if rank < 4 or np.max(np.abs(coefficients)) > 1.0 or np.sum(np.abs(coefficients)) > 2.5 or \
                np.linalg.norm(coefficients @ points[support] - midpoint - displacement) > extent * 1e-6:
            reasons["ill_conditioned_or_excessive_stencil"] += 1
            continue
        edge_stencils[(a, b)] = [(display_for[i], float(weight)) for i, weight in zip(support, coefficients, strict=True)
                                if abs(weight) > 1e-12]
        displacements.append(float(np.linalg.norm(displacement)))
        reasons["curved"] += 1

    added, indices, attribute_edges = [], [], {}

    def midpoint_index(a, b):
        key = tuple(sorted((a, b)))
        if key not in attribute_edges:
            ca, cb = (canonical[mesh.vertices[i].position_index] for i in key)
            stencil = edge_stencils.get(tuple(sorted((ca, cb))), [(a, 0.5), (b, 0.5)])
            attribute_edges[key] = mesh.vertex_count + len(added)
            added.append({"attributes": list(key), "position_stencil": [list(item) for item in stencil]})
        return attribute_edges[key]

    for a, b, c in triangles:
        ab, bc, ca = midpoint_index(a, b), midpoint_index(b, c), midpoint_index(c, a)
        indices.extend((a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca))
    return {
        "source_vertex_count": mesh.vertex_count,
        "source_display_list_sha256": mesh.display_list_sha256,
        "source_display_list_bytes": len(mesh.display_list),
        "source_uvs_sha256": mesh.uvs_sha256,
        "source_uv_bytes": len(mesh.raw_uvs) * 4,
        "middle_attribute": mesh.middle_attribute,
        "index_widths": list(mesh.index_widths),
        "added_vertices": added,
        "indices": indices,
        "authoring": {"method": "source-normal-curved-edge-affine-stencil/v1", "strength": strength,
            "crease_degrees": crease_degrees, "maximum_displacement_fraction": displacement_fraction,
            "source_triangles": len(triangles), "refined_triangles": len(indices) // 3,
            "canonical_vertices": len(points), "edge_decisions": dict(sorted(reasons.items())),
            "outline_guide_matches": guide_matches, "maximum_bind_displacement": max(displacements, default=0.0),
            "source_positions_sha256": mesh.positions_sha256, "source_weights_sha256": mesh.weights_sha256,
            "source_normals_sha256": mesh.normals_sha256,
            **({"planar_policy": "connected-four-triangle-coplanar-patches/v1",
                "planar_patches": planar_patches, "planar_projected_edges": planar_projected}
               if preserve_planar_regions else {}),
            "motion_acceptance": "pending", "art_acceptance": "pending"},
    }


def apply_plan_positions(mesh: WiiCharacterMesh, plan: dict) -> np.ndarray:
    source = np.asarray([mesh.positions[v.position_index] for v in mesh.vertices])
    new = [sum((source[i] * weight for i, weight in record["position_stencil"]), np.zeros(3))
           for record in plan["added_vertices"]]
    return np.concatenate((source, np.asarray(new)), axis=0)


def _correspondence_bound(extent, maximum_distance=None):
    # Default policy is unchanged. An explicit bound describes authored shell
    # thickness, not allowed refinement displacement. Small rigid limbs can
    # carry the same outline thickness as a much larger torso.
    if maximum_distance is None:
        return extent * 0.015
    if isinstance(maximum_distance, bool) or not isinstance(maximum_distance, (int, float)) or \
            not math.isfinite(maximum_distance) or not 0 < maximum_distance <= extent * 0.125:
        raise ValueError("invalid explicit shell correspondence distance")
    return maximum_distance


def paired_outline_plan(body: WiiCharacterMesh, body_plan: dict, outline: WiiCharacterMesh, *,
                        maximum_distance=None) -> dict:
    """Share each body edge stencil with its matching original outline shell.

    Require a bijection of welded source vertices and identical triangle
    connectivity. An independently smoothed black shell can cut through its
    body; it is not a safe default. Unmatched multi-piece models need a
    deliberately authored pairing instead of a nearest-point guess.
    """
    if body.middle_attribute != "normal" or outline.middle_attribute != "color0":
        raise ValueError("paired geometry needs a normal body and color outline")

    def welded(mesh):
        groups, keys, display = {}, [], {}
        for index, point in enumerate(mesh.positions):
            key = (point, _signature(mesh, index))
            if key not in groups:
                groups[key] = len(groups)
            keys.append(groups[key])
        for index, vertex in enumerate(mesh.vertices):
            display.setdefault(keys[vertex.position_index], index)
        return groups, keys, display

    body_groups, body_keys, body_display = welded(body)
    outline_groups, outline_keys, outline_display = welded(outline)
    if len(body_groups) != len(outline_groups):
        raise ValueError("body/outline welded counts differ; explicit multi-piece pairing required")
    extent = float(np.ptp(np.asarray(body.positions), axis=0).max())
    distance_bound = _correspondence_bound(extent, maximum_distance)
    def graph(mesh, groups, keys):
        value = nx.Graph()
        for (point, signature), index in groups.items():
            value.add_node(index, point=np.asarray(point), skin=signature)
        for triangle in mesh.triangle_vertex_indices():
            a, b, c = [keys[mesh.vertices[i].position_index] for i in triangle]
            value.add_edges_from(((a, b), (b, c), (c, a)))
        return value

    # Nearest points alone are ambiguous around closely spaced facial detail.
    # Match the source edge graphs with exact skin records and bounded distance,
    # then independently check the complete triangle multiset below.
    matcher = nx.algorithms.isomorphism.GraphMatcher(
        graph(outline, outline_groups, outline_keys), graph(body, body_groups, body_keys),
        node_match=lambda a, b: a["skin"] == b["skin"] and
            float(np.linalg.norm(a["point"] - b["point"])) <= distance_bound)
    if not matcher.is_isomorphic():
        raise ValueError("body/outline source-and-skin edge graphs do not match")
    matches = matcher.mapping
    reverse = {v: k for k, v in matches.items()}

    def topology(mesh, keys, mapping):
        result = []
        for triangle in mesh.triangle_vertex_indices():
            result.append(tuple(sorted(mapping[keys[mesh.vertices[i].position_index]] for i in triangle)))
        return sorted(result)

    if topology(body, body_keys, {i: i for i in body_display}) != topology(outline, outline_keys, matches):
        raise ValueError("body/outline triangle connectivity differs")
    stencils = {}
    for added in body_plan["added_vertices"]:
        edge = tuple(sorted(body_keys[body.vertices[i].position_index] for i in added["attributes"]))
        stencil = [(outline_display[reverse[body_keys[body.vertices[i].position_index]]], weight)
                   for i, weight in added["position_stencil"]]
        if edge in stencils:
            old, new = defaultdict(float), defaultdict(float)
            for i, weight in stencils[edge]:
                old[i] += weight
            for i, weight in stencil:
                new[i] += weight
            if any(abs(old[i] - new[i]) > 1e-8 for i in old.keys() | new.keys()):
                raise ValueError("body material seam has conflicting position stencils")
        stencils[edge] = stencil
    # Build topology and attribute interpolation from the outline itself, but
    # inherit all geometric decisions and support coefficients from the body.
    plan = refinement_plan(outline, normal_guide=body, strength=0.0,
                           crease_degrees=body_plan["authoring"]["crease_degrees"],
                           displacement_fraction=body_plan["authoring"]["maximum_displacement_fraction"])
    for added in plan["added_vertices"]:
        edge = tuple(sorted(matches[outline_keys[outline.vertices[i].position_index]] for i in added["attributes"]))
        if edge not in stencils:
            raise ValueError("paired outline edge has no body stencil")
        added["position_stencil"] = [list(v) for v in stencils[edge]]
    source = np.asarray([outline.positions[v.position_index] for v in outline.vertices])
    result = apply_plan_positions(outline, plan)[outline.vertex_count:]
    displacement = [float(np.linalg.norm(point - (source[a] + source[b]) * 0.5))
                    for point, (a, b) in zip(result, (v["attributes"] for v in plan["added_vertices"]), strict=True)]
    plan["authoring"].update({"strength": body_plan["authoring"]["strength"],
        "method": "paired-body-outline-affine-stencil/v1", "body_display_list_sha256": body.display_list_sha256,
        "edge_decisions": body_plan["authoring"]["edge_decisions"], "paired_welded_vertices": len(matches),
        "pairing": "bijective-skin-compatible-vertices-and-exact-triangle-connectivity",
        "maximum_bind_displacement": max(displacement, default=0.0)})
    if maximum_distance is not None:
        plan["authoring"]["maximum_correspondence_distance"] = distance_bound
    return plan


def paired_multipart_outline_plans(bodies, body_plans, outline: WiiCharacterMesh, *,
                                   maximum_distance=None):
    """Pair one original shell to an explicitly selected set of body draws.

    Body profiles keep their own original submitted vertices and never sample
    another draw at runtime. The virtual union exists only to prove complete
    source topology/skin correspondence and transfer those local stencils to
    the shell. A missing piece or a conflicting material-seam stencil rejects
    the candidate instead of installing a partial outline.
    """
    if not 2 <= len(bodies) <= 8 or len(bodies) != len(body_plans) or \
            any(body.middle_attribute != "normal" for body in bodies):
        raise ValueError("multipart pairing requires two to eight normal-bearing body draws")
    parameters = ("strength", "crease_degrees", "maximum_displacement_fraction")
    if any(any(plan["authoring"][key] != body_plans[0]["authoring"][key] for key in parameters)
           for plan in body_plans):
        raise ValueError("multipart bodies use different refinement parameters")
    positions, influences, normals, vertices, triangles, added = [], [], [], [], [], []
    decisions = defaultdict(int)
    for body, plan in zip(bodies, body_plans, strict=True):
        if plan["source_display_list_sha256"] != body.display_list_sha256 or \
                plan["source_vertex_count"] != body.vertex_count or \
                plan["authoring"]["source_positions_sha256"] != body.positions_sha256 or \
                plan["authoring"]["source_weights_sha256"] != body.weights_sha256:
            raise ValueError("multipart plan does not belong to its source body")
        position_base, normal_base, vertex_base = len(positions), len(normals), len(vertices)
        positions.extend(body.positions)
        influences.extend(body.influences)
        normals.extend(body.normals)
        vertices.extend(replace(vertex, position_index=vertex.position_index + position_base,
            normal_index=None if vertex.normal_index is None else vertex.normal_index + normal_base)
            for vertex in body.vertices)
        triangles.extend(tuple(i + vertex_base for i in triangle) for triangle in body.triangle_vertex_indices())
        added.extend({"attributes": [i + vertex_base for i in value["attributes"]],
            "position_stencil": [[i + vertex_base, weight] for i, weight in value["position_stencil"]]}
            for value in plan["added_vertices"])
        for key, value in plan["authoring"]["edge_decisions"].items():
            decisions[key] += value
    merged = SimpleNamespace(positions=positions, influences=influences, normals=normals,
        vertices=vertices, vertex_count=len(vertices), middle_attribute="normal",
        triangle_vertex_indices=lambda: triangles, display_list_sha256="virtual-union-not-a-runtime-key")
    merged_plan = {"added_vertices": added, "authoring": dict(body_plans[0]["authoring"],
        edge_decisions=dict(sorted(decisions.items())))}
    try:
        result = paired_outline_plan(merged, merged_plan, outline, maximum_distance=maximum_distance)
        paired_bodies = body_plans
    except ValueError as error:
        if "welded counts differ" not in str(error):
            raise
        # Some authored shells split a crease into two offset vertices where
        # the body has one position. Prove the complete triangle multiset, then
        # keep every affected support edge linear on BOTH body and shell.
        paired_bodies, result = _pair_split_shell(bodies, body_plans, merged, outline,
                                                maximum_distance=maximum_distance)
    result["authoring"].pop("body_display_list_sha256")
    result["authoring"].update({"method": "paired-multipart-body-outline-affine-stencil/v1",
        "body_display_list_sha256s": [body.display_list_sha256 for body in bodies],
        "body_draw_count": len(bodies), "material_seams": "identical-local-position-stencils-required"})
    return paired_bodies, result


def _unique_split_triangle_mapping(merged, outline, body_points, body_skins, body_ids, distance_bound):
    """Prove a unique bounded mapping, including authored duplicated shell corners.

    Nearest position can be wrong around close details. This finite constraint
    solver uses every original triangle occurrence, never a relaxed coverage
    threshold. Search exhaustion, ambiguity and missing faces fail closed.
    """
    groups, outline_keys, domains = {}, [], []
    for i, point in enumerate(outline.positions):
        key = (tuple(point), _signature(outline, i))
        if key not in groups:
            groups[key] = len(groups)
            candidates = {j for j, other in enumerate(body_points) if key[1] == body_skins[j]
                and float(np.linalg.norm(np.asarray(point) - other)) <= distance_bound}
            if not 1 <= len(candidates) <= 8:
                raise ValueError("split outline has no bounded tractable source correspondence")
            domains.append(candidates)
        outline_keys.append(groups[key])
    body_faces = Counter(tuple(sorted(body_ids[merged.vertices[i].position_index] for i in triangle))
                         for triangle in merged.triangle_vertex_indices())
    shell_faces = [tuple(outline_keys[outline.vertices[i].position_index] for i in triangle)
                   for triangle in outline.triangle_vertex_indices()]
    if len(shell_faces) != sum(body_faces.values()):
        raise ValueError("split outline triangle connectivity differs")
    constraints = []
    for triangle in shell_faces:
        allowed = [v for v in itertools.product(*(domains[i] for i in triangle))
                   if tuple(sorted(v)) in body_faces and
                   all(triangle[a] != triangle[b] or v[a] == v[b] for a in range(3) for b in range(a))]
        if not allowed:
            raise ValueError("split outline triangle has no bounded body correspondence")
        constraints.append((triangle, allowed))

    def propagate(current):
        current = [set(d) for d in current]
        while True:
            changed = False
            for triangle, allowed in constraints:
                valid = [v for v in allowed if all(v[j] in current[i] for j, i in enumerate(triangle))]
                if not valid:
                    return None
                for j, i in enumerate(triangle):
                    kept = current[i] & {v[j] for v in valid}
                    if not kept:
                        return None
                    if kept != current[i]:
                        current[i] = kept
                        changed = True
            if not changed:
                return current

    nodes, solutions = 0, []
    def search(current, depth=0):
        nonlocal nodes
        nodes += 1
        if nodes > 10000 or depth > 128:
            raise ValueError("split outline bounded correspondence search exhausted")
        current = propagate(current)
        if current is None:
            return
        uncertain = [i for i, d in enumerate(current) if len(d) > 1]
        if not uncertain:
            mapping = [next(iter(d)) for d in current]
            if set(mapping) == set(range(len(body_points))) and \
                    Counter(tuple(sorted(mapping[i] for i in t)) for t in shell_faces) == body_faces:
                solutions.append(mapping)
            return
        index = min(uncertain, key=lambda i: len(current[i]))
        for candidate in sorted(current[index]):
            branch = [set(d) for d in current]
            branch[index] = {candidate}
            search(branch, depth + 1)
            if len(solutions) > 1:
                return
    search(domains)
    if len(solutions) != 1:
        raise ValueError("split outline needs one unique complete triangle correspondence")
    return [solutions[0][i] for i in outline_keys]


def _pair_split_shell(bodies, body_plans, merged, outline, *, maximum_distance=None):
    body_keys, body_points, body_skins, body_ids = {}, [], [], []
    for i, point in enumerate(merged.positions):
        key = (tuple(point), _signature(merged, i))
        if key not in body_keys:
            body_keys[key] = len(body_points)
            body_points.append(point)
            body_skins.append(key[1])
        body_ids.append(body_keys[key])
    extent = float(np.ptp(np.asarray(body_points), axis=0).max())
    distance_bound = _correspondence_bound(extent, maximum_distance)
    if maximum_distance is not None:
        outline_ids = _unique_split_triangle_mapping(merged, outline, body_points, body_skins,
                                                     body_ids, distance_bound)
    else:
        outline_ids = []
        for i, point in enumerate(outline.positions):
            candidates = sorted((float(np.linalg.norm(np.asarray(point) - other)), j)
                for j, other in enumerate(body_points) if _signature(outline, i) == body_skins[j])
            if not candidates or candidates[0][0] > distance_bound or \
                    len(candidates) > 1 and candidates[1][0] - candidates[0][0] < extent * 1e-7:
                raise ValueError("split outline has no unique bounded skin-compatible body correspondence")
            outline_ids.append(candidates[0][1])
    # Same outline coordinates/skin may be UV duplicates, not shell splits.
    shell_vertices = defaultdict(dict)
    for index, vertex in enumerate(outline.vertices):
        position = vertex.position_index
        shell_vertices[outline_ids[position]].setdefault(tuple(outline.positions[position]), index)
    if set(shell_vertices) != set(body_ids):
        raise ValueError("split outline does not cover the complete body")
    body_triangles = Counter(tuple(sorted(body_ids[merged.vertices[i].position_index] for i in triangle))
                             for triangle in merged.triangle_vertex_indices())
    outline_triangles = Counter(tuple(sorted(outline_ids[outline.vertices[i].position_index] for i in triangle))
                                for triangle in outline.triangle_vertex_indices())
    if body_triangles != outline_triangles:
        raise ValueError("split outline triangle connectivity differs")
    plans = deepcopy(body_plans)
    guarded = set()
    for body, plan in zip(bodies, plans, strict=True):
        ids = [body_keys[(tuple(point), _signature(body, i))] for i, point in enumerate(body.positions)]
        for value in plan["added_vertices"]:
            support = {ids[body.vertices[i].position_index] for i, _ in value["position_stencil"]}
            if any(len(shell_vertices[key]) != 1 for key in support):
                guarded.add(tuple(sorted(ids[body.vertices[i].position_index] for i in value["attributes"])))
    stencils = {}
    for body, plan in zip(bodies, plans, strict=True):
        ids = [body_keys[(tuple(point), _signature(body, i))] for i, point in enumerate(body.positions)]
        local_guards, previously_curved = set(), set()
        source = np.asarray([body.positions[v.position_index] for v in body.vertices])
        for value in plan["added_vertices"]:
            edge = tuple(sorted(ids[body.vertices[i].position_index] for i in value["attributes"]))
            if edge in guarded:
                a, b = value["attributes"]
                previous = sum((source[i] * weight for i, weight in value["position_stencil"]), np.zeros(3))
                if np.linalg.norm(previous - (source[a] + source[b]) * 0.5) > extent * 1e-8:
                    previously_curved.add(edge)
                value["position_stencil"] = [[i, 0.5] for i in value["attributes"]]
                local_guards.add(edge)
            stencil = defaultdict(float)
            for i, weight in value["position_stencil"]:
                stencil[ids[body.vertices[i].position_index]] += weight
            if edge in stencils and any(abs(stencils[edge].get(i, 0) - stencil.get(i, 0)) > 1e-8
                                       for i in stencils[edge].keys() | stencil.keys()):
                raise ValueError("body material seam has conflicting position stencils")
            stencils[edge] = dict(stencil)
        plan["authoring"]["split_outline_guarded_edges"] = len(local_guards)
        decisions = plan["authoring"]["edge_decisions"]
        decisions["curved"] = decisions.get("curved", 0) - len(previously_curved)
        decisions["split_outline_guard"] = len(previously_curved)
        plan["authoring"]["maximum_bind_displacement"] = max((float(np.linalg.norm(point -
            (source[a] + source[b]) * 0.5)) for point, (a, b) in zip(
            apply_plan_positions(body, plan)[body.vertex_count:],
            (v["attributes"] for v in plan["added_vertices"]), strict=True)), default=0)
    base = body_plans[0]["authoring"]
    plan = refinement_plan(outline, normal_guide=merged, strength=0.0,
        crease_degrees=base["crease_degrees"], displacement_fraction=base["maximum_displacement_fraction"])
    for value in plan["added_vertices"]:
        edge = tuple(sorted(outline_ids[outline.vertices[i].position_index] for i in value["attributes"]))
        if edge not in stencils:
            raise ValueError("split outline edge has no body stencil")
        if edge in guarded:
            value["position_stencil"] = [[i, 0.5] for i in value["attributes"]]
        else:
            value["position_stencil"] = [[next(iter(shell_vertices[key].values())), weight]
                for key, weight in stencils[edge].items()]
    source = np.asarray([outline.positions[v.position_index] for v in outline.vertices])
    new_positions = apply_plan_positions(outline, plan)[outline.vertex_count:]
    decisions = Counter()
    for body_plan in plans:
        decisions.update(body_plan["authoring"]["edge_decisions"])
    plan["authoring"].update({"strength": base["strength"],
        "body_display_list_sha256": "virtual-union-not-a-runtime-key",
        "paired_welded_vertices": len(body_points), "split_outline_guarded_edges": len(guarded),
        "edge_decisions": dict(sorted(decisions.items())),
        "pairing": "unique-bounded-skin-correspondence-exact-full-triangle-multiset-with-split-shell-guards",
        "maximum_bind_displacement": max((float(np.linalg.norm(p - (source[a] + source[b]) * 0.5))
            for p, (a, b) in zip(new_positions, (v["attributes"] for v in plan["added_vertices"]), strict=True)), default=0)})
    if maximum_distance is not None:
        plan["authoring"]["maximum_correspondence_distance"] = distance_bound
        plan["authoring"]["pairing"] = "unique-bounded-complete-triangle-constraint-correspondence-with-split-shell-guards"
        plan["authoring"]["outline_body_correspondence_sha256"] = hashlib.sha256(
            json.dumps(outline_ids, separators=(",", ":")).encode()).hexdigest()
    return plans, plan

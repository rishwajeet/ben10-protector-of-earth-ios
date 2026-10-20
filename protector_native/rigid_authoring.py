"""Explicit body/outline groups for immutable rigid-source refinement.

Partial shells require an inspected, exact-source review. Default character
pairing and coverage bounds are unchanged. A separate explicit thickness review
supports small rigid limbs with model-wide outline thickness; it never changes
refinement displacement or automatically falls back after a failed full pairing.
Original transforms stay in the game; positions remain local to their draw.
"""
from __future__ import annotations

import math

from protector_native.geometry_pairing import _digest, _identity, paired_partial_shell_plans, partial_shell_audit
from protector_native.geometry_refinement import (
    _pair_split_shell, paired_multipart_outline_plans, paired_outline_plan, refinement_plan,
)


def _reviewed_full_shell_plans(meshes, plans, outline, maximum_distance):
    if len(meshes) > 1:
        return paired_multipart_outline_plans(meshes, plans, outline, maximum_distance=maximum_distance)
    try:
        return plans, paired_outline_plan(meshes[0], plans[0], outline, maximum_distance=maximum_distance)
    except ValueError as error:
        if "welded counts differ" not in str(error):
            raise
        # The explicit full-source review may prove an authored split shell.
        # The complete triangle multiset and dependent-support guards still
        # apply; this never falls back to partial coverage.
        plans, shell = _pair_split_shell(meshes, plans, meshes[0], outline,
                                         maximum_distance=maximum_distance)
        shell["authoring"]["body_display_list_sha256"] = meshes[0].display_list_sha256
        shell["authoring"]["method"] = "paired-body-split-outline-affine-stencil/v1"
        return plans, shell


def rigid_shell_correspondence_audit(bodies, outline, *, maximum_distance, mode):
    """Generate a source-bound review, never automatic candidate admission.

    A caller must inspect the thickness and correspondence before passing this
    exact report to rigid_group_plans. Full topology and partial-feature guards
    are unchanged. Distance cannot be inferred from a failed pairing.
    The body-complete mode allows additional guarded shell caps only when every
    body triangle matches; it does not weaken the ordinary partial policy.
    """
    if not 1 <= len(bodies) <= 8 or outline is None or mode not in ("full", "partial", "body-complete"):
        raise ValueError("explicit thickness review requires one to eight bodies, one shell and a supported mode")
    if isinstance(maximum_distance, bool) or not isinstance(maximum_distance, (int, float)) or \
            not math.isfinite(maximum_distance) or maximum_distance <= 0:
        raise ValueError("thickness review requires a finite positive explicit distance")
    body = bodies[0]
    # Validate roles, source transform and draw uniqueness without relaxing any
    # geometry condition. The actual topology check below remains mandatory.
    selected = [*bodies, outline]
    identity = (body.package_sha256, body.source["model_offset"], body.source["transform_byte"])
    if any(d.mesh.middle_attribute != "normal" for d in bodies) or outline.mesh.middle_attribute != "color0" or \
            any((d.package_sha256, d.source["model_offset"], d.source["transform_byte"]) != identity
                for d in selected) or len({d.source["draw_index"] for d in selected}) != len(selected):
        raise ValueError("thickness review requires an exact same-transform rigid body/shell pair")
    if any(any(d.mesh.influences) for d in selected):
        raise ValueError("explicit rigid thickness review cannot admit weighted geometry")
    if mode == "full":
        plans = [refinement_plan(d.mesh, preserve_planar_regions=True) for d in bodies]
        _, shell = _reviewed_full_shell_plans([d.mesh for d in bodies], plans, outline.mesh, maximum_distance)
        correspondence = {k: shell["authoring"][k] for k in
            ("paired_welded_vertices", "pairing", "maximum_correspondence_distance")}
        if "outline_body_correspondence_sha256" in shell["authoring"]:
            correspondence["outline_body_correspondence_sha256"] = shell["authoring"]["outline_body_correspondence_sha256"]
    else:
        correspondence = partial_shell_audit([d.mesh for d in bodies], outline.mesh,
            maximum_distance=maximum_distance, coverage="body-complete" if mode == "body-complete" else "balanced")
    result = {"schema": "protector-native.rigid-shell-correspondence-review/v1", "mode": mode,
        "source_package_sha256": body.package_sha256, "model_offset": body.source["model_offset"],
        "transform_byte": body.source["transform_byte"], "body_draw_index": body.source["draw_index"],
        "outline_draw_index": outline.source["draw_index"], "body_source": _identity(body.mesh),
        "outline_source": _identity(outline.mesh), "maximum_distance": maximum_distance,
        "correspondence": correspondence}
    if len(bodies) > 1:
        result.pop("body_draw_index")
        result.pop("body_source")
        result["body_draw_indices"] = [d.source["draw_index"] for d in bodies]
        result["body_sources"] = [_identity(d.mesh) for d in bodies]
    return result


def rigid_group_plans(bodies, outline=None, *, strength=1.0, partial_shell_review=None,
                      shell_correspondence_review=None):
    if not 1 <= len(bodies) <= 8 or any(d.mesh.middle_attribute != "normal" for d in bodies):
        raise ValueError("rigid group requires one to eight normal-bearing bodies")
    selected = [*bodies, *([] if outline is None else [outline])]
    if outline is not None and outline.mesh.middle_attribute != "color0":
        raise ValueError("rigid group outline must be a color surface")
    source = bodies[0]
    identity = (source.package_sha256, source.source["model_offset"], source.source["transform_byte"])
    if any((d.package_sha256, d.source["model_offset"], d.source["transform_byte"]) != identity
           for d in selected):
        raise ValueError("rigid group must share the exact package, model and original transform")
    if len({d.source["draw_index"] for d in selected}) != len(selected):
        raise ValueError("rigid body and outline draws must be distinct")
    if partial_shell_review is not None:
        if outline is None:
            raise ValueError("partial rigid shell review requires an explicit outline")
        expected = {
            "schema": "protector-native.partial-shell-review/v1",
            "geometry_kind": "rigid-source-array",
            "source_package_sha256": source.package_sha256,
            "model_offset": source.source["model_offset"],
            "body_draw_indices": [d.source["draw_index"] for d in bodies],
            "outline_draw_index": outline.source["draw_index"],
        }
        if not isinstance(partial_shell_review, dict) or any(
                partial_shell_review.get(k) != v for k, v in expected.items()):
            raise ValueError("partial rigid shell review does not match the exact selected source")
    plans = [refinement_plan(d.mesh, strength=strength, preserve_planar_regions=True) for d in bodies]
    if shell_correspondence_review is not None:
        if partial_shell_review is not None or not isinstance(shell_correspondence_review, dict):
            raise ValueError("supply one exact shell review, not conflicting policies")
        expected = rigid_shell_correspondence_audit(bodies, outline,
            maximum_distance=shell_correspondence_review.get("maximum_distance"),
            mode=shell_correspondence_review.get("mode"))
        if shell_correspondence_review != expected:
            raise ValueError("rigid thickness pairing requires the exact inspected source review")
        distance = expected["maximum_distance"]
        meshes = [d.mesh for d in bodies]
        if expected["mode"] == "full":
            plans, shell = _reviewed_full_shell_plans(meshes, plans, outline.mesh, distance)
        else:
            plans, shell = paired_partial_shell_plans(meshes, plans, outline.mesh,
                maximum_distance=distance, expected_audit=expected["correspondence"],
                coverage="body-complete" if expected["mode"] == "body-complete" else "balanced")
        for plan in [*plans, shell]:
            plan["authoring"]["rigid_shell_correspondence_review_sha256"] = _digest(expected)
        shell["authoring"]["rigid_shell_correspondence_review"] = expected
        return [*plans, shell]
    if outline is None:
        return plans
    meshes = [d.mesh for d in bodies]
    if partial_shell_review is not None:
        plans, shell = paired_partial_shell_plans(meshes, plans, outline.mesh,
            expected_audit=partial_shell_review.get("correspondence"))
    elif len(bodies) == 1:
        shell = paired_outline_plan(meshes[0], plans[0], outline.mesh)
    else:
        plans, shell = paired_multipart_outline_plans(meshes, plans, outline.mesh)
    return [*plans, shell]

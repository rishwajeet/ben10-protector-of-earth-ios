#!/usr/bin/env python3
"""Rebuild every selected geometry profile from an admitted personal game.

No development geometry pack, generated stencil, copied census or original
vertex array is an input. Fixed selectors/review hashes live in the recipe
contract. Output and resumable per-group results remain private, outside Git.
"""
from __future__ import annotations

import argparse
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import canonical, digest_file
from protector_native.executable_truth import RBNEG9_DOL_SHA256
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json

RECIPES = ROOT / "reference/personal_geometry_recipes.json"
MAX_RUNTIME_MANIFEST_BYTES = 24 * 1024**2
ALGORITHMS = ["tools/personal_geometry.py", "tools/audit_bigb.py",
    "requirements-personal.lock",
    "protector_native/bigb.py", "protector_native/character_skin.py",
    "protector_native/rigid_model.py", "protector_native/rigid_authoring.py",
    "protector_native/geometry_refinement.py", "protector_native/geometry_pairing.py",
    "protector_native/rigid_admission.py", "protector_native/asset_inventory.py"]


def identity(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def write_runtime_manifest(path, pack):
    # Runtime JSON is bounded by geometry_pack.mm. Pretty-printing the complete
    # stencil arrays can exceed that cap without adding any geometry.
    encoded = canonical(pack) + b"\n"
    if len(encoded) > MAX_RUNTIME_MANIFEST_BYTES:
        raise BuildError("Geometry manifest exceeds the 24 MiB runtime budget")
    if path.is_symlink():
        raise BuildError("Geometry runtime manifest is a link")
    path.write_bytes(encoded)


def validate_contract(contract):
    if contract.get("schema") != "protector-native.personal-geometry-recipes/v1" or \
            contract.get("title_dol_sha256") != RBNEG9_DOL_SHA256 or \
            contract.get("entry_count") != 194 or len(contract.get("entry_order", [])) != 194 or \
            len(set(contract["entry_order"])) != 194:
        raise BuildError("Geometry recipe coverage or source identity differs")
    groups = contract.get("groups")
    if not isinstance(groups, list) or not 1 <= len(groups) <= 194:
        raise BuildError("Missing bounded geometry groups")
    selected, names, source_draws = set(), set(), set()
    for group in groups:
        if group.get("kind") not in ("rigid", "skinned") or \
                not re.fullmatch(r"[a-z0-9_-]{1,80}", str(group.get("id", ""))) or group["id"] in names or \
                not re.fullmatch(r"[0-9_]+\.gcs", str(group.get("package", ""))) or \
                not re.fullmatch(r"0x[0-9a-f]{8}", str(group.get("offset", ""))) or \
                group.get("strength") != 1.0:
            raise BuildError("Invalid or repeated geometry group")
        names.add(group["id"])
        bodies, outline = group.get("body_draws"), group.get("outline_draw")
        if not isinstance(bodies, list) or not 1 <= len(bodies) <= 8 or \
                any(type(i) is not int or not 0 <= i < 65536 for i in bodies) or \
                len(set(bodies)) != len(bodies) or \
                outline is not None and (type(outline) is not int or not 0 <= outline < 65536 or outline in bodies):
            raise BuildError("Invalid geometry draw selection")
        draws = [*bodies, *([] if outline is None else [outline])]
        for draw in draws:
            key = (group["package"], group["kind"], group["offset"], draw)
            if key in source_draws:
                raise BuildError("Geometry groups overlap a source draw")
            source_draws.add(key)
        expected = group.get("expected_entries")
        if not isinstance(expected, list) or len(expected) != len(draws):
            raise BuildError("Geometry group lacks exact output coverage")
        for entry, draw in zip(expected, draws, strict=True):
            prefix = f"{Path(group['package']).stem}-{int(group['offset'], 16):08x}"
            wanted = prefix + ("-rigid" if group["kind"] == "rigid" else "") + f"-draw-{draw}"
            if entry.get("id") != wanted or wanted in selected or \
                    not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
                raise BuildError("Invalid or repeated expected geometry identity")
            selected.add(wanted)
        review = group.get("shell_review")
        if review is not None:
            if outline is None or review.get("kind") not in ("partial", "rigid-thickness") or \
                    not re.fullmatch(r"[0-9a-f]{64}", str(review.get("sha256", ""))):
                raise BuildError("Invalid explicit shell review")
            if review["kind"] == "rigid-thickness" and (group["kind"] != "rigid" or \
                    review.get("mode") not in ("full", "partial", "body-complete") or \
                    type(review.get("maximum_distance")) not in (int, float) or \
                    not 0 < review["maximum_distance"] < 1):
                raise BuildError("Invalid rigid correspondence bound")
    if selected != set(contract["entry_order"]):
        raise BuildError("Geometry recipes leave missing or extra entries")


def verify_entries(entries, expected):
    if not isinstance(entries, list) or len(entries) != len(expected):
        raise BuildError("Replayed geometry group coverage differs")
    for value, reference in zip(entries, expected, strict=True):
        if value.get("id") != reference["id"] or identity(value) != reference["sha256"]:
            raise BuildError(f"Replayed geometry differs from the selected profile: {reference['id']}")


def build_group(group, package, commands):
    from protector_native.character_skin import parse_wii_character_skin
    from protector_native.geometry_pairing import partial_shell_audit, paired_partial_shell_plans
    from protector_native.geometry_refinement import refinement_plan, paired_outline_plan, paired_multipart_outline_plans
    from protector_native.rigid_authoring import rigid_group_plans, rigid_shell_correspondence_audit
    from protector_native.rigid_model import parse_wii_rigid_model_draw

    rigid = group["kind"] == "rigid"
    draw_indices = [*group["body_draws"], *([] if group["outline_draw"] is None else [group["outline_draw"]])]
    parser = parse_wii_rigid_model_draw if rigid else parse_wii_character_skin
    offset = {"model_offset" if rigid else "binding_offset": int(group["offset"], 16)}
    draws = [parser(package.file_info, commands, package_sha256=package.package_sha256,
                    draw_index=index, **offset) for index in draw_indices]
    bodies = draws[:len(group["body_draws"])]
    outline = draws[-1] if group["outline_draw"] is not None else None
    review = group.get("shell_review")
    reviewed = None
    if review and review["kind"] == "rigid-thickness":
        reviewed = rigid_shell_correspondence_audit(bodies, outline,
            maximum_distance=review["maximum_distance"], mode=review["mode"])
        if identity(reviewed) != review["sha256"]:
            raise BuildError("Regenerated shell review differs from the inspected source review")
    elif review:
        reviewed = partial_shell_audit([d.mesh for d in bodies], outline.mesh)
        if identity(reviewed) != review["sha256"]:
            raise BuildError("Regenerated partial-shell audit differs from the inspected review")
    if rigid:
        partial = None
        if review and review["kind"] == "partial":
            partial = {"schema": "protector-native.partial-shell-review/v1", "geometry_kind": "rigid-source-array",
                "source_package_sha256": package.package_sha256, "model_offset": group["offset"],
                "body_draw_indices": group["body_draws"], "outline_draw_index": group["outline_draw"],
                "correspondence": reviewed}
        plans = rigid_group_plans(bodies, outline, strength=float(group["strength"]), partial_shell_review=partial,
            shell_correspondence_review=reviewed if review and review["kind"] == "rigid-thickness" else None)
    else:
        plans = [refinement_plan(d.mesh, strength=float(group["strength"])) for d in bodies]
        if outline:
            if review:
                plans, shell = paired_partial_shell_plans([d.mesh for d in bodies], plans, outline.mesh,
                    expected_audit=reviewed)
            elif len(bodies) == 1:
                shell = paired_outline_plan(bodies[0].mesh, plans[0], outline.mesh)
            else:
                plans, shell = paired_multipart_outline_plans([d.mesh for d in bodies], plans, outline.mesh)
            plans.append(shell)
    for plan, draw, expected in zip(plans, draws, group["expected_entries"], strict=True):
        plan.update(id=expected["id"], source=draw.to_dict(),
            source_anchor_prefix_bytes=draw.mesh.source_anchor_prefix_bytes,
            source_anchor_sha256=draw.mesh.source_anchor_sha256)
        if rigid:
            plan["source_rigid_arrays"] = draw.source_rigid_arrays
    verify_entries(plans, group["expected_entries"])
    return plans, draws


def skin_key(source):
    m = source["mesh"]
    return tuple(m[k] for k in ("display_list_sha256", "uvs_sha256", "source_anchor_sha256", "source_anchor_prefix_bytes"))


def skin_identity(source):
    m = source["mesh"]
    return tuple(m[k] for k in ("positions_sha256", "weights_sha256", "normals_sha256", "colors_sha256", "middle_attribute")) + \
        (tuple(source["palette"]["bone_indices"]),)


def census(game, game_table, selected, get_package):
    from protector_native.asset_inventory import inspect_package
    from protector_native.rigid_admission import matching_occurrences, runtime_key
    rigid = [d for kind, d in selected if kind == "rigid"]
    skins = {skin_key(d.to_dict()): skin_identity(d.to_dict()) for kind, d in selected if kind == "skinned"}
    if len(skins) != sum(kind == "skinned" for kind, d in selected):
        raise BuildError("Repeated skinned runtime key")
    rigid_counts, skin_counts, reports = [0] * len(rigid), dict.fromkeys(skins, 0), []
    packages = [name for name in game_table if name.startswith("files/") and Path(name).suffix in (".gcs", ".gcm")]
    if len(packages) != 336:
        raise BuildError("Complete 336-package census is required")
    for index, name in enumerate(packages):
        package, commands = get_package(Path(name).name, cache=False)
        if package.package_sha256 != game_table[name]["sha256"]:
            raise BuildError("Original package changed during source census")
        details = inspect_package(package.file_info, commands, package.package_sha256)
        if details["inspection_errors"]:
            raise BuildError(f"Source inspection failed in {name}")
        skin_hits = 0
        for source in details["skinned_meshes"]:
            key = skin_key(source)
            if key in skins:
                if skin_identity(source) != skins[key]:
                    raise BuildError("Skinned runtime key admits differing source geometry")
                skin_counts[key] += 1
                skin_hits += 1
        audit = matching_occurrences(package.file_info, commands, package.package_sha256, rigid)
        selected_hits = []
        for hit in audit["primitive_hits"]:
            if hit["selected_key_match"]:
                selected_hits.append(hit["selected_key_index"])
                rigid_counts[hit["selected_key_index"]] += 1
        reports.append({"package": name, "sha256": package.package_sha256,
            "skinned_hits": skin_hits, "selected_rigid_hits": selected_hits,
            "rejected_other_primitive_hits": len(audit["rejected_primitive_hits"])})
        if index % 16 == 0 or index == len(packages) - 1:
            print(f"Source identity census: {index + 1}/{len(packages)}", flush=True)
    if not all(rigid_counts) or not all(skin_counts.values()):
        raise BuildError("Source census did not encounter every selected runtime identity")
    return {"schema": "protector-native.personal-geometry-census/v1", "title_dol_sha256": RBNEG9_DOL_SHA256,
        "packages": reports, "rigid_profile_count": len(rigid), "skinned_profile_count": len(skins),
        "rigid_occurrences": rigid_counts, "skinned_occurrences": list(skin_counts.values()),
        "topology_uv_source_keys_unambiguous": True,
        "scope": "All admitted packages scanned for the selected runtime keys; no new visual or gameplay acceptance"}


def rebuild(game: Path, work: Path):
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    if version("networkx") != "3.6.1" or version("numpy") != "2.4.2":
        raise BuildError("Use requirements-personal.lock: reviewed geometry requires NetworkX 3.6.1 and NumPy 2.4.2")
    game, work = outside_repo(game), outside_repo(work)
    if work == game or work.is_relative_to(game) or game.is_relative_to(work):
        raise BuildError("Geometry workspace must be separate from original inputs")
    contract = json.loads(RECIPES.read_text())
    validate_contract(contract)
    if contract["source_lock_sha256"] != digest_file(LOCK):
        raise BuildError("Original-content contract changed")
    lock = json.loads(LOCK.read_text())
    check_table(game, lock["game"])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError("Geometry replay needs an existing parent with 5 GiB headroom")
    owner = {"schema": "protector-native.personal-geometry-work/v1", "game": str(game),
        "contract_sha256": digest_file(RECIPES), "algorithms": {name: digest_file(ROOT / name) for name in ALGORITHMS}}
    if work.exists():
        if work.is_symlink() or json.loads((work / "owner.json").read_text()) != owner:
            raise BuildError("Geometry workspace belongs to a different source, recipe or algorithm")
    else:
        work.mkdir(mode=0o700)
        write_json(work / "owner.json", owner)
    groups_dir = work / "groups"
    groups_dir.mkdir(exist_ok=True, mode=0o700)
    if groups_dir.is_symlink():
        raise BuildError("Geometry output directory is a link")
    started, package_cache, entries, selected = time.monotonic(), {}, {}, []

    def get_package(name, cache=True):
        if name in package_cache:
            return package_cache[name]
        path = game / "files" / name
        if path.is_symlink():
            raise BuildError("Original package is a link")
        value = decode_package(path)
        if value.package_sha256 != lock["game"]["files/" + name]["sha256"]:
            raise BuildError("Original package identity changed")
        commands = parse_relocation_commands(value.relocation, "big", file_info_size=len(value.file_info))
        result = value, commands
        if cache:
            package_cache[name] = result
        return result

    for index, group in enumerate(contract["groups"]):
        print(f"Rebuild geometry {index + 1}/{len(contract['groups'])}: {group['id']}", flush=True)
        package, commands = get_package(group["package"])
        output = groups_dir / (group["id"] + ".json")
        # Recompute selected draws even when plans are cached, so the full-source
        # census uses typed originals, never previously generated geometry.
        if output.exists():
            if output.is_symlink():
                raise BuildError("Cached geometry is a link")
            plans = json.loads(output.read_text())
            verify_entries(plans, group["expected_entries"])
            from protector_native.character_skin import parse_wii_character_skin
            from protector_native.rigid_model import parse_wii_rigid_model_draw
            rigid = group["kind"] == "rigid"
            parser = parse_wii_rigid_model_draw if rigid else parse_wii_character_skin
            offset = {"model_offset" if rigid else "binding_offset": int(group["offset"], 16)}
            draws = [parser(package.file_info, commands, package_sha256=package.package_sha256,
                draw_index=n, **offset) for n in [*group["body_draws"], *([] if group["outline_draw"] is None else [group["outline_draw"]])]]
        else:
            plans, draws = build_group(group, package, commands)
            write_json(output, plans)
        entries.update({e["id"]: e for e in plans})
        selected.extend((group["kind"], draw) for draw in draws)
    ordered = [entries[name] for name in contract["entry_order"]]
    if identity(ordered) != contract["entries_sha256"]:
        raise BuildError("Complete geometry pack differs from the selected reference")
    census_path = work / "source-census.json"
    # A census is small relative to its source. Replay it to avoid interpreting
    # a previous private receipt as freshly checked input evidence.
    audit = census(game, lock["game"], selected, get_package)
    write_json(census_path, audit)
    pack = {"schema": "protector-native.geometry-pack/v1", "title_dol_sha256": RBNEG9_DOL_SHA256,
        "pack_id": contract["pack_id"], "status": "candidate-not-accepted",
        "scope": "Exact selected render-only profiles replayed from the personal original; existing art acceptance is separate",
        "source_admission": {"kind": "full-source-replay-and-runtime-key-census/v1", "packages": 336,
            "source_lock_sha256": digest_file(LOCK), "recipe_sha256": digest_file(RECIPES),
            "inventory_sha256": digest_file(census_path), "topology_uv_source_keys_unambiguous": True,
            "reference_entries_sha256": contract["entries_sha256"]},
        "entries": ordered}
    write_runtime_manifest(work / "geometry.json", pack)
    result = {"schema": "protector-native.personal-geometry-result/v1", "status": "verified-replay",
        "entries": len(ordered), "groups": len(contract["groups"]), "source_packages_scanned": 336,
        "entries_sha256": identity(ordered), "manifest_sha256": digest_file(work / "geometry.json"),
        "seconds": time.monotonic() - started, "owner_sha256": digest_file(work / "owner.json")}
    write_json(work / "receipt.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(rebuild(args.game, args.work_dir), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f"Geometry replay: {error}\n")


if __name__ == "__main__":
    main()

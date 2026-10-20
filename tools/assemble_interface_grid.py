#!/usr/bin/env python3
"""Assemble an explicitly selected, source-traced opaque UI grid without resampling.

The grid's live quads prove adjacency and orientation. Original RGBA bytes are
copied, not screen-captured, recoloured or restored. This is private restoration
input; it does not authorize a replacement or change guest layout/visibility.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from tools.prepare_texture_restoration import DOL_SHA256
from tools.review_interface_source import KEY


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def no_links(path: Path) -> Path:
    path = path.absolute()
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError("symlink paths are not accepted")
    return path.resolve()


def report(path: Path) -> tuple[Path, bytes, dict]:
    path = no_links(path)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("input report exceeds its bound")
    data = path.read_bytes()
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("input report must be an object")
    return path, data, value


def indexed(records: list) -> dict:
    if not isinstance(records, list) or not 1 <= len(records) <= 256:
        raise ValueError("invalid bounded draw list")
    result = {}
    for record in records:
        index = record.get("draw_index")
        if type(index) is not int or index < 0 or index in result:
            raise ValueError("invalid or duplicated draw identity")
        result[index] = record
    return result


def rectangle(draw: dict, *, single: bool = False) -> list[float]:
    if (draw.get("vertex_count"), draw.get("index_count"), draw.get("indexed")) != (4, 6, True) or \
            draw.get("indices") != [0, 1, 2, 0, 2, 3]:
        raise ValueError("only complete four-vertex indexed quads are supported")
    vertices = draw.get("vertices", [])
    if len(vertices) != 4:
        raise ValueError("quad vertices are missing")
    for i, vertex in enumerate(vertices):
        clip = vertex.get("clip", [])
        if len(clip) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in clip) or clip[3] != 1:
            raise ValueError("finite orthographic clip coordinates are required")
        color = vertex.get("color", [])
        if len(color) != 4 or any(type(c) not in (int, float) or not math.isfinite(c) for c in color) or \
                not 0 <= color[0] <= 1 or color[:3] != [color[0]]*3 or \
                not 0 <= color[3] <= 1 or (not single and color[3] != 1) or \
                color != vertices[0].get("color"):
            raise ValueError("grid vertices must use a uniform opaque neutral tint")
        for stage in draw["textures"]:
            uv_set = stage.get("uv_set")
            uv = vertex.get("uv", [])
            if type(uv_set) is not int or not 0 <= uv_set < len(uv) or \
                    uv[uv_set] != [[0, 0], [1, 0], [1, 1], [0, 1]][i]:
                raise ValueError("tile UVs must preserve the complete source orientation")
    a, b, c, d = [vertex["clip"] for vertex in vertices]
    if single:
        # A single complete texture needs no adjacency assertion. Its source
        # UV order is still exact; rotation and uniform guest opacity are not
        # baked into its pixels. Multi-tile canvases retain the strict grid gate.
        turns = [(q[0]-p[0])*(r[1]-q[1])-(q[1]-p[1])*(r[0]-q[0])
                 for p, q, r in ((a, b, c), (b, c, d), (c, d, a), (d, a, b))]
        if any(v[2] != a[2] for v in (b, c, d)) or not (all(t > 0 for t in turns) or all(t < 0 for t in turns)):
            raise ValueError("single source quad must be nondegenerate, convex and at one depth")
        return [min(v[0] for v in (a, b, c, d)), max(v[1] for v in (a, b, c, d)),
                max(v[0] for v in (a, b, c, d)), min(v[1] for v in (a, b, c, d))]
    if not (a[0] < b[0] and a[1] > d[1]) or \
            a[1] != b[1] or b[0] != c[0] or c[1] != d[1] or d[0] != a[0] or \
            any(v[2] != a[2] for v in (b, c, d)):
        raise ValueError("grid quads must be axis aligned with a shared depth")
    return [a[0], a[1], c[0], c[1]]  # left, top, right, bottom; Y points up.


def assemble(audit_path: Path, trace_path: Path, output: Path, draw_indices: list[int], columns: int,
             *, paired: bool = False, isolated_quad: bool = False) -> dict:
    audit_path, audit_bytes, audit = report(audit_path)
    trace_path, trace_bytes, trace = report(trace_path)
    if audit.get("schema") != "protector-native.interface-source-audit/v1" or \
            trace.get("schema") != "protector-native.interface-source-trace/v1" or \
            trace.get("title_dol_sha256") != DOL_SHA256 or trace.get("audit_sha256") != sha(audit_bytes) or \
            Path(trace.get("audit", "")).resolve() != audit_path or trace.get("frame_index") != audit.get("frame_index"):
        raise ValueError("a matching title-bound live audit and source trace are required")
    # Mixed scene/UI captures need not contain every scene vertex to prove one
    # complete source quad. This opt-in never makes an adjacency, full-frame
    # coverage or layout claim; all selected pixels/planes/vertices remain
    # subject to the same exact source-object checks below.
    if isolated_quad and (not paired or columns != 1 or not isinstance(draw_indices, list) or len(draw_indices) != 1):
        raise ValueError("isolated mode requires one paired source quad")
    if not isolated_quad and (audit.get("omitted_orthographic_draws") != 0 or audit.get("omitted_vertices") != 0):
        raise ValueError("a complete interface audit is required")
    draws, traced = indexed(audit.get("draws")), indexed(trace.get("draws"))
    if draws.keys() != traced.keys() or (not isolated_quad and audit.get("total_draws") != len(draws)):
        raise ValueError("source trace and audit draw coverage differ")
    if isolated_quad and (any(type(audit.get(field)) is not int or audit[field] < 0 for field in
            ("total_draws", "omitted_orthographic_draws", "omitted_vertices")) or
            audit["total_draws"] < len(draws) or any(i >= audit["total_draws"] for i in draws)):
        raise ValueError("invalid mixed-frame audit bounds")
    if type(columns) is not int or not 1 <= columns <= 16 or not isinstance(draw_indices, list) or \
            not 1 <= len(draw_indices) <= 64 or len(draw_indices) % columns or \
            any(type(i) is not int for i in draw_indices) or len(set(draw_indices)) != len(draw_indices) or \
            not set(draw_indices) <= draws.keys():
        raise ValueError("select a bounded rectangular grid of unique draw indices")
    manifest_path, manifest_bytes, manifest = report(Path(trace["source_manifest"]))
    source_schema = "protector-native.texture-restoration-sources/v2" if paired else "protector-native.texture-restoration-sources/v1"
    if trace.get("source_manifest_sha256") != sha(manifest_bytes) or \
            manifest.get("schema") != source_schema or \
            manifest.get("title_dol_sha256") != DOL_SHA256 or manifest.get("failures") or \
            (paired and manifest.get("includes_auxiliary_planes") is not True):
        raise ValueError("source inventory changed or is incomplete")
    packages = {p["package"]: p["sha256"] for p in manifest["packages"]}
    traced_packages = {p["package"]: p["sha256"] for p in trace["packages"]}
    if not traced_packages or any(packages.get(name) != digest for name, digest in traced_packages.items()):
        raise ValueError("traced package identity differs from the inventory")
    destination = no_links(output)
    if destination.exists() or any(destination.is_relative_to(parent) for parent in (
            ROOT, audit_path.parent, trace_path.parent, manifest_path.parent,
            Path(manifest["source_data_root"]).resolve())):
        raise ValueError("use a new external output directory outside source/report directories")

    pixels, entries, reference = {}, [], draws[draw_indices[0]]
    viewport = reference.get("viewport")
    projection = reference.get("projection_words", [])
    if viewport not in ([0, 0, 640, 448], [0, 0, 640, 480]) or len(projection) != 7 or projection[-1] != 1:
        raise ValueError("a known full orthographic guest viewport is required")
    for position, index in enumerate(draw_indices):
        draw, match = draws[index], traced[index]
        stages = draw.get("textures", [])
        if len(stages) not in (1, 2) or draw.get("viewport") != viewport or draw.get("projection_words") != projection or \
                any(draw.get(field) != reference.get(field) for field in ("alpha_test", "blend_mode", "depth_mode")):
            raise ValueError("tile render states differ or use an unsupported stage count")
        for number, stage in enumerate(stages):
            expected = (64143, 63088 if len(stages) == 1 else 65520) if number == 0 else (589808, 63100)
            if (stage.get("stage"), stage.get("texture_unit")) != (number, number) or \
                    (stage.get("color_combiner"), stage.get("alpha_combiner")) != expected:
                raise ValueError("unsupported tile colour/coverage combiner")
            key = stage.get("source_key")
            identity = KEY.fullmatch(key) if isinstance(key, str) else None
            if not identity or stage.get("pixels_included") is not True:
                raise ValueError("complete texture pixels are required")
            width, height = int(identity[1]), int(identity[2])
            if max(width, height) > 512 or (width, height) != (stage.get("width"), stage.get("height")):
                raise ValueError("invalid bounded tile dimensions")
            if key not in pixels:
                path = no_links(audit_path.parent / f"{key}.rgba")
                if path.stat().st_size != width * height * 4:
                    raise ValueError("tile byte count changed")
                data = path.read_bytes()
                if sha(data) != identity[3] or any(a != 255 for a in data[3::4]):
                    raise ValueError("tile pixel hash changed or carries transparency")
                pixels[key] = (width, height, data)
            if number == 1 and (width, height) != (stages[0]["width"], stages[0]["height"]):
                raise ValueError("color and coverage dimensions must agree")
            if number == 1 and not paired and pixels[key][2] != bytes((0, 255, 0, 255)) * (width * height):
                raise ValueError("auxiliary coverage must be constant full green")
        keys = [s["source_key"] for s in stages]
        objects = match.get("source_objects", [])
        if match.get("match") != "exact-ordered-planes" or match.get("stage_keys") != keys or not objects:
            raise ValueError("each tile needs an exact ordered source-object match")
        for obj in objects:
            if obj.get("package_sha256") != traced_packages.get(obj.get("package")) or \
                    [p.get("source_key") for p in obj.get("planes", [])] != keys or \
                    [p.get("plane") for p in obj["planes"]] != list(range(len(stages))) or \
                    [p.get("gx_format") for p in obj["planes"]] != [s.get("gx_format") for s in stages]:
                raise ValueError("source object planes or package identity changed")
            for number in range(len(keys) if paired else 1):
                source = manifest["textures"].get(keys[number], {})
                if not any(o.get("package") == obj["package"] and o.get("resource_offset") == obj.get("resource_offset") and
                           o.get("package_sha256") == obj["package_sha256"] and
                           o.get("encoded_level_sha256") == obj["planes"][number].get("payload_sha256") and
                           (not paired or o.get("plane") == number)
                           for o in source.get("occurrences", [])):
                    raise ValueError("source plane is absent from the inventory")
        rect = rectangle(draw, single=paired and len(draw_indices) == 1)
        if draw["vertices"][0]["clip"][2] != reference["vertices"][0]["clip"][2]:
            raise ValueError("tile depths differ")
        if draw["vertices"][0]["color"] != reference["vertices"][0]["color"]:
            raise ValueError("tile neutral tints differ")
        entries.append({"row": position // columns, "column": position % columns, "draw_index": index,
                        "stage_keys": keys, "source_objects": objects, "clip_rect": rect,
                        "source_vertices": draw["vertices"]})

    sizes = {pixels[e["stage_keys"][0]][:2] for e in entries}
    if not paired and len(sizes) != 1:
        raise ValueError("grid primary dimensions must agree")
    rows = len(entries) // columns
    column_widths = [pixels[e["stage_keys"][0]][0] for e in entries[:columns]]
    row_heights = [pixels[entries[r*columns]["stage_keys"][0]][1] for r in range(rows)]
    width, height = sum(column_widths), sum(row_heights)
    if width * height > 16 * 1024 * 1024:
        raise ValueError("assembled grid exceeds its pixel bound")
    for position, entry in enumerate(entries):
        tile_width, tile_height = pixels[entry["stage_keys"][0]][:2]
        if (tile_width, tile_height) != (column_widths[entry["column"]], row_heights[entry["row"]]):
            raise ValueError("grid column widths or row heights disagree")
        left, top, right, bottom = entry["clip_rect"]
        # The guest rounds each shared edge to a source viewport pixel. Allow
        # one-pixel differences in cell size, never gaps/overlaps at the joins.
        if entry["column"]:
            previous = entries[position-1]["clip_rect"]
            if any(abs(a-b) > 1e-6 for a, b in zip((left, top, bottom), (previous[2], previous[1], previous[3]))):
                raise ValueError("horizontal tiles are not contiguous in row-major order")
        if entry["row"]:
            previous = entries[position-columns]["clip_rect"]
            if any(abs(a-b) > 1e-6 for a, b in zip((left, top, right), (previous[0], previous[3], previous[2]))):
                raise ValueError("vertical tiles are not contiguous in row-major order")
        first = entries[0]["clip_rect"]
        if abs((right-left)-(first[2]-first[0])*tile_width/column_widths[0]) > 2/viewport[2]+1e-6 or \
                abs((top-bottom)-(first[1]-first[3])*tile_height/row_heights[0]) > 2/viewport[3]+1e-6:
            raise ValueError("grid cells differ by more than guest pixel rounding")
        x, y = sum(column_widths[:entry["column"]]), sum(row_heights[:entry["row"]])
        entry["pixel_rect"] = [x, y, x+tile_width, y+tile_height]
    picture = Image.new("RGBA", (width, height))
    coverage = Image.new("RGBA", (width, height), (0, 255, 0, 255)) if paired else None
    for entry in entries:
        tw, th, data = pixels[entry["stage_keys"][0]]
        picture.paste(Image.frombytes("RGBA", (tw, th), data), tuple(entry["pixel_rect"][:2]))
        if coverage is not None and len(entry["stage_keys"]) == 2:
            coverage.paste(Image.frombytes("RGBA", (tw, th), pixels[entry["stage_keys"][1]][2]),
                           tuple(entry["pixel_rect"][:2]))
    receipt = {"schema": "protector-native.interface-source-grid/v2" if paired else "protector-native.interface-source-grid/v1", "audit": str(audit_path),
        "audit_sha256": sha(audit_bytes), "trace": str(trace_path), "trace_sha256": sha(trace_bytes),
        "source_manifest": str(manifest_path), "source_manifest_sha256": sha(manifest_bytes),
        "title_dol_sha256": DOL_SHA256, "frame_index": audit["frame_index"], "columns": columns, "rows": rows,
        "tile_dimensions": None if paired else [tile_width, tile_height],
        "column_widths": column_widths, "row_heights": row_heights,
        "dimensions": [width, height], "tiles": entries,
        "viewport": viewport, "projection_words": projection,
        "guest_vertex_color": reference["vertices"][0]["color"],
        "tint_policy": "guest neutral tint recorded but not baked into source pixels",
        "rgba8_sha256": sha(picture.tobytes()),
        "png": "source-grid.png", "method": "byte-exact row-major assembly; no resampling or restoration",
        "scope": "source pixels and live geometry only; not replacement or layout acceptance"}
    if isolated_quad:
        receipt["audit_coverage"] = {"mode": "one-complete-source-quad",
            "total_draws": audit["total_draws"], "included_draws": len(draws),
            "omitted_orthographic_draws": audit["omitted_orthographic_draws"],
            "omitted_vertices": audit["omitted_vertices"],
            "scope": "selected quad is complete; no whole-frame coverage or inter-tile adjacency claim"}
    if audit_path.read_bytes() != audit_bytes or trace_path.read_bytes() != trace_bytes or manifest_path.read_bytes() != manifest_bytes:
        raise ValueError("input reports changed during assembly")
    destination.mkdir(parents=True)
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("Origin", receipt["method"])
    metadata.add_text("AuditSHA256", receipt["audit_sha256"])
    metadata.add_text("impeccable:prompt", "Source origin: byte-exact decoded original planes; audit " + receipt["audit_sha256"])
    picture.save(destination / receipt["png"], pnginfo=metadata)
    receipt["png_sha256"] = sha((destination / receipt["png"]).read_bytes())
    if coverage is not None:
        coverage.save(destination / "coverage-grid.png", pnginfo=metadata)
        receipt["coverage"] = {"png": "coverage-grid.png", "png_sha256": sha((destination / "coverage-grid.png").read_bytes()),
            "rgba8_sha256": sha(coverage.tobytes()),
            "policy": "exact auxiliary RGBA bytes; missing auxiliary uses full green internally, never adds a runtime plane"}
    (destination / "grid.json").write_text(json.dumps(receipt, indent=2)+"\n")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--columns", type=int, required=True)
    parser.add_argument("--draws", type=int, nargs="+", required=True, help="Explicit row-major draw indices")
    parser.add_argument("--paired", action="store_true", help="Use V2 plane-qualified sources and preserve variable tiles/coverage")
    parser.add_argument("--isolated-quad", action="store_true", help="One complete paired source quad from a mixed scene/UI audit; no frame coverage claim")
    args = parser.parse_args()
    receipt = assemble(args.audit, args.trace, args.output, args.draws, args.columns,
        paired=args.paired, isolated_quad=args.isolated_quad)
    print(json.dumps({k: receipt[k] for k in ("dimensions", "rgba8_sha256", "frame_index", "scope")}))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Replay explicit texture operations from a personal original, without cloud calls.

The current contract also lists unresolved authored treatments. A subset run
does not create a complete runtime pack and never changes those treatments.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from protector_native.executable_truth import RBNEG9_DOL_SHA256
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_geometry import identity
from tools.personal_texture_variants import admit as admit_variant, compare_images

RECIPES = ROOT / "reference/personal_texture_recipes.json"
NEURAL = {"local-rgb-neutral", "local-neutral"}
SUPPORTED = {"source-constant", "sampler-bicubic-rgb", "source-monotone-radial-rgb", "source-positive-periodic"} | NEURAL
ALGORITHMS = ["tools/personal_textures.py", "tools/dat_window_batches.py", "tools/restore_texture_objects.py",
    "tools/restore_texture_batch.py", "tools/finish_texture_neutral.py", "tools/prepare_texture_restoration.py",
    "tools/audit_bigb.py", "tools/personal_texture_corrections.py", "tools/personal_source_patterns.py",
    "protector_native/textures.py", "protector_native/bigb.py", "requirements-personal.lock",
    "tools/personal_texture_variants.py", "reference/personal_texture_variants.json",
    "tools/personal_thumbnail_variants.py", "reference/personal_thumbnail_variants.json"]


def load_contract(path=RECIPES):
    contract = json.loads(path.read_text())
    files = contract.get("entry_files")
    if not isinstance(files, list) or not 1 <= len(files) <= 16 or "entries" in contract:
        raise BuildError("A bounded texture recipe index is required")
    entries, names = [], set()
    for record in files:
        name = record["path"]
        if not re.fullmatch(r"personal_texture_recipes-[0-9]{2}\.json", name) or name in names:
            raise BuildError("Unsafe or repeated recipe shard")
        names.add(name)
        source = path.parent / name
        if source.is_symlink() or source.stat().st_size > 2 * 1024**2 or digest_file(source) != record["sha256"]:
            raise BuildError("Recipe shard identity or size differs")
        rows = json.loads(source.read_text())
        if not isinstance(rows, list) or len(rows) != record["entries"] or not 1 <= len(rows) <= 512:
            raise BuildError("Recipe shard coverage differs")
        entries.extend(rows)
    return dict(contract, entries=entries)


def validate_contract(contract):
    if contract.get("schema") != "protector-native.personal-texture-recipes/v1" or \
            contract.get("title_dol_sha256") != RBNEG9_DOL_SHA256 or \
            contract.get("entry_count") != 2221 or len(contract.get("entries", [])) != 2221:
        raise BuildError("The complete selected texture contract is required")
    keys = set()
    for entry in contract["entries"]:
        source, occurrence, op = entry["source"], entry["occurrence"], entry["operation"]
        key = f"{source['width']}x{source['height']}-{source['rgba8_sha256']}"
        if entry["id"] != key or key in keys or not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*-[0-9a-f]{64}", key):
            raise BuildError("Repeated or invalid source texture identity")
        keys.add(key)
        if not re.fullmatch(r"[0-9_]+\.gc[ms]", occurrence["package"]) or \
                not re.fullmatch(r"0x[0-9a-f]{8}", occurrence["resource_offset"]):
            raise BuildError("Unsafe texture source selector")
        if len(entry["dimensions"]) != 2 or any(type(n) is not int or not 1 <= n <= 4096 for n in entry["dimensions"]):
            raise BuildError("Invalid bounded output dimensions")
        if len(entry["wrap_t_s"]) != 2 or any(s not in ("repeat", "mirror", "clamp") for s in entry["wrap_t_s"]):
            raise BuildError("Missing explicit source sampler")
        if op["kind"] not in SUPPORTED | {"authored-treatment-pending"}:
            raise BuildError("Unknown texture operation; no fallback is allowed")
        if op["kind"] in SUPPORTED:
            if type(op["scale"]) is not int or not 1 <= op["scale"] <= 64 or \
                    [source['width'] * op['scale'], source['height'] * op['scale']] != entry['dimensions'] or \
                    not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("reference_rgba8_sha256"))):
                raise BuildError("Texture scale/reference identity differs")
            if op.get('input_precision', 'float32') not in ('float32', 'float64') or \
                    op.get('input_precision') == 'float64' and op['kind'] != 'sampler-bicubic-rgb':
                raise BuildError('Input precision is unsupported for this operation')
        if op["kind"] == "local-rgb-neutral":
            if type(op["finishing_passes"]) is not int or not 0 <= op["finishing_passes"] <= 5 or \
                    op["scale"] != 4 * 2**op["finishing_passes"] or type(op["quantize_after_first"]) is not bool or \
                    op["model_sha256"] not in contract["models"] or \
                    op["finishing_passes"] and op["finisher_sha256"] not in contract["models"]:
                raise BuildError("Missing or inconsistent learned processing settings")
        elif op["kind"] == "local-neutral":
            if type(op["finishing_passes"]) is not int or not 1 <= op["finishing_passes"] <= 6 or \
                    op["scale"] != 2**op["finishing_passes"] or op["finisher_sha256"] not in contract["models"]:
                raise BuildError("Missing or inconsistent neutral processing settings")
        steps = op.get('postprocess', [])
        if op['kind'] == 'source-positive-periodic':
            from tools.personal_source_patterns import validate_periodic
            validate_periodic(op['parameters'], source['width'], source['height'])
            if entry['wrap_t_s'] != ['repeat', 'repeat']:
                raise BuildError('Periodic source sampler differs')
        if not isinstance(steps, list) or len(steps) > 1:
            raise BuildError('Unbounded texture postprocessing')
        for step in steps:
            if step['kind'] == 'source-colour-face':
                from tools.personal_source_patterns import validate_face
                validate_face(step['parameters'])
                if op['kind'] != 'local-neutral' or [source['width'], source['height'], op['scale']] != [64, 64, 8]:
                    raise BuildError('Source face requires its reviewed neutral parent')
                continue
            if step['kind'] == 'source-island-endpoints':
                if op['kind'] != 'local-neutral' or [source['width'], source['height'], op['scale']] != [32, 32, 16] or \
                        step['initial_repair'] != {'mode': 'bilinear', 'regions': [{'rectangle': [14, 11.5, 20, 32]}],
                            'exclude': [], 'inward_feather_source_pixels': .5} or entry['wrap_t_s'] != ['repeat', 'repeat']:
                    raise BuildError('Unknown original island endpoint correction')
                continue
            if step['kind'] == 'localized-source-repair':
                from tools.personal_texture_corrections import validate_repair
                if op['kind'] not in NEURAL:
                    raise BuildError('Localized repair requires its recorded neural base')
                validate_repair(step['repair'], source['width'], source['height'])
                continue
            if step['kind'] != 'source-bicubic-lettering':
                raise BuildError('Unknown source postprocess')
            core = step['source_core']
            if op['kind'] != 'local-rgb-neutral' or step['kind'] != 'source-bicubic-lettering' or \
                    len(core) != 4 or any(type(v) is not int for v in core) or \
                    not 0 <= core[0] < core[2] <= source['width'] or \
                    not 0 <= core[1] < core[3] <= source['height'] or \
                    type(step['source_feather']) is not int or not 1 <= step['source_feather'] <= 16:
                raise BuildError('Invalid source-registered lettering correction')
    for entry in contract["entries"]:
        if any(k not in keys for k in entry["required_companion_sources"]):
            raise BuildError("Selected companion texture is missing")


def source_pixels(entry, package, commands):
    from protector_native.textures import decode_wii_texture_rgba
    from tools.prepare_texture_restoration import source_planes
    expected, occurrence = entry["source"], entry["occurrence"]
    if package.package_sha256 != occurrence["package_sha256"]:
        raise BuildError("Original texture package identity differs")
    offset = int(occurrence["resource_offset"], 16)
    if offset not in {c.destination_offset for c in commands if c.name == "texture"}:
        raise BuildError("Original selection is not a typed texture")
    matches = []
    for plane, texture in source_planes(package.file_info, offset, True):
        if "plane" in occurrence and plane != occurrence["plane"]:
            continue
        if [texture.width, texture.height] != [expected["width"], expected["height"]]:
            continue
        pixels = decode_wii_texture_rgba(package.file_info, texture)
        if hashlib.sha256(pixels).hexdigest() == expected["rgba8_sha256"]:
            if texture.format_code != occurrence["format_code"] or \
                    texture.levels[0].sha256 != occurrence["encoded_level_sha256"] or \
                    [texture.wrap_t, texture.wrap_s] != entry["wrap_t_s"]:
                raise BuildError("Original plane encoding/sampler identity differs")
            matches.append(pixels)
    if not matches or any(p != matches[0] for p in matches):
        raise BuildError("Selected source pixels are missing or ambiguous")
    return matches[0]


def render(entry, rgba, engines=None):
    import numpy as np
    from PIL import Image
    from tools.restore_texture_objects import resample_auxiliary
    from tools.restore_texture_batch import checked_pixels
    source = entry["source"]
    pixels = np.frombuffer(rgba, np.uint8).reshape(source["height"], source["width"], 4)
    if np.any(pixels[:, :, 3] != 255):
        raise BuildError("This texture operation cannot discard source alpha")
    op, wraps = entry["operation"], entry["wrap_t_s"]
    rgb = pixels[:, :, :3].astype(np.float64 if op.get('input_precision') == 'float64' else np.float32) / 255
    if op["kind"] == "source-constant":
        if not np.all(pixels == pixels[0, 0]):
            raise BuildError("Source-constant operation requires exactly constant original pixels")
        picture = Image.new("RGB", tuple(entry["dimensions"]), tuple(map(int, pixels[0, 0, :3])))
    elif op["kind"] == "sampler-bicubic-rgb":
        picture = resample_auxiliary(rgb, op["scale"], wraps)
    elif op['kind'] == 'source-monotone-radial-rgb':
        from tools.personal_texture_corrections import radial_glow
        picture = radial_glow(Image.fromarray(pixels[:, :, :3]), op['scale'])
    elif op['kind'] == 'source-positive-periodic':
        from tools.personal_source_patterns import periodic_field
        picture = periodic_field(Image.fromarray(pixels[:, :, :3]), op['scale'], op['parameters'])
    elif op["kind"] in NEURAL:
        if engines is None:
            raise BuildError("Verified local model weights are required")
        output = rgb
        if op["kind"] == "local-rgb-neutral":
            output = checked_pixels(engines.first(op["model_sha256"], rgb, wraps), rgb.shape[1]*4, rgb.shape[0]*4)
            if op["quantize_after_first"]:
                output = np.rint(output * 255).astype(np.uint8).astype(np.float32) / 255
        for _ in range(op["finishing_passes"]):
            output = checked_pixels(engines.finish(output, wraps), output.shape[1]*2, output.shape[0]*2)
        picture = Image.fromarray(np.rint(output * 255).astype(np.uint8))
    else:
        raise BuildError("Authored treatment has no portable implementation; no substitute is permitted")
    for step in op.get('postprocess', []):
        original = Image.fromarray(pixels[:, :, :3])
        if step['kind'] == 'localized-source-repair':
            from tools.personal_texture_corrections import localized_repair
            picture = localized_repair(original, picture, op['scale'], wraps, step['repair'])
        elif step['kind'] == 'source-colour-face':
            from tools.personal_source_patterns import source_face
            picture = source_face(original, picture, step['parameters'])
        elif step['kind'] == 'source-island-endpoints':
            from tools.personal_source_patterns import island_endpoints
            picture = island_endpoints(original, picture, step['initial_repair'])
        elif step['kind'] == 'source-bicubic-lettering':
            picture = source_lettering(original, picture, op['scale'], step['source_core'], step['source_feather'])
        else:
            raise BuildError('Unknown postprocess; no fallback is allowed')
    if list(picture.size) != entry["dimensions"]:
        raise BuildError("Replayed texture dimensions differ")
    return picture


def source_lettering(source, prior, scale, core, feather):
    """Preserve original ambiguous glyphs, including the original quantization."""
    import numpy as np
    from PIL import Image
    if prior.size != (source.width * scale, source.height * scale):
        raise BuildError('Lettering correction scale differs')
    x, y = (np.arange(prior.width) + .5) / scale, (np.arange(prior.height) + .5) / scale
    dx, dy = np.minimum(x - core[0], core[2] - x), np.minimum(y - core[1], core[3] - y)
    distance = np.minimum(dy[:, None], dx[None, :])
    alpha = np.clip((distance + feather) / feather, 0, 1)
    alpha = (.5 - .5 * np.cos(np.pi * alpha)).astype(np.float32)
    a = np.asarray(source.convert('RGB').resize(prior.size, Image.Resampling.BICUBIC))
    b = np.asarray(prior.convert('RGB'))
    merged = np.rint(a.astype(np.float32) * alpha[:, :, None] +
        b.astype(np.float32) * (1 - alpha[:, :, None])).astype(np.uint8)
    if not np.array_equal(merged[alpha == 0], b[alpha == 0]) or not np.array_equal(merged[alpha == 1], a[alpha == 1]):
        raise BuildError('Lettering correction changed protected source/core pixels')
    return Image.fromarray(merged)


def compare_reference(entry, picture, references):
    """Private QA only: distinguish <=1 UNORM rounding from a changed treatment."""
    from PIL import Image
    record = references.get(entry['id'])
    if record is None:
        raise BuildError("No private raw reference for numerical comparison")
    path = Path(record['path'])
    if digest_file(path) != record['png_sha256']:
        raise BuildError("Private reference PNG changed")
    with Image.open(path) as im:
        if list(im.size) != entry['dimensions']:
            raise BuildError('Private reference dimensions differ')
        result, expected, _ = compare_images(im, picture)
    if expected != entry['reference_rgba8_sha256']:
        raise BuildError('Private reference does not match the selected original pixels')
    return {**result, 'reference_png_sha256': record['png_sha256'],
        'admission': 'private-reference-comparison', 'comparison_this_run': True}


def configure_torch(torch, mps_memory_fraction, device='mps'):
    if device not in ('mps', 'cpu'):
        raise BuildError('First-pass device must be mps or cpu')
    if type(mps_memory_fraction) not in (int, float) or not 0 < mps_memory_fraction <= 0.5:
        raise BuildError('MPS memory fraction must be greater than zero and at most 0.5')
    torch.set_num_threads(4)
    if device == 'mps':
        torch.mps.set_per_process_memory_fraction(float(mps_memory_fraction))


def replay(game, work, model_dir, kinds, entry_id, provider, numerical_reference=None, mps_memory_fraction=0.5,
           dat_window_batch_size=0, device='mps', cpu_conv_output_rows=0):
    if type(dat_window_batch_size) is not int or not 0 <= dat_window_batch_size <= 128:
        raise BuildError('DAT window batch size must be 0 through 128; zero retains original execution')
    if type(cpu_conv_output_rows) is not int or not 0 <= cpu_conv_output_rows <= 256 or \
            (cpu_conv_output_rows and device != 'cpu'):
        raise BuildError('CPU convolution rows must be 0 through 256 and require --device cpu')
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    from tools.restore_texture_batch import LocalModels
    game, work = outside_repo(game), outside_repo(work)
    if work == game or work.is_relative_to(game) or game.is_relative_to(work):
        raise BuildError("Texture workspace must be separate from original inputs")
    contract = load_contract()
    validate_contract(contract)
    if contract["source_lock_sha256"] != digest_file(LOCK):
        raise BuildError("Original-content contract changed")
    lock = json.loads(LOCK.read_text())
    check_table(game, lock["game"])
    requested_ids = {entry_id} if isinstance(entry_id, str) else set(entry_id or [])
    selected = [e for e in contract["entries"] if (not kinds or e["operation"]["kind"] in kinds)
        and (not requested_ids or e["id"] in requested_ids)]
    if requested_ids and {e['id'] for e in selected} != requested_ids:
        raise BuildError('An explicitly requested source is missing or excluded by the operation filter')
    if not selected or any(e["operation"]["kind"] not in SUPPORTED for e in selected):
        raise BuildError("Selection is empty or includes unresolved authored treatments; select an implemented operation explicitly")
    selected.sort(key=lambda e: (e["occurrence"]["package"], e["id"]))
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError("Texture replay needs an existing parent with 5 GiB headroom")
    config = {"models": {}}
    learned = [e for e in selected if e["operation"]["kind"] in NEURAL]
    model_root = None
    if learned:
        if model_dir is None:
            raise BuildError("Supply the local model directory; no download or licence acceptance is automatic")
        model_root = outside_repo(model_dir)
        if model_root == work or model_root.is_relative_to(work) or work.is_relative_to(model_root):
            raise BuildError("Model inputs and outputs must be separate")
        required = {e["operation"]["model_sha256"] for e in learned if e["operation"]["kind"] == "local-rgb-neutral"} | \
            {e["operation"]["finisher_sha256"] for e in learned if e["operation"]["finishing_passes"]}
        for sha in required:
            record = contract["models"][sha]
            name = record["filename"]
            if Path(name).name != name:
                raise BuildError("Unsafe model filename")
            path = model_root / name
            if path.is_symlink() or digest_file(path) != sha:
                raise BuildError("Local model identity differs")
            model = {"weights": str(path), "sha256": sha}
            if any(e["operation"].get("finisher_sha256") == sha for e in learned):
                if "finisher" in config:
                    raise BuildError("Multiple finishers require separate engines")
                config["finisher"] = model
            else:
                config["models"][sha] = model
        import torch
        configure_torch(torch, mps_memory_fraction, device)
    execution = {"schema": "protector-native.personal-texture-execution/v1", "game": str(game),
        "contract_sha256": digest_file(RECIPES), "provider": provider,
        "mps_memory_fraction": mps_memory_fraction if device == 'mps' else None,
        "dat_window_batch_size": dat_window_batch_size,
        "cpu_conv_output_rows": cpu_conv_output_rows,
        "first_pass_device": device,
        "mps_low_watermark_ratio_environment": os.environ.get('PYTORCH_MPS_LOW_WATERMARK_RATIO'),
        "algorithms": {p: digest_file(ROOT / p) for p in ALGORITHMS}, "models": config}
    references = {}
    if numerical_reference:
        reference_path = outside_repo(numerical_reference)
        reference_index = json.loads(reference_path.read_text())
        if reference_index.get('schema') != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private reference index')
        references = reference_index['entries']
        execution['private_reference_index_sha256'] = digest_file(reference_path)
    owner = {"schema": "protector-native.personal-texture-work/v2", "game": str(game),
        "source_lock_sha256": digest_file(LOCK), "creation_execution": execution}
    if work.exists():
        previous = json.loads((work / "owner.json").read_text())
        if work.is_symlink() or previous.get("schema") not in ("protector-native.personal-texture-work/v1", owner["schema"]) or \
                previous.get("game") != str(game) or previous.get("source_lock_sha256", digest_file(LOCK)) != digest_file(LOCK):
            raise BuildError("Texture workspace belongs to different original inputs")
        # Safe across recipe/tool revisions only because every reused PNG is
        # rehashed against the current reviewed raw pixels, and its original
        # typed source is decoded again. Record this run's actual tools below.
    else:
        work.mkdir(mode=0o700)
        write_json(work / "owner.json", owner)
    outputs = work / "candidates"
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError("Candidate directory is a link")
    @lru_cache(maxsize=2)
    def get_package(name):
        package = decode_package(game / "files" / name)
        commands = parse_relocation_commands(package.relocation, "big", file_info_size=len(package.file_info))
        return package, commands
    engines = {}
    def engine_for(backend):
        if backend not in engines:
            engines[backend] = LocalModels(config, model_root, device, backend, dat_window_batch_size,
                                          cpu_conv_output_rows)
        return engines[backend]
    started, results = time.monotonic(), []
    for index, entry in enumerate(selected):
        backend_used = None
        numerical = None
        op = entry["operation"]
        target = outputs / (entry["id"] + ".png")
        if target.is_symlink():
            raise BuildError("Candidate output is a link")
        # Sources are always re-decoded, even when a candidate is reusable.
        rgba = source_pixels(entry, *get_package(entry["occurrence"]["package"]))
        if target.exists():
            with Image.open(target) as saved:
                if list(saved.size) != entry["dimensions"] or saved.format != "PNG":
                    raise BuildError("Cached texture dimensions/format differ")
                actual = hashlib.sha256(saved.convert("RGBA").tobytes()).hexdigest()
                numerical = admit_variant(entry, actual)
                if numerical is None and actual != entry['reference_rgba8_sha256'] and references and op['kind'] in NEURAL:
                    numerical = compare_reference(entry, saved, references)
        else:
            if shutil.disk_usage(work).free < 5 * 1024**3:
                raise BuildError("5 GiB storage reserve reached; completed candidates retained")
            if op["kind"] in NEURAL:
                # Historical receipts used both ONNX backends. They differ in
                # rounding. Auto mode tries only the same pinned model/operation
                # with those two backends. Public admission permits exact
                # selected hashes or individually qualified variant hashes.
                # Unknown outputs still need private numerical comparison.
                backends = [provider] if provider != "auto" else \
                    (["coreml", "cpu"] if references or op.get("quantize_after_first", False) else ["cpu", "coreml"])
                for backend in backends:
                    picture = render(entry, rgba, engine_for(backend))
                    actual = hashlib.sha256(picture.convert("RGBA").tobytes()).hexdigest()
                    backend_used = backend
                    if actual == entry["reference_rgba8_sha256"]:
                        break
                    numerical = admit_variant(entry, actual)
                    if numerical is not None:
                        break
                    if references:
                        numerical = compare_reference(entry, picture, references)
                        if numerical['max_channel_error'] <= 1:
                            break
                        print(f"Backend {backend} exceeded the reviewed rounding bound for {entry['id']}: "
                            f"max={numerical['max_channel_error']}, mean={numerical['mean_channel_error']:.8f}", flush=True)
            else:
                picture = render(entry, rgba)
                actual = hashlib.sha256(picture.convert("RGBA").tobytes()).hexdigest()
            if actual == entry["reference_rgba8_sha256"] or numerical is not None and numerical['max_channel_error'] <= 1:
                with target.open("xb") as stream:
                    picture.save(stream, format="PNG")
        if actual != entry["reference_rgba8_sha256"] and (numerical is None or numerical['max_channel_error'] > 1):
            raise BuildError(f"Replayed texture pixels differ from selected reference: {entry['id']} ({actual})")
        results.append({"id": entry["id"], "rgba8_sha256": actual, "png_sha256": digest_file(target),
            "provider_this_run": backend_used, "reference_pixels_exact": actual == entry['reference_rgba8_sha256'],
            "numerical_comparison": numerical})
        if index % 16 == 0 or index == len(selected)-1:
            print(f"Texture replay verified: {index+1}/{len(selected)}", flush=True)
    if any(digest_file(ROOT / p) != sha for p, sha in execution['algorithms'].items()):
        raise BuildError('Replay tools changed during execution; completed candidates retained for revalidation')
    rounded = sum(not r['reference_pixels_exact'] for r in results)
    result = {"schema": "protector-native.personal-texture-result/v1",
        "status": "numerically-verified-selected-subset" if rounded else "exact-selected-subset",
        "exact_pixel_matches": len(results)-rounded, "bounded_rounding_matches": rounded,
        "selected": len(selected), "complete_pack": len(selected) == contract["entry_count"],
        "seconds": time.monotonic()-started, "owner_sha256": digest_file(work / "owner.json"),
        "execution": execution,
        "runtime": {k: v.metadata for k, v in engines.items()} if engines else
            {"method": "source reconstruction or exact cached pixels; no model loaded"}, "entries": results}
    write_json(work / "receipt.json", result)
    return {k: v for k, v in result.items() if k not in ("entries", "runtime", "execution")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--kind", choices=sorted(SUPPORTED), action="append")
    parser.add_argument("--entry", action="append", help="Repeat to select a bounded worker's exact source identities")
    parser.add_argument("--provider", choices=("auto", "cpu", "coreml"), default="auto")
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps",
        help="First-pass Torch device; separate from the ONNX finisher provider")
    parser.add_argument("--mps-memory-fraction", type=float, default=0.5,
        help="Torch MPS allocation fraction of recommended device memory; greater than zero, at most 0.5")
    parser.add_argument("--dat-window-batch-size", type=int, default=0,
        help="Opt-in DAT spatial-window batching; 1-128, or 0 for the original execution")
    parser.add_argument("--cpu-conv-output-rows", type=int, default=0,
        help="Opt-in CPU DAT/ESRGAN convolution workspace bound; 1-256 output rows, default off")
    parser.add_argument("--numerical-reference", type=Path,
        help="Optional private developer index; allows at most 1/255 channel rounding in pinned neural output only")
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args.game, args.work_dir, args.model_dir, args.kind, args.entry, args.provider,
            args.numerical_reference, args.mps_memory_fraction, args.dat_window_batch_size, args.device,
            args.cpu_conv_output_rows), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f"Texture replay: {error}\n")


if __name__ == "__main__":
    main()

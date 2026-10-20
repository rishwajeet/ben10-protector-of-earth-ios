#!/usr/bin/env python3
"""Reconstruct three painted signs with explicit fresh/reference-parent modes.

Reference-parent mode proves only the bounded compositor. It never loads a model
or claims fresh neural reconstruction. Private authored vectors stay external.
"""
import argparse
import copy
import hashlib
from importlib.metadata import version
from io import BytesIO
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, outside_repo, write_json
from tools.personal_textures import load_contract, validate_contract, render as render_neural, ALGORITHMS
from tools.personal_structural_plates import replay as replay_plates
from tools.build_interface_vectors import read_vector

CONTRACT = ROOT / 'reference/personal_sign_recipes.json'
SCHEMA = 'protector-native.personal-signs/v1'
METHOD = 'painted restoration plus source-word selective hand-authored vector lettering'


def rgba_hash(picture):
    return hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()


def validate_recipe(recipe, width, height):
    fields = {'schema', 'id', 'base_operation', 'base_reference_rgba8_sha256', 'vector_sha256', 'lines', 'retain'}
    if set(recipe) != fields or recipe['schema'] != 'protector-native.private-sign/v1' or \
            (width, height) not in ((128, 128), (128, 64)) or not 1 <= len(recipe['lines']) <= 6 or len(recipe['retain']) > 8:
        raise BuildError('Invalid selected sign recipe')
    for value in (recipe['base_reference_rgba8_sha256'], recipe['vector_sha256']):
        if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise BuildError('Invalid painted-sign input identity')
    def box(value):
        if len(value) != 4 or any(type(v) is not int for v in value) or not \
                (0 <= value[0] < value[2] <= width and 0 <= value[1] < value[3] <= height):
            raise BuildError('Sign correction leaves the source canvas')
    for line in recipe['lines']:
        if set(line) != {'box', 'mode'} or line['mode'] not in ('red', 'light', 'dark'):
            raise BuildError('Unsupported sign ink detector')
        box(line['box'])
    for value in recipe['retain']:
        box(value)
    op = recipe['base_operation']
    if set(op) != {'kind', 'scale', 'model_sha256', 'finisher_sha256', 'finishing_passes', 'quantize_after_first'} or \
            op['kind'] != 'local-rgb-neutral' or op['scale'] != 16 or op['finishing_passes'] != 2 or op['quantize_after_first'] is not False:
        raise BuildError('Unknown painted-sign neural parent operation')


def remove_ink(picture, line, scale):
    import numpy as np
    from PIL import Image
    from scipy.ndimage import binary_dilation, distance_transform_edt, convolve
    box = tuple(v * scale for v in line['box'])
    a = np.asarray(picture.crop(box)).astype(np.float32)
    luma = a.mean(axis=2)
    if line['mode'] == 'red':
        mask = (a[:, :, 0] - np.maximum(a[:, :, 1], a[:, :, 2])) > 32
    elif line['mode'] == 'light':
        mask = luma > 149
    elif line['mode'] == 'dark':
        mask = (luma < 112) | (luma > 191)
    else:
        raise BuildError('Unknown sign ink detector')
    if not mask.any():
        raise BuildError('No old ink in the selected sign region')
    mask = binary_dilation(mask, iterations=max(1, round(scale * .65)))
    mask[[0, -1], :] = False
    mask[:, [0, -1]] = False
    nearest = distance_transform_edt(mask, return_distances=False, return_indices=True)
    work = a.copy()
    work[mask] = a[nearest[0][mask], nearest[1][mask]]
    kernel = np.array([[0, .25, 0], [.25, 0, .25], [0, .25, 0]], dtype=np.float32)
    for _ in range(160):
        for channel in range(3):
            averaged = convolve(work[:, :, channel], kernel, mode='nearest')
            work[:, :, channel][mask] = averaged[mask]
    result = picture.copy()
    result.paste(Image.fromarray(np.rint(np.clip(work, 0, 255)).astype(np.uint8)), box[:2])
    return result, int(mask.sum())


def compose(original, parent, recipe, vector):
    import numpy as np
    import resvg_py
    from PIL import Image
    validate_recipe(recipe, original.width, original.height)
    if resvg_py.__version__ != '0.5.0' or resvg_py.__resvg_version__ != '0.48.1':
        raise BuildError('Use the qualified resvg-py 0.5.0 / resvg 0.48.1 rasterizer')
    scale = 16
    if parent.size != (original.width * scale, original.height * scale) or parent.convert('RGBA').getextrema()[3] != (255, 255):
        raise BuildError('Painted sign parent dimensions or alpha changed')
    before = np.asarray(parent.convert('RGB')).copy()
    picture = parent.convert('RGB')
    touched = np.zeros((parent.height, parent.width), dtype=bool)
    for line in recipe['lines']:
        picture, _ = remove_ink(picture, line, scale)
        x0, y0, x1, y1 = line['box']
        touched[y0*scale:y1*scale, x0*scale:x1*scale] = True
    raw = resvg_py.svg_to_bytes(svg_string=vector.decode('utf-8'), width=parent.width,
        height=parent.height, skip_system_fonts=True)
    with Image.open(BytesIO(raw)) as image:
        overlay = image.convert('RGBA')
    if np.any((np.asarray(overlay)[:, :, 3] > 0) & ~touched):
        raise BuildError('Authored sign lettering exceeds the declared correction regions')
    picture = Image.alpha_composite(picture.convert('RGBA'), overlay).convert('RGB')
    for box in recipe['retain']:
        x0, y0, x1, y1 = box
        picture.paste(original.convert('RGB').crop(box).resize(((x1-x0)*scale, (y1-y0)*scale),
            Image.Resampling.BICUBIC), (x0*scale, y0*scale))
        touched[y0*scale:y1*scale, x0*scale:x1*scale] = True
    if not np.array_equal(np.asarray(picture)[~touched], before[~touched]):
        raise BuildError('Sign compositor changed pixels outside its declared regions')
    return picture


def export(manifest, private_inputs):
    from PIL import Image
    from tools.export_personal_texture_recipes import operation
    selected = load_contract()
    if digest_file(manifest) != selected['reference_manifest_sha256']:
        raise BuildError('Use the selected production pack')
    inputs = outside_repo(private_inputs)
    if inputs.exists() or inputs.is_symlink() or not inputs.parent.is_dir():
        raise BuildError('Use a new external private sign directory')
    rows, payloads, vectors, parents = [], {}, {}, {}
    qualified = copy.deepcopy(selected)
    indexed = {e['id']: e for e in qualified['entries']}
    for entry in json.loads(manifest.read_text())['entries']:
        pr = entry['provenance']
        if pr['method'] != METHOD:
            continue
        src = entry['source']
        key = f"{src['width']}x{src['height']}-{src['rgba8_sha256']}"
        parent = Path(pr['base_candidate'])
        if parent.is_symlink() or digest_file(parent) != pr['base_candidate_sha256']:
            raise BuildError('Original painted parent changed')
        with Image.open(parent) as image:
            provenance = json.loads(image.info['protector_origin'])
            parent_sha = rgba_hash(image)
        if provenance['source_key'] != key or pr['source_key'] != key:
            raise BuildError('Sign parent belongs to different original pixels')
        models = {}
        op = operation(dict(entry, provenance=provenance), models)
        if any(sha not in selected['models'] or selected['models'][sha]['filename'] != model['filename'] for sha, model in models.items()):
            raise BuildError('Sign parent introduced an unqualified model')
        vector = Path(pr['vector'])
        if vector.is_symlink() or digest_file(vector) != pr['vector_sha256']:
            raise BuildError('Original sign lettering changed')
        read_vector(vector, src['width'], src['height'])
        spec = pr['specification']
        recipe = {'schema': 'protector-native.private-sign/v1', 'id': key,
            'base_operation': op, 'base_reference_rgba8_sha256': parent_sha,
            'vector_sha256': pr['vector_sha256'], 'lines': [{'box': line['box'], 'mode': line['mode']} for line in spec['lines']],
            'retain': spec['retain']}
        validate_recipe(recipe, src['width'], src['height'])
        indexed[key]['operation'] = op
        indexed[key]['reference_rgba8_sha256'] = parent_sha
        raw = (json.dumps(recipe, indent=2, sort_keys=True) + '\n').encode()
        sha = hashlib.sha256(raw).hexdigest()
        payloads[sha] = raw
        vectors[pr['vector_sha256']] = vector
        rows.append({'id': key, 'recipe_sha256': sha})
        parents[key] = {'path': str(parent), 'png_sha256': pr['base_candidate_sha256'], 'rgba8_sha256': parent_sha}
    validate_contract(qualified)
    if len(rows) != 3 or len({r['id'] for r in rows}) != 3:
        raise BuildError('Expected the three selected painted signs')
    inputs.mkdir(mode=0o700)
    write_json(inputs / 'owner.json', {'schema': 'protector-native.private-sign-inputs/v1',
        'distribution_clearance': False, 'recipes': sorted(payloads), 'vectors': sorted(vectors)})
    write_json(inputs / 'reference-parents.json', {'schema': 'protector-native.private-sign-reference-parents/v1',
        'purpose': 'Developer compositor-only verification; not fresh neural reconstruction', 'entries': parents})
    for sha, raw in payloads.items():
        with (inputs / (sha + '.json')).open('xb') as stream:
            stream.write(raw)
    for sha, path in vectors.items():
        target = inputs / (sha + '.svg')
        shutil.copyfile(path, target)
        if digest_file(target) != sha:
            raise BuildError('Private sign vector copy changed')
    return {'schema': SCHEMA,
        **{k: selected[k] for k in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')},
        'entries': rows, 'scope': 'Recipe identities only; authored SVG/regions stay private; neural parents must be reconstructed locally'}


def replay(game, work, authored, reference_parents=None, model_dir=None, provider='auto'):
    from PIL import Image
    if bool(reference_parents) == bool(model_dir):
        raise BuildError('Select either explicit reference-parent verification or fresh local-model reconstruction')
    for name, expected in {'numpy': '2.4.2', 'Pillow': '12.1.1', 'scipy': '1.17.0'}.items():
        if version(name) != expected:
            raise BuildError('Use the qualified sign requirements')
    authored = outside_repo(authored)
    selected = load_contract()
    entries = {e['id']: e for e in selected['entries']}
    references = {}
    context = {'compositor_only': reference_parents is not None, 'fresh_neural_replay': reference_parents is None,
        'neural_parent': 'retained-reference' if reference_parents else 'fresh-source', 'providers': {}}
    if reference_parents:
        index = outside_repo(reference_parents)
        data = json.loads(index.read_text())
        if data['schema'] != 'protector-native.private-sign-reference-parents/v1':
            raise BuildError('Invalid compositor-only reference index')
        references = data['entries']
        context['private_reference_index_sha256'] = digest_file(index)
    model_root = outside_repo(model_dir) if model_dir else None
    if model_root and (outside_repo(work) == model_root or outside_repo(work).is_relative_to(model_root) or model_root.is_relative_to(outside_repo(work))):
        raise BuildError('Sign output must be separate from model inputs')
    def drawing(original, scale, recipe):
        validate_recipe(recipe, original.width, original.height)
        entry = dict(entries[recipe['id']], operation=recipe['base_operation'], reference_rgba8_sha256=recipe['base_reference_rgba8_sha256'])
        # Reuse the main contract validator for the explicit model operation.
        qualified = dict(selected, entries=[entry if e['id'] == entry['id'] else e for e in selected['entries']])
        validate_contract(qualified)
        if reference_parents:
            ref = references[entry['id']]
            path = outside_repo(Path(ref['path']))
            if path.is_symlink() or digest_file(path) != ref['png_sha256'] or ref['rgba8_sha256'] != recipe['base_reference_rgba8_sha256']:
                raise BuildError('Pinned compositor-only parent changed')
            with Image.open(path) as image:
                if image.format != 'PNG' or image.convert('RGBA').getextrema()[3] != (255, 255):
                    raise BuildError('Invalid compositor-only parent format or alpha')
                parent = image.convert('RGB')
        else:
            import gc
            import torch
            from tools.restore_texture_batch import LocalModels
            torch.set_num_threads(2)
            torch.mps.set_per_process_memory_fraction(0.25)
            config = {'models': {}}
            op = recipe['base_operation']
            for role, sha in [('model', op['model_sha256']), ('finisher', op['finisher_sha256'])]:
                record = selected['models'][sha]
                name = record['filename']
                if Path(name).name != name:
                    raise BuildError('Unsafe local model filename')
                path = model_root / name
                if path.is_symlink() or digest_file(path) != sha:
                    raise BuildError('Local sign model identity differs')
                item = {'weights': str(path), 'sha256': sha}
                if role == 'model':
                    config['models'][sha] = item
                else:
                    config['finisher'] = item
            for backend in (['cpu', 'coreml'] if provider == 'auto' else [provider]):
                engine = LocalModels(config, model_root, 'mps', backend)
                try:
                    parent = render_neural(entry, original.convert('RGBA').tobytes(), engine)
                finally:
                    del engine
                    gc.collect()
                    torch.mps.empty_cache()
                if rgba_hash(parent) == recipe['base_reference_rgba8_sha256']:
                    context['providers'][entry['id']] = backend
                    break
        if rgba_hash(parent) != recipe['base_reference_rgba8_sha256']:
            raise BuildError('Painted sign neural parent differs; no silent rounding or historical fallback')
        path = authored / (recipe['vector_sha256'] + '.svg')
        if path.is_symlink() or digest_file(path) != recipe['vector_sha256']:
            raise BuildError('The exact private sign drawing is required')
        return compose(original, parent, recipe, read_vector(path, original.width, original.height))
    return replay_plates(game, work, authored, contract_path=CONTRACT, contract_schema=SCHEMA,
        entry_count=3, renderer=drawing, extra_algorithms=[*ALGORITHMS, 'tools/personal_signs.py',
            'tools/build_interface_vectors.py', 'requirements-personal-vectors.lock'], family='painted sign',
        receipt_context=context)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    stage = subs.add_parser('export')
    stage.add_argument('--manifest', type=Path, required=True)
    stage.add_argument('--private-inputs', type=Path, required=True)
    stage.add_argument('--output', type=Path, required=True)
    run = subs.add_parser('replay')
    run.add_argument('--game', type=Path, required=True)
    run.add_argument('--work-dir', type=Path, required=True)
    run.add_argument('--authored-inputs', type=Path, required=True)
    mode = run.add_mutually_exclusive_group(required=True)
    mode.add_argument('--reference-parents', type=Path)
    mode.add_argument('--model-dir', type=Path)
    run.add_argument('--provider', choices=('auto', 'cpu', 'coreml'), default='auto')
    args = parser.parse_args()
    try:
        if args.command == 'export':
            if args.output.exists() or args.output.is_symlink():
                raise BuildError('Use a new painted-sign contract path')
            result = export(args.manifest, args.private_inputs)
            write_json(args.output, result)
            print(json.dumps({'selected': len(result['entries']), 'distribution_clearance': False}))
        else:
            print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs,
                args.reference_parents, args.model_dir, args.provider), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Painted sign replay: {error}\n')

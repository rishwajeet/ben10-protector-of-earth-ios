#!/usr/bin/env python3
"""Rebuild selected bounded atlas corrections without historical pixel payloads."""
import argparse
import hashlib
from io import BytesIO
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, outside_repo, write_json
from tools.personal_textures import load_contract
from tools.personal_structural_plates import replay as replay_plates
from tools.personal_atlases import METHOD as BASE_METHOD, check_runtime, render as render_base
from tools.build_interface_vectors import read_vector

CONTRACT = ROOT / 'reference/personal_layered_atlas_recipes.json'
SCHEMA = 'protector-native.personal-layered-atlases/v1'
LOCAL = 'Reviewer-directed bounded local correction, retaining all pixels outside declared edit regions.'
RIBS = 'Intentional source-coordinate strokes and single-fill rib contours; no threshold tracing, enlarged source fragments or global pass.'
STROKES = 'Manually source-registered, constant-width open strokes with longitudinal source-value samples; no filled ribbons, blade ends, source enlargement, blur or transverse sheen.'


def rgba_hash(picture):
    return hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()


def validate_recipe(recipe, size):
    if recipe.get('schema') != 'protector-native.private-layered-atlas/v1' or \
            not 1 <= len(recipe.get('steps', [])) <= 3 or size not in (64, 128):
        raise BuildError('Invalid bounded atlas recipe')
    def sha(value):
        if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise BuildError('Invalid intermediate or drawing identity')
    def box(value):
        if len(value) != 4 or any(type(v) is not int for v in value) or not \
                (0 <= value[0] < value[2] <= size and 0 <= value[1] < value[3] <= size):
            raise BuildError('Local correction leaves the source canvas')
    if set(recipe) != {'schema', 'id', 'base', 'steps'} or set(recipe['base']) != {'vector_sha256', 'reference_rgba8_sha256'}:
        raise BuildError('Layered atlas contains unsupported data')
    for value in recipe['base'].values():
        sha(value)
    for step in recipe['steps']:
        sha(step['reference_rgba8_sha256'])
        if not 1 <= len(step['allowed_boxes']) <= 32:
            raise BuildError('Local correction requires bounded edit regions')
        for value in step['allowed_boxes']:
            box(value)
        if step['kind'] == 'local-source':
            if set(step) != {'kind', 'allowed_boxes', 'operations', 'reference_rgba8_sha256'} or not 1 <= len(step['operations']) <= 32:
                raise BuildError('Unsupported local-source step')
            for op in step['operations']:
                fields = {'kind', 'box'} | ({'sample_box'} if op['kind'] == 'rectangle' else set())
                if op['kind'] not in ('source-field', 'rectangle', 'ambiguous-footprint') or set(op) != fields:
                    raise BuildError('Only original-sampled local operations are permitted')
                box(op['box'])
                if op['kind'] == 'rectangle':
                    box(op['sample_box'])
        elif step['kind'] == 'overlay':
            if set(step) != {'kind', 'allowed_boxes', 'restore_base_boxes', 'vector_sha256', 'reference_rgba8_sha256'}:
                raise BuildError('Unsupported private overlay step')
            sha(step['vector_sha256'])
            if len(step['restore_base_boxes']) > 32:
                raise BuildError('Too many quiet-field restoration regions')
            for value in step['restore_base_boxes']:
                box(value)
        else:
            raise BuildError('Unknown layered atlas step')


def monotone_source(original, size):
    import numpy as np
    from scipy.interpolate import PchipInterpolator
    a = np.asarray(original.convert('RGB'), dtype=float)
    h, w = a.shape[:2]
    x = np.clip((np.arange(size) + .5) * w / size, .5, w - .5)
    y = np.clip((np.arange(size) + .5) * h / size, .5, h - .5)
    along_x = PchipInterpolator(np.arange(w) + .5, a, axis=1)(x)
    result = PchipInterpolator(np.arange(h) + .5, along_x, axis=0)(y)
    if result.min() < a.min() - 1e-7 or result.max() > a.max() + 1e-7:
        raise BuildError('Monotone reconstruction overshot original values')
    return result


def apply_step(original, prior, base, step, vector=None):
    import numpy as np
    from PIL import Image
    size, scale = prior.width, prior.width / original.width
    before = np.asarray(prior.convert('RGB'))
    result = before.copy()
    allowed = np.zeros(before.shape[:2], dtype=bool)
    def region(box):
        x0, y0, x1, y1 = [round(v * scale) for v in box]
        return np.s_[y0:y1, x0:x1]
    for box in step['allowed_boxes']:
        allowed[region(box)] = True
    if step['kind'] == 'local-source':
        source = np.asarray(original.convert('RGB'), dtype=float)
        reconstructed = monotone_source(original, size)
        for op in step['operations']:
            target = region(op['box'])
            if op['kind'] == 'source-field':
                result[target] = np.rint(reconstructed[target]).astype(np.uint8)
            elif op['kind'] == 'rectangle':
                x0, y0, x1, y1 = op['sample_box']
                color = np.rint(np.median(source[y0:y1, x0:x1].reshape(-1, 3), axis=0)).astype(int)
                result[target] = color
            else:
                x0, y0, x1, y1 = op['box']
                crop = source[y0:y1, x0:x1]
                border = np.concatenate([crop[0], crop[-1], crop[:, 0], crop[:, -1]])
                field = np.median(border, axis=0)
                # The original producer's one quiet sample is source-registered,
                # not a copied colour. This recipe is qualified only at 64 square.
                if original.size != (64, 64):
                    raise BuildError('Ambiguous footprint has an unsupported source canvas')
                quiet = before[50 * int(scale), 16 * int(scale)].astype(float)
                residual = reconstructed[target] - field
                yy, xx = np.indices(residual.shape[:2], dtype=float)
                edge = np.minimum.reduce([xx + .5, yy + .5, residual.shape[1] - .5 - xx, residual.shape[0] - .5 - yy])
                weight = np.clip(edge / (.6 * scale), 0, 1)
                result[target] = np.rint((quiet + residual * weight[:, :, None]).clip(0, 255)).astype(np.uint8)
        if not np.array_equal(result[~allowed], before[~allowed]):
            raise BuildError('Local-source operation exceeds its declared regions')
    else:
        import cairosvg
        if vector is None:
            raise BuildError('The exact private overlay is required')
        for box in step['restore_base_boxes']:
            result[region(box)] = np.asarray(base)[region(box)]
        raw = cairosvg.svg2png(bytestring=vector, output_width=2048, output_height=2048, unsafe=False)
        with Image.open(BytesIO(raw)) as image:
            layer = image.convert('RGBA').resize((1024, 1024), Image.Resampling.LANCZOS)
        composited = Image.alpha_composite(Image.fromarray(result).convert('RGBA'), layer).convert('RGB')
        result = np.asarray(composited).copy()
        result[~allowed] = before[~allowed]
    return Image.fromarray(result)


def render(original, scale, recipe, authored):
    validate_recipe(recipe, original.width)
    if original.width != original.height or original.width * scale != 1024:
        raise BuildError('Layered atlas source/output scale differs')
    def vector(sha):
        path = authored / (sha + '.svg')
        if path.is_symlink() or digest_file(path) != sha:
            raise BuildError('Exact private atlas drawing is required')
        return read_vector(path, original.width, original.height)
    base = render_base(vector(recipe['base']['vector_sha256']),
        {'raster_dimensions': [2048, 2048], 'dimensions': [1024, 1024]}).convert('RGB')
    if rgba_hash(base) != recipe['base']['reference_rgba8_sha256']:
        raise BuildError('Reconstructed private atlas base changed')
    result = base
    for step in recipe['steps']:
        layer = vector(step['vector_sha256']) if step['kind'] == 'overlay' else None
        result = apply_step(original, result, base, step, layer)
        if rgba_hash(result) != step['reference_rgba8_sha256']:
            raise BuildError('Layered atlas intermediate differs from selected lineage')
    return result


def export(manifest, private_inputs):
    from PIL import Image
    selected = load_contract()
    if digest_file(manifest) != selected['reference_manifest_sha256']:
        raise BuildError('Use the selected production pack')
    inputs = outside_repo(private_inputs)
    if inputs.exists() or inputs.is_symlink() or not inputs.parent.is_dir():
        raise BuildError('Use a new private layered-atlas directory')
    rows, payloads, vectors = [], {}, {}
    def stage_vector(drawing, size):
        path, sha = Path(drawing['path']), drawing['sha256']
        if path.is_symlink() or digest_file(path) != sha:
            raise BuildError('Historical private drawing changed')
        read_vector(path, size, size)
        vectors[sha] = path
        return sha
    def chain(pr, expected, key, size, seen):
        if pr['source_key'] != key or len(seen) > 3:
            raise BuildError('Layered source lineage changed or exceeds bounds')
        if pr['method'] == BASE_METHOD:
            return {'schema': 'protector-native.private-layered-atlas/v1', 'id': key,
                'base': {'vector_sha256': stage_vector(pr['source_drawing'], size),
                         'reference_rgba8_sha256': expected}, 'steps': []}
        if pr['method'] not in (LOCAL, RIBS, STROKES):
            raise BuildError('Unsupported historical atlas operation')
        parent = pr['previous_candidate']
        path = Path(parent['path'])
        if path in seen or path.is_symlink() or digest_file(path) != parent['sha256']:
            raise BuildError('Historical atlas parent changed or repeats')
        with Image.open(path) as image:
            before = json.loads(image.info['protector_origin'])
            parent_sha = rgba_hash(image)
        recipe = chain(before, parent_sha, key, size, seen | {path})
        step = {'kind': 'local-source' if pr['method'] == LOCAL else 'overlay',
            'allowed_boxes': pr['edit_boxes_source_texels'], 'reference_rgba8_sha256': expected}
        if pr['method'] == LOCAL:
            step['operations'] = []
            for op in pr['operations']:
                if op['kind'] == 'preservation':
                    continue
                kind = {'source-value-field': 'source-field', 'bounded source rectangle': 'rectangle',
                    'ambiguous source footprint': 'ambiguous-footprint'}[op['kind']]
                migrated = {'kind': kind, 'box': op['source_texel_edge_box']}
                if kind == 'rectangle':
                    migrated['sample_box'] = op['original_color_sample_box']
                step['operations'].append(migrated)
        else:
            suffix = ('reviewer-fix-02' if pr['method'] == RIBS else 'reviewer-fix-03') + '/fix.py'
            producers = [p for p in pr['inputs'] if p['path'].endswith(suffix)]
            if len(producers) != 1 or digest_file(Path(producers[0]['path'])) != producers[0]['sha256']:
                raise BuildError('Unknown private overlay producer')
            receipt = json.loads((Path(producers[0]['path']).parent / 'receipt.json').read_text())
            records = [r for r in receipt['results'] if r['source'] == key]
            if len(records) != 1:
                raise BuildError('Ambiguous historical private overlay')
            row = records[0]
            png = Path(producers[0]['path']).parent / row['png']
            if digest_file(png) != row['png_sha256']:
                raise BuildError('Historical overlay result changed')
            with Image.open(png) as image:
                if rgba_hash(image) != expected:
                    raise BuildError('Overlay receipt is not the selected intermediate')
            step['vector_sha256'] = stage_vector(row['source_drawing'], size)
            step['restore_base_boxes'] = pr.get('quiet_restoration_from_v3_boxes', [])
        recipe['steps'].append(step)
        return recipe
    for entry in json.loads(manifest.read_text())['entries']:
        pr = entry['provenance']
        if pr['method'] not in (LOCAL, RIBS, STROKES):
            continue
        src = entry['source']
        key = f"{src['width']}x{src['height']}-{src['rgba8_sha256']}"
        recipe = chain(pr, entry['replacement']['uncompressed_rgba8_sha256'], key, src['width'], set())
        validate_recipe(recipe, src['width'])
        raw = (json.dumps(recipe, indent=2, sort_keys=True) + '\n').encode()
        sha = hashlib.sha256(raw).hexdigest()
        payloads[sha] = raw
        rows.append({'id': key, 'recipe_sha256': sha})
    if len(rows) != 3 or len({r['id'] for r in rows}) != 3:
        raise BuildError('Expected all three selected layered atlases')
    inputs.mkdir(mode=0o700)
    write_json(inputs / 'owner.json', {'schema': 'protector-native.private-layered-atlas-inputs/v1',
        'distribution_clearance': False, 'recipes': sorted(payloads), 'vectors': sorted(vectors)})
    for sha, raw in payloads.items():
        with (inputs / (sha + '.json')).open('xb') as stream:
            stream.write(raw)
    for sha, path in vectors.items():
        target = inputs / (sha + '.svg')
        shutil.copyfile(path, target)
        if digest_file(target) != sha:
            raise BuildError('Private atlas drawing copy changed')
    return {'schema': SCHEMA,
        **{k: selected[k] for k in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')},
        'entries': rows, 'scope': 'Recipe identities only; private authored geometry and drawings are external; no historical pixel payloads'}


def replay(game, work, authored):
    check_runtime()
    authored = outside_repo(authored)
    return replay_plates(game, work, authored, contract_path=CONTRACT, contract_schema=SCHEMA,
        entry_count=3, renderer=lambda original, scale, recipe: render(original, scale, recipe, authored),
        extra_algorithms=['tools/personal_layered_atlases.py', 'tools/personal_atlases.py',
            'tools/build_interface_vectors.py', 'requirements-personal-atlases.lock'], family='layered atlas')


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
    args = parser.parse_args()
    try:
        if args.command == 'export':
            if args.output.exists() or args.output.is_symlink():
                raise BuildError('Use a new layered-atlas contract path')
            result = export(args.manifest, args.private_inputs)
            write_json(args.output, result)
            print(json.dumps({'selected': len(result['entries']), 'distribution_clearance': False}))
        else:
            print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Layered atlas replay: {error}\n')

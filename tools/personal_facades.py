#!/usr/bin/env python3
"""Reconstruct seven private architectural treatments from original source fields."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, outside_repo, write_json
from tools.personal_textures import load_contract
from tools.personal_source_patterns import PERIODIC, periodic_field
from tools.personal_structural_plates import replay as replay_plates

CONTRACT = ROOT / 'reference/personal_facade_recipes.json'
SCHEMA = 'protector-native.personal-facades/v1'
METHOD = 'Selective source-registered bounded architectural paths over unchanged quiet v2 fields; original-sampled local colors.'


def validate_recipe(recipe):
    if recipe.get('schema') != 'protector-native.private-facade/v1' or not 1 <= len(recipe.get('operations', [])) <= 128:
        raise BuildError('A bounded private facade recipe is required')
    sha = recipe.get('base_rgba8_sha256', '')
    if len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
        raise BuildError('A pinned reconstructed base identity is required')
    for op in recipe['operations']:
        if op['geometry'] not in ('polygon', 'bounded_polyline'):
            raise BuildError('Unsupported facade primitive')
        fields = {'geometry', 'points', 'sample_box', 'sample_rank'}
        if op['geometry'] == 'bounded_polyline':
            fields.add('width')
        if set(op) != fields:
            raise BuildError('Facade primitives must sample original colours, not supply paint values')
        points, box, rank = op['points'], op['sample_box'], op['sample_rank']
        minimum = 3 if op['geometry'] == 'polygon' else 2
        if not minimum <= len(points) <= 128 or any(len(p) != 2 or any(
                type(v) not in (int, float) or not math.isfinite(v) or not -1 <= v <= 65 for v in p) for p in points):
            raise BuildError('Facade path exceeds its original canvas')
        if len(box) != 4 or any(type(v) is not int for v in box) or not \
                (0 <= box[0] < box[2] <= 64 and 0 <= box[1] < box[3] <= 64):
            raise BuildError('Facade colour sampling leaves the original')
        if rank is not None and (type(rank) not in (int, float) or not math.isfinite(rank) or not 0 <= rank <= 1):
            raise BuildError('Invalid original-sample quantile')
        if op['geometry'] == 'bounded_polyline' and (type(op['width']) not in (int, float) or
                not math.isfinite(op['width']) or not 0 < op['width'] <= 8):
            raise BuildError('Invalid facade stroke width')


def render(original, scale, recipe):
    import numpy as np
    from PIL import Image, ImageDraw
    validate_recipe(recipe)
    if original.size != (64, 64) or scale != 16:
        raise BuildError('Facade reconstruction requires the selected 64-to-1024 scale')
    base = periodic_field(original, scale, PERIODIC)
    if hashlib.sha256(base.convert('RGBA').tobytes()).hexdigest() != recipe['base_rgba8_sha256']:
        raise BuildError('Reconstructed quiet field differs from the selected parent')
    source = np.asarray(original.convert('RGB'), dtype=np.float64)
    image = base.resize((2048, 2048), Image.Resampling.NEAREST)
    mask = Image.new('L', image.size)
    draw, md = ImageDraw.Draw(image), ImageDraw.Draw(mask)
    for op in recipe['operations']:
        x0, y0, x1, y1 = op['sample_box']
        pixels = source[y0:y1, x0:x1].reshape(-1, 3)
        rank = op['sample_rank']
        if rank is not None:
            luma = pixels @ np.array([.2126, .7152, .0722])
            q = np.quantile(luma, rank)
            pixels = pixels[luma <= q] if rank < .5 else pixels[luma >= q]
        color = tuple(int(v) for v in np.rint(np.median(pixels, axis=0)))
        xy = [(round(x * 32), round(y * 32)) for x, y in op['points']]
        if op['geometry'] == 'polygon':
            draw.polygon(xy, fill=color)
            md.polygon(xy, fill=255)
        else:
            width = round(op['width'] * 32)
            draw.line(xy, fill=color, width=width, joint='curve')
            md.line(xy, fill=255, width=width, joint='curve')
    image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    mask = mask.resize((1024, 1024), Image.Resampling.LANCZOS)
    output, coverage = np.asarray(image).copy(), np.asarray(mask)
    output[coverage == 0] = np.asarray(base)[coverage == 0]
    return Image.fromarray(output)


def export(manifest, private_inputs):
    from PIL import Image
    selected = load_contract()
    if digest_file(manifest) != selected['reference_manifest_sha256']:
        raise BuildError('Use the selected production pack')
    inputs = outside_repo(private_inputs)
    if inputs.exists() or inputs.is_symlink() or not inputs.parent.is_dir():
        raise BuildError('Use a new external private facade directory')
    rows, payloads = [], {}
    for entry in json.loads(manifest.read_text())['entries']:
        pr = entry['provenance']
        if pr['method'] != METHOD:
            continue
        source = entry['source']
        key = f"{source['width']}x{source['height']}-{source['rgba8_sha256']}"
        if key != pr['source_key'] or [source['width'], source['height']] != [64, 64] or pr['scale'] != 16:
            raise BuildError('Facade source identity or scale changed')
        parent = Path(pr['previous_candidate']['path'])
        if parent.is_symlink() or digest_file(parent) != pr['previous_candidate']['sha256']:
            raise BuildError('Original quiet-field parent changed')
        with Image.open(parent) as image:
            origin = json.loads(image.info['protector_origin'])
            if origin['source_key'] != key or origin['parameters'] != PERIODIC or origin['method'] != \
                    'Positive periodic cubic source-sample reconstruction; explicit source-registered axis strokes on four named textures.':
                raise BuildError('Unsupported facade parent reconstruction')
            parent_sha = hashlib.sha256(image.convert('RGBA').tobytes()).hexdigest()
        recipe = {'schema': 'protector-native.private-facade/v1', 'id': key,
            'base_rgba8_sha256': parent_sha, 'operations': []}
        for op in pr['structural_paths']:
            row = {'geometry': op['geometry'], 'points': op['source_texel_edge_points'],
                'sample_box': op['original_sample_box'], 'sample_rank': op['sample_rank']}
            if op['geometry'] == 'bounded_polyline':
                row['width'] = op['width_source_texels']
            recipe['operations'].append(row)
        validate_recipe(recipe)
        raw = (json.dumps(recipe, indent=2, sort_keys=True) + '\n').encode()
        sha = hashlib.sha256(raw).hexdigest()
        payloads[sha] = raw
        rows.append({'id': key, 'recipe_sha256': sha})
    if len(rows) != 7 or len({r['id'] for r in rows}) != 7:
        raise BuildError('Expected all seven selected facade treatments')
    inputs.mkdir(mode=0o700)
    write_json(inputs / 'owner.json', {'schema': 'protector-native.private-facade-inputs/v1',
        'distribution_clearance': False, 'recipes': sorted(payloads)})
    for sha, raw in payloads.items():
        with (inputs / (sha + '.json')).open('xb') as stream:
            stream.write(raw)
    return {'schema': SCHEMA,
        **{k: selected[k] for k in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')},
        'entries': rows, 'scope': 'Recipe identities only; authored paths stay private and all colours are resampled from originals'}


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
                raise BuildError('Use a new facade contract path')
            result = export(args.manifest, args.private_inputs)
            write_json(args.output, result)
            print(json.dumps({'selected': len(result['entries']), 'distribution_clearance': False}))
        else:
            result = replay_plates(args.game, args.work_dir, args.authored_inputs,
                contract_path=CONTRACT, contract_schema=SCHEMA, entry_count=7, renderer=render,
                extra_algorithms=['tools/personal_facades.py', 'tools/personal_source_patterns.py'], family='facade')
            print(json.dumps(result, indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Facade replay: {error}\n')

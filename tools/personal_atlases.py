#!/usr/bin/env python3
"""Replay private source-coordinate SVG atlases without neural inference.

The public contract contains identities and processing settings, not drawings.
The separately supplied authored drawings are not cleared for redistribution.
"""
import argparse
from functools import lru_cache
import hashlib
from importlib.metadata import version
from io import BytesIO
import json
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_geometry import identity
from tools.personal_textures import load_contract, source_pixels, validate_contract
from tools.build_interface_vectors import read_vector

CONTRACT = ROOT / 'reference/personal_atlas_recipes.json'
RASTERIZER = 'CairoSVG 2.8.2; cairocffi 1.7.1; cairo 1.18.4'
METHOD = 'Explicit source-coordinate structural redraw with sampled quiet fills; local source-level contours only in named mark ROIs.'
ALGORITHMS = ['tools/personal_atlases.py', 'tools/build_interface_vectors.py',
    'tools/personal_textures.py', 'tools/prepare_texture_restoration.py',
    'protector_native/textures.py', 'requirements-personal-atlases.lock']


def validate_atlases(contract, selected):
    if contract.get('schema') != 'protector-native.personal-atlases/v1' or len(contract.get('entries', [])) != 6:
        raise BuildError('The six selected atlas planes are required')
    for key in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256'):
        if contract[key] != selected[key]:
            raise BuildError('Atlas contract belongs to different original inputs')
    entries, seen = {e['id']: e for e in selected['entries']}, set()
    for row in contract['entries']:
        if row['id'] in seen or row['id'] not in entries:
            raise BuildError('Unknown or repeated atlas output')
        seen.add(row['id'])
        entry = entries[row['id']]
        if row['source_dimensions'] != [entry['source']['width'], entry['source']['height']] or \
                row['dimensions'] != entry['dimensions'] or row['dimensions'] != [1024, 1024] or \
                row['raster_dimensions'] != [2048, 2048] or row['rasterizer'] != RASTERIZER or \
                row['downsample'] != 'RGB Lanczos 2:1' or \
                row['reference_rgba8_sha256'] != entry['reference_rgba8_sha256']:
            raise BuildError('Atlas source, pixel identity or rendering settings changed')
        if len(row['vector_sha256']) != 64 or any(c not in '0123456789abcdef' for c in row['vector_sha256']):
            raise BuildError('Invalid private drawing identity')
        if entry['operation']['kind'] != 'authored-treatment-pending':
            raise BuildError('Atlas does not match the selected authored treatment')


def check_runtime():
    import cairocffi
    for name, expected in {'CairoSVG': '2.8.2', 'cairocffi': '1.7.1', 'Pillow': '12.1.1',
                           'numpy': '2.4.2', 'scipy': '1.17.0'}.items():
        if version(name) != expected:
            raise BuildError('Use the qualified atlas requirements lock')
    if cairocffi.cairo_version_string() != '1.18.4':
        raise BuildError('Atlas replay requires the separately installed cairo 1.18.4 library')


def render(vector, row):
    import cairosvg
    from PIL import Image
    raw = cairosvg.svg2png(bytestring=vector, output_width=row['raster_dimensions'][0],
        output_height=row['raster_dimensions'][1], unsafe=False)
    with Image.open(BytesIO(raw)) as raster:
        # Preserve the original producer's RGB conversion BEFORE downsampling.
        return raster.convert('RGB').resize(tuple(row['dimensions']), Image.Resampling.LANCZOS).convert('RGBA')


def export(manifest, private_inputs):
    selected = load_contract()
    validate_contract(selected)
    if digest_file(manifest) != selected['reference_manifest_sha256']:
        raise BuildError('Use the selected production pack')
    inputs = outside_repo(private_inputs)
    if inputs.exists() or inputs.is_symlink() or not inputs.parent.is_dir():
        raise BuildError('Use a new external private drawing directory')
    rows, drawings = [], {}
    for entry in json.loads(manifest.read_text())['entries']:
        pr = entry['provenance']
        if pr['method'] != METHOD:
            continue
        src, params, drawing = entry['source'], pr['parameters'], pr['source_drawing']
        if params != {'downsample': 'Lanczos 2:1 only for path antialiasing', 'final': 1024,
                'global_source_filter': False, 'learned_model': None, 'raster': 2048,
                'svg_source_units': [src['width'], src['height']]}:
            raise BuildError('Original atlas production settings changed')
        path = Path(drawing['path'])
        if path.is_symlink() or digest_file(path) != drawing['sha256']:
            raise BuildError('Original authored drawing changed')
        read_vector(path, src['width'], src['height'])
        rows.append({'id': f"{src['width']}x{src['height']}-{src['rgba8_sha256']}",
            'source_dimensions': [src['width'], src['height']], 'dimensions': [1024, 1024],
            'raster_dimensions': [2048, 2048], 'rasterizer': RASTERIZER,
            'downsample': 'RGB Lanczos 2:1', 'vector_sha256': drawing['sha256'],
            'reference_rgba8_sha256': entry['replacement']['uncompressed_rgba8_sha256']})
        drawings[drawing['sha256']] = path
    contract = {'schema': 'protector-native.personal-atlases/v1',
        **{k: selected[k] for k in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')},
        'entries': rows, 'distribution_clearance': False,
        'scope': 'Identities only; private authored SVG files are supplied separately'}
    validate_atlases(contract, selected)
    inputs.mkdir(mode=0o700)
    write_json(inputs / 'owner.json', {'schema': 'protector-native.private-atlas-inputs/v1',
        'contract_identity': identity(contract), 'distribution_clearance': False})
    for sha, path in drawings.items():
        target = inputs / (sha + '.svg')
        shutil.copyfile(path, target)
        if digest_file(target) != sha:
            raise BuildError('Private drawing copy changed')
    return contract


def replay(game, work, authored):
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    check_runtime()
    game, work, authored = outside_repo(game), outside_repo(work), outside_repo(authored)
    if any(work == p or work.is_relative_to(p) or p.is_relative_to(work) for p in (game, authored)):
        raise BuildError('Atlas output must be separate from original and authored inputs')
    selected = load_contract()
    validate_contract(selected)
    contract = json.loads(CONTRACT.read_text())
    validate_atlases(contract, selected)
    if contract['source_lock_sha256'] != digest_file(LOCK):
        raise BuildError('Original content lock changed')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError('Atlas output needs an existing parent and 5 GiB headroom')
    owner = {'schema': 'protector-native.personal-atlas-work/v1', 'game': str(game),
        'source_lock_sha256': digest_file(LOCK), 'contract_sha256': digest_file(CONTRACT)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Atlas output belongs to different inputs')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Atlas candidate directory is a link')
    @lru_cache(maxsize=1)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    entries = {e['id']: e for e in selected['entries']}
    algorithms = {p: digest_file(ROOT / p) for p in ALGORITHMS}
    started, results = time.monotonic(), []
    for row in contract['entries']:
        entry = entries[row['id']]
        source_pixels(entry, *package(entry['occurrence']['package']))
        path = authored / (row['vector_sha256'] + '.svg')
        if path.is_symlink() or digest_file(path) != row['vector_sha256']:
            raise BuildError('Supply the exact selected private drawing')
        picture = render(read_vector(path, *row['source_dimensions']), row)
        actual = hashlib.sha256(picture.tobytes()).hexdigest()
        if actual != row['reference_rgba8_sha256']:
            raise BuildError('Atlas differs from selected pixels: ' + row['id'])
        target = outputs / (row['id'] + '.png')
        if target.is_symlink():
            raise BuildError('Atlas candidate path is a link')
        if target.exists():
            with Image.open(target) as cached:
                if cached.format != 'PNG' or cached.size != picture.size or \
                        hashlib.sha256(cached.convert('RGBA').tobytes()).hexdigest() != actual:
                    raise BuildError('Cached atlas candidate changed')
        else:
            with target.open('xb') as stream:
                picture.save(stream, format='PNG')
        results.append({'id': row['id'], 'rgba8_sha256': actual, 'png_sha256': digest_file(target),
            'vector_sha256': row['vector_sha256'], 'reference_pixels_exact': True})
        print(f'Private atlas replay verified: {len(results)}/6', flush=True)
    if digest_file(CONTRACT) != owner['contract_sha256'] or any(digest_file(ROOT / p) != sha for p, sha in algorithms.items()):
        raise BuildError('Atlas tools or contract changed during replay')
    receipt = {'schema': 'protector-native.personal-atlas-result/v1', 'selected': len(results),
        'exact_pixel_matches': len(results), 'complete_texture_pack': False,
        'requires_private_authored_inputs': True, 'distribution_clearance': False,
        'seconds': time.monotonic() - started, 'rasterizer': RASTERIZER,
        'algorithms': algorithms, 'entries': results}
    write_json(work / 'receipt.json', receipt)
    return {k: v for k, v in receipt.items() if k not in ('algorithms', 'entries')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    stage = subs.add_parser('export', help='Developer-only private drawing migration')
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
                raise BuildError('Use a new atlas contract path')
            result = export(args.manifest, args.private_inputs)
            write_json(args.output, result)
            print(json.dumps({'selected': len(result['entries']), 'distribution_clearance': False}))
        else:
            print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Atlas replay: {error}\n')

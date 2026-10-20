#!/usr/bin/env python3
"""Replay selected vectors from separately supplied private authored inputs."""
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
from tools.build_interface_vectors import read_vector, split_planes

CONTRACT = ROOT / 'reference/personal_vector_recipes.json'
ALGORITHMS = ['tools/personal_vectors.py', 'tools/build_interface_vectors.py',
    'tools/personal_textures.py', 'tools/prepare_texture_restoration.py',
    'protector_native/textures.py', 'requirements-personal-vectors.lock']


def validate_vectors(contract, selected):
    if contract.get('schema') != 'protector-native.personal-vectors/v1' or \
            len(contract.get('entries', [])) != 31 or len(contract.get('groups', {})) != 21:
        raise BuildError('The complete selected vector contract is required')
    for key in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256'):
        if contract[key] != selected[key]:
            raise BuildError('Vector contract belongs to different original inputs')
    entries = {e['id']: e for e in selected['entries']}
    lock = json.loads(LOCK.read_text())
    for key, group in contract['groups'].items():
        if identity(group) != key or group['kind'] not in ('colour-and-mask', 'mask-only', 'opaque-plane', 'straight-alpha') or \
                type(group['scale']) is not int or not 2 <= group['scale'] <= 16 or \
                group['rasterizer'] != 'resvg-py 0.5.0; resvg 0.48.1' or \
                len(group['planes']) != (2 if group['kind'] in ('colour-and-mask', 'mask-only') else 1):
            raise BuildError('Vector job identity or shape differs')
        for index, plane in enumerate(group['planes']):
            src, occurrence = plane['source'], plane['occurrence']
            if plane['id'] != f"{src['width']}x{src['height']}-{src['rgba8_sha256']}" or \
                    [src['width'], src['height']] != group['dimensions'] or \
                    max(group['dimensions']) * group['scale'] > 4096 or occurrence['plane'] != index or \
                    lock['game']['files/' + occurrence['package']]['sha256'] != occurrence['package_sha256']:
                raise BuildError('Invalid original vector source plane')
        if len(group['planes']) == 2:
            a, b = [p['occurrence'] for p in group['planes']]
            if (a['package'], a['resource_offset']) != (b['package'], b['resource_offset']):
                raise BuildError('Vector colour and coverage are not an original source pair')
    seen = set()
    for row in contract['entries']:
        if row['id'] in seen or row['id'] not in entries:
            raise BuildError('Repeated or unknown vector output')
        seen.add(row['id'])
        entry, group = entries[row['id']], contract['groups'][row['group']]
        if row['plane'] not in range(len(group['planes'])) or group['planes'][row['plane']]['id'] != row['id'] or \
                entry['dimensions'] != [v * group['scale'] for v in group['dimensions']]:
            raise BuildError('Vector output identity or dimensions differ')
        expected = entry['reference_rgba8_sha256']
        if entry['format'] in ('rgba8', 'rgba8-unorm'):
            expected = entry['reference_delivery_sha256']
        if row['reference_rgba8_sha256'] != expected:
            raise BuildError('Vector output has a different selected pixel identity')


def render(vector, group):
    import resvg_py
    from PIL import Image
    if resvg_py.__version__ != '0.5.0' or resvg_py.__resvg_version__ != '0.48.1':
        raise BuildError('Use the qualified vector rasterizer version')
    width, height = [v * group['scale'] for v in group['dimensions']]
    picture = Image.open(BytesIO(resvg_py.svg_to_bytes(svg_string=vector.decode('utf-8'),
        skip_system_fonts=True, width=width, height=height))).convert('RGBA')
    if picture.size != (width, height):
        raise BuildError('Vector rasterizer changed canvas dimensions')
    if group['kind'] == 'opaque-plane':
        if picture.getextrema()[3] != (255, 255):
            raise BuildError('Opaque vector does not cover its canvas')
        return [picture]
    color, coverage = split_planes(picture)
    if group['kind'] == 'straight-alpha':
        color.putalpha(picture.getchannel('A'))
        return [color]
    return [color, coverage]


def replay(game, work, authored):
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    for name, expected in {'numpy': '2.4.2', 'Pillow': '12.1.1', 'scipy': '1.17.0'}.items():
        if version(name) != expected:
            raise BuildError('Use the qualified vector requirements lock')
    game, work, authored = outside_repo(game), outside_repo(work), outside_repo(authored)
    if any(work == p or work.is_relative_to(p) or p.is_relative_to(work) for p in (game, authored)):
        raise BuildError('Vector output must be separate from original and authored inputs')
    selected = load_contract()
    validate_contract(selected)
    contract = json.loads(CONTRACT.read_text())
    validate_vectors(contract, selected)
    if contract['source_lock_sha256'] != digest_file(LOCK):
        raise BuildError('Original content lock changed')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError('Vector output needs an existing parent and 5 GiB headroom')
    owner = {'schema': 'protector-native.personal-vector-work/v1', 'game': str(game),
        'source_lock_sha256': digest_file(LOCK), 'contract_sha256': digest_file(CONTRACT)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Vector output belongs to different inputs')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Vector output directory is a link')
    @lru_cache(maxsize=2)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    algorithms = {p: digest_file(ROOT / p) for p in ALGORITHMS}
    started, results = time.monotonic(), []
    for key, group in contract['groups'].items():
        for plane in group['planes']:
            raw = source_pixels(plane, *package(plane['occurrence']['package']))
            source = Image.frombytes('RGBA', tuple(group['dimensions']), raw)
            if group['kind'] != 'straight-alpha' and source.getextrema()[3] != (255, 255):
                raise BuildError('Vector source plane unexpectedly has alpha')
            if group['kind'] == 'mask-only' and plane == group['planes'][0] and source.getcolors(maxcolors=1) is None:
                raise BuildError('Mask-only vector lost its retained constant colour')
        path = authored / (group['vector_sha256'] + '.svg')
        if path.is_symlink() or digest_file(path) != group['vector_sha256']:
            raise BuildError('Supply the exact reviewed private vector; replacements are not automatic')
        vector = read_vector(path, *group['dimensions'],
            max_bytes=(4 if group['kind'] == 'straight-alpha' else 1) * 1024**2)
        pictures = render(vector, group)
        for row in (r for r in contract['entries'] if r['group'] == key):
            picture = pictures[row['plane']]
            actual = hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()
            if actual != row['reference_rgba8_sha256']:
                raise BuildError('Vector replay differs from the selected pixels: ' + row['id'])
            target = outputs / (row['id'] + '.png')
            if target.is_symlink():
                raise BuildError('Vector candidate path is a link')
            if target.exists():
                with Image.open(target) as saved:
                    if saved.format != 'PNG' or saved.size != picture.size or \
                            hashlib.sha256(saved.convert('RGBA').tobytes()).hexdigest() != actual:
                        raise BuildError('Cached vector candidate changed')
            else:
                with target.open('xb') as stream:
                    picture.save(stream, format='PNG')
            results.append({'id': row['id'], 'rgba8_sha256': actual, 'png_sha256': digest_file(target),
                'vector_sha256': group['vector_sha256'], 'reference_pixels_exact': True})
        print(f'Private vector replay verified: {len(results)}/31', flush=True)
    if digest_file(CONTRACT) != owner['contract_sha256'] or any(digest_file(ROOT / p) != sha for p, sha in algorithms.items()):
        raise BuildError('Vector contract or tools changed during execution')
    receipt = {'schema': 'protector-native.personal-vector-result/v1', 'selected': len(results),
        'exact_pixel_matches': len(results), 'complete_texture_pack': False,
        'requires_private_authored_inputs': True, 'distribution_clearance': False,
        'seconds': time.monotonic() - started, 'algorithms': algorithms, 'entries': results}
    write_json(work / 'receipt.json', receipt)
    return {k: v for k, v in receipt.items() if k not in ('algorithms', 'entries')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--authored-inputs', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Vector replay: {error}\n')

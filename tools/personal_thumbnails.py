#!/usr/bin/env python3
"""Build registered thumbnails from original borders and verified restored parents."""
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_textures import compare_reference, load_contract, source_pixels, validate_contract
from tools.personal_texture_variants import admit as admit_parent
from tools.personal_thumbnail_variants import admit_thumbnail

CONTRACT = ROOT / 'reference/personal_thumbnail_recipes.json'
ALGORITHMS = ['tools/personal_thumbnails.py', 'tools/personal_textures.py',
    'tools/prepare_texture_restoration.py', 'protector_native/textures.py', 'requirements-personal.lock',
    'tools/personal_texture_variants.py', 'reference/personal_texture_variants.json',
    'tools/personal_thumbnail_variants.py', 'reference/personal_thumbnail_variants.json']


def validate_thumbnails(contract, selected):
    if contract.get('schema') != 'protector-native.personal-thumbnails/v1' or len(contract.get('entries', [])) != 34:
        raise BuildError('The complete registered thumbnail contract is required')
    for key in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256'):
        if contract[key] != selected[key]:
            raise BuildError('Thumbnail contract belongs to different inputs')
    entries, seen = {e['id']: e for e in selected['entries']}, set()
    for row in contract['entries']:
        if row['id'] in seen or row['id'] not in entries or row['parent'] not in entries or row['id'] == row['parent']:
            raise BuildError('Unknown or duplicate thumbnail dependency')
        seen.add(row['id'])
        entry, parent = entries[row['id']], entries[row['parent']]
        if entry['dimensions'] != [1024, 1024] or parent['dimensions'] != [4096, 4096] or \
                [entry['source'][k] for k in ('width', 'height')] != [64, 64] or \
                [parent['source'][k] for k in ('width', 'height')] != [256, 256] or \
                row['border_source_pixels'] != 2 or row['blend_source_pixels'] != 1 or \
                not 0 <= row['registration_score'] < .022:
            raise BuildError('Thumbnail scale, border or registration differs')
        box = row['source_crop']
        if len(box) != 4 or any(type(v) is not int or not 0 <= v <= 256 for v in box) or \
                box[2] - box[0] != 64 or box[3] - box[1] != 64:
            raise BuildError('Invalid source crop')


def render(original, parent, row):
    import numpy as np
    from PIL import Image
    if original.size != (64, 64) or parent.size != (4096, 4096):
        raise BuildError('Thumbnail source or restored parent has wrong dimensions')
    axis = (np.arange(1024) + .5) / 16
    edge = np.minimum(axis, 64 - axis)
    alpha = np.clip(np.minimum(edge[:, None], edge[None, :]) - 2, 0, 1)
    alpha = (.5 - .5 * np.cos(np.pi * alpha)).astype(np.float32)
    crop = parent.convert('RGB').crop(tuple(v * 16 for v in row['source_crop']))
    border = original.convert('RGB').resize((1024, 1024), Image.Resampling.BICUBIC)
    a, b = np.asarray(crop), np.asarray(border)
    rgb = np.rint(a.astype(np.float32) * alpha[:, :, None] +
        b.astype(np.float32) * (1 - alpha[:, :, None])).astype(np.uint8)
    if not np.array_equal(rgb[alpha == 1], a[alpha == 1]) or not np.array_equal(rgb[alpha == 0], b[alpha == 0]):
        raise BuildError('Thumbnail crop core or original border changed')
    return Image.fromarray(rgb)


def replay(args):
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    game, work = outside_repo(args.game), outside_repo(args.work_dir)
    parents = [outside_repo(p) for p in args.parent_candidates]
    inputs = [game, *parents]
    if any(work == p or work.is_relative_to(p) or p.is_relative_to(work) for p in inputs):
        raise BuildError('Thumbnail output must be separate from all inputs')
    selected = load_contract()
    validate_contract(selected)
    contract = json.loads(CONTRACT.read_text())
    validate_thumbnails(contract, selected)
    if digest_file(LOCK) != contract['source_lock_sha256']:
        raise BuildError('Source lock changed')
    wanted = [r for r in contract['entries'] if not args.entry or r['id'] == args.entry]
    if not wanted:
        raise BuildError('Requested thumbnail is not selected')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError('Thumbnail output needs 5 GiB headroom and an existing parent')
    references = {}
    if args.numerical_reference:
        index = json.loads(outside_repo(args.numerical_reference).read_text())
        if index['schema'] != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private reference index')
        references = index['entries']
    owner = {'schema': 'protector-native.personal-thumbnail-work/v1', 'game': str(game),
        'source_lock_sha256': digest_file(LOCK), 'contract_sha256': digest_file(CONTRACT)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Thumbnail workspace belongs to different inputs')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Thumbnail candidate directory is a link')
    @lru_cache(maxsize=2)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    entries = {e['id']: e for e in selected['entries']}
    algorithms = {p: digest_file(ROOT / p) for p in ALGORITHMS}
    started, results = time.monotonic(), []
    for row in wanted:
        entry, parent_entry = entries[row['id']], entries[row['parent']]
        raw = source_pixels(entry, *package(entry['occurrence']['package']))
        source_pixels(parent_entry, *package(parent_entry['occurrence']['package']))
        original = Image.frombytes('RGBA', (64, 64), raw)
        if original.getextrema()[3] != (255, 255):
            raise BuildError('Original thumbnail acquired alpha')
        choices = [p / (row['parent'] + '.png') for p in parents if (p / (row['parent'] + '.png')).exists()]
        if not choices or any(p.is_symlink() for p in choices):
            raise BuildError('Rebuild the selected full-art parent first: ' + row['parent'])
        if len({digest_file(p) for p in choices}) != 1:
            raise BuildError('Ambiguous restored parent candidates; supply one verified directory')
        with Image.open(choices[0]) as parent:
            if parent.format != 'PNG' or parent.size != (4096, 4096) or parent.convert('RGBA').getextrema()[3] != (255, 255):
                raise BuildError('Restored parent format or alpha differs')
            parent_hash = hashlib.sha256(parent.convert('RGBA').tobytes()).hexdigest()
            parent_comparison = None
            if parent_hash != parent_entry['reference_rgba8_sha256']:
                parent_comparison = admit_parent(parent_entry, parent_hash)
                if parent_comparison is None and references:
                    parent_comparison = compare_reference(parent_entry, parent, references)
                if parent_comparison is None or parent_comparison['max_channel_error'] > 1:
                    raise BuildError('Restored parent is not the reviewed artwork')
            picture = render(original, parent, row)
        actual = hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()
        comparison = None
        if actual != entry['reference_rgba8_sha256']:
            comparison = admit_thumbnail(entry, actual, recipe=row, parent_entry=parent_entry, parent_hash=parent_hash)
            if comparison is None and references:
                comparison = compare_reference(entry, picture, references)
            if comparison is None or comparison['max_channel_error'] > 1:
                raise BuildError('Thumbnail differs from selected reference: ' + row['id'])
        target = outputs / (row['id'] + '.png')
        if target.is_symlink():
            raise BuildError('Thumbnail candidate is a link')
        if target.exists():
            with Image.open(target) as saved:
                if saved.size != picture.size or hashlib.sha256(saved.convert('RGBA').tobytes()).hexdigest() != actual:
                    raise BuildError('Cached thumbnail changed')
        else:
            with target.open('xb') as stream:
                picture.save(stream, format='PNG')
        results.append({'id': row['id'], 'parent': row['parent'], 'parent_rgba8_sha256': parent_hash,
            'parent_numerical_comparison': parent_comparison,
            'rgba8_sha256': actual, 'png_sha256': digest_file(target),
            'reference_pixels_exact': actual == entry['reference_rgba8_sha256'], 'numerical_comparison': comparison})
        print(f'Registered thumbnail replay verified: {len(results)}/{len(wanted)}', flush=True)
    if digest_file(CONTRACT) != owner['contract_sha256'] or any(digest_file(ROOT / p) != sha for p, sha in algorithms.items()):
        raise BuildError('Thumbnail recipes or tools changed during execution')
    rounded = sum(not r['reference_pixels_exact'] for r in results)
    receipt = {'schema': 'protector-native.personal-thumbnail-result/v1', 'selected': len(results),
        'exact_pixel_matches': len(results) - rounded, 'bounded_rounding_matches': rounded,
        'complete_texture_pack': False, 'seconds': time.monotonic() - started,
        'algorithms': algorithms, 'entries': results}
    write_json(work / 'receipt.json', receipt)
    return {k: v for k, v in receipt.items() if k not in ('algorithms', 'entries')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--parent-candidates', type=Path, action='append', required=True)
    parser.add_argument('--entry')
    parser.add_argument('--numerical-reference', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Thumbnail replay: {error}\n')

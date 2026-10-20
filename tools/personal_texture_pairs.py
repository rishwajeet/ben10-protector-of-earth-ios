#!/usr/bin/env python3
"""Replay source-derived paired contours and interior colour extension exactly."""
import argparse
from functools import lru_cache
import hashlib
from importlib.metadata import version
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

CONTRACT = ROOT / 'reference/personal_texture_pairs.json'
ALGORITHMS = ['tools/personal_texture_pairs.py', 'tools/personal_textures.py',
    'tools/restore_texture_objects.py', 'tools/prepare_texture_restoration.py',
    'protector_native/textures.py', 'requirements-personal-structural.lock']


def topology(mask, coverage, scale):
    import numpy as np
    from scipy.ndimage import distance_transform_edt, label
    height, width = mask.shape
    down = coverage.reshape(height, scale, width, scale).mean(axis=(1, 3))
    before, after = mask >= .5, down >= .5
    changed = before ^ after
    distance = np.where(before, distance_transform_edt(before), distance_transform_edt(~before)) - 1
    union = int((before | after).sum())
    result = {'mask_iou': float((before & after).sum() / union) if union else 1.,
        'foreground_components': [int(label(before)[1]), int(label(after)[1])],
        'background_components': [int(label(~before)[1]), int(label(~after)[1])],
        'max_changed_boundary_inset': float(distance[changed].max()) if changed.any() else 0.,
        'mean_coverage_delta': abs(float(mask.mean()) - float(coverage.mean()))}
    if result['mask_iou'] < .98 or result['foreground_components'][0] != result['foreground_components'][1] or \
            result['background_components'][0] != result['background_components'][1] or \
            result['max_changed_boundary_inset'] > 1 or result['mean_coverage_delta'] > .01:
        raise BuildError('Source contour topology or displacement guard failed')
    return result


def render(primary, auxiliary, scale, operation, wraps):
    import numpy as np
    from PIL import Image
    from scipy.ndimage import distance_transform_edt, gaussian_filter, map_coordinates
    from tools.restore_texture_objects import resample_auxiliary
    if primary.shape != auxiliary.shape or primary.ndim != 3 or primary.shape[2] != 3 or \
            not np.isfinite(primary).all() or not np.isfinite(auxiliary).all() or \
            primary.min() < 0 or primary.max() > 1 or auxiliary.min() < 0 or auxiliary.max() > 1:
        raise BuildError('Invalid source pair')
    mask = auxiliary[:, :, 1]
    interior = mask > .90
    if operation != 'water-contour' and not interior.any():
        raise BuildError('The selected source has no interior colour samples')
    if operation == 'interior-cubic':
        nearest = distance_transform_edt(~interior, return_distances=False, return_indices=True)
        extended = primary[nearest[0], nearest[1]]
        return [resample_auxiliary(extended, scale, wraps[0]),
                resample_auxiliary(auxiliary, scale, wraps[1])], {}
    if operation not in ('flame-contour', 'water-contour') or wraps != [['repeat', 'repeat']] * 2 or \
            np.any(auxiliary[:, :, [0, 2]] != 0):
        raise BuildError('Contour operation requires the reviewed periodic pure-green source mask')
    height, width = mask.shape
    coordinates = np.stack(np.meshgrid((np.arange(height * scale) + .5) / scale - .5,
        (np.arange(width * scale) + .5) / scale - .5, indexing='ij'))
    amplitude = float(np.median(mask[mask > .85])) if operation == 'flame-contour' else 1.
    if not np.isfinite(amplitude) or amplitude <= 0:
        raise BuildError('Invalid source contour amplitude')
    field = gaussian_filter(mask / amplitude, sigma=.45, mode='wrap')
    high = map_coordinates(field, coordinates, order=3, mode='grid-wrap', prefilter=True)
    gx = (np.roll(high, -1, 1) - np.roll(high, 1, 1)) / 2
    gy = (np.roll(high, -1, 0) - np.roll(high, 1, 0)) / 2
    coverage = np.clip((high - .5) / np.maximum(np.hypot(gx, gy), 1e-8) + .5, 0, 1) * amplitude
    metrics = topology(mask, coverage, scale)
    if operation == 'flame-contour':
        nearest = distance_transform_edt(~interior, return_distances=False, return_indices=True)
        extended = primary[nearest[0], nearest[1]]
        rgb = np.stack([np.clip(map_coordinates(extended[:, :, c], coordinates,
            order=3, mode='grid-wrap', prefilter=True), 0, 1) for c in range(3)], axis=2)
        down = rgb.reshape(height, scale, width, scale, 3).mean(axis=(1, 3))
        delta = float(np.abs(down - primary)[interior].mean() * 255)
        if delta >= 2:
            raise BuildError('Source contour interior colour guard failed')
        metrics['interior_color_roundtrip_mae_255'] = delta
        color_image = Image.fromarray(np.rint(rgb * 255).astype(np.uint8))
    else:
        interior = mask > .97
        if int(interior.sum()) <= 500:
            raise BuildError('Water contour has insufficient original interior samples')
        # The original recipe computes the median in uint8 space, then rounds.
        original = np.rint(primary * 255).astype(np.uint8)
        color = np.median(original[interior], axis=0).round().astype(np.uint8)
        if color.min() < 100 or color[2] < 247:
            raise BuildError('Original ripple interior no longer matches its colour policy')
        color_image = Image.fromarray(np.rint(coverage[:, :, None] * color).astype(np.uint8))
    mask_image = Image.fromarray(np.stack([np.zeros_like(coverage),
        np.rint(coverage * 255), np.zeros_like(coverage)], axis=2).astype(np.uint8))
    return [color_image, mask_image], metrics


def validate_pairs(contract, selected):
    if contract.get('schema') != 'protector-native.personal-texture-pairs/v1' or \
            len(contract.get('entries', [])) != 43 or len(contract.get('groups', {})) != 28:
        raise BuildError('The complete selected paired contract is required')
    for key in ('title_dol_sha256', 'reference_manifest_sha256', 'source_lock_sha256'):
        if contract[key] != selected[key]:
            raise BuildError('Paired inputs differ from the selected pack')
    lock = json.loads(LOCK.read_text())
    entries = {e['id']: e for e in selected['entries']}
    for key, group in contract['groups'].items():
        if identity(group) != key or group['operation'] not in ('flame-contour', 'water-contour', 'interior-cubic') or \
                len(group['planes']) != 2 or type(group['scale']) is not int or not 1 <= group['scale'] <= 64:
            raise BuildError('Invalid paired operation or identity')
        dimensions = None
        for index, plane in enumerate(group['planes']):
            src, occurrence = plane['source'], plane['occurrence']
            if plane['id'] != f"{src['width']}x{src['height']}-{src['rgba8_sha256']}" or \
                    occurrence['plane'] != index or \
                    lock['game']['files/' + occurrence['package']]['sha256'] != occurrence['package_sha256'] or \
                    max(src['width'], src['height']) * group['scale'] > 4096:
                raise BuildError('Invalid paired source plane')
            pair_dimensions = [src['width'], src['height']]
            if dimensions is not None and dimensions != pair_dimensions:
                raise BuildError('Original paired dimensions differ')
            dimensions = pair_dimensions
    seen = set()
    for row in contract['entries']:
        if row['id'] in seen or row['id'] not in entries or row['plane'] not in (0, 1):
            raise BuildError('Repeated or unknown paired output')
        seen.add(row['id'])
        group = contract['groups'][row['group']]
        plane, entry = group['planes'][row['plane']], entries[row['id']]
        if plane['id'] != row['id'] or [plane['source'][k] * group['scale'] for k in ('width', 'height')] != entry['dimensions']:
            raise BuildError('Paired output identity or dimensions differ')


def replay(game, work):
    import numpy as np
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    for name, expected in {'numpy': '2.4.2', 'Pillow': '12.1.1', 'scipy': '1.17.0'}.items():
        if version(name) != expected:
            raise BuildError('Use the qualified structural requirements lock')
    game, work = outside_repo(game), outside_repo(work)
    if work == game or work.is_relative_to(game) or game.is_relative_to(work):
        raise BuildError('Pair workspace must be separate from original inputs')
    selected = load_contract()
    validate_contract(selected)
    contract = json.loads(CONTRACT.read_text())
    validate_pairs(contract, selected)
    if digest_file(LOCK) != contract['source_lock_sha256']:
        raise BuildError('Original content lock changed')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError('Pair replay needs an existing parent and 5 GiB headroom')
    owner = {'schema': 'protector-native.personal-texture-pair-work/v1', 'game': str(game),
        'contract_sha256': digest_file(CONTRACT), 'source_lock_sha256': digest_file(LOCK)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Pair workspace belongs to different inputs')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Paired output directory is a link')
    @lru_cache(maxsize=2)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    entries = {e['id']: e for e in selected['entries']}
    algorithms = {p: digest_file(ROOT / p) for p in ALGORITHMS}
    started, results = time.monotonic(), []
    for key, group in contract['groups'].items():
        arrays = []
        for plane in group['planes']:
            raw = source_pixels(plane, *package(plane['occurrence']['package']))
            if any(a != 255 for a in raw[3::4]):
                raise BuildError('Paired source has nonopaque alpha')
            arrays.append(np.frombuffer(raw, np.uint8).reshape(plane['source']['height'],
                plane['source']['width'], 4)[:, :, :3].astype(np.float64) / 255)
        pictures, metrics = render(*arrays, group['scale'], group['operation'],
            [p['wrap_t_s'] for p in group['planes']])
        for row in (r for r in contract['entries'] if r['group'] == key):
            entry, picture = entries[row['id']], pictures[row['plane']]
            actual = hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()
            if actual != entry['reference_rgba8_sha256'] or list(picture.size) != entry['dimensions']:
                raise BuildError('Paired replay differs from selected reference: ' + row['id'])
            target = outputs / (row['id'] + '.png')
            if target.is_symlink():
                raise BuildError('Paired candidate is a link')
            if target.exists():
                with Image.open(target) as saved:
                    if list(saved.size) != entry['dimensions'] or saved.format != 'PNG' or \
                            hashlib.sha256(saved.convert('RGBA').tobytes()).hexdigest() != actual:
                        raise BuildError('Cached paired candidate changed')
            else:
                with target.open('xb') as stream:
                    picture.save(stream, format='PNG')
            results.append({'id': row['id'], 'rgba8_sha256': actual, 'png_sha256': digest_file(target),
                'reference_pixels_exact': True, 'metrics': metrics})
        print(f'Paired source replay verified: {len(results)}/43', flush=True)
    if digest_file(CONTRACT) != owner['contract_sha256'] or any(digest_file(ROOT / p) != s for p, s in algorithms.items()):
        raise BuildError('Paired tools or recipes changed during execution')
    receipt = {'schema': 'protector-native.personal-texture-pair-result/v1', 'selected': len(results),
        'exact_pixel_matches': len(results), 'complete_texture_pack': False,
        'seconds': time.monotonic() - started, 'algorithms': algorithms, 'entries': results}
    write_json(work / 'receipt.json', receipt)
    return {k: v for k, v in receipt.items() if k not in ('algorithms', 'entries')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args.game, args.work_dir), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Paired replay: {error}\n')

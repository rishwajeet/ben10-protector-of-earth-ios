#!/usr/bin/env python3
"""Admit restored textures by how they relate to the player's own original pixels.

Every copy of RBNEG9 decodes to the same source textures, but model inference
rounds differently from one Mac to the next, so a restored texture cannot be
held to one exact hash. Instead each upscaled output is reduced back to its
source grid. Per region, the fingerprint records how far that reduction sits
from the original pixels (the residual) and how much detail the upscale added
inside each source texel. Rounding moves these values by a few hundredths of a
level; a different model, a wrong operation, a seam, a blank or a corrupted
region moves them far more. The contract holds only these per-region numbers,
never pixels.

    uv run --no-project --with-requirements requirements-personal.lock python \\
        tools/personal_texture_fingerprints.py record --game DIR --candidates DIR [--sign-parents FILE] --output FILE
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, outside_repo

CONTRACT = ROOT / 'reference/personal_texture_fingerprints.json'
SCHEMA = 'protector-native.personal-texture-fingerprints/v1'
REGIONS = 4       # at most 4 x 4 regions over the source grid
UNIT = 100        # stored values are hundredths of an 8-bit level
STRIP = 16        # source rows per pass, bounding memory for 4096-pixel outputs
ADMISSION = 'source-anchored-fingerprint'


def fingerprint(output, source):
    """Integer-exact per-region residual and detail of an opaque RGB upscale.

    `output` is (H, W, >=3) uint8 and `source` is (h, w, >=3) uint8 with H and W
    whole multiples of h and w. Returns rounded hundredths of a level.
    """
    import numpy as np
    H, W, h, w = output.shape[0], output.shape[1], source.shape[0], source.shape[1]
    if not (h and w) or H % h or W % w or H < h or W < w:
        raise BuildError('Fingerprints need a whole-number upscale of the source grid')
    sy, sx = H // h, W // w
    n = sy * sx
    rows = [(int(a[0]), int(a[-1]) + 1) for a in np.array_split(np.arange(h), min(REGIONS, h))]
    cols = [(int(a[0]), int(a[-1]) + 1) for a in np.array_split(np.arange(w), min(REGIONS, w))]
    residual = np.zeros((len(rows), len(cols), 3), np.int64)
    detail = np.zeros((len(rows), len(cols), 3), np.int64)
    row_region = np.zeros(h, np.int64)
    for index, (a, b) in enumerate(rows):
        row_region[a:b] = index
    for top in range(0, h, STRIP):
        bottom = min(top + STRIP, h)
        blocks = output[top * sy:bottom * sy, :, :3].astype(np.int64).reshape(bottom - top, sy, w, sx, 3)
        sums = blocks.sum(axis=(1, 3))                                   # (strip, w, 3), n x block mean
        texel_residual = sums - n * source[top:bottom, :, :3].astype(np.int64)
        texel_detail = np.abs(n * blocks - sums[:, None, :, None, :]).sum(axis=(1, 3))
        for strip_row in range(bottom - top):
            region = row_region[top + strip_row]
            for c, (a, b) in enumerate(cols):
                residual[region, c] += texel_residual[strip_row, a:b].sum(axis=0)
                detail[region, c] += texel_detail[strip_row, a:b].sum(axis=0)
    texels = np.array([[(rb - ra) * (cb - ca) for ca, cb in cols] for ra, rb in rows], np.int64)[:, :, None]
    # residual: mean of (block mean - source); detail: mean |pixel - block mean|.
    residual_levels = np.rint(residual * UNIT / (texels * n)).astype(int)
    detail_levels = np.rint(detail * UNIT / (texels * n * n)).astype(int)
    return {'regions': [len(rows), len(cols)], 'residual': residual_levels.ravel().tolist(),
            'detail': detail_levels.ravel().tolist()}


def picture_fingerprint(picture, source_rgba, source_width, source_height):
    import numpy as np
    output = np.asarray(picture.convert('RGB'))
    source = np.frombuffer(source_rgba, np.uint8).reshape(source_height, source_width, 4)
    return fingerprint(output, source)


def load_fingerprints(path=None):
    path = CONTRACT if path is None else path
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024**2:
        raise BuildError('Texture fingerprint contract is missing, linked or oversized')
    document = json.loads(path.read_text())
    tolerance = document.get('tolerance', {})
    if document.get('schema') != SCHEMA or document.get('unit') != UNIT or \
            set(tolerance) != {'residual', 'detail'} or \
            not all(type(v) is int and 1 <= v <= 100 for v in tolerance.values()):
        raise BuildError('Invalid texture fingerprint contract')
    for key, roles in document['entries'].items():
        for role, record in roles.items():
            if role not in ('output', 'sign-parent') or len(record.get('regions', [])) != 2:
                raise BuildError('Invalid fingerprint record: ' + key)
            count = record['regions'][0] * record['regions'][1] * 3
            if not all(isinstance(record.get(k), list) and len(record[k]) == count and
                       all(type(v) is int for v in record[k]) for k in ('residual', 'detail')):
                raise BuildError('Invalid fingerprint values: ' + key)
    return document, digest_file(path)


_cache = {}


def admit_fingerprint(entry, picture, source_rgba, role='output', contract=None):
    """Return a comparison record when the output matches its source-anchored fingerprint, else None."""
    if contract is None:
        if 'document' not in _cache:
            _cache['document'] = load_fingerprints()
        contract = _cache['document']
    document, contract_sha = contract
    record = document['entries'].get(entry['id'], {}).get(role)
    if record is None:
        return None
    if list(picture.size) != entry['dimensions'] and role == 'output':
        raise BuildError('Fingerprinted output has different dimensions')
    if picture.convert('RGBA').getextrema()[3] != (255, 255):
        return None
    actual = picture_fingerprint(picture, source_rgba, entry['source']['width'], entry['source']['height'])
    if actual['regions'] != record['regions']:
        return None
    deltas = {k: max(abs(a - b) for a, b in zip(actual[k], record[k])) for k in ('residual', 'detail')}
    if any(deltas[k] > document['tolerance'][k] for k in deltas):
        return None
    return {'admission': ADMISSION, 'role': role, 'fingerprint_contract_sha256': contract_sha,
            'max_residual_delta': deltas['residual'] / UNIT, 'max_detail_delta': deltas['detail'] / UNIT,
            'tolerance': {k: v / UNIT for k, v in document['tolerance'].items()}}


def within_bound(comparison):
    """Whether a non-exact output was admitted: a listed or private variant within one level, or its fingerprint."""
    if not isinstance(comparison, dict):
        return False
    if comparison.get('admission') == ADMISSION:
        return True
    error = comparison.get('max_channel_error')
    return type(error) is int and 0 <= error <= 1


def record(args):
    """Developer step: fingerprint every qualified neural-dependent output from the reviewed candidates."""
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    from tools.personal_texture_pipeline import inventory
    from tools.personal_textures import load_contract, source_pixels
    from tools.personal_texture_variants import admit as admit_variant
    game, candidates, output = outside_repo(args.game), outside_repo(args.candidates), args.output
    if output.exists() or output.is_symlink():
        raise BuildError('Write fingerprints to a new path')
    contract = load_contract()
    routing = inventory(pin_contracts=False)  # this step writes one of the pinned contracts
    wanted = {k for s in routing['stages'] if s['family'] in ('neural', 'thumbnails', 'signs') or
              s['family'] == 'grids' and s.get('plane') == 'rgb' for k in s['entries']}
    by_id = {e['id']: e for e in contract['entries']}
    packages = {}

    def source(entry):
        name = entry['occurrence']['package']
        if name not in packages:
            packages.clear()
            package = decode_package(game / 'files' / name)
            packages[name] = package, parse_relocation_commands(package.relocation, 'big', file_info_size=len(package.file_info))
        return source_pixels(entry, *packages[name])

    entries = {}
    for key in sorted(wanted, key=lambda k: (by_id[k]['occurrence']['package'], k)):
        entry = by_id[key]
        path = candidates / (key + '.png')
        with Image.open(path) as image:
            rgba = image.convert('RGBA')
            actual = hashlib.sha256(rgba.tobytes()).hexdigest()
            if actual != entry['reference_rgba8_sha256'] and admit_variant(entry, actual) is None:
                raise BuildError('Reviewed candidate is neither the selected pixels nor a listed variant: ' + key)
            entries[key] = {'output': picture_fingerprint(rgba, source(entry), entry['source']['width'],
                                                          entry['source']['height'])}
    if args.sign_parents:
        index = json.loads(outside_repo(args.sign_parents).read_text())
        for key, ref in index['entries'].items():
            with Image.open(outside_repo(Path(ref['path']))) as image:
                rgba = image.convert('RGBA')
                if hashlib.sha256(rgba.tobytes()).hexdigest() != ref['rgba8_sha256']:
                    raise BuildError('Private sign parent changed')
                entries[key]['sign-parent'] = picture_fingerprint(rgba, source(by_id[key]), by_id[key]['source']['width'],
                                                                   by_id[key]['source']['height'])
    document = {'schema': SCHEMA, 'unit': UNIT, 'regions_max': REGIONS,
                'policy': 'per-region residual against the original source and per-texel added detail; '
                          'admits other Macs\' numerical rounding, not a different treatment',
                'tolerance': {'residual': args.residual_tolerance, 'detail': args.detail_tolerance},
                'source_lock_sha256': digest_file(LOCK), 'entries': dict(sorted(entries.items()))}
    # Compact: about 1,500 records of 96 integers must stay inside the kit's per-file bound.
    output.write_text(json.dumps(document, separators=(',', ':')) + '\n')
    return {'entries': len(entries), 'sign_parents': sum('sign-parent' in v for v in entries.values()),
            'bytes': output.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    make = sub.add_parser('record')
    make.add_argument('--game', type=Path, required=True)
    make.add_argument('--candidates', type=Path, required=True)
    make.add_argument('--sign-parents', type=Path)
    make.add_argument('--residual-tolerance', type=int, required=True)
    make.add_argument('--detail-tolerance', type=int, required=True)
    make.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(record(args), indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(2, f'Texture fingerprints: {error}\n')


if __name__ == '__main__':
    main()

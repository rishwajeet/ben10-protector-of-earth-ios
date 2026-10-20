#!/usr/bin/env python3
"""Qualify saved connected-grid RGB outputs; public admission is hash-only.

Qualification rebuilds the complete original canvas and checks the exact crop,
model recipe, saved execution receipt and full-resolution reference. No inference
or generic numerical tolerance is enabled by the public registry.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, outside_repo, write_json
from tools.personal_geometry import identity
from tools.personal_texture_variants import POLICY, RBNEG9_DOL_SHA256, load_variants

CONTRACT = ROOT / 'reference/personal_grid_variants.json'
RECIPES = ROOT / 'reference/personal_texture_grids.json'


def load_grid_variants(path=None):
    document, sha = load_variants(CONTRACT if path is None else path)
    if document.get('family') != 'connected-grid-rgb' or \
            document.get('grid_contract_sha256') != digest_file(RECIPES) or len(document['entries']) > 48:
        raise BuildError('Grid variants belong to another connected-canvas contract')
    for row in document['entries'].values():
        if any(not isinstance(row.get(k), str) or not re.fullmatch(r'[0-9a-f]{64}', row[k])
               for k in ('grid_id', 'grid_recipe_sha256', 'crop_recipe_sha256')):
            raise BuildError('Grid variant lacks a pinned canvas and crop')
    return document, sha


def admit_grid(entry, actual, *, contract=None, recipe=None, grid=None):
    if entry.get('operation', {}).get('kind') != 'authored-treatment-pending' or \
            actual == entry['reference_rgba8_sha256']:
        return None
    document, contract_sha = load_grid_variants() if contract is None else contract
    record = document['entries'].get(entry['id'])
    if record is None:
        return None
    if recipe is None or grid is None:
        recipes = json.loads(RECIPES.read_text())
        matches = [r for r in recipes['entries'] if r['id'] == entry['id'] and r['plane'] == 'rgb']
        if len(matches) != 1:
            raise BuildError('Qualified grid output has no unique RGB route')
        recipe = matches[0]
        grid = recipes['grids'][recipe['grid']]
    if recipe['plane'] != 'rgb' or recipe['id'] != entry['id'] or \
            record['entry_sha256'] != identity(entry) or \
            record['reference_rgba8_sha256'] != entry['reference_rgba8_sha256'] or \
            record['grid_id'] != recipe['grid'] or grid['source_grid_sha256'] != recipe['grid'] or \
            record['grid_recipe_sha256'] != identity(grid) or record['crop_recipe_sha256'] != identity(recipe):
        raise BuildError('Grid qualification belongs to a different source, canvas, model or crop')
    matches = [v for v in record['variants'] if v['rgba8_sha256'] == actual]
    if not matches:
        return None
    variant = matches[0]
    if variant['components'] != entry['dimensions'][0] * entry['dimensions'][1] * 4:
        raise BuildError('Qualified grid variant dimensions differ')
    return {'admission': 'listed-output-sha256', 'comparison_this_run': False,
        'variant_family': 'connected-grid-rgb', 'variant_contract_sha256': contract_sha,
        'qualification_sha256': variant['qualification_sha256'], 'max_channel_error': 1,
        'alpha_exact': True, 'components': variant['components'],
        'changed_components': variant['changed_components'],
        'mean_channel_error': variant['total_absolute_error'] / variant['components']}


def qualify(args):
    from PIL import Image
    from tools.personal_texture_variants import qualification_session, compare_images
    from tools.personal_texture_grids import validate_grids, assemble
    from tools.personal_textures import source_pixels
    roots = [args.game, args.reference_index, args.output_dir, *args.cached_work]
    if any(p.is_symlink() for p in roots):
        raise BuildError('Grid qualification roots must not be links')
    game, index, output, *cached = map(outside_repo, roots)
    if not 1 <= len(cached) <= 32 or output.exists() or not output.parent.is_dir() or \
            any(output == p or output.is_relative_to(p) or p.is_relative_to(output)
                for p in [game, index, *cached]):
        raise BuildError('Use a new external qualification output separate from bounded inputs')
    session = qualification_session(game, index)
    recipes = json.loads(RECIPES.read_text())
    validate_grids(recipes, session.contract)
    selected = {e['id']: e for e in session.contract['entries']}
    recipe_sha = digest_file(RECIPES)
    candidates = {}
    for work in cached:
        owner_path = work / 'owner.json'
        if owner_path.is_symlink() or not owner_path.is_file():
            raise BuildError('Grid cache has no regular ownership receipt')
        owner = json.loads(owner_path.read_text())
        if owner.get('game') != str(game) or owner.get('grid_contract_sha256') != recipe_sha or \
                owner.get('source_lock_sha256') != digest_file(LOCK):
            raise BuildError('Grid cache belongs to other sources or recipes')
        for receipt in work.glob('receipt-rgb-*.json'):
            if receipt.is_symlink() or receipt.stat().st_size > 2 * 1024**2:
                raise BuildError('Grid execution receipt is linked or oversized')
            report = json.loads(receipt.read_text())
            if report.get('schema') != 'protector-native.personal-texture-grid-result/v1' or \
                    report.get('plane') != 'rgb' or report.get('owner_sha256') != digest_file(owner_path):
                raise BuildError('Invalid grid execution identity')
            for row in report['entries']:
                if row['id'] in candidates:
                    raise BuildError('Ambiguous duplicate grid execution output')
                candidates[row['id']] = (work / 'candidates' / (row['id'] + '.png'), receipt, row)
    wanted = [r for r in recipes['entries'] if r['plane'] == 'rgb']
    if set(candidates) != {r['id'] for r in wanted}:
        raise BuildError('Qualification requires all 48 selected RGB grid outputs')
    document = {'schema': 'protector-native.personal-texture-variants/v1',
        'family': 'connected-grid-rgb', 'title_dol_sha256': RBNEG9_DOL_SHA256,
        'source_lock_sha256': digest_file(LOCK), 'policy': POLICY,
        'grid_contract_sha256': recipe_sha, 'entries': {}}
    output.mkdir(mode=0o700)
    shutil.copyfile(Path(__file__), output / 'qualifier-source.py')
    (output / 'qualified').mkdir(mode=0o700)
    exact = 0
    for grid_key in sorted({r['grid'] for r in wanted}):
        grid = recipes['grids'][grid_key]
        original, coverage = assemble(grid, lambda plane: source_pixels(plane,
            *session.package(plane['occurrence']['package'])))
        del original, coverage
        for recipe in [r for r in wanted if r['grid'] == grid_key]:
            entry = selected[recipe['id']]
            candidate, receipt, row = candidates[entry['id']]
            ref = session.refs['entries'][entry['id']]
            reference = outside_repo(Path(ref['path']))
            paths = (candidate, reference, receipt)
            if any(p.is_symlink() or not p.is_file() or p.stat().st_size > 128 * 1024**2 for p in paths):
                raise BuildError('Grid qualification requires bounded regular inputs')
            hashes = {str(p): digest_file(p) for p in paths}
            if hashes[str(reference)] != ref['png_sha256'] or hashes[str(candidate)] != row['png_sha256']:
                raise BuildError('Grid candidate or selected reference changed')
            with Image.open(reference) as reviewed, Image.open(candidate) as picture:
                for im in (reviewed, picture):
                    if im.format != 'PNG' or list(im.size) != entry['dimensions'] or \
                            getattr(im, 'n_frames', 1) != 1 or im.getexif().get(274, 1) != 1 or \
                            im.convert('RGBA').getextrema()[3] != (255, 255):
                        raise BuildError('Grid image format, size or opaque alpha changed')
                metrics, expected, actual = compare_images(reviewed, picture)
            if expected != entry['reference_rgba8_sha256'] or actual != row['rgba8_sha256'] or \
                    metrics['max_channel_error'] > 1 or any(digest_file(p) != hashes[str(p)] for p in paths):
                raise BuildError('Grid output does not match the selected treatment within one RGB value')
            if actual == expected:
                exact += 1
                continue
            proof = {'schema': 'protector-native.private-grid-qualification/v1',
                'id': entry['id'], 'entry_sha256': identity(entry), 'grid_id': grid_key,
                'grid_recipe_sha256': identity(grid), 'crop_recipe_sha256': identity(recipe),
                'source_canvas_reassembled': True, 'source_lock_sha256': digest_file(LOCK),
                'comparison': metrics, 'reference_rgba8_sha256': expected,
                'candidate_rgba8_sha256': actual, 'input_sha256': hashes,
                'qualifier_sha256': digest_file(output / 'qualifier-source.py'),
                'fresh_neural_execution': False, 'publication_authorized': False}
            proof_path = output / 'qualified' / (entry['id'] + '.json')
            write_json(proof_path, proof)
            variant = {k: v for k, v in metrics.items() if k != 'mean_channel_error'}
            variant.update(rgba8_sha256=actual, qualification_sha256=digest_file(proof_path))
            document['entries'][entry['id']] = {k: proof[k] for k in
                ('entry_sha256', 'reference_rgba8_sha256', 'grid_id', 'grid_recipe_sha256', 'crop_recipe_sha256')}
            document['entries'][entry['id']]['variants'] = [variant]
    if digest_file(RECIPES) != recipe_sha or digest_file(Path(__file__)) != digest_file(output / 'qualifier-source.py'):
        raise BuildError('Grid qualification source changed during execution')
    public = output / 'public-contract.json'
    write_json(public, document)
    load_grid_variants(public)
    result = {'selected': len(wanted), 'exact': exact, 'qualified_variants': len(document['entries']),
        'public_contract_sha256': digest_file(public), 'fresh_neural_execution': False}
    write_json(output / 'receipt.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('game', 'reference-index', 'output-dir'):
        parser.add_argument('--' + field, type=Path, required=True)
    parser.add_argument('--cached-work', type=Path, required=True, action='append')
    try:
        print(json.dumps(qualify(parser.parse_args()), indent=2))
    except (OSError, ValueError, KeyError, ImportError) as error:
        parser.exit(2, f'Grid qualification: {error}\n')

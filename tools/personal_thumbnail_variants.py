#!/usr/bin/env python3
"""Qualify registered thumbnail bytes, binding them to their exact parent/crop.

Public admission uses hashes only. Private qualification reconstructs each crop
again, redecodes both original sources and independently compares final pixels.
It does not execute a model or admit other authored-treatment families.
"""
import argparse
import hashlib
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

CONTRACT = ROOT / 'reference/personal_thumbnail_variants.json'
RECIPES = ROOT / 'reference/personal_thumbnail_recipes.json'


def load_thumbnail_variants(path=None):
    document, sha = load_variants(CONTRACT if path is None else path)
    if document.get('family') != 'registered-thumbnails' or \
            document.get('thumbnail_contract_sha256') != digest_file(RECIPES) or len(document['entries']) > 34:
        raise BuildError('Thumbnail variants belong to a different registered recipe contract')
    for row in document['entries'].values():
        if not all(isinstance(row.get(k), str) and re.fullmatch(r'[0-9a-f]{64}', row[k])
                   for k in ('thumbnail_recipe_sha256', 'parent_entry_sha256')) or \
                not isinstance(row.get('parent_id'), str) or \
                not re.fullmatch(r'256x256-[0-9a-f]{64}', row['parent_id']):
            raise BuildError('Thumbnail variant lacks a pinned registered parent')
        for variant in row['variants']:
            if variant['components'] != 1024 * 1024 * 4 or \
                    not isinstance(variant.get('parent_rgba8_sha256'), str) or \
                    not re.fullmatch(r'[0-9a-f]{64}', variant['parent_rgba8_sha256']):
                raise BuildError('Thumbnail variant has invalid dimensions or parent pixels')
    return document, sha


def admit_thumbnail(entry, actual, *, contract=None, recipe=None, parent_entry=None, parent_hash=None):
    if entry.get('operation', {}).get('kind') != 'authored-treatment-pending' or \
            actual == entry['reference_rgba8_sha256']:
        return None
    document, contract_sha = load_thumbnail_variants() if contract is None else contract
    record = document['entries'].get(entry['id'])
    if record is None:
        return None
    if recipe is None:
        matches = [r for r in json.loads(RECIPES.read_text())['entries'] if r['id'] == entry['id']]
        if len(matches) != 1:
            raise BuildError('Qualified thumbnail has no unique current recipe')
        recipe = matches[0]
    if parent_entry is None:
        from tools.personal_textures import load_contract
        matches = [r for r in load_contract()['entries'] if r['id'] == recipe['parent']]
        if len(matches) != 1:
            raise BuildError('Qualified thumbnail parent is not selected')
        parent_entry = matches[0]
    if record['entry_sha256'] != identity(entry) or record['reference_rgba8_sha256'] != entry['reference_rgba8_sha256'] or \
            record['thumbnail_recipe_sha256'] != identity(recipe) or record['parent_id'] != recipe['parent'] or \
            parent_entry['id'] != recipe['parent'] or record['parent_entry_sha256'] != identity(parent_entry) or \
            entry['dimensions'] != [1024, 1024] or parent_entry['dimensions'] != [4096, 4096] or \
            parent_entry.get('operation', {}).get('kind') not in ('local-neutral', 'local-rgb-neutral'):
        raise BuildError('Thumbnail qualification belongs to a different source, crop or parent recipe')
    matches = [v for v in record['variants'] if v['rgba8_sha256'] == actual and
               (parent_hash is None or v['parent_rgba8_sha256'] == parent_hash)]
    if not matches:
        return None
    variant = matches[0]
    # A thumbnail cannot outlive withdrawal of its parent's numerical admission.
    from tools.personal_texture_variants import admit
    if variant['parent_rgba8_sha256'] != parent_entry['reference_rgba8_sha256'] and \
            admit(parent_entry, variant['parent_rgba8_sha256']) is None:
        raise BuildError('Qualified thumbnail parent is no longer admitted')
    return {'admission': 'listed-output-sha256', 'comparison_this_run': False,
        'variant_family': 'registered-thumbnail', 'variant_contract_sha256': contract_sha,
        'qualification_sha256': variant['qualification_sha256'],
        'parent_rgba8_sha256': variant['parent_rgba8_sha256'],
        'max_channel_error': 1, 'alpha_exact': True, 'components': variant['components'],
        'changed_components': variant['changed_components'],
        'mean_channel_error': variant['total_absolute_error'] / variant['components']}


def qualify(args):
    from PIL import Image
    from tools.personal_texture_variants import qualification_session, compare_images, admit
    from tools.personal_textures import source_pixels
    from tools.personal_thumbnails import render, validate_thumbnails, ALGORITHMS
    roots = [args.game, args.candidates, args.parents, args.reference_index, args.output_dir]
    if any(p.is_symlink() for p in roots):
        raise BuildError('Thumbnail qualification roots must not be links')
    game, candidates, parents, index, output = map(outside_repo, roots)
    if output.exists() or not output.parent.is_dir() or any(output == p or output.is_relative_to(p) or
            p.is_relative_to(output) for p in (game, candidates, parents, index)):
        raise BuildError('Use a new external qualification directory separate from inputs')
    session = qualification_session(game, index)
    recipes = json.loads(RECIPES.read_text())
    validate_thumbnails(recipes, session.contract)
    selected = {e['id']: e for e in session.contract['entries']}
    algorithms = {p: digest_file(ROOT / p) for p in [*ALGORITHMS,
        'tools/personal_texture_variants.py', 'reference/personal_texture_variants.json',
        'reference/personal_thumbnail_recipes.json']}
    algorithms['tools/personal_thumbnail_variants.py'] = digest_file(Path(__file__))
    document = {'schema': 'protector-native.personal-texture-variants/v1',
        'family': 'registered-thumbnails', 'title_dol_sha256': RBNEG9_DOL_SHA256,
        'source_lock_sha256': digest_file(LOCK), 'policy': POLICY,
        'thumbnail_contract_sha256': digest_file(RECIPES), 'entries': {}}
    output.mkdir(mode=0o700)
    shutil.copyfile(Path(__file__), output / 'qualifier-source.py')
    proof_root = output / 'qualified'
    proof_root.mkdir(mode=0o700)
    exact = 0
    for recipe in recipes['entries']:
        entry, parent_entry = selected[recipe['id']], selected[recipe['parent']]
        original = source_pixels(entry, *session.package(entry['occurrence']['package']))
        source_pixels(parent_entry, *session.package(parent_entry['occurrence']['package']))
        candidate = candidates / (entry['id'] + '.png')
        parent_path = parents / (parent_entry['id'] + '.png')
        ref = session.refs['entries'][entry['id']]
        reference = outside_repo(Path(ref['path']))
        paths = (candidate, parent_path, reference)
        if any(p.is_symlink() or not p.is_file() or p.stat().st_size > 128 * 1024**2 for p in paths):
            raise BuildError('Thumbnail qualification requires bounded regular PNGs')
        hashes = {str(p): digest_file(p) for p in paths}
        if hashes[str(reference)] != ref['png_sha256']:
            raise BuildError('Selected thumbnail reference changed')
        with Image.open(parent_path) as parent, Image.open(candidate) as picture, Image.open(reference) as reviewed:
            for im, dimensions in ((parent, [4096, 4096]), (picture, [1024, 1024]), (reviewed, [1024, 1024])):
                if im.format != 'PNG' or list(im.size) != dimensions or getattr(im, 'n_frames', 1) != 1 or im.getexif().get(274, 1) != 1:
                    raise BuildError('Thumbnail qualification input format differs')
            rgba = parent.convert('RGBA')
            if rgba.getextrema()[3] != (255, 255):
                raise BuildError('Thumbnail parent acquired alpha')
            parent_hash = hashlib.sha256(rgba.tobytes()).hexdigest()
            del rgba
            if parent_hash != parent_entry['reference_rgba8_sha256'] and admit(parent_entry, parent_hash) is None:
                raise BuildError('Reconstructed parent is not independently qualified')
            rebuilt = render(Image.frombytes('RGBA', (64, 64), original), parent, recipe)
            rebuilt_hash = hashlib.sha256(rebuilt.convert('RGBA').tobytes()).hexdigest()
            metrics, expected, actual = compare_images(reviewed, picture)
        if actual != rebuilt_hash or expected != entry['reference_rgba8_sha256'] or metrics['max_channel_error'] > 1:
            raise BuildError('Thumbnail is not the registered reconstruction of the selected treatment')
        if any(digest_file(p) != hashes[str(p)] for p in paths):
            raise BuildError('Thumbnail qualification input changed during comparison')
        if actual == expected:
            exact += 1
            continue
        proof = {'schema': 'protector-native.private-thumbnail-qualification/v1',
            'id': entry['id'], 'entry_sha256': identity(entry), 'thumbnail_recipe_sha256': identity(recipe),
            'parent_entry_sha256': identity(parent_entry), 'parent_rgba8_sha256': parent_hash,
            'reference_rgba8_sha256': expected, 'candidate_rgba8_sha256': actual,
            'source_lock_sha256': digest_file(LOCK), 'source_pixels_redecoded': True,
            'registered_crop_rebuilt': True, 'comparison': metrics, 'input_png_sha256': hashes,
            'algorithms': algorithms, 'fresh_neural_execution': False, 'publication_authorized': False}
        proof_path = proof_root / (entry['id'] + '.json')
        write_json(proof_path, proof)
        variant = {k: v for k, v in metrics.items() if k != 'mean_channel_error'}
        variant.update(rgba8_sha256=actual, parent_rgba8_sha256=parent_hash,
                       qualification_sha256=digest_file(proof_path))
        document['entries'][entry['id']] = {'entry_sha256': identity(entry),
            'reference_rgba8_sha256': expected, 'thumbnail_recipe_sha256': identity(recipe),
            'parent_id': parent_entry['id'], 'parent_entry_sha256': identity(parent_entry), 'variants': [variant]}
    session.package.cache_clear()
    if digest_file(RECIPES) != document['thumbnail_contract_sha256'] or any(digest_file(ROOT / p) != sha for p, sha in algorithms.items()):
        raise BuildError('Thumbnail qualification recipes changed while running')
    public = output / 'public-contract.json'
    write_json(public, document)
    load_thumbnail_variants(public)
    result = {'selected': len(recipes['entries']), 'exact': exact, 'qualified_variants': len(document['entries']),
              'public_contract_sha256': digest_file(public), 'fresh_neural_execution': False}
    write_json(output / 'receipt.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('game', 'candidates', 'parents', 'reference-index', 'output-dir'):
        parser.add_argument('--' + field, type=Path, required=True)
    try:
        print(json.dumps(qualify(parser.parse_args()), indent=2))
    except (OSError, ValueError, KeyError, ImportError) as error:
        parser.exit(2, f'Thumbnail qualification: {error}\n')

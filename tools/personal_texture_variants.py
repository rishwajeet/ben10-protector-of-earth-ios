#!/usr/bin/env python3
"""Admit only individually qualified neural pixel hashes, never a loose tolerance.

Qualification uses private originals/reference pixels. Runtime lookup uses only
source/recipe identities and hashes; it neither loads images nor starts models.
"""
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from protector_native.executable_truth import RBNEG9_DOL_SHA256
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_geometry import identity

CONTRACT = ROOT / 'reference/personal_texture_variants.json'
POLICY = 'listed-rgba8-sha256; independently-checked-max-error-1; exact-alpha'
NEURAL_KINDS = {'local-neutral', 'local-rgb-neutral'}


def load_variants(path=None):
    path = CONTRACT if path is None else path
    if path.is_symlink() or path.stat().st_size > 2 * 1024**2:
        raise BuildError('Numerical-variant contract is linked or oversized')
    document = json.loads(path.read_text())
    if document.get('schema') != 'protector-native.personal-texture-variants/v1' or \
            document.get('title_dol_sha256') != RBNEG9_DOL_SHA256 or document.get('policy') != POLICY or \
            document.get('source_lock_sha256') != digest_file(LOCK) or \
            not isinstance(document.get('entries'), dict) or len(document['entries']) > 1406:
        raise BuildError('Invalid source-bound numerical-variant contract')
    def sha(value):
        return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)
    for key, row in document['entries'].items():
        if not re.fullmatch(r'[1-9][0-9]*x[1-9][0-9]*-[0-9a-f]{64}', key) or \
                not sha(row.get('entry_sha256')) or not sha(row.get('reference_rgba8_sha256')) or \
                not isinstance(row.get('variants'), list) or not 1 <= len(row['variants']) <= 8:
            raise BuildError('Invalid recipe-bound variant entry')
        seen = set()
        for variant in row['variants']:
            digest = variant.get('rgba8_sha256')
            components, changed = variant.get('components'), variant.get('changed_components')
            if not sha(digest) or digest in seen or digest == row['reference_rgba8_sha256'] or \
                    not sha(variant.get('qualification_sha256')) or variant.get('alpha_exact') is not True or \
                    type(components) is not int or not 4 <= components <= 4096 * 4096 * 4 or \
                    type(changed) is not int or not 1 <= changed <= components * 3 // 4 or \
                    type(variant.get('max_channel_error')) is not int or variant['max_channel_error'] != 1 or \
                    type(variant.get('total_absolute_error')) is not int or variant['total_absolute_error'] != changed:
                raise BuildError('Variant lacks bounded one-component/exact-alpha evidence')
            seen.add(digest)
    return document, digest_file(path)


def admit(entry, actual, *, contract=None):
    if entry.get('operation', {}).get('kind') == 'authored-treatment-pending':
        from tools.personal_thumbnail_variants import admit_thumbnail
        from tools.personal_grid_variants import admit_grid
        return admit_thumbnail(entry, actual) or admit_grid(entry, actual)
    if entry.get('operation', {}).get('kind') not in NEURAL_KINDS or actual == entry['reference_rgba8_sha256']:
        return None
    document, contract_sha = load_variants() if contract is None else contract
    row = document['entries'].get(entry['id'])
    if row is None:
        return None
    if row['entry_sha256'] != identity(entry) or row['reference_rgba8_sha256'] != entry['reference_rgba8_sha256']:
        raise BuildError('Qualified variant belongs to a different selected source or recipe')
    matches = [v for v in row['variants'] if v['rgba8_sha256'] == actual]
    if not matches:
        return None
    variant = matches[0]
    if variant['components'] != entry['dimensions'][0] * entry['dimensions'][1] * 4:
        raise BuildError('Qualified variant has different output dimensions')
    return {'admission': 'listed-output-sha256', 'comparison_this_run': False,
        'variant_contract_sha256': contract_sha, 'qualification_sha256': variant['qualification_sha256'],
        'max_channel_error': 1, 'alpha_exact': True,
        'changed_components': variant['changed_components'], 'components': variant['components'],
        'mean_channel_error': variant['total_absolute_error'] / variant['components']}


def compare_images(reference, candidate):
    """Hash and compare bounded strips, avoiding full-frame int16 temporaries."""
    import numpy as np
    if reference.size != candidate.size or not all(1 <= v <= 4096 for v in reference.size):
        raise BuildError('Numerical comparison dimensions differ or exceed bounds')
    reference, candidate = reference.convert('RGBA'), candidate.convert('RGBA')
    reference_hash, candidate_hash = hashlib.sha256(), hashlib.sha256()
    changed = total = maximum = 0
    width, height = reference.size
    for y in range(0, height, 64):
        box = (0, y, width, min(y + 64, height))
        a, b = np.asarray(reference.crop(box)), np.asarray(candidate.crop(box))
        reference_hash.update(a.tobytes())
        candidate_hash.update(b.tobytes())
        if not np.array_equal(a[:, :, 3], b[:, :, 3]):
            raise BuildError('Numerical tolerance cannot change alpha coverage')
        difference = np.abs(a.astype(np.int16) - b.astype(np.int16))
        maximum = max(maximum, int(difference.max()))
        changed += int(np.count_nonzero(difference))
        total += int(difference.sum(dtype=np.int64))
    components = width * height * 4
    return ({'max_channel_error': maximum, 'changed_components': changed,
        'components': components, 'total_absolute_error': total, 'alpha_exact': True,
        'mean_channel_error': total / components}, reference_hash.hexdigest(), candidate_hash.hexdigest())


def qualification_session(game, index):
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    from tools.personal_textures import load_contract, validate_contract
    contract = load_contract()
    validate_contract(contract)
    if contract['source_lock_sha256'] != digest_file(LOCK):
        raise BuildError('Selected recipes refer to a different original-content lock')
    refs = {'entries': {}}
    if index is not None:
        refs = json.loads(index.read_text())
        if refs['schema'] != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private reference index')
    check_table(game, json.loads(LOCK.read_text())['game'])
    @lru_cache(maxsize=1)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    return SimpleNamespace(game=game, index=index, contract=contract, refs=refs, package=package)


def qualify(args, *, session=None):
    from PIL import Image
    from tools.personal_textures import source_pixels
    standalone = session is None
    session = session or qualification_session(outside_repo(args.game), outside_repo(args.reference_index))
    contract = session.contract
    entries = [e for e in contract['entries'] if e['id'] == args.entry]
    if len(entries) != 1 or entries[0]['operation']['kind'] not in NEURAL_KINDS:
        raise BuildError('Qualification currently covers explicitly selected main neural recipes only')
    entry = entries[0]
    if any(p.is_symlink() for p in (args.game, args.candidate, args.reference_index, args.execution_receipt, args.output_dir)):
        raise BuildError('Qualification inputs and output roots must not be links')
    game, candidate, index, prior, output = map(outside_repo,
        (args.game, args.candidate, args.reference_index, args.execution_receipt, args.output_dir))
    if game != session.game or index != session.index:
        raise BuildError('Qualification session belongs to different inputs')
    if output.exists() or not output.parent.is_dir() or any(output == p or output.is_relative_to(p) or
            p.is_relative_to(output) for p in (game, candidate, index, prior)):
        raise BuildError('Qualification requires a new external output separate from all inputs')
    reference = session.refs['entries'][entry['id']]
    if Path(reference['path']).is_symlink():
        raise BuildError('Private reference image is linked')
    ref_path = outside_repo(Path(reference['path']))
    if candidate.stat().st_size > 128 * 1024**2 or ref_path.stat().st_size > 128 * 1024**2 or \
            digest_file(ref_path) != reference['png_sha256']:
        raise BuildError('Private pixel inputs changed or are linked')
    source_pixels(entry, *session.package(entry['occurrence']['package']))
    candidate_sha, prior_sha = digest_file(candidate), digest_file(prior)
    recorded = [r for r in json.loads(prior.read_text())['entries'] if r['id'] == entry['id']]
    if len(recorded) != 1 or recorded[0]['png_sha256'] != candidate_sha:
        raise BuildError('Execution receipt does not identify these saved candidate bytes')
    with Image.open(ref_path) as reference_image, Image.open(candidate) as picture:
        if any(im.format != 'PNG' or getattr(im, 'n_frames', 1) != 1 or
                list(im.size) != entry['dimensions'] or im.getexif().get(274, 1) != 1
                for im in (reference_image, picture)):
            raise BuildError('Qualification requires selected-size, top-left single PNGs')
        metric, expected, actual = compare_images(reference_image, picture)
    if expected != entry['reference_rgba8_sha256'] or actual != recorded[0]['rgba8_sha256'] or \
            metric['max_channel_error'] != 1 or not metric['changed_components']:
        raise BuildError('This is not a newly checked one-UNORM variant of the selected pixels')
    if digest_file(candidate) != candidate_sha or digest_file(ref_path) != reference['png_sha256'] or digest_file(prior) != prior_sha:
        raise BuildError('Qualification inputs changed during comparison')
    evidence = {'schema': 'protector-native.private-texture-variant-qualification/v1',
        'id': entry['id'], 'entry_sha256': identity(entry), 'source_lock_sha256': digest_file(LOCK),
        'original_typed_source_redecoded': True, 'comparison': metric,
        'reference_rgba8_sha256': expected, 'candidate_rgba8_sha256': actual,
        'reference_png_sha256': reference['png_sha256'], 'candidate_png_sha256': candidate_sha,
        'reference_path': str(ref_path), 'candidate_path': str(candidate),
        'execution_receipt_sha256': prior_sha, 'qualifier_sha256': digest_file(Path(__file__)),
        'fresh_neural_execution': False, 'publication_authorized': False}
    output.mkdir(mode=0o700)
    if standalone:
        shutil.copyfile(Path(__file__), output / 'qualifier-source.py')
    receipt = output / 'qualification.json'
    write_json(receipt, evidence)
    variant = {k: v for k, v in metric.items() if k != 'mean_channel_error'}
    variant.update(rgba8_sha256=actual, qualification_sha256=digest_file(receipt))
    record = {'entry_sha256': identity(entry), 'reference_rgba8_sha256': expected, 'variants': [variant]}
    write_json(output / 'public-record.json', {entry['id']: record})
    return {'entry': entry['id'], 'rgba8_sha256': actual, 'max_channel_error': metric['max_channel_error'],
        'changed_components': metric['changed_components'], 'qualification_sha256': digest_file(receipt),
        'scope': 'checked saved candidate; no fresh inference or all-platform qualification'}


def qualify_cached(args):
    if any(p.is_symlink() for p in (args.game, args.reference_index, args.cached_work, args.output_dir)):
        raise BuildError('Cached qualification roots must not be links')
    game, index, cached, output = map(outside_repo,
        (args.game, args.reference_index, args.cached_work, args.output_dir))
    if output.exists() or not output.parent.is_dir() or any(output == p or output.is_relative_to(p) or
            p.is_relative_to(output) for p in (game, index, cached)):
        raise BuildError('Use a new external qualification output separate from inputs')
    if not 1 <= args.max_output_pixels <= 4096**2:
        raise BuildError('Qualification pixel budget must be positive and at most one 4K square')
    if any((cached / p).is_symlink() or not (cached / p).is_dir() for p in ('candidates', 'batch-receipts')):
        raise BuildError('Expected saved candidates and batch receipts, not linked directories')
    session = qualification_session(game, index)
    entries = {e['id']: e for e in session.contract['entries']}
    candidates, excluded = {}, set()
    receipts = sorted((cached / 'batch-receipts').glob('batch-*.json'))
    if not 1 <= len(receipts) <= 4096:
        raise BuildError('Expected bounded saved worker receipts')
    for path in receipts:
        if path.is_symlink() or path.stat().st_size > 2 * 1024**2:
            raise BuildError('Worker receipt is linked or oversized')
        for row in json.loads(path.read_text())['entries']:
            entry = entries.get(row['id'])
            if not entry or entry['operation']['kind'] not in NEURAL_KINDS or row.get('reference_pixels_exact') is not False:
                continue
            if entry['dimensions'][0] * entry['dimensions'][1] > args.max_output_pixels:
                excluded.add(entry['id'])
                continue
            candidates.setdefault(entry['id'], []).append((path, row))
    if not candidates:
        raise BuildError('No saved rounded candidates fall within this explicit pixel budget')
    document, _ = load_variants()
    output.mkdir(mode=0o700)
    shutil.copyfile(Path(__file__), output / 'qualifier-source.py')
    qualified = output / 'qualified'
    qualified.mkdir(mode=0o700)
    results = []
    for key in sorted(candidates, key=lambda k: (entries[k]['occurrence']['package'], k)):
        candidate = cached / 'candidates' / (key + '.png')
        if candidate.is_symlink():
            raise BuildError('Saved candidate is a link')
        sha = digest_file(candidate)
        matches = [(p, r) for p, r in candidates[key] if r['png_sha256'] == sha]
        if not matches or len({r['rgba8_sha256'] for _, r in matches}) != 1:
            raise BuildError('Saved candidate has no unambiguous execution receipt')
        folder = qualified / key
        result = qualify(SimpleNamespace(game=game, reference_index=index, entry=key,
            candidate=candidate, execution_receipt=matches[0][0], output_dir=folder), session=session)
        results.append(result)
        record = json.loads((folder / 'public-record.json').read_text())[key]
        previous = document['entries'].get(key)
        if previous:
            if any(previous[k] != record[k] for k in ('entry_sha256', 'reference_rgba8_sha256')):
                raise BuildError('Existing variant qualification belongs to a different recipe')
            # Retain the freshest independent proof for the same exact output;
            # other qualified output hashes stay intact.
            previous['variants'] = [v for v in previous['variants'] if v['rgba8_sha256'] != record['variants'][0]['rgba8_sha256']]
            previous['variants'].extend(record['variants'])
        else:
            document['entries'][key] = record
        if len(results) % 16 == 0 or len(results) == len(candidates):
            print(f'Qualified saved pixels: {len(results)}/{len(candidates)}; no inference', flush=True)
            write_json(output / 'progress.json', {'qualified': len(results), 'selected': len(candidates),
                'excluded_by_pixel_budget': len(excluded), 'fresh_neural_execution': False})
    session.package.cache_clear()
    path = output / 'public-contract.json'
    write_json(path, document)
    load_variants(path)
    return {'qualified_saved_variants': len(results), 'excluded_by_pixel_budget': len(excluded),
        'public_contract_sha256': digest_file(path), 'max_output_pixels': args.max_output_pixels,
        'fresh_neural_execution': False, 'publication_authorized': False}


def verify_known_cache(args):
    """Exercise the real worker cache gate without loading private references."""
    from tools.personal_textures import source_pixels
    from tools.replay_personal_texture_batches import cached_batch
    if args.reference_index is not None:
        raise BuildError('Known-hash verification must not receive a private reference index')
    if any(p.is_symlink() for p in (args.game, args.cached_work, args.output_dir)):
        raise BuildError('Known-cache verification roots must not be links')
    game, cached, output = map(outside_repo, (args.game, args.cached_work, args.output_dir))
    if output.exists() or not output.parent.is_dir() or any(output == p or output.is_relative_to(p) or
            p.is_relative_to(output) for p in (game, cached)):
        raise BuildError('Known-cache receipt output must be new and separate from inputs')
    document, contract_sha = load_variants()
    session = qualification_session(game, None)
    entries = {e['id']: e for e in session.contract['entries']}
    if not document['entries'] or any(k not in entries for k in document['entries']):
        raise BuildError('Known-hash registry is empty or belongs to different selected entries')
    def decode(entry):
        return source_pixels(entry, *session.package(entry['occurrence']['package']))
    results = []
    for key in sorted(document['entries'], key=lambda k: (entries[k]['occurrence']['package'], k)):
        receipt = cached_batch([entries[key]], cached, {}, decode)
        if receipt is None:
            raise BuildError('Known output is absent; verification never starts inference')
        results.extend(receipt['entries'])
        if len(results) % 32 == 0 or len(results) == len(document['entries']):
            print(f'Known-hash cache verified: {len(results)}/{len(document["entries"])}; no private references', flush=True)
    session.package.cache_clear()
    if digest_file(CONTRACT) != contract_sha:
        raise BuildError('Variant registry changed during cache verification')
    result = {'schema': 'protector-native.known-texture-cache-verification/v1',
        'selected': len(results), 'variant_contract_sha256': contract_sha,
        'source_lock_sha256': digest_file(LOCK), 'private_reference_images_loaded': False,
        'fresh_neural_execution': False, 'complete_runtime_pack': False,
        'exact_pixel_matches': sum(e['reference_pixels_exact'] for e in results),
        'listed_variant_matches': sum(not e['reference_pixels_exact'] for e in results), 'entries': results}
    output.mkdir(mode=0o700)
    write_json(output / 'receipt.json', result)
    return {k: v for k, v in result.items() if k != 'entries'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--entry')
    mode.add_argument('--cached-work', type=Path, help='Qualify saved rounded batch outputs without replay')
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--reference-index', type=Path)
    parser.add_argument('--execution-receipt', type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--max-output-pixels', type=int, default=1024**2,
        help='Cached-work pixel budget; larger candidates are explicitly excluded, not qualified')
    parser.add_argument('--verify-cache', action='store_true',
        help='Only verify registered saved outputs; no private references or inference are permitted')
    args = parser.parse_args()
    try:
        if args.cached_work and (args.candidate or args.execution_receipt) or not args.cached_work and not (args.candidate and args.execution_receipt):
            raise BuildError('Use saved-work mode or supply both the selected candidate and its execution receipt')
        if args.verify_cache:
            if not args.cached_work:
                raise BuildError('Known-cache verification requires --cached-work')
            result = verify_known_cache(args)
        else:
            if not args.reference_index:
                raise BuildError('Qualification requires a private reference index')
            result = qualify_cached(args) if args.cached_work else qualify(args)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, ImportError) as error:
        parser.exit(2, f'Texture qualification: {error}\n')


if __name__ == '__main__':
    main()

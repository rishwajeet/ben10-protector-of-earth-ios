#!/usr/bin/env python3
"""Stage source-validated texture candidates for the existing delivery cookers.

No model calls or encoding. Batches preserve the selected raw/opaque/straight
lanes and keep runtime companion guards for final composition, never raw cooking.
"""
import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_geometry import identity
from tools.personal_texture_pipeline import inventory
from tools.personal_textures import compare_reference, load_contract, source_pixels
from tools.personal_texture_variants import admit as admit_variant


def delivery_plan(selected, routing):
    entries = {e['id']: e for e in selected['entries']}
    lanes, edges = {'opaque': [], 'straight': [], 'raw': []}, set()
    for entry in entries.values():
        fmt, alpha = entry['format'], entry['alpha_mode']
        if fmt == 'rgba8-unorm' and alpha == 'opaque':
            lane = 'raw'
        elif fmt == 'astc-4x4-ldr' and alpha == 'opaque':
            lane = 'opaque'
        elif fmt in ('astc-4x4-ldr', 'astc-4x4-ldr-rgba8-tail') and alpha == 'straight':
            lane = 'straight'
        else:
            raise BuildError('Unqualified selected texture delivery format')
        lanes[lane].append(entry)
        if not isinstance(entry.get('reference_rgba8_sha256') or
                (entry['reference_delivery_sha256'] if lane == 'raw' else None), str):
            raise BuildError('Selected texture has no raw pixel identity')
        neighbors = entry['required_companion_sources']
        if len(neighbors) != len(set(neighbors)) or len(neighbors) > 8:
            raise BuildError('Invalid bounded companion set')
        for other in neighbors:
            if other == entry['id'] or other not in entries or entry['id'] not in entries[other]['required_companion_sources']:
                raise BuildError('Selected companion guards are not reciprocal')
            edges.add(tuple(sorted((entry['id'], other))))
    batches = []
    for lane, rows in lanes.items():
        rows.sort(key=lambda e: e['id'])
        for start in range(0, len(rows), 64):
            subset = rows[start:start + 64]
            batches.append({'id': f'{lane}-{start // 64:03d}', 'lane': lane,
                'entries': [e['id'] for e in subset],
                'raw_bytes': sum(e['dimensions'][0] * e['dimensions'][1] * 4 for e in subset),
                'expected_formats': dict(Counter(e['format'] for e in subset))})
    if len(batches) > 64:
        raise BuildError('Delivery batches exceed the existing composition bound')
    return {'schema': 'protector-native.personal-texture-delivery-plan/v1',
        'contracts': routing['contracts'], 'batches': batches,
        'selected_entries': len(entries), 'lane_counts': {k: len(v) for k, v in lanes.items()},
        'raw_bytes': sum(b['raw_bytes'] for b in batches),
        'companion_pairs': [list(p) for p in sorted(edges)],
        'complete_runtime_pack': False, 'publication_authorized': False}


def candidates_for(entries, directories):
    if not 1 <= len(directories) <= 64:
        raise BuildError('Supply one through 64 explicit candidate directories')
    for directory in directories:
        if directory.is_symlink() or not directory.is_dir():
            raise BuildError('Candidate directory is missing or linked')
    candidates, missing = {}, []
    for entry in entries:
        choices = [p / (entry['id'] + '.png') for p in directories if (p / (entry['id'] + '.png')).exists()]
        if not choices:
            missing.append(entry['id'])
            continue
        if any(p.is_symlink() or not p.is_file() or p.stat().st_size > 128 * 1024**2 for p in choices):
            raise BuildError('Candidate is linked, non-file or exceeds its size bound')
        hashes = {digest_file(p) for p in choices}
        if len(hashes) != 1:
            raise BuildError('Conflicting candidate copies for ' + entry['id'])
        candidates[entry['id']] = (choices[0], hashes.pop())
    if missing:
        raise BuildError(f'{len(missing)} selected candidates are missing; first: {missing[0]}')
    return candidates


def admitted_pixels(entry, path, expected_png, references, rounding_allowed):
    from PIL import Image
    if digest_file(path) != expected_png:
        raise BuildError('Candidate PNG changed during delivery staging')
    with Image.open(path) as image:
        if image.format != 'PNG' or getattr(image, 'n_frames', 1) != 1 or \
                list(image.size) != entry['dimensions'] or image.getexif().get(274, 1) != 1:
            raise BuildError('Candidate format, dimensions or orientation differ')
        rgba = image.convert('RGBA')
        if entry['alpha_mode'] == 'opaque' and rgba.getextrema()[3] != (255, 255):
            raise BuildError('Opaque delivery candidate acquired alpha')
        raw = rgba.tobytes()
        actual = hashlib.sha256(raw).hexdigest()
        expected = entry['reference_rgba8_sha256'] or entry['reference_delivery_sha256']
        comparison = None
        if actual != expected:
            comparison = admit_variant(entry, actual)
            if comparison is None:
                if not references or not rounding_allowed:
                    raise BuildError('Candidate pixels differ from the selected treatment')
                comparison = compare_reference(entry, rgba, references)
            if comparison['max_channel_error'] > 1:
                raise BuildError('Candidate exceeds the private numerical comparison bound')
    if digest_file(path) != expected_png:
        raise BuildError('Candidate changed while decoding')
    return raw, {'id': entry['id'], 'png_sha256': expected_png, 'rgba8_sha256': actual,
        'reference_pixels_exact': actual == expected, 'numerical_comparison': comparison}


def put_payload(path, raw):
    if path.is_symlink():
        raise BuildError('Delivery payload is a link')
    if path.exists():
        if path.stat().st_size != len(raw) or digest_file(path) != hashlib.sha256(raw).hexdigest():
            raise BuildError('Existing delivery payload differs; preserve it for inspection')
        return
    # Only final content-addressed payloads are reused. An interrupted temporary
    # write cannot masquerade as a completed payload on the next run.
    with tempfile.NamedTemporaryFile(prefix='pending-', dir=path.parent, delete=False) as stream:
        pending = Path(stream.name)
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(path)


def prepare(args, selected, routing, plan):
    from PIL import Image  # Verify the decoding dependency before any output.
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    matches = [b for b in plan['batches'] if b['id'] == args.batch]
    if len(matches) != 1:
        raise BuildError('Choose an exact delivery batch ID from plan')
    batch = matches[0]
    by_id = {e['id']: e for e in selected['entries']}
    entries = [by_id[k] for k in batch['entries']]
    if args.work_dir.is_symlink() or any(p.is_symlink() for p in args.candidates):
        raise BuildError('Output and candidate roots must not be links')
    game, work = outside_repo(args.game), outside_repo(args.work_dir)
    directories = [outside_repo(p) for p in args.candidates]
    inputs = [game, *directories]
    if args.numerical_reference:
        inputs.append(outside_repo(args.numerical_reference))
    if any(work == p or work.is_relative_to(p) or p.is_relative_to(work) for p in inputs):
        raise BuildError('Delivery workspace must be separate from all inputs')
    if not work.parent.is_dir():
        raise BuildError('Delivery workspace needs an existing external parent')
    candidates = candidates_for(entries, directories)
    references = {}
    if args.numerical_reference:
        record = json.loads(args.numerical_reference.read_text())
        if record['schema'] != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private numerical reference index')
        references = record['entries']
    rounded_ids = {k for s in routing['stages'] if s['family'] in ('neural', 'thumbnails') or
        s['family'] == 'grids' and s.get('plane') == 'rgb' for k in s['entries']}
    check_table(game, json.loads(LOCK.read_text())['game'])
    @lru_cache(maxsize=1)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    evidence = []
    # All selected sources and candidate pixels pass before the batch is created.
    for entry in entries:
        source_pixels(entry, *package(entry['occurrence']['package']))
        raw, result = admitted_pixels(entry, *candidates[entry['id']], references, entry['id'] in rounded_ids)
        evidence.append(result)
        del raw
    package.cache_clear()
    owner = {'schema': 'protector-native.personal-texture-delivery-work/v1',
        'game': str(game), 'plan_sha256': identity(plan)}
    if work.exists():
        if (work / 'owner.json').is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Delivery workspace belongs to different inputs or recipes')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    output = work / batch['id']
    if output.is_symlink():
        raise BuildError('Delivery batch output is a link')
    needed = batch['raw_bytes'] + 5 * 1024**3
    if shutil.disk_usage(work).free < needed:
        raise BuildError('Delivery staging needs batch raw bytes plus 5 GiB free headroom')
    output.mkdir(mode=0o700, exist_ok=True)
    payloads = output / 'textures'
    if payloads.is_symlink():
        raise BuildError('Delivery texture directory is a link')
    payloads.mkdir(mode=0o700, exist_ok=True)
    source_record = {'schema': 'protector-native.personal-texture-delivery-sources/v1',
        'title_dol_sha256': selected['title_dol_sha256'], 'source_lock_sha256': digest_file(LOCK),
        'validation': 'complete original file table and freshly decoded typed original planes',
        'entries': [{'id': e['id'], 'source': e['source'], 'occurrence': e['occurrence']} for e in entries]}
    source_path = output / 'sources.json'
    write_json(source_path, source_record)
    output_entries = []
    for entry, admitted in zip(entries, evidence, strict=True):
        raw, checked = admitted_pixels(entry, *candidates[entry['id']], references, entry['id'] in rounded_ids)
        if checked != admitted:
            raise BuildError('Candidate admission changed after preflight')
        sha = admitted['rgba8_sha256']
        relative = f'textures/{sha}.rgba'
        put_payload(output / relative, raw)
        replacement = {'width': entry['dimensions'][0], 'height': entry['dimensions'][1],
            'format': 'rgba8-unorm', 'alpha_mode': entry['alpha_mode'], 'byte_length': len(raw),
            'sha256': sha, 'path': relative, 'source_png_sha256': admitted['png_sha256']}
        if entry['alpha_mode'] == 'straight':
            replacement['mip_filter'] = 'alpha-weighted-box-unorm-v1'
        output_entries.append({'source': entry['source'], 'replacement': replacement,
            'treatment': entry['treatment'], 'source_occurrences': [entry['occurrence']],
            'provenance': {'method': entry['selected_method'],
                'selected_provenance_sha256': entry['provenance_sha256'],
                'delivery_plan_sha256': identity(plan)}})
        del raw
    if any(digest_file(ROOT / p) != sha for p, sha in plan['contracts'].items()):
        raise BuildError('Selected contracts changed during staging; payloads retained')
    report = {'schema': 'protector-native.texture-pack/v4', 'pack_id': 'personal-' + batch['id'],
        'title_dol_sha256': selected['title_dol_sha256'], 'status': 'candidate',
        'scope': 'source-validated selected raw batch; cooking and full companion composition remain separate',
        'sources_sha256': digest_file(source_path), 'recipe_sha256': identity(plan), 'entries': output_entries}
    pack = output / 'pack.json'
    if pack.is_symlink() or pack.exists() and json.loads(pack.read_text()) != report:
        raise BuildError('Existing batch manifest differs; completed payloads retained')
    write_json(pack, report)
    result = {'schema': 'protector-native.personal-texture-delivery-result/v1',
        'batch': batch['id'], 'selected': len(entries), 'raw_bytes': batch['raw_bytes'],
        'exact_pixel_matches': sum(e['reference_pixels_exact'] for e in evidence),
        'entries': evidence, 'pack_sha256': digest_file(pack),
        'assembler_sha256': digest_file(Path(__file__)),
        'complete_runtime_pack': False, 'publication_authorized': False}
    write_json(output / 'receipt.json', result)
    return {k: v for k, v in result.items() if k != 'entries'}


def check_delivery_entries(batch, selected, document, *, raw=False):
    wanted = {e['id']: e for e in selected['entries'] if e['id'] in batch['entries']}
    actual = {}
    for row in document['entries']:
        src = row['source']
        key = f"{src['width']}x{src['height']}-{src['rgba8_sha256']}"
        if key in actual or key not in wanted or src != wanted[key]['source']:
            raise BuildError('Delivery pack has duplicate, foreign or changed source identities')
        entry, replacement = wanted[key], row['replacement']
        if [replacement['width'], replacement['height']] != entry['dimensions'] or \
                replacement['alpha_mode'] != entry['alpha_mode'] or \
                replacement['format'] != ('rgba8-unorm' if raw else entry['format']):
            raise BuildError('Delivery dimensions, selected format or alpha mode changed')
        actual[key] = row
    if set(actual) != set(wanted):
        raise BuildError('Delivery batch is incomplete')
    return actual


def assemble(args, selected, routing, plan):
    from tools.cook_texture_pack import read_source_pack
    from tools.compose_texture_packs import compose
    roots = [args.game, args.work_dir, args.cooked_dir, args.output]
    if any(p.is_symlink() for p in roots):
        raise BuildError('Assembly roots must not be links')
    game, work, cooked, output = map(outside_repo, roots)
    if output.exists() or not output.parent.is_dir() or any(output == p or output.is_relative_to(p) or
            p.is_relative_to(output) for p in (game, work, cooked)):
        raise BuildError('Final output must be new and separate from all inputs')
    paths = [(batch, work / batch['id'] / 'pack.json',
        (work if batch['lane'] == 'raw' else cooked) / batch['id'] / 'pack.json') for batch in plan['batches']]
    if any(not p.is_file() or p.is_symlink() or p.parent.is_symlink() for _, raw, final in paths for p in (raw, final)):
        raise BuildError('All staged and cooked delivery batches are required before assembly')
    owner = {'schema': 'protector-native.personal-texture-delivery-work/v1',
        'game': str(game), 'plan_sha256': identity(plan)}
    if json.loads((work / 'owner.json').read_text()) != owner:
        raise BuildError('Assembly workspace belongs to different inputs or recipes')
    check_table(game, json.loads(LOCK.read_text())['game'])
    encoder = json.loads((ROOT / 'reference/personal_tool_sources.json').read_text())['resources']['astcenc.zip']['binary_sha256']
    pairs, inputs, payload_bytes = plan['companion_pairs'], [], 0
    allowed_rounding = {k for s in routing['stages'] if s['family'] in ('neural', 'thumbnails') or
        s['family'] == 'grids' and s.get('plane') == 'rgb' for k in s['entries']}
    selected_ids = {e['id']: e for e in selected['entries']}
    for batch, raw_path, final_path in paths:
        raw, _ = read_source_pack(raw_path, allow_straight=True)
        raw_entries = check_delivery_entries(batch, selected, raw, raw=True)
        source_path = raw_path.parent / 'sources.json'
        if digest_file(source_path) != raw['sources_sha256'] or raw['recipe_sha256'] != identity(plan):
            raise BuildError('Staged source evidence or selected recipe changed')
        receipt = json.loads((raw_path.parent / 'receipt.json').read_text())
        records = {e['id']: e for e in receipt['entries']}
        if receipt['pack_sha256'] != digest_file(raw_path) or set(records) != set(raw_entries) or \
                len(receipt['entries']) != len(raw_entries):
            raise BuildError('Staging receipt does not cover this exact raw batch')
        for key, row in raw_entries.items():
            expected = selected_ids[key]['reference_rgba8_sha256'] or selected_ids[key]['reference_delivery_sha256']
            actual = row['replacement']['sha256']
            evidence = records[key]
            if evidence['rgba8_sha256'] != actual:
                raise BuildError('Staged pixel admission changed')
            comparison = evidence.get('numerical_comparison') or {}
            if comparison.get('admission') == 'listed-output-sha256' and admit_variant(selected_ids[key], actual) is None:
                raise BuildError('Staged output is no longer an admitted numerical variant')
            if actual != expected and (key not in allowed_rounding or evidence.get('reference_pixels_exact') is not False or
                    not isinstance(evidence.get('numerical_comparison'), dict) or
                    not 0 <= evidence['numerical_comparison'].get('max_channel_error', 256) <= 1):
                raise BuildError('Unadmitted pixel variation in staged batch')
        final = json.loads(final_path.read_text())
        delivered = check_delivery_entries(batch, selected, final)
        payload_bytes += sum(e['replacement']['byte_length'] for e in final['entries'])
        if batch['lane'] != 'raw':
            if final.get('raw_pack_sha256') != digest_file(raw_path) or \
                    final.get('cooking', {}).get('encoder_sha256') != encoder or \
                    final.get('sources_sha256') != raw['sources_sha256']:
                raise BuildError('Cooked batch has a different source or encoder')
            for key, row in delivered.items():
                if row['replacement'].get('uncompressed_rgba8_sha256') != raw_entries[key]['replacement']['sha256'] or \
                        {k: v for k, v in row.items() if k != 'replacement'} != \
                        {k: v for k, v in raw_entries[key].items() if k != 'replacement'}:
                    raise BuildError('Cooked pixels or provenance do not identify staged candidates')
        inputs.append({'path': str(final_path), 'sha256': digest_file(final_path)})
    if any(digest_file(ROOT / p) != sha for p, sha in plan['contracts'].items()):
        raise BuildError('Texture contracts changed during assembly admission')
    if shutil.disk_usage(output.parent).free < payload_bytes + 5 * 1024**3:
        raise BuildError('Final composition needs payload bytes plus 5 GiB free headroom')
    recipe = {'schema': 'protector-native.texture-pack-composition/v5',
        'pack_id': 'personal-selected-textures', 'packs': inputs, 'companion_pairs': pairs}
    recipe_path = work / ('composition-' + identity(recipe) + '.json')
    write_json(recipe_path, recipe)
    result = compose(recipe_path, output)
    # The existing composer validates every payload/mip/codec receipt, including
    # dual-decode alpha policy, then adds reciprocal guards from this exact graph.
    by_id = {f"{e['source']['width']}x{e['source']['height']}-{e['source']['rgba8_sha256']}": e for e in result['entries']}
    if set(by_id) != set(selected_ids) or any(sorted(by_id[k].get('required_companion_sources', [])) !=
            sorted(e['required_companion_sources']) for k, e in selected_ids.items()):
        raise BuildError('Composed pack coverage or selected companion guards differ')
    receipt = {'schema': 'protector-native.personal-texture-assembly/v1', 'selected_entries': len(by_id),
        'companion_pairs': len(pairs), 'pack_sha256': digest_file(output / 'pack.json'),
        'delivery_plan_sha256': identity(plan), 'complete_selected_pack_assembled': True,
        'runtime_acceptance': 'not run by assembler', 'publication_authorized': False}
    write_json(output / 'assembly-receipt.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('plan', help='Describe delivery batches and companion constraints; no pixel reads')
    stage = sub.add_parser('prepare', help='Admit and stage exactly one raw delivery batch, without compression')
    stage.add_argument('--batch', required=True)
    stage.add_argument('--game', type=Path, required=True)
    stage.add_argument('--work-dir', type=Path, required=True)
    stage.add_argument('--candidates', type=Path, action='append', required=True)
    stage.add_argument('--numerical-reference', type=Path)
    finish = sub.add_parser('assemble', help='Compose only after all selected raw and cooked batches pass admission')
    finish.add_argument('--game', type=Path, required=True)
    finish.add_argument('--work-dir', type=Path, required=True)
    finish.add_argument('--cooked-dir', type=Path, required=True)
    finish.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        selected, routing = load_contract(), inventory()
        plan = delivery_plan(selected, routing)
        if args.action == 'prepare':
            result = prepare(args, selected, routing, plan)
        elif args.action == 'assemble':
            result = assemble(args, selected, routing, plan)
        else:
            result = {k: v for k, v in plan.items() if k not in ('contracts', 'companion_pairs', 'batches')}
            result['companion_pair_count'] = len(plan['companion_pairs'])
            result['batches'] = [{k: v for k, v in b.items() if k != 'entries'} |
                {'entry_count': len(b['entries'])} for b in plan['batches']]
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, ImportError, KeyboardInterrupt) as error:
        parser.exit(2, f'Texture delivery: {error or "interrupted; completed payloads retained"}\n')


if __name__ == '__main__':
    main()

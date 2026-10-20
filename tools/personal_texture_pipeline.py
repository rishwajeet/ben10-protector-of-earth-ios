#!/usr/bin/env python3
"""Inventory all selected texture routes, or explicitly run one isolated stage.

Planning never loads models or reads private pixels. A completed stage produces
candidates, not a cooked runtime pack or redistribution clearance.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, outside_repo, write_json
from tools.personal_textures import NEURAL, SUPPORTED, load_contract, validate_contract
from tools.replay_personal_texture_batches import pressure_limits, host_pressure, check_pressure, wait_worker

# family: contract suffix, schema suffix, entry count, worker, subcommand, lock
FAMILIES = {
    'pairs': ('texture_pairs', 'texture-pairs', 43, 'texture_pairs', '', 'personal'),
    'grids': ('texture_grids', 'texture-grids', 70, 'texture_grids', '', 'personal'),
    'thumbnails': ('thumbnail_recipes', 'thumbnails', 34, 'thumbnails', '', 'personal'),
    'vectors': ('vector_recipes', 'vectors', 31, 'vectors', '', 'personal-vectors'),
    'structural': ('structural_plates', 'structural-plates', 20, 'structural_plates', '', 'personal-vectors'),
    'atlases': ('atlas_recipes', 'atlases', 6, 'atlases', 'replay', 'personal-atlases'),
    'facades': ('facade_recipes', 'facades', 7, 'facades', 'replay', 'personal-vectors'),
    'finite': ('finite_recipes', 'finite-materials', 8, 'finite_materials', 'replay', 'personal-vectors'),
    'layered-atlases': ('layered_atlas_recipes', 'layered-atlases', 3, 'layered_atlases', 'replay', 'personal-vectors'),
    'signs': ('sign_recipes', 'signs', 3, 'signs', 'replay', 'personal-vectors'),
}
AUTHORED = {'vectors', 'structural', 'atlases', 'facades', 'finite', 'layered-atlases', 'signs'}


def inventory(selected=None, companions=None):
    selected = load_contract() if selected is None else selected
    validate_contract(selected)
    if selected['source_lock_sha256'] != digest_file(LOCK):
        raise BuildError('Original-content lock differs from texture index')
    files = ['reference/personal_texture_recipes.json', 'reference/personal_build_inputs.json',
        'reference/personal_texture_variants.json', 'reference/personal_thumbnail_variants.json',
        'reference/personal_grid_variants.json',
        *['reference/' + row['path'] for row in selected['entry_files']]]
    entries = {e['id']: e for e in selected['entries']}
    routes, stages = {}, []

    def stage(name, family, rows, neural=False, **extra):
        ids = sorted(r['id'] for r in rows)
        if not ids or len(ids) != len(set(ids)) or any(k in routes or k not in entries for k in ids):
            raise BuildError('Empty, repeated or unknown texture route: ' + name)
        routes.update({k: name for k in ids})
        stages.append({'id': name, 'family': family, 'entries': ids,
            'neural': neural, 'requires_private_authored_inputs': family in AUTHORED,
            'dependencies': [], **extra})

    for name, kinds in [('source', SUPPORTED - NEURAL), ('neural', NEURAL)]:
        stage(name, name, [e for e in entries.values() if e['operation']['kind'] in kinds],
            neural=name == 'neural', kinds=sorted(kinds))
    for family, (suffix, schema, count, _, _, _) in FAMILIES.items():
        path = 'reference/personal_' + suffix + '.json'
        files.append(path)
        contract = json.loads((ROOT / path).read_text()) if companions is None else companions[family]
        rows = contract.get('entries', [])
        if contract.get('schema') != 'protector-native.personal-' + schema + '/v1' or len(rows) != count or \
                any(contract.get(k) != selected[k] for k in
                    ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')):
            raise BuildError('Companion contract identity or coverage differs: ' + family)
        if any(r['id'] not in entries or entries[r['id']]['operation']['kind'] !=
                'authored-treatment-pending' for r in rows):
            raise BuildError('Companion route overlaps an implemented main operation')
        if family == 'grids':
            if any(r['plane'] not in ('rgb', 'coverage') or r['grid'] not in contract['grids'] or
                    not re.fullmatch(r'[0-9a-f]{64}', r['grid']) for r in rows):
                raise BuildError('Unknown grid plane or parent')
            stage('grid-coverage', family, [r for r in rows if r['plane'] == 'coverage'], plane='coverage')
            for grid in sorted({r['grid'] for r in rows if r['plane'] == 'rgb'}):
                stage('grid-rgb-' + grid, family,
                    [r for r in rows if r['plane'] == 'rgb' and r['grid'] == grid],
                    neural=True, plane='rgb', grid=grid)
        else:
            stage(family, family, rows, neural=family == 'signs')
        if family == 'thumbnails':
            if any(r['parent'] not in entries or r['parent'] == r['id'] for r in rows):
                raise BuildError('Unknown or cyclic thumbnail parent')
            stages[-1]['parent_entries'] = sorted({r['parent'] for r in rows})
    if set(routes) != set(entries):
        raise BuildError('Selected texture entries have no reconstruction route')
    for row in stages:
        row['dependencies'] = sorted({routes[k] for k in row.get('parent_entries', [])})
        if row['family'] == 'thumbnails' and any(k != 'neural' for k in row['dependencies']):
            raise BuildError('Thumbnail parent route changed; qualify its integration first')
        lock = FAMILIES[row['family']][5] if row['family'] in FAMILIES else 'personal'
        row['requirements'] = ['requirements-' + lock + '.lock']
        if row['family'] == 'signs':
            row['requirements'].append('requirements-personal.lock')
    families = {s['id']: s['family'] for s in stages}
    return {'schema': 'protector-native.personal-texture-pipeline/v1',
        'selected_entries': len(entries), 'routed_entries': len(routes),
        'companion_entries': sum(FAMILIES[k][2] for k in FAMILIES),
        'family_counts': dict(sorted(Counter(families[s] for s in routes.values()).items())),
        'contracts': {p: digest_file(ROOT / p) for p in files},
        'stages': stages, 'replay_verified': False, 'complete_runtime_pack': False,
        'publication_authorized': False}


def command_for(stage, args):
    """No shell, automatic model downloads, historical parents or implicit ML."""
    family = stage['family']
    device, rows = getattr(args, 'device', 'mps'), getattr(args, 'cpu_conv_output_rows', 0)
    tail_rows = getattr(args, 'cpu_tail_input_rows', 0)
    if device not in ('mps', 'cpu') or type(rows) is not int or not 0 <= rows <= 256 or (rows and device != 'cpu'):
        raise BuildError('Convolution rows must be 0 through 256 and require CPU execution')
    if type(tail_rows) is not int or not 0 <= tail_rows <= 256 or \
            (tail_rows and (device != 'cpu' or family != 'grids' or stage.get('plane') != 'rgb')):
        raise BuildError('Tail input rows must be 0 through 256 and are supported only for CPU RGB grids')
    if (device != 'mps' or rows) and family not in ('source', 'neural', 'grids'):
        raise BuildError('Explicit first-pass device/convolution rows are not supported by this companion stage')
    if stage['neural'] and not args.allow_neural:
        raise BuildError('Neural work is disabled; explicitly opt in with --allow-neural')
    if stage['neural'] and not args.model_dir:
        raise BuildError('This stage requires explicitly supplied pinned local model weights')
    work = args.work_dir / stage['id']
    if family in ('source', 'neural'):
        cmd = [sys.executable, str(ROOT / 'tools/replay_personal_texture_batches.py'),
            '--batch-size', '1' if family == 'neural' else '8']
        for kind in stage['kinds']:
            cmd.extend(['--kind', kind])
        # The batch runner owns its inference children; it must enforce the
        # thresholds itself so neither RSS nor interruption targets a wrapper.
        for name, value in (pressure_limits(args) or {}).items():
            if value is not None:
                cmd.extend(['--' + name.replace('_', '-'), str(value)])
    else:
        _, _, _, worker, subcommand, _ = FAMILIES[family]
        cmd = [sys.executable, str(ROOT / ('tools/personal_' + worker + '.py'))]
        if subcommand:
            cmd.append(subcommand)
    cmd.extend(['--game', str(args.game), '--work-dir', str(work)])
    if family in ('source', 'neural', 'grids'):
        cmd.extend(['--device', device, '--cpu-conv-output-rows', str(rows)])
    if family == 'grids':
        cmd.extend(['--cpu-tail-input-rows', str(tail_rows)])
        cmd.extend(['--plane', stage['plane']])
        if stage.get('grid'):
            cmd.extend(['--grid', stage['grid']])
    if stage['neural']:
        cmd.extend(['--model-dir', str(args.model_dir), '--provider', args.provider])
    if family in AUTHORED:
        if not args.authored_inputs:
            raise BuildError('This stage requires its separate private authored-input bundle')
        cmd.extend(['--authored-inputs', str(args.authored_inputs)])
    if family == 'thumbnails':
        parents = args.parent_candidates or [args.work_dir / 'neural' / 'candidates']
        if not all(p.is_dir() and not p.is_symlink() for p in parents):
            raise BuildError('Reconstruct full-art parents first, or supply their candidate directory')
        for parent in parents:
            cmd.extend(['--parent-candidates', str(parent)])
    if args.numerical_reference and family in ('source', 'neural', 'grids', 'thumbnails'):
        cmd.extend(['--numerical-reference', str(args.numerical_reference)])
    return cmd


def run_stage(plan, args):
    matches = [s for s in plan['stages'] if s['id'] == args.stage]
    if len(matches) != 1:
        raise BuildError('Select one exact stage ID from the inventory')
    stage = matches[0]
    limits = pressure_limits(args)
    if args.work_dir.is_symlink() or (args.work_dir / 'pipeline-owner.json').is_symlink():
        raise BuildError('Pipeline workspace and owner must not be links')
    args.game, args.work_dir = outside_repo(args.game), outside_repo(args.work_dir)
    inputs = [args.game, *args.parent_candidates]
    inputs.extend(p for p in (args.model_dir, args.authored_inputs, args.numerical_reference) if p)
    for path in inputs:
        path = outside_repo(path)
        if args.work_dir == path or args.work_dir.is_relative_to(path) or path.is_relative_to(args.work_dir):
            raise BuildError('Pipeline output must be separate from supplied inputs')
    command = command_for(stage, args)  # Refuse disabled/missing inputs before creating directories.
    guarded = limits and stage['family'] not in ('source', 'neural')
    baseline = host_pressure() if guarded else None
    if guarded:
        check_pressure(baseline, baseline, limits)
    owner = {'schema': 'protector-native.personal-texture-pipeline-work/v1',
        'game': str(args.game), 'contracts': plan['contracts']}
    if args.work_dir.exists():
        if json.loads((args.work_dir / 'pipeline-owner.json').read_text()) != owner:
            raise BuildError('Pipeline workspace belongs to different inputs or recipes')
    else:
        if not args.work_dir.parent.is_dir():
            raise BuildError('Pipeline workspace needs an existing parent')
        args.work_dir.mkdir(mode=0o700)
        write_json(args.work_dir / 'pipeline-owner.json', owner)
    print('Starting isolated stage: ' + stage['id'], flush=True)
    guard = None
    try:
        if guarded:
            worker = subprocess.Popen(command)
            status, guard = wait_worker(worker, limits, baseline)
            if status:
                raise subprocess.CalledProcessError(status, command)
        else:
            subprocess.run(command, check=True)
    except (KeyboardInterrupt, OSError, ValueError, subprocess.SubprocessError) as error:
        write_json(args.work_dir / ('failure-' + stage['id'] + '-' + str(time.time_ns()) + '.json'),
            {'schema': 'protector-native.personal-texture-stage-failure/v1',
             'stage': stage['id'], 'error_type': type(error).__name__, 'error': str(error) or 'interrupted',
             'resource_guard': getattr(error, 'resource_guard', guard),
             'complete_runtime_pack': False, 'publication_authorized': False})
        raise
    if any(digest_file(ROOT / p) != sha for p, sha in plan['contracts'].items()):
        raise BuildError('Texture contracts changed while stage ran; candidates retained')
    # The worker performs source, recipe, cache, and pixel admission. Never turn
    # its successful exit into an inferred full-pack or fresh-neural claim.
    result = {'schema': 'protector-native.personal-texture-stage-dispatch/v1',
        'stage': stage['id'], 'worker_exit_code': 0, 'requested_entries': len(stage['entries']),
        'worker_evidence_directory': str(args.work_dir / stage['id']),
        'complete_runtime_pack': False, 'publication_authorized': False}
    if guard is not None:
        result['resource_guard'] = guard
    write_json(args.work_dir / ('dispatch-' + stage['id'] + '.json'), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    plan_parser = sub.add_parser('plan', help='Check complete routing without loading models or source pixels')
    plan_parser.add_argument('--output', type=Path, help='New external JSON inventory file')
    run = sub.add_parser('run', help='Run only the explicitly selected stage in an isolated process')
    run.add_argument('--stage', required=True)
    run.add_argument('--game', type=Path, required=True)
    run.add_argument('--work-dir', type=Path, required=True)
    run.add_argument('--model-dir', type=Path)
    run.add_argument('--authored-inputs', type=Path)
    run.add_argument('--parent-candidates', type=Path, action='append', default=[])
    run.add_argument('--numerical-reference', type=Path)
    run.add_argument('--provider', choices=('cpu', 'coreml'), default='cpu')
    run.add_argument('--device', choices=('mps', 'cpu'), default='mps')
    run.add_argument('--cpu-conv-output-rows', type=int, default=0)
    run.add_argument('--cpu-tail-input-rows', type=int, default=0)
    run.add_argument('--allow-neural', action='store_true')
    run.add_argument('--max-worker-rss-mib', type=int, help='Sampled macOS RSS stop threshold, not a hard quota')
    run.add_argument('--max-swap-growth-mib', type=int, help='Stop if host swap grows beyond this stage baseline')
    run.add_argument('--min-memory-free-percent', type=int, help='Stop below the reported macOS free-memory percentage')
    args = parser.parse_args()
    try:
        plan = inventory()
        if args.action == 'run':
            result = run_stage(plan, args)
        else:
            if args.output:
                output = outside_repo(args.output)
                if output.exists() or output.is_symlink() or not output.parent.is_dir():
                    raise BuildError('Inventory output must be a new file under an existing external parent')
                write_json(output, plan)
            result = {k: v for k, v in plan.items() if k not in ('contracts', 'stages')}
            result['stages'] = [{k: v for k, v in s.items() if k not in ('entries', 'parent_entries')}
                | {'entry_count': len(s['entries'])} for s in plan['stages']]
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        parser.exit(2, f'Texture pipeline: {error or "interrupted; completed candidates retained"}\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Release inference memory between bounded personal-texture worker batches."""
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_geometry import identity
from tools.personal_textures import ALGORITHMS, NEURAL, SUPPORTED, compare_reference, load_contract, source_pixels, validate_contract
from tools.personal_texture_variants import admit as admit_variant


def host_pressure():
    """Read macOS pressure, failing closed if an opted-in guard is unavailable."""
    if sys.platform != 'darwin':
        raise BuildError('The optional swap/memory guard currently requires macOS')
    swap = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'vm.swapusage'], text=True, timeout=5)
    free = subprocess.check_output(['/usr/bin/memory_pressure', '-Q'], text=True, timeout=5)
    used = re.search(r'\bused\s*=\s*([0-9.]+)([KMG])\b', swap)
    available = re.search(r'System-wide memory free percentage:\s*([0-9]+)%', free)
    if used is None or available is None or not 0 <= int(available[1]) <= 100:
        raise BuildError('Cannot read the requested macOS memory guard')
    return {'swap_used_mib': float(used[1]) * {'K': 1 / 1024, 'M': 1, 'G': 1024}[used[2]],
            'memory_free_percent': int(available[1])}


def pressure_limits(args):
    values = {name: getattr(args, name, None) for name in
              ('max_worker_rss_mib', 'max_swap_growth_mib', 'min_memory_free_percent')}
    if any(v is not None and (type(v) is not int or v <= 0) for v in values.values()) or \
            (values['min_memory_free_percent'] or 0) > 100:
        raise BuildError('Memory guard limits must be positive; free percentage cannot exceed 100')
    return values if any(v is not None for v in values.values()) else None


def check_pressure(state, baseline, limits, rss_mib=0):
    if limits['max_swap_growth_mib'] is not None and \
            state['swap_used_mib'] - baseline['swap_used_mib'] > limits['max_swap_growth_mib']:
        raise BuildError('Swap-growth guard stopped replay; completed candidates remain reusable')
    if limits['min_memory_free_percent'] is not None and \
            state['memory_free_percent'] < limits['min_memory_free_percent']:
        raise BuildError('Available-memory guard stopped replay; completed candidates remain reusable')
    if limits['max_worker_rss_mib'] is not None and rss_mib > limits['max_worker_rss_mib']:
        raise BuildError('Worker-RSS guard stopped replay; completed candidates remain reusable')


def stop_worker(worker):
    """Stop only this spawned worker, never another app or a name-matched PID."""
    if worker.poll() is None:
        worker.send_signal(signal.SIGINT)
        try:
            worker.wait(timeout=10)
        except subprocess.TimeoutExpired:
            worker.kill()
            worker.wait()


def wait_worker(worker, limits=None, baseline=None):
    evidence = {'policy': limits, 'baseline': baseline, 'sample_interval_seconds': 2,
                'samples': 0, 'peak_sampled_rss_mib': 0, 'maximum_sampled_swap_growth_mib': 0,
                'minimum_sampled_memory_free_percent': None, 'hard_memory_quota': False}
    try:
        if limits is None:
            return worker.wait(), None
        while True:
            try:
                return worker.wait(timeout=2), evidence
            except subprocess.TimeoutExpired:
                state = host_pressure()
                rss = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(worker.pid)],
                                     capture_output=True, text=True, timeout=5)
                if rss.returncode or not rss.stdout.strip():
                    if worker.poll() is not None:
                        return worker.returncode, evidence
                    raise BuildError('Cannot read worker RSS; stopping the guarded worker')
                rss_mib = int(rss.stdout.strip()) / 1024
                evidence['samples'] += 1
                evidence['peak_sampled_rss_mib'] = max(evidence['peak_sampled_rss_mib'], rss_mib)
                evidence['maximum_sampled_swap_growth_mib'] = max(evidence['maximum_sampled_swap_growth_mib'],
                    state['swap_used_mib'] - baseline['swap_used_mib'])
                evidence['minimum_sampled_memory_free_percent'] = min(
                    evidence['minimum_sampled_memory_free_percent'] or 100, state['memory_free_percent'])
                check_pressure(state, baseline, limits, rss_mib)
    except (KeyboardInterrupt, OSError, ValueError, subprocess.SubprocessError) as error:
        error.resource_guard = evidence
        stop_worker(worker)
        raise


def cached_batch(batch, work, references, decode):
    """Revalidate pixels and typed original planes, without starting an ML worker."""
    from PIL import Image
    paths = [work / 'candidates' / (e['id'] + '.png') for e in batch]
    if not all(p.exists() for p in paths):
        return None
    if (work / 'candidates').is_symlink() or any(p.is_symlink() for p in paths):
        raise BuildError('Cached texture path is a link')
    started, results = time.monotonic(), []
    for entry, path in zip(batch, paths, strict=True):
        decode(entry)
        numerical = None
        with Image.open(path) as image:
            rgba = image.convert('RGBA')
            if image.format != 'PNG' or list(image.size) != entry['dimensions'] or rgba.getextrema()[3] != (255, 255):
                raise BuildError('Cached worker texture dimensions, format or alpha changed')
            actual = hashlib.sha256(rgba.tobytes()).hexdigest()
            if actual != entry['reference_rgba8_sha256']:
                numerical = admit_variant(entry, actual)
                if numerical is None and references and entry['operation']['kind'] in NEURAL:
                    numerical = compare_reference(entry, image, references)
                if numerical is None or numerical['max_channel_error'] > 1:
                    raise BuildError('Cached worker texture differs from current reference')
        results.append({'id': entry['id'], 'rgba8_sha256': actual, 'png_sha256': digest_file(path),
            'provider_this_run': None, 'reference_pixels_exact': actual == entry['reference_rgba8_sha256'],
            'numerical_comparison': numerical})
    rounded = sum(not r['reference_pixels_exact'] for r in results)
    return {'schema': 'protector-native.personal-texture-result/v1', 'selected': len(results),
        'exact_pixel_matches': len(results) - rounded, 'bounded_rounding_matches': rounded,
        'complete_pack': False, 'seconds': time.monotonic() - started,
        'execution': {'algorithms': {p: digest_file(ROOT / p) for p in ALGORITHMS},
            'cache_verifier_sha256': digest_file(Path(__file__)),
            'source_validation': 'complete original table plus typed selected plane decode'},
        'runtime': {'method': 'verified cached pixels; no model loaded'}, 'entries': results}


def run_batches(args):
    limits = pressure_limits(args)
    convolution_rows = getattr(args, 'cpu_conv_output_rows', 0)
    if type(convolution_rows) is not int or not 0 <= convolution_rows <= 256 or \
            (convolution_rows and getattr(args, 'device', 'mps') != 'cpu'):
        raise BuildError('CPU convolution rows must be 0 through 256 and require --device cpu')
    new_worker_limit = getattr(args, 'max_new_workers', None)
    if new_worker_limit is not None and (type(new_worker_limit) is not int or new_worker_limit < 1):
        raise BuildError('The new-worker limit must be a positive integer')
    baseline = host_pressure() if limits else None
    if limits:
        check_pressure(baseline, baseline, limits)
    contract = load_contract()
    validate_contract(contract)
    kinds = set(args.kind or SUPPORTED)
    requested = set(getattr(args, 'entry', None) or [])
    selected = sorted((e for e in contract['entries'] if e['operation']['kind'] in kinds and
        (not requested or e['id'] in requested)),
        key=lambda e: (e['occurrence']['package'], e['id']))
    if requested and {e['id'] for e in selected} != requested:
        raise BuildError('Requested worker source is unknown or excluded by its operation')
    if not selected or not 1 <= args.batch_size <= 8:
        raise BuildError('Select an implemented operation and one through eight entries per worker')
    deferred_requested = set(getattr(args, 'defer_entry', None) or [])
    if deferred_requested and (args.batch_size != 1 or not deferred_requested <= {e['id'] for e in selected}):
        raise BuildError('Deferral requires single-entry workers and exact selected source IDs')
    work = outside_repo(args.work_dir)
    if not work.parent.is_dir():
        raise BuildError('Worker directory needs an existing parent')
    game = outside_repo(args.game)
    if work == game or work.is_relative_to(game) or game.is_relative_to(work):
        raise BuildError('Worker output must be separate from original inputs')
    if contract['source_lock_sha256'] != digest_file(LOCK):
        raise BuildError('Original content lock changed')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if work.exists():
        owner = json.loads((work / 'owner.json').read_text())
        if work.is_symlink() or owner.get('game') != str(game) or \
                owner.get('source_lock_sha256', digest_file(LOCK)) != digest_file(LOCK):
            raise BuildError('Worker directory belongs to different original inputs')
    references = {}
    if args.numerical_reference:
        index = json.loads(outside_repo(args.numerical_reference).read_text())
        if index['schema'] != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private reference index')
        references = index['entries']
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    @lru_cache(maxsize=2)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    def decode(entry):
        return source_pixels(entry, *package(entry['occurrence']['package']))
    batch_count = (len(selected) + args.batch_size - 1) // args.batch_size
    summaries, results, new_workers = [], [], 0
    deferred, worker_limit_reached = [], False
    def checkpoint(status, **extra):
        write_json(work / 'batch-progress.json', {'schema': 'protector-native.personal-texture-batches/v1',
            'status': status, 'selected_entries': len(selected), 'completed_entries': len(results),
            'complete_texture_pack': len(results) == contract['entry_count'],
            'batch_size': args.batch_size, 'new_workers': new_workers,
            'deferred_sources': list(deferred), 'batches': summaries, **extra})
    for start in range(0, len(selected), args.batch_size):
        if shutil.disk_usage(work if work.exists() else work.parent).free < 10 * 1024**3:
            raise BuildError('Batch replay stopped below 10 GiB headroom; completed candidates remain reusable')
        batch = selected[start:start+args.batch_size]
        ids = [e['id'] for e in batch]
        command = [sys.executable, str(ROOT / 'tools/personal_textures.py'), '--game', str(args.game),
            '--work-dir', str(work), '--provider', args.provider,
            '--device', getattr(args, 'device', 'mps'),
            '--mps-memory-fraction', str(getattr(args, 'mps_memory_fraction', 0.5)),
            '--dat-window-batch-size', str(getattr(args, 'dat_window_batch_size', 0)),
            '--cpu-conv-output-rows', str(convolution_rows)]
        if args.model_dir:
            command.extend(['--model-dir', str(args.model_dir)])
        if args.numerical_reference:
            command.extend(['--numerical-reference', str(args.numerical_reference)])
        for key in ids:
            command.extend(['--entry', key])
        receipt = cached_batch(batch, work, references, decode)
        if receipt is None:
            if ids[0] in deferred_requested:
                deferred.extend(ids)
                print(f'Deferred incomplete source remains pending: {ids[0]}', flush=True)
                checkpoint('in-progress')
                continue
            if new_worker_limit is not None and new_workers >= new_worker_limit:
                print('Requested new-worker limit reached; remaining reconstruction is pending', flush=True)
                worker_limit_reached = True
                checkpoint('stopped-at-new-worker-limit')
                break
            guard = None
            try:
                if limits:
                    preflight = host_pressure()
                    guard = {'policy': limits, 'baseline': baseline, 'preflight': preflight,
                             'hard_memory_quota': False}
                    check_pressure(preflight, baseline, limits)
                print(f'Isolated texture worker {len(summaries)+1}/{batch_count}: {len(ids)} entries', flush=True)
                worker = subprocess.Popen(command)
                status, guard = wait_worker(worker, limits, baseline)
                if status:
                    raise BuildError(f'Texture worker stopped with exit {status}; earlier completed candidates retained')
            except (KeyboardInterrupt, OSError, ValueError, subprocess.SubprocessError) as error:
                failure = {'schema': 'protector-native.personal-texture-batch-failure/v1',
                    'sources': ids, 'error_type': type(error).__name__,
                    'error': str(error) or 'interrupted',
                    'mps_memory_fraction': getattr(args, 'mps_memory_fraction', 0.5),
                    'dat_window_batch_size': getattr(args, 'dat_window_batch_size', 0),
                    'cpu_conv_output_rows': convolution_rows,
                    'first_pass_device': getattr(args, 'device', 'mps'),
                    'resource_guard': getattr(error, 'resource_guard', guard),
                    'deferred_sources': list(deferred),
                    'completed_entries': len(results), 'selected_entries': len(selected),
                    'new_workers_completed': new_workers, 'complete_texture_pack': False}
                failure_name = f'batch-failure-{time.time_ns()}.json'
                write_json(work / failure_name, failure)
                checkpoint('stopped-on-worker-error', failure_receipt=failure_name)
                raise
            receipt = json.loads((work / 'receipt.json').read_text())
            if guard is not None:
                receipt['resource_guard'] = guard
            new_workers += 1
        elif len(summaries) % 25 == 0:
            print(f'Cached source/pixel verification: {start+len(batch)}/{len(selected)}', flush=True)
        if {e['id'] for e in receipt['entries']} != set(ids) or receipt['selected'] != len(ids):
            raise BuildError('Worker receipt does not match its requested sources')
        records = work / 'batch-receipts'
        records.mkdir(exist_ok=True)
        if records.is_symlink():
            raise BuildError('Batch receipt directory is a link')
        name = 'batch-' + identity(ids) + '.json'
        write_json(records / name, receipt)
        summaries.append({'sources': ids, 'receipt': name, 'seconds': receipt['seconds'],
            'exact_pixel_matches': receipt['exact_pixel_matches'],
            'bounded_rounding_matches': receipt['bounded_rounding_matches']})
        results.extend(receipt['entries'])
        checkpoint('complete-selected-operations' if len(results) == len(selected) else 'in-progress')
    if deferred and not worker_limit_reached:
        checkpoint('stopped-with-deferred-entries')
    return {'selected_entries': len(selected), 'completed_entries': len(results),
        'new_workers': new_workers, 'stopped_at_new_worker_limit': worker_limit_reached,
        'deferred_sources': deferred,
        'exact_pixel_matches': sum(s['exact_pixel_matches'] for s in summaries),
        'bounded_rounding_matches': sum(s['bounded_rounding_matches'] for s in summaries),
        'complete_texture_pack': len(results) == contract['entry_count']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--model-dir', type=Path)
    parser.add_argument('--kind', action='append', choices=sorted(SUPPORTED))
    parser.add_argument('--entry', action='append', help='Limit the batch to explicit selected source IDs')
    parser.add_argument('--defer-entry', action='append',
                        help='Keep this exact incomplete source pending while processing others; requires batch size 1')
    parser.add_argument('--batch-size', type=int, default=8)
    parser.add_argument('--provider', choices=('auto', 'cpu', 'coreml'), default='auto')
    parser.add_argument('--device', choices=('mps', 'cpu'), default='mps',
                        help='First-pass Torch device, separate from the ONNX provider')
    parser.add_argument('--mps-memory-fraction', type=float, default=0.5,
                        help='Torch MPS allocator fraction; positive and at most 0.5')
    parser.add_argument('--dat-window-batch-size', type=int, default=0,
                        help='Opt-in independent DAT window batching; 1-128, default off')
    parser.add_argument('--cpu-conv-output-rows', type=int, default=0,
                        help='Opt-in CPU DAT/ESRGAN convolution workspace bound; 1-256 output rows, default off')
    parser.add_argument('--numerical-reference', type=Path)
    parser.add_argument('--max-new-workers', type=int, help='Stop before another inference worker; cached entries are revalidated')
    parser.add_argument('--max-worker-rss-mib', type=int, help='Sampled macOS RSS stop threshold, not a hard quota')
    parser.add_argument('--max-swap-growth-mib', type=int, help='Stop if host swap grows beyond the run baseline')
    parser.add_argument('--min-memory-free-percent', type=int, help='Stop below the reported macOS free-memory percentage')
    args = parser.parse_args()
    try:
        print(json.dumps(run_batches(args), indent=2))
    except (OSError, ValueError, KeyboardInterrupt, subprocess.SubprocessError) as error:
        parser.exit(2, f'Batched texture replay: {error or "interrupted; completed candidates retained"}\n')

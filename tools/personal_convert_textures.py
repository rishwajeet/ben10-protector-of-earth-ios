#!/usr/bin/env python3
"""Run every texture reconstruction stage, then cook and assemble RestoredArt.

This only sequences the existing per-stage tools with the requirement locks the
plan names. Each underlying tool keeps its own admission, resume and failure
receipts; rerunning this command reuses completed work. Nothing is downloaded.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
AUTHORED_DIRECTORIES = {'vectors': 'vectors', 'structural': 'structural', 'atlases': 'atlases',
    'facades': 'facades', 'finite': 'finite', 'layered-atlases': 'layered-atlases', 'signs': 'signs'}
DELIVERY_LOCK = 'requirements-personal-delivery.lock'


def uv_python(locks):
    uv = shutil.which('uv')
    if not uv:
        raise SystemExit('uv is required on PATH')
    command = [uv, 'run', '--no-project']
    for lock in locks:
        command.extend(['--with-requirements', str(ROOT / lock)])
    return command + ['python']


def execute(command, dry_run):
    print('$ ' + ' '.join(str(part) for part in command), flush=True)
    if not dry_run:
        subprocess.run([str(part) for part in command], cwd=ROOT, check=True)


def stage_plan():
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / 'plan.json'
        subprocess.run([sys.executable, str(ROOT / 'tools/personal_texture_pipeline.py'), 'plan',
                        '--output', str(output)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        return json.loads(output.read_text())['stages']


def run_stages(args):
    stages = stage_plan()
    if args.stage:
        unknown = set(args.stage) - {stage['id'] for stage in stages}
        if unknown:
            raise SystemExit('Unknown stage: ' + ', '.join(sorted(unknown)))
        stages = [stage for stage in stages if stage['id'] in args.stage]
    for index, stage in enumerate(stages, 1):
        print(f'\n[{index}/{len(stages)}] {stage["id"]} ({stage["family"]})', flush=True)
        command = uv_python(stage['requirements']) + [ROOT / 'tools/personal_texture_pipeline.py', 'run',
            '--stage', stage['id'], '--game', args.game, '--work-dir', args.work_dir]
        if stage['neural']:
            command += ['--allow-neural', '--model-dir', args.model_dir]
        if stage['requires_private_authored_inputs']:
            command += ['--authored-inputs', args.authored_inputs / AUTHORED_DIRECTORIES[stage['family']]]
        execute(command, args.dry_run)


def deliver(args):
    batches = json.loads(subprocess.run([sys.executable, str(ROOT / 'tools/personal_texture_delivery.py'), 'plan'],
                                        cwd=ROOT, check=True, capture_output=True, text=True).stdout)['batches']
    candidates = sorted(path for path in args.work_dir.glob('*/candidates') if path.is_dir())
    if not candidates and not args.dry_run:
        raise SystemExit('No reconstructed candidates found; run the stages first')
    delivery, cooked = args.delivery_dir, args.cooked_dir
    for index, batch in enumerate(batches, 1):
        print(f'\n[{index}/{len(batches)}] {batch["id"]} ({batch["lane"]})', flush=True)
        prepare = uv_python([DELIVERY_LOCK]) + [ROOT / 'tools/personal_texture_delivery.py', 'prepare',
            '--batch', batch['id'], '--game', args.game, '--work-dir', delivery]
        for directory in candidates:
            prepare += ['--candidates', directory]
        execute(prepare, args.dry_run)
        if batch['lane'] == 'raw':
            continue
        target = cooked / batch['id']
        if (target / 'pack.json').is_file():
            print('Already cooked: ' + batch['id'], flush=True)
            continue
        if target.exists() and not args.dry_run:
            raise SystemExit(f'Interrupted cook left {target}; move it aside and rerun')
        tool = 'cook_texture_pack.py' if batch['lane'] == 'opaque' else 'cook_alpha_texture_pack.py'
        cook = uv_python([DELIVERY_LOCK]) + [ROOT / 'tools' / tool, delivery / batch['id'] / 'pack.json', target,
            '--encoder', args.astcenc]
        if batch['lane'] == 'opaque':
            cook += ['--block', '4', '--quality', 'thorough']
        execute(cook + ['--threads', str(args.threads)], args.dry_run)
    execute(uv_python([DELIVERY_LOCK]) + [ROOT / 'tools/personal_texture_delivery.py', 'assemble',
        '--game', args.game, '--work-dir', delivery, '--cooked-dir', cooked, '--output', args.output], args.dry_run)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    stages = sub.add_parser('stages', help='reconstruct every texture candidate')
    stages.add_argument('--game', type=Path, required=True, help='the extracted folder from personal_build.py prepare')
    stages.add_argument('--work-dir', type=Path, required=True)
    stages.add_argument('--model-dir', type=Path, required=True)
    stages.add_argument('--authored-inputs', type=Path, required=True, help='the unzipped authored-inputs bundle')
    stages.add_argument('--stage', action='append', help='run only this stage ID (repeatable)')
    stages.add_argument('--dry-run', action='store_true')
    finish = sub.add_parser('deliver', help='compress every batch and assemble RestoredArt')
    finish.add_argument('--game', type=Path, required=True)
    finish.add_argument('--work-dir', type=Path, required=True, help='the stages work directory')
    finish.add_argument('--delivery-dir', type=Path, required=True)
    finish.add_argument('--cooked-dir', type=Path, required=True)
    finish.add_argument('--output', type=Path, required=True, help='new RestoredArt folder')
    finish.add_argument('--astcenc', type=Path, required=True)
    finish.add_argument('--threads', type=int, default=max(1, min(8, (os.cpu_count() or 2) // 2)))
    finish.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    for name in ('game', 'work_dir', 'model_dir', 'authored_inputs', 'delivery_dir', 'cooked_dir', 'output', 'astcenc'):
        if getattr(args, name, None) is not None:
            setattr(args, name, getattr(args, name).expanduser().resolve())
    try:
        (run_stages if args.command == 'stages' else deliver)(args)
    except subprocess.CalledProcessError as error:
        parser.exit(2, f'Texture conversion stopped (exit {error.returncode}); completed work is kept. Fix the cause and rerun.\n')


if __name__ == '__main__':
    main()

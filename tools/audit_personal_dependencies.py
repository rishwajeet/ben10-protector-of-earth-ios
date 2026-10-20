#!/usr/bin/env python3
"""Inventory pinned Python metadata without importing inference libraries.

This is host/environment evidence, never redistribution or security clearance.
Run in each selected locked environment. No packages or models are downloaded
by this tool. Missing distributions remain explicit rather than being inferred.
Notice collection is optional; upstream licence texts are fetched only with the
explicit --fetch-missing-notices flag and checked against version-pinned hashes.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata as metadata
import json
from pathlib import Path, PurePosixPath
import re
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.personal_build import BuildError, outside_repo, write_json

SUPPLEMENTAL_NOTICES = {
    ('flatbuffers', '25.12.19'): {
        'url': 'https://raw.githubusercontent.com/google/flatbuffers/v25.12.19/LICENSE',
        'bytes': 11358,
        'sha256': 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'},
    ('spandrel', '0.4.2'): {
        'url': 'https://raw.githubusercontent.com/chaiNNer-org/spandrel/v0.4.2/LICENSE',
        'bytes': 1069,
        'sha256': '7458e7c247ac7470a4a892b7db02cd04f50cc105142561e28db1f5a7001d4fce'},
}


def canonical(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def read_pins(path):
    pins = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '--hash=')):
            continue
        match = re.fullmatch(r'([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)(?:\s+\\)?', line)
        if not match:
            raise BuildError(f'Unsupported lock syntax in {path.name}')
        name, version = canonical(match[1]), match[2]
        if name in pins:
            raise BuildError(f'Duplicate pin in {path.name}: {name}')
        pins[name] = version
    if not pins:
        raise BuildError(f'Empty lock: {path.name}')
    return pins


def inspect_distribution(name, expected):
    row = {'name': name, 'expected_version': expected}
    try:
        dist = metadata.distribution(name)
    except metadata.PackageNotFoundError:
        return {**row, 'status': 'not-installed-in-this-environment'}
    row.update(installed_version=dist.version,
               status='version-match' if dist.version == expected else 'version-mismatch',
               license_expression=dist.metadata.get('License-Expression'),
               declared_license=dist.metadata.get('License'),
               license_classifiers=[v for v in dist.metadata.get_all('Classifier', [])
                                    if v.startswith('License ::')],
               project_urls=dist.metadata.get_all('Project-URL', []))
    notices = []
    for relative in dist.files or []:
        path = PurePosixPath(str(relative))
        # Restrict reads to recorded files inside the installed distribution.
        if path.is_absolute() or '..' in path.parts:
            continue
        if not any(re.match(r'(?i)^(licen[cs]e|copying|notice|copyright)([._-]|$)', part)
                   for part in path.parts):
            continue
        actual = Path(dist.locate_file(relative))
        if actual.is_symlink() or not actual.is_file():
            continue
        if actual.stat().st_size > 16 * 1024**2:
            notices.append({'path': str(path), 'status': 'oversized-not-read'})
            continue
        data = actual.read_bytes()
        notices.append({'path': str(path), 'bytes': len(data),
                        'sha256': hashlib.sha256(data).hexdigest()})
    row['notice_files'] = sorted(notices, key=lambda item: item['path'])
    row['notice_text_reviewed'] = False
    return row


def inventory(locks):
    pins, records = {}, []
    for lock in locks:
        entries = read_pins(lock)
        records.append({'name': lock.name, 'sha256': hashlib.sha256(lock.read_bytes()).hexdigest(),
                        'pins': entries})
        for name, version in entries.items():
            if name in pins and pins[name] != version:
                raise BuildError(f'Conflicting lock versions: {name}')
            pins[name] = version
    rows = [inspect_distribution(name, version) for name, version in sorted(pins.items())]
    return {'schema': 'protector-native.personal-dependency-inventory/v1',
            'publication_authorized': False, 'status': 'metadata-inventory-not-license-clearance',
            'python_version': sys.version.split()[0], 'platform': sys.platform,
            'locks': records, 'distributions': rows,
            'all_pins_installed_at_expected_version': all(row['status'] == 'version-match' for row in rows),
            'limitations': ['Only selected Python lock pins and current installed wheel metadata.',
                           'Notice text, bundled native libraries and transitive native licences need review.',
                           'Does not audit model weights, system tools, game content or project ownership.']}


def collect_notices(report, directory, *, fetch_missing=False):
    """Collect immutable evidence in a new external directory, never clearance."""
    directory = outside_repo(directory)
    if directory.exists() or directory.is_symlink() or not directory.parent.is_dir():
        raise BuildError('Use a new external notice directory under an existing parent')
    if not report['all_pins_installed_at_expected_version']:
        raise BuildError('Notice collection requires every selected version to match')
    planned, missing = [], []
    for row in report['distributions']:
        name, version = row['name'], row['expected_version']
        dist = metadata.distribution(name)
        if dist.version != version:
            raise BuildError(f'Installed version changed: {name}')
        for notice in row['notice_files']:
            if 'sha256' not in notice:
                raise BuildError(f'Uncollected oversized notice: {name}')
            relative = PurePosixPath(notice['path'])
            if relative.is_absolute() or '..' in relative.parts:
                raise BuildError('Unsafe notice path')
            source = Path(dist.locate_file(str(relative)))
            if source.is_symlink() or not source.is_file() or source.stat().st_size != notice['bytes']:
                raise BuildError(f'Notice changed: {name}')
            data = source.read_bytes()
            if hashlib.sha256(data).hexdigest() != notice['sha256']:
                raise BuildError(f'Notice hash changed: {name}')
            planned.append((f'{name}/{relative}', data, {
                'package': name, 'version': version, 'origin': 'installed-distribution', **notice}))
        if not row['notice_files']:
            supplemental = SUPPLEMENTAL_NOTICES.get((name, version)) if fetch_missing else None
            if supplemental is None:
                missing.append({'package': name, 'version': version})
                continue
            with urllib.request.urlopen(supplemental['url'], timeout=30) as response:
                data = response.read(supplemental['bytes'] + 1)
            if len(data) != supplemental['bytes'] or hashlib.sha256(data).hexdigest() != supplemental['sha256']:
                raise BuildError(f'Upstream notice identity mismatch: {name}')
            planned.append((f'{name}/upstream-LICENSE.txt', data, {
                'package': name, 'version': version, 'origin': 'version-tagged-upstream', **supplemental}))
    # Preflight every byte before creating output. No installs, model loads or
    # substitutions for missing upstream evidence are performed.
    directory.mkdir(mode=0o700)
    records = []
    for relative, data, evidence in planned:
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
        if hashlib.sha256(target.read_bytes()).hexdigest() != evidence['sha256']:
            raise BuildError('Collected notice verification failed')
        records.append({**evidence, 'bundle_path': relative})
    result = {'schema': 'protector-native.personal-notice-collection/v1',
              'status': 'collected-text-not-redistribution-clearance',
              'publication_authorized': False, 'notice_text_reviewed': False,
              'locks': report['locks'], 'files': records, 'packages_without_notice': missing}
    write_json(directory / 'NOTICE-RECEIPT.json', result)
    return {'directory': str(directory), 'files': len(records),
            'packages_without_notice': missing, 'notice_text_reviewed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', action='append', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--notice-dir', type=Path)
    parser.add_argument('--fetch-missing-notices', action='store_true',
                        help='Fetch only the two version/hash-pinned upstream licence texts; requires --notice-dir')
    args = parser.parse_args()
    try:
        output = outside_repo(args.output)
        if output.exists() or output.is_symlink() or not output.parent.is_dir():
            raise BuildError('Use a new external output file under an existing directory')
        result = inventory(args.lock)
        if args.fetch_missing_notices and args.notice_dir is None:
            raise BuildError('--fetch-missing-notices requires --notice-dir')
        if args.notice_dir:
            result['notice_collection'] = collect_notices(result, args.notice_dir,
                                                         fetch_missing=args.fetch_missing_notices)
        write_json(output, result)
        print(json.dumps({'output': str(output), 'packages': len(result['distributions']),
                          'all_pins_installed_at_expected_version': result['all_pins_installed_at_expected_version']}))
    except (OSError, ValueError) as error:
        parser.exit(2, f'Dependency inventory: {error}\n')

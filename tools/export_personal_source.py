#!/usr/bin/env python3
"""Stage an explicit source allowlist without Git history or private payloads.

This creates a private engineering candidate, not publication clearance. The
bounded content checks do not replace a provenance, licence or secret audit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, outside_repo, write_json

ALLOWLIST = ROOT / "reference/personal_source_allowlist.json"
ALLOWED_SUFFIXES = {'.py', '.c', '.cpp', '.h', '.m', '.mm', '.inc', '.cmake', '.in', '.txt', '.md', '.json', '.lock'}
# README images only: bounded binary files under one folder, never game data formats.
MEDIA_ROOT, MEDIA_SUFFIXES = PurePosixPath('docs/media'), {'.jpg', '.png', '.webp'}
SECRET_PATTERNS = [rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'\bgh[pousr]_[A-Za-z0-9]{30,}\b', rb'\bAKIA[0-9A-Z]{16}\b',
    rb'\bxox[baprs]-[0-9A-Za-z-]{20,}\b', rb'\bAIza[0-9A-Za-z_-]{35}\b']


def safe_relative(name):
    if not isinstance(name, str) or not name or '\\' in name or '\0' in name:
        raise BuildError("Invalid export path")
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or any(part.startswith('.') and part != '__init__.py' for part in path.parts):
        raise BuildError("Hidden, absolute or traversing export path")
    if path.suffix not in ALLOWED_SUFFIXES and str(path) != 'LICENSE' and not is_media(path):
        raise BuildError("Non-source export extension")
    return path


def is_media(path):
    return path.parent == MEDIA_ROOT and path.suffix in MEDIA_SUFFIXES


def inspect_media(path, max_bytes=2 * 1024**2):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > max_bytes:
        raise BuildError(f"Linked, missing or oversized media: {path.name}")
    data = path.read_bytes()
    signatures = {'.jpg': (b'\xff\xd8\xff',), '.png': (b'\x89PNG\r\n\x1a\n',), '.webp': (b'RIFF',)}
    if not data.startswith(signatures[path.suffix]) or (path.suffix == '.webp' and data[8:12] != b'WEBP'):
        raise BuildError(f"Media content does not match its extension: {path.name}")
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def inspect_file(path, *, scan_text=True, max_bytes=2 * 1024**2):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > max_bytes:
        raise BuildError(f"Linked, missing or oversized source: {path.name}")
    data = path.read_bytes()
    try:
        data.decode('utf-8')
    except UnicodeDecodeError as error:
        raise BuildError(f"Binary data is outside the source export: {path.name}") from error
    if b'\0' in data:
        raise BuildError(f"Binary NUL in source: {path.name}")
    if scan_text and (b'/Users/' in data or any(re.search(p, data) for p in SECRET_PATTERNS)):
        raise BuildError(f"Private-path or credential-pattern review required: {path.name}")
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def publication_record(contract):
    """An authorized export must name who approved it, when and for what scope."""
    record = contract.get('publication')
    keys = ('approved_by', 'date', 'scope')
    if not isinstance(record, dict) or set(record) != set(keys) or \
            not all(isinstance(record[key], str) and record[key].strip() for key in keys) or \
            not re.fullmatch(r'\d{4}-\d{2}-\d{2}', record['date']):
        raise BuildError('Publication requires an explicit approval record')
    return {key: record[key] for key in keys}


def export(destination):
    contract = json.loads(ALLOWLIST.read_text())
    authorized = contract.get('publication_authorized')
    if contract.get('schema') != 'protector-native.personal-source-allowlist/v1' or \
            authorized not in (True, False) or not 1 <= len(contract.get('files', [])) <= 512:
        raise BuildError('A bounded source allowlist is required')
    approval = publication_record(contract) if authorized else None
    destination = outside_repo(destination)
    if destination.exists() or destination.is_symlink() or not destination.parent.is_dir():
        raise BuildError('Use a new external export directory under an existing parent')
    planned, outputs, sources = [], set(), set()
    for record in contract['files']:
        source_name, target_name = str(safe_relative(record['source'])), str(safe_relative(record['destination']))
        if target_name in outputs:
            raise BuildError('Repeated output in explicit allowlist')
        sources.add(source_name)
        outputs.add(target_name)
        source = ROOT / source_name
        if not source.resolve().is_relative_to(ROOT):
            raise BuildError('Source escapes repository')
        # The scanner itself necessarily contains its private-path/secret
        # pattern strings. Its other text is still checked below after removing
        # only those exact pattern definitions, not arbitrary line exclusions.
        scan = source_name != 'tools/export_personal_source.py'
        evidence = inspect_media(source) if is_media(PurePosixPath(source_name)) else inspect_file(source, scan_text=scan)
        if not scan:
            text = source.read_bytes().replace(b"b'/Users/'", b"b'REDACTED_PATTERN'")
            if b'/Users/' in text or any(re.search(p, text) for p in SECRET_PATTERNS):
                raise BuildError('Export scanner contains an actual private value')
        planned.append((source, target_name, evidence))
    destination.mkdir(mode=0o700)
    for source, relative, evidence in planned:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if digest_file(target) != evidence['sha256'] or digest_file(source) != evidence['sha256']:
            raise BuildError('Source changed during export; staging is incomplete')
    receipt = {'schema': 'protector-native.personal-source-export/v1', 'publication_authorized': authorized,
        'status': 'owner-approved-public-source-release' if authorized else
            'private-engineering-staging-not-redistribution-clearance',
        **({'publication': approval} if approval else {}),
        'allowlist_sha256': digest_file(ALLOWLIST),
        'files': {relative: evidence for _, relative, evidence in planned},
        'checks': {'explicit_allowlist_only': True, 'git_history_included': False,
            'utf8_source_only_outside_docs_media': True, 'bounded_private_path_and_credential_patterns': 'no matches'},
        'remaining_review': ['full provenance and dependency notices',
            'game-specific source derivation and authored reconstruction inputs', 'publication authority']}
    write_json(destination / 'EXPORT-RECEIPT.json', receipt)
    return {'directory': str(destination), 'files': len(planned), 'bytes': sum(v['bytes'] for _, _, v in planned),
        'status': receipt['status']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(export(args.destination), indent=2))
    except (OSError, ValueError) as error:
        parser.exit(2, f'Source export: {error}\n')

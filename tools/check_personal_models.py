#!/usr/bin/env python3
"""Check manually acquired weights without loading models or accessing a network."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.personal_build import BuildError, outside_repo


def catalog(root=ROOT):
    texture = json.loads((root / 'reference/personal_texture_recipes.json').read_text())['models']
    movie = json.loads((root / 'reference/personal_cinematic_recipes.json').read_text())['models']
    table = json.loads((root / 'reference/personal_model_sources.json').read_text())
    rows = table.get('models', [])
    expected = set(texture) | {r['sha256'] for r in movie.values()}
    if table.get('schema') != 'protector-native.personal-model-sources/v1' or len(rows) != 5 or \
            len(expected) != 5 or {r['sha256'] for r in rows} != expected or \
            len({r['filename'] for r in rows}) != len(rows):
        raise BuildError('Model acquisition catalog does not cover the exact five recipe models')
    for row in rows:
        name, sha = row['filename'], row['sha256']
        if not re.fullmatch(r'[A-Za-z0-9_-]+\.(?:pth|safetensors|onnx)', name) or \
                not re.fullmatch('[0-9a-f]{64}', sha) or type(row['bytes']) is not int or \
                not 0 < row['bytes'] <= 256 * 1024**2:
            raise BuildError('Invalid bounded model record')
        if sha in texture and texture[sha]['filename'] != name:
            raise BuildError('Texture worker requires a different model filename')
        for field in ('download_url', 'review_url'):
            url = urlparse(row[field])
            if url.scheme != 'https' or url.hostname not in ('github.com', 'raw.githubusercontent.com') or \
                    url.username or url.password or url.port or url.fragment:
                raise BuildError('Expected a direct upstream HTTPS reference')
    return rows


def inspect(directory, rows):
    directory = Path(directory).absolute()
    if any(p.is_symlink() for p in (directory, *directory.parents)):
        raise BuildError('Model directory must not contain path links')
    directory = outside_repo(directory)
    if directory.exists() and not directory.is_dir():
        raise BuildError('Model location is not a directory')
    results = []
    for row in rows:
        path = directory / row['filename']
        result = dict(row, status='missing')
        if path.is_symlink():
            result['status'] = 'linked-file-rejected'
        elif path.exists():
            if not path.is_file():
                result['status'] = 'not-a-regular-file'
            elif path.stat().st_size != row['bytes']:
                result['status'] = 'size-mismatch'
            else:
                h = hashlib.sha256()
                with path.open('rb') as stream:
                    while block := stream.read(1024**2):
                        h.update(block)
                result['status'] = 'verified' if h.hexdigest() == row['sha256'] else 'hash-mismatch'
        results.append(result)
    return {'schema': 'protector-native.personal-model-check/v1',
        'all_models_verified': all(r['status'] == 'verified' for r in results),
        'models': results, 'network_access': False, 'model_code_loaded': False,
        'license_acceptance': False, 'distribution_clearance': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.model_dir, catalog())
        print(json.dumps(result, indent=2))
        sys.exit(0 if result['all_models_verified'] else 2)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f'Model preflight: {error}\n')

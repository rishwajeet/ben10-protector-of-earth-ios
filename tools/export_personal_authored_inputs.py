#!/usr/bin/env python3
"""Stage the exact authored dependency closure; never imply rights clearance.

Run beside a source export, not inside it. No game pixels, model weights,
historical owner receipts or developer reference-parent lists are copied.
"""
import argparse
import hashlib
import importlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.personal_build import BuildError, outside_repo, write_json
from tools.export_personal_source import inspect_file
from tools.build_interface_vectors import read_vector

# Explicit scope: contract suffix, schema suffix, selected entries, validator.
FAMILIES = {
    'vectors': ('vector_recipes', 'vectors', 31, None),
    'structural': ('structural_plates', 'structural-plates', 20, 'structural_plates'),
    'atlases': ('atlas_recipes', 'atlases', 6, None),
    'facades': ('facade_recipes', 'facades', 7, 'facades'),
    'finite': ('finite_recipes', 'finite-materials', 8, 'finite_materials'),
    'layered-atlases': ('layered_atlas_recipes', 'layered-atlases', 3, 'layered_atlases'),
    'signs': ('sign_recipes', 'signs', 3, 'signs'),
}
RECEIPT = 'AUTHORED-INPUTS.json'


def checked_root(path):
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise BuildError('Authored input/output paths must not contain links')
    return outside_repo(path)


def read_input(directory, sha, suffix, dimensions=None, max_bytes=1024**2):
    if not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha):
        raise BuildError('Invalid content-addressed authored input')
    path = directory / (sha + suffix)
    evidence = inspect_file(path, max_bytes=max_bytes)
    if evidence['sha256'] != sha:
        raise BuildError('Authored input hash differs: ' + path.name)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != sha:
        raise BuildError('Authored input changed while reading')
    if suffix == '.svg':
        if read_vector(path, *dimensions, max_bytes=max_bytes) != data:
            raise BuildError('Authored vector changed while validating')
    return path.name, data, evidence


def plan(sources, root=ROOT):
    if set(sources) != set(FAMILIES):
        raise BuildError('Supply exactly all seven authored-input families')
    planned, families, seen = {}, {}, set()
    for family, (suffix, schema, count, validator) in FAMILIES.items():
        directory = checked_root(sources[family])
        if not directory.is_dir():
            raise BuildError('Missing authored input family: ' + family)
        contract_path = root / 'reference' / ('personal_' + suffix + '.json')
        contract_data = contract_path.read_bytes()
        contract = json.loads(contract_data)
        rows = contract.get('entries', [])
        if contract.get('schema') != 'protector-native.personal-' + schema + '/v1' or len(rows) != count:
            raise BuildError('Incomplete or unsupported authored contract: ' + family)
        ids = [r['id'] for r in rows]
        if len(set(ids)) != count or seen.intersection(ids):
            raise BuildError('Repeated selected authored entry')
        seen.update(ids)

        def add(sha, ext, dimensions=None, max_bytes=1024**2):
            name, data, evidence = read_input(directory, sha, ext, dimensions, max_bytes)
            planned[family + '/' + name] = (data, evidence)
            return data

        if family == 'vectors':
            groups = contract['groups']
            if len(groups) != 21 or set(groups) != {r['group'] for r in rows}:
                raise BuildError('Incomplete vector group closure')
            for group in groups.values():
                add(group['vector_sha256'], '.svg', group['dimensions'],
                    (4 if group['kind'] == 'straight-alpha' else 1) * 1024**2)
        elif family == 'atlases':
            for row in rows:
                add(row['vector_sha256'], '.svg', row['source_dimensions'])
        else:
            validate = importlib.import_module('tools.personal_' + validator).validate_recipe
            for row in rows:
                match = re.fullmatch(r'(\d+)x(\d+)-[0-9a-f]{64}', row['id'])
                if not match:
                    raise BuildError('Invalid selected source identity')
                width, height = map(int, match.groups())
                recipe = json.loads(add(row['recipe_sha256'], '.json'))
                if recipe.get('id') != row['id']:
                    raise BuildError('Authored recipe belongs to another texture')
                if family in ('structural', 'signs'):
                    validate(recipe, width, height)
                elif family == 'layered-atlases':
                    if width != height:
                        raise BuildError('Layered atlas must be square')
                    validate(recipe, width)
                else:
                    validate(recipe)
                if family == 'signs':
                    add(recipe['vector_sha256'], '.svg', (width, height))
                elif family == 'layered-atlases':
                    add(recipe['base']['vector_sha256'], '.svg', (width, height))
                    for step in recipe['steps']:
                        if step['kind'] == 'overlay':
                            add(step['vector_sha256'], '.svg', (width, height))
        families[family] = {'selected_entries': sorted(ids),
            'contract': str(contract_path.relative_to(root)),
            'contract_sha256': hashlib.sha256(contract_data).hexdigest(),
            'files': sum(p.startswith(family + '/') for p in planned)}
    return planned, families


def verify(destination, root=ROOT):
    destination = checked_root(destination)
    receipt = json.loads((destination / RECEIPT).read_text())
    if receipt.get('schema') != 'protector-native.authored-input-staging/v1' or \
            receipt.get('owner_inclusion_authorized') is not True or \
            receipt.get('distribution_clearance') is not False or \
            receipt.get('published') is not False:
        raise BuildError('Expected an authorized, unpublished review candidate')
    planned, families = plan({k: destination / k for k in FAMILIES}, root)
    expected = {p: evidence for p, (_, evidence) in planned.items()}
    actual = set()
    for path in destination.rglob('*'):
        if path.is_symlink():
            raise BuildError('Staged bundle contains a link')
        if path.is_file():
            actual.add(path.relative_to(destination).as_posix())
    if actual != set(expected) | {RECEIPT} or receipt.get('files') != expected or receipt.get('families') != families:
        raise BuildError('Staged closure, contract or file inventory differs')
    return {'files': len(expected), 'bytes': sum(e['bytes'] for e in expected.values()),
        'selected_entries': sum(len(f['selected_entries']) for f in families.values()),
        'distribution_clearance': False, 'published': False}


def export(sources, destination, *, owner_authorized=False, root=ROOT):
    if owner_authorized is not True:
        raise BuildError('Explicit owner inclusion authorization must be recorded')
    destination = checked_root(destination)
    if destination.exists() or not destination.parent.is_dir():
        raise BuildError('Use a new external destination under an existing parent')
    for source in sources.values():
        source = checked_root(source)
        if destination.is_relative_to(source) or source.is_relative_to(destination):
            raise BuildError('Staging must not overlap supplied inputs')
    planned, families = plan(sources, root)
    destination.mkdir(mode=0o700)
    for relative, (data, _) in planned.items():
        path = destination / relative
        path.parent.mkdir(exist_ok=True, mode=0o700)
        with path.open('xb') as stream:
            stream.write(data)
    write_json(destination / RECEIPT, {
        'schema': 'protector-native.authored-input-staging/v1',
        'owner_inclusion_authorized': True, 'distribution_clearance': False, 'published': False,
        'status': 'local-release-review-candidate', 'families': families,
        'files': {p: evidence for p, (_, evidence) in planned.items()},
        'excluded': ['historical owner receipts', 'developer reference-parent lists',
            'game pixel payloads', 'model weights', 'unreferenced files'],
        'remaining_review': ['authorship and derivative-work rights', 'asset license and notices'],
        'checks': ['exact contract dependency closure', 'worker recipe and SVG validation',
            'bounded private-path and credential-pattern scan; not full secret or rights audit']})
    return verify(destination, root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    stage = sub.add_parser('stage')
    stage.add_argument('--destination', type=Path, required=True)
    stage.add_argument('--owner-authorized', action='store_true')
    for family in FAMILIES:
        stage.add_argument('--' + family, type=Path, required=True)
    check = sub.add_parser('verify')
    check.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'verify':
            result = verify(args.destination)
        else:
            result = export({k: getattr(args, k.replace('-', '_')) for k in FAMILIES},
                args.destination, owner_authorized=args.owner_authorized)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f'Authored input staging: {error}\n')

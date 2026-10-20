import copy
import json
from pathlib import Path
import tempfile
import unittest

from tools import personal_grid_variants as grids


class GridVariantTests(unittest.TestCase):
    def fixture(self):
        entry = {'id': '64x64-' + 'a' * 64, 'reference_rgba8_sha256': 'b' * 64,
            'dimensions': [256, 256], 'operation': {'kind': 'authored-treatment-pending'}}
        recipe = {'id': entry['id'], 'grid': 'c' * 64, 'plane': 'rgb', 'pixel_rect': [0, 0, 256, 256]}
        grid = {'source_grid_sha256': 'c' * 64, 'model_sha256': 'd' * 64, 'scale': 4}
        variant = {'rgba8_sha256': 'e' * 64, 'qualification_sha256': 'f' * 64,
            'components': 256 * 256 * 4, 'changed_components': 100, 'total_absolute_error': 100,
            'max_channel_error': 1, 'alpha_exact': True}
        document = {'schema': 'protector-native.personal-texture-variants/v1',
            'family': 'connected-grid-rgb', 'title_dol_sha256': grids.RBNEG9_DOL_SHA256,
            'source_lock_sha256': grids.digest_file(grids.LOCK), 'policy': grids.POLICY,
            'grid_contract_sha256': grids.digest_file(grids.RECIPES),
            'entries': {entry['id']: {'entry_sha256': grids.identity(entry),
                'reference_rgba8_sha256': entry['reference_rgba8_sha256'], 'grid_id': recipe['grid'],
                'grid_recipe_sha256': grids.identity(grid), 'crop_recipe_sha256': grids.identity(recipe),
                'variants': [variant]}}}
        return entry, recipe, grid, document

    def load(self, document):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'contract.json'
            path.write_text(json.dumps(document))
            return grids.load_grid_variants(path)

    def test_only_exact_registered_hash_is_admitted(self):
        entry, recipe, grid, doc = self.fixture()
        args = dict(contract=self.load(doc), recipe=recipe, grid=grid)
        result = grids.admit_grid(entry, 'e' * 64, **args)
        self.assertFalse(result['comparison_this_run'])
        self.assertEqual(result['variant_family'], 'connected-grid-rgb')
        self.assertIsNone(grids.admit_grid(entry, '9' * 64, **args))
        self.assertIsNone(grids.admit_grid(entry, entry['reference_rgba8_sha256'], **args))

    def test_source_dimensions_crop_canvas_model_and_plane_are_bound(self):
        entry, recipe, grid, doc = self.fixture()
        for target, field, value in [('entry', 'dimensions', [512, 512]),
                ('entry', 'reference_rgba8_sha256', '9' * 64),
                ('recipe', 'pixel_rect', [1, 0, 257, 256]), ('recipe', 'plane', 'coverage'),
                ('grid', 'model_sha256', '8' * 64), ('grid', 'source_grid_sha256', '7' * 64)]:
            e, r, g = copy.deepcopy((entry, recipe, grid))
            {'entry': e, 'recipe': r, 'grid': g}[target][field] = value
            with self.subTest(target=target, field=field), self.assertRaises(grids.BuildError):
                grids.admit_grid(e, 'e' * 64, contract=self.load(doc), recipe=r, grid=g)

    def test_malformed_registry_cannot_widen_tolerance(self):
        entry, _, _, doc = self.fixture()
        for field, value in [('max_channel_error', 2), ('alpha_exact', False), ('qualification_sha256', 'bad')]:
            bad = copy.deepcopy(doc); bad['entries'][entry['id']]['variants'][0][field] = value
            with self.subTest(field=field), self.assertRaises(grids.BuildError):
                self.load(bad)
        for field, value in [('family', 'all-authored'), ('grid_contract_sha256', '0' * 64)]:
            bad = copy.deepcopy(doc); bad[field] = value
            with self.subTest(field=field), self.assertRaises(grids.BuildError):
                self.load(bad)

    def test_other_families_are_not_admitted(self):
        entry, recipe, grid, doc = self.fixture()
        contract = self.load(doc)
        entry['operation']['kind'] = 'local-neutral'
        self.assertIsNone(grids.admit_grid(entry, 'e' * 64, contract=contract, recipe=recipe, grid=grid))
        entry['operation']['kind'] = 'authored-treatment-pending'; entry['id'] = '64x64-' + '9' * 64
        self.assertIsNone(grids.admit_grid(entry, 'e' * 64, contract=contract, recipe=recipe, grid=grid))


if __name__ == '__main__':
    unittest.main()

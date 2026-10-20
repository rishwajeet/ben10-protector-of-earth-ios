import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import personal_thumbnail_variants as thumbnails
from tools import personal_texture_variants as variants


class ThumbnailVariantTests(unittest.TestCase):
    def fixture(self):
        entry = {'id': '64x64-' + 'a' * 64, 'reference_rgba8_sha256': 'b' * 64,
                 'dimensions': [1024, 1024], 'operation': {'kind': 'authored-treatment-pending'}}
        parent = {'id': '256x256-' + 'c' * 64, 'reference_rgba8_sha256': 'd' * 64,
                  'dimensions': [4096, 4096], 'operation': {'kind': 'local-rgb-neutral'}}
        recipe = {'id': entry['id'], 'parent': parent['id'], 'source_crop': [0, 0, 64, 64]}
        variant = {'rgba8_sha256': 'e' * 64, 'parent_rgba8_sha256': 'd' * 64,
                   'qualification_sha256': 'f' * 64, 'components': 1024 * 1024 * 4,
                   'changed_components': 100, 'total_absolute_error': 100,
                   'max_channel_error': 1, 'alpha_exact': True}
        document = {'schema': 'protector-native.personal-texture-variants/v1',
                    'family': 'registered-thumbnails', 'title_dol_sha256': thumbnails.RBNEG9_DOL_SHA256,
                    'source_lock_sha256': thumbnails.digest_file(thumbnails.LOCK), 'policy': thumbnails.POLICY,
                    'thumbnail_contract_sha256': thumbnails.digest_file(thumbnails.RECIPES),
                    'entries': {entry['id']: {'entry_sha256': thumbnails.identity(entry),
                        'reference_rgba8_sha256': entry['reference_rgba8_sha256'],
                        'parent_id': parent['id'], 'parent_entry_sha256': thumbnails.identity(parent),
                        'thumbnail_recipe_sha256': thumbnails.identity(recipe), 'variants': [variant]}}}
        return entry, parent, recipe, document

    def load(self, document):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'contract.json'
            path.write_text(json.dumps(document))
            return thumbnails.load_thumbnail_variants(path)

    def test_known_hash_requires_exact_recipe_parent_and_output(self):
        entry, parent, recipe, document = self.fixture()
        contract = self.load(document)
        def admit(actual, parent_hash='d' * 64):
            return thumbnails.admit_thumbnail(entry, actual, contract=contract,
                recipe=recipe, parent_entry=parent, parent_hash=parent_hash)
        result = admit('e' * 64)
        self.assertEqual(result['admission'], 'listed-output-sha256')
        self.assertEqual(result['variant_family'], 'registered-thumbnail')
        self.assertFalse(result['comparison_this_run'])
        self.assertIsNone(admit('1' * 64))
        self.assertIsNone(admit('e' * 64, '2' * 64))
        self.assertIsNone(admit(entry['reference_rgba8_sha256']))

    def test_changed_child_crop_and_parent_recipe_fail(self):
        entry, parent, recipe, document = self.fixture()
        contract = self.load(document)
        for target, field, value in [('child', 'dimensions', [2048, 2048]),
                ('crop', 'source_crop', [1, 0, 65, 64]), ('parent', 'operation', {'kind': 'local-neutral'})]:
            child, crop, full = copy.deepcopy(entry), copy.deepcopy(recipe), copy.deepcopy(parent)
            {'child': child, 'crop': crop, 'parent': full}[target][field] = value
            with self.subTest(target=target), self.assertRaises(thumbnails.BuildError):
                thumbnails.admit_thumbnail(child, 'e' * 64, contract=contract, recipe=crop, parent_entry=full)

    def test_withdrawn_parent_qualification_rejects_child(self):
        entry, parent, recipe, document = self.fixture()
        document['entries'][entry['id']]['variants'][0]['parent_rgba8_sha256'] = '1' * 64
        with patch.object(variants, 'admit', return_value=None), self.assertRaises(thumbnails.BuildError):
            thumbnails.admit_thumbnail(entry, 'e' * 64, contract=self.load(document), recipe=recipe, parent_entry=parent)

    def test_malformed_contract_cannot_widen_family_or_tolerance(self):
        entry, _, _, document = self.fixture()
        for field, value in [('alpha_exact', False), ('max_channel_error', 2),
                             ('components', 4096 * 4096 * 4), ('parent_rgba8_sha256', 'bad')]:
            bad = copy.deepcopy(document)
            bad['entries'][entry['id']]['variants'][0][field] = value
            with self.subTest(field=field), self.assertRaises(thumbnails.BuildError):
                self.load(bad)
        for field, value in [('family', 'all-authored'), ('thumbnail_contract_sha256', '0' * 64)]:
            bad = copy.deepcopy(document); bad[field] = value
            with self.subTest(field=field), self.assertRaises(thumbnails.BuildError):
                self.load(bad)

    def test_neural_and_unregistered_authored_entries_are_not_thumbnails(self):
        entry, parent, recipe, document = self.fixture()
        self.assertIsNone(thumbnails.admit_thumbnail(parent, 'e' * 64, contract=self.load(document)))
        entry['id'] = '64x64-' + '9' * 64
        self.assertIsNone(thumbnails.admit_thumbnail(entry, 'e' * 64, contract=self.load(document)))


if __name__ == '__main__':
    unittest.main()

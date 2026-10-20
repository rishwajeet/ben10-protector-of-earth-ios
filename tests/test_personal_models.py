import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import check_personal_models as checker


class ModelPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.data = b'synthetic weight, never deserialize'
        self.rows = [{'filename': 'model.pth', 'bytes': len(self.data),
            'sha256': hashlib.sha256(self.data).hexdigest()}]

    def test_catalog_covers_exact_current_recipes(self):
        rows = checker.catalog()
        self.assertEqual(len(rows), 5)
        self.assertEqual(sum(r['bytes'] for r in rows), 243569014)

    def test_missing_directory_reports_without_creating_it(self):
        path = self.root / 'missing'
        result = checker.inspect(path, self.rows)
        self.assertFalse(result['all_models_verified'])
        self.assertEqual(result['models'][0]['status'], 'missing')
        self.assertFalse(path.exists())

    def test_verified_without_network_or_model_loading(self):
        path = self.root / 'model.pth'
        path.write_bytes(self.data)
        with patch('urllib.request.urlopen', side_effect=AssertionError('network forbidden')):
            result = checker.inspect(self.root, self.rows)
        self.assertTrue(result['all_models_verified'])
        self.assertFalse(result['network_access'])
        self.assertFalse(result['model_code_loaded'])
        self.assertFalse(result['license_acceptance'])
        self.assertFalse(result['distribution_clearance'])
        self.assertEqual(path.read_bytes(), self.data)

    def test_wrong_size_then_wrong_hash(self):
        path = self.root / 'model.pth'
        path.write_bytes(b'x')
        self.assertEqual(checker.inspect(self.root, self.rows)['models'][0]['status'], 'size-mismatch')
        path.write_bytes(b'x' * len(self.data))
        self.assertEqual(checker.inspect(self.root, self.rows)['models'][0]['status'], 'hash-mismatch')

    def test_links_rejected(self):
        stored = self.root / 'stored'
        stored.write_bytes(self.data)
        (self.root / 'model.pth').symlink_to(stored)
        result = checker.inspect(self.root, self.rows)
        self.assertEqual(result['models'][0]['status'], 'linked-file-rejected')
        (self.root / 'linked').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(checker.BuildError):
            checker.inspect(self.root / 'linked', self.rows)

    def test_file_as_directory_rejected(self):
        path = self.root / 'file'
        path.write_bytes(b'x')
        with self.assertRaises(checker.BuildError):
            checker.inspect(path, self.rows)

    def test_nonregular_weight_rejected_and_unrelated_files_untouched(self):
        (self.root / 'model.pth').mkdir()
        extra = self.root / 'unrelated.txt'
        extra.write_bytes(b'keep')
        result = checker.inspect(self.root, self.rows)
        self.assertEqual(result['models'][0]['status'], 'not-a-regular-file')
        self.assertEqual(extra.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()

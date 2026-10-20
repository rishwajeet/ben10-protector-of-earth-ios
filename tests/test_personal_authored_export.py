import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import export_personal_authored_inputs as exporter


class AuthoredExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'source'
        (self.root / 'reference').mkdir(parents=True)
        self.inputs = self.base / 'inputs'
        self.inputs.mkdir()
        self.target = self.base / 'staged'
        self.vector = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64"/></svg>'
        self.sha = hashlib.sha256(self.vector).hexdigest()
        self.path = self.inputs / (self.sha + '.svg')
        self.path.write_bytes(self.vector)
        self.key = '64x64-' + 'a' * 64
        self.contract = self.root / 'reference/personal_atlas_recipes.json'
        self.contract.write_text(json.dumps({'schema': 'protector-native.personal-atlases/v1',
            'entries': [{'id': self.key, 'vector_sha256': self.sha, 'source_dimensions': [64, 64]}]}))
        self.sources = {'atlases': self.inputs}
        patcher = patch.object(exporter, 'FAMILIES', {'atlases': ('atlas_recipes', 'atlases', 1, None)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def stage(self):
        return exporter.export(self.sources, self.target, owner_authorized=True, root=self.root)

    def test_exact_closure_excludes_private_receipts_and_pixels(self):
        (self.inputs / 'owner.json').write_text('{"private": true}')
        (self.inputs / 'reference-parents.json').write_text('{}')
        (self.inputs / 'reference.png').write_bytes(b'not part of the closure')
        result = self.stage()
        self.assertEqual(result['files'], 1)
        self.assertEqual(result['selected_entries'], 1)
        self.assertFalse(result['distribution_clearance'])
        self.assertFalse(result['published'])
        self.assertEqual((self.target / 'atlases' / self.path.name).read_bytes(), self.vector)
        self.assertEqual(exporter.verify(self.target, self.root), result)

    def test_authorization_required_before_writes(self):
        with self.assertRaises(exporter.BuildError):
            exporter.export(self.sources, self.target, root=self.root)
        self.assertFalse(self.target.exists())

    def test_changed_input_rejects_before_staging(self):
        self.path.write_bytes(self.vector + b' ')
        with self.assertRaises(exporter.BuildError):
            self.stage()
        self.assertFalse(self.target.exists())

    def test_missing_family_and_missing_input(self):
        with self.assertRaises(exporter.BuildError):
            exporter.plan({}, self.root)
        self.path.unlink()
        with self.assertRaises(exporter.BuildError):
            self.stage()
        self.assertFalse(self.target.exists())

    def test_no_overwrite_or_overlap(self):
        self.stage()
        with self.assertRaises(exporter.BuildError):
            self.stage()
        with self.assertRaises(exporter.BuildError):
            exporter.export(self.sources, self.inputs / 'nested', owner_authorized=True, root=self.root)
        self.assertFalse((self.inputs / 'nested').exists())

    def test_extra_or_changed_staged_file_rejects(self):
        self.stage()
        extra = self.target / 'extra.json'
        extra.write_text('{}')
        with self.assertRaises(exporter.BuildError):
            exporter.verify(self.target, self.root)
        extra.unlink()
        (self.target / 'atlases' / self.path.name).write_bytes(self.vector + b' ')
        with self.assertRaises(exporter.BuildError):
            exporter.verify(self.target, self.root)

    def test_symlinks_reject(self):
        stored = self.inputs / 'stored.svg'
        self.path.rename(stored)
        self.path.symlink_to(stored)
        with self.assertRaises(exporter.BuildError):
            self.stage()
        linked_root = self.base / 'linked'
        linked_root.symlink_to(self.inputs, target_is_directory=True)
        with self.assertRaises(exporter.BuildError):
            exporter.checked_root(linked_root)

    def test_invalid_hash_and_embedded_image_reject(self):
        with self.assertRaises(exporter.BuildError):
            exporter.read_input(self.inputs, '../escape', '.svg', [64, 64])
        data = self.vector.replace(b'<rect width="64" height="64"/>', b'<image href="data:image/png;base64,YQ=="/>')
        sha = hashlib.sha256(data).hexdigest()
        (self.inputs / (sha + '.svg')).write_bytes(data)
        with self.assertRaises(ValueError):
            exporter.read_input(self.inputs, sha, '.svg', [64, 64])

    def test_contract_and_clearance_tampering_reject(self):
        self.stage()
        self.contract.write_text(self.contract.read_text() + '\n')
        with self.assertRaises(exporter.BuildError):
            exporter.verify(self.target, self.root)
        receipt_path = self.target / exporter.RECEIPT
        receipt = json.loads(receipt_path.read_text())
        receipt['distribution_clearance'] = True
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaises(exporter.BuildError):
            exporter.verify(self.target, self.root)


if __name__ == '__main__':
    unittest.main()

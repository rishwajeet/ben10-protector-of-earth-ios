from pathlib import Path
import hashlib
import io
import tempfile
import unittest
from unittest.mock import patch

from tools import audit_personal_dependencies as audit


class DependencyInventoryTests(unittest.TestCase):
    def test_pinned_lock_and_normalization(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / 'test.lock'
            lock.write_text('# uv output\nSome_Package==1.2.3 \\\n --hash=sha256:abc\n # via root\n')
            self.assertEqual(audit.read_pins(lock), {'some-package': '1.2.3'})
            for text in ('', 'pkg>=1.0', '-r elsewhere.lock', 'pkg==1\npkg==2'):
                lock.write_text(text)
                with self.subTest(text=text), self.assertRaises(audit.BuildError):
                    audit.read_pins(lock)

    def test_missing_distribution_is_not_clearance(self):
        with patch.object(audit.metadata, 'distribution', side_effect=audit.metadata.PackageNotFoundError):
            self.assertEqual(audit.inspect_distribution('missing', '1')['status'],
                             'not-installed-in-this-environment')

    def test_version_and_notice_evidence(self):
        class Metadata(dict):
            def get_all(self, key, default):
                return default
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'LICENSE').write_text('synthetic test notice')
            class Distribution:
                version = '2'
                metadata = Metadata({'License-Expression': 'MIT'})
                files = ['LICENSE', '../outside-LICENSE', '/absolute/LICENSE']
                def locate_file(self, path):
                    return root / path
            with patch.object(audit.metadata, 'distribution', return_value=Distribution()):
                row = audit.inspect_distribution('example', '1')
            self.assertEqual(row['status'], 'version-mismatch')
            self.assertEqual(len(row['notice_files']), 1)
            self.assertEqual(len(row['notice_files'][0]['sha256']), 64)
            self.assertFalse(row['notice_text_reviewed'])

    def test_conflicting_locks_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = Path(directory) / 'a.lock', Path(directory) / 'b.lock'
            first.write_text('pkg==1\n')
            second.write_text('pkg==2\n')
            with self.assertRaises(audit.BuildError):
                audit.inventory([first, second])

    def test_collects_verified_text_and_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            source = base / 'LICENSE'
            source.write_text('synthetic notice')
            class Distribution:
                version = '1'
                def locate_file(self, path):
                    return source
            report = {'all_pins_installed_at_expected_version': True, 'locks': [],
                      'distributions': [{'name': 'example', 'expected_version': '1',
                        'notice_files': [{'path': 'LICENSE', 'bytes': source.stat().st_size,
                                         'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}]}]}
            with patch.object(audit.metadata, 'distribution', return_value=Distribution()):
                result = audit.collect_notices(report, base / 'notices')
                self.assertEqual(result['files'], 1)
                self.assertEqual((base / 'notices/example/LICENSE').read_bytes(), source.read_bytes())
                with self.assertRaises(audit.BuildError):
                    audit.collect_notices(report, base / 'notices')
                source.write_text('tampered notice!')
                with self.assertRaises(audit.BuildError):
                    audit.collect_notices(report, base / 'tampered')
                self.assertFalse((base / 'tampered').exists())

    def test_supplemental_download_requires_opt_in_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            class Distribution:
                version = '0.4.2'
            report = {'all_pins_installed_at_expected_version': True, 'locks': [],
                      'distributions': [{'name': 'spandrel', 'expected_version': '0.4.2',
                                         'notice_files': []}]}
            with patch.object(audit.metadata, 'distribution', return_value=Distribution()), \
                    patch.object(audit.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')) as request:
                result = audit.collect_notices(report, base / 'offline')
                request.assert_not_called()
                self.assertEqual(len(result['packages_without_notice']), 1)
                with self.assertRaises(audit.BuildError):
                    audit.collect_notices(report, base / 'wrong', fetch_missing=True)
                self.assertFalse((base / 'wrong').exists())

    def test_mismatch_cannot_collect(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(audit.BuildError):
                audit.collect_notices({'all_pins_installed_at_expected_version': False},
                                      Path(directory) / 'bundle')


if __name__ == '__main__':
    unittest.main()

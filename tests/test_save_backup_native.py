"""Actual Foundation save recovery, using only isolated synthetic progress."""
import base64
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'Foundation requires macOS')
class SaveBackupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.probe = cls.root / 'probe'
        repo = Path(__file__).resolve().parents[1]
        command = ['xcrun', 'clang++', '-fobjc-arc', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                   '-DPROTECTOR_SAVE_BACKUP_TEST_FIXTURES=1', '-I', str(repo / 'native/include'),
                   str(repo / 'native/apple/save_backup.mm'), str(repo / 'native/tests/save_backup_probe.mm'),
                   '-framework', 'Foundation', '-o', str(cls.probe)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.root))
        self.source = self.case / 'source' / 'UpgradedSaves-RBNEG9-v1'
        self.target = self.case / 'target' / 'UpgradedSaves-RBNEG9-v1'
        self.recovery = self.case / 'recovery'
        self.archive = self.case / 'progress.pnsave'
        self.seed(self.source, b'synthetic new progress', b'new banner')
        self.seed(self.target, b'synthetic earned progress', b'old banner')
        exported = self.run_probe('export', self.source, self.archive)
        self.assertEqual(exported.returncode, 0, exported.stderr)

    def seed(self, directory, game, banner):
        directory.mkdir(parents=True)
        (directory / '.protector-edition.json').write_text(json.dumps({
            'schema': 'protector-native.save-edition/v1', 'edition': 'upgraded',
            'title': 'RBNEG9', 'namespace_version': 1}))
        (directory / 'SavedGames').write_bytes(game)
        (directory / 'banner.bin').write_bytes(banner)

    def run_probe(self, action, *args, stop=None):
        env = os.environ.copy()
        if stop:
            env['PROTECTOR_SAVE_BACKUP_TEST_STOP'] = stop
        else:
            env.pop('PROTECTOR_SAVE_BACKUP_TEST_STOP', None)
        return subprocess.run([str(self.probe), action, *map(str, args)], env=env,
                              capture_output=True, text=True, timeout=15)

    def assert_old(self):
        self.assertEqual((self.target / 'SavedGames').read_bytes(), b'synthetic earned progress')
        self.assertEqual((self.target / 'banner.bin').read_bytes(), b'old banner')

    def test_export_validate_restore_and_recovery(self):
        validated = self.run_probe('validate', self.archive)
        self.assertEqual(validated.returncode, 0, validated.stderr)
        (self.target / 'SavedGames.previous').write_bytes(b'older protected generation')
        result = self.run_probe('restore', self.archive, self.target, self.recovery)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt['durability_confirmed'])
        for name in ('SavedGames', 'banner.bin', '.protector-edition.json'):
            if name != '.protector-edition.json':
                self.assertEqual((self.target / name).read_bytes(), (self.source / name).read_bytes())
        previous = Path(receipt['previous_directory'])
        self.assertEqual((previous / 'SavedGames.previous').read_bytes(), b'older protected generation')
        recovered = self.run_probe('restore', receipt['recovery_backup'], self.target, self.recovery)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assert_old()

    def test_fresh_install_and_optional_banner(self):
        (self.source / 'banner.bin').unlink()
        second = self.case / 'without-banner.pnsave'
        self.assertEqual(self.run_probe('export', self.source, second).returncode, 0)
        fresh = self.case / 'fresh' / 'UpgradedSaves-RBNEG9-v1'
        result = self.run_probe('restore', second, fresh, self.recovery)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('recovery_backup', json.loads(result.stdout))
        self.assertFalse((fresh / 'banner.bin').exists())
        self.assertEqual(json.loads((fresh / '.protector-edition.json').read_text())['edition'], 'upgraded')

    def test_corruption_wrong_title_and_traversal_preserve_current(self):
        original = json.loads(self.archive.read_text())
        cases = []
        for key, value in (('title', 'OTHER'), ('edition', 'original'), ('namespace_version', 2), ('namespace_version', True)):
            changed = json.loads(json.dumps(original))
            changed[key] = value
            cases.append(changed)
        changed = json.loads(json.dumps(original))
        changed['files']['../SavedGames'] = changed['files'].pop('SavedGames')
        cases.append(changed)
        changed = json.loads(json.dumps(original))
        changed['files']['SavedGames']['base64'] = base64.b64encode(b'damage').decode()
        cases.append(changed)
        for value in cases:
            self.archive.write_text(json.dumps(value))
            with self.subTest(value=value):
                self.assertNotEqual(self.run_probe('restore', self.archive, self.target, self.recovery).returncode, 0)
                self.assert_old()
        self.archive.write_bytes(b'{truncated')
        self.assertNotEqual(self.run_probe('restore', self.archive, self.target, self.recovery).returncode, 0)
        self.assert_old()

    def test_links_wrong_namespace_overwrite_and_recovery_failure(self):
        self.assertNotEqual(self.run_probe('export', self.source, self.archive).returncode, 0)
        linked = self.case / 'linked.pnsave'
        linked.symlink_to(self.archive)
        self.assertNotEqual(self.run_probe('validate', linked).returncode, 0)
        original = self.case / 'Original' / 'RBNEG9'
        self.seed(original, b'legacy earned progress', b'legacy banner')
        self.assertNotEqual(self.run_probe('restore', self.archive, original, self.recovery).returncode, 0)
        self.assertEqual((original / 'SavedGames').read_bytes(), b'legacy earned progress')
        self.recovery.write_text('blocked directory')
        self.assertNotEqual(self.run_probe('restore', self.archive, self.target, self.recovery).returncode, 0)
        self.assert_old()

    def test_empty_current_and_linked_save_rejected(self):
        (self.target / 'SavedGames').write_bytes(b'')
        self.assertNotEqual(self.run_probe('export', self.target, self.case / 'empty.pnsave').returncode, 0)
        result = self.run_probe('restore', self.archive, self.target, self.recovery)
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.target / 'SavedGames').unlink()
        (self.target / 'SavedGames').symlink_to(self.source / 'SavedGames')
        self.assertNotEqual(self.run_probe('restore', self.archive, self.target, self.recovery).returncode, 0)
        self.assertTrue((self.target / 'SavedGames').is_symlink())

    def test_process_death_does_not_mix_save_generations(self):
        for phase in ('staged', 'committed'):
            result = self.run_probe('restore', self.archive, self.target, self.recovery, stop=phase)
            self.assertEqual(result.returncode, 23, result.stderr)
            if phase == 'staged':
                self.assert_old()
            else:
                self.assertEqual((self.target / 'SavedGames').read_bytes(), b'synthetic new progress')
                self.assertEqual((self.target / 'banner.bin').read_bytes(), b'new banner')
            self.assertTrue(list(self.recovery.glob('Before-restore-*.pnsave')))


if __name__ == '__main__':
    unittest.main()

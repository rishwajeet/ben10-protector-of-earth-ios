from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import tempfile
import unittest

from tools import personal_sign as signing
from tools.personal_build import BuildError

NOW = datetime(2026, 10, 26, tzinfo=timezone.utc)
CERT = b'synthetic-der-certificate'


def profile(app_id='ABCDE12345.com.you.protector', days=6, devices=('00008160-AAA',), all_devices=False, **extra):
    return {'TeamIdentifier': ['ABCDE12345'], 'Platform': ['iOS'], 'Name': 'iOS Team Provisioning Profile',
            'UUID': 'u', 'ExpirationDate': (NOW + timedelta(days=days)).replace(tzinfo=None),
            'Entitlements': {'application-identifier': app_id, 'get-task-allow': True},
            'ProvisionedDevices': list(devices), 'ProvisionsAllDevices': all_devices,
            'DeveloperCertificates': [CERT], **extra}


class PersonalSignTests(unittest.TestCase):
    def test_coverage_by_app_id_device_and_expiry(self):
        bundle = 'com.you.protector'
        self.assertTrue(signing.covers(profile(), bundle, '00008160-AAA', NOW))
        self.assertTrue(signing.covers(profile('ABCDE12345.*'), bundle, None, NOW))
        self.assertTrue(signing.covers(profile('ABCDE12345.com.you.*'), bundle, None, NOW))
        self.assertTrue(signing.covers(profile(devices=(), all_devices=True), bundle, 'any', NOW))
        for rejected in (profile(days=-1), profile('ABCDE12345.com.other'), profile('ZZZZZ99999.com.you.protector'),
                         profile(Platform=['OSX'])):
            self.assertFalse(signing.covers(rejected, bundle, None, NOW))
        self.assertFalse(signing.covers(profile(), bundle, 'someone-else', NOW))

    def test_prefers_exact_app_id_then_latest_expiry(self):
        profiles = {'a.mobileprovision': profile('ABCDE12345.*', days=300),
                    'b.mobileprovision': profile(days=3), 'c.mobileprovision': profile(days=6),
                    'd.mobileprovision': profile('ABCDE12345.com.other', days=9)}
        with tempfile.TemporaryDirectory() as directory:
            for name in profiles:
                (Path(directory) / name).write_bytes(b'')
            path, chosen = signing.find_profile('com.you.protector', None, [directory],
                                                reader=lambda p: profiles[p.name])
            self.assertEqual(path.name, 'c.mobileprovision')
            path, _ = signing.find_profile('com.you.other', None, [directory], reader=lambda p: profiles[p.name])
            self.assertEqual(path.name, 'a.mobileprovision')
            del profiles['a.mobileprovision']
            (Path(directory) / 'a.mobileprovision').unlink()
            with self.assertRaises(BuildError):
                signing.find_profile('com.you.other', None, [directory], reader=lambda p: profiles[p.name])

    def test_identity_and_entitlements(self):
        sha = hashlib.sha1(CERT).hexdigest().upper()
        listing = f'  1) {"0" * 40} "Apple Development: other"\n  2) {sha} "Apple Development: you (ABCDE12345)"\n'
        self.assertEqual(signing.signing_identity(profile(), listing), sha)
        with self.assertRaises(BuildError):
            signing.signing_identity(profile(), f'  1) {"0" * 40} "x"\n')
        self.assertEqual(signing.entitlements(profile('ABCDE12345.*'), 'com.you.protector'),
                         {'application-identifier': 'ABCDE12345.com.you.protector',
                          'com.apple.developer.team-identifier': 'ABCDE12345', 'get-task-allow': True})


if __name__ == '__main__':
    unittest.main()

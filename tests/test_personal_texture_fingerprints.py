import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageFilter

from tools import personal_texture_fingerprints as fingerprints
from tools.personal_build import BuildError

ROOT = Path(__file__).resolve().parents[1]
TOLERANCE = {'residual': 25, 'detail': 15}


def synthetic(scale=8, size=16, seed=3):
    """A source grid and an upscale whose blocks carry zero-mean detail, like a restored texture."""
    rng = np.random.default_rng(seed)
    source = np.dstack([rng.integers(40, 216, (size, size, 3), dtype=np.uint8), np.full((size, size), 255, np.uint8)])
    output = np.repeat(np.repeat(source[:, :, :3].astype(np.int16), scale, 0), scale, 1)
    y, x = np.mgrid[0:size * scale, 0:size * scale]
    pattern = np.rint(12 * np.sin(2 * np.pi * x / scale) * np.cos(2 * np.pi * y / scale)).astype(np.int16)
    return source, np.clip(output + pattern[:, :, None], 0, 255).astype(np.uint8)


def admitted(reference, candidate, source):
    expected = fingerprints.fingerprint(reference, source)
    actual = fingerprints.fingerprint(candidate, source)
    return all(max(abs(a - b) for a, b in zip(actual[k], expected[k])) <= TOLERANCE[k] for k in TOLERANCE)


class FingerprintTests(unittest.TestCase):
    def test_block_upscale_has_zero_residual_and_detail(self):
        source, _ = synthetic()
        flat = np.repeat(np.repeat(source[:, :, :3], 8, 0), 8, 1)
        result = fingerprints.fingerprint(flat, source)
        self.assertEqual(result['regions'], [4, 4])
        self.assertEqual(set(result['residual']) | set(result['detail']), {0})
        tiny = fingerprints.fingerprint(flat[:16, :16], source[:2, :2])
        self.assertEqual(tiny['regions'], [2, 2])
        with self.assertRaises(BuildError):
            fingerprints.fingerprint(flat[:-1], source)

    def test_rounding_passes_and_changed_treatments_fail(self):
        source, output = synthetic()
        rng = np.random.default_rng(9)
        rounded = output.astype(np.int16)
        mask = rng.random(output.shape[:2]) < .05
        rounded[mask] += rng.choice([-1, 1], (int(mask.sum()), 3))
        self.assertTrue(admitted(output, np.clip(rounded, 0, 255).astype(np.uint8), source))
        brighter = np.clip(output.astype(np.int16) + 2, 0, 255).astype(np.uint8)
        blurred = np.asarray(Image.fromarray(output).filter(ImageFilter.GaussianBlur(1)))
        patched = output.copy()
        patched[:16, :16] = rng.integers(0, 256, (16, 16, 3), dtype=np.uint8)
        for changed in (brighter, blurred, patched):
            self.assertFalse(admitted(output, changed, source))

    def test_admission_record_and_bounds(self):
        source, output = synthetic()
        entry = {'id': '16x16-synthetic', 'dimensions': [128, 128], 'source': {'width': 16, 'height': 16}}
        document = {'tolerance': TOLERANCE,
                    'entries': {entry['id']: {'output': fingerprints.fingerprint(output, source)}}}
        contract = (document, 'contract-sha')
        picture = Image.fromarray(output)
        result = fingerprints.admit_fingerprint(entry, picture, source.tobytes(), contract=contract)
        self.assertEqual(result['admission'], fingerprints.ADMISSION)
        self.assertTrue(fingerprints.within_bound(result))
        translucent = picture.convert('RGBA')
        translucent.putpixel((0, 0), (0, 0, 0, 0))
        self.assertIsNone(fingerprints.admit_fingerprint(entry, translucent, source.tobytes(), contract=contract))
        self.assertIsNone(fingerprints.admit_fingerprint(entry, picture, source.tobytes(), role='sign-parent',
                                                         contract=contract))
        self.assertIsNone(fingerprints.admit_fingerprint(dict(entry, id='other'), picture, source.tobytes(),
                                                         contract=contract))
        for value, expected in ((None, False), ({'max_channel_error': 1}, True), ({'max_channel_error': 2}, False),
                                ({'max_channel_error': None}, False), ({'admission': fingerprints.ADMISSION}, True)):
            self.assertEqual(fingerprints.within_bound(value), expected)

    def test_contract_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fingerprints.json'
            base = {'schema': fingerprints.SCHEMA, 'unit': fingerprints.UNIT, 'tolerance': TOLERANCE,
                    'entries': {'a': {'output': {'regions': [1, 1], 'residual': [0, 0, 0], 'detail': [1, 1, 1]}}}}
            path.write_text(json.dumps(base))
            self.assertIn('a', fingerprints.load_fingerprints(path)[0]['entries'])
            for broken in ({**base, 'tolerance': {'residual': 0, 'detail': 15}},
                           {**base, 'entries': {'a': {'output': {'regions': [2, 2], 'residual': [0], 'detail': [0]}}}},
                           {**base, 'entries': {'a': {'unknown-role': base['entries']['a']['output']}}}):
                path.write_text(json.dumps(broken))
                with self.assertRaises(BuildError):
                    fingerprints.load_fingerprints(path)

    def test_shipped_contract_covers_every_inference_output(self):
        from tools.personal_texture_pipeline import inventory
        document, _ = fingerprints.load_fingerprints()
        routing = inventory()
        self.assertIn('reference/personal_texture_fingerprints.json', routing['contracts'])
        wanted = {k for s in routing['stages'] if s['family'] in ('neural', 'thumbnails', 'signs') or
                  s['family'] == 'grids' and s.get('plane') == 'rgb' for k in s['entries']}
        self.assertEqual(set(document['entries']), wanted)
        self.assertEqual(sum('sign-parent' in v for v in document['entries'].values()), 3)


if __name__ == '__main__':
    unittest.main()

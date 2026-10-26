import hashlib
from importlib.util import find_spec
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = all(find_spec(name) for name in ('numpy', 'PIL', 'resvg_py'))
FACE = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">'
        b'<circle cx="64" cy="64" r="60" fill="#333"/><circle cx="64" cy="64" r="40" fill="#999"/></svg>')
MARKERS = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">'
           b'<rect x="58" y="0" width="12" height="10" fill="#ccc"/><rect x="58" y="118" width="12" height="10" fill="#ccc"/></svg>')


class AppIconContractTests(unittest.TestCase):
    def test_pinned_vectors_belong_to_the_bundle_contract(self):
        source = (ROOT / 'tools/make_app_icon.py').read_text()
        contract = json.loads((ROOT / 'reference/personal_vector_recipes.json').read_text())
        pinned = {group['vector_sha256'] for group in contract['groups'].values()}
        for name in ('FACE_SHA256', 'MARKERS_SHA256'):
            line = next(l for l in source.splitlines() if l.startswith(name + ' = '))
            self.assertIn(line.split('"')[1], pinned)

    def test_no_icon_artwork_in_the_source_tree(self):
        self.assertFalse((ROOT / 'native/ios/Assets.xcassets').exists())
        allowlist = json.loads((ROOT / 'reference/personal_source_allowlist.json').read_text())
        self.assertFalse([f for f in allowlist['files'] if f['source'].endswith('.xcassets') or '.xcassets/' in f['source']])


@unittest.skipUnless(DEPENDENCIES, 'needs requirements-personal-vectors.lock')
class AppIconRenderTests(unittest.TestCase):
    def setUp(self):
        from tools import make_app_icon
        self.icon = make_app_icon
        self.base = Path(tempfile.mkdtemp()).resolve()
        (self.base / 'bundle/vectors').mkdir(parents=True)
        self.shas = {}
        for name, data in (('face', FACE), ('markers', MARKERS)):
            sha = hashlib.sha256(data).hexdigest()
            (self.base / 'bundle/vectors' / (sha + '.svg')).write_bytes(data)
            self.shas[name] = sha
        self.patches = [patch.object(make_app_icon, 'FACE_SHA256', self.shas['face']),
                        patch.object(make_app_icon, 'MARKERS_SHA256', self.shas['markers']),
                        patch.object(make_app_icon, 'vector_dimensions',
                                     lambda: {sha: [128, 128] for sha in self.shas.values()})]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in self.patches:
            item.stop()

    def test_catalog_holds_three_appearances(self):
        from PIL import Image
        catalog = self.icon.write_catalog(self.base / 'bundle', self.base / 'out')
        contents = json.loads((catalog / 'AppIcon.appiconset/Contents.json').read_text())
        names = [image['filename'] for image in contents['images']]
        self.assertEqual(names, ['AppIcon.png', 'AppIcon-Dark.png', 'AppIcon-Tinted.png'])
        for name in names:
            with Image.open(catalog / 'AppIcon.appiconset' / name) as picture:
                self.assertEqual((picture.size, picture.mode), ((1024, 1024), 'RGB'))
        with Image.open(catalog / 'AppIcon.appiconset/AppIcon-Tinted.png') as tinted:
            red, green, blue = tinted.split()
            self.assertEqual(red.tobytes(), green.tobytes())
            self.assertEqual(green.tobytes(), blue.tobytes())

    def test_rejects_changed_vectors_and_in_repo_output(self):
        (self.base / 'bundle/vectors' / (self.shas['face'] + '.svg')).write_bytes(FACE.replace(b'#333', b'#334'))
        with self.assertRaises(self.icon.BuildError):
            self.icon.write_catalog(self.base / 'bundle', self.base / 'out')
        with self.assertRaises(self.icon.BuildError):
            self.icon.write_catalog(self.base / 'bundle', ROOT / 'build-icon')


if __name__ == '__main__':
    unittest.main()

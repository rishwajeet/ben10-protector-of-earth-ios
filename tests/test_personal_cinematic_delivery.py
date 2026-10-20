import json
from pathlib import Path
import tempfile
import unittest

from tools import personal_cinematic_delivery as delivery


class CinematicDeliveryTests(unittest.TestCase):
    def test_contract_lists_the_complete_library(self):
        movies = delivery.expected_movies()
        self.assertEqual(len(movies), 76)
        self.assertIn('watch.bik', movies)

    def test_missing_or_incomplete_restorations_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            with self.assertRaisesRegex(ValueError, 'has not been restored'):
                delivery.completed_masters(work, ['watch.bik'])
            folder = work / 'cinematic-masters/watch'
            folder.mkdir(parents=True)
            (folder / 'cinematics.json').write_text(json.dumps({'entries': [{'movie': 'watch.bik'}]}))
            (folder / 'receipt.json').write_text(json.dumps({'status': 'running'}))
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                delivery.completed_masters(work, ['watch.bik'])
            (folder / 'receipt.json').write_text(json.dumps({'status': 'complete-candidate'}))
            (folder / 'cinematics.json').write_text(json.dumps({'entries': [{'movie': 'other.bik'}]}))
            with self.assertRaisesRegex(ValueError, 'exactly that movie'):
                delivery.completed_masters(work, ['watch.bik'])

    def test_output_must_stay_outside_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            with self.assertRaisesRegex(ValueError, 'outside'):
                delivery.build(work, work / 'out', 12, ['watch.bik'])
            with self.assertRaisesRegex(ValueError, 'Unknown movie'):
                delivery.build(work, Path(directory + '-out'), 12, ['nope.bik'])


if __name__ == '__main__':
    unittest.main()

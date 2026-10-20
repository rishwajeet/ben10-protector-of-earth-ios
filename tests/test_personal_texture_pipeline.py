import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock

from tools import personal_texture_pipeline as pipeline


class TexturePipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selected = pipeline.load_contract()
        cls.companions = {k: json.loads((pipeline.ROOT / ('reference/personal_' + v[0] + '.json')).read_text())
            for k, v in pipeline.FAMILIES.items()}
        cls.plan = pipeline.inventory(cls.selected, cls.companions)

    def args(self, root=Path('/private/synthetic')):
        return argparse.Namespace(stage='atlases', game=root / 'game', work_dir=root / 'output',
            model_dir=None, authored_inputs=root / 'authored', parent_candidates=[],
            numerical_reference=None, provider='cpu', allow_neural=False)

    def test_all_entries_have_exactly_one_route_and_parents_are_explicit(self):
        plan = self.plan
        ids = [k for s in plan['stages'] for k in s['entries']]
        self.assertEqual(len(ids), 2221)
        self.assertEqual(len(set(ids)), 2221)
        self.assertEqual(plan['companion_entries'], 225)
        self.assertEqual(plan['family_counts']['neural'], 1406)
        self.assertEqual(plan['family_counts']['source'], 590)
        thumbnail = next(s for s in plan['stages'] if s['id'] == 'thumbnails')
        self.assertEqual(thumbnail['dependencies'], ['neural'])
        self.assertFalse(plan['replay_verified'])
        self.assertFalse(plan['complete_runtime_pack'])

    def test_rejects_duplicate_missing_foreign_and_main_overlap(self):
        for mutation in ('duplicate', 'missing', 'foreign', 'main-overlap'):
            companions = copy.deepcopy(self.companions)
            rows = companions['signs']['entries']
            if mutation == 'duplicate':
                rows[1] = copy.deepcopy(rows[0])
            elif mutation == 'missing':
                rows.pop()
            elif mutation == 'foreign':
                companions['signs']['reference_manifest_sha256'] = '0' * 64
            else:
                rows[0]['id'] = next(e['id'] for e in self.selected['entries']
                    if e['operation']['kind'] in pipeline.SUPPORTED)
            with self.subTest(mutation=mutation), self.assertRaises(pipeline.BuildError):
                pipeline.inventory(self.selected, companions)

    def test_rejects_wrong_thumbnail_parent_route(self):
        companions = copy.deepcopy(self.companions)
        companions['thumbnails']['entries'][0]['parent'] = companions['signs']['entries'][0]['id']
        with self.assertRaises(pipeline.BuildError):
            pipeline.inventory(self.selected, companions)

    def test_neural_never_starts_implicitly(self):
        for stage in self.plan['stages']:
            if stage['neural']:
                with self.subTest(stage=stage['id']), self.assertRaises(pipeline.BuildError):
                    pipeline.command_for(stage, self.args())
        args = self.args()
        args.allow_neural = True
        with self.assertRaises(pipeline.BuildError):
            pipeline.command_for(next(s for s in self.plan['stages'] if s['id'] == 'neural'), args)

    def test_command_routes_and_bounded_workers(self):
        args = self.args()
        args.allow_neural, args.model_dir = True, Path('/private/models')
        for stage in self.plan['stages']:
            if stage['id'] == 'thumbnails':
                continue
            cmd = pipeline.command_for(stage, args)
            self.assertEqual(cmd[0], pipeline.sys.executable)
            self.assertIn('--work-dir', cmd)
            self.assertNotIn('--reference-parents', cmd)
            if stage['family'] in ('source', 'neural'):
                self.assertEqual(cmd[cmd.index('--batch-size') + 1], '1' if stage['neural'] else '8')
            if stage.get('grid'):
                self.assertEqual(cmd[cmd.index('--grid') + 1], stage['grid'])
            if stage['family'] == 'atlases':
                self.assertEqual(cmd[2], 'replay')

    def test_blocked_dispatch_does_not_create_output_or_launch_worker(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.args(Path(temp))
            args.stage = 'neural'
            with patch.object(pipeline.subprocess, 'run') as launch, self.assertRaises(pipeline.BuildError):
                pipeline.run_stage(self.plan, args)
            launch.assert_not_called()
            self.assertFalse(args.work_dir.exists())

    def test_worker_failure_retains_workspace_without_success_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.args(Path(temp))
            with patch.object(pipeline.subprocess, 'run', side_effect=subprocess.CalledProcessError(2, [])), \
                    self.assertRaises(subprocess.CalledProcessError):
                pipeline.run_stage(self.plan, args)
            self.assertTrue((args.work_dir / 'pipeline-owner.json').exists())
            self.assertFalse((args.work_dir / 'dispatch-atlases.json').exists())

    def test_success_is_only_worker_dispatch_not_full_pack_or_clearance(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.args(Path(temp))
            with patch.object(pipeline.subprocess, 'run') as launch:
                receipt = pipeline.run_stage(self.plan, args)
            launch.assert_called_once()
            self.assertEqual(receipt['requested_entries'], 6)
            self.assertFalse(receipt['complete_runtime_pack'])
            self.assertFalse(receipt['publication_authorized'])

    def test_batch_stages_forward_guards_to_the_actual_worker_owner(self):
        args = self.args()
        args.model_dir, args.allow_neural = Path('/private/models'), True
        args.max_worker_rss_mib, args.min_memory_free_percent = 4096, 50
        cmd = pipeline.command_for(next(s for s in self.plan['stages'] if s['id'] == 'neural'), args)
        self.assertEqual(cmd[cmd.index('--max-worker-rss-mib') + 1], '4096')
        self.assertEqual(cmd[cmd.index('--min-memory-free-percent') + 1], '50')

    def test_grid_explicit_cpu_convolution_options_are_forwarded(self):
        args = self.args()
        args.model_dir, args.allow_neural = Path('/private/models'), True
        args.device, args.cpu_conv_output_rows = 'cpu', 64
        stage = next(s for s in self.plan['stages'] if s['family'] == 'grids' and s['neural'])
        cmd = pipeline.command_for(stage, args)
        self.assertEqual(cmd[cmd.index('--device') + 1], 'cpu')
        self.assertEqual(cmd[cmd.index('--cpu-conv-output-rows') + 1], '64')
        with self.assertRaisesRegex(pipeline.BuildError, 'not supported'):
            pipeline.command_for(next(s for s in self.plan['stages'] if s['id'] == 'signs'), args)
        args.device = 'mps'
        with self.assertRaisesRegex(pipeline.BuildError, 'require CPU'):
            pipeline.command_for(stage, args)

    def test_tail_rows_are_forwarded_only_to_cpu_rgb_grids(self):
        args = self.args()
        args.model_dir, args.allow_neural, args.device = Path('/private/models'), True, 'cpu'
        args.cpu_tail_input_rows = 32
        stage = next(s for s in self.plan['stages'] if s.get('plane') == 'rgb')
        cmd = pipeline.command_for(stage, args)
        self.assertEqual(cmd[cmd.index('--cpu-tail-input-rows') + 1], '32')
        for name in ('source', 'neural', 'grid-coverage', 'signs'):
            with self.subTest(stage=name), self.assertRaisesRegex(pipeline.BuildError, 'CPU RGB grids'):
                pipeline.command_for(next(s for s in self.plan['stages'] if s['id'] == name), args)
        for rows, device in ((32, 'mps'), (True, 'cpu'), (257, 'cpu'), (-1, 'cpu')):
            args.cpu_tail_input_rows, args.device = rows, device
            with self.subTest(rows=rows, device=device), self.assertRaises(pipeline.BuildError):
                pipeline.command_for(stage, args)

    def test_companion_guard_success_and_failure_evidence(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as temp:
                args = self.args(Path(temp))
                args.max_worker_rss_mib = 4096
                baseline = {'memory_free_percent': 60, 'swap_used_mib': 0}
                evidence = {'samples': 1, 'hard_memory_quota': False}
                error = pipeline.BuildError('synthetic pressure stop')
                error.resource_guard = evidence
                worker = Mock()
                with patch.object(pipeline, 'host_pressure', return_value=baseline), \
                        patch.object(pipeline.subprocess, 'Popen', return_value=worker) as launch, \
                        patch.object(pipeline, 'wait_worker', side_effect=error if fail else None,
                                     return_value=(0, evidence)) as wait:
                    if fail:
                        with self.assertRaisesRegex(pipeline.BuildError, 'pressure stop'):
                            pipeline.run_stage(self.plan, args)
                        self.assertFalse((args.work_dir / 'dispatch-atlases.json').exists())
                        failure = json.loads(next(args.work_dir.glob('failure-atlases-*.json')).read_text())
                        self.assertEqual(failure['resource_guard'], evidence)
                    else:
                        receipt = pipeline.run_stage(self.plan, args)
                        self.assertEqual(receipt['resource_guard'], evidence)
                        self.assertFalse(receipt['complete_runtime_pack'])
                    launch.assert_called_once()
                    self.assertIs(wait.call_args.args[0], worker)

    def test_guarded_preflight_refuses_before_launch_or_workspace_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            args = self.args(Path(temp))
            args.min_memory_free_percent = 50
            with patch.object(pipeline, 'host_pressure', return_value={
                    'memory_free_percent': 49, 'swap_used_mib': 0}), \
                    patch.object(pipeline.subprocess, 'Popen') as launch, \
                    self.assertRaisesRegex(pipeline.BuildError, 'Available-memory'):
                pipeline.run_stage(self.plan, args)
            launch.assert_not_called()
            self.assertFalse(args.work_dir.exists())


if __name__ == '__main__':
    unittest.main()

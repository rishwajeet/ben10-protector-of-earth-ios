import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from tools import replay_personal_texture_batches as batches


class TextureBatchTests(unittest.TestCase):
    def test_cached_batch_redecodes_original_and_checks_exact_pixels(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'candidates').mkdir()
            image = Image.new('RGB', (2, 2), (12, 34, 56))
            image.save(work / 'candidates' / 'sample.png')
            entry = {'id': 'sample', 'dimensions': [2, 2],
                'reference_rgba8_sha256': hashlib.sha256(image.convert('RGBA').tobytes()).hexdigest(),
                'operation': {'kind': 'source-constant'}}
            decode = Mock()
            receipt = batches.cached_batch([entry], work, {}, decode)
            decode.assert_called_once_with(entry)
            self.assertEqual(receipt['exact_pixel_matches'], 1)
            self.assertEqual(receipt['bounded_rounding_matches'], 0)
            entry['reference_rgba8_sha256'] = '0' * 64
            with self.assertRaises(batches.BuildError):
                batches.cached_batch([entry], work, {}, decode)
            self.assertIsNone(batches.cached_batch([dict(entry, id='absent')], work, {}, decode))

    def run_fixture(self, directory, *, free=20 * 1024**3, wrong_receipt=False, max_new_workers=None,
                    device='mps', mps_memory_fraction=0.5, dat_window_batch_size=0,
                    defer_entry=None, batch_size=2, cpu_conv_output_rows=0):
        work = Path(directory) / 'work'
        work.mkdir()
        contract = {'entry_count': 3, 'source_lock_sha256': batches.digest_file(batches.LOCK), 'entries': [
            {'id': str(i), 'occurrence': {'package': '1.gcs'},
             'operation': {'kind': 'source-constant'}} for i in range(3)]}
        args = argparse.Namespace(kind=['source-constant'], work_dir=work,
            game=Path(directory) / 'game', provider='cpu', model_dir=None,
            numerical_reference=None, batch_size=batch_size, max_new_workers=max_new_workers, defer_entry=defer_entry,
            device=device, mps_memory_fraction=mps_memory_fraction, dat_window_batch_size=dat_window_batch_size,
            cpu_conv_output_rows=cpu_conv_output_rows)
        (work / 'owner.json').write_text(json.dumps({'game': str(args.game.resolve())}))
        commands = []
        def launch(command):
            commands.append(command)
            ids = [command[i+1] for i, item in enumerate(command) if item == '--entry']
            receipt = {'entries': [{'id': key} for key in ids], 'selected': len(ids),
                'seconds': .01, 'exact_pixel_matches': len(ids), 'bounded_rounding_matches': 0}
            if wrong_receipt:
                receipt['entries'][0]['id'] = 'unrequested'
            (work / 'receipt.json').write_text(json.dumps(receipt))
            return Mock(wait=Mock(return_value=0))
        with patch.object(batches, 'load_contract', return_value=contract), \
                patch.object(batches, 'validate_contract'), \
                patch.object(batches, 'check_table'), \
                patch.object(batches.shutil, 'disk_usage', return_value=SimpleNamespace(free=free)), \
                patch.object(batches.subprocess, 'Popen', side_effect=launch):
            return batches.run_batches(args), commands, work

    def test_bounded_workers_and_aggregate_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            result, commands, work = self.run_fixture(directory)
            self.assertEqual([c.count('--entry') for c in commands], [2, 1])
            self.assertTrue(all(c[c.index('--cpu-conv-output-rows')+1] == '0' for c in commands))
            self.assertEqual(result['completed_entries'], 3)
            self.assertEqual(result['exact_pixel_matches'], 3)
            self.assertTrue(result['complete_texture_pack'])
            progress = json.loads((work / 'batch-progress.json').read_text())
            self.assertEqual(progress['status'], 'complete-selected-operations')
            self.assertEqual(len(list((work / 'batch-receipts').glob('*.json'))), 2)

    def test_low_storage_and_mismatched_receipt_stop(self):
        for options in ({'free': 9 * 1024**3}, {'wrong_receipt': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(batches.BuildError):
                    self.run_fixture(directory, **options)

    def test_worker_limit_does_not_claim_remaining_entries_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            result, commands, work = self.run_fixture(directory, max_new_workers=1)
            self.assertEqual(len(commands), 1)
            self.assertEqual(result['selected_entries'], 3)
            self.assertEqual(result['completed_entries'], 2)
            self.assertFalse(result['complete_texture_pack'])
            self.assertTrue(result['stopped_at_new_worker_limit'])
            progress = json.loads((work / 'batch-progress.json').read_text())
            self.assertEqual(progress['status'], 'stopped-at-new-worker-limit')
            self.assertEqual(len(progress['batches']), 1)

    def test_explicit_device_and_memory_options_reach_each_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            _, commands, _ = self.run_fixture(directory, device='cpu', mps_memory_fraction=0.1,
                                              dat_window_batch_size=32, cpu_conv_output_rows=64)
            for command in commands:
                self.assertEqual(command[command.index('--device')+1], 'cpu')
                self.assertEqual(command[command.index('--mps-memory-fraction')+1], '0.1')
                self.assertEqual(command[command.index('--dat-window-batch-size')+1], '32')
                self.assertEqual(command[command.index('--cpu-conv-output-rows')+1], '64')

    def test_cpu_convolution_bound_rejects_wrong_device_or_bad_size(self):
        for options in ({'cpu_conv_output_rows': 64},
                        {'device': 'cpu', 'cpu_conv_output_rows': 257},
                        {'device': 'cpu', 'cpu_conv_output_rows': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(batches.BuildError):
                    self.run_fixture(directory, **options)

    def test_deferral_keeps_full_total_and_incomplete_status(self):
        for cap in (None, 1):
            with self.subTest(cap=cap), tempfile.TemporaryDirectory() as directory:
                result, commands, work = self.run_fixture(directory, batch_size=1,
                    defer_entry=['0'], max_new_workers=cap)
                self.assertEqual(result['selected_entries'], 3)
                self.assertEqual(result['completed_entries'], 2 if cap is None else 1)
                self.assertEqual(result['deferred_sources'], ['0'])
                self.assertFalse(result['complete_texture_pack'])
                self.assertEqual(result['stopped_at_new_worker_limit'], cap == 1)
                self.assertTrue(all(command[command.index('--entry')+1] != '0' for command in commands))
                progress = json.loads((work / 'batch-progress.json').read_text())
                self.assertEqual(progress['deferred_sources'], ['0'])
                self.assertEqual(progress['status'], 'stopped-with-deferred-entries' if cap is None
                                 else 'stopped-at-new-worker-limit')

    def test_deferral_rejects_unknown_ids_and_multi_entry_workers(self):
        for options in ({'defer_entry': ['unknown'], 'batch_size': 1}, {'defer_entry': ['0']}):
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(batches.BuildError):
                self.run_fixture(directory, **options)

    def test_all_deferred_is_not_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            result, commands, work = self.run_fixture(directory, batch_size=1, defer_entry=['0', '1', '2'])
            self.assertEqual(result['selected_entries'], 3)
            self.assertEqual(result['completed_entries'], 0)
            self.assertFalse(commands)
            self.assertFalse(result['complete_texture_pack'])
            self.assertEqual(json.loads((work / 'batch-progress.json').read_text())['status'],
                             'stopped-with-deferred-entries')

    def test_pressure_parser_and_invalid_readback(self):
        with patch.object(batches.sys, 'platform', 'darwin'), patch.object(batches.subprocess, 'check_output',
                side_effect=['total = 32G used = 20.5G free = 11.5G', 'System-wide memory free percentage: 76%']):
            self.assertEqual(batches.host_pressure(), {'swap_used_mib': 20992, 'memory_free_percent': 76})
        with patch.object(batches.sys, 'platform', 'darwin'), patch.object(batches.subprocess, 'check_output',
                side_effect=['unavailable', 'System-wide memory free percentage: 76%']), self.assertRaises(batches.BuildError):
            batches.host_pressure()

    def test_pressure_thresholds_and_exact_boundaries(self):
        limits = {'max_worker_rss_mib': 4096, 'max_swap_growth_mib': 256, 'min_memory_free_percent': 50}
        baseline = {'swap_used_mib': 20000, 'memory_free_percent': 76}
        batches.check_pressure({'swap_used_mib': 20256, 'memory_free_percent': 50}, baseline, limits, 4096)
        for state, rss in [({'swap_used_mib': 20257, 'memory_free_percent': 76}, 100),
                           ({'swap_used_mib': 20000, 'memory_free_percent': 49}, 100),
                           (baseline, 4097)]:
            with self.subTest(state=state, rss=rss), self.assertRaises(batches.BuildError):
                batches.check_pressure(state, baseline, limits, rss)
        for args in [SimpleNamespace(max_worker_rss_mib=0), SimpleNamespace(min_memory_free_percent=101)]:
            with self.assertRaises(batches.BuildError):
                batches.pressure_limits(args)

    def test_guard_records_sample_without_stopping_successful_worker(self):
        worker = Mock(pid=123, wait=Mock(side_effect=[subprocess.TimeoutExpired('worker', 2), 0]))
        baseline = {'swap_used_mib': 20000, 'memory_free_percent': 76}
        limits = {'max_worker_rss_mib': 4096, 'max_swap_growth_mib': 256, 'min_memory_free_percent': 50}
        with patch.object(batches, 'host_pressure', return_value=baseline), patch.object(batches.subprocess, 'run',
                return_value=SimpleNamespace(returncode=0, stdout='1048576')) as ps:
            status, evidence = batches.wait_worker(worker, limits, baseline)
        self.assertEqual(status, 0)
        self.assertEqual(evidence['samples'], 1)
        self.assertEqual(evidence['peak_sampled_rss_mib'], 1024)
        self.assertFalse(evidence['hard_memory_quota'])
        self.assertEqual(ps.call_args.args[0][-1], '123')
        worker.send_signal.assert_not_called()

    def test_mps_allocation_fraction_is_bounded_and_applied(self):
        from tools.personal_textures import configure_torch
        torch = Mock()
        configure_torch(torch, 0.1)
        torch.mps.set_per_process_memory_fraction.assert_called_once_with(0.1)
        torch.set_num_threads.assert_called_once_with(4)
        for value in (0, -1, 0.51, float('nan'), float('inf'), True, '0.1'):
            with self.subTest(value=value), self.assertRaises(batches.BuildError):
                configure_torch(torch, value)
        self.assertEqual(torch.mps.set_per_process_memory_fraction.call_count, 1)
        cpu = Mock()
        configure_torch(cpu, 0.1, 'cpu')
        cpu.set_num_threads.assert_called_once_with(4)
        cpu.mps.set_per_process_memory_fraction.assert_not_called()
        with self.assertRaises(batches.BuildError):
            configure_torch(cpu, 0.1, 'unknown')

    def test_guard_failure_interrupts_only_owned_worker(self):
        worker = Mock(pid=123, poll=Mock(return_value=None),
                      wait=Mock(side_effect=[subprocess.TimeoutExpired('worker', 2), 0]))
        baseline = {'swap_used_mib': 20000, 'memory_free_percent': 76}
        limits = {'max_worker_rss_mib': 4096, 'max_swap_growth_mib': 256, 'min_memory_free_percent': 50}
        with patch.object(batches, 'host_pressure', side_effect=batches.BuildError('unavailable')), \
                self.assertRaises(batches.BuildError) as caught:
            batches.wait_worker(worker, limits, baseline)
        self.assertEqual(caught.exception.resource_guard['samples'], 0)
        self.assertEqual(caught.exception.resource_guard['baseline'], baseline)
        worker.send_signal.assert_called_once_with(batches.signal.SIGINT)
        worker.kill.assert_not_called()

    def test_failed_worker_preserves_diagnostic_and_incomplete_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            error = batches.BuildError('Available-memory guard stopped replay')
            error.resource_guard = {'minimum_sampled_memory_free_percent': 49, 'hard_memory_quota': False}
            with patch.object(batches, 'wait_worker', side_effect=error), self.assertRaises(batches.BuildError):
                self.run_fixture(directory)
            work = Path(directory) / 'work'
            progress = json.loads((work / 'batch-progress.json').read_text())
            self.assertEqual(progress['status'], 'stopped-on-worker-error')
            self.assertEqual(progress['completed_entries'], 0)
            self.assertFalse(progress['complete_texture_pack'])
            failure = json.loads((work / progress['failure_receipt']).read_text())
            self.assertEqual(failure['sources'], ['0', '1'])
            self.assertEqual(failure['error'], str(error))
            self.assertEqual(failure['resource_guard'], error.resource_guard)

    def test_nonzero_worker_exit_preserves_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(batches, 'wait_worker', return_value=(7, None)), self.assertRaises(batches.BuildError):
                self.run_fixture(directory)
            work = Path(directory) / 'work'
            progress = json.loads((work / 'batch-progress.json').read_text())
            failure = json.loads((work / progress['failure_receipt']).read_text())
            self.assertIn('exit 7', failure['error'])
            self.assertEqual(failure['new_workers_completed'], 0)

    def test_stuck_owned_worker_is_killed_after_interrupt_grace(self):
        worker = Mock(poll=Mock(return_value=None), wait=Mock(side_effect=[subprocess.TimeoutExpired('worker', 10), 0]))
        batches.stop_worker(worker)
        worker.send_signal.assert_called_once_with(batches.signal.SIGINT)
        worker.kill.assert_called_once_with()


if __name__ == '__main__':
    unittest.main()

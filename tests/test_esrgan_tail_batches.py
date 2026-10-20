from types import SimpleNamespace
import unittest
from unittest.mock import patch

import torch
from spandrel.architectures.ESRGAN.__arch.RRDB import RRDBNet
from tools.esrgan_tail_batches import install_cpu_tail_batches, streamed_tail
from tools.dat_window_batches import install_cpu_convolution_batches


class EsrganTailBatchTests(unittest.TestCase):
    def descriptor(self, **kwargs):
        return SimpleNamespace(architecture=SimpleNamespace(id='ESRGAN'),
            model=RRDBNet(num_filters=4, num_blocks=1, **kwargs).eval())

    def test_full_model_and_combined_convolution_bound_preserve_output(self):
        torch.set_num_threads(2)
        torch.manual_seed(124)
        for height, width, rows in ((1, 3, 1), (3, 5, 1), (9, 13, 3), (17, 11, 4), (7, 9, 32)):
            with self.subTest(height=height, width=width, rows=rows):
                descriptor = self.descriptor()
                inputs = torch.rand(2, 3, height, width)
                with torch.inference_mode():
                    expected = descriptor.model(inputs)
                    install_cpu_convolution_batches(descriptor, 3)
                    evidence = install_cpu_tail_batches(descriptor, rows)
                    actual = descriptor.model(inputs)
                torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6)
                self.assertEqual(tuple(actual.shape), (2, 3, height * 4, width * 4))
                self.assertEqual(evidence['full_canvas_trunk_calls'], 1)
                self.assertEqual(evidence['tail_strips'], (height + rows - 1) // rows)
                self.assertLessEqual(evidence['maximum_tail_input_rows'], rows + 4)
                self.assertFalse(evidence['input_image_tiling'])

    def test_exact_halos_include_interior_seams_and_true_outer_edges(self):
        torch.set_num_threads(2)
        torch.manual_seed(125)
        layers = tuple(self.descriptor().model.model.children())[2:]
        with torch.inference_mode():
            for layer in layers:
                if type(layer) is torch.nn.Conv2d:
                    # Nonnegative integer inputs/weights avoid backend rounding
                    # and negative-slope arithmetic hiding a missing halo row.
                    layer.weight.copy_(torch.randint(0, 2, layer.weight.shape).float())
                    layer.bias.zero_()
            features = torch.randint(0, 2, (1, 4, 13, 9)).float()
            expected = features
            for layer in layers:
                expected = layer(expected)
            for rows in (1, 2, 3, 5, 13, 32):
                actual = streamed_tail(features, layers, rows)
                torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_nonstandard_tail_and_architecture_are_rejected(self):
        for modify in (
                lambda d: setattr(d.model, 'shuffle_factor', 2),
                lambda d: setattr(d.model, 'scale', 2),
                lambda d: setattr(d.architecture, 'id', 'DAT'),
                lambda d: setattr(d.model.model[2], 'mode', 'bilinear'),
                lambda d: setattr(d.model.model[3], 'padding', (0, 0)),
                lambda d: setattr(d.model.model[4], 'negative_slope', 0.1),
                lambda d: d.model.train(), lambda d: d.model.double()):
            descriptor = self.descriptor(); modify(descriptor)
            with self.assertRaises(ValueError):
                install_cpu_tail_batches(descriptor, 4)

    def test_inference_only_rows_source_identity_and_duplicate_install(self):
        descriptor = self.descriptor()
        for rows in (0, 257, True):
            with self.assertRaises(ValueError):
                install_cpu_tail_batches(descriptor, rows)
        with patch('tools.esrgan_tail_batches.ESRGAN_SOURCES', {
                'spandrel.architectures.ESRGAN.__arch.RRDB': '0' * 64}), self.assertRaises(ValueError):
            install_cpu_tail_batches(descriptor, 4)
        install_cpu_tail_batches(descriptor, 4)
        with self.assertRaises(ValueError):
            install_cpu_tail_batches(descriptor, 4)
        with self.assertRaises(ValueError):
            descriptor.model(torch.rand(1, 3, 5, 7))


if __name__ == '__main__':
    unittest.main()

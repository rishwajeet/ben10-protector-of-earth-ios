from types import MethodType, SimpleNamespace
import unittest
from unittest.mock import patch
import torch
from spandrel.architectures.DAT.__arch.DAT import Spatial_Attention
from tools.dat_window_batches import (install_cpu_convolution_batches, install_window_batches,
                                     row_bounded_convolution, windowed_attention)


class DatWindowBatchTests(unittest.TestCase):
    def test_original_window_math_and_masks_for_multiple_images(self):
        torch.set_num_threads(2)
        torch.manual_seed(121)
        for index, positional, masked in ((0, True, True), (1, True, False), (0, False, True)):
            with self.subTest(index=index, positional=positional, masked=masked):
                layer = Spatial_Attention(48, index, split_size=[4, 8], num_heads=3,
                                          position_bias=positional).eval()
                inputs = torch.randn(3, 2, 16*32, 48)
                mask = torch.randn(16, 32, 32) if masked else None
                with torch.inference_mode():
                    expected = layer(inputs, 16, 32, mask)
                    layer._window_batch_size = 3
                    actual = windowed_attention(layer, inputs, 16, 32, mask)
                torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_install_validates_architecture_and_inference(self):
        layer = Spatial_Attention(48, 0, split_size=[4, 8], num_heads=3).eval()
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='DAT'), model=layer)
        result = install_window_batches(descriptor, 3)
        self.assertEqual(result['spatial_layers'], 1)
        self.assertFalse(result['input_image_tiling'])
        self.assertIsInstance(layer.forward, MethodType)
        with self.assertRaises(ValueError):
            layer(torch.randn(3, 1, 8*8, 48), 8, 8)
        for size in (0, 129, True):
            with self.assertRaises(ValueError):
                install_window_batches(descriptor, size)
        descriptor.architecture.id = 'other'
        with self.assertRaises(ValueError):
            install_window_batches(descriptor, 3)

    def test_cpu_heap_hook_retains_output_and_records_relief(self):
        layer = Spatial_Attention(48, 0, split_size=[4, 8], num_heads=3).eval()
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='DAT'), model=layer)
        inputs = torch.randn(3, 1, 8*8, 48)
        with torch.inference_mode():
            expected = layer(inputs, 8, 8)
            evidence = install_window_batches(descriptor, 3, release_cpu_cache=True)
            with patch('tools.dat_window_batches.release_cached_heap', return_value=123):
                actual = layer(inputs, 8, 8)
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)
        self.assertEqual(evidence['heap_relief_calls'], 1)
        self.assertEqual(evidence['heap_released_bytes'], 123)

    def test_convolution_halos_cover_strides_dilation_groups_and_edge_rows(self):
        torch.set_num_threads(2)
        torch.manual_seed(122)
        for kernel, padding, stride, dilation, groups, height, rows in (
                (3, 1, 1, 1, 1, 17, 4), (3, 2, 2, 2, 2, 17, 4),
                (1, 0, 1, 1, 1, 17, 4), (3, 0, 1, 1, 2, 17, 3),
                (3, 6, 1, 1, 1, 2, 2), (3, 1, 1, 1, 1, 3, 8)):
            with self.subTest(kernel=kernel, padding=padding, stride=stride,
                              dilation=dilation, groups=groups, height=height, rows=rows):
                layer = torch.nn.Conv2d(4, 6, kernel, stride=stride, padding=padding,
                                        dilation=dilation, groups=groups).eval()
                inputs = torch.randint(-3, 4, (2, 4, height, 13)).float()
                with torch.inference_mode():
                    # Exact integers separate halo/indexing correctness from
                    # backend-dependent floating-point reduction rounding.
                    layer.weight.copy_(torch.randint(-2, 3, layer.weight.shape).float())
                    layer.bias.copy_(torch.randint(-2, 3, layer.bias.shape).float())
                    expected = layer(inputs)
                    layer._cpu_conv_output_rows = rows
                    actual = row_bounded_convolution(layer, inputs)
                torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_convolution_install_is_cpu_fp32_inference_only(self):
        layer = torch.nn.Conv2d(3, 5, 3, padding=1).eval()
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='DAT'), model=layer)
        inputs = torch.randn(1, 3, 17, 19)
        with torch.inference_mode():
            expected = layer(inputs)
            evidence = install_cpu_convolution_batches(descriptor, 4)
            actual = layer(inputs)
        torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6)
        self.assertEqual(evidence['convolution_layers'], 1)
        self.assertTrue(evidence['complete_receptive_fields'])
        self.assertFalse(evidence['input_image_tiling'])
        with self.assertRaises(ValueError):
            layer(inputs)
        for rows in (0, 257, True):
            with self.assertRaises(ValueError):
                install_cpu_convolution_batches(descriptor, rows)
        layer.double()
        with self.assertRaises(ValueError):
            install_cpu_convolution_batches(descriptor, 4)

    def test_convolution_rejects_unqualified_padding_and_architecture(self):
        layer = torch.nn.Conv2d(3, 5, 3, padding=1, padding_mode='reflect').eval()
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='DAT'), model=layer)
        with self.assertRaises(ValueError):
            install_cpu_convolution_batches(descriptor, 4)
        descriptor.architecture.id = 'other'
        with self.assertRaises(ValueError):
            install_cpu_convolution_batches(descriptor, 4)

    def test_esrgan_full_residual_and_upsampling_graph_preserves_pixels(self):
        from spandrel.architectures.ESRGAN.__arch.RRDB import RRDBNet
        torch.set_num_threads(2)
        torch.manual_seed(123)
        model = RRDBNet(num_filters=8, num_blocks=1, scale=4).eval()
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='ESRGAN'), model=model)
        inputs = torch.rand(1, 3, 9, 13)
        with torch.inference_mode():
            expected = model(inputs)
            evidence = install_cpu_convolution_batches(descriptor, 3)
            actual = model(inputs)
        torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6)
        self.assertEqual(tuple(actual.shape), (1, 3, 36, 52))
        self.assertEqual(evidence['architecture'], 'ESRGAN')
        self.assertEqual(len(evidence['upstream_esrgan_sources']), 2)
        self.assertFalse(evidence['input_image_tiling'])

    def test_esrgan_source_drift_is_rejected(self):
        descriptor = SimpleNamespace(architecture=SimpleNamespace(id='ESRGAN'),
                                     model=torch.nn.Conv2d(3, 3, 1).eval())
        with patch('tools.dat_window_batches.ESRGAN_SOURCES', {
                'spandrel.architectures.ESRGAN.__arch.RRDB': '0' * 64}), \
                self.assertRaisesRegex(ValueError, 'needs requalification'):
            install_cpu_convolution_batches(descriptor, 4)

"""Bound the pinned ESRGAN 4x upsampling tail, not its full-image RRDB trunk.

The two nearest-neighbor 2x upsamplers and four 3x3 convolutions require two
input-feature rows of halo at each strip boundary. Complete width and true
external zero padding are retained; no overlap blending or image tiling occurs.
Different convolution shapes can round differently: final pixel admission is
still mandatory. The default model implementation is never changed implicitly.
"""
import hashlib
import importlib
from pathlib import Path
from types import MethodType

from tools.dat_window_batches import ESRGAN_SOURCES


def streamed_tail(features, layers, rows, evidence=None):
    import torch
    if torch.is_grad_enabled() or features.device.type != 'cpu' or \
            features.dtype != torch.float32 or features.ndim != 4:
        raise ValueError('ESRGAN tail strips require CPU FP32 inference')
    if type(rows) is not int or not 1 <= rows <= 256:
        raise ValueError('ESRGAN tail input rows must be 1 through 256')
    batch, _, height, width = features.shape
    result = features.new_empty((batch, 3, height * 4, width * 4))
    for start in range(0, height, rows):
        end = min(height, start + rows)
        first, last = max(0, start - 2), min(height, end + 2)
        block = features[:, :, first:last, :]
        for layer in layers:
            block = layer(block)
        if tuple(block.shape) != (batch, 3, (last - first) * 4, width * 4):
            raise ValueError('ESRGAN tail changed its admitted 4x RGB geometry')
        result[:, :, start * 4:end * 4, :] = block[:, :, (start - first) * 4:(end - first) * 4, :]
        del block
        if evidence is not None:
            evidence['tail_strips'] += 1
            evidence['maximum_tail_input_rows'] = max(evidence['maximum_tail_input_rows'], last - first)
    return result


def bounded_forward(network, inputs):
    import torch
    if network.training or torch.is_grad_enabled() or inputs.device.type != 'cpu' or \
            inputs.dtype != torch.float32 or inputs.ndim != 4:
        raise ValueError('ESRGAN tail batching requires evaluated CPU FP32 inference')
    # These two modules include the complete, unchanged residual-dense trunk.
    # Only its output feature tensor is subsequently divided into strips.
    features = network.model[1](network.model[0](inputs))
    network._cpu_tail_evidence['full_canvas_trunk_calls'] += 1
    return streamed_tail(features, tuple(network.model.children())[2:],
                         network._cpu_tail_input_rows, network._cpu_tail_evidence)


def install_cpu_tail_batches(descriptor, rows):
    import torch
    from spandrel.architectures.ESRGAN.__arch.RRDB import RRDBNet
    from spandrel.architectures.__arch_helpers.block import ShortcutBlock
    if type(rows) is not int or not 1 <= rows <= 256:
        raise ValueError('ESRGAN tail input rows must be 1 through 256')
    for name, expected in ESRGAN_SOURCES.items():
        module = importlib.import_module(name)
        if hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest() != expected:
            raise ValueError('ESRGAN implementation changed; tail batching needs requalification')
    network = descriptor.model
    if descriptor.architecture.id != 'ESRGAN' or type(network) is not RRDBNet or \
            network.shuffle_factor is not None or network.scale != 4 or network.training or \
            any(p.device.type != 'cpu' or p.dtype != torch.float32 for p in network.parameters()) or \
            any(layer.training for layer in network.modules()):
        raise ValueError('Tail batching requires the evaluated CPU FP32 4x unshuffled ESRGAN')
    if type(network.model) is not torch.nn.Sequential or hasattr(network, '_cpu_tail_input_rows'):
        raise ValueError('ESRGAN tail graph is nonstandard or already patched')
    layers = list(network.model.children())
    expected_types = [torch.nn.Conv2d, ShortcutBlock, torch.nn.Upsample,
        torch.nn.Conv2d, torch.nn.LeakyReLU, torch.nn.Upsample,
        torch.nn.Conv2d, torch.nn.LeakyReLU, torch.nn.Conv2d,
        torch.nn.LeakyReLU, torch.nn.Conv2d]
    if [type(layer) for layer in layers] != expected_types:
        raise ValueError('Only the pinned nearest-upsample and local-convolution tail is admitted')
    filters = layers[0].out_channels
    for index in (0, 3, 6, 8, 10):
        layer = layers[index]
        expected_channels = (3 if index == 0 else filters, 3 if index == 10 else filters)
        if (layer.in_channels, layer.out_channels) != expected_channels or \
                layer.kernel_size != (3, 3) or layer.stride != (1, 1) or \
                layer.padding != (1, 1) or layer.dilation != (1, 1) or \
                layer.groups != 1 or layer.padding_mode != 'zeros':
            raise ValueError('ESRGAN tail convolution geometry changed')
    for index in (2, 5):
        layer = layers[index]
        if layer.mode != 'nearest' or layer.scale_factor != 2.0 or layer.size is not None or \
                layer.align_corners is not None or layer.recompute_scale_factor not in (None, False):
            raise ValueError('ESRGAN tail requires exact nearest-neighbor 2x upsampling')
    for index in (4, 7, 9):
        if layers[index].negative_slope != 0.2:
            raise ValueError('ESRGAN tail activation changed')
    evidence = {'input_feature_rows_per_strip': rows, 'halo_input_rows': 2,
        'upsample_scale': 4, 'upstream_esrgan_sources': dict(ESRGAN_SOURCES),
        'full_canvas_residual_trunk': True, 'input_image_tiling': False,
        'complete_receptive_fields': True, 'overlap_blending': False,
        'whole_model_pixel_qualification_required': True,
        'full_canvas_trunk_calls': 0, 'tail_strips': 0, 'maximum_tail_input_rows': 0}
    network._cpu_tail_input_rows = rows
    network._cpu_tail_evidence = evidence
    network.forward = MethodType(bounded_forward, network)
    return evidence

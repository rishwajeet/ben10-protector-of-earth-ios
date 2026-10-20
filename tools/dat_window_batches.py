"""Bound DAT's independent spatial-window work without tiling the input image.

Uses the installed Spandrel 0.4.2 DAT partition/merge and learned bias modules.
Architecture source: chaiNNer-org/spandrel, architectures/DAT/__arch/DAT.py.
Only inference is supported. Original windows, masks, FP32 arithmetic and
within-window reductions are retained; output still needs normal pixel admission.
The independent CPU convolution-row bound also supports source-pinned ESRGAN;
its residual/upsampling graph remains unchanged and consumes full feature maps.
"""
import hashlib
import importlib
from functools import lru_cache
from pathlib import Path
import sys
from types import MethodType

DAT_SOURCE_SHA256 = '9e7b8e8926fb905275a5d8a29fcc185210f85e38ba8e41f82d80f816d98bd121'
ESRGAN_SOURCES = {
    'spandrel.architectures.ESRGAN.__arch.RRDB': '323f23baf4022b79486610da9eda81f369c71fdcced3639153de76a3ce7ee5f5',
    'spandrel.architectures.__arch_helpers.block': 'e0dc18e008cd58a941428bdbccace510124cc0a65f16806f2b79aee82a00be8f',
}


def windowed_attention(layer, qkv, height, width, mask=None):
    import torch
    from spandrel.architectures.DAT.__arch.DAT import windows2img
    if layer.training or torch.is_grad_enabled():
        raise ValueError('Window batching is inference-only')
    batch, tokens, channels = qkv[0].shape
    if tokens != height * width or qkv.dtype != torch.float32:
        raise ValueError('Expected full-image FP32 DAT attention input')
    queries, keys, values = (layer.im2win(part, height, width) for part in qkv)
    queries = queries * layer.scale
    window_tokens = layer.H_sp * layer.W_sp
    windows_per_image = queries.shape[0] // batch
    if mask is not None and tuple(mask.shape) != (windows_per_image, window_tokens, window_tokens):
        raise ValueError('Unexpected shifted-window mask layout')
    bias = None
    if layer.position_bias:
        learned = layer.pos(layer.rpe_biases)
        bias = learned[layer.relative_position_index.reshape(-1)].reshape(
            window_tokens, window_tokens, layer.num_heads).permute(2, 0, 1).contiguous()
    pieces = []
    for image in range(batch):
        for start in range(0, windows_per_image, layer._window_batch_size):
            end = min(start + layer._window_batch_size, windows_per_image)
            selection = slice(image * windows_per_image + start, image * windows_per_image + end)
            scores = queries[selection] @ keys[selection].transpose(-2, -1)
            if bias is not None:
                scores = scores + bias.unsqueeze(0)
            if mask is not None:
                scores = scores + mask[start:end].unsqueeze(1)
            weights = torch.nn.functional.softmax(scores, dim=-1, dtype=scores.dtype)
            output = layer.attn_drop(weights) @ values[selection]
            pieces.append(output.transpose(1, 2).reshape(end-start, window_tokens, channels))
    return windows2img(torch.cat(pieces, dim=0), layer.H_sp, layer.W_sp, height, width)


@lru_cache(maxsize=1)
def heap_reliever():
    if sys.platform != 'darwin':
        raise ValueError('CPU heap relief currently requires macOS')
    import ctypes
    function = ctypes.CDLL(None).malloc_zone_pressure_relief
    function.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    function.restype = ctypes.c_size_t
    return function


def release_cached_heap():
    # Public macOS malloc API: NULL examines this process's zones; zero requests
    # maximal release of unused pages. It does not free live allocations.
    return int(heap_reliever()(None, 0))


def row_bounded_convolution(layer, inputs):
    """Evaluate complete convolution receptive fields in bounded output rows.

    This does not divide the image passed through DAT attention. It only bounds
    one local convolution's workspace; every row retains its exact input halo.
    Backend rounding can differ, so normal end-to-end pixel admission is required.
    """
    import torch
    from torch.nn import functional as functional
    if layer.training or torch.is_grad_enabled() or inputs.device.type != 'cpu' or \
            inputs.dtype != torch.float32 or inputs.ndim != 4:
        raise ValueError('Row-bounded convolution requires CPU FP32 inference')
    rows = layer._cpu_conv_output_rows
    batch, _channels, height, width = inputs.shape
    ph, pw = layer.padding
    sh, sw = layer.stride
    dh, dw = layer.dilation
    kh, kw = layer.kernel_size
    out_height = (height + 2 * ph - dh * (kh - 1) - 1) // sh + 1
    out_width = (width + 2 * pw - dw * (kw - 1) - 1) // sw + 1
    if out_height <= 0 or out_width <= 0:
        raise ValueError('Convolution has no output pixels')
    if out_height <= rows:
        return functional.conv2d(inputs, layer.weight, layer.bias, layer.stride,
                                 layer.padding, layer.dilation, layer.groups)
    result = inputs.new_empty((batch, layer.out_channels, out_height, out_width))
    for start in range(0, out_height, rows):
        end = min(start + rows, out_height)
        first = start * sh - ph
        last = (end - 1) * sh - ph + dh * (kh - 1) + 1
        source = inputs[:, :, min(height, max(0, first)):max(0, min(height, last)), :]
        top = max(0, min(last, 0) - first)
        bottom = max(0, last - max(first, height))
        padded = functional.pad(source, (pw, pw, top, bottom))
        block = functional.conv2d(padded, layer.weight, layer.bias, layer.stride,
                                  0, layer.dilation, layer.groups)
        if tuple(block.shape) != (batch, layer.out_channels, end - start, out_width):
            raise ValueError('Convolution row/halo coverage differs')
        result[:, :, start:end, :] = block
        del source, padded, block
    return result


def install_cpu_convolution_batches(descriptor, rows):
    """Opt-in local-convolution workspace bound for pinned CPU DAT/ESRGAN."""
    import torch
    if type(rows) is not int or not 1 <= rows <= 256:
        raise ValueError('CPU convolution rows must be an integer from 1 through 256')
    architecture = descriptor.architecture.id
    if architecture not in ('DAT', 'ESRGAN'):
        raise ValueError('CPU convolution batching requires a qualified DAT or ESRGAN architecture')
    sources = {'spandrel.architectures.DAT.__arch.DAT': DAT_SOURCE_SHA256} if architecture == 'DAT' else ESRGAN_SOURCES
    for name, expected in sources.items():
        module = importlib.import_module(name)
        if hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest() != expected:
            raise ValueError(architecture + ' implementation changed; convolution batching needs requalification')
    if descriptor.model.training or \
            any(p.device.type != 'cpu' or p.dtype != torch.float32 for p in descriptor.model.parameters()):
        raise ValueError('CPU convolution batching requires evaluated FP32 DAT or ESRGAN')
    layers = [layer for layer in descriptor.model.modules() if type(layer) is torch.nn.Conv2d]
    if not layers or any(layer.padding_mode != 'zeros' or isinstance(layer.padding, str)
                         or layer.training for layer in layers):
        raise ValueError('Expected evaluated zero-padded Conv2d layers')
    for layer in layers:
        layer._cpu_conv_output_rows = rows
        layer.forward = MethodType(row_bounded_convolution, layer)
    return {'output_rows_per_convolution': rows, 'convolution_layers': len(layers),
            **({'upstream_dat_sha256': DAT_SOURCE_SHA256} if architecture == 'DAT' else
               {'upstream_esrgan_sources': dict(sources)}),
            'architecture': architecture, 'input_image_tiling': False,
            'complete_receptive_fields': True, 'whole_model_pixel_qualification_required': True}


def install_window_batches(descriptor, size, *, release_cpu_cache=False):
    if type(size) is not int or not 1 <= size <= 128:
        raise ValueError('DAT window batch size must be an integer from 1 through 128')
    module = importlib.import_module('spandrel.architectures.DAT.__arch.DAT')
    if hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest() != DAT_SOURCE_SHA256:
        raise ValueError('DAT implementation changed; window batching needs requalification')
    if descriptor.architecture.id != 'DAT':
        raise ValueError('Window batching requires the qualified DAT architecture')
    layers = [layer for layer in descriptor.model.modules() if type(layer) is module.Spatial_Attention]
    if not layers or any(layer.training for layer in layers):
        raise ValueError('Expected evaluated DAT spatial-attention layers')
    for layer in layers:
        layer._window_batch_size = size
        layer.forward = MethodType(windowed_attention, layer)
    evidence = {'window_batch_size': size, 'spatial_layers': len(layers),
                'upstream_dat_sha256': DAT_SOURCE_SHA256, 'input_image_tiling': False,
                'cpu_heap_relief': release_cpu_cache, 'heap_relief_calls': 0, 'heap_released_bytes': 0}
    if release_cpu_cache:
        if any(parameter.device.type != 'cpu' for parameter in descriptor.model.parameters()):
            raise ValueError('CPU heap relief requires a CPU model')
        def after_forward(_layer, _inputs, _output):
            evidence['heap_released_bytes'] += release_cached_heap()
            evidence['heap_relief_calls'] += 1
        for layer in descriptor.model.modules():
            if type(layer) in (module.Spatial_Attention, module.DATB):
                layer.register_forward_hook(after_forward)
    return evidence

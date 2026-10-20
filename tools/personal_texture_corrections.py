"""Source-only paint repairs and measured monotone glow reconstruction.

The registered regions are scalar selections, not replacement artwork. Every
colour sample comes from the supplied original; unselected pixels stay intact.
"""
import math

from tools.personal_build import BuildError


def validate_repair(spec, width, height):
    if spec.get('mode') not in ('bilinear', 'source-cells') or \
            type(spec.get('inward_feather_source_pixels')) not in (int, float) or \
            not 0 <= spec['inward_feather_source_pixels'] <= 4 or \
            not isinstance(spec.get('regions'), list) or not 1 <= len(spec['regions']) <= 32 or \
            not isinstance(spec.get('exclude'), list) or len(spec['exclude']) > 32:
        raise BuildError('Invalid bounded source repair')
    for shape in spec['regions'] + spec['exclude']:
        if not isinstance(shape, dict) or len(shape) != 1 or next(iter(shape)) not in ('rectangle', 'circle'):
            raise BuildError('Only source rectangles and circles are admitted')
        name, values = next(iter(shape.items()))
        if not isinstance(values, list) or any(type(v) not in (int, float) or not math.isfinite(v) for v in values):
            raise BuildError('Source repair has nonfinite coordinates')
        if name == 'rectangle':
            if len(values) != 4 or not 0 <= values[0] < values[2] <= width or not 0 <= values[1] < values[3] <= height:
                raise BuildError('Repair rectangle is outside the source')
        elif len(values) != 3 or not 0 <= values[0] <= width or not 0 <= values[1] <= height or \
                not 0 < values[2] <= max(width, height):
            raise BuildError('Repair circle is invalid')


def coordinates(length, scale):
    import numpy as np
    return (np.arange(length * scale, dtype=np.float64) + .5) / scale


def shape_distance(shape, x, y):
    import numpy as np
    if 'rectangle' in shape:
        left, top, right, bottom = shape['rectangle']
        return np.minimum(np.minimum(x - left, right - x), np.minimum(y - top, bottom - y))
    cx, cy, radius = shape['circle']
    return radius - np.sqrt((x - cx)**2 + (y - cy)**2)


def repair_mask(spec, width, height, scale):
    import numpy as np
    validate_repair(spec, width, height)
    x, y = np.meshgrid(coordinates(width, scale), coordinates(height, scale))
    distance = np.maximum.reduce([shape_distance(shape, x, y) for shape in spec['regions']])
    for shape in spec['exclude']:
        distance = np.minimum(distance, -shape_distance(shape, x, y))
    feather = spec['inward_feather_source_pixels']
    return (distance > 0).astype(np.float64) if not feather else np.clip(distance / feather, 0, 1)


def wrapped(indices, size, mode):
    import numpy as np
    if mode == 'repeat':
        return indices % size
    if mode == 'clamp':
        return indices.clip(0, size - 1)
    if mode != 'mirror':
        raise BuildError('Unknown original sampler')
    value = indices % (size * 2)
    return np.where(value < size, value, size * 2 - 1 - value)


def reconstruct(source, scale, mode, wraps):
    import numpy as np
    height, width = source.shape[:2]
    if mode == 'source-cells':
        return source.repeat(scale, 0).repeat(scale, 1)
    if mode != 'bilinear':
        raise BuildError('Unknown source reconstruction')
    x, y = coordinates(width, scale) - .5, coordinates(height, scale) - .5
    xi, yi = np.floor(x).astype(int), np.floor(y).astype(int)
    ax, ay = x - xi, y - yi
    x0, x1 = wrapped(xi, width, wraps[1]), wrapped(xi + 1, width, wraps[1])
    y0, y1 = wrapped(yi, height, wraps[0]), wrapped(yi + 1, height, wraps[0])
    top = source[y0[:, None], x0[None, :]] * (1 - ax[None, :, None]) + source[y0[:, None], x1[None, :]] * ax[None, :, None]
    bottom = source[y1[:, None], x0[None, :]] * (1 - ax[None, :, None]) + source[y1[:, None], x1[None, :]] * ax[None, :, None]
    return top * (1 - ay[:, None, None]) + bottom * ay[:, None, None]


def localized_repair(original, prior, scale, wraps, spec):
    import numpy as np
    from PIL import Image
    if prior.size != (original.width * scale, original.height * scale):
        raise BuildError('Source repair dimensions differ')
    source = np.asarray(original.convert('RGB'), dtype=np.float64)
    base = np.asarray(prior.convert('RGB'), dtype=np.uint8)
    mask = repair_mask(spec, original.width, original.height, scale)
    repaired = reconstruct(source, scale, spec['mode'], wraps)
    if not np.isfinite(repaired).all() or repaired.min() < source.min() or repaired.max() > source.max():
        raise BuildError('Source repair left the original colour bounds')
    final = np.rint(base.astype(np.float64) * (1 - mask[:, :, None]) + repaired * mask[:, :, None]).astype(np.uint8)
    if not np.array_equal(final[mask == 0], base[mask == 0]):
        raise BuildError('Source repair changed protected pixels')
    return Image.fromarray(final)


def decreasing(values, weights):
    import numpy as np
    if len(values) != len(weights) or not len(values) or not np.isfinite(values).all() or \
            not np.isfinite(weights).all() or np.any(weights <= 0):
        raise BuildError('Invalid weighted radial profile')
    blocks = []
    for i, (value, weight) in enumerate(zip(values, weights, strict=True)):
        blocks.append([i, i + 1, float(weight), float(value) * float(weight)])
        while len(blocks) > 1 and blocks[-2][3] / blocks[-2][2] < blocks[-1][3] / blocks[-1][2]:
            a, b = blocks[-2:]
            blocks[-2:] = [[a[0], b[1], a[2] + b[2], a[3] + b[3]]]
    result = np.empty_like(values)
    for lo, hi, weight, total in blocks:
        result[lo:hi] = total / weight
    return result


def radial_glow(original, scale):
    import numpy as np
    from PIL import Image
    from scipy.interpolate import PchipInterpolator
    from scipy.ndimage import gaussian_filter1d
    # The original producer quantized the initial normalization to FP32.
    rgb = (np.asarray(original.convert('RGB'), dtype=np.float32) / 255).astype(np.float64)
    height, width = rgb.shape[:2]
    yy, xx = np.indices((height, width), dtype=np.float64)
    xx += .5
    yy += .5
    luminance = rgb @ np.array([.2126, .7152, .0722])
    weights = np.maximum(luminance - .01, 0)**2
    if weights.sum() <= 0:
        raise BuildError('Original glow has no measurable light')
    cx, cy = float((xx * weights).sum() / weights.sum()), float((yy * weights).sum() / weights.sum())
    radius = np.hypot(xx - cx, yy - cy)
    bins = np.arange(0, float(radius.max()) + 1.5, .5)
    bucket = np.floor(radius / .5).astype(int)
    counts = np.bincount(bucket.ravel(), minlength=len(bins)).astype(np.float64)
    profile = np.zeros((len(bins), 3), dtype=np.float64)
    for channel in range(3):
        sums = np.bincount(bucket.ravel(), weights=rgb[:, :, channel].ravel(), minlength=len(bins))
        valid = counts > 0
        measured = np.interp(bins, bins[valid], sums[valid] / counts[valid])
        smooth = gaussian_filter1d(measured, 1.2, mode='nearest')
        profile[:, channel] = decreasing(smooth, np.maximum(counts, 1))
    oy, ox = np.indices((height * scale, width * scale), dtype=np.float64)
    radii = np.hypot((ox + .5) / scale - cx, (oy + .5) / scale - cy)
    output = np.stack([PchipInterpolator(bins + .25, profile[:, c], extrapolate=True)(radii)
        for c in range(3)], axis=2).clip(0, 1)
    if not np.isfinite(output).all():
        raise BuildError('Glow reconstruction is nonfinite')
    return Image.fromarray(np.rint(output * 255).astype(np.uint8))

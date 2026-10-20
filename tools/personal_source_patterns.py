"""Reconstruct selected periodic fields and source-colour facial regions."""
import math

from tools.personal_build import BuildError


PERIODIC = {'degree': 3, 'prefilter': False, 'pixel_centers': True, 'wrap': 'grid-wrap'}
THRESHOLDS = {'R>85,R>=1.13G,G>=1.16B', 'R>70,1.03G<=R<1.80G,G>=1.08B',
    'R>45,R>=1.07G,G>=1.08B', 'G>70,R>48,0.62G<=R<=0.95G,B<=0.95R'}


def validate_periodic(parameters, width, height):
    if {k: parameters.get(k) for k in PERIODIC} != PERIODIC or \
            set(parameters) - set(PERIODIC) - {'axis_reconstruction'}:
        raise BuildError('Unsupported periodic reconstruction settings')
    axes = parameters.get('axis_reconstruction')
    if axes is None:
        return
    if axes['width_source_texels'] != 1.0 or axes['field_reconstruction'] != 'ink-excluded normalized positive cubic' or \
            set(axes['axis_centers']) != {'x', 'y'}:
        raise BuildError('Unknown source axis treatment')
    for name, size in [('x', width), ('y', height)]:
        values = axes['axis_centers'][name]
        if not isinstance(values, list) or len(values) > 32 or len(set(values)) != len(values) or \
                any(type(v) not in (int, float) or not math.isfinite(v) or not 0 <= v < size for v in values):
            raise BuildError('Invalid registered source axes')


def positive_cubic(source, scale):
    import numpy as np
    from scipy.ndimage import map_coordinates
    height, width = source.shape[:2]
    y, x = np.indices((height * scale, width * scale), dtype=np.float64)
    coordinates = np.array([(y + .5) / scale - .5, (x + .5) / scale - .5])
    return np.stack([map_coordinates(source[:, :, c], coordinates,
        order=3, prefilter=False, mode='grid-wrap') for c in range(source.shape[2])], axis=2)


def periodic_field(original, scale, parameters):
    import numpy as np
    from PIL import Image
    validate_periodic(parameters, original.width, original.height)
    source = np.asarray(original.convert('RGB'), dtype=np.float64) / 255
    output = positive_cubic(source, scale)
    settings = parameters.get('axis_reconstruction')
    if settings is not None:
        height, width = source.shape[:2]
        sy, sx = np.indices((height, width), dtype=np.float64)
        ink = np.zeros((height, width), dtype=np.float64)
        for axis, points in settings['axis_centers'].items():
            position, period = (sx, width) if axis == 'x' else (sy, height)
            for center in points:
                distance = np.abs((position - center + period / 2) % period - period / 2)
                ink = np.maximum(ink, np.clip(1.2 - distance, 0, 1))
        weights = 1 - ink
        numerator = positive_cubic(source * weights[:, :, None], scale)
        denominator = positive_cubic(weights[:, :, None], scale)
        field = np.divide(numerator, denominator, out=output.copy(), where=denominator > 1e-6)
        y, x = np.indices(field.shape[:2], dtype=np.float64)
        u, v = (x + .5) / scale - .5, (y + .5) / scale - .5
        coverage = np.zeros(field.shape[:2], dtype=np.float64)
        for axis, points in settings['axis_centers'].items():
            position, period = (u, width) if axis == 'x' else (v, height)
            for center in points:
                distance = np.abs((position - center + period / 2) % period - period / 2)
                coverage = np.maximum(coverage, np.clip((.50 + 1 / scale / 2 - distance) * scale, 0, 1))
        samples = source[ink >= .99]
        if not len(samples):
            raise BuildError('Registered lines have no original colour samples')
        luminance = samples.mean(axis=1)
        color = np.median(samples[luminance <= np.quantile(luminance, .45)], axis=0)
        # This recorded checksum is not a colour input: strokes always sample
        # the supplied source. Exporters may omit the redundant colour record.
        if 'stroke_color_rgb_255' in settings and list(np.rint(color * 255)) != settings['stroke_color_rgb_255']:
            raise BuildError('Original registered line colour differs')
        output = field * (1 - coverage[:, :, None]) + color * coverage[:, :, None]
    if not np.isfinite(output).all() or output.min() < -1e-8 or output.max() > 1 + 1e-8:
        raise BuildError('Positive periodic reconstruction left source colour bounds')
    return Image.fromarray(np.rint(output.clip(0, 1) * 255).astype(np.uint8))


def validate_face(parameters):
    roi = parameters['source_roi']
    threshold = parameters.get('threshold', parameters.get('source_warm_threshold'))
    if threshold not in THRESHOLDS or len(roi) != 4 or any(type(v) is not int for v in roi) or \
            not 0 < roi[0] < roi[2] < 64 or not 0 < roi[1] < roi[3] < 64 or \
            parameters['close_kernel'] != 5 or parameters['dilate_kernel'] != 3 or \
            parameters['feather_output_px'] != 5.6 or parameters['fill_enclosed_holes'] is not True:
        raise BuildError('Unsupported original-colour face mask')


def source_face(original, parent, parameters):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    validate_face(parameters)
    if original.size != (64, 64) or parent.size != (512, 512):
        raise BuildError('Original-colour correction needs the selected source/output scale')
    source, parent = original.convert('RGB'), parent.convert('RGB')
    pixels = np.asarray(source).astype(np.float32)
    r, g, b = [pixels[:, :, n] for n in range(3)]
    threshold = parameters.get('threshold', parameters.get('source_warm_threshold'))
    if threshold == 'R>85,R>=1.13G,G>=1.16B':
        seed = (r > 85) & (r >= g * 1.13) & (g >= b * 1.16)
    elif threshold == 'R>70,1.03G<=R<1.80G,G>=1.08B':
        seed = (r > 70) & (r >= 1.03 * g) & (r < 1.80 * g) & (g >= 1.08 * b)
    elif threshold == 'R>45,R>=1.07G,G>=1.08B':
        seed = (r > 45) & (r >= 1.07 * g) & (g >= 1.08 * b)
    else:
        seed = (g > 70) & (r > 48) & (r >= .62 * g) & (r <= .95 * g) & (b <= .95 * r)
    roi = parameters['source_roi']
    allowed = np.zeros((64, 64), dtype=np.uint8)
    allowed[roi[1]:roi[3], roi[0]:roi[2]] = 255
    mask = Image.fromarray(np.minimum(seed.astype(np.uint8) * 255, allowed))
    mask = mask.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))
    mask = Image.fromarray(np.minimum(np.asarray(mask), allowed))
    flood = mask.copy()
    ImageDraw.floodfill(flood, (0, 0), 128, thresh=0)
    mask = Image.fromarray(np.where(np.asarray(flood) == 128, 0, 255).astype(np.uint8))
    mask = mask.filter(ImageFilter.MaxFilter(3))
    mask = mask.resize((512, 512), Image.Resampling.BICUBIC).filter(ImageFilter.GaussianBlur(5.6))
    bounded = Image.fromarray(allowed).resize((512, 512), Image.Resampling.NEAREST)
    mask = Image.fromarray(np.minimum(np.asarray(mask), np.asarray(bounded)))
    bicubic = source.resize((512, 512), Image.Resampling.BICUBIC)
    corrected = Image.composite(bicubic, parent, mask)
    before, after, alpha = np.asarray(parent), np.asarray(corrected), np.asarray(mask)
    if not np.array_equal(before[alpha == 0], after[alpha == 0]) or \
            not np.array_equal(np.asarray(bicubic)[alpha == 255], after[alpha == 255]) or \
            int((alpha == 255).sum()) <= 10000:
        raise BuildError('Source face core or unchanged exterior guard failed')
    return corrected


def island_endpoints(original, prior, initial_repair):
    """Reproduce the reviewed atlas-endpoint correction after the first repair."""
    import numpy as np
    from PIL import Image
    from tools.personal_texture_corrections import localized_repair
    if original.size != (32, 32) or prior.size != (512, 512):
        raise BuildError('Island correction dimensions differ')
    expected = {'mode': 'bilinear', 'regions': [{'rectangle': [14, 11.5, 20, 32]}],
        'exclude': [], 'inward_feather_source_pixels': .5}
    if initial_repair != expected:
        raise BuildError('Island correction must follow the reviewed first repair')
    source = np.asarray(original.convert('RGB'), dtype=np.float64)
    base = np.asarray(localized_repair(original, prior, 16, ['repeat', 'repeat'], initial_repair))
    preceding = np.asarray(prior.convert('RGB'), dtype=np.uint8)
    coordinates = (np.arange(512, dtype=np.float64) + .5) / 16
    x, y = np.meshgrid(coordinates, coordinates)
    xmask = np.clip(np.minimum(x - 14, 20 - x) / .5, 0, 1)
    endpoint = ((y >= 11.5) & (y < 12.5)) | (y >= 31.5)
    mask = (xmask > 0) & endpoint
    xi = coordinates - .5
    x0 = np.floor(xi).astype(int)
    ax = xi - x0
    x0, x1 = x0 % 32, (x0 + 1) % 32
    yi = np.clip(coordinates - .5, 12, 31)
    y0 = np.floor(yi).astype(int)
    y1 = np.minimum(y0 + 1, 31)
    ay = yi - y0
    upper = source[y0[:, None], x0[None, :]] * (1 - ax[None, :, None]) + source[y0[:, None], x1[None, :]] * ax[None, :, None]
    lower = source[y1[:, None], x0[None, :]] * (1 - ax[None, :, None]) + source[y1[:, None], x1[None, :]] * ax[None, :, None]
    reconstructed = upper * (1 - ay[:, None, None]) + lower * ay[:, None, None]
    local = np.rint(preceding * (1 - xmask[:, :, None]) + reconstructed * xmask[:, :, None]).astype(np.uint8)
    local[y < 12] = preceding[y < 12]
    final = base.copy()
    final[mask] = local[mask]
    if not np.array_equal(final[~mask], base[~mask]) or not np.array_equal(final[200:504], base[200:504]):
        raise BuildError('Island repair changed the protected middle')
    return Image.fromarray(final)

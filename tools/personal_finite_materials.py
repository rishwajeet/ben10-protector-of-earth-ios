#!/usr/bin/env python3
"""Replay selected finite-domain materials with separately supplied private paths."""
import argparse
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, outside_repo, write_json
from tools.personal_textures import load_contract, source_pixels, validate_contract
from tools.personal_structural_plates import replay as replay_plates

CONTRACT = ROOT / 'reference/personal_finite_recipes.json'
SCHEMA = 'protector-native.personal-finite-materials/v1'
METHOD = ('Reviewer-directed local source contour and finite-edge finish. '
    'Same registered interior motifs and paths, no opposite-edge filtering, '
    'no forced seamlessness, no native or pack admission.')


def validate_recipe(recipe):
    if recipe.get('schema') != 'protector-native.private-finite-material/v1' or \
            recipe.get('kind') not in ('grid', 'strip', 'tread', 'pointed') or recipe.get('role') not in (0, 1):
        raise BuildError('Unknown finite-material recipe')
    def bounded(value, depth=0):
        if depth > 10:
            raise BuildError('Finite recipe nesting exceeds bounds')
        if isinstance(value, dict):
            for k, v in value.items():
                if k not in {'schema', 'id', 'kind', 'role', 'width', 'boxes', 'paths', 'axis',
                        'points', 'shadow_width', 'highlight_width', 'highlight_offset',
                        'dark_width', 'dark_offset', 'outlines', 'companion', 'sharp_tips'}:
                    raise BuildError('Finite recipe contains non-geometric or unsupported inputs')
                bounded(v, depth + 1)
        elif isinstance(value, list):
            if len(value) > 2048:
                raise BuildError('Finite recipe list exceeds bounds')
            for v in value:
                bounded(v, depth + 1)
        elif isinstance(value, (float, int)):
            if not math.isfinite(value) or not -16 <= value <= 128:
                raise BuildError('Finite recipe coordinate exceeds bounds')
        elif not isinstance(value, str):
            raise BuildError('Unsupported finite recipe value')
    bounded(recipe)
    kind, role = recipe['kind'], recipe['role']
    if kind == 'tread':
        if role != 0 or recipe['width'] not in (1.65, 2.15) or not 1 <= len(recipe['boxes']) <= 128 or \
                any(len(b) != 5 or any(type(v) is not int for v in b) or b[4] not in (-1, 1) or
                    not (-8 <= b[0] < b[2] <= 72 and -8 <= b[1] < b[3] <= 72) for b in recipe['boxes']):
            raise BuildError('Invalid source-owned tread boxes')
    if kind in ('grid', 'strip') and role == 0:
        if not 1 <= len(recipe['paths']) <= 32:
            raise BuildError('Invalid finite path count')
        for path in recipe['paths']:
            if not 2 <= len(path['points']) <= 64 or any(len(p) != 2 for p in path['points']):
                raise BuildError('Invalid finite path geometry')
            if kind == 'grid' and path['axis'] not in ('horizontal', 'vertical'):
                raise BuildError('Invalid grid path axis')
        if kind == 'strip' and (not isinstance(recipe['companion'], str) or len(recipe['companion']) != 70):
            raise BuildError('Original strip coverage source is required')
    if kind == 'strip' and role == 1 and (not 1 <= len(recipe['outlines']) <= 64 or
            any(not 3 <= len(p) <= 2048 or any(len(v) != 2 for v in p) for p in recipe['outlines'])):
        raise BuildError('Invalid finite coverage outlines')
    if kind == 'pointed':
        tips = recipe['sharp_tips']
        if not tips or tips != sorted(set(tips)) or any(type(x) is not int or not 0 < x < 63 for x in tips):
            raise BuildError('Invalid registered sharp tips')


def resize_float(a, scale):
    import numpy as np
    from scipy.ndimage import map_coordinates
    h, w = a.shape[:2]
    y, x = np.indices((h * scale, w * scale), dtype=float)
    uv = [(y + .5) / scale - .5, (x + .5) / scale - .5]
    return np.stack([map_coordinates(a[:, :, c], uv, order=1, mode='nearest') for c in range(3)], axis=2)


def clean_field(src, excluded, sigma):
    import numpy as np
    from scipy.ndimage import gaussian_filter
    valid = 1 - excluded.astype(float)
    den = gaussian_filter(valid, sigma, mode='nearest')
    med = np.median(src.reshape(-1, 3), axis=0)
    out = np.empty_like(src)
    for c in range(3):
        num = gaussian_filter(src[:, :, c] * valid, sigma, mode='nearest')
        out[:, :, c] = np.divide(num, den, out=np.full(den.shape, med[c]), where=den > .001)
    return out


def rounded_path(points):
    import numpy as np
    p = np.asarray(points, float)
    closed = np.linalg.norm(p[0] - p[-1]) < 1e-5
    if closed:
        p = p[:-1]
    out = []
    for i, b in enumerate(p):
        if not closed and (i == 0 or i == len(p) - 1):
            out.append(b)
            continue
        a, c = p[(i - 1) % len(p)], p[(i + 1) % len(p)]
        r = min(.30, np.linalg.norm(b - a) * .32, np.linalg.norm(c - b) * .32)
        u = b + (a - b) * r / max(1e-8, np.linalg.norm(a - b))
        v = b + (c - b) * r / max(1e-8, np.linalg.norm(c - b))
        for t in np.linspace(0, 1, 7):
            out.append((1 - t)**2 * u + 2 * (1 - t) * t * b + t * t * v)
    if closed:
        out.append(out[0])
    return np.asarray(out).round(5).tolist()


def mask_polygon(paths, size, scale, rounded=False):
    import numpy as np
    from PIL import Image, ImageDraw
    pic = Image.new('L', (size * scale * 2, size * scale * 2))
    draw = ImageDraw.Draw(pic)
    for path in paths:
        if rounded:
            path = rounded_path(path)
        draw.polygon([((x + .5) * scale * 2, (y + .5) * scale * 2) for x, y in path], fill=255)
    return np.asarray(pic.resize((size * scale, size * scale), Image.Resampling.LANCZOS), float) / 255


def curve(points):
    import numpy as np
    from scipy.interpolate import CubicSpline
    p = np.asarray(points, float)
    t = np.r_[0, np.cumsum(np.linalg.norm(np.diff(p, axis=0), axis=1))]
    if np.any(np.diff(t) <= 0):
        raise BuildError('Repeated finite path vertex')
    tt = np.linspace(0, t[-1], max(2, int(t[-1] * 24)))
    return CubicSpline(t, p, bc_type='natural')(tt)


def colored_stroke(pic, path, width, colors, scale):
    import numpy as np
    from PIL import ImageDraw
    draw = ImageDraw.Draw(pic)
    coords = [(float((x + .5) * scale), float((y + .5) * scale)) for x, y in path]
    colors = np.asarray(colors)
    if colors.ndim == 1:
        colors = np.tile(colors, (len(path), 1))
    for k in range(len(coords) - 1):
        color = tuple(np.rint(colors[k]).clip(0, 255).astype(int))
        draw.line([coords[k], coords[k + 1]], fill=color, width=max(1, round(width * scale)))


def crossed_span(row, center):
    c = int(round(center))
    lo = hi = c
    if row[c] >= 128:
        raise BuildError('Aperture centre no longer lies inside its source hole')
    while lo > 0 and row[lo - 1] < 128:
        lo -= 1
    while hi < len(row) - 1 and row[hi + 1] < 128:
        hi += 1
    left = lo - .5 if lo == 0 else lo - 1 + (row[lo - 1] - 128) / (row[lo - 1] - row[lo])
    right = hi + .5 if hi == len(row) - 1 else hi + (128 - row[hi]) / (row[hi + 1] - row[hi])
    return float(left), float(right)


def apertures(src, scale):
    import numpy as np
    from scipy.ndimage import label
    holes, count = label(src[:, :, 1] < 128)
    if count != 25:
        raise BuildError('The selected source must have exactly 25 apertures')
    yy, xx = np.indices((32 * scale, 32 * scale), dtype=float)
    x, y = (xx + .5) / scale - .5, (yy + .5) / scale - .5
    coverage = np.ones(x.shape)
    for k in range(1, count + 1):
        sy, sx = np.where(holes == k)
        cx, cy = float(sx.mean()), float(sy.mean())
        left, right = crossed_span(src[int(round(cy)), :, 1], cx)
        top, bottom = crossed_span(src[:, int(round(cx)), 1], cy)
        radius = min(.64, (right - left) * .17, (bottom - top) * .17)
        qx = abs(x - (left + right) / 2) - (right - left) / 2 + radius
        qy = abs(y - (top + bottom) / 2) - (bottom - top) / 2 + radius
        sd = np.sqrt(np.maximum(qx, 0)**2 + np.maximum(qy, 0)**2) + np.minimum(np.maximum(qx, qy), 0) - radius
        coverage *= 1 - np.clip(.5 - sd / .18, 0, 1)
    result = np.zeros((32 * scale, 32 * scale, 3))
    result[:, :, 1] = coverage * 255
    return result


def path_field(src, scale, recipe, auxiliary):
    import numpy as np
    from PIL import Image
    kind = recipe['kind']
    if kind == 'grid':
        yy, xx = np.indices((32, 32))
        excluded = np.zeros((32, 32), bool)
        for p in recipe['paths']:
            coordinate, axis = (yy, 1) if p['axis'] == 'horizontal' else (xx, 0)
            excluded |= abs(coordinate - round(p['points'][0][axis])) < 1.1
        field = clean_field(src, excluded, 1.1)
    else:
        field = clean_field(src, auxiliary[:, :, 1] > 30, 1.15)
    pic = Image.fromarray(np.rint(resize_float(field, scale)).clip(0, 255).astype('uint8'))
    for record in recipe['paths']:
        p = curve(record['points'])
        if kind == 'grid':
            ix, iy = np.rint(p[:, 0]).astype(int).clip(0, 31), np.rint(p[:, 1]).astype(int).clip(0, 31)
            color = src[iy, ix]
            dark, light = np.quantile(color, .30, axis=0), np.quantile(color, .76, axis=0)
            colored_stroke(pic, p + record['highlight_offset'], record['highlight_width'], light, scale)
            colored_stroke(pic, p, record['shadow_width'], dark, scale)
        else:
            dark, light = [], []
            for x, y in p:
                ix, iy = int(round(x)), int(round(y))
                pixels = src[max(0, iy - 1):min(32, iy + 2), max(0, ix - 1):min(32, ix + 2)].reshape(-1, 3)
                dark.append(np.quantile(pixels, .12, axis=0))
                light.append(np.quantile(pixels, .92, axis=0))
            colored_stroke(pic, p + record['dark_offset'], record['dark_width'], dark, scale)
            colored_stroke(pic, p + record['highlight_offset'], record['highlight_width'], light, scale)
    return np.asarray(pic, float)


def register_tread(src, box, width):
    import numpy as np
    x0, y0, x1, y1, direction = box
    yy, xx = np.mgrid[max(0, y0):min(64, y1 + 1), max(0, x0):min(64, x1 + 1)]
    values = src[yy, xx].mean(2)
    weights = np.maximum(abs(values - float(np.median(values))) - 7, 0).ravel()
    points = np.stack([xx, yy], axis=-1).reshape(-1, 2)
    if not weights.sum() > 0:
        raise BuildError('Tread box has no supporting original samples')
    center = np.average(points, axis=0, weights=weights)
    axis = np.array([1., float(direction)]) / np.sqrt(2)
    along = (points - center) @ axis
    strong = weights >= np.quantile(weights[weights > 0], .35)
    lo, hi = np.quantile(along[strong], [.02, .98])
    margin = .35 if y0 < 0 or y1 > 63 or x0 < 0 or x1 > 63 else .2
    lo -= margin
    hi += margin
    limit = 6.4 if width < 2 else 7.2
    if hi - lo > limit:
        mid = (hi + lo) / 2
        lo, hi = mid - limit / 2, mid + limit / 2
    local = src[yy, xx].reshape(-1, 3)
    return {'box': box, 'a': center + axis * lo, 'b': center + axis * hi,
        'normal': np.array([1., -float(direction)]) / np.sqrt(2),
        'dark': np.quantile(local, .06 if width < 2 else .10, axis=0),
        'light': np.quantile(local, .94 if width < 2 else .88, axis=0),
        'fill': np.quantile(local, .62, axis=0)}


def treads(src, scale, recipe):
    import numpy as np
    from PIL import Image, ImageDraw
    width = recipe['width']
    regs = [register_tread(src, b, width) for b in recipe['boxes']]
    yy, xx = np.indices((64, 64))
    points = np.stack([xx, yy], axis=-1)
    exclusion = np.zeros((64, 64), bool)
    for r in regs:
        a, b = r['a'], r['b']
        ab = b - a
        t = np.clip(np.sum((points - a) * ab, axis=2) / (ab @ ab), 0, 1)
        exclusion |= np.linalg.norm(points - a - t[:, :, None] * ab, axis=2) < width * .85
    field = clean_field(src, exclusion, 1.5 if width < 2 else 2.0)
    pic = Image.fromarray(np.rint(resize_float(field, scale)).clip(0, 255).astype('uint8'))
    draw = ImageDraw.Draw(pic)
    def paint(r, a, b):
        n, w, axis = r['normal'], width, (b - a) / np.linalg.norm(b - a)
        def polygon(points, color):
            draw.polygon([tuple((p + .5) * scale) for p in points], fill=tuple(np.rint(color).astype(int)))
        polygon([a, b, b - axis * .25 + n * w * .45, a + axis * .25 + n * w * .45], r['dark'])
        polygon([a, b, b - axis * .25 - n * w * .34, a + axis * .25 - n * w * .34], r['fill'])
        polygon([a + axis * .35 - n * w * .38, b - axis * .35 - n * w * .38,
            b - axis * .65 - n * w * .06, a + axis * .65 - n * w * .06], r['light'])
    for r in regs:
        paint(r, r['a'], r['b'])
    # The recorded correction paints over the original fragments; it does not
    # erase them or refit the quiet background after extending the endpoints.
    for r in regs:
        x0, y0, x1, y1, _ = r['box']
        if not (x0 < 0 or y0 < 0 or x1 > 63 or y1 > 63):
            continue
        a, b = r['a'].copy(), r['b'].copy()
        v = (b - a) / np.linalg.norm(b - a)
        for axis, lower, upper in [(0, x0 < 0, x1 > 63), (1, y0 < 0, y1 > 63)]:
            for active, cut, want_low in [(lower, -.5, True), (upper, 63.5, False)]:
                if not active:
                    continue
                which = 0 if ((a[axis] < b[axis]) == want_low) else 1
                p = a if which == 0 else b
                p = p + v * ((cut - p[axis]) / v[axis])
                if which == 0:
                    a = p
                else:
                    b = p
        paint(r, a, b)
    return np.asarray(pic, float)


def pointed(src, scale, recipe):
    import numpy as np
    from scipy.ndimage import gaussian_filter1d
    from scipy.interpolate import PchipInterpolator
    role = recipe['role']
    z, threshold = (src.mean(2), 25) if role == 0 else (src[:, :, 1], 128)
    raw = []
    for x in range(64):
        hits = np.where(z[:, x] < threshold)[0]
        y = float(hits[0]) if len(hits) else 64.
        if 0 < y < 64:
            iy = int(y)
            previous, now = z[iy - 1, x], z[iy, x]
            y = iy - 1 + (previous - threshold) / max(1e-6, previous - now)
        raw.append(y)
    raw = np.array(raw)
    heights = gaussian_filter1d(raw, .60, mode='nearest')
    heights[0], heights[-1] = raw[0], raw[-1]
    for x in recipe['sharp_tips']:
        heights[x] = raw[x]
    cuts, dense = [0, *recipe['sharp_tips'], 63], []
    for start, end in zip(cuts[:-1], cuts[1:]):
        xx = np.arange(start, end + 1, dtype=float)
        sample = np.linspace(start, end, max(2, (end - start) * 48 + 1))
        part = np.stack([sample, PchipInterpolator(xx, heights[start:end + 1])(sample)], axis=1)
        dense.extend(part[:-1].tolist())
    dense.append([63, float(heights[63])])
    line = [[-.5, float(heights[0])], *dense, [63.5, float(heights[-1])], [63.5, 63.5], [-.5, 63.5]]
    mask = mask_polygon([line], 64, scale)
    if role == 0:
        brown = np.median(src[:10].reshape(-1, 3), axis=0)
        result = np.tile(brown, (64 * scale, 64 * scale, 1)) * (1 - mask[:, :, None])
    else:
        result = np.zeros((64 * scale, 64 * scale, 3))
        result[:, :, 1] = (1 - mask) * 255
    y, x = np.indices(result.shape[:2])
    yy, xx = (y + .5) / scale - .5, (x + .5) / scale - .5
    distance = np.minimum.reduce([xx + .5, yy + .5, 63.5 - xx, 63.5 - yy])
    weight = np.clip((distance - .5) / .5, 0, 1)
    return result * weight[:, :, None] + resize_float(src, scale) * (1 - weight[:, :, None])


def render(original, scale, recipe, companion=None):
    import numpy as np
    from PIL import Image
    validate_recipe(recipe)
    kind, role = recipe['kind'], recipe['role']
    size = 32 if kind in ('grid', 'strip') else 64
    if original.size != (size, size) or scale != 16:
        raise BuildError('Finite material source dimensions or output scale differ')
    src = np.asarray(original.convert('RGB'), dtype=float)
    if kind == 'tread':
        result = treads(src, scale, recipe)
    elif kind == 'pointed':
        result = pointed(src, scale, recipe)
    elif role == 1:
        if kind == 'grid':
            result = apertures(src, scale)
        else:
            result = np.zeros((size * scale, size * scale, 3))
            result[:, :, 1] = mask_polygon(recipe['outlines'], size, scale, rounded=True) * 255
    else:
        auxiliary = None
        if kind == 'strip':
            if companion is None:
                raise BuildError('Supply the typed original companion coverage plane')
            auxiliary = np.asarray(companion(recipe['companion']).convert('RGB'), dtype=float)
            if auxiliary.shape != src.shape:
                raise BuildError('Companion dimensions differ')
        result = path_field(src, scale, recipe, auxiliary)
    return Image.fromarray(np.rint(result).clip(0, 255).astype('uint8'))


def export(manifest, private_inputs):
    selected = load_contract()
    if digest_file(manifest) != selected['reference_manifest_sha256']:
        raise BuildError('Use the selected production pack')
    inputs = outside_repo(private_inputs)
    if inputs.exists() or inputs.is_symlink() or not inputs.parent.is_dir():
        raise BuildError('Use a new private finite-material input directory')
    rows, payloads = [], {}
    for entry in json.loads(manifest.read_text())['entries']:
        pr = entry['provenance']
        if pr['method'] != METHOD:
            continue
        src, base, fix = entry['source'], pr['base_registration'], pr['reviewer_fix']
        key = f"{src['width']}x{src['height']}-{src['rgba8_sha256']}"
        if key != pr['source_key'] or pr['scale'] != 16:
            raise BuildError('Finite source identity changed')
        recipe = {'schema': 'protector-native.private-finite-material/v1', 'id': key, 'role': pr['role']}
        if 'motifs' in base:
            widths = {m['width'] for m in base['motifs']}
            if len(widths) != 1:
                raise BuildError('Tread width lineage changed')
            recipe.update(kind='tread', width=next(iter(widths)), boxes=[m['source_box'] for m in base['motifs']])
        elif 'joint_paths' in base:
            recipe['kind'] = 'grid'
            if pr['role'] == 0:
                recipe['paths'] = [{k: p[k] for k in ('axis', 'points', 'shadow_width', 'highlight_width', 'highlight_offset')}
                    for p in base['joint_paths']]
        elif 'coverage_outline_paths' in base:
            recipe['kind'] = 'strip'
            if pr['role'] == 1:
                recipe['outlines'] = base['coverage_outline_paths']
            else:
                recipe['paths'] = [{k: p[k] for k in ('points', 'dark_width', 'dark_offset', 'highlight_width', 'highlight_offset')}
                    for p in base['paths']]
                companions = entry['required_companion_sources']
                if len(companions) != 1:
                    raise BuildError('Strip companion is ambiguous')
                recipe['companion'] = companions[0]
        else:
            recipe.update(kind='pointed', sharp_tips=fix['rgb' if pr['role'] == 0 else 'coverage']['sharp_tip_x'])
        validate_recipe(recipe)
        raw = (json.dumps(recipe, indent=2, sort_keys=True) + '\n').encode()
        sha = hashlib.sha256(raw).hexdigest()
        payloads[sha] = raw
        rows.append({'id': key, 'recipe_sha256': sha})
    if len(rows) != 8 or len({r['id'] for r in rows}) != 8:
        raise BuildError('Expected all eight finite-material planes')
    inputs.mkdir(mode=0o700)
    write_json(inputs / 'owner.json', {'schema': 'protector-native.private-finite-inputs/v1',
        'distribution_clearance': False, 'recipes': sorted(payloads)})
    for sha, raw in payloads.items():
        with (inputs / (sha + '.json')).open('xb') as stream:
            stream.write(raw)
    return {'schema': SCHEMA,
        **{k: selected[k] for k in ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')},
        'entries': rows, 'scope': 'Identities only; private registered geometry is external and colour values are reconstructed from originals'}


def replay(game, work, authored):
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    game = outside_repo(game)
    selected = load_contract()
    validate_contract(selected)
    entries = {e['id']: e for e in selected['entries']}
    @lru_cache(maxsize=1)
    def original(key):
        entry = entries[key]
        package = decode_package(game / 'files' / entry['occurrence']['package'])
        relocations = parse_relocation_commands(package.relocation, 'big', file_info_size=len(package.file_info))
        raw = source_pixels(entry, package, relocations)
        return Image.frombytes('RGBA', (entry['source']['width'], entry['source']['height']), raw)
    def drawing(source, scale, recipe):
        if recipe.get('companion'):
            a, b = entries[recipe['id']]['occurrence'], entries[recipe['companion']]['occurrence']
            if (a['package'], a['resource_offset']) != (b['package'], b['resource_offset']) or a['plane'] != 0 or b['plane'] != 1:
                raise BuildError('Strip planes are not paired in the original object')
        return render(source, scale, recipe, original)
    return replay_plates(game, work, authored, contract_path=CONTRACT, contract_schema=SCHEMA,
        entry_count=8, renderer=drawing, extra_algorithms=['tools/personal_finite_materials.py'], family='finite material')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    stage = subs.add_parser('export')
    stage.add_argument('--manifest', type=Path, required=True)
    stage.add_argument('--private-inputs', type=Path, required=True)
    stage.add_argument('--output', type=Path, required=True)
    run = subs.add_parser('replay')
    run.add_argument('--game', type=Path, required=True)
    run.add_argument('--work-dir', type=Path, required=True)
    run.add_argument('--authored-inputs', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'export':
            if args.output.exists() or args.output.is_symlink():
                raise BuildError('Use a new finite-material contract path')
            result = export(args.manifest, args.private_inputs)
            write_json(args.output, result)
            print(json.dumps({'selected': len(result['entries']), 'distribution_clearance': False}))
        else:
            print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Finite material replay: {error}\n')

#!/usr/bin/env python3
"""Replay structural plates from original pixels and private registered geometry."""
import argparse
from functools import lru_cache
import hashlib
from importlib.metadata import version
import json
import math
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_textures import load_contract, source_pixels, validate_contract

CONTRACT = ROOT / 'reference/personal_structural_plates.json'
ALGORITHMS = ['tools/personal_structural_plates.py', 'tools/personal_textures.py',
    'tools/prepare_texture_restoration.py', 'protector_native/textures.py', 'requirements-personal-structural.lock']


def validate_recipe(recipe, width, height):
    if recipe.get('schema') != 'protector-native.private-structural-plate/v1' or \
            not isinstance(recipe.get('operations'), list) or len(recipe['operations']) > 128 or \
            len(recipe.get('stripes', [])) > 1:
        raise BuildError('Invalid bounded structural plate recipe')
    for op in recipe['operations']:
        if set(op) - {'coordinate_precision'} != {'kind', 'geometry', 'sample_roi', 'sample_luma_quantile', 'erase_margin'} or \
                op['kind'] not in ('line', 'frame', 'rect') or not 0 <= op['erase_margin'] <= 4:
            raise BuildError('Unknown structural operation')
        if op.get('coordinate_precision', 'python') not in ('python', 'float64') or \
                op.get('coordinate_precision') == 'float64' and op['kind'] != 'line':
            raise BuildError('Unknown geometry scalar precision')
        roi, quantile, geometry = op['sample_roi'], op['sample_luma_quantile'], op['geometry']
        if len(roi) != 4 or not 0 <= roi[0] < roi[2] <= width or not 0 <= roi[1] < roi[3] <= height or \
                len(quantile) != 2 or not 0 <= quantile[0] <= quantile[1] <= 1:
            raise BuildError('Invalid original colour selection')
        if op['kind'] == 'line':
            points = geometry['points']
            if not 2 <= len(points) <= 256 or not 0 < geometry['width'] <= 16 or \
                    any(len(p) != 2 or any(not math.isfinite(v) or abs(v) > 2 * max(width, height) for v in p) for p in points):
                raise BuildError('Invalid bounded structural line')
        else:
            box = geometry['box']
            if len(box) != 4 or not box[0] < box[2] or not box[1] < box[3] or \
                    any(not math.isfinite(v) or abs(v) > 2 * max(width, height) for v in box) or \
                    not 0 <= geometry['radius' if op['kind'] == 'rect' else 'width'] <= 16:
                raise BuildError('Invalid structural rectangle or frame')
    for stripe in recipe.get('stripes', []):
        if set(stripe) != {'domain', 'period', 'slope', 'duty', 'phase'} or \
                not 1 <= stripe['period'] <= 64 or not -2 <= stripe['slope'] <= 2 or \
                not 0 < stripe['duty'] < 1 or not 0 <= stripe['phase'] < stripe['period']:
            raise BuildError('Invalid measured stripe registration')
        box = stripe['domain']
        if len(box) != 4 or not 0 <= box[0] < box[2] <= width or not 0 <= box[1] < box[3] <= height:
            raise BuildError('Stripe domain is outside the source')


class Plate:
    def __init__(self, source, scale, recipe):
        self.src = source
        self.height, self.width = source.shape[:2]
        self.scale = scale
        validate_recipe(recipe, self.width, self.height)
        self.operations = [dict(op, color=self.color(op['sample_roi'], op['sample_luma_quantile']))
                           for op in recipe['operations']]
        # Ellipse samples in the original authoring recipe were NumPy FP64
        # scalars. JSON numbers alone lose this distinction: NumPy 2's weak
        # Python scalars otherwise retain FP32 coordinate-array arithmetic.
        import numpy as np
        for op in self.operations:
            if op.get('coordinate_precision') == 'float64':
                op['geometry'] = dict(op['geometry'], points=[
                    [np.float64(v) for v in point] for point in op['geometry']['points']])

    def coordinates(self, scale):
        import numpy as np
        y, x = np.indices((self.height * scale, self.width * scale), dtype=np.float32)
        return (x + .5) / scale, (y + .5) / scale

    def color(self, roi, quantile):
        import numpy as np
        x0, y0, x1, y1 = roi
        samples = self.src[max(0, int(y0)):min(self.height, math.ceil(y1)),
            max(0, int(x0)):min(self.width, math.ceil(x1))].reshape(-1, 3)
        luma = samples @ np.array([.2126, .7152, .0722])
        lo, hi = np.quantile(luma, quantile)
        return np.median(samples[(luma >= lo) & (luma <= hi)], axis=0).tolist()

    def mask(self, op, x, y, aa, margin=0):
        import numpy as np
        geometry = op['geometry']
        if op['kind'] == 'frame':
            x0, y0, x1, y1 = geometry['box']
            width = geometry['width']
            outer = np.maximum(np.abs(x - (x0 + x1) / 2) - (x1 - x0 + width) / 2,
                np.abs(y - (y0 + y1) / 2) - (y1 - y0 + width) / 2)
            inner = np.minimum((x1 - x0 - width) / 2 - np.abs(x - (x0 + x1) / 2),
                (y1 - y0 - width) / 2 - np.abs(y - (y0 + y1) / 2))
            distance = np.maximum(outer, inner)
        elif op['kind'] == 'rect':
            x0, y0, x1, y1 = geometry['box']
            radius = geometry['radius']
            qx = np.abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - radius)
            qy = np.abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - radius)
            distance = np.minimum(np.maximum(qx, qy), 0) + np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) - radius
        else:
            distance = np.full(x.shape, np.inf, dtype=np.float32)
            for a, b in zip(geometry['points'], geometry['points'][1:]):
                dx, dy = b[0] - a[0], b[1] - a[1]
                denominator = dx * dx + dy * dy
                if denominator == 0:
                    continue
                length = np.sqrt(denominator)
                t = ((x - a[0]) * dx + (y - a[1]) * dy) / length
                side = np.abs((x - a[0]) * dy - (y - a[1]) * dx) / length - geometry['width'] / 2
                end = np.maximum(-t, t - length)
                distance = np.minimum(distance, np.maximum(side, end))
        return np.clip(.5 + (margin - distance) / aa, 0, 1)

    def field(self, source, scale):
        import numpy as np
        from scipy.ndimage import map_coordinates
        x, y = self.coordinates(scale)
        uv = np.array([y - .5, x - .5])
        return np.stack([map_coordinates(source[:, :, c], uv, order=3, prefilter=False, mode='nearest')
            for c in range(3)], axis=2)

    def render(self):
        import numpy as np
        from scipy.ndimage import distance_transform_edt, gaussian_filter
        x, y = self.coordinates(1)
        erased = np.zeros((self.height, self.width), bool)
        for op in self.operations:
            erased |= self.mask(op, x, y, 1, op['erase_margin']) > .05
        if erased.all():
            raise BuildError('Registered plate would erase all original quiet samples')
        nearest = distance_transform_edt(erased, return_distances=False, return_indices=True)
        cleaned = self.src.copy()
        cleaned[erased] = self.src[tuple(nearest[:, erased])]
        image = self.field(cleaned, self.scale)
        x, y = self.coordinates(self.scale)
        for op in self.operations:
            mask = self.mask(op, x, y, 1 / self.scale)[..., None]
            ink = np.array(op['color'])
            if op['kind'] in ('line', 'frame'):
                sx, sy = self.coordinates(1)
                samples = self.mask(op, sx, sy, 1, .35)
                x0, y0, x1, y1 = op['sample_roi']
                inroi = (sx >= x0) & (sx < x1) & (sy >= y0) & (sy < y1)
                luma = self.src @ np.array([.2126, .7152, .0722])
                lo, hi = np.quantile(luma[inroi], op['sample_luma_quantile'])
                samples *= inroi & (luma >= lo) & (luma <= hi)
                if np.count_nonzero(samples) >= 2:
                    weights = gaussian_filter(samples, .9, mode='nearest')
                    num = np.stack([gaussian_filter(self.src[:, :, c] * samples, .9, mode='nearest') for c in range(3)], axis=2)
                    nearest = distance_transform_edt(samples == 0, return_distances=False, return_indices=True)
                    colors = self.src[tuple(nearest)]
                    np.divide(num, weights[:, :, None], out=colors, where=weights[:, :, None] > 1e-8)
                    ink = np.clip(self.field(colors, self.scale), ink - 12, ink + 12)
            image = image * (1 - mask) + ink * mask
        return image

    def stripes(self, registration):
        import numpy as np
        from scipy.ndimage import distance_transform_edt, gaussian_filter
        x0, y0, x1, y1 = registration['domain']
        period, slope, duty, phase = [registration[k] for k in ('period', 'slope', 'duty', 'phase')]
        sy, sx = np.indices((self.height, self.width), dtype=float)
        u, v = sx + .5, sy + .5
        region = (u >= x0) & (u < x1) & (v >= y0) & (v < y1)
        x, y = self.coordinates(self.scale)
        highphase = (x + slope * y - phase) % period
        edge = np.minimum(highphase, period * duty - highphase)
        high = np.clip(.5 + edge * self.scale / np.sqrt(1 + slope * slope), 0, 1)
        high = np.where(highphase > period * duty, 0, high)
        high = np.maximum(high, np.clip(.5 - (period - highphase) * self.scale / np.sqrt(1 + slope * slope), 0, 1))
        inside = (x >= x0) & (x < x1) & (y >= y0) & (y < y1)
        lowclass = ((u + slope * v - phase) % period) < period * duty
        fields = []
        for which in (False, True):
            selected = region & (lowclass == which)
            if selected.sum() <= 20:
                raise BuildError('Measured stripe class has insufficient source samples')
            weights = gaussian_filter(selected.astype(float), .55, mode='nearest')
            numerator = np.stack([gaussian_filter(self.src[:, :, c] * selected, .55, mode='nearest') for c in range(3)], axis=2)
            nearest = distance_transform_edt(~selected, return_distances=False, return_indices=True)
            filled = self.src[tuple(nearest)]
            np.divide(numerator, weights[:, :, None], out=filled, where=weights[:, :, None] > 1e-8)
            fields.append(self.field(filled, self.scale))
        return inside, fields[0] * (1 - high[..., None]) + fields[1] * high[..., None]


def render(original, scale, recipe):
    import numpy as np
    from PIL import Image
    plate = Plate(np.array(original.convert('RGB')).astype(float), scale, recipe)
    pixels = plate.render()
    for registration in recipe.get('stripes', []):
        inside, striped = plate.stripes(registration)
        pixels[inside] = striped[inside]
    if not np.isfinite(pixels).all():
        raise BuildError('Nonfinite reconstructed plate')
    return Image.fromarray(np.rint(pixels.clip(0, 255)).astype('uint8'))


def replay(game, work, authored, *, contract_path=None, contract_schema=None,
           entry_count=20, renderer=None, extra_algorithms=(), family='structural',
           receipt_context=None, admit=None):
    """`admit(entry, picture, source_rgba)` may accept a non-exact plate; structural plates are exact."""
    from PIL import Image
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    for name, expected in {'numpy': '2.4.2', 'Pillow': '12.1.1', 'scipy': '1.17.0'}.items():
        if version(name) != expected:
            raise BuildError('Use the qualified structural requirements lock')
    game, work, authored = outside_repo(game), outside_repo(work), outside_repo(authored)
    if any(work == p or work.is_relative_to(p) or p.is_relative_to(work) for p in (game, authored)):
        raise BuildError('Plate output must be separate from inputs')
    selected = load_contract()
    validate_contract(selected)
    contract_path = contract_path or CONTRACT
    contract_schema = contract_schema or 'protector-native.personal-structural-plates/v1'
    renderer = renderer or render
    contract = json.loads(contract_path.read_text())
    if contract['schema'] != contract_schema or len(contract['entries']) != entry_count or \
            len({e['id'] for e in contract['entries']}) != entry_count or any(contract[k] != selected[k] for k in
            ('title_dol_sha256', 'source_lock_sha256', 'reference_manifest_sha256')) or digest_file(LOCK) != contract['source_lock_sha256']:
        raise BuildError('Complete selected structural contract required')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 5 * 1024**3:
        raise BuildError('Plate output needs an existing parent and 5 GiB headroom')
    owner = {'schema': 'protector-native.personal-plate-work/v1', 'game': str(game),
        'source_lock_sha256': digest_file(LOCK), 'contract_sha256': digest_file(contract_path)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Plate output belongs to different inputs')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Plate output directory is a link')
    @lru_cache(maxsize=1)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    entries = {e['id']: e for e in selected['entries']}
    algorithms = {p: digest_file(ROOT / p) for p in [*ALGORITHMS, *extra_algorithms]}
    started, results = time.monotonic(), []
    for row in contract['entries']:
        entry = entries[row['id']]
        raw = source_pixels(entry, *package(entry['occurrence']['package']))
        source = Image.frombytes('RGBA', (entry['source']['width'], entry['source']['height']), raw)
        if source.getextrema()[3] != (255, 255):
            raise BuildError('Structural source unexpectedly has alpha')
        path = authored / (row['recipe_sha256'] + '.json')
        if path.is_symlink() or path.stat().st_size > 1024**2 or digest_file(path) != row['recipe_sha256']:
            raise BuildError('Supply the exact selected private structural recipe')
        recipe = json.loads(path.read_text())
        scale = entry['dimensions'][0] // source.width
        if recipe['id'] != entry['id'] or [source.width * scale, source.height * scale] != entry['dimensions']:
            raise BuildError('Private plate source or scale differs')
        picture = renderer(source, scale, recipe)
        actual = hashlib.sha256(picture.convert('RGBA').tobytes()).hexdigest()
        comparison = None
        if actual != entry['reference_rgba8_sha256']:
            comparison = admit(entry, picture, raw) if admit else None
            if comparison is None:
                raise BuildError('Plate replay differs from selected pixels: ' + entry['id'])
        target = outputs / (entry['id'] + '.png')
        if target.is_symlink():
            raise BuildError('Plate candidate is a link')
        if target.exists():
            with Image.open(target) as saved:
                if saved.format != 'PNG' or saved.size != picture.size or \
                        hashlib.sha256(saved.convert('RGBA').tobytes()).hexdigest() != actual:
                    raise BuildError('Cached plate changed')
        else:
            with target.open('xb') as stream:
                picture.save(stream, format='PNG')
        results.append({'id': entry['id'], 'rgba8_sha256': actual, 'png_sha256': digest_file(target),
            'recipe_sha256': row['recipe_sha256'], 'reference_pixels_exact': comparison is None,
            **({'numerical_comparison': comparison} if comparison else {})})
        print(f'Private {family} plate replay verified: {len(results)}/{entry_count}', flush=True)
    if digest_file(contract_path) != owner['contract_sha256'] or any(digest_file(ROOT / p) != sha for p, sha in algorithms.items()):
        raise BuildError('Structural tools or contract changed during execution')
    receipt = {'schema': 'protector-native.personal-plate-result/v1', 'selected': len(results),
        'exact_pixel_matches': sum(r['reference_pixels_exact'] for r in results), 'complete_texture_pack': False,
        'requires_private_authored_inputs': True, 'distribution_clearance': False,
        'seconds': time.monotonic() - started, 'algorithms': algorithms, 'entries': results}
    if receipt_context is not None:
        receipt['reconstruction'] = receipt_context
    write_json(work / 'receipt.json', receipt)
    return {k: v for k, v in receipt.items() if k not in ('algorithms', 'entries')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--authored-inputs', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args.game, args.work_dir, args.authored_inputs), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Structural replay: {error}\n')

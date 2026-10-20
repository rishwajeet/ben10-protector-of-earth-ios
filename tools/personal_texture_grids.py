#!/usr/bin/env python3
"""Rebuild selected connected interface canvases from an admitted personal game.

Coverage is source-resampled exactly. RGB is one whole-canvas local-model call,
never independent tile inference. One RGB grid per process bounds model memory.
"""
import argparse
import gc
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, LOCK, check_table, outside_repo, write_json
from tools.personal_textures import compare_reference, load_contract, source_pixels, validate_contract

CONTRACT = ROOT / 'reference/personal_texture_grids.json'
ALGORITHMS = ['tools/personal_texture_grids.py', 'tools/personal_textures.py',
    'tools/personal_grid_variants.py', 'reference/personal_grid_variants.json',
    'tools/esrgan_tail_batches.py',
    'tools/dat_window_batches.py',
    'tools/restore_interface_grid.py', 'tools/restore_texture_batch.py',
    'tools/finish_texture_neutral.py', 'tools/prepare_texture_restoration.py',
    'protector_native/textures.py', 'requirements-personal.lock']


def validate_grids(contract, selected):
    if contract.get('schema') != 'protector-native.personal-texture-grids/v1' or \
            len(contract.get('grids', {})) != 21 or len(contract.get('entries', [])) != 70:
        raise BuildError('The complete selected grid contract is required')
    for key in ('title_dol_sha256', 'reference_manifest_sha256', 'source_lock_sha256'):
        if contract[key] != selected[key]:
            raise BuildError('Grid inputs differ from the selected texture contract')
    entries = {e['id']: e for e in selected['entries']}
    lock = json.loads(LOCK.read_text())
    for key, grid in contract['grids'].items():
        if not re.fullmatch(r'[0-9a-f]{64}', key) or key != grid['source_grid_sha256']:
            raise BuildError('Invalid grid identity')
        width, height = grid['dimensions']
        rows, columns = grid['rows'], grid['columns']
        if any(type(n) is not int or n < 1 for n in (width, height, rows, columns)) or \
                max(width, height) > 2048 or width * height > 2 * 1024**2 or \
                rows * columns > 64 or len(grid['tiles']) != rows * columns or \
                type(grid['scale']) is not int or grid['scale'] not in (4, 8, 16) or \
                max(width, height) * grid['scale'] > 8192:
            raise BuildError('Unbounded grid layout or scale')
        widths = [t['pixel_rect'][2] - t['pixel_rect'][0] for t in grid['tiles'][:columns]]
        heights = [grid['tiles'][r * columns]['pixel_rect'][3] - grid['tiles'][r * columns]['pixel_rect'][1]
            for r in range(rows)]
        if min(widths + heights) < 1 or (sum(widths), sum(heights)) != (width, height):
            raise BuildError('Grid tiles do not cover the canvas')
        for i, tile in enumerate(grid['tiles']):
            row, column = divmod(i, columns)
            x, y = sum(widths[:column]), sum(heights[:row])
            if (tile['row'], tile['column']) != (row, column) or \
                    tile['pixel_rect'] != [x, y, x + widths[column], y + heights[row]] or \
                    not 1 <= len(tile['planes']) <= 2:
                raise BuildError('Grid tile order or rectangles changed')
            for plane in tile['planes']:
                src, occurrence = plane['source'], plane['occurrence']
                source_key = f"{src['width']}x{src['height']}-{src['rgba8_sha256']}"
                if plane['id'] != source_key or not re.fullmatch(r'[1-9][0-9]*x[1-9][0-9]*-[0-9a-f]{64}', source_key) or \
                        [src['width'], src['height']] != [widths[column], heights[row]] or \
                        not re.fullmatch(r'[0-9_]+\.gc[ms]', occurrence['package']) or \
                        not re.fullmatch(r'0x[0-9a-f]{8}', occurrence['resource_offset']) or \
                        lock['game']['files/' + occurrence['package']]['sha256'] != occurrence['package_sha256']:
                    raise BuildError('Grid plane source identity or dimensions differ')
        for sha in (grid['model_sha256'], *([grid['finisher_sha256']] if grid['scale'] > 4 else [])):
            if sha not in contract['models'] or sha not in selected['models'] or \
                    contract['models'][sha] != selected['models'][sha]:
                raise BuildError('Grid model identity differs')
    seen = set()
    for row in contract['entries']:
        if row['id'] in seen or row['id'] not in entries or row['plane'] not in ('rgb', 'coverage'):
            raise BuildError('Duplicate or unknown grid output')
        seen.add(row['id'])
        grid, entry = contract['grids'][row['grid']], entries[row['id']]
        plane = 0 if row['plane'] == 'rgb' else 1
        matches = [t for t in grid['tiles'] if len(t['planes']) > plane and t['planes'][plane]['id'] == row['id']]
        if len(matches) != 1 or [v * grid['scale'] for v in matches[0]['pixel_rect']] != row['pixel_rect']:
            raise BuildError('Grid output crop does not match its original tile')
        r = row['pixel_rect']
        if [r[2] - r[0], r[3] - r[1]] != entry['dimensions']:
            raise BuildError('Grid output dimensions differ')


def assemble(grid, get_pixels):
    from PIL import Image
    picture = Image.new('RGBA', tuple(grid['dimensions']))
    coverage = Image.new('RGBA', tuple(grid['dimensions']), (0, 255, 0, 255))
    for tile in grid['tiles']:
        rect = tile['pixel_rect']
        size = (rect[2] - rect[0], rect[3] - rect[1])
        for index, plane in enumerate(tile['planes']):
            raw = get_pixels(plane)
            if len(raw) != size[0] * size[1] * 4 or any(a != 255 for a in raw[3::4]):
                raise BuildError('Grid source pixels have unexpected dimensions or alpha')
            (picture if index == 0 else coverage).paste(Image.frombytes('RGBA', size, raw), tuple(rect[:2]))
    if hashlib.sha256(picture.tobytes()).hexdigest() != grid['source_rgba8_sha256'] or \
            grid['coverage_rgba8_sha256'] is not None and \
            hashlib.sha256(coverage.tobytes()).hexdigest() != grid['coverage_rgba8_sha256']:
        raise BuildError('Reassembled original grid does not match the reviewed source canvas')
    return picture.convert('RGB'), coverage.convert('RGB')


def restore_rgb(source, scale, engine, finish, *, release_first=None):
    import numpy as np
    from PIL import Image
    from tools.restore_texture_batch import checked_pixels, padded_source
    rgb = np.asarray(source, dtype=np.float32) / 255
    borders = [32 + (-(size + 64) % 64) // 2 for size in rgb.shape[:2]]
    padded = padded_source(rgb, ['clamp', 'clamp'], borders)
    result = checked_pixels(engine(padded), padded.shape[1] * 4, padded.shape[0] * 4)
    if release_first is not None:
        release_first()
    top, left = [b * 4 for b in borders]
    result = result[top:top + source.height * 4, left:left + source.width * 4]
    for _ in range((scale // 4).bit_length() - 1):
        result = checked_pixels(finish(result, ['clamp', 'clamp']), result.shape[1] * 2, result.shape[0] * 2)
    return Image.fromarray(np.rint(result * 255).astype(np.uint8))


def replay(args):
    from PIL import Image
    device, convolution_rows = getattr(args, 'device', 'mps'), getattr(args, 'cpu_conv_output_rows', 0)
    tail_rows = getattr(args, 'cpu_tail_input_rows', 0)
    if device not in ('mps', 'cpu') or type(convolution_rows) is not int or not 0 <= convolution_rows <= 256 or \
            (convolution_rows and device != 'cpu'):
        raise BuildError('Grid convolution rows must be 0 through 256 and require CPU execution')
    if type(tail_rows) is not int or not 0 <= tail_rows <= 256 or \
            (tail_rows and (device != 'cpu' or args.plane != 'rgb')):
        raise BuildError('Grid tail input rows must be 0 through 256 and require CPU RGB execution')
    from protector_native.bigb import parse_relocation_commands
    from tools.audit_bigb import decode_package
    game, work = outside_repo(args.game), outside_repo(args.work_dir)
    if work == game or work.is_relative_to(game) or game.is_relative_to(work):
        raise BuildError('Grid workspace and original inputs must be separate')
    selected = load_contract()
    validate_contract(selected)
    contract = json.loads(CONTRACT.read_text())
    validate_grids(contract, selected)
    if digest_file(LOCK) != contract['source_lock_sha256']:
        raise BuildError('Original-content contract changed')
    wanted = [r for r in contract['entries'] if r['plane'] == args.plane and (not args.grid or r['grid'] == args.grid)]
    if not wanted or args.plane == 'rgb' and not args.grid:
        raise BuildError('Select one RGB grid per process, or the coverage subset')
    check_table(game, json.loads(LOCK.read_text())['game'])
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 10 * 1024**3:
        raise BuildError('Grid replay needs an existing parent and 10 GiB free space')
    owner = {'schema': 'protector-native.personal-texture-grid-work/v1',
        'game': str(game), 'grid_contract_sha256': digest_file(CONTRACT),
        'source_lock_sha256': digest_file(LOCK)}
    if work.exists():
        if work.is_symlink() or json.loads((work / 'owner.json').read_text()) != owner:
            raise BuildError('Grid workspace belongs to different inputs or recipes')
    else:
        work.mkdir(mode=0o700)
        write_json(work / 'owner.json', owner)
    outputs = work / 'candidates'
    outputs.mkdir(exist_ok=True, mode=0o700)
    if outputs.is_symlink():
        raise BuildError('Grid candidates directory is a link')
    references = {}
    if args.numerical_reference:
        index = json.loads(outside_repo(args.numerical_reference).read_text())
        if index['schema'] != 'protector-native.private-texture-reference-index/v1':
            raise BuildError('Invalid private reference index')
        references = index['entries']
    algorithms = {p: digest_file(ROOT / p) for p in ALGORITHMS}
    @lru_cache(maxsize=2)
    def package(name):
        p = decode_package(game / 'files' / name)
        return p, parse_relocation_commands(p.relocation, 'big', file_info_size=len(p.file_info))
    def pixels(plane):
        return source_pixels(plane, *package(plane['occurrence']['package']))
    entries = {e['id']: e for e in selected['entries']}
    started, results, runtime = time.monotonic(), [], {}
    for grid_key in sorted({r['grid'] for r in wanted}):
        grid = contract['grids'][grid_key]
        original, coverage = assemble(grid, pixels)
        rows = [r for r in wanted if r['grid'] == grid_key]
        picture = None
        if any(not (outputs / (r['id'] + '.png')).exists() for r in rows):
            size = tuple(v * grid['scale'] for v in grid['dimensions'])
            if args.plane == 'coverage':
                picture = coverage.resize(size, Image.Resampling.BICUBIC)
            else:
                if args.model_dir is None:
                    raise BuildError('Supply local models for RGB replay')
                models = outside_repo(args.model_dir)
                if models == work or models.is_relative_to(work) or work.is_relative_to(models):
                    raise BuildError('Model and output paths must be separate')
                config = {}
                for role in ('model', 'finisher'):
                    sha = grid[role + '_sha256']
                    if sha is None:
                        continue
                    record = contract['models'][sha]
                    if Path(record['filename']).name != record['filename']:
                        raise BuildError('Unsafe model path')
                    path = models / record['filename']
                    if path.is_symlink() or digest_file(path) != sha:
                        raise BuildError('Local grid model hash differs')
                    config[role] = {'weights': str(path), 'sha256': sha}
                import torch
                from tools.restore_interface_grid import CanvasModel
                from tools.restore_texture_batch import LocalModels
                torch.set_num_threads(4 if device == 'mps' else 2)
                if device == 'mps':
                    torch.mps.set_per_process_memory_fraction(.5)
                engine = CanvasModel(Path(config['model']['weights']), device)
                if convolution_rows:
                    from tools.dat_window_batches import install_cpu_convolution_batches
                    engine.metadata['cpu_convolution_batching'] = install_cpu_convolution_batches(
                        engine.model, convolution_rows)
                if tail_rows:
                    from tools.esrgan_tail_batches import install_cpu_tail_batches
                    engine.metadata['cpu_tail_batching'] = install_cpu_tail_batches(engine.model, tail_rows)
                neutral = LocalModels(config, models, device, args.provider)
                def release_first():
                    engine.model = None
                    gc.collect()
                    if device == 'mps':
                        torch.mps.empty_cache()
                    elif sys.platform == 'darwin':
                        from tools.dat_window_batches import release_cached_heap
                        engine.metadata['released_heap_bytes'] = release_cached_heap()
                picture = restore_rgb(original, grid['scale'], engine, neutral.finish,
                                      release_first=release_first)
                runtime[grid_key] = {'first_pass': engine.metadata, 'finisher': neutral.metadata}
                del engine, neutral
                if device == 'mps':
                    torch.mps.empty_cache()
        for row in rows:
            entry = entries[row['id']]
            target = outputs / (row['id'] + '.png')
            if target.is_symlink():
                raise BuildError('Grid output is a link')
            if target.exists():
                with Image.open(target) as saved:
                    if saved.format != 'PNG' or list(saved.size) != entry['dimensions']:
                        raise BuildError('Cached grid tile dimensions/format differ')
                    if saved.convert('RGBA').getextrema()[3] != (255, 255):
                        raise BuildError('Cached grid tile acquired nonopaque alpha')
                    tile = saved.convert('RGB')
            else:
                tile = picture.crop(tuple(row['pixel_rect']))
            actual = hashlib.sha256(tile.convert('RGBA').tobytes()).hexdigest()
            numerical = None
            if actual != entry['reference_rgba8_sha256']:
                if args.plane == 'rgb':
                    from tools.personal_grid_variants import admit_grid
                    numerical = admit_grid(entry, actual, recipe=row, grid=grid)
                    if numerical is None and references:
                        numerical = compare_reference(entry, tile, references)
                if numerical is None or numerical['max_channel_error'] > 1:
                    raise BuildError('Grid tile differs from selected pixels: ' + row['id'])
            if not target.exists():
                with target.open('xb') as stream:
                    tile.save(stream, format='PNG')
            results.append({'id': row['id'], 'rgba8_sha256': actual,
                'png_sha256': digest_file(target), 'reference_pixels_exact': actual == entry['reference_rgba8_sha256'],
                'numerical_comparison': numerical})
        print(f'Grid replay verified: {len(results)}/{len(wanted)} selected tiles', flush=True)
    if digest_file(CONTRACT) != owner['grid_contract_sha256'] or any(digest_file(ROOT / p) != s for p, s in algorithms.items()):
        raise BuildError('Grid tools or contract changed during execution; candidates retained')
    rounded = sum(not e['reference_pixels_exact'] for e in results)
    receipt = {'schema': 'protector-native.personal-texture-grid-result/v1', 'selected': len(results),
        'complete_texture_pack': False, 'exact_pixel_matches': len(results) - rounded,
        'bounded_rounding_matches': rounded, 'seconds': time.monotonic() - started,
        'owner_sha256': digest_file(work / 'owner.json'), 'algorithms': algorithms,
        'plane': args.plane, 'provider': args.provider if args.plane == 'rgb' else None,
        'first_pass_device': device if args.plane == 'rgb' else None,
        'cpu_conv_output_rows': convolution_rows, 'cpu_tail_input_rows': tail_rows,
        'fresh_grid_runtime': runtime, 'entries': results}
    name = 'receipt-' + args.plane + '-' + (args.grid or 'all') + '.json'
    write_json(work / name, receipt)
    return {k: v for k, v in receipt.items() if k not in ('entries', 'algorithms')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--plane', choices=('rgb', 'coverage'), required=True)
    parser.add_argument('--grid', help='Exact grid hash from the source contract')
    parser.add_argument('--model-dir', type=Path)
    parser.add_argument('--provider', choices=('cpu', 'coreml'), default='cpu')
    parser.add_argument('--device', choices=('mps', 'cpu'), default='mps')
    parser.add_argument('--cpu-tail-input-rows', type=int, default=0,
                        help='Opt-in pinned ESRGAN tail feature strips; zero keeps the original tail')
    parser.add_argument('--cpu-conv-output-rows', type=int, default=0,
                        help='Opt-in CPU convolution workspace bound; 1-256 rows, default off')
    parser.add_argument('--numerical-reference', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args), indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f'Grid replay: {error}\n')

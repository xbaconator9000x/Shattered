#!/usr/bin/env python3
"""Render actual private RMXP maps using the native three-layer tile database.

Uses the authorised staged game; never embeds, uploads or distributes game art.
Output images are private visual-review assets, NOT gameplay/collision acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from PIL import Image, ImageDraw

TILE = 32


def render_map(metadata, table_bytes, image):
    """Composite all three native RMXP tile layers, preserving transparency."""
    width, height = metadata['width'], metadata['height']
    if type(width) is not int or type(height) is not int or not (1 <= width <= 256 and 1 <= height <= 256):
        raise ValueError('invalid native dimensions')
    if len(table_bytes) < 20:
        raise ValueError('truncated native Table')
    dimension, tw, th, depth, count = struct.unpack_from('<5I', table_bytes)
    if (dimension != 3 or (tw, th, depth) != (width, height, 3) or
            count != width * height * 3 or len(table_bytes) != 20 + count * 2):
        raise ValueError('native Table shape mismatch')
    if image.width != 256 or image.height % TILE:
        raise ValueError('invalid 256px RMXP tilesheet')
    pixels = struct.unpack_from(f'<{count}H', table_bytes, 20)
    canvas = Image.new('RGBA', (width * TILE, height * TILE), (0, 0, 0, 255))
    rendered = 0
    for layer in range(3):
        for y in range(height):
            for x in range(width):
                tile_id = pixels[(layer * height + y) * width + x]
                if tile_id == 0:
                    continue
                if tile_id < 384:
                    raise ValueError(f'unsupported autotile {tile_id} at {x},{y},{layer}')
                index = tile_id - 384
                sx, sy = (index % 8) * TILE, (index // 8) * TILE
                if sy + TILE > image.height:
                    raise ValueError(f'out-of-range native tile {tile_id} at {x},{y},{layer}')
                canvas.alpha_composite(image.crop((sx, sy, sx + TILE, sy + TILE)), (x * TILE, y * TILE))
                rendered += 1
    return canvas, rendered


def overlay_events(image, events):
    result = image.copy()
    drawing = ImageDraw.Draw(result)
    for event in events:
        x, y = event['x'] * TILE, event['y'] * TILE
        drawing.rectangle((x, y, x + 31, y + 31), outline=(255, 190, 0, 255), width=2)
        drawing.text((x + 3, y + 2), str(event['id']), fill='white',
                     stroke_width=2, stroke_fill='black')
    return result


def generate(project, output, map_ids, exporter=None):
    project, output = Path(project).resolve(), Path(output)
    if not project.is_dir() or not (project / 'SHATTERED_STAGING_REPORT.json').is_file():
        raise ValueError('requires a private staged Shattered project')
    if output.exists() or output.is_symlink():
        raise ValueError('refusing to overwrite private preview directory')
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise ValueError('preview parent directory missing or unsafe')
    exporter = Path(exporter or Path(__file__).with_name('export_private_rmxp_map.rb'))
    with tempfile.TemporaryDirectory(prefix='shattered-map-preview-') as temp:
        tmp = Path(temp)
        records = []
        for map_id in map_ids:
            if type(map_id) is not int or not 1 <= map_id <= 999:
                raise ValueError('invalid map ID')
            subprocess.run(['ruby', str(exporter), '--project', str(project),
                            '--map-id', str(map_id), '--output-dir', str(tmp)],
                           check=True, capture_output=True, text=True)
            stem = f'map{map_id:03d}'
            metadata = json.loads((tmp / (stem + '_metadata.json')).read_text())
            tiles = (tmp / (stem + '_tiles.bin')).read_bytes()
            sheet = Path(metadata['tileset_path'])
            if sheet.parent != project / 'Graphics' / 'Tilesets' or sheet.is_symlink():
                raise ValueError('tileset path escapes private project')
            with Image.open(sheet) as source:
                image, count = render_map(metadata, tiles, source.convert('RGBA'))
            records.append((map_id, image, overlay_events(image, metadata['events']), {
                'map_id': map_id, 'dimensions': [metadata['width'], metadata['height']],
                'events': len(metadata['events']), 'tiles_rendered': count,
                'source_map_sha256': hashlib.sha256((project / 'Data' / f'Map{map_id:03d}.rxdata').read_bytes()).hexdigest(),
                'tileset_png_sha256': hashlib.sha256(sheet.read_bytes()).hexdigest(),
                'gameplay_verified': False, 'collision_verified': False,
            }))
        report = {'kind': 'private_native_map_visual_review_not_gameplay', 'maps': []}
        with tempfile.TemporaryDirectory(prefix='.shattered-preview-', dir=output.parent) as stage:
            stage = Path(stage)
            for map_id, image, events_image, rec in records:
                stem = f'map{map_id:03d}'
                image.save(stage / (stem + '_native_tiles.png'))
                events_image.save(stage / (stem + '_native_events.png'))
                report['maps'].append(rec)
            (stage / 'review_manifest.json').write_text(json.dumps(report, indent=2) + '\n')
            if output.exists() or output.is_symlink():
                raise ValueError('refusing to overwrite private preview directory')
            stage.rename(output)
        return report


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', required=True)
    p.add_argument('--output-dir', required=True)
    p.add_argument('--map-ids', type=int, nargs='+', required=True)
    args = p.parse_args()
    generate(args.project, args.output_dir, args.map_ids)

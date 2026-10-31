#!/usr/bin/env python3
"""Private, review-only preview of HnS -> RPG Maker XP map bundles.

Never installs maps, writes to a game project, or redistributes source art.
Run only against locally authorised tilesets and converted JSON bundles.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from PIL import Image, ImageDraw

TILE = 32
IMAGE_NAME = re.compile(r"\A[A-Za-z0-9_-]+\.png\Z")
MAPS = ("gate", "victory_1f", "victory_b1f", "victory_b2f")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def checked_map(map_data, tilesets_dir):
    """Preflight every tile and source image before any output is written."""
    size = map_data.get("dimensions", {})
    width, height = size.get("width"), size.get("height")
    if type(width) is not int or type(height) is not int or not (1 <= width <= 256 and 1 <= height <= 256):
        raise ValueError("invalid map dimensions")
    layers = map_data.get("layers")
    if not isinstance(layers, list) or len(layers) != 3 or any(
        not isinstance(layer, list) or len(layer) != width * height for layer in layers
    ):
        raise ValueError("missing complete three-layer map")
    collision = map_data.get("source_collision")
    if not isinstance(collision, list) or len(collision) != width * height or any(
        type(c) is not int or c not in range(64) for c in collision
    ):
        raise ValueError("missing or invalid source collision grid")
    tables = map_data.get("tileset_tables")
    if not isinstance(tables, dict):
        raise ValueError("missing reviewed tileset passage tables")
    target = map_data.get("target", {})
    name = target.get("tileset_image")
    if not isinstance(name, str) or not IMAGE_NAME.fullmatch(name):
        raise ValueError("unsafe tileset image name")
    image_path = Path(tilesets_dir) / name
    if image_path.is_symlink() or not image_path.is_file():
        raise ValueError("missing or unsafe local tileset image")
    expected = target.get("tileset_sha256")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("missing reviewed tileset SHA-256")
    if digest(image_path) != expected:
        raise ValueError("local tileset image SHA-256 differs from conversion")
    try:
        with Image.open(image_path) as source:
            if source.format != "PNG" or source.width != 256 or source.height < 32 or source.height % 32:
                raise ValueError("not a 256px-wide, 32px-aligned RMXP PNG")
            if source.height > 32768:
                raise ValueError("tileset image is unreasonably tall")
            source.load()  # Detect corrupt IDAT/CRC, not merely a valid IHDR.
            image = source.convert("RGBA")
    except (OSError, SyntaxError) as exc:
        raise ValueError("unreadable or corrupt local PNG") from exc
    tile_count = image.height // TILE * 8
    for layer in layers:
        for tile_id in layer:
            if type(tile_id) is not int or tile_id < 0 or (0 < tile_id < 384):
                raise ValueError("invalid or unmapped RMXP tile ID")
            if tile_id >= 384 + tile_count:
                raise ValueError("map references tile beyond reviewed PNG")
            triple = tables.get(str(tile_id))
            if not isinstance(triple, list) or len(triple) != 3 or any(type(v) is not int for v in triple):
                raise ValueError("missing reviewed tile passage/priority/terrain")
            if not (0 <= triple[0] <= 31 and 0 <= triple[1] <= 5 and 0 <= triple[2] <= 255):
                raise ValueError("invalid reviewed passage/priority/terrain")
    warps = map_data.get("warps")
    if not isinstance(warps, list):
        raise ValueError("missing source warp list")
    for warp in warps:
        x, y = warp.get("x"), warp.get("y")
        if type(x) is not int or type(y) is not int or not (0 <= x < width and 0 <= y < height):
            raise ValueError("warp lies outside reviewed map")
    return width, height, layers, collision, tables, warps, image, expected


def draw_map(data, overlay=False):
    width, height, layers, collision, tables, warps, tileset, _sha = data
    canvas = Image.new("RGBA", (width * TILE, height * TILE), (0, 0, 0, 0))
    for layer in layers:
        for index, tile_id in enumerate(layer):
            if tile_id == 0:
                continue
            source_index = tile_id - 384
            sx, sy = (source_index % 8) * TILE, (source_index // 8) * TILE
            tile = tileset.crop((sx, sy, sx + TILE, sy + TILE))
            canvas.alpha_composite(tile, ((index % width) * TILE, (index // width) * TILE))
    if overlay:
        marks = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(marks)
        for index, source_block in enumerate(collision):
            xp_block = any(
                (tables[str(layer[index])][0] & 0x0F) != 0 and
                (tables[str(layer[index])][0] & 0x10) == 0
                for layer in layers if layer[index] != 0
            )
            if source_block or xp_block:
                x, y = (index % width) * TILE, (index // width) * TILE
                draw.rectangle((x, y, x + TILE - 1, y + TILE - 1), fill=(220, 25, 25, 105))
        for index, warp in enumerate(warps):
            x, y = warp["x"] * TILE, warp["y"] * TILE
            draw.rectangle((x + 1, y + 1, x + TILE - 2, y + TILE - 2),
                           outline=(255, 218, 0, 255), width=3)
            draw.text((x + 5, y + 7), str(index), fill=(255, 255, 255, 255),
                      stroke_width=2, stroke_fill=(0, 0, 0, 255))
        canvas = Image.alpha_composite(canvas, marks)
    return canvas


def build_review(gate_path, road_path, tilesets_dir, output_dir):
    gate_path, road_path = Path(gate_path), Path(road_path)
    gate = json.loads(gate_path.read_text(encoding="utf-8"))
    road = json.loads(road_path.read_text(encoding="utf-8"))
    if gate.get("format") != "shattered-hns-rmxp-map" or road.get("format") != "shattered-hns-victory-road-rmxp-bundle":
        raise ValueError("wrong source bundle formats")
    floors = road.get("floors")
    if not isinstance(floors, list) or len(floors) != 3:
        raise ValueError("expected exactly three Victory Road floors")
    maps = [gate, *floors]
    checked = [checked_map(item, tilesets_dir) for item in maps]
    output_dir = Path(output_dir)
    if output_dir.exists() or output_dir.is_symlink():
        raise ValueError("refusing to overwrite an existing review output")
    if not output_dir.parent.is_dir() or output_dir.parent.is_symlink():
        raise ValueError("review output parent must be an existing regular directory")
    with tempfile.TemporaryDirectory(prefix=".shattered-hns-review-", dir=output_dir.parent) as temp:
        staging = Path(temp)
        manifest = {
            "purpose": "private visual review only; NOT game-ready or native-runtime evidence",
            "imported_into_game": False, "native_gameplay_verified": False,
            "source_bundles_sha256": {"gate": digest(gate_path), "victory_road": digest(road_path)},
            "maps": {},
        }
        thumbs = []
        for name, data in zip(MAPS, checked):
            clean = draw_map(data)
            debug = draw_map(data, overlay=True)
            files = {}
            for kind, image in (("clean", clean), ("collision_warps", debug)):
                filename = f"{name}_{kind}.png"
                image.save(staging / filename)
                files[kind] = {"file": filename, "sha256": digest(staging / filename)}
            manifest["maps"][name] = {
                "size_tiles": [data[0], data[1]], "source_tileset_sha256": data[7],
                "warp_count": len(data[5]), "previews": files,
            }
            thumb = debug.copy()
            thumb.thumbnail((480, 400), Image.Resampling.NEAREST)
            thumbs.append((name, thumb))
        sheet = Image.new("RGB", (1000, 930), (245, 245, 245))
        draw = ImageDraw.Draw(sheet)
        for i, (name, thumb) in enumerate(thumbs):
            left, top = 10 + (i % 2) * 500, 10 + (i // 2) * 460
            draw.text((left + 8, top + 5), name.replace("_", " ").upper(), fill=(20, 20, 20))
            sheet.paste(thumb, (left + (480 - thumb.width) // 2, top + 30), thumb)
        sheet.save(staging / "review_contact_sheet.png")
        manifest["contact_sheet_sha256"] = digest(staging / "review_contact_sheet.png")
        (staging / "review_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        os.rename(staging, output_dir)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate-bundle", required=True)
    parser.add_argument("--victory-road-bundle", required=True)
    parser.add_argument("--tilesets-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    result = build_review(args.gate_bundle, args.victory_road_bundle,
                          args.tilesets_dir, args.output_dir)
    print(json.dumps({"maps": list(result["maps"]), "imported_into_game": False}, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Privately convert pinned Heart & Soul source graphics into four real map previews.

This intentionally requires NO RPG Maker project, guessed metatile mapping or
manual passage approvals. It renders original GBA metatile/palette pixels at
32px, and generates two provisional RMXP tilesheets plus mapping templates.
Outputs contain upstream game artwork: NEVER commit or distribute them.
They are NOT compiled maps and MUST NOT be installed before collision review.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

from PIL import Image, ImageDraw

from render_hns_tiles import (
    PIN_MANIFEST, SOURCE_REVISION, build, palette, render_metatile, tileset,
    verify_pinned_source,
)

TILE = 32
MAPS = (
    ("LAYOUT_RECEPTION_GATE_HNS", "MAP_RECEPTION_GATE_HNS", "gate"),
    ("LAYOUT_VICTORY_ROAD_KANTO_1F_HNS", "MAP_VICTORY_ROAD_KANTO_1F_HNS", "victory_1f"),
    ("LAYOUT_VICTORY_ROAD_KANTO_B1F_HNS", "MAP_VICTORY_ROAD_KANTO_B1F_HNS", "victory_b1f"),
    ("LAYOUT_VICTORY_ROAD_KANTO_B2F_HNS", "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "victory_b2f"),
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_palettes(primary, secondary):
    slots = {}
    for slot in range(16):
        source = secondary if 7 <= slot <= 12 else primary
        path = source["root"] / "palettes" / f"{slot:02d}.pal"
        if path.is_file():
            slots[slot] = palette(path)
    return slots


def render_map(source_root, layout, source_map, primary, secondary, palettes, name, output):
    """Composite source metatiles; overlay GBA cell collision and source warps."""
    width, height = layout["width"], layout["height"]
    if type(width) is not int or type(height) is not int or not (0 < width <= 256 and 0 < height <= 256):
        raise ValueError(f"{name}: invalid source dimensions")
    raw = (source_root / layout["blockdata_filepath"]).read_bytes()
    if len(raw) != width * height * 2:
        raise ValueError(f"{name}: source blockdata length mismatch")
    canvas = Image.new("RGBA", (width * TILE, height * TILE))
    overlay = Image.new("RGBA", canvas.size)
    drawing = ImageDraw.Draw(overlay)
    cache = {}
    blocked = 0
    for index, (word,) in enumerate(struct.iter_unpack("<H", raw)):
        metatile = word & 1023
        collision = (word >> 10) & 3
        if metatile not in cache:
            cache[metatile] = render_metatile(metatile, primary, secondary, palettes)
        x, y = index % width, index // width
        for layer in cache[metatile]:
            canvas.alpha_composite(layer, (x * TILE, y * TILE))
        if collision:
            blocked += 1
            drawing.rectangle((x * TILE, y * TILE,
                               (x + 1) * TILE - 1, (y + 1) * TILE - 1),
                              fill=(220, 35, 35, 95))
    warps = source_map.get("warp_events", [])
    if not isinstance(warps, list):
        raise ValueError(f"{name}: source warps must be a list")
    for warp in warps:
        x, y = warp.get("x"), warp.get("y")
        if type(x) is not int or type(y) is not int or not (0 <= x < width and 0 <= y < height):
            raise ValueError(f"{name}: source warp out of bounds")
        drawing.rectangle((x * TILE + 2, y * TILE + 2,
                           (x + 1) * TILE - 3, (y + 1) * TILE - 3),
                          outline=(0, 180, 255, 255), width=3)
    clean_name, overlay_name = f"{name}_source.png", f"{name}_collision_warps.png"
    canvas.save(output / clean_name)
    Image.alpha_composite(canvas, overlay).save(output / overlay_name)
    return {
        "width": width, "height": height, "source_warps": len(warps),
        "source_collision_nonzero_cells": blocked,
        "source_metatiles_used": len(cache),
        "source_image": clean_name, "collision_warps_image": overlay_name,
    }


def generate(source_root, output_dir, *, verify_source=True):
    """Create 4 maps + 2 genuine RMXP tile PNGs, without touching any game."""
    root, output = Path(source_root), Path(output_dir)
    if not root.is_dir() or root.is_symlink():
        raise ValueError("missing or unsafe local HnS source tree")
    if output.exists() or output.is_symlink():
        raise ValueError("refusing to replace an existing private preview directory")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise ValueError("preview parent directory must already exist")
    pins = json.loads(PIN_MANIFEST.read_text(encoding="utf-8"))
    layout_records = json.loads((root / "data/layouts/layouts.json").read_text(encoding="utf-8"))["layouts"]
    layouts = {record["id"]: record for record in layout_records}
    if len(layouts) != len(layout_records):
        raise ValueError("duplicate source layout identifiers")
    groups = ((MAPS[:1], "gate", "HnS_Gate_Review"),
              (MAPS[1:], "victory", "HnS_Victory_Review"))
    with tempfile.TemporaryDirectory(prefix=".shattered-hns-", dir=output.parent) as tmp:
        staging = Path(tmp)
        report = {"source_repository": pins["source_repository"],
                  "source_revision": SOURCE_REVISION,
                  "raw_source_pins_checked": bool(verify_source),
                  "commercial_art_redistribution_authorized": False,
                  "passage_reviewed": False,
                  "native_gameplay_verified": False,
                  "android_verified": False,
                  "maps": {}, "rmxp_tilesets": {}}
        for group, label, stem in groups:
            selected = [layouts[layout_id] for layout_id, _, _ in group]
            pinned = pins["layouts"][group[0][0]]
            primary_dir, secondary_dir = pinned["primary_dir"], pinned["secondary_dir"]
            if verify_source:
                verify_pinned_source(root, selected, primary_dir, secondary_dir)
            primary = tileset(root / primary_dir)
            secondary = tileset(root / secondary_dir)
            palettes = load_palettes(primary, secondary)
            for layout_id, expected_map_id, name in group:
                source_pin = pins["layouts"][layout_id]
                source_map = json.loads((root / source_pin["map_json_path"]).read_text(encoding="utf-8"))
                if source_map.get("id") != expected_map_id or source_map.get("layout") != layout_id:
                    raise ValueError(f"{name}: source map identity mismatch")
                report["maps"][name] = render_map(
                    root, layouts[layout_id], source_map, primary, secondary,
                    palettes, name, staging)
            # Render an actual 256px-wide RPG Maker XP tile atlas for this
            # source pair. Passage values remain explicitly UNREVIEWED.
            if label == "gate":
                targets = {"target": {"tileset_name": stem, "tileset_image": stem + ".png"}}
            else:
                targets = {"floors": {map_id: {
                    "tileset_name": stem, "tileset_image": stem + ".png"}
                    for _, map_id, _ in group}}
            targets["passage_reviewed"] = False
            base = staging / f".{label}_preview_base.json"
            base.write_text(json.dumps(targets), encoding="utf-8")
            png = staging / (stem + ".png")
            mapping_path = staging / (stem + ".json")
            mapping = build(root, [layout_id for layout_id, _, _ in group],
                            primary_dir, secondary_dir, base, png, mapping_path,
                            verify_source=verify_source)
            base.unlink()
            report["rmxp_tilesets"][label] = {
                "image": png.name, "mapping": mapping_path.name,
                "unique_source_cells": len(mapping["entries"]),
                "passage_reviewed": False, "preview_only": True}
        report["sha256"] = {
            p.name: digest(p) for p in sorted(staging.iterdir())
            if p.is_file() and p.name != "review_manifest.json"}
        (staging / "review_manifest.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8")
        # No output is published unless all four maps and both source atlases
        # succeed. The temporary directory is cleaned on any exception.
        os.rename(staging, output)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True,
                        help="private checkout of the exact pinned HnS revision")
    parser.add_argument("--output-dir", required=True,
                        help="new private directory; must not exist")
    args = parser.parse_args()
    result = generate(args.source_root, args.output_dir)
    print(f"Rendered {len(result['maps'])} source-grounded map previews and "
          f"{len(result['rmxp_tilesets'])} provisional RMXP tilesets: {args.output_dir}")
    print("PREVIEW ONLY: collision/passage review and native install are still required.")


if __name__ == "__main__":
    main()

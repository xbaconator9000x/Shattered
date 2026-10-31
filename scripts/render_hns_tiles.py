#!/usr/bin/env python3
"""Render privately obtained HnS GBA metatiles to native RMXP 32px tilesheets.

Source assets remain local. Output is a private PNG and a JSON mapping consumed
by convert_hns_reception_gate.py / convert_hns_victory_road.py. Source 16px
metatiles are scaled nearest-neighbour 2x to match RMXP's 32px grid.
Requires Pillow for indexed GBA source PNGs. Passage values must be reviewed
explicitly for every metatile; the GBA collision bits remain authoritative.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
from PIL import Image


SOURCE_REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
PIN_MANIFEST = Path(__file__).resolve().parents[1] / "development/hns_source_asset_pins.json"


def git_blob_sha1(path):
    data = Path(path).read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\x00" + data).hexdigest()


def verify_pinned_source(root, selected, primary_dir, secondary_dir):
    """Reject substituted HnS maps, metatiles, palettes and tiles before rendering."""
    pins = json.loads(PIN_MANIFEST.read_text(encoding="utf-8"))
    if (pins.get("source_repository") != "PokemonHnS-Development/pokehns-expansion" or
            pins.get("source_revision") != SOURCE_REVISION):
        raise ValueError("unrecognized HnS source manifest")
    pair = (str(Path(primary_dir)), str(Path(secondary_dir)))
    for record in selected:
        layout = pins["layouts"].get(record["id"])
        if layout is None:
            raise ValueError(f"unpinned HnS layout: {record['id']}")
        if pair != (layout["primary_dir"], layout["secondary_dir"]):
            raise ValueError(f"{record['id']}: source tileset directory pair mismatch")
        if record["blockdata_filepath"] != layout["blockdata_path"]:
            raise ValueError(f"{record['id']}: source blockdata path mismatch")
    def verify(relative, expected):
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or unsafe pinned HnS source asset: {relative}")
        if git_blob_sha1(path) != expected:
            raise ValueError(f"pinned HnS source blob mismatch: {relative}")
    verify("data/layouts/layouts.json", pins["layouts_sha1"])
    for record in selected:
        layout = pins["layouts"][record["id"]]
        verify(layout["map_json_path"], layout["map_json_sha1"])
        verify(layout["blockdata_path"], layout["blockdata_sha1"])
    for directory in pair:
        for relative, blob in pins["tilesets"][directory].items():
            verify(str(Path(directory) / relative), blob)



def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def palette(path):
    lines = Path(path).read_text(encoding="ascii").splitlines()
    if lines[:3] != ["JASC-PAL", "0100", "16"] or len(lines) < 19:
        raise ValueError(f"invalid JASC 16-color palette: {path}")
    colors = [tuple(map(int, line.split())) for line in lines[3:19]]
    if any(len(c) != 3 or any(n < 0 or n > 255 for n in c) for c in colors):
        raise ValueError(f"invalid JASC RGB values: {path}")
    return colors


def tileset(root):
    root = Path(root)
    image_path = root / "tiles.png"
    source = Image.open(image_path)
    if source.mode != "P" or source.width % 8 or source.height % 8:
        raise ValueError(f"source tileset must be indexed PNG with 8px grid: {image_path}")
    source.load()
    metatiles_path = root / "metatiles.bin"
    attributes_path = root / "metatile_attributes.bin"
    raw = metatiles_path.read_bytes()
    attrs = attributes_path.read_bytes()
    if len(raw) % 16 or len(attrs) * 8 != len(raw):
        raise ValueError(f"invalid metatile/attribute counts: {root}")
    return {"image": source, "metatiles": raw, "attrs": attrs,
            "columns": source.width // 8, "capacity": source.width * source.height // 64,
            "root": root, "sha256": {p.name: sha256(p) for p in
                (image_path, metatiles_path, attributes_path)}}


def render_metatile(metatile_id, primary, secondary, palettes):
    primary_count = len(primary["metatiles"]) // 16
    source = primary if metatile_id < primary_count else secondary
    local_id = metatile_id if source is primary else metatile_id - primary_count
    offset = local_id * 16
    if offset + 16 > len(source["metatiles"]):
        raise ValueError(f"metatile {metatile_id} is absent from source tilesets")
    words = struct.unpack_from("<8H", source["metatiles"], offset)
    layers = [Image.new("RGBA", (16, 16), (0, 0, 0, 0)) for _ in range(2)]
    for index, word in enumerate(words):
        tile_id = word & 0x3FF
        tile_source = primary if tile_id < 512 else secondary
        local_tile = tile_id if tile_source is primary else tile_id - 512
        if local_tile >= tile_source["capacity"]:
            raise ValueError(f"tile {tile_id} exceeds its source PNG atlas")
        palette_id = word >> 12
        if palette_id not in palettes:
            raise ValueError(f"GBA palette slot {palette_id} is unavailable")
        colors = palettes[palette_id]
        tile_x = (local_tile % tile_source["columns"]) * 8
        tile_y = (local_tile // tile_source["columns"]) * 8
        source_tile = tile_source["image"].crop((tile_x, tile_y, tile_x + 8, tile_y + 8))
        if word & 0x400:
            source_tile = source_tile.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if word & 0x800:
            source_tile = source_tile.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        indices = list(source_tile.getdata())
        if max(indices) > 15:
            raise ValueError(f"GBA source PNG contains non-4bpp index in tile {tile_id}")
        colored = Image.new("RGBA", (8, 8))
        colored.putdata([(*colors[p], 255 if p else 0) for p in indices])
        x, y = (index % 2) * 8, ((index % 4) // 2) * 8
        layers[index // 4].alpha_composite(colored, (x, y))
    return [layer.resize((32, 32), Image.Resampling.NEAREST) for layer in layers]


def checked_output_targets(mapping, png_path):
    """Bind a generated sheet to every consumer; never trust an unrelated PNG."""
    targets = []
    if "target" in mapping:
        targets.append(mapping["target"])
    if "floors" in mapping:
        floors = mapping["floors"]
        if not isinstance(floors, dict) or not floors:
            raise ValueError("floors must be a nonempty mapping")
        targets.extend(floors.values())
    if not targets:
        raise ValueError("mapping needs a gate target or Victory Road floor targets")
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError("invalid tileset target")
        name = target.get("tileset_name")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ValueError("invalid tileset name in output target")
        if target.get("tileset_image") != name + ".png":
            raise ValueError("target tileset image/name mismatch")
        if target["tileset_image"] != Path(png_path).name:
            raise ValueError("output PNG filename does not match mapped tileset image")
    return targets


def build(source_root, layout_ids, primary_dir, secondary_dir, base_mapping, png_path, mapping_path, verify_source=True):
    root = Path(source_root)
    layouts = json.loads((root / "data/layouts/layouts.json").read_text(encoding="utf-8"))["layouts"]
    by_id = {record["id"]: record for record in layouts}
    selected = [by_id[layout_id] for layout_id in layout_ids]
    if not selected:
        raise ValueError("at least one layout is required")
    expected_pair = (selected[0]["primary_tileset"], selected[0]["secondary_tileset"])
    if any((r["primary_tileset"], r["secondary_tileset"]) != expected_pair for r in selected):
        raise ValueError("layouts with different source tilesets require separate XP images")
    if verify_source:
        verify_pinned_source(root, selected, primary_dir, secondary_dir)
    primary = tileset(root / primary_dir)
    secondary = tileset(root / secondary_dir)
    palettes = {}
    # Emerald/FRLG overworld palette slots: 0..6 from primary, 7..12
    # from secondary; 13..15 from primary where present.
    for slot in range(16):
        directory = secondary["root"] if 7 <= slot <= 12 else primary["root"]
        path = directory / "palettes" / f"{slot:02d}.pal"
        if path.is_file():
            palettes[slot] = palette(path)
    mapping = json.loads(Path(base_mapping).read_text(encoding="utf-8"))
    if "entries" in mapping:
        raise ValueError("base mapping must not predefine generated entries")
    targets = checked_output_targets(mapping, png_path)
    passage = mapping.pop("passage_by_metatile", {})
    keys = set()
    for record in selected:
        binary = (root / record["blockdata_filepath"]).read_bytes()
        if len(binary) != record["width"] * record["height"] * 2:
            raise ValueError(f"incorrect blockdata size for {record['id']}")
        for (word,) in struct.iter_unpack("<H", binary):
            keys.add((word & 1023, (word >> 10) & 3, (word >> 12) & 15))
    missing = sorted({metatile for metatile, _, _ in keys if str(metatile) not in passage})
    if missing:
        raise ValueError(f"passage_by_metatile needs explicit reviewed entries: {missing}")
    count = len(keys) * 2
    if 384 + count > 8192:
        raise ValueError("too many unique tiles for RMXP")
    sheet = Image.new("RGBA", (256, ((count + 7) // 8) * 32))
    entries = {}
    for i, (metatile, collision, elevation) in enumerate(sorted(keys)):
        base_id = 384 + i * 2
        base_layer, upper_layer = render_metatile(metatile, primary, secondary, palettes)
        for layer_index, image in enumerate((base_layer, upper_layer)):
            offset = i * 2 + layer_index
            sheet.alpha_composite(image, ((offset % 8) * 32, (offset // 8) * 32))
        primary_count = len(primary["metatiles"]) // 16
        source = primary if metatile < primary_count else secondary
        local_metatile = metatile if source is primary else metatile - primary_count
        attr = struct.unpack_from("<H", source["attrs"], local_metatile * 2)[0]
        layer_type = (attr >> 12) & 15
        if layer_type not in (0, 1, 2):
            raise ValueError(f"metatile {metatile} has unsupported GBA layer type {layer_type}")
        blocked = collision != 0
        base_passage = 15 if blocked else passage[str(metatile)]
        if type(base_passage) is not int or not 0 <= base_passage <= 31:
            raise ValueError(f"invalid reviewed passage for metatile {metatile}")
        upper_priority = 0 if layer_type == 1 else 1
        upper_passage = base_passage if layer_type == 1 else 0
        entries[f"{metatile}:{collision}:{elevation}"] = {
            "layers": [base_id, base_id + 1, 0],
            "tables": [{"passage": base_passage, "priority": 0, "terrain": 0},
                       {"passage": upper_passage, "priority": upper_priority, "terrain": 0},
                       {"passage": 0, "priority": 0, "terrain": 0}]}
    png_path, mapping_path = Path(png_path), Path(mapping_path)
    if (png_path.resolve() == mapping_path.resolve() or png_path.is_symlink() or
            mapping_path.is_symlink() or png_path.exists() or mapping_path.exists()):
        raise ValueError("refusing to overwrite private generated output")
    image_buffer = io.BytesIO()
    sheet.save(image_buffer, format="PNG")
    png_bytes = image_buffer.getvalue()
    image_sha = hashlib.sha256(png_bytes).hexdigest()
    for target in targets:
        pinned = target.get("tileset_sha256")
        if pinned is not None and pinned != image_sha:
            raise ValueError("reviewed target tileset SHA-256 conflicts with generated PNG")
        target["tileset_sha256"] = image_sha
    mapping["entries"] = entries
    mapping["private_hns_art_manifest"] = {
        "layouts": list(layout_ids), "primary_tileset": expected_pair[0],
        "secondary_tileset": expected_pair[1], "primary_source": primary["sha256"],
        "secondary_source": secondary["sha256"], "source_pixel_scale": 2,
        "unique_mapping_keys": len(keys), "passage_reviewed": True,
        "rendered_tileset_sha256": image_sha,
        "in_engine_visual_and_collision_verified": False}
    mapping_bytes = (json.dumps(mapping, indent=2) + "\n").encode("utf-8")
    # Exclusive creation and rollback prevent a failed conversion leaving a
    # plausible-looking PNG/mapping pair or replacing approved private assets.
    created_png = created_mapping = False
    try:
        with png_path.open("xb") as stream:
            created_png = True
            stream.write(png_bytes)
        with mapping_path.open("xb") as stream:
            created_mapping = True
            stream.write(mapping_bytes)
    except BaseException:
        if created_mapping:
            mapping_path.unlink(missing_ok=True)
        if created_png:
            png_path.unlink(missing_ok=True)
        raise
    return mapping


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source-root", required=True)
    p.add_argument("--layout-id", action="append", required=True)
    p.add_argument("--primary-dir", required=True)
    p.add_argument("--secondary-dir", required=True)
    p.add_argument("--base-mapping", required=True)
    p.add_argument("--output-png", required=True)
    p.add_argument("--output-mapping", required=True)
    args = p.parse_args()
    result = build(args.source_root, args.layout_id, args.primary_dir, args.secondary_dir,
                   args.base_mapping, args.output_png, args.output_mapping)
    print(f"Rendered {len(result['entries'])} HnS source cells into private RMXP PNG and mapping")


if __name__ == "__main__":
    main()

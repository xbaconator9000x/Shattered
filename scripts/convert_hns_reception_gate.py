#!/usr/bin/env python3
"""Convert the HnS reception-gate layout into a rights-conscious Essentials import bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from resolve_hns_gate_warps import resolve_warp_targets


SOURCE_REPOSITORY = "https://github.com/PokemonHnS-Development/pokehns-expansion"
SOURCE_REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
MAP_PATH = "data/maps/ReceptionGate_hns/map.json"
LAYOUTS_PATH = "data/layouts/layouts.json"
BLOCKDATA_PATH = "data/layouts/ReceptionGate_hns/map.bin"
LAYOUT_ID = "LAYOUT_RECEPTION_GATE_HNS"
MAP_ID = "MAP_RECEPTION_GATE_HNS"
EXPECTED_WIDTH = 22
EXPECTED_HEIGHT = 21
# Git blob IDs from development/hns_source_asset_pins.json at SOURCE_REVISION.
# Reject lookalike/reconstructed map files even when dimensions and exits match.
PINNED_GATE_BLOBS = {
    "map": "8651cb350a508181bfd7b69fc216696cb67c6829",
    "layouts": "a3c3be1b411b1dca5a81494c7e2d4ef100b1e75d",
    "blockdata": "bb1affeda8bedc75358a7c72813a7e7c6db0c660",
}
DIRECTION_BY_DESTINATION = {
    "MAP_ROUTE28_HNS": "west",
    "MAP_ROUTE22_HNS": "east",
    "MAP_ROUTE26NORTH_HNS": "south",
    "MAP_VICTORY_ROAD_KANTO_B2F_HNS": "north",
}


def _read_json(path):
    with Path(path).open(encoding="utf-8") as stream:
        return json.load(stream)


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _layout_record(layouts, layout_id):
    records = layouts.get("layouts")
    if not isinstance(records, list):
        raise ValueError("layouts JSON has no layouts list")
    matches = [record for record in records if record.get("id") == layout_id]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {layout_id} layout record")
    return matches[0]


def _classify_warp(warp):
    destination = warp.get("dest_map")
    if destination not in DIRECTION_BY_DESTINATION:
        raise ValueError(f"unrecognized source warp destination: {destination!r}")
    return DIRECTION_BY_DESTINATION[destination]


def git_blob_sha1(path):
    """Git blob identity, not the ordinary SHA-1 of file contents."""
    data = Path(path).read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\x00" + data).hexdigest()


def verify_pinned_gate_source(map_json, layouts_json, map_bin):
    """Require exact reviewed HnS source files before production conversion."""
    for label, path in (("map", map_json), ("layouts", layouts_json),
                        ("blockdata", map_bin)):
        if git_blob_sha1(path) != PINNED_GATE_BLOBS[label]:
            raise ValueError(f"{label}: not the pinned HnS source Git blob")
    return True


def inspect_source(map_json, layouts_json, map_bin, *, verify_source=True):
    if verify_source:
        verify_pinned_gate_source(map_json, layouts_json, map_bin)
    map_data = _read_json(map_json)
    layouts_data = _read_json(layouts_json)
    binary = Path(map_bin).read_bytes()
    if map_data.get("id") != MAP_ID or map_data.get("layout") != LAYOUT_ID:
        raise ValueError("source map is not the expected HnS ReceptionGate_hns map")
    layout = _layout_record(layouts_data, map_data["layout"])
    width, height = layout.get("width"), layout.get("height")
    if (width, height) != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
        raise ValueError(f"expected a {EXPECTED_WIDTH}x{EXPECTED_HEIGHT} layout")
    if len(binary) != width * height * 2:
        raise ValueError("GBA blockdata must contain one little-endian word per map cell")
    tuples = sorted({
        (word & 0x03FF, (word >> 10) & 0x03, (word >> 12) & 0x0F)
        for (word,) in struct.iter_unpack("<H", binary)
    })
    warps = map_data.get("warp_events")
    if not isinstance(warps, list):
        raise ValueError("source map has no warp_events list")
    named_warps = []
    for warp in warps:
        direction = _classify_warp(warp)
        if not (0 <= warp.get("x", -1) < width and 0 <= warp.get("y", -1) < height):
            raise ValueError("source warp lies outside the map")
        named_warps.append({
            "direction": direction,
            "x": warp["x"],
            "y": warp["y"],
            "source_destination": warp["dest_map"],
            "source_warp_id": str(warp.get("dest_warp_id", "0")),
        })
    counts = {name: sum(w["direction"] == name for w in named_warps)
              for name in ("west", "east", "south", "north")}
    if counts != {"west": 1, "east": 1, "south": 1, "north": 2}:
        raise ValueError(f"unexpected directional warp layout: {counts}")
    return {
        "map": map_data,
        "layout": layout,
        "binary": binary,
        "warps": named_warps,
        "required_mapping_keys": [f"{block}:{collision}:{elevation}"
                                 for block, collision, elevation in tuples],
    }


def _mapping_entry(mapping, metatile, collision, elevation):
    key = f"{metatile}:{collision}:{elevation}"
    entry = mapping.get("entries", {}).get(key)
    if entry is None:
        raise ValueError(f"missing tile mapping entry {key}")
    layers = entry.get("layers")
    tables = entry.get("tables")
    if (not isinstance(layers, list) or len(layers) != 3 or
            not isinstance(tables, list) or len(tables) != 3):
        raise ValueError(f"{key} must define three XP layers and three table records")
    for tile_id in layers:
        if not isinstance(tile_id, int) or not 0 <= tile_id <= 8191:
            raise ValueError(f"{key} contains an invalid XP tile ID")
        if tile_id != 0 and tile_id < 384:
            raise ValueError(f"{key} uses an autotile ID without an autotile mapping")
    normalized_tables = []
    for values in tables:
        if not isinstance(values, dict):
            raise ValueError(f"{key} has an invalid tileset table record")
        passage = values.get("passage")
        priority = values.get("priority")
        terrain = values.get("terrain")
        if not isinstance(passage, int) or not 0 <= passage <= 31:
            raise ValueError(f"{key} passage must be an XP passage bitmask (0..31)")
        if not isinstance(priority, int) or not 0 <= priority <= 5:
            raise ValueError(f"{key} priority must be between 0 and 5")
        if not isinstance(terrain, int) or not 0 <= terrain <= 255:
            raise ValueError(f"{key} terrain tag must be between 0 and 255")
        normalized_tables.append({
            "passage": passage,
            "priority": priority,
            "terrain": terrain,
        })
    if layers[0] == 0 and any(normalized_tables[0].values()):
        raise ValueError(f"{key} cannot assign collision/tags to the transparent XP tile")
    return layers, normalized_tables


def convert(map_json, layouts_json, map_bin, mapping_json, *, verify_source=True):
    source = inspect_source(map_json, layouts_json, map_bin, verify_source=verify_source)
    mapping = _read_json(mapping_json)
    target = mapping.get("target", {})
    for field in ("map_id", "tileset_template_id", "tileset_name", "tileset_image"):
        if field not in target:
            raise ValueError(f"mapping target is missing {field}")
    for field in ("map_id", "tileset_template_id"):
        if not isinstance(target[field], int) or target[field] <= 0:
            raise ValueError(f"mapping target {field} must be a positive integer")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", target["tileset_name"]):
        raise ValueError("tileset_name must be a simple filename stem")
    if target["tileset_image"] != target["tileset_name"] + ".png":
        raise ValueError("tileset_image must be the PNG named by tileset_name")
    image_sha = target.get("tileset_sha256")
    if not isinstance(image_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", image_sha):
        raise ValueError("generated gate tileset requires a SHA-256 from the private renderer")

    # Destination-only mappings cannot distinguish the two northern exits,
    # which lead to the same source map but must have distinct native landings.
    # The pinned map.json warp_events order is the stable source index.
    targets = resolve_warp_targets(source["warps"], mapping)
    output_warps = [
        {**warp, "source_warp_index": index, "target": target}
        for index, (warp, target) in enumerate(zip(source["warps"], targets))
    ]

    width = source["layout"]["width"]
    height = source["layout"]["height"]
    layers = [[0] * (width * height) for _ in range(3)]
    source_collision = []
    source_elevation = []
    tile_tables = {}
    for offset, (word,) in enumerate(struct.iter_unpack("<H", source["binary"])):
        metatile = word & 0x03FF
        collision = (word >> 10) & 0x03
        elevation = (word >> 12) & 0x0F
        tile_layers, tables = _mapping_entry(mapping, metatile, collision, elevation)
        for z, tile_id in enumerate(tile_layers):
            layers[z][offset] = tile_id
            encoded = [tables[z]["passage"], tables[z]["priority"], tables[z]["terrain"]]
            key = str(tile_id)
            if key in tile_tables and tile_tables[key] != encoded:
                raise ValueError(f"XP tile {tile_id} is assigned conflicting table values")
            tile_tables[key] = encoded
        source_collision.append(collision)
        source_elevation.append(elevation)

    map_bytes = Path(map_json).read_bytes()
    layouts_bytes = Path(layouts_json).read_bytes()
    return {
        "format": "shattered-hns-rmxp-map",
        "format_version": 1,
        "map_name": "Heart & Soul League Reception Gate",
        "dimensions": {"width": width, "height": height, "tile_pixels": 32},
        "target": {
            "map_id": target["map_id"],
            "tileset_template_id": target["tileset_template_id"],
            "tileset_name": target["tileset_name"],
            "tileset_image": target["tileset_image"],
            "tileset_sha256": image_sha,
        },
        "source": {
            "repository": SOURCE_REPOSITORY,
            "revision": SOURCE_REVISION,
            "map_path": MAP_PATH,
            "map_sha256": _sha256(map_bytes),
            "layout_path": LAYOUTS_PATH,
            "layout_sha256": _sha256(layouts_bytes),
            "blockdata_path": BLOCKDATA_PATH,
            "blockdata_sha256": _sha256(source["binary"]),
            "layout_id": source["layout"]["id"],
            "primary_tileset": source["layout"]["primary_tileset"],
            "secondary_tileset": source["layout"]["secondary_tileset"],
            "source_palettes_included": False,
            "palette_directories": [
                "data/tilesets/primary/johto_building_hns/palettes",
                "data/tilesets/secondary/pokemon_center_white_hns/palettes",
            ],
        },
        "layers": layers,
        "source_collision": source_collision,
        "source_elevation": source_elevation,
        "tileset_tables": tile_tables,
        "warps": output_warps,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map-json", required=True)
    parser.add_argument("--layouts-json", required=True)
    parser.add_argument("--map-bin", required=True)
    parser.add_argument("--mapping",
                        help="rights-cleared XP tile, tables, and destination mapping JSON")
    parser.add_argument("--output")
    parser.add_argument("--inspect-only", action="store_true",
                        help="report dimensions, named exits, tilesets, and required tuple keys")
    args = parser.parse_args()
    if args.inspect_only:
        source = inspect_source(args.map_json, args.layouts_json, args.map_bin)
        result = {
            "dimensions": {"width": source["layout"]["width"],
                           "height": source["layout"]["height"]},
            "primary_tileset": source["layout"]["primary_tileset"],
            "secondary_tileset": source["layout"]["secondary_tileset"],
            "warps": source["warps"],
            "required_mapping_keys": source["required_mapping_keys"],
        }
        print(json.dumps(result, indent=2))
        return
    if not args.mapping or not args.output:
        parser.error("--mapping and --output are required unless --inspect-only is set")
    result = convert(args.map_json, args.layouts_json, args.map_bin, args.mapping)
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {args.output} ({result['dimensions']['width']}x"
          f"{result['dimensions']['height']}, 3 layers, "
          f"{len(result['warps'])} warps)")


if __name__ == "__main__":
    main()

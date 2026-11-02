#!/usr/bin/env python3
"""Source-pinned, PRIVATE HnS GBA metatile/palette -> RPG Maker XP conversion.

Produces a tilesheet and the existing reception_gate.json format. Does not
install native maps or establish runtime/visual acceptance or redistribution
rights. No Pokémon graphics or upstream source files belong in this repo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from PIL import Image

SOURCE_REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
PRIMARY = "data/tilesets/primary/johto_building_hns"
SECONDARY = "data/tilesets/secondary/pokemon_center_white_hns"
FIRST_XP_TILE = 384
PRIMARY_COUNT = 640
SECONDARY_COUNT = 384
EXPECTED_METATILES = 46
EXPECTED_PALETTES = frozenset((0, 5, 7, 10, 12))
SOURCE_SHA256 = {
    "data/maps/ReceptionGate_hns/map.json": "98a04926dd4ae012bb0ea0abe4653cfc060797496dd119a04cffbd8ce38618ab",
    "data/layouts/layouts.json": "3b548d055a81dbffb2348d3435077006e8b46aa19df1f2bd5798df218fba5ea3",
    "data/layouts/ReceptionGate_hns/map.bin": "121ddb32e6327f14469b7d7168900c2ee131bb822cccc0cb0139d5fd4168f3a7",
}
SOURCE_BLOBS = {
    PRIMARY + "/tiles.png": "d3d272162cfc2b297ef04dcae8f930457a0819db",
    SECONDARY + "/tiles.png": "a8067b3d475820458243967c115f61eebca28078",
    PRIMARY + "/metatiles.bin": "0eeb33833964928381ed700cfeab06a68b83b927",
    SECONDARY + "/metatiles.bin": "402af18d3a2ac531bd35e3afa231bc6ff1bc049e",
    PRIMARY + "/palettes/00.pal": "56e86d065a0de77609e904274cd8e31c04461d42",
    PRIMARY + "/palettes/05.pal": "c931e5fd2b3cba95a592d3dcc033cdcdaf6cce2e",
    SECONDARY + "/palettes/07.pal": "500e5da13238b078d48317985d38ef31e9b0f302",
    SECONDARY + "/palettes/10.pal": "a8f455c4d419ad20f5fa63d98ffc55aa832e93d7",
    SECONDARY + "/palettes/12.pal": "d1c5f8919caf2eaea0c88cdab6eb5a36051df4a2",
}

def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

def regular_bytes(root, relative, sha256=None, blob=None):
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError("Missing or symlinked source: " + relative)
    data = path.read_bytes()
    if sha256 and hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError("Pinned SHA256 mismatch: " + relative)
    if blob and blob_sha(data) != blob:
        raise ValueError("Pinned Git blob mismatch: " + relative)
    return data

def read_palette(data):
    lines = data.decode("ascii").splitlines()
    if lines[:3] != ["JASC-PAL", "0100", "16"] or len(lines) != 19:
        raise ValueError("Invalid pinned JASC-PAL")
    colors = []
    for line in lines[3:]:
        parts = line.split()
        if len(parts) != 3:
            raise ValueError("Invalid palette RGB")
        rgb = tuple(map(int, parts))
        if any(c < 0 or c > 255 for c in rgb):
            raise ValueError("Palette RGB out of range")
        colors.append(rgb)
    return colors

def read_tiles(path, size):
    with Image.open(path) as source:
        if source.format != "PNG" or source.mode != "P" or source.size != size:
            raise ValueError("Unexpected indexed HnS tile sheet")
        image = source.copy()
    if image.getextrema()[1] > 15:
        raise ValueError("GBA tile indices must be 0..15")
    return image

def decode_metatile(data, index):
    offset = index * 16
    if index < 0 or offset + 16 > len(data):
        raise ValueError("Metatile outside source")
    return struct.unpack_from("<8H", data, offset)

def tile_image(word, primary, secondary, palettes, upper):
    tile_id, palette_id = word & 1023, word >> 12
    if palette_id not in palettes:
        raise ValueError("Missing source palette " + str(palette_id))
    sheet, index = (primary, tile_id) if tile_id < PRIMARY_COUNT else (secondary, tile_id - PRIMARY_COUNT)
    if sheet.size != ((128, 320) if sheet is primary else (128, 192)):
        raise ValueError("GBA source sheet dimensions changed")
    if index >= (PRIMARY_COUNT if sheet is primary else SECONDARY_COUNT):
        raise ValueError("GBA subtile outside source sheet")
    x, y = index % 16 * 8, index // 16 * 8
    pixels = sheet.crop((x, y, x + 8, y + 8))
    if word & 0x400:
        pixels = pixels.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    if word & 0x800:
        pixels = pixels.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    rgba = Image.new("RGBA", (8, 8))
    rgba.putdata([(*palettes[palette_id][v], 0 if upper and v == 0 else 255)
                  for v in pixels.getdata()])
    return rgba

def render_metatile(words, primary, secondary, palettes, upper):
    image = Image.new("RGBA", (16, 16))
    for i, word in enumerate(words[4:] if upper else words[:4]):
        image.alpha_composite(tile_image(word, primary, secondary, palettes, upper),
                              (i % 2 * 8, i // 2 * 8))
    return image.resize((32, 32), Image.Resampling.NEAREST)

def build_layers(map_words, primary_meta, secondary_meta, primary, secondary, palettes):
    unique = sorted({w & 1023 for w in map_words})
    if len(unique) != EXPECTED_METATILES:
        raise ValueError("Unexpected source metatile inventory")
    tiles, assigned, used_palettes = [], {}, set()
    for metatile in unique:
        meta = primary_meta if metatile < PRIMARY_COUNT else secondary_meta
        index = metatile if metatile < PRIMARY_COUNT else metatile - PRIMARY_COUNT
        words = decode_metatile(meta, index)
        used_palettes.update(w >> 12 for w in words)
        lower = render_metatile(words, primary, secondary, palettes, False)
        upper = render_metatile(words, primary, secondary, palettes, True)
        lower_id = FIRST_XP_TILE + len(tiles)
        tiles.append(lower)
        upper_id = 0
        if upper.getbbox():
            upper_id = FIRST_XP_TILE + len(tiles)
            tiles.append(upper)
        assigned[metatile] = lower_id, upper_id
    if used_palettes != EXPECTED_PALETTES:
        raise ValueError("Unexpected source palette usage")
    sheet = Image.new("RGBA", (256, ((len(tiles) + 7) // 8) * 32))
    for i, tile in enumerate(tiles):
        sheet.alpha_composite(tile, (i % 8 * 32, i // 8 * 32))
    mapping = {}
    for word in sorted(set(map_words)):
        metatile, collision, elevation = word & 1023, (word >> 10) & 3, word >> 12
        lower, upper = assigned[metatile]
        mapping[f"{metatile}:{collision}:{elevation}"] = {
            "layers": [lower, upper, 0],
            "tables": [
                {"passage": 0 if collision == 0 else 15, "priority": 0, "terrain": 0},
                {"passage": 0, "priority": 1 if upper else 0, "terrain": 0},
                {"passage": 0, "priority": 0, "terrain": 0},
            ],
        }
    return sheet, mapping, {
        "source_metatiles": len(unique), "rendered_xp_tiles": len(tiles),
        "source_palette_ids": sorted(used_palettes),
        "source_collision_codes": sorted({(w >> 10) & 3 for w in map_words}),
        "source_elevation_codes": sorted({w >> 12 for w in map_words}),
    }

def convert(root, output, destinations):
    root = root.resolve(strict=True)
    if output.exists() or output.is_symlink():
        raise ValueError("Refusing to overwrite existing private output")
    expected_destinations = {"MAP_ROUTE28_HNS", "MAP_ROUTE22_HNS",
        "MAP_ROUTE26NORTH_HNS", "MAP_VICTORY_ROAD_KANTO_B2F_HNS"}
    if not isinstance(destinations, dict) or set(destinations) != expected_destinations | {"per_warp_destinations"}:
        raise ValueError("Four reviewed destinations and per-warp landings required")
    overrides = destinations["per_warp_destinations"]
    if set(overrides) != {"10,1", "11,1"}:
        raise ValueError("Both north door landings must be reviewed separately")
    for path, sha in SOURCE_SHA256.items():
        regular_bytes(root, path, sha256=sha)
    for path, sha in SOURCE_BLOBS.items():
        regular_bytes(root, path, blob=sha)
    words = struct.unpack("<462H", regular_bytes(root, "data/layouts/ReceptionGate_hns/map.bin"))
    primary = read_tiles(root / PRIMARY / "tiles.png", (128, 320))
    secondary = read_tiles(root / SECONDARY / "tiles.png", (128, 192))
    palettes = {}
    for number in EXPECTED_PALETTES:
        folder = PRIMARY if number < 7 else SECONDARY
        palettes[number] = read_palette(regular_bytes(root, f"{folder}/palettes/{number:02d}.pal"))
    sheet, entries, summary = build_layers(words,
        regular_bytes(root, PRIMARY + "/metatiles.bin"),
        regular_bytes(root, SECONDARY + "/metatiles.bin"), primary, secondary, palettes)
    from convert_hns_reception_gate import convert as convert_map
    mapping = {
        "target": {"map_id": 223, "tileset_template_id": 1,
                   "tileset_name": "ShatteredHnSAuthenticGate",
                   "tileset_image": "ShatteredHnSAuthenticGate.png"},
        "destinations": {key: value for key, value in destinations.items()
                         if key != "per_warp_destinations"},
        "per_warp_destinations": overrides,
        "require_distinct_warp_landings": True,
        "entries": entries,
    }
    temporary = output.with_name(output.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError("Stale private output transaction")
    try:
        temporary.mkdir(parents=True)
        mapping_path = temporary / "mapping.json"
        mapping_path.write_text(json.dumps(mapping, indent=2) + "\n")
        bundle = convert_map(root / "data/maps/ReceptionGate_hns/map.json",
            root / "data/layouts/layouts.json",
            root / "data/layouts/ReceptionGate_hns/map.bin", mapping_path)
        (temporary / "reception_gate.json").write_text(json.dumps(bundle, indent=2) + "\n")
        image_path = temporary / "ShatteredHnSAuthenticGate.png"
        sheet.save(image_path)
        (temporary / "receipt.json").write_text(json.dumps({
            "kind": "private_hns_metatile_conversion_not_runtime_acceptance",
            "source_revision": SOURCE_REVISION, "summary": summary,
            "tileset_sha256": hashlib.sha256(image_path.read_bytes()).hexdigest(),
            "native_map_installed": False, "visual_parity_verified": False,
            "collision_runtime_verified": False, "redistribution_approved": False
        }, indent=2) + "\n")
        temporary.rename(output)
    except BaseException:
        import shutil
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return summary

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hns-root", type=Path, required=True)
    parser.add_argument("--destinations", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(convert(args.hns_root, args.output,
                             json.loads(args.destinations.read_text())), indent=2))

if __name__ == "__main__":
    main()

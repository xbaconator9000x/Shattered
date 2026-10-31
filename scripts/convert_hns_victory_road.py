#!/usr/bin/env python3
"""Convert pinned HnS Victory Road GBA blockdata to three RMXP tile-layer bundles.

No Pokémon assets or GBA binaries are embedded. Conversion requires locally
held source map.json, layouts.json, map.bin and an independently reviewed,
rights-cleared XP tileset mapping. This emits data for a future native installer,
NOT a playable Essentials project.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from audit_hns_victory_road import audit, FLOORS, MAP_IDS, EXPECTED_DIMENSIONS
from convert_hns_reception_gate import _mapping_entry

SOURCE_REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
FORMAT = "shattered-hns-victory-road-rmxp-bundle"
PINNED_LAYOUTS_BLOB = "a3c3be1b411b1dca5a81494c7e2d4ef100b1e75d"
PINNED_FLOOR_BLOBS = (
    ("b072627ee9e367690dd909881f9ea52a6e390ed1", "db84795062e12349416c2cdb4183e2dc36ee22bc"),
    ("65ec4beafef41872863f34998219365c0792d7b7", "f4e9b9bbe18b619b18574e88f9737800c75358db"),
    ("ce561685d1d3835b6625b4c22faa76ba9f1f2a2d", "11f1e34ee30291542e06a8eba45b3be14f792aa1"),
)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_blob_sha1(path):
    data = Path(path).read_bytes()
    header = b"blob " + str(len(data)).encode("ascii") + b"\x00"
    return hashlib.sha1(header + data).hexdigest()


def positive(value, label, minimum=1):
    if type(value) is not int or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def build_bundle(source_root, mapping_path, verify_source=True):
    source_root = Path(source_root)
    map_dir = source_root / "data" / "maps"
    layouts_dir = source_root / "data" / "layouts"
    layouts_path = layouts_dir / "layouts.json"
    if verify_source and git_blob_sha1(layouts_path) != PINNED_LAYOUTS_BLOB:
        raise ValueError("unrecognized source layouts.json Git blob")
    topology = audit(map_dir, layouts_path)
    if topology["anomalies"]:
        raise ValueError("source warp graph has unresolved anomalies")
    mapping = json.loads(Path(mapping_path).read_text(encoding="utf-8"))
    floor_targets = mapping.get("floors", {})
    warp_targets = mapping.get("warp_targets", {})
    if set(floor_targets) != set(MAP_IDS):
        raise ValueError("mapping must explicitly define all three source floor IDs")
    if not isinstance(warp_targets, dict):
        raise ValueError("warp_targets must be an object")
    resolved = {}
    target_ids = set()
    for map_id in MAP_IDS:
        target = floor_targets[map_id]
        if not isinstance(target, dict):
            raise ValueError(f"invalid target floor: {map_id}")
        native_id = positive(target.get("map_id"), f"{map_id} target map ID")
        positive(target.get("tileset_template_id"), f"{map_id} tileset template ID")
        stem = target.get("tileset_name")
        if not isinstance(stem, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", stem):
            raise ValueError(f"{map_id}: invalid tileset filename")
        if target.get("tileset_image") != stem + ".png":
            raise ValueError(f"{map_id}: mismatched tileset image filename")
        if native_id in target_ids:
            raise ValueError("Victory Road target map IDs must be unique")
        target_ids.add(native_id)
        resolved[map_id] = native_id

    floor_data = []
    expected_warp_keys = set()
    for floor_name, map_id, dimensions, expected_blobs in zip(\n            FLOORS, MAP_IDS, EXPECTED_DIMENSIONS, PINNED_FLOOR_BLOBS):
        map_path = map_dir / floor_name / "map.json"
        bin_path = layouts_dir / floor_name / "map.bin"
        if verify_source and (git_blob_sha1(map_path), git_blob_sha1(bin_path)) != expected_blobs:
            raise ValueError(f"{floor_name}: source Git blob mismatch at pinned revision")
        source_map = json.loads(map_path.read_text(encoding="utf-8"))
        raw = bin_path.read_bytes()
        width, height = dimensions
        if len(raw) != width * height * 2:
            raise ValueError(f"{floor_name}: wrong GBA blockdata length")
        layers = [[0] * (width * height) for _ in range(3)]
        collision = []
        elevation = []
        tables = {}
        for index, (word,) in enumerate(struct.iter_unpack("<H", raw)):
            metatile = word & 0x03FF
            cell_collision = (word >> 10) & 3
            cell_elevation = (word >> 12) & 15
            tile_layers, tile_tables = _mapping_entry(
                mapping, metatile, cell_collision, cell_elevation)
            for z, tile_id in enumerate(tile_layers):
                layers[z][index] = tile_id
                table = [tile_tables[z][field] for field in ("passage", "priority", "terrain")]
                key = str(tile_id)
                if key in tables and tables[key] != table:
                    raise ValueError(f"{floor_name}: conflicting XP table values for tile {tile_id}")
                tables[key] = table
            collision.append(cell_collision)
            elevation.append(cell_elevation)

        warps = []
        for index, source_warp in enumerate(source_map["warp_events"]):
            key = f"{map_id}:{index}"
            expected_warp_keys.add(key)
            destination = warp_targets.get(key)
            if not isinstance(destination, dict):
                raise ValueError(f"missing explicit XP warp landing for {key}")
            target_map_id = positive(destination.get("map_id"), f"{key} target map ID")
            source_dest = source_warp["dest_map"]
            if source_dest in resolved and target_map_id != resolved[source_dest]:
                raise ValueError(f"{key}: target map ID disagrees with linked Victory Road floor")
            x = positive(destination.get("x"), f"{key} target x", 0)
            y = positive(destination.get("y"), f"{key} target y", 0)
            if source_dest in resolved:
                dest_dims = EXPECTED_DIMENSIONS[MAP_IDS.index(source_dest)]
                if x >= dest_dims[0] or y >= dest_dims[1]:
                    raise ValueError(f"{key}: target landing outside linked Victory Road floor")
            direction = destination.get("direction", 0)
            if type(direction) is not int or direction not in (0, 2, 4, 6, 8):
                raise ValueError(f"{key}: invalid XP landing direction")
            fade = destination.get("fade", 0)
            if type(fade) is not int or fade not in (0, 1):
                raise ValueError(f"{key}: invalid XP fade flag")
            warps.append({
                "source_warp_index": index,
                "x": source_warp["x"], "y": source_warp["y"],
                "source_destination": source_dest,
                "source_destination_warp_id": source_warp["dest_warp_id"],
                "target": {"map_id": target_map_id, "x": x, "y": y,
                           "direction": direction, "fade": fade},
                "external_landing_unverified": source_dest not in resolved,
            })
        floor_data.append({
            "source_map_id": map_id, "source_layout_id": source_map["layout"],
            "dimensions": {"width": width, "height": height},
            "target": floor_targets[map_id],
            "source": {"map_sha256": sha256(map_path), "blockdata_sha256": sha256(bin_path)},
            "layers": layers, "source_collision": collision,
            "source_elevation": elevation, "tileset_tables": tables,
            "warps": warps,
        })
    if set(warp_targets) != expected_warp_keys:
        raise ValueError("warp_targets contains unknown or omitted source warp keys")
    return {
        "format": FORMAT, "format_version": 1,
        "source_repository": "PokemonHnS-Development/pokehns-expansion",
        "source_revision": SOURCE_REVISION,
        "layouts_sha256": sha256(layouts_path),
        "floors": floor_data,
        "native_compiled": False,
        "runtime_verified": False,
        "rights_and_collision_review_required": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True,
                        help="private pinned Heart & Soul source checkout")
    parser.add_argument("--mapping", required=True,
                        help="reviewed XP tiles, passage tables, floor IDs and explicit warp landings")
    parser.add_argument("--output", required=True, help="private generated JSON bundle")
    args = parser.parse_args()
    bundle = build_bundle(args.source_root, args.mapping)
    output = Path(args.output)
    if output.exists():
        raise ValueError("refusing to overwrite an existing Victory Road bundle")
    output.write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")
    print(f"Converted {len(bundle['floors'])} floors and "
          f"{sum(len(f['warps']) for f in bundle['floors'])} source warps; "
          "native installation and runtime verification still required")


if __name__ == "__main__":
    main()

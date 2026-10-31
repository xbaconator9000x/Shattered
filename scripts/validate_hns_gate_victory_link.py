#!/usr/bin/env python3
"""Offline static acceptance gate for the private HnS Reception Gate/Victory Road link.

Consumes the real converter outputs, not game assets. Passing does not prove
native Essentials compilation, movement, collision, save/reload or Android.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

GATE_FORMAT = "shattered-hns-rmxp-map"
ROAD_FORMAT = "shattered-hns-victory-road-rmxp-bundle"
B2F = "MAP_VICTORY_ROAD_KANTO_B2F_HNS"
GATE = "MAP_RECEPTION_GATE_HNS"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, name, minimum=0):
    require(type(value) is int and value >= minimum, f"{name} must be an integer >= {minimum}")
    return value


def walkable(map_data, x, y):
    dimensions = map_data["dimensions"]
    width = integer(dimensions["width"], "map width", 1)
    height = integer(dimensions["height"], "map height", 1)
    integer(x, "landing x")
    integer(y, "landing y")
    require(x < width and y < height, "landing outside destination map")
    index = y * width + x
    layers = map_data["layers"]
    require(len(layers) == 3 and all(len(layer) == width * height for layer in layers),
            "destination tile layers have invalid geometry")
    collision = map_data.get("source_collision")
    require(isinstance(collision, list) and len(collision) == width * height,
            "missing source collision grid")
    require(collision[index] == 0, "landing is blocked in source collision grid")
    require(all((warp["x"], warp["y"]) != (x, y) for warp in map_data["warps"]),
            "landing overlaps a Player Touch warp event")
    require(layers[0][index] >= 384, "landing has no ordinary ground tile")
    for layer in layers:
        tile_id = layer[index]
        if tile_id == 0:
            continue
        table = map_data["tileset_tables"].get(str(tile_id))
        require(isinstance(table, list) and len(table) == 3,
                f"landing tile {tile_id} lacks reviewed passage table")
        passage = integer(table[0], "tile passage")
        require(passage <= 31, "invalid XP passage mask")
        if passage & 0x10:
            continue
        require((passage & 0x0f) == 0, "landing blocked by native XP passage")
    return True


def check(gate, road):
    require(gate.get("format") == GATE_FORMAT and road.get("format") == ROAD_FORMAT,
            "wrong converter bundle formats")
    require(gate.get("format_version") == 1 and road.get("format_version") == 1,
            "unsupported converter bundle versions")
    require(road.get("source_revision") == "167aa6d537b109bb229c231ddce4616974c4da71",
            "unrecognized HnS source revision")
    floors = road.get("floors")
    require(isinstance(floors, list) and len(floors) == 3,
            "Victory Road must have three converted floors")
    by_name = {floor["source_map_id"]: floor for floor in floors}
    require(len(by_name) == 3 and B2F in by_name, "missing unique B2F source floor")
    gate_id = integer(gate["target"]["map_id"], "gate map ID", 1)
    floor_ids = [integer(floor["target"]["map_id"], "road map ID", 1) for floor in floors]
    require(gate_id not in floor_ids and len(set(floor_ids)) == 3,
            "native map IDs overlap")
    for target in [gate["target"], *(floor["target"] for floor in floors)]:
        require(isinstance(target.get("tileset_sha256"), str) and
                re.fullmatch(r"[0-9a-f]{64}", target["tileset_sha256"]),
                "missing rendered tileset SHA-256")
    b2f = by_name[B2F]
    b2f_id = b2f["target"]["map_id"]
    exit_warps = [warp for warp in b2f["warps"] if warp["source_destination"] == GATE]
    require(len(exit_warps) == 1, "B2F must have one Reception Gate return warp")
    exit_warp = exit_warps[0]
    require(exit_warp["target"]["map_id"] == gate_id,
            "B2F return points to the wrong native map")
    gate_warps = gate["warps"]
    north = [warp for warp in gate_warps if warp["direction"] == "north"]
    require(len(north) == 2, "Reception Gate must have two northern Victory Road exits")
    # Two separate source doorways cannot silently converge on one landing.
    # Otherwise static validation could report success while the native
    # four-map installer correctly rejects the same converted bundles.
    landings = {(warp["target"]["map_id"], warp["target"]["x"],
                 warp["target"]["y"]) for warp in north}
    require(len(landings) == 2,
            "two Reception Gate north exits collapse onto one B2F landing")
    for warp in north:
        require(warp["source_destination"] == B2F and
                warp["target"]["map_id"] == b2f_id,
                "gate north exit does not point to native B2F")
        target = warp["target"]
        require(abs(target["x"] - exit_warp["x"]) +
                abs(target["y"] - exit_warp["y"]) == 1,
                "gate-to-B2F landing must be adjacent to the source return warp")
        walkable(b2f, target["x"], target["y"])
    source_gate_index = integer(int(exit_warp["source_destination_warp_id"]),
                                "source gate warp index")
    require(source_gate_index < len(gate_warps), "source gate warp index out of range")
    expected_gate_warp = gate_warps[source_gate_index]
    require(expected_gate_warp["direction"] == "north",
            "B2F return does not refer to a north gate warp")
    target = exit_warp["target"]
    require(abs(target["x"] - expected_gate_warp["x"]) +
            abs(target["y"] - expected_gate_warp["y"]) == 1,
            "B2F-to-gate landing must be adjacent to its source warp")
    walkable(gate, target["x"], target["y"])
    return {"gate_map_id": gate_id, "victory_road_b2f_map_id": b2f_id,
            "gate_north_exits_checked": len(north), "b2f_return_exits_checked": 1,
            "static_bidirectional_landing_checks_passed": True,
            "native_gameplay_verified": False, "android_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate-bundle", required=True)
    parser.add_argument("--victory-road-bundle", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    gate_path = Path(args.gate_bundle)
    road_path = Path(args.victory_road_bundle)
    result = check(json.loads(gate_path.read_text()), json.loads(road_path.read_text()))
    result["gate_bundle_sha256"] = hashlib.sha256(gate_path.read_bytes()).hexdigest()
    result["victory_road_bundle_sha256"] = hashlib.sha256(road_path.read_bytes()).hexdigest()
    output = Path(args.output)
    with output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

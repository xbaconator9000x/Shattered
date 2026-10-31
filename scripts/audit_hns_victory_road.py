#!/usr/bin/env python3
"""Audit the original Heart & Soul Kanto Victory Road 3-floor warp graph.

Input: privately sourced upstream map.json and layouts.json. Never copy graphics,
ROM blockdata or source assets into this repository. Source warp ids are
zero-based indices into destination warp_events; broken links are reported,
not silently rewritten or inferred.
"""
import argparse
import json
from pathlib import Path

FLOORS = ("VictoryRoadKanto_1F_hns", "VictoryRoadKanto_B1F_hns",
          "VictoryRoadKanto_B2F_hns")
MAP_IDS = tuple("MAP_" + n.upper() for n in FLOORS)
EXTERNAL = {"MAP_RECEPTION_GATE_HNS", "MAP_ROUTE23_HNS"}


def audit(maps_dir, layouts_path):
    layouts = json.loads(Path(layouts_path).read_text(encoding="utf-8"))["layouts"]
    layouts_by_id = {item["id"]: item for item in layouts}
    maps = {}
    for name, map_id in zip(FLOORS, MAP_IDS):
        data = json.loads((Path(maps_dir) / name / "map.json").read_text(encoding="utf-8"))
        if data.get("id") != map_id:
            raise ValueError(f"{name}: unexpected map ID")
        layout = layouts_by_id[data["layout"]]
        width, height = layout["width"], layout["height"]
        if width <= 0 or height <= 0:
            raise ValueError(f"{name}: invalid dimensions")
        warps = data["warp_events"]
        if not isinstance(warps, list):
            raise ValueError(f"{name}: missing warp events")
        for index, warp in enumerate(warps):
            if not (0 <= warp["x"] < width and 0 <= warp["y"] < height):
                raise ValueError(f"{name} warp {index}: out of bounds")
        maps[map_id] = {"name": name, "width": width, "height": height, "warps": warps}
    links = []
    anomalies = []
    for map_id, data in maps.items():
        for index, warp in enumerate(data["warps"]):
            destination = warp["dest_map"]
            if destination not in maps and destination not in EXTERNAL:
                anomalies.append({"map": map_id, "warp": index, "problem": "unknown destination", "target": destination})
                continue
            record = {"map": map_id, "warp": index, "position": [warp["x"], warp["y"]],
                      "destination": destination, "destination_warp": warp["dest_warp_id"]}
            links.append(record)
            if destination not in maps:
                continue
            try:
                dest_index = int(warp["dest_warp_id"])
            except (ValueError, TypeError):
                anomalies.append({**record, "problem": "non-numeric destination warp"})
                continue
            dest_warps = maps[destination]["warps"]
            if dest_index < 0 or dest_index >= len(dest_warps):
                anomalies.append({**record, "problem": "destination warp index out of range"})
            elif dest_warps[dest_index]["dest_map"] != map_id:
                anomalies.append({**record, "problem": "destination warp does not lead back",
                                  "actual_return": dest_warps[dest_index]["dest_map"]})
    return {"source": "PokemonHnS-Development/pokehns-expansion",
            "source_revision": "167aa6d537b109bb229c231ddce4616974c4da71",
            "floors": [{k: v for k, v in data.items() if k != "warps"} | {"id": key, "warp_count": len(data["warps"])}
                       for key, data in maps.items()],
            "links": links, "anomalies": anomalies,
            "native_compiled": False, "runtime_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--maps-dir", required=True)
    parser.add_argument("--layouts-json", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = audit(args.maps_dir, args.layouts_json)
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Audited {len(result['floors'])} floors, {len(result['links'])} warps; "
          f"{len(result['anomalies'])} anomalies (not auto-corrected)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compile source-indexed PokéBacon links into explicit, reviewable RMXP transfers.

Consumes only the sanitised SE-015 reference and a locally authored mapping.
Never guesses target map IDs, doorways, arrival tiles, facing or collision.
The resulting plan is NOT proof of installed events or a playable game.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

def integer(value, label, minimum=0, maximum=999):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{label} must be an integer in {minimum}..{maximum}")
    return value

def point(endpoint, dimensions, label):
    if not isinstance(endpoint, dict):
        raise ValueError(f"{label} must be an object")
    for axis, limit in (("x", dimensions["width"]), ("y", dimensions["height"]),
                        ("landing_x", dimensions["width"]), ("landing_y", dimensions["height"])):
        integer(endpoint.get(axis), f"{label}.{axis}", 0, limit - 1)
    if type(endpoint.get("direction")) is not int or endpoint["direction"] not in (0, 2, 4, 6, 8):
        raise ValueError(f"{label}.direction must be an RMXP facing (0,2,4,6,8)")
    if type(endpoint.get("fade", 0)) is not int or endpoint.get("fade", 0) not in (0, 1):
        raise ValueError(f"{label}.fade must be 0 or 1")

def build_plan(reference, mapping, require_all=False):
    if reference.get("schema_version") != 1 or not isinstance(reference.get("links"), list):
        raise ValueError("Expected the SE-015 source parity reference")
    if mapping.get("schema_version") != 1:
        raise ValueError("Expected world-link mapping schema version 1")
    raw_maps = reference.get("maps")
    if not isinstance(raw_maps, list):
        raise ValueError("Missing source map inventory")
    source_maps = {}
    for item in raw_maps:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or item["id"] in source_maps:
            raise ValueError("Duplicate or invalid source map ID")
        source_maps[item["id"]] = item
    map_mapping = mapping.get("maps")
    link_mapping = mapping.get("links")
    if not isinstance(map_mapping, dict) or not isinstance(link_mapping, dict):
        raise ValueError("Mapping requires maps and links objects")
    if not link_mapping:
        raise ValueError("No links selected for conversion")
    resolved_maps, seen_targets = {}, set()
    for source_id, item in map_mapping.items():
        if source_id not in source_maps or not isinstance(item, dict):
            raise ValueError(f"Unknown source map {source_id}")
        map_id = integer(item.get("target_map_id"), f"{source_id}.target_map_id", 1)
        width = integer(item.get("width"), f"{source_id}.width", 1)
        height = integer(item.get("height"), f"{source_id}.height", 1)
        if map_id in seen_targets:
            raise ValueError(f"Two source maps map to RMXP map {map_id}; explicit disambiguation required")
        seen_targets.add(map_id)
        resolved_maps[source_id] = {"source_map_id": source_id, "map_id": map_id,
                                    "width": width, "height": height}
    source_links = {}
    for link in reference["links"]:
        if not isinstance(link, dict) or not isinstance(link.get("id"), str) or not link["id"] or link["id"] in source_links:
            raise ValueError("Invalid or duplicate source link ID")
        for side in ("from", "to"):
            endpoint = link.get(side)
            if not isinstance(endpoint, dict) or endpoint.get("mapId") not in source_maps:
                raise ValueError(f"{link['id']}: unknown source {side} map")
            src_map = source_maps[endpoint["mapId"]]
            for axis in ("x", "y"):
                integer(endpoint.get(axis), f"source {link['id']}.{side}.{axis}", 0, src_map["width" if axis == "x" else "height"] - 1)
        if type(link.get("two_way")) is not bool:
            raise ValueError(f"{link['id']}: two_way must be boolean")
        source_links[link["id"]] = link
    if not set(link_mapping).issubset(source_links):
        raise ValueError("Mapping contains unknown source link IDs")
    unmapped = sorted(set(source_links) - set(link_mapping))
    if require_all and unmapped:
        raise ValueError(f"{len(unmapped)} source links remain unmapped")
    events = []
    for link_id in sorted(link_mapping):
        source = source_links[link_id]
        configured = link_mapping[link_id]
        if not isinstance(configured, dict) or set(configured) != {"from", "to"}:
            raise ValueError(f"{link_id}: explicitly map both endpoint coordinates")
        ends = {}
        for side in ("from", "to"):
            source_id = source[side]["mapId"]
            if source_id not in resolved_maps:
                raise ValueError(f"{link_id}: no RMXP map mapping for {source_id}")
            dimensions = resolved_maps[source_id]
            endpoint = configured[side]
            point(endpoint, dimensions, f"{link_id}.{side}")
            ends[side] = {"map": dimensions, "point": endpoint}
        def event(origin, destination, suffix):
            src, dst = ends[origin], ends[destination]
            p, q = src["point"], dst["point"]
            return {"link_id": link_id, "side": suffix,
                    "map_id": src["map"]["map_id"], "x": p["x"], "y": p["y"],
                    "destination": {"map_id": dst["map"]["map_id"],
                                    "x": q["landing_x"], "y": q["landing_y"],
                                    "direction": q["direction"], "fade": q.get("fade", 0)}}
        events.append(event("from", "to", "F"))
        if source["two_way"]:
            events.append(event("to", "from", "R"))
    occupied = set()
    for event in events:
        cell = (event["map_id"], event["x"], event["y"])
        if cell in occupied:
            raise ValueError(f"Multiple transfer triggers occupy {cell}")
        occupied.add(cell)
    for event in events:
        dest = event["destination"]
        if (dest["map_id"], dest["x"], dest["y"]) in occupied:
            raise ValueError(f"{event['link_id']}: arrival is on a transfer trigger (warp loop)")
    return {"format": "shattered-world-links", "format_version": 1,
            "status": "uninstalled_unverified", "maps": sorted(resolved_maps.values(), key=lambda m: m["map_id"]),
            "events": sorted(events, key=lambda e: (e["map_id"], e["y"], e["x"], e["link_id"], e["side"])),
            "mapped_links": len(link_mapping), "unmapped_links": unmapped,
            "source_link_count": len(source_links)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--mapping", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--require-all", action="store_true")
    args = parser.parse_args()
    reference_bytes, mapping_bytes = args.reference.read_bytes(), args.mapping.read_bytes()
    result = build_plan(json.loads(reference_bytes), json.loads(mapping_bytes), args.require_all)
    result["reference_sha256"] = hashlib.sha256(reference_bytes).hexdigest()
    result["mapping_sha256"] = hashlib.sha256(mapping_bytes).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{result['mapped_links']}/{result['source_link_count']} source links mapped, "
          f"{len(result['events'])} explicit RMXP transfers (not installed)")

if __name__ == "__main__":
    main()

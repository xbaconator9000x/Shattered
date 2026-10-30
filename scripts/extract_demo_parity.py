#!/usr/bin/env python3
"""Extract safe, source-grounded event anchors from a local PokéBacon map export.

Never copies game assets, dialogue, event scripts or raw map tiles into its output.
This is an evidence/validation tool, NOT an RPG Maker XP event converter.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

SCENES = {
    "johto_gate_aipom": (r"route 22.*28\.0", r"aipom|shiny in its tail|cracked rocks|locked|\bkey\b"),
    "route22_rattata": (r"route 22.*3\.41", r"rattata"),
    "route22_mankey": (r"route 22.*3\.41", r"mankey"),
    "viridian_entry_escort": (r"viridian city.*3\.1", r"powell|hana|nidoran|who goes there|\bguard\b"),
    "viridian_raid": (r"viridian city.*3\.1", r"beedrill|\braider\b|\bmara\b|\bren\b"),
    "murkrow_rescue": (r"route 22.*28\.5", r"murkrow|\blio\b"),
    "dojo_and_starter": (r"viridian city.*5\.[02]", r"dojo|\bren\b|vulpix|staryu|exeggcute"),
}



def extract_script_ops(script):
    """Return only control/FX identifiers, never original script lines or dialogue."""
    flags_set, flags_cleared, vars_written, audio = set(), set(), set(), set()
    warps = movements = 0
    for line in (script or "").splitlines():
        tokens = line.strip().split()
        if len(tokens) < 2:
            continue
        opcode, operand = tokens[0].lower(), tokens[1].rstrip(",")
        if not re.fullmatch(r"0x[0-9a-fA-F]+|[0-9]+", operand):
            continue
        if opcode == "setflag":
            flags_set.add(operand.upper())
        elif opcode == "clearflag":
            flags_cleared.add(operand.upper())
        elif opcode == "setvar":
            vars_written.add(operand.upper())
        elif opcode in ("playse", "playmoncry", "playbgm"):
            audio.add(f"{opcode}:{operand.upper()}")
        elif opcode == "warp":
            warps += 1
        elif opcode == "applymovement":
            movements += 1
    return {"flags_set": sorted(flags_set), "flags_cleared": sorted(flags_cleared),
            "vars_written": sorted(vars_written), "audio_cues": sorted(audio),
            "warp_commands": warps, "movement_commands": movements}


def require_point(point, map_info, label):
    if not isinstance(point, dict) or not all(isinstance(point.get(k), int) and not isinstance(point[k], bool) for k in ("x", "y")):
        raise ValueError(f"{label}: missing or noninteger x/y")
    if not (0 <= point["x"] < map_info["width"] and 0 <= point["y"] < map_info["height"]):
        raise ValueError(f"{label}: coordinates outside {map_info['name']}")


def extract(data, source_name, source_sha256):
    if data.get("format") != "pokebacon-map-studio" or not isinstance(data.get("maps"), list):
        raise ValueError("Expected PokéBacon map-studio export with maps array")
    maps = {}
    for m in data["maps"]:
        if not isinstance(m.get("id"), str) or not m["id"] or m["id"] in maps:
            raise ValueError("Missing or duplicate source map id")
        if not isinstance(m.get("name"), str) or not all(isinstance(m.get(k), int) and m[k] > 0 for k in ("width", "height")):
            raise ValueError("Invalid map name/dimensions")
        maps[m["id"]] = m

    scene_hits = {scene: [] for scene in SCENES}
    marker_counts = Counter()
    marker_total = 0
    for m in data["maps"]:
        for marker in m.get("markers", []):
            marker_total += 1
            kind = marker.get("kind", "unknown")
            marker_counts[kind] += 1
            native_id = marker.get("nativeId") or marker.get("id")
            if not isinstance(native_id, str) or not native_id:
                raise ValueError(f"{m['name']}: marker without id")
            require_point(marker, m, native_id)
            # Classification uses only visible event titles/text, never raw scripts.
            searchable = f"{marker.get('title', '')} {marker.get('text', '')}".lower()
            rom = marker.get("rom") or {}
            for scene, (map_pattern, event_pattern) in SCENES.items():
                if re.search(map_pattern, m["name"], re.I) and re.search(event_pattern, searchable, re.I):
                    scene_hits[scene].append({
                        "map_id": m["id"], "source_event_id": native_id,
                        "kind": kind, "x": marker["x"], "y": marker["y"],
                        "source_rom_address": rom.get("address") if isinstance(rom.get("address"), int) else None,
                        "script_length": len(rom.get("scriptSource") or ""),
                        "dialogue_entries": len(rom.get("dialogue") or []),
                        "script_ops": extract_script_ops(rom.get("scriptSource")),
                    })

    links = []
    for link in data.get("links", []):
        a, b = link.get("from") or {}, link.get("to") or {}
        if a.get("mapId") not in maps or b.get("mapId") not in maps:
            raise ValueError(f"Unknown map in link {link.get('id')}")
        require_point(a, maps[a["mapId"]], f"link {link.get('id')} from")
        require_point(b, maps[b["mapId"]], f"link {link.get('id')} to")
        links.append({
            "id": link.get("id"), "from": {k: a[k] for k in ("mapId", "x", "y")},
            "to": {k: b[k] for k in ("mapId", "x", "y")},
            "kind": link.get("kind"), "two_way": link.get("twoWay") is True,
        })
    return {
        "schema_version": 1,
        "purpose": "source-only parity anchors; not compiled, installed or runtime verified",
        "source": {"name": Path(source_name).name, "sha256": source_sha256, "format": data["format"]},
        "summary": {"map_count": len(maps), "marker_count": marker_total,
                    "marker_kinds": dict(sorted(marker_counts.items())),
                    "object_count": sum(len(m.get("objects", [])) for m in data["maps"]),
                    "link_count": len(links)},
        "maps": [{"id": m["id"], "name": m["name"], "width": m["width"], "height": m["height"]} for m in data["maps"]],
        "scenes": {k: {"status": "source_reference_only", "essentials_map_id": None,
                       "anchors": sorted(v, key=lambda x: (x["map_id"], x["source_event_id"]))}
                   for k, v in scene_hits.items()},
        "links": links,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Local authorised PokéBacon JSON; never upload to GitHub")
    parser.add_argument("--output", required=True, type=Path, help="Sanitised event metadata JSON")
    args = parser.parse_args()
    raw = args.source.read_bytes()
    data = json.loads(raw)
    result = extract(data, args.source.name, hashlib.sha256(raw).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{result['summary']['map_count']} maps, {result['summary']['marker_count']} markers, "
          f"{result['summary']['link_count']} links; {sum(len(v['anchors']) for v in result['scenes'].values())} scene anchors")


if __name__ == "__main__":
    main()

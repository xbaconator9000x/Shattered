#!/usr/bin/env python3
"""Prepare a private, source-pinned native installer for the initial Shattered slice."""

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

import shattered_integration as integration


INSTALL_ORDER = [
    "pbInstallShatteredHNSReceptionGate",
    "pbInstallShatteredWorldLinks",
    "pbInstallShatteredGateStory",
    "pbInstallShatteredRoute22",
]
HNS_DIRECTIONS = {
    "west": [(1, 9)],
    "east": [(20, 9)],
    "south": [(11, 19)],
    "north": [(10, 1), (11, 1)],
}
HNS_SOURCE_REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
STORY_FLAG_PLAN = "shattered_gate_story_v1"
ROUTE22_UUID = "c4c03051-b9be-4d3c-a06c-bcde09a0e3a2"
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
SAFE_BASENAME = re.compile(r"^[A-Za-z0-9_ -]+$")
# Existing private Essentials projects store species cries in Audio/SE/Cries/.
# Allow only this single literal subdirectory for the Aipom cry.
SAFE_AIPOM_CRY = re.compile(r"^(?:Cries/)?[A-Za-z0-9_ -]+$")
ROOT = Path(__file__).resolve().parents[1]
RUBY_TEMPLATE = ROOT / "scripts" / "templates" / "shattered_initial_slice_installer.rb"


def _fail(condition, message):
    if not condition:
        raise integration.IntegrationError(message)


def _positive_id(value, label):
    _fail(isinstance(value, int) and not isinstance(value, bool) and value > 0,
          f"{label} must be a positive integer")
    return value


def _sha(value, label):
    _fail(isinstance(value, str) and HEX_64.fullmatch(value) is not None,
          f"{label} must be a lowercase SHA256")
    return value


def _pair(value, label):
    _fail(isinstance(value, list) and len(value) == 2 and
          all(isinstance(item, int) and not isinstance(item, bool) and item > 0 for item in value),
          f"{label} must be positive [width, height]")
    return value


def _source_records(manifest, lock, profile):
    selected = set(integration._profile_config(manifest, profile)["source_prs"])
    records = {record["id"]: record for record in lock["pull_requests"]}
    _fail(set(records) == selected, "source lock does not contain the exact initial-slice PR set")
    result = []
    for pr in manifest["pull_requests"]:
        if pr["id"] not in selected:
            continue
        record = records[pr["id"]]
        _fail(record["head"] == pr["head"] and record["base"] == pr["base"],
              f"PR #{pr['id']} source pin differs from the manifest")
        expected_commit = manifest["main"]["commit"] if pr["state"] == "merged" else pr["head"]
        _fail(record.get("source_commit") == expected_commit,
              f"PR #{pr['id']} resolved source commit is stale")
        result.append({
            "id": pr["id"],
            "state": pr["state"],
            "branch": pr["branch"],
            "head": pr["head"],
            "base": pr["base"],
            "source_ref": record["source_ref"],
            "source_commit": expected_commit,
        })
    return result


def _validate_hns(config, target_id, existing_ids, manifest):
    _fail(isinstance(config, dict) and config.get("format") == "shattered-hns-rmxp-map" and
          config.get("format_version") == 1, "invalid HnS reception-gate import config")
    source = config.get("source")
    source_spec = next(item for item in manifest["source_projects"] if item["id"] == "hns_reception_gate")
    _fail(isinstance(source, dict) and
          source.get("repository") == "https://github.com/" + source_spec["repository"] and
          source.get("revision") == HNS_SOURCE_REVISION,
          "HnS config source revision differs from the pinned converter")
    for source_record in source_spec["source_files"][:3]:
        hash_field, path_field = (
            ("map_sha256", "map_path") if source_record["path"].endswith("map.json")
            else ("layout_sha256", "layout_path") if source_record["path"].endswith("layouts.json")
            else ("blockdata_sha256", "blockdata_path")
        )
        _fail(source.get(hash_field) == source_record["sha256"] and
              source.get(path_field) == source_record["path"],
              f"HnS converted source hash differs from the pinned source: {source_record['path']}")
    dimensions = config.get("dimensions", {})
    _fail(dimensions == {"width": 22, "height": 21, "tile_pixels": 32},
          "HnS converted map must be the pinned 22x21 source")
    target = config.get("target", {})
    _fail(isinstance(target, dict), "HnS target must be an object")
    _fail(target.get("map_id") == target_id, "HnS target map ID differs from the reviewed gate ID")
    _positive_id(target.get("tileset_template_id"), "HnS tileset template ID")
    _fail(isinstance(target.get("tileset_name"), str) and
          re.fullmatch(r"[A-Za-z0-9_-]+", target["tileset_name"]) is not None and
          target.get("tileset_image") == target["tileset_name"] + ".png",
          "HnS tileset image/name mismatch")
    _fail(isinstance(config.get("layers"), list) and len(config["layers"]) == 3 and
          all(isinstance(layer, list) and len(layer) == 22 * 21 for layer in config["layers"]),
          "HnS map must provide three complete layers")
    warps = config.get("warps")
    _fail(isinstance(warps, list) and len(warps) == 5, "HnS config must contain five warps")
    grouped = {direction: [] for direction in HNS_DIRECTIONS}
    for warp in warps:
        _fail(isinstance(warp, dict), "HnS config contains a malformed warp")
        direction = warp.get("direction")
        _fail(direction in grouped, "HnS config contains an unknown warp direction")
        grouped[direction].append((warp.get("x"), warp.get("y")))
        destination = warp.get("target", {})
        _fail(isinstance(destination, dict), "HnS warp destination must be an object")
        dest_id = _positive_id(destination.get("map_id"), "HnS warp destination map ID")
        _fail(dest_id in existing_ids, f"HnS warp destination map {dest_id} is not reviewed")
    _fail(grouped == HNS_DIRECTIONS, "HnS warp positions differ from the pinned source")


def _validate_world_links(config, gate_id, route_id):
    _fail(isinstance(config, dict) and config.get("format") == "shattered-world-links" and
          config.get("format_version") == 1, "invalid world-links config")
    expected = {gate_id: [22, 21], route_id: [48, 24]}
    maps = config.get("maps")
    _fail(isinstance(maps, list) and len(maps) == 2 and
          all(isinstance(item, dict) for item in maps) and
          {item.get("map_id"): [item.get("width"), item.get("height")] for item in maps} == expected,
          "world-links must target exactly the reviewed gate and Route22 maps")
    events = config.get("events")
    _fail(isinstance(events, list) and len(events) >= 2,
          "world-links config must contain the reviewed gate/Route22 transfers")
    positions, landings, names, map_ids = set(), set(), set(), set()
    for event in events:
        _fail(isinstance(event, dict), "world-link event must be an object")
        map_id = _positive_id(event.get("map_id"), "world-link map ID")
        _fail(map_id in expected, "world-link source is outside the initial slice")
        map_ids.add(map_id)
        name = event.get("link_id")
        _fail(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+", name) is not None and
              event.get("side") in ("F", "R"), "invalid world-link identity")
        names.add((name, event["side"]))
        width, height = expected[map_id]
        _fail(isinstance(event.get("x"), int) and not isinstance(event.get("x"), bool) and
              0 <= event["x"] < width and isinstance(event.get("y"), int) and
              not isinstance(event.get("y"), bool) and 0 <= event["y"] < height,
              "world-link event coordinate is outside its target map")
        key = (map_id, event.get("x"), event.get("y"))
        _fail(key not in positions, "duplicate world-link event coordinate")
        positions.add(key)
        destination = event.get("destination", {})
        _fail(isinstance(destination, dict) and destination.get("map_id") in expected,
              "world-link destination is outside the initial slice")
        dest_width, dest_height = expected[destination["map_id"]]
        _fail(isinstance(destination.get("x"), int) and not isinstance(destination.get("x"), bool) and
              0 <= destination["x"] < dest_width and
              isinstance(destination.get("y"), int) and not isinstance(destination.get("y"), bool) and
              0 <= destination["y"] < dest_height and
              destination.get("direction") in (0, 2, 4, 6, 8) and
              destination.get("fade") in (0, 1),
              "invalid world-link arrival coordinate, facing, or fade")
        landings.add((destination["map_id"], destination["x"], destination["y"]))
    _fail(map_ids == {gate_id, route_id}, "world-links must write both initial-slice maps")
    _fail(len(names) == len(events), "duplicate world-link event name")
    gate_warps = {(x, y) for points in HNS_DIRECTIONS.values() for x, y in points}
    _fail(not any(map_id == gate_id and (x, y) in gate_warps
                  for map_id, x, y in positions),
          "world-link event overlaps an HnS source warp")
    _fail(not any(map_id == gate_id and (x, y) in gate_warps
                  for map_id, x, y in landings),
          "world-link arrival overlaps an HnS exit")
    return positions, landings


def _validate_story(config, gate_id, hns_config, links_positions, links_landings):
    _fail(isinstance(config, dict) and config.get("schema_version") == 1 and
          config.get("flag_plan") == STORY_FLAG_PLAN and config.get("map_id") == gate_id,
          "invalid Gate Story config or map ID")
    positions = config.get("positions")
    _fail(isinstance(positions, dict) and
          set(positions) == {"collapse", "aipom", "johto_block"},
          "Gate Story requires three reviewed event positions")
    normalized, unique = {}, set()
    for label, point in positions.items():
        _fail(isinstance(point, dict), f"invalid Gate Story position: {label}")
        x, y = point.get("x"), point.get("y")
        _fail(isinstance(x, int) and not isinstance(x, bool) and 0 <= x < 22 and
              isinstance(y, int) and not isinstance(y, bool) and 0 <= y < 21,
              f"invalid Gate Story position: {label}")
        _fail((x, y) not in unique, "duplicate Gate Story event position")
        unique.add((x, y))
        normalized[label] = (x, y)
    _fail(normalized["johto_block"] == HNS_DIRECTIONS["south"][0],
          "Gate Story blocker must occupy the pinned HnS south exit")
    gate_warps = {(x, y) for points in HNS_DIRECTIONS.values() for x, y in points}
    _fail(not any(normalized[label] in gate_warps for label in ("collapse", "aipom")),
          "Gate Story event overlaps an HnS exit")
    _fail(not links_positions.intersection((gate_id, *point) for label, point in normalized.items()
                                           if label != "johto_block"),
          "Gate Story position overlaps a world-link event")
    _fail(not links_landings.intersection((gate_id, *normalized[label])
                                          for label in ("collapse", "aipom")),
          "Gate Story event overlaps a world-link arrival")
    south = next(warp for warp in hns_config["warps"] if warp["direction"] == "south")
    target = south["target"]
    expected_transfer = [0, target["map_id"], target["x"], target["y"],
                         target["direction"], target["fade"]]
    _fail(config.get("expected_south_transfer") == expected_transfer,
          "Gate Story south transfer differs from the converted HnS transfer")
    _fail(isinstance(config.get("collapse_sounds"), list) and len(config["collapse_sounds"]) == 6,
          "Gate Story requires six collapse sound basenames")
    for key in ("collapse_sounds",):
        _fail(all(isinstance(name, str) and SAFE_BASENAME.fullmatch(name) for name in config[key]),
              f"unsafe Gate Story asset basename: {key}")
    for key in ("final_roar_sound", "aipom_character"):
        _fail(isinstance(config.get(key), str) and SAFE_BASENAME.fullmatch(config[key]),
              f"unsafe Gate Story asset basename: {key}")
    _fail(isinstance(config.get("aipom_cry"), str) and
          SAFE_AIPOM_CRY.fullmatch(config["aipom_cry"]),
          "unsafe Gate Story Aipom cry path")


def _validate_route22(config, route_target, switch_ids, variable_ids):
    _fail(isinstance(config, dict) and config.get("schema_version") == 1 and
          config.get("source_map_uuid") == ROUTE22_UUID,
          "invalid Route22 config or source map UUID")
    _fail(config.get("map_id") == route_target["id"], "Route22 target map ID mismatch")
    _fail(config.get("expected_map_sha256") == route_target["sha256"],
          "Route22 reviewed base map hash differs from the staged map")
    _fail(config.get("scatter_switch") == switch_ids["route22_scatter"] and
          config.get("cleared_switch") == switch_ids["route22_cleared"] and
          config.get("outcome_variable") == variable_ids["route22_outcome"],
          "Route22 config resource IDs differ from reviewed allocations")
    _fail(isinstance(config.get("rattata_character"), str) and
          SAFE_BASENAME.fullmatch(config["rattata_character"]),
          "invalid Route22 character basename")


def _route22_reserved_positions(manifest):
    component = next(item for item in manifest["components"] if item["id"] == "route22")
    contract = next(item for item in component["event_contracts"]
                    if item.get("api") == "pbInstallShatteredRoute22")
    trigger_positions = contract.get("source_trigger_positions")
    npc_positions = contract.get("source_npc_positions")
    _fail(isinstance(trigger_positions, list) and len(trigger_positions) == 3 and
          isinstance(npc_positions, list) and len(npc_positions) == 3,
          "Route22 trigger/NPC positions are missing from the source contract")
    positions = trigger_positions + npc_positions
    _fail(all(isinstance(point, list) and len(point) == 2 and
              all(isinstance(value, int) and not isinstance(value, bool) for value in point)
              for point in positions) and len({tuple(point) for point in positions}) == 6,
          "Route22 trigger/NPC positions are invalid or duplicated")
    return positions


def _asset_paths(configs, assets, build_report, project):
    hashes = build_report.get("assets_sha256", {})
    gate = configs["gate_story"]
    route = configs["route22"]
    named = {
        "hns_reception_gate_tileset": (
            Path("Graphics/Tilesets") / configs["hns_import"]["target"]["tileset_image"]
        ),
        "aipom_sprite": Path("Graphics/Characters") / f"{gate['aipom_character']}.png",
        "aipom_cry": None,
        "gate_final_roar": None,
        "route22_rattata_sprite": Path("Graphics/Characters") / f"{route['rattata_character']}.png",
    }
    for index, name in enumerate(gate["collapse_sounds"], 1):
        named[f"gate_collapse_se_{index}"] = None
    named["aipom_cry"] = None
    named["gate_final_roar"] = None
    sound_names = {
        "aipom_cry": gate["aipom_cry"],
        "gate_final_roar": gate["final_roar_sound"],
    }
    sound_names.update({
        f"gate_collapse_se_{index}": name
        for index, name in enumerate(gate["collapse_sounds"], 1)
    })
    result = {}
    for asset_id, expected in named.items():
        _fail(asset_id in hashes, f"staging report is missing asset provenance: {asset_id}")
        if expected is not None:
            candidates = [expected]
        else:
            candidates = sorted((project / "Audio/SE").glob(sound_names[asset_id] + ".*"))
            candidates = [path.relative_to(project) for path in candidates if path.is_file()]
        _fail(len(candidates) == 1, f"missing or ambiguous staged asset for {asset_id}")
        relative = candidates[0].as_posix()
        path = integration.regular_file(project, relative, f"native asset {asset_id}")
        digest = integration.sha256(path)
        _fail(digest == hashes[asset_id], f"staged asset hash differs from provenance: {asset_id}")
        if asset_id == "hns_reception_gate_tileset":
            header = path.read_bytes()[:24]
            _fail(len(header) == 24 and header[:8] == b"\x89PNG\r\n\x1a\n" and
                  header[12:16] == b"IHDR" and
                  int.from_bytes(header[16:20], "big") == 256 and
                  int.from_bytes(header[20:24], "big") > 0 and
                  int.from_bytes(header[20:24], "big") % 32 == 0,
                  "HnS tileset must be a valid 256px-wide XP PNG")
        result[asset_id] = {"path": relative, "sha256": digest}
    return result


def prepare_native_handoff(project, source_root, plan, manifest, synthetic_fixture=False):
    integration.validate_manifest(manifest)
    profile = "initial_slice"
    project = Path(project).resolve()
    _fail(project.is_dir(), "staged project directory is missing")
    _fail((project / "SHATTERED_STAGING_REPORT.json").is_file(),
          "native handoff requires an integration-staged copy")
    try:
        build_report = json.loads((project / "SHATTERED_INTEGRATION_BUILD.json").read_text())
        staging_report = json.loads((project / "SHATTERED_STAGING_REPORT.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise integration.IntegrationError(f"invalid staged build provenance: {exc}") from exc
    _fail(build_report.get("profile") == profile and staging_report.get("profile") == profile,
          "native handoff only accepts the initial_slice staged profile")
    _fail(staging_report.get("engine") == "Essentials 21.1",
          "staged project marker does not identify Essentials v21.1")
    lock = integration.verify_source_bundle(
        source_root, manifest, synthetic_fixture=synthetic_fixture, profile=profile
    )
    pins = _source_records(manifest, lock, profile)
    expected_report_pins = [
        {
            "id": item["id"],
            "branch": item["branch"],
            "commit": item["head"],
            "base": item["base"],
            "state": item["state"],
            "source_ref": item["source_ref"],
            "source_commit": item["source_commit"],
        }
        for item in pins
    ]
    _fail(build_report.get("source_prs") == expected_report_pins,
          "staged build report source pins differ from the verified source lock")
    _fail(staging_report.get("source_prs") == build_report.get("source_prs"),
          "staging marker and build report source pins differ")

    _fail(isinstance(plan, dict) and plan.get("schema_version") == 1 and
          plan.get("profile") == profile, "unsupported native handoff plan")
    targets = plan.get("map_targets", {})
    _fail(set(targets) == {"reception_gate", "route22"},
          "native handoff plan needs reviewed reception_gate and route22 targets")
    gate_target, route_target = targets["reception_gate"], targets["route22"]
    gate_id = _positive_id(gate_target.get("id"), "reception gate map ID")
    route_id = _positive_id(route_target.get("id"), "Route22 map ID")
    _fail(gate_id != route_id, "reception gate and Route22 map IDs must differ")
    _fail(gate_target.get("reviewed") is True and gate_target.get("map_info_reviewed") is True,
          "reception gate map ID/MapInfos allocation is not reviewed")
    _fail(gate_target.get("source_uuid") == manifest["target_map_slots"]["reception_gate"]["source_uuid"],
          "reception gate source UUID differs from the pinned source")
    _fail(route_target.get("reviewed") is True and route_target.get("map_info_reviewed") is True and
          route_target.get("source_uuid") == ROUTE22_UUID,
          "Route22 map identity/MapInfos allocation is not reviewed")
    gate_path = project / f"Data/Map{gate_id:03d}.rxdata"
    _fail(not gate_path.exists() and not gate_path.is_symlink(),
          "reception gate map target is occupied; the HnS importer must create it")
    route_path = integration.regular_file(
        project, f"Data/Map{route_id:03d}.rxdata", "Route22 target map"
    )
    route_hash = _sha(route_target.get("sha256"), "Route22 target map hash")
    _fail(integration.sha256(route_path) == route_hash,
          "Route22 target map SHA256 differs from the reviewed handoff plan")
    _fail(route_target.get("dimensions") == [48, 24],
          "Route22 target map must match the pinned 48x24 dimensions")

    expected_slots = {
        key: value for key, value in build_report["map_targets"].items()
        if key in ("reception_gate", "route22")
    }
    _fail(expected_slots.get("reception_gate", {}).get("id") == gate_id and
          expected_slots.get("reception_gate", {}).get("created_by_installer") is True and
          expected_slots.get("route22", {}).get("id") == route_id and
          expected_slots.get("route22", {}).get("sha256") == route_hash,
          "reviewed target maps differ from the staged build plan")

    switch_ids = plan.get("switch_ids", {})
    variable_ids = plan.get("variable_ids", {})
    profile_config = integration._profile_config(manifest, profile)
    _fail(set(switch_ids) == set(profile_config["switch_ids"]) and
          set(variable_ids) == set(profile_config["variable_ids"]),
          "handoff plan must allocate every initial-slice switch and variable")
    all_resource_ids = list(switch_ids.values()) + list(variable_ids.values())
    _fail(all(isinstance(value, int) and not isinstance(value, bool) and value > 0
              for value in all_resource_ids) and
          len(switch_ids.values()) == len(set(switch_ids.values())) and
          len(variable_ids.values()) == len(set(variable_ids.values())),
          "handoff plan contains duplicate or invalid switch/variable IDs")
    _fail(switch_ids == build_report.get("switch_ids") and
          variable_ids == build_report.get("variable_ids"),
          "handoff resource IDs differ from the staged build plan")

    required_existing = plan.get("required_existing_maps")
    _fail(isinstance(required_existing, list), "reviewed existing HnS warp destinations are required")
    existing_by_id = {}
    for target in required_existing:
        _fail(isinstance(target, dict), "existing destination map record must be an object")
        map_id = _positive_id(target.get("id"), "existing destination map ID")
        _fail(map_id not in existing_by_id and map_id != gate_id,
              "duplicate or newly-created map listed as an existing destination")
        _fail(target.get("reviewed") is True and target.get("map_info_reviewed") is True,
              f"existing destination map {map_id} is not reviewed")
        dimensions = _pair(target.get("dimensions"), f"map {map_id} dimensions")
        digest = _sha(target.get("sha256"), f"map {map_id} hash")
        path = integration.regular_file(project, f"Data/Map{map_id:03d}.rxdata",
                                        f"HnS warp destination map {map_id}")
        _fail(integration.sha256(path) == digest, f"HnS warp destination map hash mismatch: {map_id}")
        existing_by_id[map_id] = {"id": map_id, "dimensions": dimensions, "sha256": digest}
    _fail(route_id in existing_by_id and existing_by_id[route_id]["sha256"] == route_hash,
          "Route22 must be a reviewed existing HnS warp destination")

    configs = plan.get("installer_configs", {})
    _fail(set(configs) == {"hns_import", "world_links", "gate_story", "route22"},
          "all four native installer configurations are required")
    _validate_hns(configs["hns_import"], gate_id, set(existing_by_id), manifest)
    links_positions, links_landings = _validate_world_links(
        configs["world_links"], gate_id, route_id
    )
    _validate_story(
        configs["gate_story"], gate_id, configs["hns_import"],
        links_positions, links_landings,
    )
    _validate_route22(configs["route22"], route_target, switch_ids, variable_ids)
    route22_reserved = _route22_reserved_positions(manifest)
    for event in configs["world_links"]["events"]:
        if event["map_id"] == route_id:
            _fail([event["x"], event["y"]] not in route22_reserved,
                  "World-link event overlaps a reserved Route22 event coordinate")
        destination = event["destination"]
        if destination["map_id"] == route_id:
            _fail([destination["x"], destination["y"]] not in route22_reserved,
                  "World-link arrival overlaps a reserved Route22 event coordinate")
    hns_destinations = {warp["target"]["map_id"] for warp in configs["hns_import"]["warps"]}
    _fail(hns_destinations == set(existing_by_id),
          "reviewed existing map inventory must exactly cover all HnS warp destinations")
    for warp in configs["hns_import"]["warps"]:
        destination = warp["target"]
        width, height = existing_by_id[destination["map_id"]]["dimensions"]
        _fail(destination["x"] < width and destination["y"] < height,
              f"HnS warp destination coordinate is outside map {destination['map_id']}")
    _fail(configs["world_links"]["maps"] == [
        {"map_id": gate_id, "width": 22, "height": 21},
        {"map_id": route_id, "width": 48, "height": 24},
    ] or {
        item["map_id"]: [item["width"], item["height"]]
        for item in configs["world_links"]["maps"]
    } == {gate_id: [22, 21], route_id: [48, 24]},
        "world-link target map dimensions are inconsistent")
    for event in configs["world_links"]["events"]:
        destination = event["destination"]
        destination_id = destination["map_id"]
        _fail(destination_id in (gate_id, route_id),
              "world-link destination is outside the initial slice")

    # New Game must not silently retain the prototype's old Crystal-gate spawn.
    # Coordinates are reviewed private input, never inferred from a screenshot or a warp.
    spawn = plan.get("new_game_spawn")
    _fail(isinstance(spawn, dict) and set(spawn) == {
        "map_id", "x", "y", "reviewed", "passability_attested", "system_sha256"
    }, "reviewed New Game spawn contract is required")
    _fail(spawn["reviewed"] is True and spawn["passability_attested"] is True,
          "New Game spawn and passability must be explicitly reviewed")
    _fail(spawn["map_id"] == gate_id and type(spawn["map_id"]) is int,
          "New Game must start at the reviewed HnS gate map ID")
    _fail(all(type(spawn[axis]) is int and 0 <= spawn[axis] < limit
              for axis, limit in (("x", 22), ("y", 21))),
          "New Game spawn is outside the HnS reception gate")
    spawn_xy = (spawn["x"], spawn["y"])
    _fail(spawn_xy not in {tuple(p) for positions in HNS_DIRECTIONS.values() for p in positions},
          "New Game spawn overlaps an HnS exit")
    _fail(spawn_xy not in {(e["x"], e["y"]) for e in configs["world_links"]["events"]
                           if e["map_id"] == gate_id},
          "New Game spawn overlaps a world-link event")
    _fail(spawn_xy not in {(p["x"], p["y"])
                           for p in configs["gate_story"]["positions"].values()},
          "New Game spawn overlaps a Gate Story event")
    _fail(spawn_xy not in {(e["destination"]["x"], e["destination"]["y"])
                           for e in configs["world_links"]["events"]
                           if e["destination"]["map_id"] == gate_id},
          "New Game spawn overlaps a world-link landing")
    system_path = integration.regular_file(project, "Data/System.rxdata",
                                           "original native New Game system data")
    _fail(integration.sha256(system_path) == _sha(spawn["system_sha256"], "System baseline"),
          "reviewed New Game System.rxdata hash differs from staged baseline")

    assets = _asset_paths(configs, plan, build_report, project)
    for path in ("PBS/items.txt", "PBS/pokemon.txt", "Data/MapInfos.rxdata", "Data/Tilesets.rxdata", "Data/System.rxdata"):
        integration.regular_file(project, path, f"native handoff prerequisite {path}")
    _fail("[SHATTEREDGATEKEY]" in (project / "PBS/items.txt").read_text(encoding="utf-8-sig"),
          "compiled-input PBS items file is missing [SHATTEREDGATEKEY]")
    pokemon_text = (project / "PBS/pokemon.txt").read_text(encoding="utf-8-sig")
    _fail("[HUMAN]" in pokemon_text and "[RATTATA]" in pokemon_text,
          "compiled-input PBS species file must contain [HUMAN] and [RATTATA]")

    source_files = {}
    for item in manifest["required_source_files"]:
        if item["pr"] not in profile_config["source_prs"] or not item.get("stage"):
            continue
        bundle_rel = f"pr-{item['pr']}/{item['path']}"
        digest = lock["files"][f"{item['pr']}:{item['path']}"]
        staged_rel = Path("Plugins") / Path(*Path(item["path"]).parts[2:])
        staged_path = integration.regular_file(project, staged_rel.as_posix(),
                                               f"staged PR #{item['pr']} plugin source")
        _fail(integration.sha256(staged_path) == digest,
              f"staged plugin file differs from its pinned source: {staged_rel.as_posix()}")
        source_files[staged_rel.as_posix()] = digest

    installer_root = Path("Plugins/Shattered Initial Slice Installer")
    hns_config_path = Path("Plugins/Shattered HnS Gate/reception_gate.json")
    config_paths = {
        "hns_import": hns_config_path.as_posix(),
        "world_links": (installer_root / "world_links.json").as_posix(),
        "gate_story": (installer_root / "gate_story.json").as_posix(),
        "route22": (installer_root / "route22.json").as_posix(),
    }
    installer_meta = "Name = Shattered Initial Slice Installer\nVersion = 0.1.0\n"
    outputs = {path: copy.deepcopy(configs[key]) for key, path in config_paths.items()}
    outputs[(installer_root / "meta.txt").as_posix()] = installer_meta

    handoff = {
        "schema_version": 1,
        "profile": profile,
        "status": "native_install_pending",
        "evidence_tier": "synthetic-fixture" if synthetic_fixture else "staged-copy-only",
        "runtime_acceptance_status": "BLOCKED until native installer, gameplay and save/reload are verified",
        "source_pins": pins,
        "source_file_hashes": {
            f"{item['pr']}:{item['path']}": lock["files"][f"{item['pr']}:{item['path']}"]
            for item in manifest["required_source_files"] if item["pr"] in profile_config["source_prs"]
        },
        "installer_apis": INSTALL_ORDER,
        "plugin_load_order": build_report.get("declared_plugin_load_order", []) +
            ["Shattered Initial Slice Installer"],
        "plugin_load_order_engine_verified": False,
        "config_paths": config_paths,
        "config_hashes": {},
        "runtime_files": {**source_files},
        "asset_files": assets,
        "new_game_spawn": {k: spawn[k] for k in ("map_id", "x", "y", "reviewed", "passability_attested")},
        "map_targets": {
            "reception_gate": {"id": gate_id, "dimensions": [22, 21], "created_by_installer": True},
            "route22": {
                "id": route_id, "dimensions": [48, 24], "source_uuid": ROUTE22_UUID,
                "sha256": route_hash,
            },
        },
        "required_existing_maps": list(existing_by_id.values()),
        "resource_ids": {"switches": switch_ids, "variables": variable_ids},
        "route22_reserved_positions": route22_reserved,
        "baseline_hashes": {
            "Data/System.rxdata": integration.sha256(project / "Data/System.rxdata"),
            "Data/MapInfos.rxdata": integration.sha256(project / "Data/MapInfos.rxdata"),
            "Data/Tilesets.rxdata": integration.sha256(project / "Data/Tilesets.rxdata"),
            f"Data/Map{route_id:03d}.rxdata": route_hash,
        },
        "compatibility_adapters": ["temporary HnS Array to Gate Story Hash tileset view; bytes restored"],
        "installer_template_sha256": hashlib.sha256(
            RUBY_TEMPLATE.read_bytes()
        ).hexdigest(),
        "rights_records_sha256": build_report.get("rights_records_sha256", {}),
        "source_project_rights_sha256": build_report.get("source_project_rights_sha256", {}),
        "asset_hashes": build_report.get("assets_sha256", {}),
        "gameplay_verified": False,
        "save_reload_verified": False,
        "android_joiplay_verified": False,
        "open_runtime_gates": [
            "PBS compilation, plugin script compilation, and game boot in native Essentials v21.1",
            "Route22 event trigger semantics require native RMXP confirmation",
            "New Game spawn tile and collision require native validation, then HUMAN battle, gate/Aipom/Route22 and save/reload",
            "Android JoiPlay/NaviaXP playthrough",
        ],
    }
    for key, path in config_paths.items():
        encoded = (json.dumps(configs[key], sort_keys=True, separators=(",", ":")) + "\n").encode()
        handoff["config_hashes"][path] = hashlib.sha256(encoded).hexdigest()
        outputs[path] = encoded
    for path in ("PBS/items.txt", "PBS/pokemon.txt"):
        handoff["runtime_files"][path] = integration.sha256(project / path)
    meta_path = (installer_root / "meta.txt").as_posix()
    handoff["runtime_files"][meta_path] = hashlib.sha256(
        installer_meta.encode("utf-8")
    ).hexdigest()

    template = integration.regular_file(
        ROOT, "scripts/templates/shattered_initial_slice_installer.rb", "native installer template"
    ).read_text(encoding="utf-8")
    runner = template.replace("__PLAN_SHA256__", "__PLAN_SHA256__")
    outputs[(installer_root / "001_Install.rb").as_posix()] = runner

    pending = copy.deepcopy(handoff)
    pending.pop("config_hashes", None)
    pending["installer_entrypoint"] = "pbInstallShatteredInitialSlice"
    pending["installer_plan_path"] = "Plugins/Shattered Initial Slice Installer/initial_slice_plan.json"
    pending["native_command"] = "pbInstallShatteredInitialSlice"
    handoff["plan_path"] = pending["installer_plan_path"]
    handoff["installer_entrypoint"] = pending["installer_entrypoint"]
    handoff["native_command"] = pending["native_command"]
    handoff["config_hashes"] = dict(sorted(handoff["config_hashes"].items()))

    # Build the plan payload before embedding its digest in the executable runner.
    plan_bytes = (json.dumps(handoff, indent=2, sort_keys=True) + "\n").encode()
    plan_digest = hashlib.sha256(plan_bytes).hexdigest()
    outputs[(installer_root / "001_Install.rb").as_posix()] = template.replace(
        "__PLAN_SHA256__", plan_digest
    ).replace("__TEMPLATE_SHA256__", handoff["installer_template_sha256"])
    outputs[(installer_root / "initial_slice_plan.json").as_posix()] = plan_bytes

    for path in outputs:
        destination = project / integration.safe_relative(path, "native handoff output")
        _fail(not destination.exists() and not destination.is_symlink(),
              f"refusing to overwrite staged handoff file: {path}")
    _fail(not (project / installer_root).exists(),
          "native installer plugin directory already exists; refusing a partial/duplicate handoff")
    existing_plugins = integration._project_plugins(project)
    _fail("Shattered Initial Slice Installer" not in existing_plugins,
          "duplicate Shattered Initial Slice Installer plugin name")

    temp = Path(tempfile.mkdtemp(prefix=".shattered-native-handoff-", dir=project))
    installed = []
    original_reports = {
        project / name: (project / name).read_bytes()
        for name in ("SHATTERED_INTEGRATION_BUILD.json", "SHATTERED_STAGING_REPORT.json")
    }
    try:
        for relative, content in outputs.items():
            path = temp / integration.safe_relative(relative, "native handoff output")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        for relative in outputs:
            destination = project / integration.safe_relative(relative, "native handoff output")
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.replace(temp / integration.safe_relative(relative, "native handoff output"), destination)
            installed.append(destination)
        build_report["native_install"] = {
            "status": "native_install_pending",
            "plan_sha256": plan_digest,
            "entrypoint": "pbInstallShatteredInitialSlice",
            "plan_path": pending["installer_plan_path"],
            "native_context_required": True,
            "gameplay_verified": False,
            "save_reload_verified": False,
            "android_joiplay_verified": False,
        }
        staging_report["native_install_status"] = "native_install_pending"
        staging_report["native_install_plan_sha256"] = plan_digest
        for relative, data in (
            ("SHATTERED_INTEGRATION_BUILD.json", build_report),
            ("SHATTERED_STAGING_REPORT.json", staging_report),
        ):
            target = project / relative
            temp_report = temp / relative
            temp_report.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            os.replace(temp_report, target)
            installed.append(target)
    except Exception:
        for path in reversed(installed):
            if path in original_reports:
                path.write_bytes(original_reports[path])
            else:
                path.unlink(missing_ok=True)
        raise
    finally:
        shutil.rmtree(temp, ignore_errors=True)
    return {
        "status": "native_install_pending",
        "plan_sha256": plan_digest,
        "installer_entrypoint": "pbInstallShatteredInitialSlice",
        "installer_plan_path": pending["installer_plan_path"],
        "evidence_tier": handoff["evidence_tier"],
        "native_execution_verified": False,
        "gameplay_verified": False,
        "save_reload_verified": False,
        "android_joiplay_verified": False,
    }

#!/usr/bin/env python3
"""Report exact local inputs and implementation gates for private native assembly.

The report contains paths and hashes only, never copies ROMs, project files,
tilesets, screenshots, or other private assets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import os

from build_private_native_candidate import (
    BASE_REQUIRED_FILES,
    validate_base_rights,
)

HNS_FILES = (
    "data/maps/ReceptionGate_hns/map.json",
    "data/layouts/layouts.json",
    "data/layouts/ReceptionGate_hns/map.bin",
    "data/maps/VictoryRoadKanto_1F_hns/map.json",
    "data/layouts/VictoryRoadKanto_1F_hns/map.bin",
    "data/maps/VictoryRoadKanto_B1F_hns/map.json",
    "data/layouts/VictoryRoadKanto_B1F_hns/map.bin",
    "data/maps/VictoryRoadKanto_B2F_hns/map.json",
    "data/layouts/VictoryRoadKanto_B2F_hns/map.bin",
)


def _file_record(value):
    if not value:
        return {"status": "missing", "reason": "path not supplied"}
    path = Path(value).absolute()
    if path.is_symlink() or not path.is_file():
        return {"status": "missing", "reason": "not a regular local file"}
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "status": "present",
        "name": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": digest.hexdigest(),
    }


def _rights_record(value, expected_id, expected_type, source_path):
    result = _file_record(value)
    if result["status"] != "present":
        return result
    try:
        record = json.loads(Path(value).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {"status": "invalid", "reason": "rights record is not valid JSON"}
    source = _file_record(source_path)
    if source["status"] != "present":
        return {"status": "blocked", "reason": "authorized source file is missing"}
    if not isinstance(record, dict):
        return {"status": "invalid", "reason": "rights record must be a JSON object"}
    expected_sha = record.get("archive_sha256", record.get("source_sha256"))
    if not isinstance(record, dict) or record.get("id") != expected_id or \
       record.get("type") != expected_type or record.get("rights_cleared") is not True or \
       not all(isinstance(record.get(key), str) and record[key].strip()
               for key in ("source", "license", "basis")):
        return {"status": "invalid", "reason": "rights record lacks required authorization fields"}
    if expected_sha != source["sha256"]:
        return {"status": "invalid", "reason": "rights-record SHA256 does not match local source"}
    return {"status": "verified", "sha256": result["sha256"]}


def _project_status(project):
    if not project:
        return {"status": "missing", "missing_files": list(BASE_REQUIRED_FILES)}
    root = Path(project).absolute()
    if root.is_symlink() or not root.is_dir():
        return {"status": "missing", "reason": "project path is not a regular directory"}
    missing = []
    for relative in BASE_REQUIRED_FILES:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            missing.append(relative)
    return {
        "status": "present" if not missing else "incomplete",
        "missing_files": missing,
    }


def diagnose(*, project=None, base_archive=None, base_rights=None,
             source_rom=None, rom_rights=None, hns_source=None,
             gate_mapping=None, road_mapping=None, gate_tileset=None,
             road_tilesets=None, route22_source=None, viridian_source=None,
             native_engine=None):
    project_status = _project_status(project)
    if base_archive:
        if not base_rights:
            base_status = {
                "status": "invalid",
                "reason": "a SHA-pinned local rights record is required",
            }
        else:
            try:
                base_status = {
                    "status": "verified",
                    **validate_base_rights(base_archive, base_rights),
                }
            except (OSError, TypeError, ValueError) as error:
                base_status = {"status": "invalid", "reason": str(error)}
    else:
        base_status = project_status

    rom_status = _file_record(source_rom)
    rom_rights_status = _rights_record(
        rom_rights, "source_rom", "gba_rom", source_rom
    )
    hns_root = Path(hns_source).absolute() if hns_source else None
    missing_hns = [
        name for name in HNS_FILES
        if hns_root is None or hns_root.is_symlink() or (hns_root / name).is_symlink() or
        not (hns_root / name).is_file()
    ]
    hns_status = {
        "status": "present_unverified" if not missing_hns else "incomplete",
        "missing_files": missing_hns,
        "note": "The pinned converters must still verify source hashes and reviewed mappings.",
    }

    file_inputs = {
        "gate_mapping": gate_mapping,
        "road_mapping": road_mapping,
        "gate_tileset": gate_tileset,
        "route22_source": route22_source,
        "viridian_source": viridian_source,
        "native_engine": native_engine,
    }
    checked = {name: _file_record(path) for name, path in file_inputs.items()}
    if checked["native_engine"]["status"] == "present" and not os.access(
        Path(native_engine).absolute(), os.X_OK
    ):
        checked["native_engine"] = {
            "status": "invalid",
            "reason": "native engine file is not executable",
        }
    if road_tilesets:
        root = Path(road_tilesets).absolute()
        checked["road_tilesets"] = {
            "status": "present" if root.is_dir() and not root.is_symlink() else "missing",
            "reason": None if root.is_dir() and not root.is_symlink()
            else "not a regular local directory",
        }
    else:
        checked["road_tilesets"] = {
            "status": "missing",
            "reason": "path not supplied",
        }

    blockers = []
    if base_status["status"] not in ("present", "verified"):
        blockers.append("authorized_essentials_v21_1_base")
    if rom_status["status"] != "present":
        blockers.append("authorized_source_rom")
    if rom_rights_status["status"] != "verified":
        blockers.append("source_rom_rights_record")
    if hns_status["status"] != "present_unverified":
        blockers.append("hns_source_export_files")
    for name in ("gate_mapping", "road_mapping", "gate_tileset",
                 "road_tilesets", "route22_source", "viridian_source",
                 "native_engine"):
        if checked[name]["status"] != "present":
            blockers.append(name)

    implementation_gaps = [
        "No checked-in converter derives the Essentials/RMXP project or native event maps directly from a GBA ROM; the current HnS converters require pinned map exports and reviewed XP tile mappings.",
        "Native HnS map and initial-slice event installers require an RGSS/Essentials execution step; this diagnostic does not claim that they have been run.",
        "Native game launch is not a playthrough; opening checkpoints and Save/Continue require a real interactive run and private visual evidence.",
    ]
    return {
        "schema_version": 1,
        "kind": "private_native_assembly_input_diagnostic",
        "status": "BLOCKED" if blockers or implementation_gaps else "READY_FOR_ASSEMBLY",
        "input_status": "complete" if not blockers else "missing_or_invalid",
        "inputs": {
            "essentials_base": base_status,
            "source_rom": rom_status,
            "source_rom_rights": rom_rights_status,
            "hns_source": hns_status,
            **checked,
        },
        "blockers": blockers,
        "implementation_gaps": implementation_gaps,
        "assembly_ready": False,
        "native_gameplay_verified": False,
        "save_reload_verified": False,
        "screenshots_created": False,
        "private_assets_copied": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", help="optional extracted local Essentials project")
    parser.add_argument("--base-archive", help="local clean Essentials 21.1 ZIP")
    parser.add_argument("--base-rights", help="SHA-pinned local Essentials rights record")
    parser.add_argument("--source-rom", help="local authorized source ROM")
    parser.add_argument("--rom-rights", help="SHA-pinned source-ROM rights record")
    parser.add_argument("--hns-source", help="pinned local HnS source checkout")
    parser.add_argument("--gate-mapping", help="reviewed reception-gate XP mapping JSON")
    parser.add_argument("--road-mapping", help="reviewed Victory Road XP mapping JSON")
    parser.add_argument("--gate-tileset", help="rights-cleared reception-gate tileset PNG")
    parser.add_argument("--road-tilesets", help="directory of rights-cleared Victory Road PNGs")
    parser.add_argument("--route22-source", help="local reviewed Route 22 native map input")
    parser.add_argument("--viridian-source", help="local reviewed Viridian native map input")
    parser.add_argument("--native-engine", help="local official mkxp-z executable")
    parser.add_argument("--report", type=Path, help="write a new local JSON diagnostic")
    args = parser.parse_args(argv)
    result = diagnose(
        project=args.project, base_archive=args.base_archive,
        base_rights=args.base_rights, source_rom=args.source_rom,
        rom_rights=args.rom_rights, hns_source=args.hns_source,
        gate_mapping=args.gate_mapping, road_mapping=args.road_mapping,
        gate_tileset=args.gate_tileset, road_tilesets=args.road_tilesets,
        route22_source=args.route22_source, viridian_source=args.viridian_source,
        native_engine=args.native_engine,
    )
    if args.report:
        if args.report.exists() or args.report.is_symlink():
            parser.error("refusing to overwrite an existing report")
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "READY_FOR_ASSEMBLY" else 2


if __name__ == "__main__":
    raise SystemExit(main())

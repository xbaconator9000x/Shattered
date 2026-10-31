#!/usr/bin/env python3
"""Prepare a PRIVATE staged Essentials project for Linux's case-sensitive map compiler.

The authorised v0.4 Essentials v21.1 Compiler::MapData requests Data/mapNNN.rxdata,
while RPG Maker XP stores Data/MapNNN.rxdata. Never rename originals or publish RXData.
Run only after stage_essentials.py, before native debug compilation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

RECEIPT = "SHATTERED_LINUX_MAP_ALIASES.json"
PATTERN = re.compile(r"Map[0-9]{3}\.rxdata\Z")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(project):
    project = Path(project).absolute()
    if project.is_symlink() or not project.is_dir():
        raise ValueError("unsafe private project directory")
    if not (project / "SHATTERED_STAGING_REPORT.json").is_file():
        raise ValueError("refusing to alter project without private staging receipt")
    data = project / "Data"
    if data.is_symlink() or not data.is_dir():
        raise ValueError("unsafe native Data directory")
    originals = sorted(
        p for p in data.iterdir() if PATTERN.fullmatch(p.name)
    )
    if not originals:
        raise ValueError("no native MapNNN.rxdata files found")
    planned = []
    for original in originals:
        if original.is_symlink() or not original.is_file():
            raise ValueError(f"unsafe native map: {original.name}")
        alias = data / ("map" + original.name[3:])
        if alias.is_symlink():
            if os.readlink(alias) != original.name:
                raise ValueError(f"wrong lowercase map alias: {alias.name}")
        elif alias.exists():
            raise ValueError(f"lowercase map path collides: {alias.name}")
        planned.append((original, alias))
    receipt_path = project / RECEIPT
    if receipt_path.is_symlink():
        raise ValueError("unsafe existing alias receipt")
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("kind") != "private_linux_native_map_aliases_not_gameplay_acceptance":
            raise ValueError("invalid existing alias receipt")
        if receipt.get("maps") != {
            src.name: digest(src) for src, _ in planned
        } or any(not dst.is_symlink() for _, dst in planned):
            raise ValueError("map aliases or source hashes changed after preparation")
        return receipt
    created = []
    try:
        for original, alias in planned:
            if not alias.is_symlink():
                alias.symlink_to(original.name)
                created.append(alias)
        receipt = {
            "kind": "private_linux_native_map_aliases_not_gameplay_acceptance",
            "maps": {src.name: digest(src) for src, _ in planned},
            "alias_count": len(planned),
            "native_pbs_compiled": False,
            "gameplay_verified": False,
        }
        temporary = project / (RECEIPT + ".tmp")
        if temporary.exists() or temporary.is_symlink():
            raise ValueError("stale map alias receipt temp")
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(receipt_path)
        return receipt
    except BaseException:
        for alias in created:
            alias.unlink(missing_ok=True)
        (project / (RECEIPT + ".tmp")).unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.project), indent=2))

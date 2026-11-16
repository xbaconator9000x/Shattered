#!/usr/bin/env python3
"""Build private Onix rider character sheets from existing project art.

No source pixels are kept in this repository. The installer uses only an
authorised project's existing ONIX front and player character sheets, emits
deterministic private composites and writes a hash receipt. Crystal Onix,
Crystalix and Bullgrum deliberately remain unavailable until their reviewed
source sheets exist; this never substitutes Onix art for another species.
"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


CELL = (32, 48)
SHEET = (128, 192)
PLAYER_SHEETS = ("boy_run", "girl_run")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path):
    return path.is_file() and not path.is_symlink()


def build(project):
    root = Path(project).resolve()
    characters = root / "Graphics" / "Characters"
    source = root / "Graphics" / "Pokemon" / "Front" / "ONIX.png"
    if not regular(source):
        raise ValueError("missing private ONIX front")
    with Image.open(source) as raw:
        front = raw.convert("RGBA")
    if front.size != (160, 160):
        raise ValueError("unexpected ONIX front geometry")
    bounds = front.getbbox()
    if not bounds:
        raise ValueError("blank ONIX front")
    mount = front.crop(bounds)
    mount.thumbnail((32, 30), Image.Resampling.NEAREST)
    installed = []
    for name in PLAYER_SHEETS:
        player_path = characters / f"{name}.png"
        if not regular(player_path):
            continue
        with Image.open(player_path) as raw:
            player = raw.convert("RGBA")
        if player.size != SHEET:
            raise ValueError(f"unexpected player sheet geometry: {name}")
        sheet = Image.new("RGBA", SHEET, (0, 0, 0, 0))
        for row in range(4):
            for column in range(4):
                x, y = column * CELL[0], row * CELL[1]
                # The character's upper portion remains visible as the rider;
                # the actual project Onix front supplies the mount pixels.
                rider = player.crop((x, y, x + CELL[0], y + 26))
                frame = Image.new("RGBA", CELL, (0, 0, 0, 0))
                frame.alpha_composite(mount, ((CELL[0] - mount.width) // 2, 18))
                frame.alpha_composite(rider, (0, 0))
                sheet.alpha_composite(frame, (x, y))
        target = characters / f"SHATTERED_RIDE_ONIX_{name}.png"
        if target.exists() and target.is_symlink():
            raise ValueError(f"unsafe mount target: {target.name}")
        sheet.save(target)
        installed.append({"character": target.name, "sha256": digest(target),
                          "player_source_sha256": digest(player_path)})
    if not installed:
        raise ValueError("no recognised private player sheets")
    report = {"kind": "private_onix_mount_composites_not_runtime_acceptance",
              "onix_front_sha256": digest(source), "installed": installed,
              "unavailable_species": ["CRYSTALONIX", "CRYSTALIX", "BULLGRUM"],
              "native_engine_launched": False, "gameplay_verified": False}
    (root / "SHATTERED_MOUNT_COMPOSITES_REPORT.json").write_text(
        json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    print(json.dumps(build(parser.parse_args().project), indent=2))

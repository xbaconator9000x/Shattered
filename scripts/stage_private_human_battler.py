#!/usr/bin/env python3
"""Private-only temporary HUMAN battle art from an authorised Essentials v21.1 base.

No image is stored in GitHub. This source-only transform permits native battle
playtests while a proper Shattered HUMAN battler/icon is being drawn and reviewed.
It is deliberately NOT a final art asset or a claim of game/runtime acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image

BACK_REL = Path("Graphics/Trainers/POKEMONTRAINER_Red_back.png")
FRONT_REL = Path("Graphics/Trainers/POKEMONTRAINER_Red.png")
BACK_SHA256 = "9f5e0fa8b6c02b059085b1d75af994cf8f875c9c4f25c33b57f322dd28e7499c"
FRONT_SHA256 = "dd51e9fb78fb791212f0943333b73524d8932b614b54023a13f28745b9729bfb"
TARGETS = {
    "back": Path("Graphics/Pokemon/Back/HUMAN.png"),
    "front": Path("Graphics/Pokemon/Front/HUMAN.png"),
    "icon": Path("Graphics/Pokemon/Icons/HUMAN.png"),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def png(image: Image.Image) -> bytes:
    stream = io.BytesIO()
    image.save(stream, format="PNG", optimize=False)
    return stream.getvalue()


def fit_icon(image: Image.Image) -> Image.Image:
    bbox = image.getbbox()
    if not bbox:
        raise ValueError("source has no visible HUMAN pixels")
    cropped = image.crop(bbox)
    ratio = min(56 / cropped.width, 56 / cropped.height)
    size = (max(1, int(cropped.width * ratio)), max(1, int(cropped.height * ratio)))
    sprite = cropped.resize(size, Image.Resampling.NEAREST)
    result = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    result.alpha_composite(sprite, ((64 - size[0]) // 2, 62 - size[1]))
    return result


def build_assets(back_bytes: bytes, front_bytes: bytes) -> dict[str, bytes]:
    with Image.open(io.BytesIO(back_bytes)) as image:
        if image.size != (800, 160):
            raise ValueError("expected native five-frame 800x160 trainer back sheet")
        back = image.convert("RGBA").crop((0, 0, 160, 160))
    if not back.getbbox():
        raise ValueError("empty first trainer back frame")
    with Image.open(io.BytesIO(front_bytes)) as image:
        if image.size != (128, 128):
            raise ValueError("expected native 128x128 trainer front image")
        front_source = image.convert("RGBA")
    if not front_source.getbbox():
        raise ValueError("empty trainer front image")
    front = Image.new("RGBA", (160, 160), (0, 0, 0, 0))
    front.alpha_composite(front_source, (16, 32))
    icon_frame = fit_icon(front_source)
    icon = Image.new("RGBA", (128, 64), (0, 0, 0, 0))
    icon.alpha_composite(icon_frame, (0, 0))
    icon.alpha_composite(icon_frame, (64, 0))
    return {"back": png(back), "front": png(front), "icon": png(icon)}


def checked_file(root: Path, relative: Path) -> Path:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"symlinked private path: {relative}")
    if not current.is_file():
        raise ValueError(f"missing private file: {relative}")
    return current


def stage(project: Path, *, pins: tuple[str, str] = (BACK_SHA256, FRONT_SHA256)) -> dict:
    project = Path(project).absolute()
    if project.is_symlink() or not project.is_dir():
        raise ValueError("requires a real private staged project directory")
    marker = checked_file(project, Path("SHATTERED_STAGING_REPORT.json"))
    report = json.loads(marker.read_text(encoding="utf-8"))
    if report.get("engine") != "Essentials 21.1":
        raise ValueError("not an Essentials v21.1 staged project")
    sources = [checked_file(project, BACK_REL).read_bytes(),
               checked_file(project, FRONT_REL).read_bytes()]
    if (sha256(sources[0]), sha256(sources[1])) != pins:
        raise ValueError("trainer art hash differs from reviewed private v0.4 base")
    outputs = build_assets(*sources)
    # Preflight ALL three outputs before writing any. Never replace a foreign
    # HUMAN sprite supplied by the user or an already reviewed custom battler.
    for kind, relative in TARGETS.items():
        dest = project / relative
        current = project
        for part in relative.parts[:-1]:
            current = current / part
            if current.is_symlink():
                raise ValueError(f"symlinked destination directory: {relative}")
        if dest.is_symlink() or (dest.exists() and (not dest.is_file() or dest.read_bytes() != outputs[kind])):
            raise ValueError(f"refusing to overwrite custom HUMAN art: {relative}")
    for kind, relative in TARGETS.items():
        dest = project / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists():
            with dest.open("xb") as file:
                file.write(outputs[kind])
    return {
        "kind": "temporary_private_human_battle_art",
        "source_sha256": {str(BACK_REL): pins[0], str(FRONT_REL): pins[1]},
        "outputs": {str(TARGETS[k]): sha256(v) for k, v in outputs.items()},
        "source_game_art_redistributable": False,
        "final_shattered_art_approved": False,
        "native_gameplay_verified": False,
        "android_verified": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(stage(args.project), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

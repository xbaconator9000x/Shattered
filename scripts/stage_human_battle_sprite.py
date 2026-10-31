#!/usr/bin/env python3
"""Private Essentials HUMAN battle-back fallback from a reviewed 5-frame trainer sheet.

The user's original v0.4 project has a 800x160 RGBA trainer-back animation
but no HUMAN Pokémon back sprite. Extract one 160x160 frame into the *staged*
game's Graphics/Pokemon/Back/HUMAN.png. Source assets are never embedded in Git.
This is a temporary visual fallback, NOT the intended Shattered survivalist art.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import struct
import tempfile
import zlib

PNG = b"\x89PNG\r\n\x1a\n"
MAX_SOURCE = 5 * 1024 * 1024
SOURCE_WIDTH, HEIGHT, FRAME = 800, 160, 160


class SpriteError(ValueError):
    pass


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload +
            struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))


def rgba_rows(raw):
    if len(raw) > MAX_SOURCE or not raw.startswith(PNG):
        raise SpriteError("expected a small PNG")
    offset, image_data, width, height, ended = 8, bytearray(), None, None, False
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise SpriteError("truncated PNG")
        size = struct.unpack_from(">I", raw, offset)[0]
        kind = raw[offset + 4:offset + 8]
        end = offset + 12 + size
        if end > len(raw):
            raise SpriteError("invalid PNG chunk length")
        payload = raw[offset + 8:end - 4]
        crc = struct.unpack_from(">I", raw, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise SpriteError("PNG CRC mismatch")
        if offset == 8:
            if kind != b"IHDR" or size != 13:
                raise SpriteError("invalid PNG header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if (width, height, depth, color, compression, filtering, interlace) != (
                    SOURCE_WIDTH, HEIGHT, 8, 6, 0, 0, 0):
                raise SpriteError("expected non-interlaced 800x160 RGBA trainer sheet")
        elif kind == b"IDAT":
            image_data.extend(payload)
            if len(image_data) > MAX_SOURCE:
                raise SpriteError("oversized PNG image data")
        elif kind == b"IEND":
            ended = size == 0 and end == len(raw)
            break
        elif kind and kind[0] & 0x20 == 0:
            raise SpriteError("unsupported PNG critical chunk")
        offset = end
    if not ended or not image_data:
        raise SpriteError("incomplete PNG")
    stride = SOURCE_WIDTH * 4
    expected = HEIGHT * (stride + 1)
    inflater = zlib.decompressobj()
    data = inflater.decompress(bytes(image_data), expected + 1)
    if len(data) > expected or inflater.unconsumed_tail:
        raise SpriteError("oversized decompressed PNG")
    data += inflater.flush()
    if len(data) != expected or not inflater.eof or inflater.unused_data:
        raise SpriteError("invalid PNG scanlines")
    rows, previous = [], bytearray(stride)
    for y in range(HEIGHT):
        line = data[y * (stride + 1):(y + 1) * (stride + 1)]
        filter_type, row = line[0], bytearray(line[1:])
        if filter_type > 4:
            raise SpriteError("unsupported PNG row filter")
        for i in range(stride):
            a = row[i - 4] if i >= 4 else 0
            b = previous[i]
            c = previous[i - 4] if i >= 4 else 0
            if filter_type == 1:
                row[i] = (row[i] + a) & 255
            elif filter_type == 2:
                row[i] = (row[i] + b) & 255
            elif filter_type == 3:
                row[i] = (row[i] + (a + b) // 2) & 255
            elif filter_type == 4:
                p = a + b - c
                options = (a, b, c)
                row[i] = (row[i] + options[min(range(3), key=lambda j: abs(p - options[j]))]) & 255
        rows.append(bytes(row))
        previous = row
    return rows


def build_frame(raw, frame_index):
    if not isinstance(frame_index, int) or not 0 <= frame_index < 5:
        raise SpriteError("trainer back frame index must be 0 through 4")
    rows = rgba_rows(raw)
    start = frame_index * FRAME * 4
    scanlines = b"".join(
        b"\x00" + row[start:start + FRAME * 4] for row in rows
    )
    return (PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", FRAME, FRAME, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b""))


def stage(project, *, source="Graphics/Trainers/POKEMONTRAINER_Red_back.png",
          frame_index=0, expected_source_sha256=None, force=False):
    project = Path(project).absolute()
    if project.is_symlink() or not project.is_dir() or not (
            project / "SHATTERED_STAGING_REPORT.json").is_file():
        raise SpriteError("requires a private staged Essentials project")
    if not re.fullmatch(r"Graphics/Trainers/[A-Za-z0-9_-]+_back\.png", source):
        raise SpriteError("source must be a reviewed private trainer-back sprite")
    path = project / source
    target = project / "Graphics/Pokemon/Back/HUMAN.png"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_SOURCE:
        raise SpriteError("missing or unsafe trainer sprite")
    if target.is_symlink() or target.parent.is_symlink() or (
            target.exists() and not force):
        raise SpriteError("refusing to overwrite HUMAN sprite without explicit --force")
    if expected_source_sha256 is not None and not re.fullmatch(r"[0-9a-f]{64}", expected_source_sha256):
        raise SpriteError("invalid source SHA pin")
    raw = path.read_bytes()
    source_hash = hashlib.sha256(raw).hexdigest()
    if expected_source_sha256 and source_hash != expected_source_sha256:
        raise SpriteError("source sprite SHA differs from reviewed asset")
    result = build_frame(raw, frame_index)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix=".human-back-",
                                         suffix=".png.tmp", dir=target.parent,
                                         delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(result)
        os.replace(temporary, target)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return {
        "source_sha256": source_hash,
        "output_sha256": hashlib.sha256(result).hexdigest(),
        "source_dimensions": [SOURCE_WIDTH, HEIGHT],
        "output_dimensions": [FRAME, FRAME],
        "frame_index": frame_index,
        "asset_redistribution_authorised": False,
        "temporary_fallback_not_final_survivalist_art": True,
        "native_battle_verified": False,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--source", default="Graphics/Trainers/POKEMONTRAINER_Red_back.png")
    parser.add_argument("--frame-index", type=int, default=0)
    parser.add_argument("--expected-source-sha256")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    import json
    print(json.dumps(stage(args.project, source=args.source,
                           frame_index=args.frame_index,
                           expected_source_sha256=args.expected_source_sha256,
                           force=args.force), indent=2))

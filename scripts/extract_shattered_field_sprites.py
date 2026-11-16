#!/usr/bin/env python3
"""Convert the authenticated private xx1.08 Viridian guard to an RMXP sheet.

Only source code belongs in git. ROM, extracted pixels and receipts stay private.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from PIL import Image

ROM_SHA256 = "e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2"
MAP_GROUPS = 0x36FC9C
GRAPHICS_TABLE = 0x3C402C
PALETTE_ENTRY = 0x3C93D4
NAME = "SHATTERED_ROM_Guard"


def pointer(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise ValueError("pointer outside ROM")
    value = struct.unpack_from("<I", data, offset)[0] - 0x08000000
    if not 0 <= value < len(data):
        raise ValueError("invalid ROM pointer")
    return value


def decode_frame(data, offset, width, height, palette):
    size = width * height // 2
    if width % 8 or height % 8 or len(palette) != 32 or offset + size > len(data):
        raise ValueError("invalid native frame geometry or palette")
    colours = []
    for index in range(16):
        value = struct.unpack_from("<H", palette, index * 2)[0]
        colours.append(tuple(((value >> shift) & 31) * 255 // 31 for shift in (0, 5, 10))
                       + (0 if index == 0 else 255,))
    image = Image.new("RGBA", (width, height))
    for y in range(height):
        for x in range(width):
            tile = (y // 8) * (width // 8) + x // 8
            value = data[offset + tile * 32 + y % 8 * 4 + x % 8 // 2]
            image.putpixel((x, y), colours[(value >> (4 * (x % 2))) & 15])
    return image


def guard_sheet(data):
    # Read the actual map 3.1 object event; do not infer identity from a filename.
    header = pointer(data, pointer(data, MAP_GROUPS + 3 * 4) + 4)
    events = pointer(data, header + 4)
    objects = pointer(data, events + 4)
    records = [objects + i * 24 for i in range(data[events])]
    guards = [o for o in records if data[o] == 1 and data[o + 1] == 60
              and struct.unpack_from("<HH", data, o + 4) == (9, 16)]
    if len(guards) != 1:
        raise ValueError("Viridian guard source event differs")
    info = pointer(data, GRAPHICS_TABLE + 60 * 4)
    if struct.unpack_from("<HH", data, info + 8) != (16, 32):
        raise ValueError("guard frame dimensions changed")
    tag = struct.unpack_from("<H", data, info + 2)[0]
    if tag != 0x1103 or struct.unpack_from("<H", data, PALETTE_ENTRY + 4)[0] != tag:
        raise ValueError("guard palette identity changed")
    palette_offset = pointer(data, PALETTE_ENTRY)
    palette = data[palette_offset:palette_offset + 32]
    images = pointer(data, info + 28)
    frames = []
    for index in range(9):
        offset = pointer(data, images + index * 8)
        if struct.unpack_from("<I", data, images + index * 8 + 4)[0] != 256:
            raise ValueError("guard native frame size changed")
        frames.append(decode_frame(data, offset, 16, 32, palette))
    sheet = Image.new("RGBA", (128, 128))
    # Native GBA: idle down/up/left, then two walking poses per direction.
    for row, (idle, left, right, mirror) in enumerate(
            ((0, 3, 4, False), (2, 7, 8, False),
             (2, 7, 8, True), (1, 5, 6, False))):
        for column, frame in enumerate((idle, left, idle, right)):
            image = frames[frame]
            if mirror:
                image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            sheet.alpha_composite(image, (column * 32 + 8, row * 32))
    return sheet, {"map": [3, 1], "local_id": 1, "position": [9, 16],
                   "graphics_id": 60, "object_offset": guards[0],
                   "graphics_info_offset": info, "palette_offset": palette_offset}


def export(rom, output):
    data = Path(rom).read_bytes()
    if hashlib.sha256(data).hexdigest() != ROM_SHA256:
        raise ValueError("unrecognised ROM; resolve pointers before converting another revision")
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists")
    sheet, source = guard_sheet(data)
    output.mkdir(parents=True)
    target = output / (NAME + ".png")
    sheet.save(target)
    receipt = {"rom_sha256": ROM_SHA256, "source_event": source,
               "character": NAME, "dimensions": [128, 128],
               "sheet_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
               "native_gameplay_verified": False}
    (output / "guard_provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(export(args.rom, args.output), indent=2))

#!/usr/bin/env python3
"""Export selected Pokémon: Shattered xx1.08 front sprites without storing ROM art.

The user supplies their authorised xx1.08 ROM locally. This utility validates
that exact source and writes editable Essentials PNGs; no ROM bytes or derived
art belong in the repository.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from PIL import Image

ROM_SHA256 = "d9e5e3fbbaf4c63686b33a800cb95cb9c8849f5356a0c77c28245f2a95afc017"
ROM_BASE = 0x08000000
FRONT_TABLE = 0x24C280
PALETTE_TABLE = 0x24E4E0
FRONT_BYTES = 0x800
# xx1.08 retains these base slots while replacing their art/data with the
# Shattered regional forms. The final evolution occupies the vanilla slot.
SPECIES_IDS = {
    "RATTATA": 19,
    "NIDORANfE": 29,
    "NIDORANmA": 32,
    "VULPIX": 37,
    "NOCTALES": 38,
    "ONIX": 95,
    "EXEGGCUTE": 102,
    "EXEGGUTIVE": 103,
    "STARYU": 120,
    "STARUS": 121,
}


def lz77(data: bytes, offset: int) -> bytes:
    if offset + 4 > len(data) or data[offset] != 0x10:
        raise ValueError(f"expected GBA LZ77 header at 0x{offset:X}")
    size = data[offset + 1] | (data[offset + 2] << 8) | (data[offset + 3] << 16)
    pos, output = offset + 4, bytearray()
    while len(output) < size:
        if pos >= len(data):
            raise ValueError("truncated LZ77 flags")
        flags = data[pos]
        pos += 1
        for bit in range(7, -1, -1):
            if len(output) >= size:
                break
            if flags & (1 << bit):
                if pos + 2 > len(data):
                    raise ValueError("truncated LZ77 copy token")
                token = (data[pos] << 8) | data[pos + 1]
                pos += 2
                length, distance = (token >> 12) + 3, (token & 0xFFF) + 1
                if distance > len(output):
                    raise ValueError("invalid LZ77 back-reference")
                for _ in range(length):
                    output.append(output[-distance])
                    if len(output) >= size:
                        break
            else:
                if pos >= len(data):
                    raise ValueError("truncated LZ77 literal")
                output.append(data[pos])
                pos += 1
    return bytes(output[:size])


def gba_colour(value: int) -> tuple[int, int, int, int]:
    return tuple(((value >> shift) & 31) * 255 // 31 for shift in (0, 5, 10)) + (
        0 if value == 0 else 255,
    )


def decode_front(tiles: bytes, palette: bytes) -> Image.Image:
    if len(tiles) != FRONT_BYTES:
        raise ValueError(f"front sprite is {len(tiles)} bytes, expected {FRONT_BYTES}")
    if len(palette) != 32:
        raise ValueError("front palette must be 16 colours")
    colours = [gba_colour(int.from_bytes(palette[i : i + 2], "little")) for i in range(0, 32, 2)]
    image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    pixels = image.load()
    for tile in range(64):
        x0, y0, base = (tile % 8) * 8, (tile // 8) * 8, tile * 32
        for y in range(8):
            for x in range(8):
                packed = tiles[base + y * 4 + x // 2]
                index = packed & 0x0F if x % 2 == 0 else packed >> 4
                pixels[x0 + x, y0 + y] = colours[index]
    return image


def source_pointer(data: bytes, table: int, species_id: int) -> int:
    address = int.from_bytes(data[table + species_id * 8 : table + species_id * 8 + 4], "little")
    if not ROM_BASE <= address < ROM_BASE + len(data):
        raise ValueError(f"species {species_id} has invalid ROM pointer 0x{address:X}")
    return address - ROM_BASE


def export_one(data: bytes, name: str, species_id: int, output: Path) -> None:
    graphics = lz77(data, source_pointer(data, FRONT_TABLE, species_id))
    palette_offset = source_pointer(data, PALETTE_TABLE, species_id)
    native = decode_front(graphics, data[palette_offset : palette_offset + 32])
    # Essentials v21.1's existing Pokémon fronts are 160px. Preserve the
    # original pixels at a 2x nearest-neighbour scale, centered in that canvas.
    rendered = native.resize((128, 128), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", (160, 160), (0, 0, 0, 0))
    canvas.alpha_composite(rendered, (16, 16))
    canvas.save(output / f"{name}.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--species", nargs="*", choices=sorted(SPECIES_IDS))
    args = parser.parse_args()
    data = args.rom.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != ROM_SHA256:
        raise SystemExit(f"refusing unrecognised ROM: {actual} (expected {ROM_SHA256})")
    args.output.mkdir(parents=True, exist_ok=True)
    for name in args.species or list(SPECIES_IDS):
        export_one(data, name, SPECIES_IDS[name], args.output)
    print(f"exported {len(args.species or SPECIES_IDS)} authenticated xx1.08 fronts to {args.output}")


if __name__ == "__main__":
    main()

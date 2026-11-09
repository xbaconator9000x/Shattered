#!/usr/bin/env python3
"""Enable Crystal Onix and Crystalix in the live mount hook."""
from pathlib import Path
import hashlib
import struct

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "Shattered_Onix_Bullgrum_Crystal_Assets_Experimental.gba"
TARGET = ROOT / "Shattered_All_Three_Mounts_Experimental.gba"
ROM_BASE = 0x08000000
CODE_BASE = 0x08929A00
OLD_TABLE = CODE_BASE + 0x984
NEW_CODE = CODE_BASE + 0xB00
NEW_TABLE = CODE_BASE + 0xB60

def profile(species, seat_x, seat_y, height, frames, palette):
    return struct.pack("<H10B9I", species, *seat_x, *seat_y, height, 64,
                       *frames, palette)

rom = bytearray(SOURCE.read_bytes())
if len(rom) != 32 * 1024 * 1024:
    raise SystemExit("unexpected test ROM size")
old = rom[OLD_TABLE - ROM_BASE:OLD_TABLE - ROM_BASE + 96]
if len(old) != 96 or old[:2] != struct.pack("<H", 95) or old[48:50] != struct.pack("<H", 262):
    raise SystemExit("expected Onix/Bullgrum profile table was not found")

crystal_onix = profile(272, (24, 27, 30, 34), (18, 19, 22, 22), 14,
                       tuple(0x08931000 + i * 0x800 for i in range(8)), 0x08935000)
crystalix = profile(273, (32, 31, 35, 29), (19, 18, 20, 20), 14,
                     tuple(0x08936000 + i * 0x800 for i in range(8)), 0x0893A000)
rom[NEW_TABLE - ROM_BASE:NEW_TABLE - ROM_BASE + 192] = old + crystal_onix + crystalix

old_profile = CODE_BASE + 0x484
delta = NEW_CODE - (old_profile + 4)
if delta % 2 or not (-2048 <= delta // 2 <= 2047):
    raise SystemExit("dispatcher branch out of range")
rom[old_profile - ROM_BASE:old_profile - ROM_BASE + 2] = struct.pack("<H", 0xE000 | ((delta // 2) & 0x7FF))

# Thumb: profile(95), profile(262), profile(272), profile(273), else NULL.
words = [
    0x285F, 0xD00C, 0x2183, 0x0049, 0x4288, 0xD00A,
    0x2188, 0x0049, 0x4288, 0xD008, 0x3101, 0x4288, 0xD007,
    0x2000, 0x4770,
    0x4804, 0x4770, 0x4804, 0x4770, 0x4804, 0x4770, 0x4804, 0x4770,
]
dispatch = struct.pack("<" + "H" * len(words), *words)
dispatch += struct.pack("<4I", NEW_TABLE, NEW_TABLE + 48, NEW_TABLE + 96, NEW_TABLE + 144)
rom[NEW_CODE - ROM_BASE:NEW_CODE - ROM_BASE + len(dispatch)] = dispatch
for address in (CODE_BASE + 0x480, CODE_BASE + 0x834):
    rom[address - ROM_BASE:address - ROM_BASE + 4] = struct.pack("<I", NEW_TABLE)
TARGET.write_bytes(rom)
print(TARGET)
print("sha256", hashlib.sha256(rom).hexdigest())
print("profile ids", [struct.unpack_from("<H", rom, NEW_TABLE - ROM_BASE + i * 48)[0] for i in range(4)])

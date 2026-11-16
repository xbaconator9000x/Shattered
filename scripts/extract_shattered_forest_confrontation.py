#!/usr/bin/env python3
"""Extract the private ROM's forest confrontation without publishing its text."""
import argparse
import hashlib
import json
from pathlib import Path

ROM_SHA = "e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2"
DIALOGUE = {"choice": 0x159A254, "intro": 0x159A2CC, "won": 0x159A32C,
            "lost": 0x159A36C, "after": 0x159A3F0}

def decode(data, offset):
    table = {0: " ", 0x1B: "é", 0xAB: "!", 0xAC: "?", 0xAD: ".", 0xAE: "-",
             0xB0: "…", 0xB1: "“", 0xB2: "”", 0xB3: "‘", 0xB4: "'",
             0xB8: ",", 0xBA: "/", 0xF0: ":", 0xFE: "\n", 0xFA: "\n\n",
             0xFB: "\n\n"}
    table.update({0xBB + i: chr(65 + i) for i in range(26)})
    table.update({0xD5 + i: chr(97 + i) for i in range(26)})
    table.update({0xA1 + i: str(i) for i in range(10)})
    result, i = [], offset
    while i < min(len(data), offset + 4096):
        value = data[i]; i += 1
        if value == 0xFF:
            return "".join(result)
        if value == 0xFC:
            if i >= len(data) or data[i] != 4:
                raise ValueError("unsupported source text control")
            i += 4
        elif value == 0xFD:
            if i >= len(data) or data[i] != 1:
                raise ValueError("unsupported source text substitution")
            result.append("{PLAYER}"); i += 1
        elif value in table:
            result.append(table[value])
        else:
            raise ValueError(f"unsupported source text byte {value:#x}")
    raise ValueError("unterminated source text")

def extract(rom, output):
    raw = Path(rom).read_bytes()
    if hashlib.sha256(raw).hexdigest() != ROM_SHA:
        raise ValueError("unknown ROM revision")
    payload = {
        "rom_sha256": ROM_SHA, "dialogue_offsets": DIALOGUE,
        "dialogue": {key: decode(raw, value).split("\n\n") for key, value in DIALOGUE.items()},
        "foe": {"species": "RAIDER", "level": 7,
                "moves": ["POUND", "LEER", "FOCUSENERGY", "QUICKATTACK"],
                "iv": 15, "personality": 0x23456789},
    }
    target = Path(output)
    if target.exists(): raise ValueError("output already exists")
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    return payload

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(extract(args.rom, args.output), indent=2, ensure_ascii=False))

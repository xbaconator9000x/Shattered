#!/usr/bin/env python3
"""Extract the private registered-mounts ROM's first Viridian chapter dialogue."""
import argparse
import hashlib
import json
from pathlib import Path

ROM_SHA = 'e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2'
SOURCES = {
    'hana': [0xF9AC34, 0xCD75B0], 'morning': [0xF5B884],
    'tour': [0x15F4154, 0x15F41A8, 0x15F4230, 0x15F42CC, 0x15F4364,
             0x15F43D8, 0x15F4464, 0x15F453C, 0x15F45A8],
    'council': [0x15E85C8], 'request': [0x15E8724],
    'accepted': [0x15E883C, 0x15E8AA0], 'reminder': [0x15CF894],
    'thanks': [0x15CF950, 0x15CFA68], 'bag_full': [0x15CFB40],
    'tools_full': [0x15E8BC8]
}


def decode(data, offset):
    table = {0: ' ', 0xAB: '!', 0xAC: '?', 0xAD: '.', 0xAE: '-',
             0xB0: '…', 0xB1: '“', 0xB2: '”', 0xB3: '‘', 0xB4: "'",
             0xB8: ',', 0xBA: '/', 0xF0: ':', 0x1B: 'é',
             0xFE: '\n', 0xFA: '\n\n', 0xFB: '\n\n'}
    table.update({0xBB+i: chr(65+i) for i in range(26)})
    table.update({0xD5+i: chr(97+i) for i in range(26)})
    table.update({0xA1+i: str(i) for i in range(10)})
    result = []
    i = offset
    while i < min(len(data), offset + 4096):
        byte = data[i]
        i += 1
        if byte == 0xFF:
            return ''.join(result)
        if byte == 0xFC:
            if data[i] != 4:
                raise ValueError('unsupported text control')
            i += 4  # Colour, highlight, and shadow: three parameters.
        elif byte == 0xFD:
            if data[i] != 1:
                raise ValueError('unsupported dialogue substitution')
            result.append('{PLAYER}')
            i += 1
        elif byte in table:
            result.append(table[byte])
        else:
            raise ValueError(f'unsupported text byte {byte:#x} at {i-1:#x}')
    raise ValueError('unterminated source text')


def extract(rom, output):
    data = Path(rom).read_bytes()
    if hashlib.sha256(data).hexdigest() != ROM_SHA:
        raise ValueError('unknown ROM revision')
    dialogue = {}
    for key, pointers in SOURCES.items():
        entries = [decode(data, pointer).split('\n\n') for pointer in pointers]
        dialogue[key] = entries if key == 'tour' else [line for entry in entries for line in entry]
    report = {'rom_sha256': ROM_SHA, 'source_offsets': SOURCES, 'dialogue': dialogue}
    target = Path(output)
    if target.exists():
        raise ValueError('output already exists')
    target.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    extract(args.rom, args.output)

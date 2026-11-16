#!/usr/bin/env python3
"""Recover the authenticated private ROM's curriculum; never publish its output."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from extract_shattered_viridian_dialogue import ROM_SHA, decode

CLASS_TABLE = 0x10B7D90
LEARN_TABLE = 0x10B21F0
LEARN_COUNT = 5850


def curriculum(data):
    if hashlib.sha256(data).hexdigest() != ROM_SHA:
        raise ValueError('unknown ROM revision')

    def pointer(offset):
        value = struct.unpack_from('<I', data, offset)[0] - 0x8000000
        if not 0 <= value < len(data):
            raise ValueError('invalid source pointer')
        return value

    def ascii_text(offset):
        end = data.index(0, offset, offset + 256)
        return data[offset:end].decode('ascii')

    move_names = pointer(0x1FFF008)
    classes = []
    for index in range(171):
        row = CLASS_TABLE + index * 24
        classes.append(dict(id=index, name=ascii_text(pointer(row)),
                            description=ascii_text(pointer(row + 4)),
                            stats=list(data[row+8:row+14]),
                            types=list(data[row+14:row+16]),
                            passives=[decode(data, 0x266E18 + ability * 13) if ability else 'None'
                                      for ability in data[row+16:row+18]], moves=[]))
    previous = 0
    for index in range(LEARN_COUNT):
        cls, level, move = struct.unpack_from('<BBH', data, LEARN_TABLE + index * 4)
        if cls < previous or cls >= len(classes) or not 1 <= level <= 100:
            raise ValueError('invalid curriculum row')
        previous = cls
        classes[cls]['moves'].append([level, move, decode(data, move_names + move * 13)])
    if any(not entry['moves'] for entry in classes):
        raise ValueError('missing class curriculum')
    return dict(rom_sha256=ROM_SHA, class_table=CLASS_TABLE, learn_table=LEARN_TABLE,
                classes=classes, lesson=decode(data, 0x15DBF68).split('\n\n'))


def extract(rom, output):
    result = curriculum(Path(rom).read_bytes())
    with Path(output).open('x') as target:
        json.dump(result, target, indent=2)
        target.write('\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    extract(args.rom, args.output)

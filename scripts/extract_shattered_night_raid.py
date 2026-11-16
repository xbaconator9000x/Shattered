#!/usr/bin/env python3
"""Recover private night-raid battles by evaluating the ROM's selector code.

This bounded Thumb evaluator only executes encounter selection, stopping before
the builder calls any game functions. It is not gameplay or emulator evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from extract_shattered_viridian_dialogue import ROM_SHA, decode
from extract_shattered_xx108_fronts import source_pointer, lz77, decode_front, FRONT_TABLE, PALETTE_TABLE

BASE = 0x8000000
SPECIALS = 0x163D2C
START = 0xEB2964
STOP = 0xEB2A0A
ACTORS = [
    ('ren', 0x10BF0E0, [0x15B4E58, 0x15B4F58, 0x15B4FB8]),
    ('cook', 0x10BF28C, [0x15B5038, 0x15B507C, 0x15B50BC]),
    ('saff', 0x10BF43C, [0x15B513C, 0x15B5180, 0x15B51C0]),
    ('mara', 0x10BF64C, [0xF4B30C, 0xF4B380, 0xF4B3D4]),
    ('resident', 0x10BF864, [0xF4B454, 0xF4B4CC, 0xF4B540])
]


def select_encounter(data, selector):
    regs = [0] * 8
    pc, zero, carry = START, False, False
    for _ in range(128):
        if pc == STOP:
            return regs[7], regs[4], regs[6] - BASE
        if not START <= pc < STOP:
            raise ValueError('selector escaped reviewed code')
        op = struct.unpack_from('<H', data, pc)[0]
        next_pc = pc + 2
        if op & 0xF800 == 0x4800:  # LDR literal
            address = ((pc + 4) & ~3) + (op & 255) * 4
            regs[(op >> 8) & 7] = struct.unpack_from('<I', data, address)[0]
        elif op & 0xFE00 == 0x8800:  # LDRH immediate
            address = regs[(op >> 3) & 7] + ((op >> 6) & 31) * 2
            if address != 0x20370C0:
                raise ValueError('unexpected selector memory read')
            regs[op & 7] = selector
        elif op & 0xF800 == 0x2000:  # MOV immediate
            regs[(op >> 8) & 7] = op & 255
        elif op & 0xF800 == 0x2800:  # CMP immediate
            value, operand = regs[(op >> 8) & 7], op & 255
            zero, carry = value == operand, value >= operand
        elif op & 0xF800 == 0x1800:  # ADD/SUB low registers or immediate
            operand = (op >> 6) & 7
            if not op & 0x400:
                operand = regs[operand]
            value = regs[(op >> 3) & 7]
            regs[op & 7] = (value - operand if op & 0x200 else value + operand) & 0xFFFFFFFF
        elif op & 0xF800 in (0, 0x800):  # LSL/LSR immediate
            value, shift = regs[(op >> 3) & 7], (op >> 6) & 31
            regs[op & 7] = (value >> (shift or 32)) if op & 0x800 else (value << shift) & 0xFFFFFFFF
        elif op & 0xF000 == 0xD000:  # conditional branch
            condition = (op >> 8) & 15
            taken = {0: zero, 1: not zero, 9: not carry or zero}.get(condition)
            if taken is None:
                raise ValueError('unsupported selector condition')
            if taken:
                delta = (op & 255) - (256 if op & 128 else 0)
                next_pc = pc + 4 + delta * 2
        elif op & 0xF800 == 0xE000:
            delta = (op & 2047) - (2048 if op & 1024 else 0)
            next_pc = pc + 4 + delta * 2
        else:
            raise ValueError(f'unsupported selector instruction {op:#x} at {pc:#x}')
        pc = next_pc
    raise ValueError('selector exceeded instruction budget')


def recover(data):
    if hashlib.sha256(data).hexdigest() != ROM_SHA:
        raise ValueError('unknown ROM revision')
    if struct.unpack_from('<I', data, SPECIALS + 454 * 4)[0] != BASE + START - 3:
        raise ValueError('encounter builder pointer changed')
    if struct.unpack_from('<H', data, 0xEB2A26)[0] != 0x230F:
        raise ValueError('opponent fixed IV instruction changed')
    names = struct.unpack_from('<I', data, 0x1FFF008)[0] - BASE
    result = []
    for actor, script, texts in ACTORS:
        block = data[script:script+160]
        pattern = b'\x16\x04\x80'
        offsets = [i for i in range(len(block)-12) if block[i:i+3] == pattern and
                   block[i+5:i+12] == b'\x25\xc6\x01\x25\xc7\x01\x27']
        if len(offsets) != 1:
            raise ValueError('missing or ambiguous encounter call')
        selector = struct.unpack_from('<H', block, offsets[0]+3)[0]
        species, level, moves_at = select_encounter(data, selector)
        if species not in (15, 253) or not 1 <= level <= 100:
            raise ValueError('unsupported opponent mapping')
        moves = struct.unpack_from('<4H', data, moves_at)
        source_name = decode(data, 0x25D0B4 + species * 11)
        if source_name != ('BEEDRILL' if species == 15 else 'RAIDER'):
            raise ValueError('source species name changed')
        result.append(dict(id=actor, source_script=script, selector=selector,
                           species=source_name,
                           source_species=species, level=level, iv=15,
                           personality=struct.unpack_from('<I', data, 0xEB2A6C)[0],
                           moves=[decode(data, names+move*13).replace(' ', '').replace('-', '').upper() for move in moves],
                           source_moves=list(moves), moves_offset=moves_at,
                           dialogue={key: decode(data, offset).split('\n\n')
                                     for key, offset in zip(('intro', 'won', 'lost'), texts)}))
    raider = data[0x26B95C+253*28:0x26B95C+254*28]
    beedrill = data[0x26B95C+15*28:0x26B95C+16*28]
    return dict(rom_sha256=ROM_SHA, special_table=SPECIALS, builder=START-4,
                raider=dict(base_stats=list(raider[:6]), types=list(raider[6:8]),
                            catch_rate=raider[8], base_exp=raider[9],
                            ability=decode(data, 0x266E18+raider[22]*13).replace(' ', '').upper()),
                beedrill=dict(base_stats=list(beedrill[:6]), base_exp=beedrill[9]),
                selection_sha256=hashlib.sha256(data[START:STOP]).hexdigest(), encounters=result)


def extract(rom, output):
    data = Path(rom).read_bytes()
    result = recover(data)
    assets = Path(output).with_suffix('')
    if Path(output).exists() or assets.exists():
        raise ValueError('output already exists')
    assets.mkdir()
    # RAIDER is its own source species, not the player's HUMAN. Recover its
    # actual opponent art instead of borrowing the player's battle sprite.
    for species, name in [(253, 'RAIDER'), (15, 'BEEDRILL')]:
        front = lz77(data, source_pointer(data, FRONT_TABLE, species))
        palette = lz77(data, source_pointer(data, PALETTE_TABLE, species))
        decode_front(front, palette).resize((128, 128), resample=0).save(assets / (name+'.png'))
    result['asset_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in assets.iterdir()}
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

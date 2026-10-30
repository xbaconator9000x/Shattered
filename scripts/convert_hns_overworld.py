#!/usr/bin/env python3
"""Convert a locally held HnS six-pose indexed PNG to a 4x4 RPG Maker XP sheet.

Input: six 32x32 poses in one 192x32 strip, ordered down/down-walk,
up/up-walk, left/left-walk. Output: 128x128 RGBA, four frames per
direction, row order down/left/right/up. Right-facing is mirrored.
No Pokémon assets are embedded, fetched or committed by this tool.
Source rights and native gameplay must be verified independently.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

PNG = b"\x89PNG\r\n\x1a\n"
MAX_SIZE = 1024 * 1024

class SpriteFormatError(ValueError):
    pass

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

def decode(raw):
    if len(raw) > MAX_SIZE or not raw.startswith(PNG):
        raise SpriteFormatError("expected a small PNG")
    pos, width, height, depth, palette, compressed, alpha = 8, None, None, None, None, bytearray(), None
    ended = False
    while pos < len(raw):
        if pos + 12 > len(raw):
            raise SpriteFormatError("truncated PNG chunk")
        size = struct.unpack_from(">I", raw, pos)[0]
        tag = raw[pos + 4:pos + 8]
        end = pos + size + 12
        if end > len(raw):
            raise SpriteFormatError("truncated PNG chunk data")
        data = raw[pos + 8:pos + 8 + size]
        crc = struct.unpack_from(">I", raw, pos + 8 + size)[0]
        if zlib.crc32(tag + data) & 0xffffffff != crc:
            raise SpriteFormatError("PNG CRC mismatch")
        pos = end
        if tag == b"IHDR":
            if width is not None or len(data) != 13:
                raise SpriteFormatError("invalid PNG header")
            width, height, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", data)
            if (width, height) != (192, 32) or depth not in (1, 2, 4, 8) or color != 3 or (comp, filt, interlace) != (0, 0, 0):
                raise SpriteFormatError("expected 192x32 indexed, non-interlaced PNG")
        elif tag == b"PLTE":
            if not 0 < len(data) <= 768 or len(data) % 3:
                raise SpriteFormatError("invalid palette")
            palette = [tuple(data[i:i + 3]) for i in range(0, len(data), 3)]
        elif tag == b"tRNS":
            alpha = data
        elif tag == b"IDAT":
            compressed.extend(data)
            if len(compressed) > MAX_SIZE:
                raise SpriteFormatError("compressed PNG too large")
        elif tag == b"IEND":
            ended = True
            break
        elif tag and tag[0] & 0x20 == 0:
            raise SpriteFormatError("unsupported critical PNG chunk")
    if not ended or pos != len(raw) or not palette or not compressed or width is None:
        raise SpriteFormatError("incomplete indexed PNG")
    if alpha is not None and (not alpha or alpha[0] != 0 or any(x != 255 for x in alpha[1:])):
        raise SpriteFormatError("unexpected transparency palette")
    rowbytes = (width * depth + 7) // 8
    expected = height * (rowbytes + 1)
    inflater = zlib.decompressobj()
    pixels = inflater.decompress(bytes(compressed), expected + 1)
    if inflater.unconsumed_tail or len(pixels) > expected:
        raise SpriteFormatError("oversized decompressed PNG")
    pixels += inflater.flush()
    if len(pixels) != expected or not inflater.eof or inflater.unused_data:
        raise SpriteFormatError("invalid PNG scanline data")
    previous, rows = bytearray(rowbytes), []
    for y in range(height):
        scanline = pixels[y * (rowbytes + 1):(y + 1) * (rowbytes + 1)]
        kind, row = scanline[0], bytearray(scanline[1:])
        if kind > 4:
            raise SpriteFormatError("unsupported PNG filter")
        for i in range(rowbytes):
            a = row[i - 1] if i else 0
            b = previous[i]
            c = previous[i - 1] if i else 0
            if kind == 1:
                row[i] = (row[i] + a) & 255
            elif kind == 2:
                row[i] = (row[i] + b) & 255
            elif kind == 3:
                row[i] = (row[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                values = (a, b, c)
                row[i] = (row[i] + values[min(range(3), key=lambda n: abs(p - values[n]))]) & 255
        indices = bytearray()
        mask = (1 << depth) - 1
        for value in row:
            for shift in range(8 - depth, -1, -depth):
                indices.append((value >> shift) & mask)
        indices = indices[:width]
        if any(index >= len(palette) for index in indices):
            raise SpriteFormatError("palette index out of range")
        rows.append(indices)
        previous = row
    return rows, palette

def build_sheet(raw):
    rows, palette = decode(raw)
    rgba = bytearray(128 * 128 * 4)
    directions = ((0, 1, False), (4, 5, False), (4, 5, True), (2, 3, False))
    for direction, (idle, walk, mirror) in enumerate(directions):
        for column, frame in enumerate((idle, walk, idle, walk)):
            for y in range(32):
                for x in range(32):
                    source_x = frame * 32 + (31 - x if mirror else x)
                    index = rows[y][source_x]
                    offset = ((direction * 32 + y) * 128 + column * 32 + x) * 4
                    rgba[offset:offset + 4] = bytes((*palette[index], 0 if index == 0 else 255))
    scanlines = b"".join(b"\x00" + rgba[y * 512:(y + 1) * 512] for y in range(128))
    return (PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b""))

def convert(source, output, *, force=False):
    source, output = Path(source), Path(output)
    if source.is_symlink() or not source.is_file() or source.stat().st_size > MAX_SIZE:
        raise SpriteFormatError("source must be a small regular local PNG")
    if output.is_symlink() or (output.exists() and not force):
        raise SpriteFormatError("refusing to overwrite output without --force")
    original = source.read_bytes()
    result = build_sheet(original)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(result)
    return {"source_sha256": hashlib.sha256(original).hexdigest(),
            "output_sha256": hashlib.sha256(result).hexdigest(),
            "source_dimensions": [192, 32], "output_dimensions": [128, 128],
            "source_frames": 6, "output_frames": 16,
            "rights_reviewed": False, "redistribution_authorised": False,
            "native_gameplay_verified": False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    info = convert(args.source, args.output, force=args.force)
    if args.manifest:
        if args.manifest.is_symlink() or args.manifest.exists():
            parser.error("manifest already exists")
        args.manifest.write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps(info, sort_keys=True))

if __name__ == "__main__":
    main()

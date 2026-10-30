"""Asset-free regression coverage for the HnS indexed PNG to RMXP converter."""
import importlib.util
from pathlib import Path
import hashlib
import struct
import tempfile
import unittest
import zlib

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "convert_hns_overworld.py"
spec = importlib.util.spec_from_file_location("convert_hns_overworld", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def atlas(width=192):
    palette = bytes((152,208,160, 220,0,0, 0,220,0, 0,0,220,
                     220,220,0, 220,0,220, 0,220,220, 255,255,255, 0,0,0))
    data = bytearray()
    for _ in range(32):
        indices = []
        for x in range(width):
            value = min(x // 32 + 1, 6)
            if x // 32 == 4 and x % 32 == 0:
                value = 7
            if x // 32 == 4 and x % 32 == 31:
                value = 8
            indices.append(value)
        data.append(0)
        for x in range(0, width, 2):
            data.append((indices[x] << 4) | indices[x + 1])
    return (mod.PNG + mod.chunk(b"IHDR", struct.pack(">IIBBBBB", width,32,4,3,0,0,0)) +
            mod.chunk(b"PLTE", palette) + mod.chunk(b"IDAT", zlib.compress(data)) +
            mod.chunk(b"IEND", b""))

def pixels(png):
    offset, chunks = len(mod.PNG), {}
    while offset < len(png):
        size = struct.unpack_from(">I", png, offset)[0]
        chunks[png[offset + 4:offset + 8]] = png[offset + 8:offset + 8 + size]
        offset += 12 + size
    width, height = struct.unpack_from(">II", chunks[b"IHDR"])
    data = zlib.decompress(chunks[b"IDAT"])
    assert (width, height) == (128,128)
    assert len(data) == 128 * 513
    def pixel(x,y):
        start = y * 513 + 1 + x * 4
        return tuple(data[start:start + 4])
    return pixel

class OverworldConversionTests(unittest.TestCase):
    def test_six_frames_are_decoded(self):
        rows, palette = mod.decode(atlas())
        self.assertEqual([rows[0][x] for x in (5,37,69,101,133,165)], [1,2,3,4,5,6])
        self.assertEqual(palette[0], (152,208,160))

    def test_direction_and_frame_mapping(self):
        pixel = pixels(mod.build_sheet(atlas()))
        colors = [(220,0,0,255),(0,220,0,255),(0,0,220,255),
                  (220,220,0,255),(220,0,220,255),(0,220,220,255)]
        for y, first, second in ((16,0,1),(48,4,5),(80,4,5),(112,2,3)):
            for x, frame in ((16,first),(48,second),(80,first),(112,second)):
                self.assertEqual(pixel(x,y), colors[frame])

    def test_right_facing_is_mirrored(self):
        pixel = pixels(mod.build_sheet(atlas()))
        for x in range(32):
            self.assertEqual(pixel(x,48), pixel(31-x,80))
        self.assertNotEqual(pixel(0,48), pixel(0,80))

    def test_wrong_geometry_rejected(self):
        with self.assertRaisesRegex(mod.SpriteFormatError, "192x32"):
            mod.build_sheet(atlas(160))

    def test_corrupt_crc_rejected(self):
        raw = bytearray(atlas())
        raw[30] ^= 0x10
        with self.assertRaisesRegex(mod.SpriteFormatError, "CRC"):
            mod.build_sheet(bytes(raw))

    def test_truncated_input_rejected(self):
        with self.assertRaises(mod.SpriteFormatError):
            mod.build_sheet(atlas()[:-12])

    def test_conversion_deterministic_no_overwrite_and_source_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)/"source.png"
            output = Path(tmp)/"Graphics"/"Characters"/"Aipom.png"
            source.write_bytes(atlas())
            original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            first = mod.convert(source,output)
            self.assertEqual(first["source_sha256"],original_hash)
            self.assertEqual(first["output_sha256"],hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertFalse(first["native_gameplay_verified"])
            self.assertFalse(first["redistribution_authorised"])
            with self.assertRaises(mod.SpriteFormatError):
                mod.convert(source,output)
            self.assertEqual(first,mod.convert(source,output,force=True))
            self.assertEqual(original_hash,hashlib.sha256(source.read_bytes()).hexdigest())

    def test_symlink_source_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)/"source.png"
            link = Path(tmp)/"link.png"
            source.write_bytes(atlas())
            link.symlink_to(source)
            with self.assertRaises(mod.SpriteFormatError):
                mod.convert(link,Path(tmp)/"output.png")

if __name__ == "__main__":
    unittest.main()

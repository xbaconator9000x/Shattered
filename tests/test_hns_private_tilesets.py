"""Real PNG preflight for private Victory Road tilesheet staging."""
import binascii
import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from convert_hns_victory_road import verify_private_tilesets


def png(width=256, height=64):
    def chunk(kind, payload):
        data = kind + payload
        return struct.pack(">I", len(payload)) + data + struct.pack(">I", binascii.crc32(data) & 0xffffffff)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixels = zlib.compress((b"\\x00" + b"\\x00" * width * 4) * height)
    return b"\\x89PNG\\r\\n\\x1a\\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


class PrivateTilesetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "approved.png"
        self.path.write_bytes(png())
        self.bundle = {"floors": [{"target": {"tileset_image": "approved.png"},
                                    "layers": [[384, 399], [0, 0], [0, 0]]}]}

    def test_verified_capacity_and_hash(self):
        result = verify_private_tilesets(self.bundle, self.root)
        self.assertEqual([256, 64], result["approved.png"]["dimensions"])
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(),
                         result["approved.png"]["sha256"])

    def test_out_of_range_tile_rejected(self):
        self.bundle["floors"][0]["layers"][0][1] = 400
        with self.assertRaisesRegex(ValueError, "exceeds image capacity"):
            verify_private_tilesets(self.bundle, self.root)

    def test_corrupt_png_rejected(self):
        raw = bytearray(self.path.read_bytes())
        raw[29] ^= 1
        self.path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "CRC"):
            verify_private_tilesets(self.bundle, self.root)

    def test_wrong_width_rejected(self):
        self.path.write_bytes(png(128, 64))
        with self.assertRaisesRegex(ValueError, "256px"):
            verify_private_tilesets(self.bundle, self.root)

    def test_missing_tileset_rejected(self):
        self.path.unlink()
        with self.assertRaisesRegex(ValueError, "missing or unsafe"):
            verify_private_tilesets(self.bundle, self.root)


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / "scripts/extract_shattered_field_sprites.py"
spec = importlib.util.spec_from_file_location("field_sprites", PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FieldSpritesTest(unittest.TestCase):
    def test_tile_order_palette_and_transparency(self):
        palette = bytearray(32)
        palette[0:2] = (31).to_bytes(2, "little")
        palette[2:4] = (31 << 5).to_bytes(2, "little")
        tiles = bytearray(256)
        tiles[0] = 0x10
        tiles[32] = 0x11
        tiles[64] = 0x11
        image = mod.decode_frame(tiles, 0, 16, 32, palette)
        self.assertEqual(image.getpixel((0, 0))[3], 0)
        for point in ((1, 0), (8, 0), (0, 8)):
            self.assertEqual(image.getpixel(point), (0, 255, 0, 255))

    def test_unknown_rom_writes_no_output(self):
        with tempfile.TemporaryDirectory() as root:
            rom = Path(root) / "bad.gba"
            rom.write_bytes(bytes(1024))
            output = Path(root) / "output"
            with self.assertRaises(ValueError):
                mod.export(rom, output)
            self.assertFalse(output.exists())

    def test_invalid_pointer_and_truncated_frame_are_rejected(self):
        with self.assertRaises(ValueError):
            mod.pointer(bytes(8), 0)
        with self.assertRaises(ValueError):
            mod.decode_frame(bytes(255), 0, 16, 32, bytes(32))


if __name__ == "__main__":
    unittest.main()

"""Synthetic pixel tests. Upstream assets are intentionally NOT checked in."""
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

try:
    from PIL import Image
except ImportError:
    Image = None

if Image is not None:
    path = Path(__file__).resolve().parents[1] / "scripts/build_authentic_hns_gate_tileset.py"
    spec = importlib.util.spec_from_file_location("hns_gate_tiles", path)
    hns = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = hns
    spec.loader.exec_module(hns)
else:
    hns = None


def sheet(size):
    image = Image.new("P", size, 0)
    image.putpixel((0, 0), 1)
    image.putpixel((7, 0), 2)
    return image


@unittest.skipUnless(Image is not None, "Pillow required for GBA pixel tests")
class AuthenticHnSGateTilesetTest(unittest.TestCase):
    def setUp(self):
        self.primary = sheet((128, 320))
        self.secondary = sheet((128, 192))
        self.palettes = {n: [(i, i + 1, i + 2) for i in range(16)]
                         for n in hns.EXPECTED_PALETTES}

    def test_primary_secondary_palette_selection(self):
        primary = hns.tile_image(0 | (5 << 12), self.primary, self.secondary,
                                 self.palettes, False)
        secondary = hns.tile_image(640 | (12 << 12), self.primary, self.secondary,
                                   self.palettes, False)
        self.assertEqual(primary.getpixel((0, 0)), (*self.palettes[5][1], 255))
        self.assertEqual(secondary.getpixel((0, 0)), (*self.palettes[12][1], 255))

    def test_horizontal_vertical_flip_and_overlay_alpha(self):
        normal = hns.tile_image(0, self.primary, self.secondary, self.palettes, True)
        horizontal = hns.tile_image(0x400, self.primary, self.secondary, self.palettes, True)
        vertical = hns.tile_image(0x800, self.primary, self.secondary, self.palettes, True)
        self.assertEqual(normal.getpixel((0, 0))[3], 255)
        self.assertEqual(normal.getpixel((1, 1))[3], 0)
        self.assertEqual(horizontal.getpixel((7, 0)), normal.getpixel((0, 0)))
        self.assertEqual(vertical.getpixel((0, 7)), normal.getpixel((0, 0)))

    def test_two_layer_metatile_and_nearest_neighbour_scaling(self):
        words = (0, 0x400, 0x800, 0xC00, 0, 0, 0, 0)
        lower = hns.render_metatile(words, self.primary, self.secondary,
                                     self.palettes, False)
        upper = hns.render_metatile(words, self.primary, self.secondary,
                                     self.palettes, True)
        self.assertEqual(lower.size, (32, 32))
        self.assertEqual(lower.getpixel((0, 0)), lower.getpixel((1, 1)))
        self.assertEqual(upper.getpixel((2, 2))[3], 0)

    def test_all_46_source_metatiles_have_xp_layers_and_collision(self):
        primary_meta = bytearray(640 * 16)
        secondary_meta = bytes(255 * 16)
        used = sorted(hns.EXPECTED_PALETTES)
        words = []
        for i in range(46):
            palette = used[i % len(used)]
            tile_id = 640 if palette >= 7 else 0
            struct.pack_into("<8H", primary_meta, i * 16,
                             *([tile_id | (palette << 12)] * 4 + [0] * 4))
            words.append(i | ((i % 2) << 10))
        image, mapping, summary = hns.build_layers(words, bytes(primary_meta),
            secondary_meta, self.primary, self.secondary, self.palettes)
        self.assertEqual(summary["source_metatiles"], 46)
        self.assertEqual(summary["source_palette_ids"], used)
        self.assertEqual(image.width, 256)
        self.assertEqual(len(mapping), 46)
        self.assertEqual(mapping["0:0:0"]["tables"][0]["passage"], 0)
        self.assertEqual(mapping["1:1:0"]["tables"][0]["passage"], 15)
        self.assertTrue(all(item["layers"][0] >= 384 for item in mapping.values()))

    def test_bad_palette_or_metatile_inventory_rejected(self):
        with self.assertRaisesRegex(ValueError, "Missing source palette"):
            hns.tile_image(3 << 12, self.primary, self.secondary, self.palettes, True)
        with self.assertRaisesRegex(ValueError, "Unexpected source metatile"):
            hns.build_layers([0], bytes(640 * 16), bytes(255 * 16),
                             self.primary, self.secondary, self.palettes)

    def test_palette_and_git_blob_validation(self):
        valid = b"JASC-PAL\n0100\n16\n" + b"1 2 3\n" * 16
        self.assertEqual(hns.read_palette(valid)[0], (1, 2, 3))
        with self.assertRaises(ValueError):
            hns.read_palette(valid.replace(b"16\n", b"15\n"))
        self.assertEqual(hns.blob_sha(b"hello"),
                         "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")


if __name__ == "__main__":
    unittest.main()

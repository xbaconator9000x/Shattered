"""Synthetic HnS metatile-to-RMXP rendering regression tests (no game assets)."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
try:
    from PIL import Image
    from render_hns_tiles import build
except ImportError:
    Image = None
    build = None


@unittest.skipIf(Image is None, "Pillow is installed in dedicated HnS rendering CI")
class RenderHnsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "data/layouts/Test").mkdir(parents=True)
        for group in ("primary", "secondary"):
            directory = self.root / group
            (directory / "palettes").mkdir(parents=True)
            image = Image.new("P", (16, 8), 0)
            for x in range(8):
                image.putpixel((x, 0), 1)
            image.save(directory / "tiles.png")
            (directory / "metatiles.bin").write_bytes(struct.pack("<8H", *([0] * 8)))
            (directory / "metatile_attributes.bin").write_bytes(b"\x00\x00")
            for palette_id in range(16):
                colors = ["0 0 0"] * 16
                colors[1] = "255 0 0"
                (directory / "palettes" / f"{palette_id:02d}.pal").write_text(
                    "JASC-PAL\n0100\n16\n" + "\n".join(colors) + "\n")
        layout = {"id": "LAYOUT_TEST", "width": 1, "height": 1,
                  "blockdata_filepath": "data/layouts/Test/map.bin",
                  "primary_tileset": "gPrimary", "secondary_tileset": "gSecondary"}
        (self.root / "data/layouts/layouts.json").write_text(json.dumps({"layouts": [layout]}))
        (self.root / "data/layouts/Test/map.bin").write_bytes(struct.pack("<H", 0))
        self.base = self.root / "base.json"
        self.base.write_text(json.dumps({
            "target": {"tileset_name": "approved", "tileset_image": "approved.png"},
            "passage_by_metatile": {"0": 0}}))
        self.png = self.root / "approved.png"
        self.mapping = self.root / "approved.json"

    def convert(self):
        return build(self.root, ["LAYOUT_TEST"], "primary", "secondary",
                     self.base, self.png, self.mapping)

    def test_generates_scaled_png_and_mapping(self):
        result = self.convert()
        self.assertEqual([384, 385, 0], result["entries"]["0:0:0"]["layers"])
        with Image.open(self.png) as png:
            self.assertEqual((256, 32), png.size)
            self.assertEqual((255, 0, 0, 255), png.getpixel((0, 0)))
        self.assertFalse(result["private_hns_art_manifest"]["in_engine_visual_and_collision_verified"])
        import hashlib
        image_sha = hashlib.sha256(self.png.read_bytes()).hexdigest()
        self.assertEqual(image_sha, result["target"]["tileset_sha256"])
        self.assertEqual(image_sha, result["private_hns_art_manifest"]["rendered_tileset_sha256"])
        self.assertEqual(image_sha, json.loads(self.mapping.read_text())["target"]["tileset_sha256"])

    def test_collision_bit_blocks_tile(self):
        (self.root / "data/layouts/Test/map.bin").write_bytes(struct.pack("<H", 1 << 10))
        result = self.convert()
        self.assertEqual(15, result["entries"]["0:1:0"]["tables"][0]["passage"])

    def test_covered_layer_inherits_blocking_passage(self):
        (self.root / "primary/metatile_attributes.bin").write_bytes(struct.pack("<H", 0x1000))
        (self.root / "data/layouts/Test/map.bin").write_bytes(struct.pack("<H", 1 << 10))
        result = self.convert()
        self.assertEqual({"passage": 15, "priority": 0, "terrain": 0},
                         result["entries"]["0:1:0"]["tables"][1])

    def test_missing_reviewed_collision_fails(self):
        self.base.write_text(json.dumps({
            "target": {"tileset_name": "approved", "tileset_image": "approved.png"},
            "passage_by_metatile": {}}))
        with self.assertRaisesRegex(ValueError, "explicit reviewed entries"):
            self.convert()
        self.assertFalse(self.png.exists())

    def test_invalid_source_blockdata_fails(self):
        (self.root / "data/layouts/Test/map.bin").write_bytes(b"\x00")
        with self.assertRaisesRegex(ValueError, "incorrect blockdata"):
            self.convert()

    def test_victory_road_floor_targets_share_verified_image_sha(self):
        targets = {name: {"tileset_name": "approved", "tileset_image": "approved.png"}
                   for name in ("MAP_VICTORY_ROAD_KANTO_1F_HNS",
                                "MAP_VICTORY_ROAD_KANTO_B1F_HNS",
                                "MAP_VICTORY_ROAD_KANTO_B2F_HNS")}
        self.base.write_text(json.dumps({"floors": targets,
                                         "passage_by_metatile": {"0": 0}}))
        result = self.convert()
        import hashlib
        actual = hashlib.sha256(self.png.read_bytes()).hexdigest()
        self.assertEqual({actual}, {t["tileset_sha256"] for t in result["floors"].values()})
        self.assertEqual(result["floors"], json.loads(self.mapping.read_text())["floors"])

    def test_rejects_mismatched_output_image_name(self):
        self.base.write_text(json.dumps({
            "target": {"tileset_name": "different", "tileset_image": "different.png"},
            "passage_by_metatile": {"0": 0}}))
        with self.assertRaisesRegex(ValueError, "output PNG filename"):
            self.convert()
        self.assertFalse(self.png.exists())
        self.assertFalse(self.mapping.exists())

    def test_rejects_conflicting_reviewed_sha(self):
        self.base.write_text(json.dumps({
            "target": {"tileset_name": "approved", "tileset_image": "approved.png",
                       "tileset_sha256": "0" * 64},
            "passage_by_metatile": {"0": 0}}))
        with self.assertRaisesRegex(ValueError, "SHA-256 conflicts"):
            self.convert()
        self.assertFalse(self.png.exists())
        self.assertFalse(self.mapping.exists())

    def test_rejects_identical_png_and_mapping_paths(self):
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            build(self.root, ["LAYOUT_TEST"], "primary", "secondary",
                  self.base, self.png, self.png)
        self.assertFalse(self.png.exists())

    def test_rejects_unreviewed_second_floor_tileset(self):
        self.base.write_text(json.dumps({
            "floors": {
                "MAP_1": {"tileset_name": "approved", "tileset_image": "approved.png"},
                "MAP_2": {"tileset_name": "other", "tileset_image": "other.png"}},
            "passage_by_metatile": {"0": 0}}))
        with self.assertRaisesRegex(ValueError, "output PNG filename"):
            self.convert()
        self.assertFalse(self.png.exists())

    def test_no_overwrite(self):
        self.convert()
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            self.convert()


if __name__ == "__main__":
    unittest.main()

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

spec = importlib.util.spec_from_file_location(
    "preview_hns_native_maps", Path(__file__).resolve().parents[1] / "scripts" / "preview_hns_native_maps.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class ReviewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        tiles = self.root / "tilesets"
        tiles.mkdir()
        image = Image.new("RGBA", (256, 32), (255, 0, 0, 255))
        image.paste((0, 0, 255, 255), (32, 0, 64, 32))
        image.save(tiles / "Demo.png")
        sha = hashlib.sha256((tiles / "Demo.png").read_bytes()).hexdigest()
        self.map = {
            "dimensions": {"width": 2, "height": 2},
            "layers": [[384, 385, 384, 384], [0, 0, 0, 0], [0, 0, 0, 0]],
            "source_collision": [0, 0, 1, 0],
            "tileset_tables": {"0": [0, 0, 0], "384": [0, 0, 0], "385": [0, 0, 0]},
            "warps": [{"x": 1, "y": 1}],
            "target": {"tileset_image": "Demo.png", "tileset_sha256": sha},
        }
        self.gate = {"format": "shattered-hns-rmxp-map", **self.map}
        self.road = {"format": "shattered-hns-victory-road-rmxp-bundle", "floors": [self.map] * 3}
        self.gate_path = self.root / "gate.json"
        self.road_path = self.root / "road.json"
        self.tiles = tiles
        self.out = self.root / "review"
        self.write()

    def write(self):
        self.gate_path.write_text(json.dumps(self.gate))
        self.road_path.write_text(json.dumps(self.road))

    def build(self):
        return preview.build_review(self.gate_path, self.road_path, self.tiles, self.out)

    def test_renders_four_review_maps_without_touching_sources(self):
        original = [p.read_bytes() for p in (self.gate_path, self.road_path, self.tiles / "Demo.png")]
        manifest = self.build()
        self.assertEqual(set(preview.MAPS), set(manifest["maps"]))
        self.assertFalse(manifest["imported_into_game"])
        self.assertTrue((self.out / "review_contact_sheet.png").is_file())
        with Image.open(self.out / "gate_clean.png") as image:
            self.assertEqual(image.size, (64, 64))
            self.assertEqual(image.getpixel((5, 5)), (255, 0, 0, 255))
            self.assertEqual(image.getpixel((37, 5)), (0, 0, 255, 255))
        with Image.open(self.out / "gate_collision_warps.png") as image:
            self.assertNotEqual(image.getpixel((5, 37)), (255, 0, 0, 255))
        self.assertEqual(original, [p.read_bytes() for p in (self.gate_path, self.road_path, self.tiles / "Demo.png")])

    def test_rejects_wrong_png_sha_without_partial_output(self):
        self.gate["target"]["tileset_sha256"] = "0" * 64
        self.write()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_invalid_tile_id(self):
        self.gate["layers"][0][0] = 900
        self.write()
        with self.assertRaisesRegex(ValueError, "beyond reviewed PNG"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_incomplete_layers(self):
        self.gate["layers"][1] = [0]
        self.write()
        with self.assertRaisesRegex(ValueError, "three-layer"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_unsafe_symlinked_image(self):
        (self.tiles / "Demo.png").unlink()
        (self.tiles / "Demo.png").symlink_to(self.root / "missing.png")
        with self.assertRaisesRegex(ValueError, "unsafe local tileset"):
            self.build()

    def test_refuses_existing_review_directory(self):
        self.out.mkdir()
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.build()

    def test_rejects_invalid_warp_coordinates(self):
        self.gate["warps"][0]["x"] = 3
        self.write()
        with self.assertRaisesRegex(ValueError, "warp lies outside"):
            self.build()

    def test_rejects_corrupt_png_even_when_sha_matches(self):
        path = self.tiles / "Demo.png"
        path.write_bytes(path.read_bytes()[:30])
        self.gate["target"]["tileset_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.write()
        with self.assertRaisesRegex(ValueError, "unreadable or corrupt"):
            self.build()


if __name__ == "__main__":
    unittest.main()

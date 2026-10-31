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
        source_revision = "167aa6d537b109bb229c231ddce4616974c4da71"
        source_repo = "PokemonHnS-Development/pokehns-expansion"

        def map_fixture(width, height, native_id, warp_count):
            cells = width * height
            ground = [384] * cells
            ground[1] = 385
            collision = [0] * cells
            collision[width] = 1
            return {
                "dimensions": {"width": width, "height": height, "tile_pixels": 32},
                "layers": [ground, [0] * cells, [0] * cells],
                "source_collision": collision,
                "tileset_tables": {"0": [0, 0, 0], "384": [0, 0, 0], "385": [0, 0, 0]},
                "warps": [{"x": i + 1, "y": 1} for i in range(warp_count)],
                "target": {"map_id": native_id, "tileset_image": "Demo.png",
                           "tileset_sha256": sha},
                "source": {"map_sha256": "a" * 64, "blockdata_sha256": "b" * 64},
            }

        self.gate = {"format": "shattered-hns-rmxp-map",
                     **map_fixture(22, 21, 300, 5)}
        self.gate["source"].update({
            "repository": "https://github.com/" + source_repo,
            "revision": source_revision,
            "map_path": "data/maps/ReceptionGate_hns/map.json",
            "blockdata_path": "data/layouts/ReceptionGate_hns/map.bin",
            "layout_id": "LAYOUT_RECEPTION_GATE_HNS",
        })
        floor_specs = (
            ("1F", 50, 30, 301, 10),
            ("B1F", 60, 30, 302, 10),
            ("B2F", 40, 50, 303, 2),
        )
        floors = []
        for name, width, height, native_id, count in floor_specs:
            floor = map_fixture(width, height, native_id, count)
            floor["source_map_id"] = f"MAP_VICTORY_ROAD_KANTO_{name}_HNS"
            floor["source_layout_id"] = f"LAYOUT_VICTORY_ROAD_KANTO_{name}_HNS"
            floors.append(floor)
        self.road = {"format": "shattered-hns-victory-road-rmxp-bundle",
                     "source_repository": source_repo,
                     "source_revision": source_revision, "floors": floors}
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
            self.assertEqual(image.size, (22 * 32, 21 * 32))
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
        self.gate["warps"][0]["x"] = 22
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



    def test_rejects_wrong_source_floor_order(self):
        self.road["floors"][0], self.road["floors"][1] = (
            self.road["floors"][1], self.road["floors"][0])
        self.write()
        with self.assertRaisesRegex(ValueError, "wrong or reordered source floor"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_unrelated_gate_artwork_metadata(self):
        self.gate["source"]["map_path"] = "data/maps/SomeOtherGate/map.json"
        self.write()
        with self.assertRaisesRegex(ValueError, "source identity"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_incorrect_pinned_map_geometry(self):
        self.road["floors"][2]["dimensions"]["height"] = 49
        self.write()
        with self.assertRaisesRegex(ValueError, "wrong pinned source dimensions"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_missing_source_warps(self):
        self.road["floors"][0]["warps"].pop()
        self.write()
        with self.assertRaisesRegex(ValueError, "wrong pinned source warp count"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_source_revision_drift(self):
        self.road["source_revision"] = "0" * 40
        self.write()
        with self.assertRaisesRegex(ValueError, "source identity"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_native_map_id_overlap(self):
        self.road["floors"][1]["target"]["map_id"] = 300
        self.write()
        with self.assertRaisesRegex(ValueError, "overlapping native review map IDs"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_missing_raw_source_hash(self):
        del self.road["floors"][1]["source"]["blockdata_sha256"]
        self.write()
        with self.assertRaisesRegex(ValueError, "source file SHA-256 provenance"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_out_of_range_gba_collision(self):
        self.gate["source_collision"][0] = 4
        self.write()
        with self.assertRaisesRegex(ValueError, "source collision grid"):
            self.build()
        self.assertFalse(self.out.exists())

if __name__ == "__main__":
    unittest.main()

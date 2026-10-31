import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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
                "warps": [{"source_warp_index": i, "x": i + 1, "y": 1} for i in range(warp_count)],
                "target": {"map_id": native_id, "tileset_image": "Demo.png",
                           "tileset_sha256": sha},
                "source": {"map_sha256": "a" * 64, "blockdata_sha256": "b" * 64},
            }

        self.gate = {"format": "shattered-hns-rmxp-map",
                     **map_fixture(22, 21, 300, 5)}
        gate_exits = (
            ("west", "MAP_ROUTE28_HNS"),
            ("east", "MAP_ROUTE22_HNS"),
            ("north", "MAP_VICTORY_ROAD_KANTO_B2F_HNS"),
            ("north", "MAP_VICTORY_ROAD_KANTO_B2F_HNS"),
            ("south", "MAP_ROUTE26NORTH_HNS"),
        )
        for warp, (direction, destination) in zip(self.gate["warps"], gate_exits):
            warp["direction"] = direction
            warp["source_destination"] = destination
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


    def test_rejects_wrong_gate_exit_destination(self):
        self.gate["warps"][1]["source_destination"] = "MAP_ROUTE28_HNS"
        self.write()
        with self.assertRaisesRegex(ValueError, "exit directions/destinations"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_duplicate_source_warp_position(self):
        self.road["floors"][0]["warps"][1]["x"] = self.road["floors"][0]["warps"][0]["x"]
        self.write()
        with self.assertRaisesRegex(ValueError, "duplicate source warp coordinates"):
            self.build()
        self.assertFalse(self.out.exists())

    def test_rejects_swapped_source_warp_indices(self):
        self.road["floors"][1]["warps"][1]["source_warp_index"] = 0
        self.write()
        with self.assertRaisesRegex(ValueError, "source warp indices"):
            self.build()
        self.assertFalse(self.out.exists())


    def private_source_fixture(self):
        """Synthetic byte pins, deliberately injected ONLY into the tests."""
        root = self.root / "source"
        pins = {"source_repository": preview.SOURCE_REPOSITORY,
                "source_revision": preview.SOURCE_REVISION, "layouts": {}}
        first_source_file = None
        for data, (_map_id, layout, _dimensions, _warp_count) in zip(
                [self.gate, *self.road["floors"]], preview.SOURCE_MAPS):
            map_rel = (data["source"]["map_path"] if data is self.gate
                       else f"data/maps/{layout}/map.json")
            bin_rel = (data["source"]["blockdata_path"] if data is self.gate
                       else f"data/layouts/{layout}/map.bin")
            cells = data["dimensions"]["width"] * data["dimensions"]["height"]
            data["source_elevation"] = [0] * cells
            for warp in data["warps"]:
                warp.setdefault("source_destination", "MAP_TEST_DESTINATION")
            source_warps = [
                {"x": warp["x"], "y": warp["y"], "dest_map": warp["source_destination"]}
                for warp in data["warps"]
            ]
            map_bytes = json.dumps({"warp_events": source_warps}, sort_keys=True).encode("utf-8")
            bin_bytes = b"".join(
                ((collision << 10) | (elevation << 12)).to_bytes(2, "little")
                for collision, elevation in zip(data["source_collision"], data["source_elevation"])
            )
            paths = ((map_rel, map_bytes), (bin_rel, bin_bytes))
            for rel, payload in paths:
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
                if first_source_file is None:
                    first_source_file = path
            data["source"]["map_sha256"] = hashlib.sha256(map_bytes).hexdigest()
            data["source"]["blockdata_sha256"] = hashlib.sha256(bin_bytes).hexdigest()
            pins["layouts"][layout] = {
                "map_json_path": map_rel,
                "map_json_sha1": preview.git_blob_sha1(map_bytes),
                "blockdata_path": bin_rel,
                "blockdata_sha1": preview.git_blob_sha1(bin_bytes),
            }
        pin_path = self.root / "source_pins.json"
        pin_path.write_text(json.dumps(pins))
        self.write()
        return root, pin_path, first_source_file

    def test_accepts_verified_private_source_bytes(self):
        root, pin_path, _first = self.private_source_fixture()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            manifest = preview.build_review(
                self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertTrue(manifest["raw_upstream_source_bytes_verified_by_preview"])
        self.assertTrue(manifest["raw_collision_elevation_and_warps_verified"])
        self.assertFalse(manifest["rmxp_tiles_recomputed_from_raw_source"])
        self.assertFalse(manifest["native_gameplay_verified"])

    def test_rejects_modified_private_source_blob(self):
        root, pin_path, first = self.private_source_fixture()
        first.write_bytes(first.read_bytes() + b"modified")
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "Git blob SHA-1 mismatch"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_bundle_source_hash_disagreement(self):
        root, pin_path, _first = self.private_source_fixture()
        self.gate["source"]["map_sha256"] = "0" * 64
        self.write()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "raw source SHA-256 mismatch"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_symlinked_private_source_file(self):
        root, pin_path, first = self.private_source_fixture()
        external = self.root / "external-source.bin"
        external.write_bytes(first.read_bytes())
        first.unlink()
        first.symlink_to(external)
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "symlinked private HnS source"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_gate_path_disagreement_with_pins(self):
        root, pin_path, _first = self.private_source_fixture()
        self.gate["source"]["map_path"] = "data/maps/FakeGate/map.json"
        self.write()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "source identity"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_forged_converted_collision(self):
        root, pin_path, _first = self.private_source_fixture()
        self.road["floors"][1]["source_collision"][2] = 1
        self.write()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "collision/elevation differs"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_forged_converted_elevation(self):
        root, pin_path, _first = self.private_source_fixture()
        self.gate["source_elevation"][2] = 5
        self.write()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "collision/elevation differs"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_forged_source_warp_coordinate(self):
        root, pin_path, _first = self.private_source_fixture()
        self.road["floors"][2]["warps"][0]["x"] += 1
        self.write()
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "converted source warp differs"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

    def test_rejects_wrong_pinned_source_revision(self):
        root, pin_path, _first = self.private_source_fixture()
        pins = json.loads(pin_path.read_text())
        pins["source_revision"] = "0" * 40
        pin_path.write_text(json.dumps(pins))
        with patch.object(preview, "SOURCE_PINS_PATH", pin_path):
            with self.assertRaisesRegex(ValueError, "source pins differ"):
                preview.build_review(
                    self.gate_path, self.road_path, self.tiles, self.out, source_root=root)
        self.assertFalse(self.out.exists())

if __name__ == "__main__":
    unittest.main()

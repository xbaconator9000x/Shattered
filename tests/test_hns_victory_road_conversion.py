import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_hns_victory_road import FLOORS, MAP_IDS, LAYOUT_IDS, EXPECTED_DIMENSIONS
from convert_hns_victory_road import build_bundle, FORMAT


class VictoryRoadConversionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.maps = self.root / "data/maps"
        self.layouts = self.root / "data/layouts"
        self.mapping_path = self.root / "mapping.json"
        layouts = []
        for i, (name, map_id, layout_id, (width, height)) in enumerate(
                zip(FLOORS, MAP_IDS, LAYOUT_IDS, EXPECTED_DIMENSIONS)):
            (self.maps / name).mkdir(parents=True)
            (self.layouts / name).mkdir(parents=True)
            layouts.append({"id": layout_id, "width": width, "height": height})
            self.write_map(i, [])
            cells = [1] * (width * height)
            cells[0] = 2 | (1 << 10) | (2 << 12)
            (self.layouts / name / "map.bin").write_bytes(struct.pack("<" + "H" * len(cells), *cells))
        (self.layouts / "layouts.json").write_text(json.dumps({"layouts": layouts}))
        self.write_map(0, [self.warp(MAP_IDS[1], "0", 1, 1),
                           self.warp("MAP_ROUTE23_HNS", "0", 2, 2)])
        self.write_map(1, [self.warp(MAP_IDS[0], "0", 1, 1),
                           self.warp(MAP_IDS[2], "1", 2, 2)])
        self.write_map(2, [self.warp("MAP_RECEPTION_GATE_HNS", "2", 1, 1),
                           self.warp(MAP_IDS[1], "1", 2, 2)])
        def table(passage):
            return {"passage": passage, "priority": 0, "terrain": 0}
        self.mapping = {
            "floors": {map_id: {"map_id": 400 + i, "tileset_template_id": 1,
                               "tileset_name": "reviewed_cave",
                               "tileset_image": "reviewed_cave.png",
                               "tileset_sha256": "0" * 64}
                       for i, map_id in enumerate(MAP_IDS)},
            "entries": {
                "1:0:0": {"layers": [384, 385, 0],
                          "tables": [table(0), table(15), table(0)]},
                "2:1:2": {"layers": [386, 387, 0],
                          "tables": [table(15), table(15), table(0)]},
            },
            "warp_targets": {
                f"{MAP_IDS[0]}:0": {"map_id": 401, "x": 1, "y": 1},
                f"{MAP_IDS[0]}:1": {"map_id": 500, "x": 1, "y": 1},
                f"{MAP_IDS[1]}:0": {"map_id": 400, "x": 1, "y": 1},
                f"{MAP_IDS[1]}:1": {"map_id": 402, "x": 2, "y": 2},
                f"{MAP_IDS[2]}:0": {"map_id": 223, "x": 10, "y": 1},
                f"{MAP_IDS[2]}:1": {"map_id": 401, "x": 2, "y": 2},
            }
        }
        self.write_mapping()

    def warp(self, dest, warp_id, x, y):
        return {"x": x, "y": y, "dest_map": dest, "dest_warp_id": warp_id}

    def write_map(self, index, warps):
        path = self.maps / FLOORS[index] / "map.json"
        path.write_text(json.dumps({"id": MAP_IDS[index], "layout": LAYOUT_IDS[index],
                                    "warp_events": warps}))

    def write_mapping(self):
        self.mapping_path.write_text(json.dumps(self.mapping))

    def test_default_rejects_non_pinned_synthetic_source(self):
        with self.assertRaisesRegex(ValueError, "unrecognized source layouts.json Git blob"):
            build_bundle(self.root, self.mapping_path)

    def test_three_floors_preserve_layers_collision_and_source_warps(self):
        result = build_bundle(self.root, self.mapping_path, verify_source=False)
        self.assertEqual(FORMAT, result["format"])
        self.assertEqual(3, len(result["floors"]))
        self.assertEqual(6, sum(len(f["warps"]) for f in result["floors"]))
        for floor, (width, height) in zip(result["floors"], EXPECTED_DIMENSIONS):
            self.assertEqual(width * height, len(floor["layers"][0]))
            self.assertEqual([386, 387, 0], [layer[0] for layer in floor["layers"]])
            self.assertEqual(1, floor["source_collision"][0])
            self.assertEqual(2, floor["source_elevation"][0])
            self.assertEqual([15, 0, 0], floor["tileset_tables"]["386"])
            self.assertEqual(64, len(floor["source"]["blockdata_sha256"]))
        self.assertTrue(result["rights_and_collision_review_required"])
        self.assertFalse(result["native_compiled"])
        self.assertFalse(result["runtime_verified"])

    def test_invisible_blocking_tile_rejected(self):
        self.mapping["entries"]["2:1:2"]["tables"][2]["passage"] = 15
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "transparent XP tile"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_missing_or_invalid_reviewed_tileset_digest_rejected(self):
        target = self.mapping["floors"][MAP_IDS[0]]
        del target["tileset_sha256"]
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "missing reviewed tileset SHA-256"):
            build_bundle(self.root, self.mapping_path, verify_source=False)
        target["tileset_sha256"] = "not-a-real-sha"
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "missing reviewed tileset SHA-256"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_missing_tile_mapping_rejected(self):
        del self.mapping["entries"]["2:1:2"]
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "missing tile mapping entry"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_truncated_source_blockdata_rejected(self):
        path = self.layouts / FLOORS[1] / "map.bin"
        path.write_bytes(path.read_bytes()[:-2])
        with self.assertRaisesRegex(ValueError, "wrong GBA blockdata length"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_missing_external_landing_rejected(self):
        del self.mapping["warp_targets"][f"{MAP_IDS[2]}:0"]
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "missing explicit XP warp landing"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_wrong_internal_floor_target_rejected(self):
        self.mapping["warp_targets"][f"{MAP_IDS[1]}:1"]["map_id"] = 999
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "disagrees with linked"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_outside_internal_floor_landing_rejected(self):
        self.mapping["warp_targets"][f"{MAP_IDS[0]}:0"]["x"] = 60
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "outside linked Victory Road floor"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_wrong_in_bounds_internal_warp_landing_rejected(self):
        self.mapping["warp_targets"][f"{MAP_IDS[1]}:1"]["x"] = 10
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "not at/adjacent to source destination warp"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_duplicate_native_map_id_rejected(self):
        self.mapping["floors"][MAP_IDS[2]]["map_id"] = 400
        self.write_mapping()
        with self.assertRaisesRegex(ValueError, "must be unique"):
            build_bundle(self.root, self.mapping_path, verify_source=False)

    def test_source_warp_graph_breakage_rejected(self):
        self.write_map(1, [self.warp(MAP_IDS[2], "0", 1, 1),
                           self.warp(MAP_IDS[2], "1", 2, 2)])
        with self.assertRaisesRegex(ValueError, "unresolved anomalies"):
            build_bundle(self.root, self.mapping_path, verify_source=False)


if __name__ == "__main__":
    unittest.main()

import json
from unittest import mock
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from convert_hns_reception_gate import (convert, inspect_source, git_blob_sha1,
                                         PINNED_GATE_BLOBS)


class ReceptionGateConversionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.map_json = self.root / "map.json"
        self.layouts_json = self.root / "layouts.json"
        self.map_bin = self.root / "map.bin"
        self.mapping_json = self.root / "mapping.json"
        self.warps = [
            {"x": 11, "y": 19, "dest_map": "MAP_ROUTE26NORTH_HNS", "dest_warp_id": "0"},
            {"x": 11, "y": 1, "dest_map": "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "dest_warp_id": "0"},
            {"x": 10, "y": 1, "dest_map": "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "dest_warp_id": "0"},
            {"x": 1, "y": 9, "dest_map": "MAP_ROUTE28_HNS", "dest_warp_id": "0"},
            {"x": 20, "y": 9, "dest_map": "MAP_ROUTE22_HNS", "dest_warp_id": "0"},
        ]
        self.map_json.write_text(json.dumps({
            "id": "MAP_RECEPTION_GATE_HNS",
            "layout": "LAYOUT_RECEPTION_GATE_HNS",
            "warp_events": self.warps,
        }))
        self.layouts_json.write_text(json.dumps({
            "layouts": [{
                "id": "LAYOUT_RECEPTION_GATE_HNS",
                "width": 22,
                "height": 21,
                "primary_tileset": "gTileset_Johto_Building_Hns",
                "secondary_tileset": "gTileset_PokemonCenter_White_Hns",
            }],
        }))
        self.map_bin.write_bytes(struct.pack("<462H", *([0x0408] * 462)))
        self.mapping = {
            "target": {
                "map_id": 300,
                "tileset_template_id": 1,
                "tileset_name": "SE013_ReceptionGate",
                "tileset_image": "SE013_ReceptionGate.png",
                "tileset_sha256": "a" * 64,
            },
            "destinations": {
                name: {"map_id": index + 1, "x": 4, "y": 5, "direction": 2}
                for index, name in enumerate({
                    "MAP_ROUTE26NORTH_HNS", "MAP_VICTORY_ROAD_KANTO_B2F_HNS",
                    "MAP_ROUTE28_HNS", "MAP_ROUTE22_HNS",
                })
            },
            "entries": {
                "8:1:0": {
                    "layers": [384, 0, 0],
                    "tables": [
                        {"passage": 15, "priority": 0, "terrain": 0},
                        {"passage": 0, "priority": 0, "terrain": 0},
                        {"passage": 0, "priority": 0, "terrain": 0},
                    ],
                },
            },
        }
        # The two source north exits require separate reviewed B2F landings.
        b2f_id = self.mapping["destinations"]["MAP_VICTORY_ROAD_KANTO_B2F_HNS"]["map_id"]
        self.mapping["warp_targets"] = {
            "MAP_RECEPTION_GATE_HNS:1": {"map_id": b2f_id, "x": 30, "y": 46},
            "MAP_RECEPTION_GATE_HNS:2": {"map_id": b2f_id, "x": 31, "y": 47},
        }
        self.mapping_json.write_text(json.dumps(self.mapping))

    def test_gate_git_blob_pins_match_versioned_source_manifest(self):
        pins = json.loads((Path(__file__).resolve().parents[1] /
                           "development" / "hns_source_asset_pins.json").read_text())
        layout = pins["layouts"]["LAYOUT_RECEPTION_GATE_HNS"]
        self.assertEqual(PINNED_GATE_BLOBS, {
            "map": layout["map_json_sha1"],
            "layouts": pins["layouts_sha1"],
            "blockdata": layout["blockdata_sha1"],
        })

    def test_production_conversion_refuses_lookalike_gate_source(self):
        # Same geometry, map ID and warp layout are insufficient to prove HnS
        # provenance. Production conversion must reject a synthetic map.
        with self.assertRaisesRegex(ValueError, "not the pinned HnS source Git blob"):
            inspect_source(self.map_json, self.layouts_json, self.map_bin)
        with self.assertRaisesRegex(ValueError, "not the pinned HnS source Git blob"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)

    def test_exact_git_blob_pins_accept_then_detect_modified_source(self):
        fixture_pins = {
            "map": git_blob_sha1(self.map_json),
            "layouts": git_blob_sha1(self.layouts_json),
            "blockdata": git_blob_sha1(self.map_bin),
        }
        with mock.patch.dict(PINNED_GATE_BLOBS, fixture_pins):
            source = inspect_source(self.map_json, self.layouts_json, self.map_bin)
            self.assertEqual(len(source["warps"]), 5)
            converted = convert(self.map_json, self.layouts_json, self.map_bin,
                                self.mapping_json)
            self.assertEqual(converted["dimensions"]["width"], 22)
            self.map_bin.write_bytes(self.map_bin.read_bytes()[:-2] + b"\x00\x00")
            with self.assertRaisesRegex(ValueError, "blockdata: not the pinned HnS source"):
                inspect_source(self.map_json, self.layouts_json, self.map_bin)

    def test_reads_actual_geometry_and_named_exit_coordinates(self):
        source = inspect_source(self.map_json, self.layouts_json, self.map_bin, verify_source=False)
        self.assertEqual((22, 21), (source["layout"]["width"], source["layout"]["height"]))
        self.assertEqual(["8:1:0"], source["required_mapping_keys"])
        self.assertEqual([
            ("south", 11, 19),
            ("north", 11, 1),
            ("north", 10, 1),
            ("west", 1, 9),
            ("east", 20, 9),
        ], [(w["direction"], w["x"], w["y"]) for w in source["warps"]])

    def test_decodes_blockdata_to_three_layers_and_table_data(self):
        output = convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)
        self.assertEqual([462, 462, 462], [len(layer) for layer in output["layers"]])
        self.assertEqual([384] * 462, output["layers"][0])
        self.assertEqual([0] * 462, output["layers"][1])
        self.assertEqual([1] * 462, output["source_collision"])
        self.assertEqual([0] * 462, output["source_elevation"])
        self.assertEqual([15, 0, 0], output["tileset_tables"]["384"])
        self.assertEqual(5, len(output["warps"]))
        self.assertEqual([0, 1, 2, 3, 4],
                         [warp["source_warp_index"] for warp in output["warps"]])
        self.assertEqual([(30, 46), (31, 47)],
                         [(warp["target"]["x"], warp["target"]["y"])
                          for warp in output["warps"] if warp["direction"] == "north"])
        self.assertEqual("a" * 64, output["target"]["tileset_sha256"])

    def test_missing_generated_tileset_hash_is_rejected(self):
        self.mapping["target"].pop("tileset_sha256")
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "requires a SHA-256"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)

    def test_missing_metatile_mapping_is_rejected(self):
        self.map_bin.write_bytes(struct.pack("<462H", *([0x0409] * 462)))
        with self.assertRaisesRegex(ValueError, "missing tile mapping entry 9:1:0"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)

    def test_same_xp_tile_cannot_have_conflicting_passages(self):
        self.mapping["entries"]["8:1:0"]["tables"][0]["passage"] = 0
        self.mapping["entries"]["8:1:0"]["layers"] = [384, 384, 0]
        self.mapping["entries"]["8:1:0"]["tables"][1]["passage"] = 15
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "XP tile 384 is assigned conflicting"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)

    def test_wrong_map_dimensions_and_binary_length_are_rejected(self):
        layout = json.loads(self.layouts_json.read_text())
        layout["layouts"][0]["width"] = 21
        self.layouts_json.write_text(json.dumps(layout))
        with self.assertRaisesRegex(ValueError, "expected a 22x21 layout"):
            inspect_source(self.map_json, self.layouts_json, self.map_bin, verify_source=False)

    def test_short_blockdata_is_rejected(self):
        self.map_bin.write_bytes(b"\x00\x00")
        with self.assertRaisesRegex(ValueError, "one little-endian word per map cell"):
            inspect_source(self.map_json, self.layouts_json, self.map_bin, verify_source=False)


    def test_missing_source_indexed_north_landing_is_rejected(self):
        self.mapping["warp_targets"].pop("MAP_RECEPTION_GATE_HNS:2")
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "requires explicit per-warp landing"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)

    def test_two_north_warps_cannot_land_on_same_tile(self):
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:2"]["x"] = 30
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:2"]["y"] = 46
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "collapse onto one landing"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json, verify_source=False)



if __name__ == "__main__":
    unittest.main()

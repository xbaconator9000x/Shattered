import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from convert_hns_reception_gate import convert, inspect_source


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
        self.mapping_json.write_text(json.dumps(self.mapping))

    def test_reads_actual_geometry_and_named_exit_coordinates(self):
        source = inspect_source(self.map_json, self.layouts_json, self.map_bin)
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
        output = convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)
        self.assertEqual([462, 462, 462], [len(layer) for layer in output["layers"]])
        self.assertEqual([384] * 462, output["layers"][0])
        self.assertEqual([0] * 462, output["layers"][1])
        self.assertEqual([1] * 462, output["source_collision"])
        self.assertEqual([0] * 462, output["source_elevation"])
        self.assertEqual([15, 0, 0], output["tileset_tables"]["384"])
        self.assertEqual(5, len(output["warps"]))

    def test_two_north_doors_keep_distinct_native_landings(self):
        self.mapping["per_warp_destinations"] = {
            "10,1": {"map_id": 224, "x": 29, "y": 47, "direction": 8},
            "11,1": {"map_id": 224, "x": 30, "y": 46, "direction": 8},
        }
        self.mapping["require_distinct_warp_landings"] = True
        self.mapping_json.write_text(json.dumps(self.mapping))
        output = convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)
        north = {(w["x"], w["y"]): w["target"] for w in output["warps"]
                 if w["direction"] == "north"}
        self.assertEqual((224, 29, 47), tuple(north[(10, 1)][key]
            for key in ("map_id", "x", "y")))
        self.assertEqual((224, 30, 46), tuple(north[(11, 1)][key]
            for key in ("map_id", "x", "y")))

    def test_duplicate_north_landings_fail_closed_in_strict_mode(self):
        self.mapping["require_distinct_warp_landings"] = True
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "distinct native landing"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)

    def test_unknown_source_warp_override_rejected(self):
        self.mapping["per_warp_destinations"] = {
            "15,15": {"map_id": 224, "x": 29, "y": 47, "direction": 8},
        }
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "unknown source coordinate"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)

    def test_missing_metatile_mapping_is_rejected(self):
        self.map_bin.write_bytes(struct.pack("<462H", *([0x0409] * 462)))
        with self.assertRaisesRegex(ValueError, "missing tile mapping entry 9:1:0"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)

    def test_same_xp_tile_cannot_have_conflicting_passages(self):
        self.mapping["entries"]["8:1:0"]["tables"][0]["passage"] = 0
        self.mapping["entries"]["8:1:0"]["layers"] = [384, 384, 0]
        self.mapping["entries"]["8:1:0"]["tables"][1]["passage"] = 15
        self.mapping_json.write_text(json.dumps(self.mapping))
        with self.assertRaisesRegex(ValueError, "XP tile 384 is assigned conflicting"):
            convert(self.map_json, self.layouts_json, self.map_bin, self.mapping_json)

    def test_wrong_map_dimensions_and_binary_length_are_rejected(self):
        layout = json.loads(self.layouts_json.read_text())
        layout["layouts"][0]["width"] = 21
        self.layouts_json.write_text(json.dumps(layout))
        with self.assertRaisesRegex(ValueError, "expected a 22x21 layout"):
            inspect_source(self.map_json, self.layouts_json, self.map_bin)

    def test_short_blockdata_is_rejected(self):
        self.map_bin.write_bytes(b"\x00\x00")
        with self.assertRaisesRegex(ValueError, "one little-endian word per map cell"):
            inspect_source(self.map_json, self.layouts_json, self.map_bin)


if __name__ == "__main__":
    unittest.main()

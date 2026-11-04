import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from resolve_hns_gate_warps import resolve_warp_targets


class ResolveGateWarpTests(unittest.TestCase):
    def setUp(self):
        self.warps = [{"source_destination": dest} for dest in
                      ("MAP_ROUTE26NORTH_HNS", "MAP_VICTORY_ROAD_KANTO_B2F_HNS",
                       "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "MAP_ROUTE28_HNS", "MAP_ROUTE22_HNS")]
        self.mapping = {
            "destinations": {d: {"map_id": i + 10, "x": 4, "y": 5}
                             for i, d in enumerate(dict.fromkeys(w["source_destination"] for w in self.warps))},
            "warp_targets": {
                "MAP_RECEPTION_GATE_HNS:1": {"map_id": 11, "x": 30, "y": 46},
                "MAP_RECEPTION_GATE_HNS:2": {"map_id": 11, "x": 31, "y": 47},
            },
        }

    def test_distinct_north_landings_and_unique_exit_fallback(self):
        result = resolve_warp_targets(self.warps, self.mapping)
        self.assertEqual((30, 46), (result[1]["x"], result[1]["y"]))
        self.assertEqual((31, 47), (result[2]["x"], result[2]["y"]))
        self.assertEqual(12, result[3]["map_id"])
        self.assertEqual(0, result[2]["fade"])

    def test_rejects_missing_second_north_override(self):
        self.mapping["warp_targets"].pop("MAP_RECEPTION_GATE_HNS:2")
        with self.assertRaisesRegex(ValueError, "requires explicit per-warp landing"):
            resolve_warp_targets(self.warps, self.mapping)

    def test_rejects_duplicate_north_landing(self):
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:2"]["x"] = 30
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:2"]["y"] = 46
        with self.assertRaisesRegex(ValueError, "collapse onto one landing"):
            resolve_warp_targets(self.warps, self.mapping)

    def test_rejects_north_map_disagreement(self):
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:2"]["map_id"] = 99
        with self.assertRaisesRegex(ValueError, "disagree on destination map"):
            resolve_warp_targets(self.warps, self.mapping)

    def test_rejects_unknown_source_warp_index(self):
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:5"] = {"map_id": 11, "x": 3, "y": 4}
        with self.assertRaisesRegex(ValueError, "unknown Reception Gate warp_targets"):
            resolve_warp_targets(self.warps, self.mapping)

    def test_rejects_boolean_map_id_and_bad_fade(self):
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:1"]["map_id"] = True
        with self.assertRaisesRegex(ValueError, "invalid target map_id"):
            resolve_warp_targets(self.warps, self.mapping)
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:1"]["map_id"] = 11
        self.mapping["warp_targets"]["MAP_RECEPTION_GATE_HNS:1"]["fade"] = 2
        with self.assertRaisesRegex(ValueError, "invalid target fade"):
            resolve_warp_targets(self.warps, self.mapping)

    def test_all_five_per_warp_destinations_without_defaults(self):
        self.mapping.pop("destinations")
        self.mapping["warp_targets"].update({
            f"MAP_RECEPTION_GATE_HNS:{i}": {"map_id": i + 1, "x": i, "y": i}
            for i in (0, 3, 4)
        })
        self.assertEqual(5, len(resolve_warp_targets(self.warps, self.mapping)))


if __name__ == "__main__":
    unittest.main()

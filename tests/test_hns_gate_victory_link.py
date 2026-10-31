"""Synthetic cross-bundle gate/road transfer tests, not gameplay acceptance."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from validate_hns_gate_victory_link import check


def fixture():
    def floor(name, native_id, width, height):
        return {"source_map_id": name, "target": {"map_id": native_id,
                "tileset_sha256": "a" * 64},
                "dimensions": {"width": width, "height": height},
                "layers": [[384] * (width * height), [0] * (width * height), [0] * (width * height)],
                "source_collision": [0] * (width * height),
                "tileset_tables": {"384": [0, 0, 0]}, "warps": []}
    gate = floor("MAP_RECEPTION_GATE_HNS", 300, 22, 21)
    gate["format"] = "shattered-hns-rmxp-map"
    gate["format_version"] = 1
    gate["warps"] = [
        {"direction": "south", "x": 11, "y": 19, "source_destination": "MAP_ROUTE26NORTH_HNS", "target": {"map_id": 10, "x": 0, "y": 0}},
        {"direction": "north", "x": 11, "y": 1, "source_destination": "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "target": {"map_id": 303, "x": 30, "y": 46}},
        {"direction": "north", "x": 10, "y": 1, "source_destination": "MAP_VICTORY_ROAD_KANTO_B2F_HNS", "target": {"map_id": 303, "x": 31, "y": 47}},
        {"direction": "west", "x": 1, "y": 9, "source_destination": "MAP_ROUTE28_HNS", "target": {"map_id": 11, "x": 0, "y": 0}},
        {"direction": "east", "x": 20, "y": 9, "source_destination": "MAP_ROUTE22_HNS", "target": {"map_id": 12, "x": 0, "y": 0}},
    ]
    b2f = floor("MAP_VICTORY_ROAD_KANTO_B2F_HNS", 303, 40, 50)
    b2f["warps"] = [{"x": 30, "y": 47, "source_destination": "MAP_RECEPTION_GATE_HNS",
                     "source_destination_warp_id": 2,
                     "target": {"map_id": 300, "x": 10, "y": 2}}]
    road = {"format": "shattered-hns-victory-road-rmxp-bundle", "format_version": 1,
            "source_revision": "167aa6d537b109bb229c231ddce4616974c4da71",
            "floors": [floor("MAP_VICTORY_ROAD_KANTO_1F_HNS", 301, 50, 30),
                       floor("MAP_VICTORY_ROAD_KANTO_B1F_HNS", 302, 60, 30), b2f]}
    return gate, road


class GateRoadLinkTests(unittest.TestCase):
    def setUp(self):
        self.gate, self.road = fixture()

    def test_bidirectional_static_link(self):
        result = check(self.gate, self.road)
        self.assertEqual(2, result["gate_north_exits_checked"])
        self.assertFalse(result["native_gameplay_verified"])

    def test_distinct_north_exits_cannot_share_b2f_landing(self):
        self.gate["warps"][2]["target"].update(x=30, y=46)
        with self.assertRaisesRegex(ValueError, "collapse onto one B2F landing"):
            check(self.gate, self.road)

    def test_wrong_native_b2f_target(self):
        self.gate["warps"][1]["target"]["map_id"] = 999
        with self.assertRaisesRegex(ValueError, "does not point to native B2F"):
            check(self.gate, self.road)

    def test_landing_on_warp_event(self):
        self.gate["warps"][1]["target"].update(x=30, y=47)
        with self.assertRaisesRegex(ValueError, "adjacent"):
            check(self.gate, self.road)

    def test_blocked_ground_not_hidden_by_overlay(self):
        b2f = self.road["floors"][2]
        idx = 46 * 40 + 30
        b2f["tileset_tables"]["385"] = [0, 1, 0]
        b2f["layers"][1][idx] = 385
        b2f["tileset_tables"]["384"] = [15, 0, 0]
        with self.assertRaisesRegex(ValueError, "blocked by native XP passage"):
            check(self.gate, self.road)

    def test_source_collision_blocked(self):
        self.road["floors"][2]["source_collision"][46 * 40 + 30] = 1
        with self.assertRaisesRegex(ValueError, "source collision"):
            check(self.gate, self.road)

    def test_return_landing_wrong_source_warp(self):
        self.road["floors"][2]["warps"][0]["source_destination_warp_id"] = 0
        with self.assertRaisesRegex(ValueError, "not refer to a north gate warp"):
            check(self.gate, self.road)

    def test_reject_missing_image_hash(self):
        del self.gate["target"]["tileset_sha256"]
        with self.assertRaisesRegex(ValueError, "missing rendered tileset SHA"):
            check(self.gate, self.road)

    def test_overlapping_native_ids(self):
        self.road["floors"][2]["target"]["map_id"] = 300
        with self.assertRaisesRegex(ValueError, "native map IDs overlap"):
            check(self.gate, self.road)


if __name__ == "__main__":
    unittest.main()

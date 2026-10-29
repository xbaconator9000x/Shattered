import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_world_links import build_plan

A, B = "source-map-a", "source-map-b"
REF = {"schema_version": 1, "maps": [
    {"id": A, "width": 20, "height": 20},
    {"id": B, "width": 12, "height": 12}],
    "links": [
        {"id": "door-one", "from": {"mapId": A, "x": 3, "y": 4},
         "to": {"mapId": B, "x": 2, "y": 3}, "two_way": True},
        {"id": "door-two", "from": {"mapId": A, "x": 9, "y": 4},
         "to": {"mapId": B, "x": 8, "y": 3}, "two_way": False}]}
MAP = {"schema_version": 1, "maps": {
    A: {"target_map_id": 10, "width": 20, "height": 20},
    B: {"target_map_id": 11, "width": 12, "height": 12}},
    "links": {"door-one": {
        "from": {"x": 3, "y": 4, "landing_x": 3, "landing_y": 5, "direction": 2},
        "to": {"x": 2, "y": 3, "landing_x": 2, "landing_y": 4, "direction": 8}}}}

class WorldLinksTest(unittest.TestCase):
    def test_two_way_explicit_arrival_not_trigger(self):
        plan = build_plan(REF, MAP)
        self.assertEqual((1, 1), (plan["mapped_links"], len(plan["unmapped_links"])))
        self.assertEqual(2, len(plan["events"]))
        forward = next(e for e in plan["events"] if e["side"] == "F")
        self.assertEqual({"map_id": 11, "x": 2, "y": 4, "direction": 8, "fade": 0},
                         forward["destination"])
        reverse = next(e for e in plan["events"] if e["side"] == "R")
        self.assertEqual((10, 3, 5), (reverse["destination"]["map_id"],
                                      reverse["destination"]["x"], reverse["destination"]["y"]))
        self.assertEqual("uninstalled_unverified", plan["status"])

    def test_one_way_does_not_create_return(self):
        data = copy.deepcopy(MAP)
        data["links"]["door-two"] = {
            "from": {"x": 9, "y": 4, "landing_x": 9, "landing_y": 5, "direction": 2},
            "to": {"x": 8, "y": 3, "landing_x": 8, "landing_y": 4, "direction": 8}}
        plan = build_plan(REF, data, require_all=True)
        self.assertEqual(3, len(plan["events"]))
        self.assertEqual(0, len(plan["unmapped_links"]))
        self.assertEqual(["F"], [e["side"] for e in plan["events"] if e["link_id"] == "door-two"])

    def test_requires_complete_when_requested(self):
        with self.assertRaisesRegex(ValueError, "remain unmapped"):
            build_plan(REF, MAP, require_all=True)

    def test_does_not_guess_missing_map(self):
        data = copy.deepcopy(MAP)
        del data["maps"][B]
        with self.assertRaisesRegex(ValueError, "no RMXP map mapping"):
            build_plan(REF, data)

    def test_rejects_duplicate_target_map(self):
        data = copy.deepcopy(MAP)
        data["maps"][B]["target_map_id"] = 10
        with self.assertRaisesRegex(ValueError, "Two source maps"):
            build_plan(REF, data)

    def test_rejects_out_of_bounds_door(self):
        data = copy.deepcopy(MAP)
        data["links"]["door-one"]["from"]["x"] = 20
        with self.assertRaisesRegex(ValueError, "door-one.from.x"):
            build_plan(REF, data)

    def test_rejects_arrival_warp_loop(self):
        data = copy.deepcopy(MAP)
        data["links"]["door-one"]["to"]["landing_y"] = 3
        with self.assertRaisesRegex(ValueError, "warp loop"):
            build_plan(REF, data)

    def test_rejects_duplicate_trigger_cells(self):
        data = copy.deepcopy(MAP)
        data["links"]["door-two"] = {
            "from": {"x": 3, "y": 4, "landing_x": 9, "landing_y": 5, "direction": 2},
            "to": {"x": 8, "y": 3, "landing_x": 8, "landing_y": 4, "direction": 8}}
        with self.assertRaisesRegex(ValueError, "Multiple transfer triggers"):
            build_plan(REF, data)

    def test_rejects_untrusted_source_coordinate(self):
        data = copy.deepcopy(REF)
        data["links"][0]["from"]["x"] = 999
        with self.assertRaisesRegex(ValueError, "source door-one.from.x"):
            build_plan(data, MAP)

    def test_rejects_unknown_link(self):
        data = copy.deepcopy(MAP)
        data["links"]["unlisted"] = data["links"].pop("door-one")
        with self.assertRaisesRegex(ValueError, "unknown source link"):
            build_plan(REF, data)

    def test_rejects_boolean_map_id(self):
        data = copy.deepcopy(MAP)
        data["maps"][A]["target_map_id"] = True
        with self.assertRaisesRegex(ValueError, "target_map_id"):
            build_plan(REF, data)

    def test_deterministic_output(self):
        self.assertEqual(build_plan(REF, MAP), build_plan(copy.deepcopy(REF), copy.deepcopy(MAP)))

if __name__ == "__main__":
    unittest.main()

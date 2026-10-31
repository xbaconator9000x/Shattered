import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_hns_victory_road import audit, FLOORS, MAP_IDS, LAYOUT_IDS, EXPECTED_DIMENSIONS


class VictoryRoadAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.maps = self.root / "maps"
        self.layouts = self.root / "layouts.json"
        layouts = []
        for i, (name, map_id, layout_id, dimensions) in enumerate(
                zip(FLOORS, MAP_IDS, LAYOUT_IDS, EXPECTED_DIMENSIONS)):
            (self.maps / name).mkdir(parents=True)
            layouts.append({"id": layout_id, "width": dimensions[0], "height": dimensions[1]})
            data = {"id": map_id, "layout": layout_id, "warp_events": []}
            (self.maps / name / "map.json").write_text(json.dumps(data))
        self.layouts.write_text(json.dumps({"layouts": layouts}))
        self.set_warps(0, [])
        self.set_warps(2, [])

    def set_warps(self, floor, warps):
        path = self.maps / FLOORS[floor] / "map.json"
        data = json.loads(path.read_text())
        warps = list(warps)
        if floor == 0 and not any(w["dest_map"] == "MAP_ROUTE23_HNS" for w in warps):
            warps.append(self.warp("MAP_ROUTE23_HNS", x=0, y=0))
        if floor == 2 and not any(w["dest_map"] == "MAP_RECEPTION_GATE_HNS" for w in warps):
            warps.append(self.warp("MAP_RECEPTION_GATE_HNS", x=0, y=0))
        data["warp_events"] = warps
        path.write_text(json.dumps(data))

    def warp(self, target, index="0", x=1, y=1):
        return {"x": x, "y": y, "dest_map": target, "dest_warp_id": index}

    def test_pinned_source_identifiers_and_geometry(self):
        self.assertEqual("MAP_VICTORY_ROAD_KANTO_B2F_HNS", MAP_IDS[2])
        self.assertEqual("LAYOUT_VICTORY_ROAD_KANTO_1F_HNS", LAYOUT_IDS[0])
        self.assertEqual(((50, 30), (60, 30), (40, 50)), EXPECTED_DIMENSIONS)

    def test_reciprocal_warps_are_valid(self):
        self.set_warps(0, [self.warp(MAP_IDS[1])])
        self.set_warps(1, [self.warp(MAP_IDS[0])])
        result = audit(self.maps, self.layouts)
        self.assertEqual([], result["anomalies"])
        self.assertEqual(4, len(result["links"]))
        self.assertFalse(result["runtime_verified"])

    def test_out_of_range_destination_is_reported_not_rewritten(self):
        self.set_warps(0, [self.warp(MAP_IDS[1], "99")])
        result = audit(self.maps, self.layouts)
        self.assertEqual("destination warp index out of range", result["anomalies"][0]["problem"])

    def test_nonreciprocal_destination_is_reported(self):
        self.set_warps(0, [self.warp(MAP_IDS[1])])
        self.set_warps(1, [self.warp(MAP_IDS[2])])
        self.assertEqual("destination warp does not lead back", audit(self.maps, self.layouts)["anomalies"][0]["problem"])

    def test_external_reception_gate_is_preserved(self):
        result = audit(self.maps, self.layouts)
        gate_links = [w for w in result["links"] if w["destination"] == "MAP_RECEPTION_GATE_HNS"]
        self.assertEqual(1, len(gate_links))
        self.assertEqual(MAP_IDS[2], gate_links[0]["map"])

    def test_out_of_bounds_source_rejected(self):
        self.set_warps(0, [self.warp(MAP_IDS[1], x=50)])
        with self.assertRaisesRegex(ValueError, "out of bounds"):
            audit(self.maps, self.layouts)

    def test_duplicate_source_warp_rejected(self):
        self.set_warps(1, [self.warp(MAP_IDS[0]), self.warp(MAP_IDS[0])])
        with self.assertRaisesRegex(ValueError, "duplicate source position"):
            audit(self.maps, self.layouts)

    def test_wrong_source_layout_rejected(self):
        path = self.maps / FLOORS[0] / "map.json"
        data = json.loads(path.read_text())
        data["layout"] = LAYOUT_IDS[1]
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "unexpected or missing source layout"):
            audit(self.maps, self.layouts)


if __name__ == "__main__":
    unittest.main()

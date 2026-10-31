import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_hns_victory_road import audit, FLOORS, MAP_IDS


class VictoryRoadAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.maps = self.root / "maps"
        self.layouts = self.root / "layouts.json"
        layouts = []
        for name, map_id in zip(FLOORS, MAP_IDS):
            (self.maps / name).mkdir(parents=True)
            layouts.append({"id": "LAYOUT_" + name.upper(), "width": 6, "height": 6})
            data = {"id": map_id, "layout": "LAYOUT_" + name.upper(), "warp_events": []}
            (self.maps / name / "map.json").write_text(json.dumps(data))
        self.layouts.write_text(json.dumps({"layouts": layouts}))

    def set_warps(self, floor, warps):
        path = self.maps / FLOORS[floor] / "map.json"
        data = json.loads(path.read_text())
        data["warp_events"] = warps
        path.write_text(json.dumps(data))

    def warp(self, target, index="0", x=1, y=1):
        return {"x": x, "y": y, "dest_map": target, "dest_warp_id": index}

    def test_reciprocal_warps_are_valid(self):
        self.set_warps(0, [self.warp(MAP_IDS[1])])
        self.set_warps(1, [self.warp(MAP_IDS[0])])
        result = audit(self.maps, self.layouts)
        self.assertEqual([], result["anomalies"])
        self.assertEqual(2, len(result["links"]))
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
        self.set_warps(2, [self.warp("MAP_RECEPTION_GATE_HNS", "2")])
        result = audit(self.maps, self.layouts)
        self.assertEqual([], result["anomalies"])
        self.assertEqual("MAP_RECEPTION_GATE_HNS", result["links"][0]["destination"])

    def test_out_of_bounds_source_rejected(self):
        self.set_warps(0, [self.warp(MAP_IDS[1], x=6)])
        with self.assertRaisesRegex(ValueError, "out of bounds"):
            audit(self.maps, self.layouts)


if __name__ == "__main__":
    unittest.main()

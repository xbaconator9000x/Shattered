"""Offline, rights-cleared fixture tests for source event metadata extraction."""
import importlib.util
import json
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("extract_demo_parity", Path(__file__).resolve().parents[1] / "scripts" / "extract_demo_parity.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


def fixture():
    return {"format": "pokebacon-map-studio", "maps": [
        {"id": "gate", "name": "ROUTE 22 · 28.0", "width": 22, "height": 21, "objects": [],
         "markers": [{"id": "aipom", "nativeId": "28.0:npc:15", "kind": "npc", "x": 11, "y": 17,
                      "title": "Aipom has something shiny in its tail", "text": "private dialogue should never be copied",
                      "rom": {"address": 100, "scriptSource": "private original script", "dialogue": [{"text": "secret"}]}}]},
        {"id": "route", "name": "ROUTE 22 · 3.41", "width": 48, "height": 24, "objects": [{}],
         "markers": [{"id": "rattata", "nativeId": "3.41:trigger:36,16", "kind": "event", "x": 36, "y": 16,
                      "title": "Several Rattata are chewing", "rom": {"scriptSource": "secret"}}]},
    ], "links": [{"id": "warp", "kind": "east", "twoWay": True,
                   "from": {"mapId": "gate", "x": 21, "y": 10}, "to": {"mapId": "route", "x": 0, "y": 10}}]}


class ParityTests(unittest.TestCase):
    def test_extracts_real_event_anchors_and_counts(self):
        result = mod.extract(fixture(), "original.pokebacon.json", "a" * 64)
        self.assertEqual(result["summary"], {"map_count": 2, "marker_count": 2,
                          "marker_kinds": {"event": 1, "npc": 1}, "object_count": 1, "link_count": 1})
        self.assertEqual(result["scenes"]["johto_gate_aipom"]["anchors"][0]["source_event_id"], "28.0:npc:15")
        self.assertEqual(result["scenes"]["route22_rattata"]["anchors"][0]["source_event_id"], "3.41:trigger:36,16")
        self.assertEqual(result["links"][0]["to"]["x"], 0)
        self.assertIsNone(result["scenes"]["johto_gate_aipom"]["essentials_map_id"])

    def test_never_copies_dialogue_script_tiles_or_assets(self):
        result = mod.extract(fixture(), "original.json", "b" * 64)
        serial = json.dumps(result)
        for secret in ("private dialogue", "private original script", "secret", "assets", "layers"):
            self.assertNotIn(secret, serial)
        self.assertEqual(result["scenes"]["johto_gate_aipom"]["anchors"][0]["script_length"], 23)

    def test_rejects_invalid_map_and_warp_coordinates(self):
        data = fixture()
        data["links"][0]["to"]["x"] = 48
        with self.assertRaisesRegex(ValueError, "outside"):
            mod.extract(data, "local", "hash")

    def test_rejects_out_of_bounds_marker(self):
        data = fixture()
        data["maps"][0]["markers"][0]["y"] = -1
        with self.assertRaisesRegex(ValueError, "outside"):
            mod.extract(data, "local", "hash")

    def test_rejects_unknown_destination_map(self):
        data = fixture()
        data["links"][0]["to"]["mapId"] = "missing"
        with self.assertRaisesRegex(ValueError, "Unknown map"):
            mod.extract(data, "local", "hash")

    def test_rejects_duplicate_source_map_id(self):
        data = fixture()
        data["maps"][1]["id"] = "gate"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            mod.extract(data, "local", "hash")

    def test_output_is_deterministic(self):
        first = mod.extract(fixture(), "a.json", "hash")
        second = mod.extract(fixture(), "a.json", "hash")
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))



class CommittedReferenceTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "development" / "demo_parity_reference.json"
        self.reference = json.loads(path.read_text(encoding="utf-8"))

    def test_source_reference_is_metadata_only_and_matches_inspected_counts(self):
        doc = self.reference
        self.assertEqual(doc["summary"], {
            "map_count": 23, "marker_count": 656,
            "marker_kinds": {"event": 156, "npc": 77, "sign": 423},
            "object_count": 567, "link_count": 36,
        })
        self.assertEqual(sum(len(scene["anchors"]) for scene in doc["scenes"].values()), 123)
        self.assertTrue(all(scene["status"] == "source_reference_only" and
                            scene["essentials_map_id"] is None for scene in doc["scenes"].values()))
        self.assertIsNone(doc["source"]["sha256"])
        for field in ('"scriptSource"', '"dialogue":', '"layers":', '"assets":'):
            self.assertNotIn(field, json.dumps(doc))

    def test_committed_anchor_and_link_coordinates_are_in_bounds(self):
        maps = {m["id"]: m for m in self.reference["maps"]}
        self.assertEqual(len(maps), 23)
        for scene in self.reference["scenes"].values():
            for anchor in scene["anchors"]:
                mod.require_point(anchor, maps[anchor["map_id"]], anchor["source_event_id"])
        for link in self.reference["links"]:
            mod.require_point(link["from"], maps[link["from"]["mapId"]], link["id"])
            mod.require_point(link["to"], maps[link["to"]["mapId"]], link["id"])



if __name__ == "__main__":
    unittest.main()

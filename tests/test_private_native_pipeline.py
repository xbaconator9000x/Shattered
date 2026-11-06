import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from private_native_pipeline import HNS_FILES, diagnose


class PrivateNativePipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write_rights(self, path, source, identity="source_rom", kind="gba_rom"):
        record = {
            "id": identity,
            "type": kind,
            "rights_cleared": True,
            "source": "local authorized source",
            "license": "local use authorized",
            "basis": "owner-held rights record",
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        }
        path.write_text(json.dumps(record))

    def complete_inputs(self):
        base = self.root / "base"
        for relative in (
            "Game.ini", "Data/PluginScripts.rxdata", "Data/Scripts.rxdata",
            "Data/MapInfos.rxdata", "Data/Tilesets.rxdata",
            "PBS/pokemon.txt", "PBS/items.txt",
        ):
            target = base / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"synthetic " + relative.encode())

        rom = self.root / "source.gba"
        rom.write_bytes(b"synthetic-rom-input")
        rom_rights = self.root / "rom-rights.json"
        self.write_rights(rom_rights, rom, "source_rom", "gba_rom")

        hns = self.root / "hns"
        for relative in HNS_FILES:
            target = hns / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"synthetic " + relative.encode())

        inputs = {}
        for name in (
            "gate_mapping", "road_mapping", "gate_tileset",
            "route22_source", "viridian_source", "native_engine",
        ):
            path = self.root / name
            path.write_bytes(b"synthetic " + name.encode())
            inputs[name] = path
        inputs["native_engine"].chmod(0o755)
        road_tilesets = self.root / "road-tilesets"
        road_tilesets.mkdir()
        return {
            "project": base,
            "source_rom": rom,
            "rom_rights": rom_rights,
            "hns_source": hns,
            "road_tilesets": road_tilesets,
            **inputs,
        }

    def test_reports_exact_missing_components_without_claiming_acceptance(self):
        result = diagnose()

        self.assertEqual("BLOCKED", result["status"])
        self.assertIn("authorized_essentials_v21_1_base", result["blockers"])
        self.assertIn("authorized_source_rom", result["blockers"])
        self.assertEqual("incomplete", result["inputs"]["hns_source"]["status"])
        self.assertIn("data/maps/ReceptionGate_hns/map.json",
                      result["inputs"]["hns_source"]["missing_files"])
        self.assertFalse(result["native_gameplay_verified"])
        self.assertFalse(result["save_reload_verified"])
        self.assertFalse(result["screenshots_created"])

    def test_complete_local_inputs_are_reported_ready_but_not_playtested(self):
        inputs = self.complete_inputs()
        result = diagnose(**inputs)

        self.assertEqual("BLOCKED", result["status"])
        self.assertEqual("complete", result["input_status"])
        self.assertEqual([], result["blockers"])
        self.assertEqual("present", result["inputs"]["essentials_base"]["status"])
        self.assertEqual("verified", result["inputs"]["source_rom_rights"]["status"])
        self.assertEqual("present_unverified", result["inputs"]["hns_source"]["status"])
        self.assertFalse(result["assembly_ready"])
        self.assertFalse(result["native_gameplay_verified"])
        self.assertFalse(result["save_reload_verified"])
        self.assertIn("No checked-in converter derives the Essentials/RMXP project",
                      result["implementation_gaps"][0])

    def test_rejects_rom_rights_record_with_wrong_hash(self):
        inputs = self.complete_inputs()
        record = json.loads(inputs["rom_rights"].read_text())
        record["source_sha256"] = "0" * 64
        inputs["rom_rights"].write_text(json.dumps(record))

        result = diagnose(**inputs)

        self.assertEqual("invalid", result["inputs"]["source_rom_rights"]["status"])
        self.assertIn("source_rom_rights_record", result["blockers"])

    def test_rejects_non_executable_runtime_and_symlinked_source(self):
        inputs = self.complete_inputs()
        inputs["native_engine"].chmod(0o644)
        inputs["hns_source"].rename(self.root / "hns-target")
        inputs["hns_source"].symlink_to(self.root / "hns-target")

        result = diagnose(**inputs)

        self.assertEqual("invalid", result["inputs"]["native_engine"]["status"])
        self.assertEqual("incomplete", result["inputs"]["hns_source"]["status"])
        self.assertIn("native_engine", result["blockers"])

if __name__ == "__main__":
    unittest.main()

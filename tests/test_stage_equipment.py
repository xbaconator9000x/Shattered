"""Source-only equipment staging: fail closed on missing native PBS definitions."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from stage_essentials import stage, EQUIPMENT_ITEMS, EQUIPMENT_MOVES


class EquipmentStageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "base"
        (self.base / "PBS").mkdir(parents=True)
        (self.base / "Plugins").mkdir()
        (self.base / "Game.ini").write_text("[Game]\nTitle=Test\n")
        (self.base / "PBS/pokemon.txt").write_text("[PIKACHU]\nName = Pikachu\n")
        self.items = self.base / "PBS/items.txt"
        self.moves = self.base / "PBS/moves.txt"
        self.items.write_text("".join(f"[{item}]\nName = {item}\n" for item in EQUIPMENT_ITEMS))
        self.moves.write_text("".join(f"[{move}]\nName = {move}\n" for move in EQUIPMENT_MOVES))
        self.out = self.root / "staged"

    def test_opt_in_stages_source_and_preserves_original(self):
        before = self.items.read_bytes()
        result = stage(self.base, self.out, include_equipment=True)
        self.assertFalse(result["runtime_verified"])
        self.assertFalse(result["equipment"]["runtime_verified"])
        self.assertEqual(list(EQUIPMENT_ITEMS), result["equipment"]["pbs_items_checked"])
        self.assertTrue((self.out / "Plugins/Shattered Equipment/001_Equipment.rb").is_file())
        self.assertTrue((self.out / "Plugins/Shattered Core/001_Core.rb").is_file())
        self.assertEqual(before, self.items.read_bytes())
        self.assertEqual(result["equipment"], json.loads(
            (self.out / "SHATTERED_STAGING_REPORT.json").read_text()
        )["equipment"])
        self.assertFalse((self.base / "Plugins/Shattered Equipment").exists())

    def test_default_does_not_silently_install_equipment(self):
        result = stage(self.base, self.out)
        self.assertNotIn("equipment", result)
        self.assertFalse((self.out / "Plugins/Shattered Equipment").exists())

    def test_missing_native_gear_id_aborts_atomically(self):
        self.items.write_text(self.items.read_text().replace("[KNIFE]", "[UNREVIEWED]"))
        with self.assertRaisesRegex(ValueError, "missing PBS/items.txt IDs: KNIFE"):
            stage(self.base, self.out, include_equipment=True)
        self.assertFalse(self.out.exists())
        self.assertIn("[UNREVIEWED]", self.items.read_text())

    def test_missing_move_and_missing_pbs_file_abort_atomically(self):
        self.moves.write_text(self.moves.read_text().replace("[SLASH]", "[UNKNOWN]"))
        with self.assertRaisesRegex(ValueError, "missing PBS/moves.txt IDs: SLASH"):
            stage(self.base, self.out, include_equipment=True)
        self.assertFalse(self.out.exists())
        self.moves.unlink()
        with self.assertRaisesRegex(ValueError, "requires reviewed PBS/moves.txt"):
            stage(self.base, self.out, include_equipment=True)
        self.assertFalse(self.out.exists())

    def test_casefold_plugin_collision_aborts_without_overwrite(self):
        existing = self.base / "Plugins/shattered equipment"
        existing.mkdir()
        (existing / "meta.txt").write_text("preserve me")
        with self.assertRaisesRegex(ValueError, "would overwrite an existing plugin"):
            stage(self.base, self.out, include_equipment=True)
        self.assertFalse(self.out.exists())
        self.assertEqual("preserve me", (existing / "meta.txt").read_text())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Regression coverage for private project staging policy."""
import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "stage_essentials", ROOT / "scripts" / "stage_essentials.py"
)
stage_essentials = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage_essentials)


class StageEssentialsTests(unittest.TestCase):
    def test_runtime_set_stages_companion_with_other_runtime_plugins(self):
        with tempfile.TemporaryDirectory() as temp:
            dest = Path(temp)
            (dest / "Plugins").mkdir()
            report = stage_essentials.install_shattered_runtime_set(dest)
            self.assertIn("Shattered Companion", report["staged"])
            self.assertIn("Shattered Gameplay", report["staged"])
            self.assertTrue(
                (dest / "Plugins" / "Shattered Companion" / "001_Companion.rb").is_file()
            )

    def test_runtime_set_can_replace_only_known_runtime_plugins(self):
        with tempfile.TemporaryDirectory() as temp:
            dest = Path(temp)
            old = dest / "Plugins" / "Shattered Raid"
            old.mkdir(parents=True)
            (old / "meta.txt").write_text("old")
            report = stage_essentials.install_shattered_runtime_set(
                dest, replace_existing=True
            )
            self.assertEqual(["Shattered Raid"], report["replaced"])
            self.assertNotEqual("old", (old / "meta.txt").read_text())

    def test_rom_front_import_rejects_unrecognised_input_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            rom = root / "not-shattered.gba"
            rom.write_bytes(b"not a recognised rom")
            staged = root / "staged"
            staged.mkdir()
            with self.assertRaisesRegex(ValueError, "unrecognised Shattered ROM"):
                stage_essentials.install_shattered_rom_fronts(staged, rom)
            self.assertFalse((staged / "Graphics").exists())


if __name__ == "__main__":
    unittest.main()

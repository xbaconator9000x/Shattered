import sys
import tempfile
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from install_gate_key_pbs import install

class GateKeyPBSTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name)
        (self.project / "PBS").mkdir()
        (self.project / "PBS" / "items.txt").write_text("[POTION]\nName = Potion\n", encoding="utf-8")
        (self.project / "SHATTERED_STAGING_REPORT.json").write_text("{}")
    def test_append_once_idempotent(self):
        self.assertEqual("installed", install(self.project))
        p = self.project / "PBS" / "items.txt"
        first = p.read_bytes()
        self.assertIn(b"Flags = KeyItem", first)
        self.assertEqual(1, first.count(b"[SHATTEREDGATEKEY]"))
        self.assertEqual("unchanged", install(self.project))
        self.assertEqual(first, p.read_bytes())
    def test_refuses_original_project(self):
        (self.project / "SHATTERED_STAGING_REPORT.json").unlink()
        original = (self.project / "PBS" / "items.txt").read_bytes()
        with self.assertRaises(ValueError):
            install(self.project)
        self.assertEqual(original, (self.project / "PBS" / "items.txt").read_bytes())
    def test_refuses_conflicting_key_definition(self):
        p = self.project / "PBS" / "items.txt"
        p.write_text("[SHATTEREDGATEKEY]\nName = Another item\n")
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            install(self.project)
    def test_refuses_duplicate_key_definitions(self):
        p = self.project / "PBS" / "items.txt"
        p.write_text("[SHATTEREDGATEKEY]\n[SHATTEREDGATEKEY]\n")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            install(self.project)

if __name__ == "__main__":
    unittest.main()

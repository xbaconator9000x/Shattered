import unittest
from scripts.verify_playable_receipt import GATES, validate


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.receipt = {
            "project": "Shattered Essentials v21.1",
            "main_sha": "a" * 40,
            "gates": {name: {"status": "verified", "evidence": "local private runtime log"} for name in GATES},
        }

    def test_complete_receipt(self):
        self.assertEqual(validate(self.receipt), [])

    def test_synthetic_checks_do_not_count(self):
        self.receipt["gates"]["human_battle"] = {"status": "implemented", "evidence": "Ruby unit tests"}
        self.assertIn("human_battle: not runtime verified", validate(self.receipt))

    def test_missing_save_evidence_rejected(self):
        self.receipt["gates"]["save_reload"]["evidence"] = ""
        self.assertIn("save_reload: missing evidence reference", validate(self.receipt))

    def test_invalid_sha_rejected(self):
        self.receipt["main_sha"] = "main"
        self.assertTrue(any("main_sha" in error for error in validate(self.receipt)))

import json
from pathlib import Path
import tempfile
import unittest

from scripts.prepare_linux_map_aliases import prepare, RECEIPT


class LinuxMapAliasTest(unittest.TestCase):
    def stage(self, root):
        project = Path(root) / "staged"
        data = project / "Data"
        data.mkdir(parents=True)
        (project / "SHATTERED_STAGING_REPORT.json").write_text("{}")
        (data / "Map001.rxdata").write_bytes(b"original-one")
        (data / "Map222.rxdata").write_bytes(b"original-two")
        return project, data

    def test_creates_only_lowercase_aliases_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            report = prepare(project)
            self.assertEqual(2, report["alias_count"])
            self.assertTrue((data / "map001.rxdata").is_symlink())
            self.assertEqual("Map001.rxdata", (data / "map001.rxdata").readlink().as_posix())
            self.assertEqual(b"original-one", (data / "Map001.rxdata").read_bytes())
            self.assertEqual(report, prepare(project))
            self.assertFalse(report["native_pbs_compiled"])
            self.assertFalse(report["gameplay_verified"])

    def test_fails_closed_on_lowercase_collision_without_partial_aliases(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            (data / "map222.rxdata").write_bytes(b"foreign")
            with self.assertRaisesRegex(ValueError, "collides"):
                prepare(project)
            self.assertFalse((data / "map001.rxdata").exists())
            self.assertFalse((project / RECEIPT).exists())

    def test_fails_closed_on_wrong_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            (data / "map222.rxdata").symlink_to("Map001.rxdata")
            with self.assertRaisesRegex(ValueError, "wrong lowercase"):
                prepare(project)
            self.assertFalse((data / "map001.rxdata").exists())

    def test_requires_private_staging_report(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            (project / "SHATTERED_STAGING_REPORT.json").unlink()
            with self.assertRaisesRegex(ValueError, "private staging"):
                prepare(project)
            self.assertFalse((data / "map001.rxdata").exists())

    def test_detects_source_tamper_after_preparation(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            prepare(project)
            (data / "Map001.rxdata").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "source hashes changed"):
                prepare(project)

    def test_rejects_symlinked_source_map(self):
        with tempfile.TemporaryDirectory() as root:
            project, data = self.stage(root)
            (data / "Map222.rxdata").unlink()
            (data / "Map222.rxdata").symlink_to("Map001.rxdata")
            with self.assertRaisesRegex(ValueError, "unsafe native map"):
                prepare(project)
            self.assertFalse((data / "map001.rxdata").exists())


if __name__ == "__main__":
    unittest.main()

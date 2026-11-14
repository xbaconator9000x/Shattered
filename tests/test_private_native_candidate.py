"""Integration tests for one private, source-pinned compiled Shattered candidate.

Uses synthetic minimal RXData only; never claims native engine/gameplay acceptance.
"""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_private_native_candidate import build, source_pin


@unittest.skipUnless(shutil.which("ruby"), "Ruby is required for native archive fixture")
class PrivateNativeCandidateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "original"
        (self.base / "Data").mkdir(parents=True)
        (self.base / "PBS").mkdir()
        (self.base / "Plugins").mkdir()
        (self.base / "Game.ini").write_text("[Game]\nTitle=Shattered\n")
        (self.base / "PBS/pokemon.txt").write_text("[PIKACHU]\nName = Pikachu\n")
        (self.base / "Data/Map001.rxdata").write_bytes(b"synthetic-map-not-native")
        archive = self.base / "Data/PluginScripts.rxdata"
        code = (
            "require 'zlib'; "
            "entries = [['v21.1 Hotfixes', "
            "{:name=>'v21.1 Hotfixes', :version=>'1.0.3', :essentials=>['21.1']}, "
            "[['Hotfix.rb', Zlib::Deflate.deflate('HOTFIX_TEST = true')]]]]; "
            "File.binwrite(ARGV[0], Marshal.dump(entries))"
        )
        subprocess.run(["ruby", "-e", code, str(archive)], check=True)
        self.original_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        try:
            source_pin()
            self.requested_sha = None
        except ValueError:
            # Source-only GitHub handoff artifacts deliberately contain no .git.
            self.requested_sha = 'a' * 40

    def test_full_candidate_compiles_isolates_and_preserves_original(self):
        dest = self.root / "candidate"
        receipt = build(self.base, dest, requested_sha=self.requested_sha, linux_aliases=True)
        self.assertEqual(9, len(receipt["runtime_plugins"]))
        self.assertIn("Shattered Companion", receipt["runtime_plugins"])
        self.assertGreaterEqual(receipt["offline_installers_isolated"], 7)
        self.assertEqual(1, receipt["linux_map_alias_count"])
        self.assertFalse(receipt["native_engine_launched"])
        self.assertFalse(receipt["native_pbs_compiled"])
        self.assertFalse(receipt["gameplay_verified"])
        self.assertFalse(receipt["distributable"])
        self.assertTrue((dest / "SHATTERED_NATIVE_CANDIDATE.json").is_file())
        self.assertTrue((dest / "SHATTERED_RUNTIME_ISOLATION_REPORT.json").is_file())
        self.assertTrue((dest / "Plugins/Shattered Core/001_Core.rb").is_file())
        self.assertFalse((dest / "Plugins/Shattered Gate Story/002_Install.rb").exists())
        self.assertTrue((dest / "SHATTERED_OFFLINE_TOOLS/Shattered Gate Story/002_Install.rb").is_file())
        self.assertTrue((dest / "Data/map001.rxdata").is_symlink())
        self.assertEqual(self.original_digest, hashlib.sha256(
            (self.base / "Data/PluginScripts.rxdata").read_bytes()
        ).hexdigest())
        self.assertFalse((self.base / "Plugins/Shattered Core").exists())

    def test_rejects_existing_candidate_without_overwriting(self):
        dest = self.root / "candidate"
        dest.mkdir()
        (dest / "keep.txt").write_text("unchanged")
        with self.assertRaisesRegex(ValueError, "already exists"):
            build(self.base, dest, requested_sha=self.requested_sha)
        self.assertEqual("unchanged", (dest / "keep.txt").read_text())

    def test_rejects_missing_native_plugin_archive(self):
        (self.base / "Data/PluginScripts.rxdata").unlink()
        with self.assertRaisesRegex(ValueError, "PluginScripts.rxdata"):
            build(self.base, self.root / "candidate", requested_sha=self.requested_sha)
        self.assertFalse((self.root / "candidate").exists())

    def test_rebuild_replaces_existing_runtime_plugin_in_staging_only(self):
        collision = self.base / "Plugins/Shattered Raid"
        collision.mkdir()
        (collision / "meta.txt").write_text("existing")
        receipt = build(self.base, self.root / "candidate", requested_sha=self.requested_sha)
        self.assertIn("Shattered Raid", receipt["runtime_plugins"])
        self.assertTrue((self.root / "candidate").exists())
        self.assertEqual("existing", (collision / "meta.txt").read_text())

    def test_requested_commit_cannot_disagree_with_checkout(self):
        try:
            _sha, verified = source_pin()
        except ValueError:
            self.skipTest("source-only archive has no Git metadata")
        if not verified:
            self.skipTest("source-only archive")
        with self.assertRaisesRegex(ValueError, "does not match checkout"):
            source_pin("0" * 40)


if __name__ == "__main__":
    unittest.main()

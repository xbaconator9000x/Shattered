# frozen_string_literal: true
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_private_opening_candidate as opening
import build_private_native_candidate as base_builder
import shattered_integration as integration


class PrivateOpeningCandidateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "essentials-21.1.zip"
        self.archive.write_bytes(b"synthetic-authorized-base-archive")
        self.rights = self.root / "base-rights.json"
        self.write_rights()
        self.sources = self.root / "sources"
        self.sources.mkdir()
        (self.sources / "source.lock").write_text("synthetic pinned source bundle")
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        (self.inputs / "licensed-asset.bin").write_bytes(b"local-only input")
        self.stage_plan = self.root / "stage-plan.json"
        self.stage_plan.write_text("{}")
        self.native_plan = self.root / "native-plan.json"
        self.native_plan.write_text("{}")
        self.manifest = Path(integration.MANIFEST_PATH)
        self.output = self.root / "candidate"
        self.base = self.root / "extracted"
        self.base.mkdir()
        self.plugin_archive = b"compiled synthetic plugins"
        self.plugin_sha = hashlib.sha256(self.plugin_archive).hexdigest()

    def write_rights(self, **changes):
        record = {
            "id": "base_project",
            "type": "essentials_project",
            "engine_version": "21.1",
            "rights_cleared": True,
            "source": "official locally obtained Essentials 21.1 distribution",
            "license": "local use authorized",
            "basis": "owner-held local attestation",
            "archive_sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
        }
        record.update(changes)
        self.rights.write_text(json.dumps(record))

    def fake_stage(self, project, sources, inputs, plan, output, manifest, profile):
        self.assertEqual("initial_slice", profile)
        output.mkdir()
        (output / "Data").mkdir()
        (output / "Data/PluginScripts.rxdata").write_bytes(self.plugin_archive)
        return {"status": "staged_test_copy", "profile": profile}

    def patches(self, handoff):
        profile = integration._profile_config(
            integration.load_manifest(self.manifest), "initial_slice"
        )
        plugins = [
            item["name"] for item in integration.load_manifest(self.manifest)["components"]
            if item["id"] in set(profile["components"]) and item["name"].startswith("Shattered ")
        ]

        def fake_ruby(script, args):
            if script == "compile_private_plugins.rb":
                return {"plugin_names": plugins, "compiled_archive_sha256": self.plugin_sha}
            if script == "finalize_private_runtime.rb":
                return {
                    "runtime_plugin_names": ["Shattered Core"],
                    "compiled_archive_sha256": self.plugin_sha,
                    "moved": [{"from": "a"}],
                }
            self.fail(f"unexpected Ruby subprocess: {script}")

        return (
            patch.object(base_builder, "validate_base_rights",
                         return_value={"archive_sha256": hashlib.sha256(
                             self.archive.read_bytes()).hexdigest()}),
            patch.object(base_builder, "extract_base_archive", return_value=self.base),
            patch.object(base_builder, "source_pin", return_value=("a" * 40, False)),
            patch.object(integration, "stage_project", side_effect=self.fake_stage),
            patch.object(opening, "_run_ruby", side_effect=fake_ruby),
            patch.object(opening, "prepare_native_handoff", side_effect=handoff),
        )

    def run_with(self, handoff):
        patches = self.patches(handoff)
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            return opening.build(
                self.archive, self.rights, self.sources, self.inputs,
                self.stage_plan, self.native_plan, self.output,
                self.manifest, source_sha="a" * 40,
            )

    def test_builds_private_candidate_and_keeps_native_acceptance_pending(self):
        result = self.run_with(lambda *args, **kwargs: {
            "status": "native_install_pending",
            "native_execution_verified": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
        })

        self.assertEqual("private_initial_slice_candidate_not_playable_acceptance",
                         result["kind"])
        self.assertEqual("native_install_pending", result["native_installer"]["status"])
        self.assertFalse(result["native_maps_installed"])
        self.assertFalse(result["native_game_launched"])
        self.assertFalse(result["gameplay_verified"])
        self.assertFalse(result["save_reload_verified"])
        self.assertTrue((self.output / opening.REPORT).is_file())
        self.assertEqual(self.plugin_archive,
                         (self.output / "Data/PluginScripts.rxdata").read_bytes())
        self.assertTrue(self.archive.is_file())
        self.assertTrue((self.base).is_dir())

    def test_native_handoff_failure_removes_partial_candidate_and_preserves_inputs(self):
        with self.assertRaisesRegex(RuntimeError, "handoff rejected"):
            self.run_with(lambda *args, **kwargs: (_ for _ in ()).throw(
                RuntimeError("handoff rejected")
            ))
        self.assertFalse(self.output.exists())
        self.assertTrue(self.archive.is_file())
        self.assertTrue(self.rights.is_file())

    def test_rights_hash_mismatch_fails_before_extraction(self):
        self.write_rights(archive_sha256="0" * 64)
        with patch.object(base_builder, "extract_base_archive") as extract:
            with self.assertRaisesRegex(ValueError, "differs from its rights record"):
                opening.build(
                    self.archive, self.rights, self.sources, self.inputs,
                    self.stage_plan, self.native_plan, self.output,
                    self.manifest, source_sha="a" * 40,
                )
        extract.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_symlinked_rights_record_is_rejected(self):
        link = self.root / "rights-link.json"
        link.symlink_to(self.rights)
        with self.assertRaisesRegex(ValueError, "missing, non-regular, or symlinked"):
            opening.build(
                self.archive, link, self.sources, self.inputs,
                self.stage_plan, self.native_plan, self.output,
                self.manifest, source_sha="a" * 40,
            )
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

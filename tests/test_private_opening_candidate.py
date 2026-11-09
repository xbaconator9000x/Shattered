# frozen_string_literal: true
import hashlib
import json
from pathlib import Path
import stat
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
        self.system_bytes = b"synthetic original System.rxdata"
        self.city_bytes = b"synthetic original Map010.rxdata"
        self.center_bytes = b"synthetic original Map011.rxdata"
        self.native_plan.write_text(json.dumps({
            "new_game_spawn": {
                "system_sha256": hashlib.sha256(self.system_bytes).hexdigest(),
            },
            "required_existing_maps": [
                {"id": 10, "sha256": hashlib.sha256(self.city_bytes).hexdigest()},
                {"id": 11, "sha256": hashlib.sha256(self.center_bytes).hexdigest()},
            ],
        }))
        self.manifest = Path(integration.MANIFEST_PATH)
        self.output = self.root / "candidate"
        self.base = self.root / "extracted"
        self.base.mkdir()
        self.plugin_archive = b"compiled synthetic plugins"
        self.plugin_sha = hashlib.sha256(self.plugin_archive).hexdigest()
        self.ruby_calls = []

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
        (output / "Plugins").mkdir()
        (output / "Data/PluginScripts.rxdata").write_bytes(self.plugin_archive)
        (output / "Data/System.rxdata").write_bytes(self.system_bytes)
        (output / "Data/Map010.rxdata").write_bytes(self.city_bytes)
        (output / "Data/Map011.rxdata").write_bytes(self.center_bytes)
        (output / "SHATTERED_INTEGRATION_BUILD.json").write_text(json.dumps({
            "declared_plugin_load_order": [],
        }))
        return {"status": "staged_test_copy", "profile": profile}

    def patches(self, handoff):
        profile = integration._profile_config(
            integration.load_manifest(self.manifest), "initial_slice"
        )
        plugins = [
            item["name"] for item in integration.load_manifest(self.manifest)["components"]
            if item["id"] in set(profile["components"]) and item["name"].startswith("Shattered ")
        ]
        plugins.extend([opening.VIRIDIAN_PLUGIN])

        def fake_ruby(script, args):
            self.ruby_calls.append(script)
            if script == "upgrade_private_viridian_handoff.rb":
                candidate = Path(args[0])
                city = candidate / "Data/Map010.rxdata"
                center = candidate / "Data/Map011.rxdata"
                system = candidate / "Data/System.rxdata"
                city.write_bytes(b"synthetic post-handoff Map010")
                center.write_bytes(b"synthetic post-handoff Map011")
                system.write_bytes(b"synthetic post-handoff System")
                return {
                    "city_sha256": hashlib.sha256(city.read_bytes()).hexdigest(),
                    "center_sha256": hashlib.sha256(center.read_bytes()).hexdigest(),
                    "system_sha256": hashlib.sha256(system.read_bytes()).hexdigest(),
                    "weather_center_handoff_installed": True,
                }
            if script == "upgrade_private_viridian_escort.rb":
                city = Path(args[0]) / "Data/Map010.rxdata"
                city.write_bytes(b"synthetic escorted Map010")
                return {
                    "native_map_sha256": hashlib.sha256(city.read_bytes()).hexdigest(),
                    "native_events_added": 4,
                    "arrival_requires_completed_route": True,
                }
            if script == "compile_private_plugins.rb":
                return {"plugin_names": plugins, "compiled_archive_sha256": self.plugin_sha}
            if script == "finalize_private_runtime.rb":
                candidate = Path(args[args.index("--project") + 1])
                source = candidate / "Plugins/Shattered Viridian/002_Install.rb"
                destination = candidate / "SHATTERED_OFFLINE_TOOLS/Shattered Viridian/002_Install.rb"
                destination.parent.mkdir(parents=True)
                source.replace(destination)
                return {
                    "runtime_plugin_names": ["Shattered Core", "Shattered Viridian"],
                    "compiled_archive_sha256": self.plugin_sha,
                    "moved": [{"from": "Plugins/Shattered Viridian/002_Install.rb"}],
                }
            if script == "compile_private_pbs_native.rb":
                candidate = Path(args[args.index("--project") + 1])
                source_sha = json.loads(
                    (candidate / opening.NATIVE_CANDIDATE).read_text()
                )["source_sha"]
                result = {
                    "kind": "actual_private_essentials_native_pbs_compiler_not_gameplay_acceptance",
                    "native_compiler_completed": True,
                    "source_sha": source_sha,
                    "original_scripts_sha256": "2" * 64,
                    "restored_scripts_sha256": "2" * 64,
                    "gameplay_verified": False,
                    "save_reload_verified": False,
                }
                (candidate / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json").write_text(
                    json.dumps(result)
                )
                return result
            if script == "install_private_initial_slice_native.rb":
                candidate = Path(args[args.index("--project") + 1])
                source_sha = json.loads(
                    (candidate / opening.NATIVE_CANDIDATE).read_text()
                )["source_sha"]
                result = {
                    "kind": "actual_private_essentials_native_initial_slice_install_not_gameplay_acceptance",
                    "native_map_install_completed": True,
                    "source_sha": source_sha,
                    "plan_sha256": "d" * 64,
                    "gameplay_verified": False,
                    "save_reload_verified": False,
                }
                (candidate / "SHATTERED_NATIVE_INITIAL_SLICE_INSTALL_REPORT.json").write_text(
                    json.dumps(result)
                )
                return result
            self.fail(f"unexpected Ruby subprocess: {script}")

        def verify_handoff(candidate, source_root, plan, manifest):
            self.assertEqual(
                hashlib.sha256(b"synthetic post-handoff System").hexdigest(),
                plan["new_game_spawn"]["system_sha256"],
            )
            self.assertEqual(
                hashlib.sha256(b"synthetic escorted Map010").hexdigest(),
                next(item["sha256"] for item in plan["required_existing_maps"]
                     if item["id"] == 10),
            )
            return handoff(candidate, source_root, plan, manifest)

        return (
            patch.object(base_builder, "validate_base_rights",
                         return_value={"archive_sha256": hashlib.sha256(
                             self.archive.read_bytes()).hexdigest()}),
            patch.object(base_builder, "extract_base_archive", return_value=self.base),
            patch.object(base_builder, "source_pin", return_value=("a" * 40, False)),
            patch.object(integration, "stage_project", side_effect=self.fake_stage),
            patch.object(opening, "_run_ruby", side_effect=fake_ruby),
            patch.object(opening, "prepare_native_handoff", side_effect=verify_handoff),
        )

    def run_with(self, handoff, native_engine=None):
        patches = self.patches(handoff)
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            return opening.build(
                self.archive, self.rights, self.sources, self.inputs,
                self.stage_plan, self.native_plan, self.output,
                self.manifest, source_sha="a" * 40, native_engine=native_engine,
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
        self.assertTrue(result["viridian_map_data_migrated"])
        self.assertFalse(result["viridian_engine_verified"])
        self.assertFalse(result["native_game_launched"])
        self.assertFalse(result["gameplay_verified"])
        self.assertFalse(result["save_reload_verified"])
        self.assertEqual(0o700, stat.S_IMODE(self.output.stat().st_mode))
        self.assertEqual(
            ["upgrade_private_viridian_handoff.rb", "upgrade_private_viridian_escort.rb",
             "compile_private_plugins.rb", "finalize_private_runtime.rb"],
            self.ruby_calls,
        )
        self.assertTrue((self.output / opening.REPORT).is_file())
        self.assertIn("Shattered Viridian",
                      json.loads((self.output / "SHATTERED_INTEGRATION_BUILD.json").read_text())
                      ["declared_plugin_load_order"])
        self.assertTrue((self.output / "Plugins/Shattered Viridian/001_Entry.rb").is_file())
        self.assertTrue((self.output /
                         "SHATTERED_OFFLINE_TOOLS/Shattered Viridian/002_Install.rb").is_file())
        self.assertEqual(self.plugin_archive,
                         (self.output / "Data/PluginScripts.rxdata").read_bytes())
        self.assertTrue(self.archive.is_file())
        self.assertTrue((self.base).is_dir())

    def test_native_engine_path_runs_pbs_before_gate_route_installer(self):
        engine = self.root / "mkxp-z"
        engine.write_text("synthetic executable")
        engine.chmod(0o755)
        result = self.run_with(lambda *args, **kwargs: {
            "status": "native_install_pending",
            "plan_sha256": "d" * 64,
            "native_execution_verified": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
        }, native_engine=engine)
        self.assertTrue(result["native_pbs_compiled"])
        self.assertTrue(result["native_maps_installed"])
        self.assertFalse(result["native_game_launched"])
        self.assertFalse(result["gameplay_verified"])
        self.assertEqual(
            ["upgrade_private_viridian_handoff.rb", "upgrade_private_viridian_escort.rb",
             "compile_private_plugins.rb", "finalize_private_runtime.rb",
             "compile_private_pbs_native.rb", "install_private_initial_slice_native.rb"],
            self.ruby_calls,
        )

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

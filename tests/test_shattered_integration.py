import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import shattered_integration as integration


class ShatteredIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = integration.load_manifest()

    def test_manifest_pins_live_prs_and_compatibility_order(self):
        result = integration.validate_manifest(self.manifest)
        self.assertEqual(12, result["pull_requests"])
        self.assertEqual(10, result["components"])
        self.assertEqual(7, result["map_slots"])
        self.assertEqual("Shattered Core", result["load_order"][3])

    def test_merged_source_ledger_cannot_drift_from_pinned_main(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["main"]["commit"] = "0" * 40
        with self.assertRaisesRegex(integration.IntegrationError, "inspected main commit is stale"):
            integration.validate_manifest(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest["pull_requests"][2]["state"] = "open_draft"
        with self.assertRaisesRegex(integration.IntegrationError, "merged PR ledger differs"):
            integration.validate_manifest(manifest)

    def test_wrong_stacked_branch_ancestry_fails(self):
        manifest = copy.deepcopy(self.manifest)
        route22 = next(pr for pr in manifest["pull_requests"] if pr["id"] == 15)
        route22["base"] = manifest["main"]["commit"]
        with self.assertRaisesRegex(integration.IntegrationError, "wrong branch ancestry"):
            integration.validate_manifest(manifest)

    def test_queue_task_collision_fails(self):
        task = self.manifest["queue_task"]
        with self.assertRaisesRegex(integration.IntegrationError, "queue ID collision"):
            integration.validate_queue(
                {"tasks": [{"id": task["id"], "title": "different assignment"}]},
                self.manifest,
            )
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate integration queue"):
            integration.validate_queue(
                {"tasks": [{"id": "SE-001"}, {"id": "SE-001"}]},
                self.manifest,
            )

    def test_duplicate_plugin_name_fails(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["components"][1]["name"] = manifest["components"][0]["name"]
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate plugin name"):
            integration.validate_manifest(manifest)

    def test_duplicate_capture_hook_fails(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["components"][-1]["hook_claims"].append(
            "ItemHandlers::CanUseInBattle:POKEBALL"
        )
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate hook claim"):
            integration.validate_manifest(manifest)

    def test_duplicate_gear_hook_fails_closed(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["components"][0]["hook_claims"] = ["synthetic-fixture-gear-hook"]
        manifest["components"][1]["hook_claims"].append("synthetic-fixture-gear-hook")
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate hook claim"):
            integration.validate_manifest(manifest)

    def test_unordered_overlapping_map_writes_fail(self):
        manifest = copy.deepcopy(self.manifest)
        links = next(component for component in manifest["components"] if component["id"] == "world_links")
        links["build_requires"].remove(10)
        with self.assertRaisesRegex(integration.IntegrationError, "unordered overlapping map writes"):
            integration.validate_manifest(manifest)

    def test_archive_missing_fails_closed(self):
        project, source_root, inputs, plan, _ = self._fixture()
        plan["archives"].pop("hotfixes")
        with self.assertRaisesRegex(integration.IntegrationError, "missing required plugin archive"):
            integration._validate_plan(plan, self.manifest, project, inputs)

    def test_archive_traversal_and_bad_rights_record_fail_closed(self):
        project, source_root, inputs, plan, _ = self._fixture()
        archive_path = inputs / plan["archives"]["hotfixes"]["source"]
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("release/Plugins/v21.1 Hotfixes/meta.txt", "Name = v21.1 Hotfixes\nVersion = 1.0.9\n")
            archive.writestr("../outside.rb", "not allowed")
        plan["archives"]["hotfixes"]["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(integration.IntegrationError, "unsafe archive path"):
            integration._validate_plan(plan, self.manifest, project, inputs)

        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr(
                "release/Plugins/v21.1 Hotfixes/meta.txt",
                "Name = v21.1 Hotfixes\nVersion = 1.0.9\n",
            )
        plan["archives"]["hotfixes"]["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        plan["assets"]["hns_reception_gate_tileset"]["rights_record_sha256"] = "0" * 64
        with self.assertRaisesRegex(integration.IntegrationError, "rights record hash mismatch"):
            integration._validate_plan(plan, self.manifest, project, inputs)

    def test_archive_capture_hook_conflict_fails_closed(self):
        project, source_root, inputs, plan, _ = self._fixture()
        archive_path = inputs / plan["archives"]["hotfixes"]["source"]
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr(
                "release/Plugins/v21.1 Hotfixes/meta.txt",
                "Name = v21.1 Hotfixes\nVersion = 1.0.9\n",
            )
            archive.writestr(
                "release/Plugins/v21.1 Hotfixes/capture.rb",
                "ItemHandlers::CanUseInBattle.add(:POKEBALL, proc {})\n",
            )
        plan["archives"]["hotfixes"]["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(integration.IntegrationError, "conflicting plugin hooks"):
            integration._validate_plan(plan, self.manifest, project, inputs)

    def test_unreviewed_or_missing_graphics_fail_closed(self):
        project, source_root, inputs, plan, _ = self._fixture()
        del plan["assets"]["route22_rattata_sprite"]
        with self.assertRaisesRegex(integration.IntegrationError, "asset inventory mismatch"):
            integration._validate_plan(plan, self.manifest, project, inputs)
        plan["assets"]["route22_rattata_sprite"] = {
            "source": "assets/missing.png",
            "destination": "Graphics/Characters/Rattata.png",
            "sha256": "0" * 64,
            "rights_reviewed": True,
        }
        with self.assertRaisesRegex(integration.IntegrationError, "missing regular file for asset"):
            integration._validate_plan(plan, self.manifest, project, inputs)

    def test_duplicate_switch_and_inconsistent_map_id_fail(self):
        project, source_root, inputs, plan, _ = self._fixture()
        plan["switch_ids"]["route22_cleared"] = plan["switch_ids"]["route22_scatter"]
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate event resource ID"):
            integration._validate_plan(plan, self.manifest, project, inputs)
        plan["switch_ids"]["route22_cleared"] += 1
        plan["map_targets"]["route22"]["id"] = plan["map_targets"]["reception_gate"]["id"]
        with self.assertRaisesRegex(integration.IntegrationError, "target map ID missing or duplicated"):
            integration._validate_plan(plan, self.manifest, project, inputs)

    def test_initial_slice_preflight_reports_exact_unavailable_inputs(self):
        project = self.root / "missing-project"
        sources = self.root / "missing-sources"
        inputs = self.root / "missing-inputs"
        report = integration.diagnose_preflight(
            project, sources, inputs, {}, self.manifest, "initial_slice"
        )
        self.assertEqual("BLOCKED", report["status"])
        self.assertIn(
            "missing required plugin archive hotfixes v1.0.9: archives/v21.1-hotfixes.zip",
            report["blockers"],
        )
        self.assertIn(
            "missing asset input hns_reception_gate_tileset: assets/tilesets/ReceptionGate.png",
            report["blockers"],
        )
        self.assertTrue(any("source permission" in item for item in report["blockers"]))
        self.assertIn("missing Essentials project file: Game.ini", report["blockers"])

    def test_missing_source_and_modified_source_hash_fail(self):
        project, source_root, inputs, plan, lock = self._fixture()
        missing = source_root / "pr-19" / "essentials/Plugins/Shattered Raid/meta.txt"
        missing.write_text("changed source")
        with self.assertRaisesRegex(integration.IntegrationError, "source file hash mismatch"):
            integration.verify_source_bundle(source_root, self.manifest, synthetic_fixture=True)
        missing.unlink()
        with self.assertRaisesRegex(integration.IntegrationError, "missing regular file for PR"):
            integration.verify_source_bundle(source_root, self.manifest, synthetic_fixture=True)

    def test_private_stage_is_atomic_and_does_not_modify_source(self):
        project, source_root, inputs, plan, _ = self._fixture()
        (project / ".git").mkdir()
        (project / ".git" / "config").write_text("private repository metadata")
        original_pokemon = (project / "PBS/pokemon.txt").read_bytes()
        output = self.root / "staged"
        report = integration.stage_project(
            project, source_root, inputs, plan, output, self.manifest, synthetic_fixture=True
        )
        self.assertEqual("synthetic-fixture", report["evidence_tier"])
        self.assertFalse(report["pbs_compiled"])
        self.assertTrue((output / "SHATTERED_INTEGRATION_BUILD.json").is_file())
        self.assertEqual(original_pokemon, (project / "PBS/pokemon.txt").read_bytes())
        staged_pokemon = (output / "PBS/pokemon.txt").read_text()
        self.assertEqual(1, staged_pokemon.count("[HUMAN]"))
        self.assertEqual(1, (output / "PBS/items.txt").read_text().count("[SHATTEREDGATEKEY]"))
        self.assertTrue((output / "Plugins/Shattered Raid/001_Raid.rb").is_file())
        self.assertTrue((output / "Graphics/Characters/route22_rattata_sprite.png").is_file())
        self.assertFalse((output / ".git").exists())

    def test_stage_refuses_conflicting_pbs_and_existing_output(self):
        project, source_root, inputs, plan, _ = self._fixture()
        with (project / "PBS/items.txt").open("a") as stream:
            stream.write("\n[SHATTEREDGATEKEY]\nName = Different\n")
        with self.assertRaisesRegex(integration.IntegrationError, "conflicting PBS section"):
            integration.stage_project(
                project, source_root, inputs, plan, self.root / "bad-output",
                self.manifest, synthetic_fixture=True,
            )
        self.assertFalse((self.root / "bad-output").exists())

    def test_missing_required_pbs_species_fails_without_output(self):
        project, source_root, inputs, plan, _ = self._fixture()
        pokemon = project / "PBS/pokemon.txt"
        pokemon.write_text(pokemon.read_text().replace("\n\n[RATTATA]\nName = Rattata\n", ""))
        output = self.root / "bad-pbs-output"
        with self.assertRaisesRegex(integration.IntegrationError, "PBS species definition"):
            integration.stage_project(
                project, source_root, inputs, plan, output, self.manifest, synthetic_fixture=True
            )
        self.assertFalse(output.exists())

    def _fixture(self):
        project = self.root / "project"
        source_root = self.root / "source-bundle"
        inputs = self.root / "inputs"
        for path in ("Data", "PBS", "Plugins"):
            (project / path).mkdir(parents=True, exist_ok=True)
        for path, content in {
            "Game.ini": "[Game]\nTitle=Fixture\n",
            "Data/Scripts.rxdata": b"synthetic scripts",
            "Data/MapInfos.rxdata": b"synthetic infos",
            "PBS/pokemon.txt": "[PIKACHU]\nName = Pikachu\n\n[RATTATA]\nName = Rattata\n\n[BEEDRILL]\nName = Beedrill\n",
            "PBS/items.txt": "[POTION]\nName = Potion\n",
        }.items():
            path = project / path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content if isinstance(content, bytes) else content.encode())
        targets = {}
        for index, (slot, requirement) in enumerate(self.manifest["target_map_slots"].items(), 1):
            map_id = 100 + index
            map_path = project / "Data" / f"Map{map_id:03d}.rxdata"
            map_path.write_bytes(f"synthetic map {slot}".encode())
            targets[slot] = {
                "id": map_id,
                "sha256": hashlib.sha256(map_path.read_bytes()).hexdigest(),
                "dimensions": requirement["dimensions"] or [10, 9],
                "source_uuid": requirement["source_uuid"] or f"fixture:{slot}",
                "reviewed": True,
                "map_info_reviewed": True,
            }

        source_root.mkdir()
        file_hashes = {}
        plugin_names = {}
        for component in self.manifest["components"]:
            plugin_names[component["pr"]] = (component["name"], component["version"])
        for item in self.manifest["required_source_files"]:
            path = source_root / f"pr-{item['pr']}" / item["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            if item["path"].endswith("meta.txt"):
                name, version = plugin_names[item["pr"]]
                content = f"Name = {name}\nVersion = {version}\n"
            elif item["path"].endswith("HUMAN.pbs"):
                content = "[HUMAN]\nName = Human\n"
            elif item["path"].endswith("SHATTEREDGATEKEY.pbs"):
                content = "[SHATTEREDGATEKEY]\nName = Gate Key\n"
            elif item["path"].endswith(".json"):
                content = "{}\n"
            elif item["path"].endswith(".py"):
                content = "# synthetic fixture source\n"
            else:
                content = "# synthetic fixture plugin source\n"
            path.write_text(content)
            file_hashes[f"{item['pr']}:{item['path']}"] = hashlib.sha256(path.read_bytes()).hexdigest()
        lock = {
            "schema_version": 1,
            "synthetic_fixture": True,
            "pull_requests": integration._source_lock_record(self.manifest),
            "files": file_hashes,
        }
        (source_root / integration.LOCK_NAME).write_text(json.dumps(lock))

        inputs.mkdir()
        assets = {}
        for asset in self.manifest["asset_requirements"]:
            source = f"assets/{asset['id']}.bin"
            asset_path = inputs / source
            asset_path.parent.mkdir(parents=True, exist_ok=True)
            asset_path.write_bytes(f"synthetic asset {asset['id']}".encode())
            assets[asset["id"]] = {
                "source": source,
                "destination": (
                    "Graphics/Tilesets/ReceptionGate.png"
                    if asset["id"] == "hns_reception_gate_tileset"
                    else f"Graphics/Characters/{asset['id']}.png"
                ),
                "sha256": hashlib.sha256(asset_path.read_bytes()).hexdigest(),
                "rights_reviewed": True,
            }
            rights_source = f"rights/{asset['id']}.json"
            rights_path = inputs / rights_source
            rights_path.parent.mkdir(parents=True, exist_ok=True)
            rights_path.write_text(json.dumps({
                "id": asset["id"],
                "type": "asset",
                "rights_cleared": True,
                "source": "synthetic fixture only",
                "license": "synthetic fixture",
                "basis": "test data, not for redistribution",
            }))
            assets[asset["id"]]["rights_record"] = rights_source
            assets[asset["id"]]["rights_record_sha256"] = hashlib.sha256(
                rights_path.read_bytes()
            ).hexdigest()
        assets["hns_reception_gate_mapping"]["destination"] = None

        archives = {}
        for archive in self.manifest["plugin_archives"]:
            if not archive.get("required"):
                continue
            source = f"archives/{archive['id']}.zip"
            archive_path = inputs / source
            archive_path.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(archive_path, "w") as bundle:
                bundle.writestr(
                    f"release/Plugins/{archive['name']}/meta.txt",
                    f"Name = {archive['name']}\nVersion = {archive['version']}\n",
                )
            archives[archive["id"]] = {
                "source": source,
                "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                "license_reviewed": True,
                "reviewed_hooks": [],
            }
            rights_source = f"rights/{archive['id']}.json"
            rights_path = inputs / rights_source
            rights_path.parent.mkdir(parents=True, exist_ok=True)
            rights_path.write_text(json.dumps({
                "id": archive["id"],
                "type": "plugin_archive",
                "rights_cleared": True,
                "source": archive["source"],
                "license": "synthetic fixture",
                "basis": "test data, not for redistribution",
            }))
            archives[archive["id"]]["rights_record"] = rights_source
            archives[archive["id"]]["rights_record_sha256"] = hashlib.sha256(
                rights_path.read_bytes()
            ).hexdigest()
        project_rights = inputs / "rights/base-project.json"
        project_rights.parent.mkdir(parents=True, exist_ok=True)
        project_rights.write_text(json.dumps({
            "id": "base_project",
            "type": "essentials_project",
            "engine_version": "21.1",
            "rights_cleared": True,
            "source": "synthetic fixture only",
            "license": "synthetic fixture",
            "basis": "test data, not for redistribution",
        }))
        switches = {name: index + 1 for index, name in enumerate(self.manifest["runtime_resources"]["switch_ids"])}
        variables = {name: index + 1 for index, name in enumerate(self.manifest["runtime_resources"]["variable_ids"])}
        plan = {
            "authorization": {
                "engine_version": "21.1",
                "source_authorized": True,
                "rights_record": "rights/base-project.json",
                "rights_record_sha256": hashlib.sha256(project_rights.read_bytes()).hexdigest(),
            },
            "map_targets": targets,
            "switch_ids": switches,
            "variable_ids": variables,
            "assets": assets,
            "archives": archives,
        }
        return project, source_root, inputs, plan, lock


if __name__ == "__main__":
    unittest.main()

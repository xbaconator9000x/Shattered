import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))
import shattered_integration as integration
import shattered_integration_handoff as handoff


class ShatteredNativeHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = integration.load_manifest()
        from test_shattered_integration import ShatteredIntegrationTests

        fixture = ShatteredIntegrationTests()
        fixture.root = self.root
        fixture.manifest = self.manifest
        base, self.sources, self.inputs, self.stage_plan, _ = fixture._fixture()
        lock_path = self.sources / integration.LOCK_NAME
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        selected_prs = set(integration._profile_config(self.manifest, "initial_slice")["source_prs"])
        lock["profile"] = "initial_slice"
        lock["pull_requests"] = integration._source_lock_record(self.manifest, selected_prs)
        lock["files"] = {
            key: value for key, value in lock["files"].items()
            if int(key.split(":", 1)[0]) in selected_prs
        }
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        self.project = self.root / "staged"
        shutil.copytree(base, self.project)
        self.base_digest = integration.project_tree_digest(base)
        self.native_plan = self._prepare_project()

    def _prepare_project(self):
        profile = integration._profile_config(self.manifest, "initial_slice")
        for path in ("Data", "Audio/SE", "Graphics/Tilesets",
                     "Graphics/Characters", "PBS", "Plugins"):
            (self.project / path).mkdir(parents=True, exist_ok=True)
        (self.project / "Data/Tilesets.rxdata").write_bytes(b"synthetic tilesets")
        (self.project / "Data/System.rxdata").write_bytes(b"synthetic original RPG System")

        png_header = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" + struct.pack(">II", 256, 32)
        for asset_id in profile["assets"]:
            record = self.stage_plan["assets"][asset_id]
            source = self.inputs / record["source"]
            if asset_id == "hns_reception_gate_tileset":
                source.write_bytes(png_header)
                record["sha256"] = hashlib.sha256(png_header).hexdigest()
            destination = record.get("destination")
            if asset_id == "aipom_sprite":
                destination = "Graphics/Characters/Aipom.png"
            elif asset_id == "route22_rattata_sprite":
                destination = "Graphics/Characters/Rattata.png"
            if destination:
                target = self.project / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)

        for item in self.manifest["required_source_files"]:
            if item["pr"] not in profile["source_prs"] or not item.get("stage"):
                continue
            relative = Path(*Path(item["path"]).parts[2:])
            target = self.project / "Plugins" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.sources / f"pr-{item['pr']}" / item["path"], target)

        (self.project / "PBS/items.txt").write_text(
            "[POTION]\nName = Potion\n\n[SHATTEREDGATEKEY]\nName = HnS Gate Key\n",
            encoding="utf-8",
        )
        (self.project / "PBS/pokemon.txt").write_text(
            "[HUMAN]\nName = Human\n\n[RATTATA]\nName = Rattata\n",
            encoding="utf-8",
        )

        gate_id = self.stage_plan["map_targets"]["reception_gate"]["id"]
        route_id = self.stage_plan["map_targets"]["route22"]["id"]
        target_map_ids = {"route22": route_id, "route28": 201, "route26": 203, "victory_road": 204}
        existing_maps = []
        for name, map_id in target_map_ids.items():
            path = self.project / f"Data/Map{map_id:03d}.rxdata"
            if not path.exists():
                path.write_bytes(f"synthetic {name}".encode())
            existing_maps.append({
                "id": map_id,
                "dimensions": [48, 24] if name == "route22" else [30, 30],
                "sha256": integration.sha256(path),
                "reviewed": True,
                "map_info_reviewed": True,
            })

        source_spec = next(item for item in self.manifest["source_projects"]
                           if item["id"] == "hns_reception_gate")
        source_hashes = {
            "map_sha256": source_spec["source_files"][0]["sha256"],
            "layout_sha256": source_spec["source_files"][1]["sha256"],
            "blockdata_sha256": source_spec["source_files"][2]["sha256"],
        }
        hns_warps = []
        for direction, positions in handoff.HNS_DIRECTIONS.items():
            for index, (x, y) in enumerate(positions):
                map_id = target_map_ids[
                    {"west": "route28", "east": "route22", "south": "route26",
                     "north": "victory_road"}[direction]
                ]
                hns_warps.append({
                    "direction": direction,
                    "x": x,
                    "y": y,
                    "target": {
                        "map_id": map_id, "x": 1 + index, "y": 2,
                        "direction": 2, "fade": 0,
                    },
                })
        hns_config = {
            "format": "shattered-hns-rmxp-map",
            "format_version": 1,
            "map_name": "Heart & Soul League Reception Gate",
            "dimensions": {"width": 22, "height": 21, "tile_pixels": 32},
            "target": {
                "map_id": gate_id,
                "tileset_template_id": 1,
                "tileset_name": "ReceptionGate",
                "tileset_image": "ReceptionGate.png",
            },
            "source": {
                "repository": "https://github.com/" + source_spec["repository"],
                "revision": source_spec["commit"],
                "map_path": source_spec["source_files"][0]["path"],
                "layout_path": source_spec["source_files"][1]["path"],
                "blockdata_path": source_spec["source_files"][2]["path"],
                **source_hashes,
            },
            "layers": [[0] * (22 * 21) for _ in range(3)],
            "tileset_tables": {"0": [0, 0, 0]},
            "warps": hns_warps,
        }
        links = {
            "format": "shattered-world-links",
            "format_version": 1,
            "maps": [
                {"map_id": gate_id, "width": 22, "height": 21},
                {"map_id": route_id, "width": 48, "height": 24},
            ],
            "events": [
                {"link_id": "gate-route22", "side": "F", "map_id": gate_id,
                 "x": 3, "y": 3,
                 "destination": {"map_id": route_id, "x": 4, "y": 4, "direction": 8, "fade": 0}},
                {"link_id": "gate-route22", "side": "R", "map_id": route_id,
                 "x": 30, "y": 5,
                 "destination": {"map_id": gate_id, "x": 4, "y": 4, "direction": 2, "fade": 0}},
            ],
        }
        story = {
            "schema_version": 1,
            "flag_plan": handoff.STORY_FLAG_PLAN,
            "map_id": gate_id,
            "positions": {
                "collapse": {"x": 9, "y": 11},
                "aipom": {"x": 11, "y": 2},
                "johto_block": {"x": 11, "y": 19},
            },
            "collapse_sounds": [f"GateCollapse{i}" for i in range(1, 7)],
            "final_roar_sound": "GateFinalRoar",
            "aipom_cry": "AipomCry",
            "aipom_character": "Aipom",
            "expected_south_transfer": [0, target_map_ids["route26"], 1, 2, 2, 0],
        }
        route_path = self.project / f"Data/Map{route_id:03d}.rxdata"
        route_hash = integration.sha256(route_path)
        switch_ids = {"route22_scatter": 80, "route22_cleared": 81}
        variable_ids = {"route22_outcome": 21}
        route_config = {
            "schema_version": 1,
            "source_map_uuid": handoff.ROUTE22_UUID,
            "map_id": route_id,
            "expected_map_sha256": route_hash,
            "outcome_variable": 21,
            "scatter_switch": 80,
            "cleared_switch": 81,
            "rattata_character": "Rattata",
        }
        native_plan = {
            "schema_version": 1,
            "profile": "initial_slice",
            "map_targets": {
                "reception_gate": {
                    "id": gate_id,
                    "source_uuid": self.manifest["target_map_slots"]["reception_gate"]["source_uuid"],
                    "reviewed": True,
                    "map_info_reviewed": True,
                },
                "route22": {
                    "id": route_id,
                    "source_uuid": handoff.ROUTE22_UUID,
                    "dimensions": [48, 24],
                    "sha256": route_hash,
                    "reviewed": True,
                    "map_info_reviewed": True,
                },
            },
            "new_game_spawn": {
                "map_id": gate_id, "x": 5, "y": 5,
                "reviewed": True, "passability_attested": True,
                "system_sha256": integration.sha256(self.project / "Data/System.rxdata"),
            },
            "required_existing_maps": existing_maps,
            "switch_ids": switch_ids,
            "variable_ids": variable_ids,
            "installer_configs": {
                "hns_import": hns_config,
                "world_links": links,
                "gate_story": story,
                "route22": route_config,
            },
        }
        source_pins = []
        for pr in self.manifest["pull_requests"]:
            if pr["id"] not in profile["source_prs"]:
                continue
            resolved = self.manifest["main"]["commit"] if pr["state"] == "merged" else pr["head"]
            source_pins.append({
                "id": pr["id"], "branch": pr["branch"], "commit": pr["head"],
                "base": pr["base"], "state": pr["state"],
                "source_ref": self.manifest["main"]["ref"] if pr["state"] == "merged" else pr["branch"],
                "source_commit": resolved,
            })
        source_prs = [
            {"id": item["id"], "branch": item["branch"], "commit": item["commit"],
             "base": item["base"], "state": item["state"], "source_ref": item["source_ref"],
             "source_commit": item["source_commit"]}
            for item in source_pins
        ]
        asset_hashes = {asset_id: self.stage_plan["assets"][asset_id]["sha256"]
                        for asset_id in profile["assets"]}
        self._build_report = {
            "profile": "initial_slice",
            "source_prs": source_prs,
            "map_targets": {
                "reception_gate": {"id": gate_id, "created_by_installer": True},
                "route22": {"id": route_id, "sha256": route_hash},
            },
            "switch_ids": switch_ids,
            "variable_ids": variable_ids,
            "assets_sha256": asset_hashes,
            "rights_records_sha256": {},
            "source_project_rights_sha256": {},
        }
        (self.project / "SHATTERED_INTEGRATION_BUILD.json").write_text(
            json.dumps(self._build_report, sort_keys=True), encoding="utf-8")
        (self.project / "SHATTERED_STAGING_REPORT.json").write_text(
            json.dumps({
                "engine": "Essentials 21.1", "profile": "initial_slice",
                "source_prs": source_prs,
            }, sort_keys=True), encoding="utf-8")
        return native_plan

    def _prepare(self, plan=None):
        return handoff.prepare_native_handoff(
            self.project, self.sources, copy.deepcopy(plan or self.native_plan),
            self.manifest, synthetic_fixture=True,
        )

    def test_prepares_deterministic_source_pinned_native_pending_handoff(self):
        result = self._prepare()
        plan_path = self.project / result["installer_plan_path"]
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        self.assertEqual("native_install_pending", result["status"])
        self.assertFalse(result["native_execution_verified"])
        self.assertFalse(plan["gameplay_verified"])
        self.assertEqual(handoff.INSTALL_ORDER, plan["installer_apis"])
        self.assertEqual({"map_id": self.native_plan["map_targets"]["reception_gate"]["id"],
                          "x": 5, "y": 5, "reviewed": True, "passability_attested": True},
                         plan["new_game_spawn"])
        self.assertEqual(integration.sha256(self.project / "Data/System.rxdata"),
                         plan["baseline_hashes"]["Data/System.rxdata"])
        merged_ten = next(item for item in plan["source_pins"] if item["id"] == 10)
        self.assertEqual(self.manifest["main"]["commit"], merged_ten["source_commit"])
        runner = (self.project / "Plugins/Shattered Initial Slice Installer/001_Install.rb").read_text()
        self.assertIn(result["plan_sha256"], runner)
        self.assertEqual(self.base_digest, integration.project_tree_digest(self.root / "project"))
        self.assertTrue((self.project / "Plugins/Shattered HnS Gate/reception_gate.json").is_file())

    def test_rejects_unreviewed_occupied_and_out_of_bounds_new_game_spawn(self):
        cases = [
            ({"reviewed": False}, "explicitly reviewed"),
            ({"passability_attested": False}, "explicitly reviewed"),
            ({"map_id": self.native_plan["map_targets"]["route22"]["id"]}, "HnS gate map ID"),
            ({"x": 22}, "outside the HnS reception gate"),
            ({"y": -1}, "outside the HnS reception gate"),
            ({"x": 11, "y": 19}, "overlaps an HnS exit"),
            ({"x": 9, "y": 11}, "overlaps a Gate Story event"),
            ({"x": 3, "y": 3}, "overlaps a world-link event"),
            ({"x": 4, "y": 4}, "overlaps a world-link landing"),
            ({"system_sha256": "0" * 64}, "System.rxdata hash differs"),
        ]
        for changes, expected in cases:
            with self.subTest(changes=changes):
                invalid = copy.deepcopy(self.native_plan)
                invalid["new_game_spawn"].update(changes)
                with self.assertRaisesRegex(integration.IntegrationError, expected):
                    self._prepare(invalid)

    def test_rejects_modified_original_system_data(self):
        system = self.project / "Data/System.rxdata"
        system.write_bytes(b"modified since reviewed baseline")
        with self.assertRaisesRegex(integration.IntegrationError, "System.rxdata hash differs"):
            self._prepare()

    def test_reuses_original_private_aipom_cry_from_cries_subdirectory(self):
        source = self.inputs / self.stage_plan["assets"]["aipom_cry"]["source"]
        nested = self.project / "Audio/SE/Cries/AIPOM.ogg"
        nested.parent.mkdir(parents=True, exist_ok=True)
        nested.write_bytes(source.read_bytes())
        self.native_plan["installer_configs"]["gate_story"]["aipom_cry"] = "Cries/AIPOM"
        result = self._prepare()
        plan = json.loads((self.project / result["installer_plan_path"]).read_text())
        self.assertEqual("Audio/SE/Cries/AIPOM.ogg",
                         plan["asset_files"]["aipom_cry"]["path"])
        self.assertEqual(integration.sha256(nested),
                         plan["asset_files"]["aipom_cry"]["sha256"])

    def test_rejects_aipom_cry_traversal_or_arbitrary_directories(self):
        for unsafe in ("../AIPOM", "Cries/../AIPOM", "Cries//AIPOM", "Other/AIPOM"):
            plan = copy.deepcopy(self.native_plan)
            plan["installer_configs"]["gate_story"]["aipom_cry"] = unsafe
            with self.subTest(unsafe=unsafe):
                with self.assertRaisesRegex(integration.IntegrationError,
                                            "unsafe Gate Story Aipom cry path"):
                    self._prepare(plan)

    def test_rejects_wrong_map_ids_hashes_and_source_file_hashes(self):
        wrong_id = copy.deepcopy(self.native_plan)
        wrong_id["installer_configs"]["hns_import"]["target"]["map_id"] += 1
        with self.assertRaisesRegex(integration.IntegrationError, "target map ID"):
            self._prepare(wrong_id)
        wrong_hash = copy.deepcopy(self.native_plan)
        wrong_hash["map_targets"]["route22"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(integration.IntegrationError, "SHA256 differs"):
            self._prepare(wrong_hash)
        source = self.project / "Plugins/Shattered Route22/002_Install.rb"
        original = source.read_bytes()
        source.write_bytes(original + b"\n# modified\n")
        with self.assertRaisesRegex(integration.IntegrationError, "pinned source"):
            self._prepare()

    def test_rejects_occupied_and_duplicate_event_coordinates(self):
        overlap = copy.deepcopy(self.native_plan)
        overlap["installer_configs"]["world_links"]["events"][0]["x"] = 1
        overlap["installer_configs"]["world_links"]["events"][0]["y"] = 9
        with self.assertRaisesRegex(integration.IntegrationError, "overlaps an HnS source warp"):
            self._prepare(overlap)

        landing = copy.deepcopy(self.native_plan)
        landing["installer_configs"]["world_links"]["events"][1]["destination"]["x"] = 1
        landing["installer_configs"]["world_links"]["events"][1]["destination"]["y"] = 9
        with self.assertRaisesRegex(integration.IntegrationError, "arrival overlaps an HnS exit"):
            self._prepare(landing)

        route_overlap = copy.deepcopy(self.native_plan)
        route_overlap["installer_configs"]["world_links"]["events"][1]["x"] = 36
        route_overlap["installer_configs"]["world_links"]["events"][1]["y"] = 16
        with self.assertRaisesRegex(integration.IntegrationError, "reserved Route22 event coordinate"):
            self._prepare(route_overlap)

        duplicate = copy.deepcopy(self.native_plan)
        duplicate["installer_configs"]["world_links"]["events"][1]["map_id"] = (
            duplicate["map_targets"]["reception_gate"]["id"]
        )
        duplicate["installer_configs"]["world_links"]["events"][1]["x"] = 3
        duplicate["installer_configs"]["world_links"]["events"][1]["y"] = 3
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate world-link event coordinate"):
            self._prepare(duplicate)

        story_overlap = copy.deepcopy(self.native_plan)
        story_overlap["installer_configs"]["gate_story"]["positions"]["collapse"] = {"x": 3, "y": 3}
        with self.assertRaisesRegex(integration.IntegrationError, "overlaps a world-link"):
            self._prepare(story_overlap)

    def test_rejects_missing_asset_and_duplicate_or_partial_handoff(self):
        seed = self.root / "seed"
        shutil.copytree(self.project, seed)
        partial = self.root / "partial"
        shutil.copytree(seed, partial)
        (partial / "Plugins/Shattered Initial Slice Installer").mkdir(parents=True)
        missing_asset = self.root / "missing-asset"
        shutil.copytree(seed, missing_asset)
        self.project = missing_asset
        (self.project / "Graphics/Characters/Aipom.png").unlink()
        with self.assertRaisesRegex(integration.IntegrationError, "missing regular file for native asset"):
            self._prepare()

        self.project = seed
        result = self._prepare()
        self.assertEqual("native_install_pending", result["status"])
        with self.assertRaisesRegex(integration.IntegrationError, "refusing to overwrite"):
            self._prepare()

        self.project = partial
        with self.assertRaisesRegex(integration.IntegrationError, "plugin directory already exists"):
            self._prepare()


if __name__ == "__main__":
    unittest.main()

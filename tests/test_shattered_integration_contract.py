import copy
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import shattered_integration as integration
import shattered_integration_contract as contract


class ShatteredIntegrationContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.manifest = integration.load_manifest()
        plugin_by_pr = {component["pr"]: component for component in self.manifest["components"]}
        for item in self.manifest["required_source_files"]:
            path = self.sources / f"pr-{item['pr']}" / item["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            if item["path"].endswith("meta.txt"):
                component = plugin_by_pr[item["pr"]]
                content = f"Name = {component['name']}\nVersion = {component['version']}\n"
            elif item["path"].endswith("HUMAN.pbs"):
                content = "[HUMAN]\nName = Human\n"
            elif item["path"].endswith("SHATTEREDGATEKEY.pbs"):
                content = "[SHATTEREDGATEKEY]\nName = Gate Key\n"
            else:
                content = "# synthetic source fixture\n"
            path.write_text(content)

    def test_assembles_plugins_in_declared_order_and_pbs_fragments(self):
        output = self.root / "assembled"
        report = contract._assemble_contract_tree(self.sources, output, self.manifest)
        self.assertEqual(len(self.manifest["components"]), report["plugin_count"])
        self.assertEqual(
            self.manifest["load_order"][-len(self.manifest["components"]):],
            report["plugin_names"],
        )
        self.assertEqual(["HUMAN"], report["pbs_sections"]["pokemon.txt"])
        self.assertEqual(["SHATTEREDGATEKEY"], report["pbs_sections"]["items.txt"])
        self.assertFalse(report["runtime_verified"])

    def test_duplicate_plugin_name_in_assembled_tree_fails(self):
        duplicate_meta = (
            self.sources / "pr-11/essentials/Plugins/Shattered Core/meta.txt"
        )
        duplicate_meta.write_text("Name = Shattered HnS Gate\nVersion = 0.2.2\n")
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate plugin name"):
            contract._assemble_contract_tree(
                self.sources, self.root / "duplicate-plugin", self.manifest
            )

    def test_duplicate_assembled_pbs_section_fails(self):
        manifest = copy.deepcopy(self.manifest)
        gate_key = next(
            item for item in manifest["required_source_files"]
            if item.get("pbs_target") == "PBS/items.txt"
        )
        gate_key["pbs_target"] = "PBS/pokemon.txt"
        (self.sources / f"pr-{gate_key['pr']}" / gate_key["path"]).write_text(
            "[HUMAN]\nName = Duplicate\n"
        )
        with self.assertRaisesRegex(integration.IntegrationError, "duplicate assembled PBS section"):
            contract._assemble_contract_tree(
                self.sources, self.root / "duplicate-pbs", manifest
            )


if __name__ == "__main__":
    unittest.main()

import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from validate_integration import validate_plugin_manifest


MANIFEST_PATH = (Path(__file__).resolve().parents[1] /
                 'development' / 'plugin_manifest.json')


class PluginManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST_PATH.read_text())
        self.plugins = {plugin['id']: plugin for plugin in self.manifest['plugins']}

    def test_catalogue_validates_and_unverified_plugins_are_not_runtime_verified(self):
        plugins = validate_plugin_manifest(self.manifest)
        third_party = [plugin for plugin in plugins if plugin['id'] != 'shattered_core']
        self.assertTrue(all(not plugin['runtime_verified'] for plugin in third_party))
        self.assertTrue(all(plugin['source_verification'] == 'unverified'
                            for plugin in third_party))
        self.assertEqual('unverified', self.plugins['feral_tank']['override_verification'])

    def test_rejects_engine_version_mismatch(self):
        self.plugins['following_pokemon_ex']['engine_target'] = 'Pokemon Essentials 20.1'
        with self.assertRaisesRegex(ValueError, 'engine target'):
            validate_plugin_manifest(self.manifest)

    def test_rejects_incompatible_dependency_version_pin(self):
        self.plugins['deluxe_battle_kit']['dependency_version_constraints'] = {
            'hotfixes': '>=1.0.10',
        }
        with self.assertRaisesRegex(ValueError, 'violates >=1.0.10'):
            validate_plugin_manifest(self.manifest)

    def test_rejects_missing_dependency_and_dependency_cycle(self):
        missing = copy.deepcopy(self.manifest)
        next(plugin for plugin in missing['plugins']
             if plugin['id'] == 'deluxe_battle_kit')['dependencies'] = ['missing_plugin']
        with self.assertRaisesRegex(ValueError, 'missing dependency missing_plugin'):
            validate_plugin_manifest(missing)

        cycle = copy.deepcopy(self.manifest)
        next(plugin for plugin in cycle['plugins']
             if plugin['id'] == 'hotfixes')['dependencies'] = ['deluxe_battle_kit']
        with self.assertRaisesRegex(ValueError, 'cycle'):
            validate_plugin_manifest(cycle)

    def test_rejects_conflicting_declared_overrides(self):
        self.plugins['shattered_core']['declared_overrides'] = ['Pokemon#calc_stats']
        with self.assertRaisesRegex(ValueError, 'conflicting override Pokemon#calc_stats'):
            validate_plugin_manifest(self.manifest)

    def test_rejects_runtime_claim_for_uninstalled_plugin(self):
        self.plugins['feral_tank']['runtime_verified'] = True
        with self.assertRaisesRegex(ValueError, 'uninstalled plugin cannot be runtime-verified'):
            validate_plugin_manifest(self.manifest)


if __name__ == '__main__':
    unittest.main()

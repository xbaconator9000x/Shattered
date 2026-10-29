import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from stage_essentials import stage, safe_zip_install, clean_path
from validate_integration import validate


class StagingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = self.root / 'source'
        (self.project / 'PBS').mkdir(parents=True)
        (self.project / 'Plugins' / 'v21.1 Hotfixes').mkdir(parents=True)
        (self.project / 'Game.ini').write_text('[Game]\nTitle=Sample')
        (self.project / 'PBS/pokemon.txt').write_text('[PIKACHU]\nName = Pikachu\n')
        (self.project / 'Plugins/v21.1 Hotfixes/meta.txt').write_text('Name = v21.1 Hotfixes\n')

    def test_manifest_dependency_graph(self):
        self.assertEqual(7, validate()['plugins'])

    def test_core_stages_without_altering_base(self):
        out = self.root / 'staged'
        report = stage(self.project, out)
        self.assertEqual('appended', report['core']['human_pbs'])
        self.assertIn('[HUMAN]', (out / 'PBS/pokemon.txt').read_text())
        self.assertTrue((out / 'Plugins/Shattered Core/001_Core.rb').exists())
        self.assertNotIn('[HUMAN]', (self.project / 'PBS/pokemon.txt').read_text())
        self.assertTrue((out / 'SHATTERED_STAGING_REPORT.json').exists())

    def test_preexisting_human_not_duplicated(self):
        (self.project / 'PBS/pokemon.txt').write_text('[HUMAN]\nName = Human\n')
        report = stage(self.project, self.root / 'staged')
        self.assertEqual('already-present', report['core']['human_pbs'])

    def test_zip_traversal_is_rejected(self):
        p = self.root / 'bad.zip'
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('../outside.rb', 'evil')
        with self.assertRaises(ValueError):
            safe_zip_install(p, self.project, 'following_pokemon_ex')
        self.assertFalse((self.root / 'outside.rb').exists())

    def test_zip_symlink_rejected(self):
        p = self.root / 'bad.zip'
        with zipfile.ZipFile(p, 'w') as z:
            info = zipfile.ZipInfo('Plugins/link.rb')
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            z.writestr(info, 'another-file')
        with self.assertRaises(ValueError):
            safe_zip_install(p, self.project, 'following_pokemon_ex')

    def test_clean_plugin_archive_and_dependency(self):
        p = self.root / 'follower.zip'
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('release/Plugins/Following Pokemon EX/meta.txt', 'Name = Following Pokemon EX\n')
        result = stage(self.project, self.root / 'staged', [f'following_pokemon_ex={p}'])
        self.assertEqual(1, len(result['plugin_archives']['following_pokemon_ex']))
        self.assertTrue((self.root / 'staged/Plugins/Following Pokemon EX/meta.txt').exists())

    def test_archive_collision_aborts_without_creating_output(self):
        p = self.root / 'collision.zip'
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('Plugins/v21.1 Hotfixes/meta.txt', 'Name = replaced')
        with self.assertRaises(ValueError):
            stage(self.project, self.root / 'staged', [f'hotfixes={p}'])
        self.assertFalse((self.root / 'staged').exists())

    def test_required_dbk_parent_gate(self):
        p = self.root / 'ui.zip'
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('Plugins/Enhanced UI/meta.txt', 'plugin')
        with self.assertRaisesRegex(ValueError, 'requires deluxe_battle_kit'):
            stage(self.project, self.root / 'staged', [f'enhanced_battle_ui={p}'])


if __name__ == '__main__':
    unittest.main()

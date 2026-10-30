import json
import os
import binascii
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from stage_essentials import stage, safe_zip_install, clean_path
from validate_integration import validate


def png_fixture(width, height):
    def chunk(name, data):
        body = name + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', binascii.crc32(body) & 0xFFFFFFFF)
    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    pixels = zlib.compress((b'\x00' + b'\x00' * width * 4) * height)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) +
            chunk(b'IDAT', pixels) + chunk(b'IEND', b''))


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

    def test_source_project_symlink_cannot_copy_outside_authorised_tree(self):
        outside = self.root / 'private'
        outside.mkdir()
        (outside / 'secret.txt').write_text('private content')
        (self.project / 'Plugins' / 'linked').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'project contains symlink'):
            stage(self.project, self.root / 'staged')
        self.assertFalse((self.root / 'staged').exists())
        self.assertEqual('private content', (outside / 'secret.txt').read_text())

    def test_archive_symlink_parent_rejected_even_with_overwrite(self):
        outside = self.root / 'private'
        outside.mkdir()
        (outside / 'meta.txt').write_text('original')
        (self.project / 'Plugins' / 'Linked').symlink_to(outside, target_is_directory=True)
        archive = self.root / 'linked.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Plugins/Linked/meta.txt', 'modified')
        with self.assertRaisesRegex(ValueError, 'archive destination contains symlink'):
            safe_zip_install(archive, self.project, 'hotfixes', overwrite=True)
        self.assertEqual('original', (outside / 'meta.txt').read_text())

    def test_archive_hardlink_target_rejected_even_with_overwrite(self):
        outside = self.root / 'private.txt'
        outside.write_text('original')
        linked = self.project / 'Plugins' / 'linked.txt'
        os.link(outside, linked)
        archive = self.root / 'hardlink.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Plugins/linked.txt', 'modified')
        with self.assertRaisesRegex(ValueError, 'unsafe archive overwrite target'):
            safe_zip_install(archive, self.project, 'hotfixes', overwrite=True)
        self.assertEqual('original', outside.read_text())

    def test_duplicate_normalised_archive_destination_fails_before_writes(self):
        archive = self.root / 'duplicate.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('release/Plugins/Following Pokemon EX/meta.txt', 'first')
            z.writestr('Plugins/Following Pokemon EX/meta.txt', 'second')
        with self.assertRaisesRegex(ValueError, 'duplicate archive destination'):
            safe_zip_install(archive, self.project, 'following_pokemon_ex')
        self.assertFalse((self.project / 'Plugins/Following Pokemon EX').exists())

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

    def test_gate_bundle_stages_only_into_separate_copy(self):
        bundle = self.root / 'gate.json'
        bundle.write_text(json.dumps({
            'format': 'shattered-hns-rmxp-map',
            'format_version': 1,
            'target': {'tileset_image': 'SE013_ReceptionGate.png'},
        }))
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(256, 32))
        output = self.root / 'staged'
        report = stage(self.project, output, gate_data=bundle, gate_image=image)
        self.assertFalse(report['hns_gate']['native_map_generated'])
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/001_Import.rb').is_file())
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/meta.txt').is_file())
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/reception_gate.json').is_file())
        self.assertTrue((output / 'Graphics/Tilesets/SE013_ReceptionGate.png').is_file())
        self.assertFalse((self.project / 'Plugins/Shattered HnS Gate').exists())

    def test_gate_bundle_rejects_non_xp_tileset_dimensions(self):
        bundle = self.root / 'gate.json'
        bundle.write_text(json.dumps({
            'format': 'shattered-hns-rmxp-map',
            'format_version': 1,
            'target': {'tileset_image': 'SE013_ReceptionGate.png'},
        }))
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(128, 32))
        with self.assertRaisesRegex(ValueError, '256 pixels wide'):
            stage(self.project, self.root / 'staged', gate_data=bundle, gate_image=image)
        self.assertFalse((self.root / 'staged').exists())


if __name__ == '__main__':
    unittest.main()

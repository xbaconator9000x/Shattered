import json
import os
import binascii
import hashlib
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

    def test_full_runtime_set_stages_all_reviewed_modules_without_modifying_source(self):
        out = self.root / 'staged'
        report = stage(self.project, out, include_runtime_set=True)
        self.assertEqual(9, len(report['runtime_set']['staged']))
        self.assertFalse(report['runtime_set']['native_compiled'])
        self.assertFalse(report['runtime_set']['gameplay_verified'])
        for name in report['runtime_set']['staged']:
            self.assertTrue((out / 'Plugins' / name / 'meta.txt').is_file(), name)
            self.assertFalse((self.project / 'Plugins' / name).exists(), name)
        self.assertTrue((out / 'Plugins/Shattered Gate Story/002_Install.rb').is_file())

    def test_full_runtime_set_refuses_existing_plugin_collision(self):
        collision = self.project / 'Plugins/Shattered Raid'
        collision.mkdir()
        (collision / 'meta.txt').write_text('existing content')
        with self.assertRaisesRegex(ValueError, 'destination collision'):
            stage(self.project, self.root / 'staged', include_runtime_set=True)
        self.assertFalse((self.root / 'staged').exists())
        self.assertEqual('existing content', (collision / 'meta.txt').read_text())

    def test_full_runtime_set_cannot_double_install_equipment(self):
        with self.assertRaisesRegex(ValueError, 'OR --include-equipment'):
            stage(self.project, self.root / 'staged', include_runtime_set=True,
                  include_equipment=True)
        self.assertFalse((self.root / 'staged').exists())

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

    def test_source_project_hardlink_rejected_before_copy(self):
        outside = self.root / 'private.txt'
        outside.write_text('do not copy private data')
        linked = self.project / 'Plugins' / 'private.txt'
        os.link(outside, linked)
        with self.assertRaisesRegex(ValueError, 'project contains hardlinked file'):
            stage(self.project, self.root / 'staged')
        self.assertFalse((self.root / 'staged').exists())
        self.assertEqual('do not copy private data', outside.read_text())

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'POSIX FIFO support required')
    def test_source_project_fifo_rejected_without_blocking_copy(self):
        fifo = self.project / 'Plugins' / 'named_pipe'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, 'project contains unsupported special file'):
            stage(self.project, self.root / 'staged')
        self.assertFalse((self.root / 'staged').exists())

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

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'POSIX FIFO support required')
    def test_archive_overwrite_fifo_rejected_before_open(self):
        fifo = self.project / 'Plugins' / 'blocked_pipe'
        os.mkfifo(fifo)
        archive = self.root / 'fifo.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Plugins/blocked_pipe', 'must not block')
        with self.assertRaisesRegex(ValueError, 'unsafe archive overwrite target'):
            safe_zip_install(archive, self.project, 'hotfixes', overwrite=True)
        self.assertTrue(fifo.exists())

    def test_case_only_archive_destination_collision_rejected_before_writes(self):
        archive = self.root / 'casefold.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Plugins/Follower/meta.txt', 'first')
            z.writestr('Plugins/follower/META.TXT', 'second')
        with self.assertRaisesRegex(ValueError, 'duplicate archive destination'):
            safe_zip_install(archive, self.project, 'following_pokemon_ex')
        self.assertFalse((self.project / 'Plugins/Follower').exists())

    def test_file_directory_archive_collision_rejected_before_writes(self):
        archive = self.root / 'parent-conflict.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('Plugins/Blocked', 'first')
            z.writestr('Plugins/Blocked/meta.txt', 'second')
        with self.assertRaisesRegex(ValueError, 'duplicate archive destination'):
            safe_zip_install(archive, self.project, 'following_pokemon_ex')
        self.assertFalse((self.project / 'Plugins/Blocked').exists())

    def test_corrupt_later_zip_member_rejected_before_any_project_write(self):
        archive = self.root / 'corrupt-later.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as z:
            z.writestr('Plugins/NewPlugin/first.txt', 'first valid member')
            z.writestr('Plugins/NewPlugin/second.txt', 'CORRUPT_SECOND_PAYLOAD')
        original = archive.read_bytes()
        self.assertEqual(1, original.count(b'CORRUPT_SECOND_PAYLOAD'))
        archive.write_bytes(original.replace(
            b'CORRUPT_SECOND_PAYLOAD', b'XORRUPT_SECOND_PAYLOAD', 1))
        with self.assertRaises(zipfile.BadZipFile):
            safe_zip_install(archive, self.project, 'following_pokemon_ex')
        self.assertFalse((self.project / 'Plugins/NewPlugin').exists())

    def test_corrupt_plugin_archive_does_not_publish_staged_project(self):
        archive = self.root / 'corrupt-stage.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as z:
            z.writestr('Plugins/NewPlugin/first.txt', 'first valid member')
            z.writestr('Plugins/NewPlugin/second.txt', 'CORRUPT_SECOND_PAYLOAD')
        archive.write_bytes(archive.read_bytes().replace(
            b'CORRUPT_SECOND_PAYLOAD', b'XORRUPT_SECOND_PAYLOAD', 1))
        output = self.root / 'staged'
        with self.assertRaises(zipfile.BadZipFile):
            stage(self.project, output, [f'following_pokemon_ex={archive}'])
        self.assertFalse(output.exists())
        self.assertEqual('[PIKACHU]\nName = Pikachu\n',
                         (self.project / 'PBS/pokemon.txt').read_text())

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
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(256, 32))
        image_sha = hashlib.sha256(image.read_bytes()).hexdigest()
        bundle.write_text(json.dumps({
            'format': 'shattered-hns-rmxp-map',
            'format_version': 1,
            'target': {
                'tileset_image': 'SE013_ReceptionGate.png',
                'tileset_sha256': image_sha,
            },
        }))
        output = self.root / 'staged'
        report = stage(self.project, output, gate_data=bundle, gate_image=image)
        self.assertFalse(report['hns_gate']['native_map_generated'])
        self.assertEqual(image_sha, report['hns_gate']['tileset_sha256'])
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/001_Import.rb').is_file())
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/meta.txt').is_file())
        self.assertTrue((output / 'Plugins/Shattered HnS Gate/reception_gate.json').is_file())
        self.assertTrue((output / 'Graphics/Tilesets/SE013_ReceptionGate.png').is_file())
        self.assertFalse((self.project / 'Plugins/Shattered HnS Gate').exists())

    def test_gate_bundle_rejects_non_xp_tileset_dimensions(self):
        bundle = self.root / 'gate.json'
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(128, 32))
        bundle.write_text(json.dumps({
            'format': 'shattered-hns-rmxp-map',
            'format_version': 1,
            'target': {
                'tileset_image': 'SE013_ReceptionGate.png',
                'tileset_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
            },
        }))
        with self.assertRaisesRegex(ValueError, '256 pixels wide'):
            stage(self.project, self.root / 'staged', gate_data=bundle, gate_image=image)
        self.assertFalse((self.root / 'staged').exists())

    def test_gate_bundle_rejects_mismatched_tileset_hash(self):
        bundle = self.root / 'gate.json'
        bundle.write_text(json.dumps({
            'format': 'shattered-hns-rmxp-map',
            'format_version': 1,
            'target': {
                'tileset_image': 'SE013_ReceptionGate.png',
                'tileset_sha256': '0' * 64,
            },
        }))
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(256, 32))
        with self.assertRaisesRegex(ValueError, 'SHA-256 does not match'):
            stage(self.project, self.root / 'staged', gate_data=bundle, gate_image=image)
        self.assertFalse((self.root / 'staged').exists())

    def test_gate_bundle_rejects_symlinked_inputs(self):
        bundle = self.root / 'gate.json'
        bundle.write_text('{}')
        image = self.root / 'gate.png'
        image.write_bytes(png_fixture(256, 32))
        for data, tileset in (
            (self.root / 'linked-gate.json', image),
            (bundle, self.root / 'linked-gate.png'),
        ):
            target = bundle if data != bundle else image
            linked = data if data != bundle else tileset
            try:
                linked.symlink_to(target)
            except (OSError, NotImplementedError):
                self.skipTest('symlink creation unavailable')
            try:
                with self.assertRaisesRegex(ValueError, 'without symlinked paths'):
                    stage(self.project, self.root / ('staged-' + linked.suffix),
                          gate_data=data, gate_image=tileset)
            finally:
                linked.unlink()

    def road_fixture(self, image_hashes=None):
        source_ids = [
            "MAP_VICTORY_ROAD_KANTO_1F_HNS",
            "MAP_VICTORY_ROAD_KANTO_B1F_HNS",
            "MAP_VICTORY_ROAD_KANTO_B2F_HNS",
        ]
        tilesets = self.root / "road-tilesets"
        tilesets.mkdir(exist_ok=True)
        floors = []
        for index, source_id in enumerate(source_ids):
            name = f"RoadFloor{index}"
            image = tilesets / f"{name}.png"
            image.write_bytes(png_fixture(256, 32))
            sha = hashlib.sha256(image.read_bytes()).hexdigest()
            floors.append({
                "source_map_id": source_id,
                "target": {
                    "map_id": 300 + index,
                    "tileset_template_id": 1,
                    "tileset_name": name,
                    "tileset_image": f"{name}.png",
                    "tileset_sha256": (image_hashes or {}).get(name, sha),
                },
            })
        bundle = self.root / "victory-road.json"
        bundle.write_text(json.dumps({
            "format": "shattered-hns-victory-road-rmxp-bundle",
            "format_version": 1,
            "source_repository": "PokemonHnS-Development/pokehns-expansion",
            "source_revision": "167aa6d537b109bb229c231ddce4616974c4da71",
            "floors": floors,
        }))
        return bundle, tilesets

    def test_victory_road_bundle_and_all_tilesets_stage_offline(self):
        bundle, tilesets = self.road_fixture()
        output = self.root / "road-staged"
        report = stage(self.project, output, road_data=bundle, road_tileset_dir=tilesets)

        staged = report["hns_victory_road"]
        self.assertFalse(staged["native_maps_installed"])
        self.assertEqual(3, len(staged["tilesets"]))
        self.assertTrue((output / staged["bundle"]).is_file())
        self.assertTrue((Path(__file__).resolve().parents[1] /
                         staged["installer_source"]).is_file())
        for name, metadata in staged["tilesets"].items():
            image = output / metadata["path"]
            self.assertTrue(image.is_file())
            self.assertEqual(metadata["sha256"], hashlib.sha256(image.read_bytes()).hexdigest())

    def test_victory_road_bundle_rejects_tileset_hash_mismatch_before_publish(self):
        bundle, tilesets = self.road_fixture({"RoadFloor1": "0" * 64})
        output = self.root / "road-mismatch"
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            stage(self.project, output, road_data=bundle, road_tileset_dir=tilesets)
        self.assertFalse(output.exists())

    def test_victory_road_bundle_rejects_duplicate_map_targets(self):
        bundle, tilesets = self.road_fixture()
        document = json.loads(bundle.read_text())
        document["floors"][2]["target"]["map_id"] = 301
        bundle.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, "invalid or duplicate HnS Victory Road"):
            stage(self.project, self.root / "road-duplicate",
                  road_data=bundle, road_tileset_dir=tilesets)

    def test_victory_road_bundle_rejects_symlinked_tileset_without_publishing(self):
        bundle, tilesets = self.road_fixture()
        image = tilesets / "RoadFloor1.png"
        target = self.root / "real-road.png"
        target.write_bytes(image.read_bytes())
        image.unlink()
        image.symlink_to(target)
        output = self.root / "road-symlink"

        with self.assertRaisesRegex(ValueError, "missing or unsafe HnS Victory Road tileset"):
            stage(self.project, output, road_data=bundle, road_tileset_dir=tilesets)
        self.assertFalse(output.exists())

    def test_victory_road_bundle_rejects_modified_existing_gate_importer(self):
        bundle, tilesets = self.road_fixture()
        plugin = self.project / "Plugins" / "Shattered HnS Gate"
        plugin.mkdir()
        (plugin / "001_Import.rb").write_text("unreviewed")
        (plugin / "meta.txt").write_bytes(
            (Path(__file__).resolve().parents[1] /
             "essentials/Plugins/Shattered HnS Gate/meta.txt").read_bytes()
        )
        output = self.root / "road-modified-importer"

        with self.assertRaisesRegex(ValueError, "differs from reviewed source"):
            stage(self.project, output, road_data=bundle, road_tileset_dir=tilesets)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()

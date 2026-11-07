"""Integration tests for one private, source-pinned compiled Shattered candidate.

Uses synthetic minimal RXData only; never claims native engine/gameplay acceptance.
"""
import hashlib
import binascii
import json
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
import zlib
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_private_native_candidate import build, source_pin
import build_private_native_candidate


def png_fixture(width, height):
    def chunk(name, data):
        body = name + data
        return (struct.pack(">I", len(data)) + body +
                struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixels = zlib.compress((b"\x00" + b"\x00" * width * 4) * height)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", pixels) + chunk(b"IEND", b""))


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
        (self.base / "PBS/items.txt").write_text("[POTION]\nName = Potion\n")
        (self.base / "Data/Map001.rxdata").write_bytes(b"synthetic-map-not-native")
        (self.base / "Data/Scripts.rxdata").write_bytes(b"synthetic-scripts")
        (self.base / "Data/MapInfos.rxdata").write_bytes(b"synthetic-mapinfos")
        (self.base / "Data/Tilesets.rxdata").write_bytes(b"synthetic-tilesets")
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
            self.source_sha_override = None
        except ValueError as error:
            if "uncommitted tracked changes" not in str(error) and \
               "source-only bundle requires explicit" not in str(error):
                raise
            self.requested_sha = 'a' * 40
            self.source_sha_override = (self.requested_sha, False)
        self.base_zip = self.root / "essentials-21.1.zip"
        self.write_base_zip(self.base_zip)
        self.rights_record = self.root / "base-rights.json"
        self.write_rights_record(self.base_zip, self.rights_record)

    def build_candidate(self, *args, **kwargs):
        if self.source_sha_override is None:
            return build(*args, **kwargs)
        with patch.object(build_private_native_candidate, "source_pin",
                          return_value=self.source_sha_override):
            return build(*args, **kwargs)

    def write_base_zip(self, path, extra_entries=(), omit=()):
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as bundle:
            for source in sorted(self.base.rglob("*")):
                if source.is_file():
                    relative = source.relative_to(self.base)
                    if relative.as_posix() not in omit:
                        bundle.write(source, Path("Essentials-21.1") / relative)
            for name, info in extra_entries:
                bundle.writestr(info or name, b"unsafe-test-entry")

    def write_rights_record(self, archive, path, **changes):
        record = {
            "id": "base_project",
            "type": "essentials_project",
            "engine_version": "21.1",
            "rights_cleared": True,
            "source": "official locally obtained Essentials 21.1 distribution",
            "license": "local use authorized",
            "basis": "owner-held license record",
            "archive_sha256": hashlib.sha256(Path(archive).read_bytes()).hexdigest(),
        }
        record.update(changes)
        path.write_text(json.dumps(record))

    def test_full_candidate_compiles_isolates_and_preserves_original(self):
        dest = self.root / "candidate"
        receipt = self.build_candidate(self.base, dest, requested_sha=self.requested_sha, linux_aliases=True)
        self.assertEqual(8, len(receipt["runtime_plugins"]))
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

    def test_clean_authorized_base_archive_bootstraps_candidate(self):
        dest = self.root / "candidate-from-archive"
        receipt = self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                       base_archive=self.base_zip,
                                       rights_record=self.rights_record, linux_aliases=True)
        self.assertEqual("authorized_essentials_21_1_distribution_zip",
                         receipt["base_source"]["kind"])
        self.assertEqual(hashlib.sha256(self.base_zip.read_bytes()).hexdigest(),
                         receipt["base_source"]["archive_sha256"])
        self.assertEqual(hashlib.sha256(self.rights_record.read_bytes()).hexdigest(),
                         receipt["base_source"]["rights_record_sha256"])
        self.assertFalse(receipt["native_engine_launched"])
        self.assertFalse(receipt["hns_gate_installed"])
        self.assertTrue((dest / "SHATTERED_NATIVE_CANDIDATE.json").is_file())
        self.assertTrue((dest / "Data/PluginScripts.rxdata").is_file())
        self.assertTrue(self.base_zip.is_file())

    def test_candidate_bootstrap_stages_converted_gate_bundle_and_private_tileset(self):
        gate_bundle = self.root / "gate.json"
        gate_image = self.root / "ReceptionGateHNS.png"
        gate_image.write_bytes(png_fixture(256, 32))
        gate_bundle.write_text(json.dumps({
            "format": "shattered-hns-rmxp-map",
            "format_version": 1,
            "target": {
                "tileset_image": "ReceptionGateHNS.png",
                "tileset_sha256": hashlib.sha256(gate_image.read_bytes()).hexdigest(),
            },
        }))
        dest = self.root / "candidate-with-gate-source"

        receipt = self.build_candidate(
            self.base, dest, requested_sha=self.requested_sha,
            gate_data=gate_bundle, gate_tileset_image=gate_image
        )

        self.assertTrue(receipt["hns_gate_source_staged"])
        self.assertEqual(hashlib.sha256(gate_image.read_bytes()).hexdigest(),
                         receipt["hns_gate_source_sha256"]["tileset"])
        self.assertFalse(receipt["hns_gate_installed"])
        self.assertTrue((dest / "SHATTERED_OFFLINE_TOOLS/Shattered HnS Gate/reception_gate.json").is_file())
        self.assertEqual(gate_image.read_bytes(),
                         (dest / "Graphics/Tilesets/ReceptionGateHNS.png").read_bytes())

    def test_candidate_stages_reviewed_victory_road_tilesets_and_receipt_hashes(self):
        source_ids = [
            "MAP_VICTORY_ROAD_KANTO_1F_HNS",
            "MAP_VICTORY_ROAD_KANTO_B1F_HNS",
            "MAP_VICTORY_ROAD_KANTO_B2F_HNS",
        ]
        tilesets = self.root / "road-tilesets"
        tilesets.mkdir()
        floors = []
        expected_hashes = {}
        for index, source_id in enumerate(source_ids):
            name = f"RoadFloor{index}"
            image = tilesets / f"{name}.png"
            image.write_bytes(png_fixture(256, 32))
            sha = hashlib.sha256(image.read_bytes()).hexdigest()
            expected_hashes[f"{name}.png"] = sha
            floors.append({
                "source_map_id": source_id,
                "target": {
                    "map_id": 300 + index,
                    "tileset_template_id": 1,
                    "tileset_name": name,
                    "tileset_image": f"{name}.png",
                    "tileset_sha256": sha,
                },
            })
        road_bundle = self.root / "road.json"
        road_bundle.write_text(json.dumps({
            "format": "shattered-hns-victory-road-rmxp-bundle",
            "format_version": 1,
            "source_repository": "PokemonHnS-Development/pokehns-expansion",
            "source_revision": "167aa6d537b109bb229c231ddce4616974c4da71",
            "floors": floors,
        }))
        dest = self.root / "candidate-with-road-data"

        receipt = self.build_candidate(
            self.base, dest, requested_sha=self.requested_sha,
            road_data=road_bundle, road_tileset_dir=tilesets
        )

        self.assertTrue(receipt["hns_victory_road_source_staged"])
        self.assertEqual(expected_hashes,
                         receipt["hns_victory_road_source_sha256"]["tilesets"])
        self.assertFalse(receipt["hns_gate_installed"])
        self.assertTrue((dest / "SHATTERED_OFFLINE_TOOLS/Shattered HnS Gate/victory_road.json").is_file())
        self.assertTrue((Path(__file__).resolve().parents[1] /
                         "scripts/install_hns_gate_victory_road.rb").is_file())
        for name in expected_hashes:
            self.assertTrue((dest / f"Graphics/Tilesets/{name}").is_file())

    def test_optional_native_pbs_step_uses_existing_runner_and_pins_report(self):
        engine = self.root / "fake-mkxp-z"
        engine.write_text("#!/bin/sh\nexit 0\n")
        engine.chmod(0o755)
        destination = self.root / "candidate-with-pbs"
        real_run_ruby = build_private_native_candidate.run_ruby

        def fake_native_compile(script, args):
            if script != "compile_private_pbs_native.rb":
                return real_run_ruby(script, args)
            project = Path(args[args.index("--project") + 1])
            candidate = json.loads((project / "SHATTERED_NATIVE_CANDIDATE.json").read_text())
            report = {
                "kind": "actual_private_essentials_native_pbs_compiler_not_gameplay_acceptance",
                "native_compiler_completed": True,
                "human_species_bytes_present": True,
                "source_sha": candidate["source_sha"],
                "engine_sha256": "1" * 64,
                "original_scripts_sha256": "2" * 64,
                "restored_scripts_sha256": "2" * 64,
                "gameplay_verified": False,
                "save_reload_verified": False,
            }
            (project / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json").write_text(json.dumps(report))
            return report

        with patch.object(build_private_native_candidate, "run_ruby",
                          side_effect=fake_native_compile):
            receipt = self.build_candidate(
                self.base, destination, requested_sha=self.requested_sha,
                native_engine=engine
            )

        self.assertTrue(receipt["native_pbs_compiled"])
        self.assertTrue(receipt["native_pbs_engine_invoked"])
        self.assertFalse(receipt["native_game_launched"])
        self.assertEqual(
            hashlib.sha256((destination / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json").read_bytes()).hexdigest(),
            receipt["native_pbs_report_sha256"],
        )
        self.assertFalse(receipt["native_engine_launched"])
        self.assertFalse(receipt["gameplay_verified"])

    def test_optional_native_pbs_failure_does_not_publish_candidate(self):
        engine = self.root / "fake-mkxp-z"
        engine.write_text("#!/bin/sh\nexit 9\n")
        engine.chmod(0o755)
        destination = self.root / "candidate-pbs-failure"
        real_run_ruby = build_private_native_candidate.run_ruby

        def failed_native_compile(script, args):
            if script == "compile_private_pbs_native.rb":
                raise RuntimeError("native PBS compilation failed")
            return real_run_ruby(script, args)

        with patch.object(build_private_native_candidate, "run_ruby",
                          side_effect=failed_native_compile):
            with self.assertRaisesRegex(RuntimeError, "native PBS compilation failed"):
                self.build_candidate(
                    self.base, destination, requested_sha=self.requested_sha,
                    native_engine=engine
                )
        self.assertFalse(destination.exists())

    def test_optional_native_pbs_rejects_incomplete_runner_receipt(self):
        engine = self.root / "fake-mkxp-z"
        engine.write_text("#!/bin/sh\nexit 0\n")
        engine.chmod(0o755)
        destination = self.root / "candidate-pbs-incomplete-report"
        real_run_ruby = build_private_native_candidate.run_ruby

        def incomplete_native_compile(script, args):
            if script != "compile_private_pbs_native.rb":
                return real_run_ruby(script, args)
            project = Path(args[args.index("--project") + 1])
            candidate = json.loads((project / "SHATTERED_NATIVE_CANDIDATE.json").read_text())
            report = {"native_compiler_completed": True, "source_sha": candidate["source_sha"]}
            (project / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json").write_text(json.dumps(report))
            return report

        with patch.object(build_private_native_candidate, "run_ruby",
                          side_effect=incomplete_native_compile):
            with self.assertRaisesRegex(RuntimeError, "report failed candidate verification"):
                self.build_candidate(
                    self.base, destination, requested_sha=self.requested_sha,
                    native_engine=engine
                )
        self.assertFalse(destination.exists())

    def test_archive_bootstrap_requires_complete_sha_pinned_rights_record(self):
        dest = self.root / "candidate-from-unreviewed-archive"
        wrong_hash = self.root / "wrong-hash-rights.json"
        self.write_rights_record(self.base_zip, wrong_hash, archive_sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "SHA256 differs"):
            self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                 base_archive=self.base_zip, rights_record=wrong_hash)
        self.assertFalse(dest.exists())

        bad_version = self.root / "wrong-version-rights.json"
        self.write_rights_record(self.base_zip, bad_version, engine_version="20.1")
        with self.assertRaisesRegex(ValueError, "authorized Essentials 21.1"):
            self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                 base_archive=self.base_zip, rights_record=bad_version)
        self.assertFalse(dest.exists())

        with self.assertRaisesRegex(ValueError, "requires a SHA-pinned"):
            self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                 base_archive=self.base_zip)
        self.assertFalse(dest.exists())

    def test_archive_bootstrap_rejects_traversal_symlink_and_duplicate_paths(self):
        traversal = self.root / "traversal.zip"
        self.write_base_zip(traversal, [("../outside.txt", None)])
        traversal_rights = self.root / "traversal-rights.json"
        self.write_rights_record(traversal, traversal_rights)
        with self.assertRaisesRegex(ValueError, "unsafe base archive path"):
            self.build_candidate(None, self.root / "traversal-candidate",
                                 requested_sha=self.requested_sha, base_archive=traversal,
                                 rights_record=traversal_rights)
        self.assertFalse((self.root / "outside.txt").exists())
        self.assertFalse((self.root / "traversal-candidate").exists())

        symlink = self.root / "symlink.zip"
        link_info = zipfile.ZipInfo("Essentials-21.1/linked")
        link_info.create_system = 3
        link_info.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_base_zip(symlink, [("Essentials-21.1/linked", link_info)])
        symlink_rights = self.root / "symlink-rights.json"
        self.write_rights_record(symlink, symlink_rights)
        with self.assertRaisesRegex(ValueError, "non-regular"):
            self.build_candidate(None, self.root / "symlink-candidate",
                                 requested_sha=self.requested_sha, base_archive=symlink,
                                 rights_record=symlink_rights)
        self.assertFalse((self.root / "symlink-candidate").exists())

        duplicate = self.root / "duplicate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            self.write_base_zip(duplicate, [("Essentials-21.1/Game.ini", None)])
        duplicate_rights = self.root / "duplicate-rights.json"
        self.write_rights_record(duplicate, duplicate_rights)
        with self.assertRaisesRegex(ValueError, "duplicate base archive path"):
            self.build_candidate(None, self.root / "duplicate-candidate",
                                 requested_sha=self.requested_sha, base_archive=duplicate,
                                 rights_record=duplicate_rights)
        self.assertFalse((self.root / "duplicate-candidate").exists())

    def test_archive_bootstrap_rejects_corrupt_zip_without_candidate(self):
        corrupt = self.root / "corrupt.zip"
        self.write_base_zip(corrupt)
        raw = bytearray(corrupt.read_bytes())
        marker = raw.index(b"synthetic-scripts")
        raw[marker] ^= 0x01
        corrupt.write_bytes(raw)
        corrupt_rights = self.root / "corrupt-rights.json"
        self.write_rights_record(corrupt, corrupt_rights)
        dest = self.root / "corrupt-candidate"

        with self.assertRaisesRegex(ValueError, "CRC|extract"):
            self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                 base_archive=corrupt, rights_record=corrupt_rights)

        self.assertFalse(dest.exists())

    def test_archive_bootstrap_rejects_incomplete_project_without_candidate(self):
        incomplete = self.root / "incomplete.zip"
        self.write_base_zip(incomplete, omit=("Data/Tilesets.rxdata",))
        incomplete_rights = self.root / "incomplete-rights.json"
        self.write_rights_record(incomplete, incomplete_rights)
        dest = self.root / "incomplete-candidate"

        with self.assertRaisesRegex(ValueError, "exactly one complete Essentials project"):
            self.build_candidate(None, dest, requested_sha=self.requested_sha,
                                 base_archive=incomplete, rights_record=incomplete_rights)

        self.assertFalse(dest.exists())

    def test_rejects_existing_candidate_without_overwriting(self):
        dest = self.root / "candidate"
        dest.mkdir()
        (dest / "keep.txt").write_text("unchanged")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.build_candidate(self.base, dest, requested_sha=self.requested_sha)
        self.assertEqual("unchanged", (dest / "keep.txt").read_text())

    def test_rejects_missing_native_plugin_archive(self):
        (self.base / "Data/PluginScripts.rxdata").unlink()
        with self.assertRaisesRegex(ValueError, "PluginScripts.rxdata"):
            self.build_candidate(self.base, self.root / "candidate",
                                 requested_sha=self.requested_sha)
        self.assertFalse((self.root / "candidate").exists())

    def test_failed_plugin_collision_leaves_no_partial_candidate(self):
        collision = self.base / "Plugins/Shattered Raid"
        collision.mkdir()
        (collision / "meta.txt").write_text("existing")
        with self.assertRaisesRegex(ValueError, "destination collision"):
            self.build_candidate(self.base, self.root / "candidate",
                                 requested_sha=self.requested_sha)
        self.assertFalse((self.root / "candidate").exists())
        self.assertEqual("existing", (collision / "meta.txt").read_text())

    def test_requested_commit_cannot_disagree_with_checkout(self):
        try:
            _sha, verified = source_pin()
        except ValueError as error:
            if "uncommitted tracked changes" in str(error):
                self.skipTest("source checkout has uncommitted changes")
            if "source-only bundle requires explicit" in str(error):
                self.skipTest("source-only archive has no Git metadata")
            raise
        if not verified:
            self.skipTest("source-only archive")
        with self.assertRaisesRegex(ValueError, "does not match checkout"):
            source_pin("0" * 40)


if __name__ == "__main__":
    unittest.main()

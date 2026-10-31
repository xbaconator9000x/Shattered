import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from scripts.stage_human_battle_sprite import (
    PNG, SpriteError, build_frame, chunk, stage
)


def synthetic_trainer_back():
    # Two visibly different 160x160 frames; remaining frames transparent.
    row = (bytes((255, 0, 0, 255)) * 160 +
           bytes((0, 255, 0, 255)) * 160 +
           bytes((0, 0, 0, 0)) * 480)
    payload = b"".join(b"\x00" + row for _ in range(160))
    return (PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", 800, 160, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(payload)) + chunk(b"IEND", b""))


class HumanBattleSpriteTest(unittest.TestCase):
    def private_project(self, root):
        project = Path(root) / "stage"
        (project / "Graphics/Trainers").mkdir(parents=True)
        (project / "Graphics/Pokemon/Back").mkdir(parents=True)
        (project / "SHATTERED_STAGING_REPORT.json").write_text("{}")
        source = project / "Graphics/Trainers/POKEMONTRAINER_Red_back.png"
        source.write_bytes(synthetic_trainer_back())
        return project, source

    def test_first_and_second_frames_are_cropped_correctly(self):
        raw = synthetic_trainer_back()
        first = build_frame(raw, 0)
        second = build_frame(raw, 1)
        self.assertNotEqual(first, second)
        for image, pixel in ((first, bytes((255, 0, 0, 255))),
                             (second, bytes((0, 255, 0, 255)))):
            self.assertTrue(image.startswith(PNG))
            self.assertEqual((160, 160), struct.unpack_from(">II", image, 16))
            start = image.index(b"IDAT") + 4
            length = struct.unpack_from(">I", image, start - 8)[0]
            decoded = zlib.decompress(image[start:start + length])
            self.assertEqual(pixel, decoded[1:5])

    def test_private_stage_writes_only_human_back_sprite(self):
        with tempfile.TemporaryDirectory() as root:
            project, source = self.private_project(root)
            before = source.read_bytes()
            result = stage(project, expected_source_sha256=hashlib.sha256(before).hexdigest())
            target = project / "Graphics/Pokemon/Back/HUMAN.png"
            self.assertTrue(target.is_file())
            self.assertEqual(result["output_sha256"], hashlib.sha256(target.read_bytes()).hexdigest())
            self.assertEqual(before, source.read_bytes())
            self.assertTrue(result["temporary_fallback_not_final_survivalist_art"])
            self.assertFalse(result["asset_redistribution_authorised"])
            self.assertFalse(result["native_battle_verified"])

    def test_rejects_wrong_source_pin_without_writing(self):
        with tempfile.TemporaryDirectory() as root:
            project, _ = self.private_project(root)
            with self.assertRaisesRegex(SpriteError, "SHA differs"):
                stage(project, expected_source_sha256="0" * 64)
            self.assertFalse((project / "Graphics/Pokemon/Back/HUMAN.png").exists())

    def test_rejects_unreviewed_source_path(self):
        with tempfile.TemporaryDirectory() as root:
            project, _ = self.private_project(root)
            with self.assertRaisesRegex(SpriteError, "reviewed private"):
                stage(project, source="../original/graphics.png")

    def test_requires_staging_report(self):
        with tempfile.TemporaryDirectory() as root:
            project, _ = self.private_project(root)
            (project / "SHATTERED_STAGING_REPORT.json").unlink()
            with self.assertRaisesRegex(SpriteError, "private staged"):
                stage(project)

    def test_refuses_overwrite_without_explicit_force(self):
        with tempfile.TemporaryDirectory() as root:
            project, _ = self.private_project(root)
            stage(project)
            with self.assertRaisesRegex(SpriteError, "overwrite"):
                stage(project)
            self.assertTrue(stage(project, force=True)["output_sha256"])

    def test_rejects_corrupt_png_crc_and_frame_out_of_range(self):
        raw = bytearray(synthetic_trainer_back())
        raw[50] ^= 1
        with self.assertRaisesRegex(SpriteError, "CRC"):
            build_frame(bytes(raw), 0)
        with self.assertRaisesRegex(SpriteError, "frame index"):
            build_frame(synthetic_trainer_back(), 5)

    def test_rejects_symlinked_source(self):
        with tempfile.TemporaryDirectory() as root:
            project, source = self.private_project(root)
            original = project / "original.png"
            original.write_bytes(source.read_bytes())
            source.unlink()
            source.symlink_to(original)
            with self.assertRaisesRegex(SpriteError, "unsafe"):
                stage(project)


if __name__ == "__main__":
    unittest.main()

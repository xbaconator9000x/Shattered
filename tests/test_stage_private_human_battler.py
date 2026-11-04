"""Tests for the source-only, private HUMAN battle art stage."""
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from stage_private_human_battler import TARGETS, build_assets, sha256, stage


def make_png(size):
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    image.paste((55, 80, 110, 255), (20, 25, min(size[0], 80), min(size[1], 100)))
    data = io.BytesIO()
    image.save(data, format="PNG")
    return data.getvalue()


class HumanBattlerTests(unittest.TestCase):
    def setUp(self):
        self.back = make_png((800, 160))
        self.front = make_png((128, 128))

    def test_all_three_native_formats(self):
        images = build_assets(self.back, self.front)
        self.assertEqual(set(images), {"back", "front", "icon"})
        for name, expected in {"back": (160, 160), "front": (160, 160), "icon": (128, 64)}.items():
            with Image.open(io.BytesIO(images[name])) as image:
                self.assertEqual(image.size, expected)
                self.assertIsNotNone(image.convert("RGBA").getbbox())

    def test_bad_source_shapes_fail(self):
        with self.assertRaisesRegex(ValueError, "five-frame"):
            build_assets(make_png((160, 160)), self.front)
        with self.assertRaisesRegex(ValueError, "128x128"):
            build_assets(self.back, make_png((160, 160)))

    def make_project(self, root):
        (root / "Graphics/Trainers").mkdir(parents=True)
        (root / "Graphics/Trainers/POKEMONTRAINER_Red_back.png").write_bytes(self.back)
        (root / "Graphics/Trainers/POKEMONTRAINER_Red.png").write_bytes(self.front)
        (root / "SHATTERED_STAGING_REPORT.json").write_text(json.dumps({"engine": "Essentials 21.1"}))

    def test_stage_is_idempotent_and_pins_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_project(root)
            pins = (sha256(self.back), sha256(self.front))
            first = stage(root, pins=pins)
            second = stage(root, pins=pins)
            self.assertEqual(first, second)
            self.assertFalse(first["native_gameplay_verified"])
            for target, digest in first["outputs"].items():
                self.assertEqual(sha256((root / target).read_bytes()), digest)
            with self.assertRaisesRegex(ValueError, "hash differs"):
                stage(root)

    def test_never_overwrite_user_custom_human_art(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_project(root)
            path = root / TARGETS["front"]
            path.parent.mkdir(parents=True)
            path.write_bytes(b"custom-art")
            with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                stage(root, pins=(sha256(self.back), sha256(self.front)))
            self.assertFalse((root / TARGETS["back"]).exists())
            self.assertEqual(path.read_bytes(), b"custom-art")

    def test_reject_symlinked_source_and_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_project(root)
            source = root / "Graphics/Trainers/POKEMONTRAINER_Red.png"
            source.unlink()
            source.symlink_to(root / "Graphics/Trainers/POKEMONTRAINER_Red_back.png")
            with self.assertRaisesRegex(ValueError, "symlinked"):
                stage(root, pins=(sha256(self.back), sha256(self.front)))


if __name__ == "__main__":
    unittest.main()

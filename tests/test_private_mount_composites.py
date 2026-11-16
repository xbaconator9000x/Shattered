import importlib.util
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "mount_composites", ROOT / "scripts" / "install_private_mount_composites.py"
)
mount_composites = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mount_composites)


class PrivateMountCompositeTest(unittest.TestCase):
    def fixture(self, root):
        chars = root / "Graphics/Characters"
        front = root / "Graphics/Pokemon/Front"
        chars.mkdir(parents=True); front.mkdir(parents=True)
        Image.new("RGBA", (160, 160), (0, 0, 0, 0)).save(front / "ONIX.png")
        onix = Image.open(front / "ONIX.png").convert("RGBA")
        ImageDraw.Draw(onix).rectangle((20, 20, 130, 130), fill=(80, 100, 130, 255))
        onix.save(front / "ONIX.png")
        for name in mount_composites.PLAYER_SHEETS:
            Image.new("RGBA", mount_composites.SHEET, (200, 30, 30, 255)).save(chars / f"{name}.png")

    def test_builds_private_onix_sheets_and_records_unavailable_mounts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.fixture(root)
            report = mount_composites.build(root)
            self.assertEqual(["CRYSTALONIX", "CRYSTALIX", "BULLGRUM"], report["unavailable_species"])
            self.assertEqual(2, len(report["installed"]))
            for entry in report["installed"]:
                with Image.open(root / "Graphics/Characters" / entry["character"]) as image:
                    self.assertEqual(mount_composites.SHEET, image.size)
            self.assertTrue((root / "SHATTERED_MOUNT_COMPOSITES_REPORT.json").is_file())

    def test_refuses_wrong_geometry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.fixture(root)
            Image.new("RGBA", (64, 64)).save(root / "Graphics/Pokemon/Front/ONIX.png")
            with self.assertRaisesRegex(ValueError, "geometry"):
                mount_composites.build(root)


if __name__ == "__main__":
    unittest.main()

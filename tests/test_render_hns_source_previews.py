"""Asset-free regression for direct Heart & Soul map and RMXP atlas previews."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

try:
    from PIL import Image
    from render_hns_source_previews import MAPS, PIN_MANIFEST, generate
except ImportError:
    Image = None
    generate = None


@unittest.skipIf(Image is None, "Pillow required for actual source preview rendering")
class SourcePreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "actual-previews"
        pins = json.loads(PIN_MANIFEST.read_text())
        layouts = []
        for layout_id, map_id, _ in MAPS:
            info = pins["layouts"][layout_id]
            layout = {"id": layout_id, "width": 2, "height": 1,
                      "blockdata_filepath": info["blockdata_path"],
                      "primary_tileset": "gTestPrimary" if layout_id == MAPS[0][0] else "gRoadPrimary",
                      "secondary_tileset": "gTestSecondary" if layout_id == MAPS[0][0] else "gRoadSecondary"}
            layouts.append(layout)
            map_path = self.source / info["map_json_path"]
            map_path.parent.mkdir(parents=True, exist_ok=True)
            map_path.write_text(json.dumps({
                "id": map_id, "layout": layout_id,
                "warp_events": [{"x": 1, "y": 0, "dest_map": "MAP_TEST"}]
                if layout_id == MAPS[0][0] else []}))
            block = self.source / info["blockdata_path"]
            block.parent.mkdir(parents=True, exist_ok=True)
            blocked = layout_id == MAPS[1][0]
            block.write_bytes(struct.pack("<2H", 1 << 10 if blocked else 0, 0))
        layout_path = self.source / "data/layouts/layouts.json"
        layout_path.parent.mkdir(parents=True, exist_ok=True)
        layout_path.write_text(json.dumps({"layouts": layouts}))
        for info in pins["layouts"].values():
            for key in ("primary_dir", "secondary_dir"):
                directory = self.source / info[key]
                if (directory / "tiles.png").exists():
                    continue
                (directory / "palettes").mkdir(parents=True, exist_ok=True)
                image = Image.new("P", (16, 8), 0)
                image.putpixel((0, 0), 1)
                image.save(directory / "tiles.png")
                (directory / "metatiles.bin").write_bytes(struct.pack("<8H", *([0] * 8)))
                (directory / "metatile_attributes.bin").write_bytes(b"\x00\x00")
                for palette_id in range(16):
                    colors = ["0 0 0"] * 16
                    colors[1] = "255 0 0"
                    (directory / "palettes" / f"{palette_id:02d}.pal").write_text(
                        "JASC-PAL\n0100\n16\n" + "\n".join(colors) + "\n")

    def test_generates_four_real_geometry_previews_and_two_xp_atlases(self):
        result = generate(self.source, self.output, verify_source=False)
        self.assertEqual(set(result["maps"]), {"gate", "victory_1f", "victory_b1f", "victory_b2f"})
        self.assertEqual(set(result["rmxp_tilesets"]), {"gate", "victory"})
        self.assertFalse(result["raw_source_pins_checked"])
        self.assertFalse(result["passage_reviewed"])
        self.assertEqual(12, len(result["sha256"]))
        self.assertEqual(1, result["maps"]["gate"]["source_warps"])
        self.assertEqual(1, result["maps"]["victory_1f"]["source_collision_nonzero_cells"])
        with Image.open(self.output / "gate_source.png") as image:
            self.assertEqual((64, 32), image.size)
            self.assertEqual((255, 0, 0, 255), image.getpixel((0, 0)))
        with Image.open(self.output / "victory_1f_collision_warps.png") as image:
            self.assertNotEqual((255, 0, 0, 255), image.getpixel((0, 0)))
        with Image.open(self.output / "HnS_Gate_Review.png") as image:
            self.assertEqual(256, image.width)
        mapping = json.loads((self.output / "HnS_Victory_Review.json").read_text())
        self.assertTrue(mapping["private_hns_art_manifest"]["preview_only"])
        self.assertFalse(mapping["private_hns_art_manifest"]["passage_reviewed"])
        self.assertEqual(15, mapping["entries"]["0:1:0"]["tables"][0]["passage"])
        self.assertEqual(result, json.loads((self.output / "review_manifest.json").read_text()))

    def test_refuses_overwriting_existing_review(self):
        generate(self.source, self.output, verify_source=False)
        with self.assertRaisesRegex(ValueError, "refusing to replace"):
            generate(self.source, self.output, verify_source=False)

    def test_rolls_back_all_generated_outputs_on_corrupt_source(self):
        pins = json.loads(PIN_MANIFEST.read_text())
        path = self.source / pins["layouts"][MAPS[3][0]]["blockdata_path"]
        path.write_bytes(b"\x00")
        with self.assertRaisesRegex(ValueError, "source blockdata length mismatch|incorrect blockdata"):
            generate(self.source, self.output, verify_source=False)
        self.assertFalse(self.output.exists())
        self.assertFalse(any(self.root.glob(".shattered-hns-*")))

    def test_production_rejects_synthetic_source_hashes(self):
        with self.assertRaisesRegex(ValueError, "blob mismatch|unrecognized|unpinned"):
            generate(self.source, self.output, verify_source=True)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

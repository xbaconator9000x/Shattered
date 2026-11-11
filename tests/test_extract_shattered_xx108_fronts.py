import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "extract_shattered_xx108_fronts.py"
spec = importlib.util.spec_from_file_location("extract_xx108", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ShatteredXX108FrontExtractorTests(unittest.TestCase):
    def test_lz77_literals_and_back_reference_are_decoded(self):
        # "ABCABC": three literals, then a length-three back-reference.
        stream = bytes([0x10, 6, 0, 0, 0x10, ord("A"), ord("B"), ord("C"), 0x00, 0x02])
        self.assertEqual(mod.lz77(stream, 0), b"ABCABC")

    def test_front_decoder_preserves_palette_zero_as_transparent(self):
        palette = bytearray(32)
        palette[2:4] = (31).to_bytes(2, "little")
        tiles = bytes([0x10]) + bytes(mod.FRONT_BYTES - 1)
        image = mod.decode_front(tiles, bytes(palette))
        self.assertEqual(image.size, (64, 64))
        self.assertEqual(image.getpixel((0, 0))[3], 0)
        self.assertEqual(image.getpixel((1, 0)), (255, 0, 0, 255))

    def test_canonical_starter_and_encounter_slots_are_declared(self):
        self.assertEqual(mod.SPECIES_IDS["RATTATA"], 19)
        self.assertEqual(mod.SPECIES_IDS["VULPIX"], 37)
        self.assertEqual(mod.SPECIES_IDS["NOCTALES"], 38)
        self.assertEqual(mod.SPECIES_IDS["EXEGGCUTE"], 102)
        self.assertEqual(mod.SPECIES_IDS["EXEGGUTIVE"], 103)
        self.assertEqual(mod.SPECIES_IDS["STARYU"], 120)
        self.assertEqual(mod.SPECIES_IDS["STARUS"], 121)


if __name__ == "__main__":
    unittest.main()

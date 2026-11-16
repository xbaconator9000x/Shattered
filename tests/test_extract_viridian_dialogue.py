import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'scripts/extract_shattered_viridian_dialogue.py'
spec = importlib.util.spec_from_file_location('quest_dialogue', path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class DialogueTest(unittest.TestCase):
    def test_colour_controls_player_substitution_and_page_breaks(self):
        data = bytes([0xFC, 4, 4, 1, 5, 0xC2, 0xD5, 0xE2, 0xD5, 0xF0,
                      0, 0xFD, 1, 0xB4, 0xE7, 0xAD, 0xFB, 0xBB, 0xFF])
        self.assertEqual(mod.decode(data, 0), "Hana: {PLAYER}'s.\n\nA")

    def test_unknown_control_and_unterminated_text_fail(self):
        for data in (bytes([0xFC, 8, 0xFF]), bytes([0xFD, 2, 0xFF]), bytes([0xBB])):
            with self.assertRaises(ValueError):
                mod.decode(data, 0)


if __name__ == '__main__':
    unittest.main()

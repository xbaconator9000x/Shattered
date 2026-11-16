import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import extract_shattered_training as training


class TrainingExtractionTest(unittest.TestCase):
    def test_unknown_rom_rejected_before_pointer_reads(self):
        with self.assertRaisesRegex(ValueError, 'unknown ROM'):
            training.curriculum(b'not a ROM')

    def test_invalid_table_pointer_rejected(self):
        with patch.object(training.hashlib, 'sha256') as digest:
            digest.return_value.hexdigest.return_value = training.ROM_SHA
            with self.assertRaisesRegex(ValueError, 'invalid source pointer'):
                training.curriculum(bytes(0x1FFF00C))


if __name__ == '__main__':
    unittest.main()

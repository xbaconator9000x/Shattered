import hashlib
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import extract_shattered_night_raid as raid


class SelectorTest(unittest.TestCase):
    def code(self, instructions):
        data = bytearray(raid.STOP + 16)
        for index, op in enumerate(instructions):
            struct.pack_into('<H', data, raid.START + index*2, op)
        return data

    def test_unknown_rom_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unknown ROM'):
            raid.recover(b'unknown')

    def test_unsupported_opcode_is_not_silently_skipped(self):
        with self.assertRaisesRegex(ValueError, 'unsupported selector instruction'):
            raid.select_encounter(self.code([0xFFFF]), 3)

    def test_branch_outside_reviewed_region_rejected(self):
        with self.assertRaisesRegex(ValueError, 'escaped reviewed code'):
            raid.select_encounter(self.code([0xE7FC]), 3)

    def test_infinite_loop_is_bounded(self):
        with self.assertRaisesRegex(ValueError, 'instruction budget'):
            raid.select_encounter(self.code([0xE7FE]), 3)

    def test_selection_returns_actual_registers(self):
        # MOV r7,15; MOV r4,8; LDR r6,[PC,4]; B STOP; pool
        branch_from = raid.START + 6
        delta = (raid.STOP - branch_from - 4) // 2
        data = self.code([0x270F, 0x2408, 0x4E01, 0xE000 | delta])
        struct.pack_into('<I', data, ((raid.START+8)&~3)+4, raid.BASE+0x100)
        self.assertEqual((15, 8, 0x100), raid.select_encounter(data, 9))


if __name__ == '__main__':
    unittest.main()

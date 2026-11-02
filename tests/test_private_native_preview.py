"""Source-only tests for the private native RMXP map pixel renderer."""
import importlib.util
from pathlib import Path
import struct
import unittest
from PIL import Image

spec = importlib.util.spec_from_file_location(
    'native_preview',
    Path(__file__).resolve().parents[1] / 'scripts' / 'render_private_rmxp_maps.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def table(ids, w=1, h=1):
    return struct.pack('<5I', 3, w, h, 3, w*h*3) + struct.pack('<%dH' % len(ids), *ids)


class NativeMapPreviewTest(unittest.TestCase):
    def setUp(self):
        self.atlas = Image.new('RGBA', (256, 64), (0, 0, 0, 0))
        self.atlas.paste((255, 0, 0, 255), (0, 0, 32, 32))
        self.atlas.paste((0, 0, 255, 128), (32, 0, 64, 32))
        self.meta = {'width': 1, 'height': 1}

    def test_native_layers_composite_in_correct_order(self):
        result, count = mod.render_map(self.meta, table([384, 385, 0]), self.atlas)
        self.assertEqual(2, count)
        self.assertEqual((127, 0, 128, 255), result.getpixel((8, 8)))

    def test_native_preview_keeps_unpainted_map_area_transparent(self):
        result, count = mod.render_map(self.meta, table([0, 0, 0]), self.atlas)
        self.assertEqual(0, count)
        self.assertEqual((0, 0, 0, 0), result.getpixel((8, 8)))

    def test_native_preview_preserves_tileset_pixel_transparency(self):
        self.atlas.putpixel((4, 5), (0, 0, 0, 0))
        result, _ = mod.render_map(self.meta, table([384, 0, 0]), self.atlas)
        self.assertEqual((0, 0, 0, 0), result.getpixel((4, 5)))

    def test_event_overlay_does_not_mutate_clean_preview(self):
        original, _ = mod.render_map(self.meta, table([384, 0, 0]), self.atlas)
        marked = mod.overlay_events(original, [{'id': 5, 'x': 0, 'y': 0}])
        self.assertEqual((255, 0, 0, 255), original.getpixel((0, 0)))
        self.assertNotEqual(original.getpixel((0, 0)), marked.getpixel((0, 0)))

    def test_real_rmxp_event_sprite_direction_and_frame(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Graphics' / 'Characters').mkdir(parents=True)
            sheet = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
            sheet.paste((0, 255, 0, 255), (64, 96, 96, 128))
            sheet.save(root / 'Graphics' / 'Characters' / 'Aipom.png')
            canvas = Image.new('RGBA', (64, 64), (0, 0, 0, 255))
            events = [{'x': 1, 'y': 1, 'character_name': 'Aipom',
                       'direction': 8, 'pattern': 2}]
            preview, count = mod.render_event_sprites(canvas, events, root)
            self.assertEqual(1, count)
            self.assertEqual((0, 255, 0, 255), preview.getpixel((48, 48)))
            self.assertEqual((0, 0, 0, 255), canvas.getpixel((48, 48)))

    def test_missing_native_event_sprite_fails_closed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'missing private event sprite'):
                mod.render_event_sprites(Image.new('RGBA', (32, 32)),
                    [{'x': 0, 'y': 0, 'character_name': 'Aipom',
                      'direction': 8, 'pattern': 0}], Path(directory))

    def test_rejects_unsupported_autotile(self):
        with self.assertRaisesRegex(ValueError, 'unsupported autotile'):
            mod.render_map(self.meta, table([1, 0, 0]), self.atlas)

    def test_rejects_out_of_bounds_tileset_index(self):
        with self.assertRaisesRegex(ValueError, 'out-of-range'):
            mod.render_map(self.meta, table([384 + 50, 0, 0]), self.atlas)

    def test_rejects_malformed_native_table(self):
        invalid = [
            b'', table([384, 0, 0])[:-2],
            table([384, 0, 0]).replace(b'\x03\x00\x00\x00', b'\x02\x00\x00\x00', 1),
        ]
        for bad in invalid:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                mod.render_map(self.meta, bad, self.atlas)

    def test_rejects_non_rmxp_sheet_width(self):
        with self.assertRaisesRegex(ValueError, '256px'):
            mod.render_map(self.meta, table([384, 0, 0]), Image.new('RGBA', (64, 32)))


if __name__ == '__main__':
    unittest.main()

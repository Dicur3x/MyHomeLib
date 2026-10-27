"""Native-reference outline and malformed-input regression checks."""
from pathlib import Path
import hashlib
import importlib.util
import io
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rgo_outline', ROOT / 'rgo_outline.py')
rgo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rgo)


def encoded(nibbles):
    nibbles = nibbles.replace(' ', '')
    return bytes.fromhex(nibbles + ('0' if len(nibbles) & 1 else ''))


class RepliGoOutlines(unittest.TestCase):
    def test_native_v_has_exact_contour_and_205_ink_pixels(self):
        data = bytes.fromhex('f03f6d84544454ec5454546e8fc7e7045455454544ec44454445444401')
        decoder = rgo.Decoder(data)
        glyph = decoder.glyph(0)
        width, height, left, top, rows = rgo.raster(glyph)
        self.assertEqual((width, height, left, top), (30, 30, 0, 0))
        self.assertEqual(sum(b - a for row in rows for a, b in row), 205)
        self.assertEqual(sum(abs(b[0] - a[0]) + abs(b[1] - a[1])
                             for a, b in zip(glyph[0], glyph[0][1:])), 176)
        self.assertEqual(len(glyph[0]) - 1, 96)
        self.assertEqual(decoder.pos, len(data) * 2)

    def test_small_and_wide_literals_and_byte_alignment(self):
        for code in ('ff722 ff7ee', 'fff00020002 ffffffefffe'):
            decoder = rgo.Decoder(encoded(code))
            self.assertEqual(rgo.raster(decoder.glyph(0))[:4], (2, 2, 0, 0))
            self.assertEqual(decoder.pos, len(encoded(code)) * 2)

    def test_d_repeats_exactly_twice_and_resumes_the_stream(self):
        decoder = rgo.Decoder(encoded('ffffffefffe d ffffffcfffc'))
        glyph = decoder.glyph(0)
        self.assertEqual(rgo.raster(glyph)[:4], (4, 4, -4, -4))
        self.assertLess(decoder.steps, 10)

    def test_relative_origins_and_hole_fill(self):
        # Outer 4x4 square; move right/down, inner 2x2 contour.
        decoder = rgo.Decoder(encoded('fff00040004 ffffffcfffc 11 fff00020002 ffffffefffe'))
        glyph = decoder.glyph(1)
        self.assertEqual(glyph[1][0], (1, 1))
        # A separate explicit polygon fixture verifies that holes stay paper.
        square = [[(0, 0), (4, 0), (4, 4), (0, 4), (0, 0)],
                  [(1, 1), (3, 1), (3, 3), (1, 3), (1, 1)]]
        self.assertEqual(sum(b - a for row in rgo.raster(square)[4] for a, b in row), 12)

    def test_cached_contour_returns_to_the_next_glyph(self):
        first = encoded('feb fff00020002 ffffffefffe')
        second = encoded('fec0000')
        decoder = rgo.Decoder(first + second)
        self.assertEqual(rgo.raster(decoder.glyph(0))[:4], (2, 2, 0, 0))
        self.assertEqual(rgo.raster(decoder.glyph(0))[:4], (2, 2, -2, 0))
        self.assertEqual(decoder.pos, len(first + second) * 2)
        self.assertIsNone(decoder.saved)

    def test_truncation_reserved_codes_references_and_limits(self):
        for code in ('f', 'ff7', 'fed', 'fecffff', 'febfec0000'):
            with self.subTest(code=code), self.assertRaises(rgo.OutlineError):
                rgo.Decoder(encoded(code), max_steps=50).glyph(0)
        with self.assertRaises(rgo.OutlineError):
            rgo.Decoder(encoded('0000'), max_steps=2).glyph(0)
        with self.assertRaises(rgo.OutlineError):
            rgo.Decoder(b'').glyph(300)
        with self.assertRaises(rgo.OutlineError):
            rgo.raster([[(0, 0), (10000, 0), (10000, 10000), (0, 0)]])

    def test_line_png_is_one_bit_and_retains_the_baseline(self):
        square = rgo.raster([[(0, 0), (2, 0), (2, 2), (0, 2), (0, 0)]])
        data = rgo.line_png([[(0, 0)], [(1, 0)]], [square], [0, 0], [0, 1], 1, 3)
        self.assertEqual(struct.unpack('>IIBBBBB', data[16:29]), (7, 3, 1, 0, 0, 0, 0))
        at, raw = 8, b''
        while at < len(data):
            size = struct.unpack_from('>I', data, at)[0]
            kind, body = data[at + 4:at + 8], data[at + 8:at + 8 + size]
            self.assertEqual(zlib.crc32(kind + body) & 0xffffffff, struct.unpack_from('>I', data, at + 8 + size)[0])
            if kind == b'IDAT':
                raw += body
            at += size + 12
        self.assertEqual(zlib.decompress(raw), b'\0?\0\x39\0\xf9')


if __name__ == '__main__':
    unittest.main()

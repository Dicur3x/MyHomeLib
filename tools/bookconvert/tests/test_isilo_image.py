"""Independent framed image writer, known DCT samples and malformed inputs."""
import hashlib
import math
from pathlib import Path
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

from test_isilo_input import c, fixture, isilo, load, pack_records, png_pixels
image = load('isilo_image')


def little(value, count):
    return [(value >> shift) & 1 for shift in range(count)]


def symbol(value):
    return [(value >> shift) & 1 for shift in reversed(range(9))]


def packed(bits):
    return bytes(sum(value << shift for shift, value in enumerate(bits[at:at + 8]))
                 for at in range(0, len(bits), 8))


def gray_record(width=40, height=33, dc_values=(-128, 127, 0, 32), noisy=False):
    # A deliberately simple canonical alphabet: all269 symbols have length9.
    # Its code-length alphabet contains0 and9 with one-bit codes0 and1.
    order = (16, 17, 18, 0, 8, 7, 9, 6, 10)
    table = little(len(order) - 4, 5)
    for value in order:
        table += little(1 if value in (0, 9) else 0, 3)
    table += [1] * 269
    table = packed(table)
    payload = bytearray()
    tile = 0
    for y in range(0, height, 32):
        for x in range(0, width, 32):
            bits = []
            for _ in range(math.ceil(min(32, width - x) / 8) * math.ceil(min(32, height - y) / 8)):
                if noisy:
                    bits += (symbol(127) + symbol(129)) * 32
                else:
                    bits += symbol(dc_values[tile % len(dc_values)] + 128) + symbol(268)
            data = packed(bits)
            payload += bytes([len(data)]) if len(data) < 240 else bytes([240 + len(data) // 256, len(data) % 256])
            payload += data
            tile += 1
    header = b'\x04\x04\0\0\x0c\x03' + struct.pack('>BBHHH', 75, 0, width, height, 13 + len(table))
    return header + len(table).to_bytes(3, 'big') + table + payload


class ISiloImage(unittest.TestCase):
    def test_independent_flat_tiles_cover_partial_bottom_and_right_edges(self):
        record = gray_record()
        width, height, pixels, alpha = isilo.bitmap_raster(record)
        self.assertEqual((width, height, alpha), (40, 33, False))
        expected = b''.join(bytes([shade] * 3) for y in range(height) for x in range(width)
                            for shade in [0 if x < 32 and y < 32 else
                                          255 if y < 32 else 128 if x < 32 else 160])
        self.assertEqual(pixels, expected)
        dimensions, raster = png_pixels(isilo.bitmap(record))
        self.assertEqual(dimensions[:4], (40, 33, 8, 2))
        self.assertEqual(raster, b''.join(b'\0' + expected[y * 120:(y + 1) * 120] for y in range(33)))

    def test_extended_tile_length_and_fully_populated_blocks(self):
        record = gray_record(32, 32, noisy=True)
        at = 4 + int.from_bytes(record[12:14], 'big')
        self.assertEqual(record[at:at + 2], b'\xf4\x80')  # 1152 payload bytes
        width, height, pixels, alpha = isilo.bitmap_raster(record)
        self.assertEqual((width, height, len(pixels), alpha), (32, 32, 3072, False))
        self.assertGreater(len(set(pixels)), 4)

    def test_every_zero_run_group_and_implicit_full_block(self):
        tree = isilo.Huffman([9] * 269)
        for value in range(260, 268):
            for extra in (0, 3 if value == 260 else 7):
                with self.subTest(value=value, extra=extra):
                    count = 3 + extra if value == 260 else 7 + 8 * (value - 261) + extra
                    bits = symbol(129) + symbol(value) + little(extra, 2 if value == 260 else 3) + symbol(127)
                    if count + 2 < 64:
                        bits += symbol(268)
                    blocks = list(image.coefficient_blocks(tree, packed(bits), 8, 8))
                    self.assertEqual(blocks, [[1] + [0] * count + [-1] + [0] * (62 - count)])

    def test_inverse_transform_has_known_dc_and_single_frequency_samples(self):
        quant = [1] * 64
        self.assertEqual(image.inverse_block([0] * 64, quant), bytes([128] * 64))
        self.assertEqual(image.inverse_block([80] + [0] * 63, quant), bytes([138] * 64))
        # A horizontal cosine with amplitude16/(4*sqrt(2)), repeated on every
        # row. Explicit samples also catch zigzag transposition and rounding.
        values = [131, 130, 130, 129, 127, 126, 126, 125]
        self.assertEqual(image.inverse_block([0, 16] + [0] * 62, quant), bytes(values * 8))

    def test_bad_prefixes_tables_geometry_and_padding_fail_cleanly(self):
        source = gray_record()
        table_end = 4 + int.from_bytes(source[12:14], 'big')
        cases = [source[:-1], source + b'\0', source[:table_end] + b'\xf0',
                 source[:table_end] + b'\0' + source[table_end + 1:],
                 source[:6] + b'\0' + source[7:], source[:6] + b'\x65' + source[7:],
                 source[:8] + struct.pack('>HH', 5000, 5000) + source[12:],
                 source[:14] + b'\xff\xff\xff' + source[17:],
                 source[:17] + bytes([source[17] | 31]) + source[18:]]
        for index, data in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(isilo.ISiloError):
                isilo.bitmap_raster(data)
        tree = isilo.Huffman([9] * 269)
        for data in (packed(symbol(128) * 63 + symbol(260) + little(0, 2)),
                     packed(symbol(268)) + b'\0', packed(symbol(256))):
            with self.assertRaises(ValueError):
                list(image.coefficient_blocks(tree, data, 8, 8))

    def test_full_book_conversion_assembles_custom_and_palm_parts_without_text_loss(self):
        _, records = fixture()
        records[2] = gray_record(2, 1, dc_values=(8,))
        data = pack_records(records)
        for suffix in ('.fb2', '.epub'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory(prefix='HomeLibRu-isilo-gray-') as temporary:
                root = Path(temporary)
                source, target = root / 'mistagged.ibk', root / ('result' + suffix)
                source.write_bytes(data)
                before = hashlib.sha256(data).digest()
                c.convert_book(source, target, reading=True, tools_root=root / 'absent-tools')
                if suffix == '.epub':
                    with zipfile.ZipFile(target) as archive:
                        self.assertIsNone(archive.testzip())
                        document = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                        pictures = [archive.read(name) for name in archive.namelist() if name.endswith('.png')]
                else:
                    import base64
                    document = ET.parse(target).getroot()
                    pictures = [base64.b64decode(n.text) for n in document if c.tag(n) == 'binary']
                self.assertIn('Начало книги', ''.join(document.itertext()))
                self.assertIn('Последняя строка', ''.join(document.itertext()))
                self.assertEqual(len(pictures), 1)
                dimensions, pixels = png_pixels(pictures[0])
                self.assertEqual(dimensions[:2], (3, 1))
                self.assertEqual(pixels, b'\0' + bytes([136] * 6) + b'\0\0\xff')
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                self.assertEqual(set(root.iterdir()), {source, target})


if __name__ == '__main__':
    unittest.main()

"""Independent Palm/RepliGo fixtures: text, tables, order, pictures and failures."""
import hashlib
import importlib.util
import struct
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c, rgo = load('convert_book'), load('rgo_input')


def fixture(missing_unicode=False, wrong_word_length=False, bad_picture=False, compressed=False, outlined=False):
    phrases = ['Заголовок', 'Конец', 'Левая ячейка', 'Правая ячейка']
    words = [word for phrase in phrases for word in phrase.split()]
    letters = ''.join(words)
    dictionary = ''.join(dict.fromkeys(letters))
    indexes = bytes(dictionary.index(char) for char in letters)
    if missing_unicode:
        dictionary = '\x01' + dictionary[1:]
    header = [1000, 1000, 300, 300, 0, 3, 1, 0, 0, 4, 4, 6, len(letters), 0, 0, 0, 20, 14, 0, 0, 0, 0]
    lengths = [1] * 4 + [1, 1, 2, 2] + [len(word) for word in words]
    if wrong_word_length:
        lengths[-1] += 1
    def record(kind, codec, count, body):
        if compressed:
            return struct.pack('>4H', kind, codec | 128, count, len(body)) + zlib.compress(body)
        return struct.pack('>3H', kind, codec, count) + body
    def ints(kind, values):
        return record(kind, 12, len(values), struct.pack('>' + str(len(values)) + 'H', *values))
    records = [record(5, 11, len(dictionary), dictionary.encode('utf-8')),
               record(6, 11, 3, bytes([220, 30, 10])),
               ints(39, [2, 2, 300, 300, 8, 0, 5 if outlined else 3]),
               record(40, 0, 2, bytes([0, 255, 0, 1 if bad_picture else 255])),
               record(2, 0, 1, struct.pack('>22H', *header)),
               ints(7, [0, 0, 100, 20, 0, 900, 20, 20, 0, 30, 200, 200]),
               ints(8, [2, 3, 1]),
               ints(10, [1, 2, 1, 2, 3, 2, 2, 1]),
               ints(11, lengths),
               record(22, 2, len(indexes), indexes),
               ints(38, [0, 30, 0, 100, 1])]
    if outlined:
        square = bytes.fromhex('fff00020002ffffffefffe')
        records[:0] = [record(37, 13, len(square) * len(dictionary), square * len(dictionary)),
                       ints(35, [0] * len(dictionary))]
        records.extend([ints(12, [3] * 12 + [1] * 4 + [0] * 4),
                        ints(19, [0] * len(indexes)), ints(20, [0] * len(indexes))])
    palm = bytearray(78)
    palm[:5] = b'Book\0'
    palm[60:68] = b'.rgoCERI'
    struct.pack_into('>H', palm, 76, len(records))
    table, offset = bytearray(), 78 + len(records) * 8
    for index, entry in enumerate(records):
        table.extend(struct.pack('>II', offset, index))
        offset += len(entry)
    return bytes(palm + table) + b''.join(records)


class RepliGoInput(unittest.TestCase):
    def test_stream_boundaries_and_order(self):
        document = rgo.Document(fixture())
        blocks = document.blocks(document.pages[0])
        self.assertEqual(blocks, [('text', 'Левая ячейка'), ('text', 'Правая ячейка'),
                                  ('image', 0), ('text', 'Заголовок'), ('text', 'Конец')])
        picture = document.raster(0)
        self.assertEqual(picture[:8], b'\x89PNG\r\n\x1a\n')
        at, chunks = 8, {}
        while at < len(picture):
            size = struct.unpack_from('>I', picture, at)[0]
            kind, value = picture[at + 4:at + 8], picture[at + 8:at + 8 + size]
            self.assertEqual(zlib.crc32(kind + value) & 0xffffffff,
                             struct.unpack_from('>I', picture, at + size + 8)[0])
            chunks[kind] = value
            at += size + 12
        self.assertEqual(struct.unpack('>IIBBBBB', chunks[b'IHDR']), (2, 2, 8, 3, 0, 0, 0))
        self.assertEqual(chunks[b'PLTE'][:3], bytes([220, 30, 10]))
        self.assertEqual(chunks[b'PLTE'][255 * 3:], b'\xff\xff\xff')
        self.assertEqual(zlib.decompress(chunks[b'IDAT']), b'\0\0\xff\0\0\xff')

    def test_fb2_epub_and_false_extension(self):
        for extension in ('.fb2', '.epub'):
            for compressed in (False, True):
                with self.subTest(extension=extension, compressed=compressed), tempfile.TemporaryDirectory() as folder:
                    root = Path(folder)
                    source, target = root / 'wrong-name.pdf', root / ('reading' + extension)
                    source.write_bytes(fixture(compressed=compressed))
                    before = hashlib.sha256(source.read_bytes()).digest()
                    self.assertEqual(c.detect_input(source), '.rgo')
                    warnings = c.convert_book(source, target)
                    self.assertTrue(warnings)
                    if extension == '.fb2':
                        book = ET.parse(target).getroot()
                        self.assertEqual(len(list(book.iter('{' + c.FB + '}binary'))), 1)
                        text = ''.join(book.itertext())
                    else:
                        with zipfile.ZipFile(target) as archive:
                            self.assertIsNone(archive.testzip())
                            chapter = next(name for name in archive.namelist() if name.endswith('.xhtml') and 'nav' not in name)
                            text = ''.join(ET.fromstring(archive.read(chapter)).itertext())
                            self.assertEqual(sum(name.endswith('.png') for name in archive.namelist()), 1)
                    self.assertLess(text.index('Левая ячейка'), text.index('Правая ячейка'))
                    self.assertLess(text.index('Правая ячейка'), text.index('Заголовок'))
                    self.assertLess(text.index('Заголовок'), text.index('Конец'))
                    self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                    self.assertEqual(sorted(p.name for p in root.iterdir()), sorted([source.name, target.name]))

    def test_invalid_inputs_do_not_publish_partial_book(self):
        for options in ({'missing_unicode': True}, {'wrong_word_length': True}, {'bad_picture': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source, target = root / 'source.rgo', root / 'reading.epub'
                source.write_bytes(fixture(**options))
                with self.assertRaises(c.ConversionError):
                    c.convert_book(source, target)
                self.assertFalse(target.exists())
                self.assertEqual(list(root.iterdir()), [source])

    def test_truncated_records_and_deflate_are_rejected(self):
        source = fixture(compressed=True)
        for data in (source[:70], source[:-3], source[:170] + b'\0' * 8 + source[178:]):
            with self.subTest(size=len(data)), self.assertRaises(rgo.RGOError):
                rgo.Document(data)

    def test_outlined_text_reads_and_exports_without_silent_text_loss(self):
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source, target = root / 'wrong.pdf', root / ('book' + suffix)
                source.write_bytes(fixture(missing_unicode=True, outlined=True))
                warnings = c.convert_book(source, target)['warnings']
                self.assertTrue(any('таблицы Unicode' in w for w in warnings))
                if suffix == '.epub':
                    with zipfile.ZipFile(target) as archive:
                        self.assertIsNone(archive.testzip())
                        self.assertEqual(sum(n.endswith('.png') for n in archive.namelist()), 2)
                else:
                    document = ET.parse(target).getroot()
                    self.assertEqual(len(list(document.iter('{' + c.FB + '}binary'))), 2)
                    self.assertNotIn('\1', ''.join(document.itertext()))
                text_only = root / 'no-images.epub'
                with self.assertRaisesRegex(c.ConversionError, 'удалит сам текст'):
                    c.convert_book(source, text_only, image_quality='none')
                self.assertFalse(text_only.exists())
                self.assertFalse(list(root.glob('.homelib-*')))

    def test_compact_unsigned_values_and_repeat_bounds(self):
        self.assertEqual(rgo.integers((0, 6, 2, bytes.fromhex('7fc03fc0'))), [1, 255])
        self.assertEqual(rgo.integers((0, 8, 9, bytes.fromhex('18ff00ff10'))), [1] * 8 + [255])
        with self.assertRaises(rgo.RGOError):
            rgo.integers((0, 8, 2, b'\x13'))

    def test_signed_typography_two_and_four_bit_escapes(self):
        self.assertEqual(rgo.integers((0, 5, 1, bytes.fromhex('a00023'))), [35])
        self.assertEqual(rgo.integers((0, 5, 1, bytes.fromhex('a0ff00'))), [-256])
        self.assertEqual(rgo.integers((0, 3, 1, bytes.fromhex('887d00'))), [32000])
        self.assertEqual(rgo.integers((0, 3, 1, bytes.fromhex('88880000'))), [-32768])
        self.assertEqual(rgo.integers((0, 7, 3, bytes.fromhex('f3'))), [-1, -1, -1])


if __name__ == '__main__':
    unittest.main()

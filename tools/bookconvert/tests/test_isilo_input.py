"""Independent iSilo/RFC1951 fixtures and Palm raster compatibility checks."""
import hashlib
import importlib.util
from pathlib import Path
import struct
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


isilo, c = load('isilo_input'), load('convert_book')


def word_stream(bits):
    unused = (32 - len(bits) % 32) % 32
    bits = bits + [0] * unused
    return b''.join(sum(value << bit for bit, value in enumerate(bits[i:i + 32])).to_bytes(4, 'big')
                    for i in range(0, len(bits), 32)), unused // 8


def little(value, width):
    return [(value >> bit) & 1 for bit in range(width)]


def code(value, width):
    return [(value >> bit) & 1 for bit in reversed(range(width))]


def text_record(text, back_reference=False):
    # Independent dynamic-tree writer: literal symbols have nine-bit codes.
    # Only code-length symbols 1 and 9 are needed, with codes 0 and 1.
    literal_count = 258 if back_reference else 257
    order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1]
    tree = little(literal_count - 257, 5) + little(0, 5) + little(14, 4)
    for symbol in order:
        tree += little(1 if symbol in (1, 9) else 0, 3)
    tree += [1] * literal_count + [0]
    packed_tree, tree_padding = word_stream(tree)
    blocks, padding = [], [tree_padding]
    for start in range(0, len(text), 4096):
        part = text[start:start + 4096]
        if back_reference:
            assert part == b'AAAA'
            bits = code(65, 9) + code(257, 9) + [0] + code(256, 9)
        else:
            bits = [bit for value in part for bit in code(value, 9)] + code(256, 9)
        block, unused = word_stream(bits)
        blocks.append(block)
        padding.append(unused)
    count = len(blocks) + 1
    header_size = (8 + count * 3 + 3) // 4 * 4
    offset, offsets = header_size + len(packed_tree), []
    for block in blocks:
        offsets.append(offset // 4)
        offset += len(block)
    offsets.append(offset // 4)
    result = bytearray(struct.pack('>4H', 0x0400, 0, 0x0200, count))
    result.extend(struct.pack('>' + str(count) + 'H', *offsets))
    result.extend(padding)
    result.extend(b'\0' * (header_size - len(result)))
    return bytes(result) + packed_tree + b''.join(blocks)


def palm_bitmap(width, height, pixels, compression=False):
    assert len(pixels) == width * height * 2
    header = struct.pack('>4H2BH2BH', width, height, width * 2, 0x8400 if compression else 0x400,
                         16, 2, 0, 0, 2 if compression else 0, 0)
    data = b'\x05\x06\x05\0\0\0\0\0'
    if compression:
        # One literal packet per row, no matching encoder under test is used.
        payload = b''.join(bytes([width - 1]) + pixels[y * width * 2:(y + 1) * width * 2] for y in range(height))
        data += struct.pack('>H', len(payload) + 2) + payload
    else:
        data += pixels
    return b'\x04\x04\0\0' + header + data


def fixture(text=None, picture=True):
    text = text if text is not None else 'Начало книги\nПоследняя строка'.encode('cp1251')
    index = bytearray(56)
    index[:6] = b'\0\x80\x03\0\x03\0'
    struct.pack_into('>I', index, 20, len(text))
    records = [bytes(index), text_record(text)]
    if picture:
        records += [palm_bitmap(2, 1, bytes.fromhex('f80007e0'), True),
                    palm_bitmap(1, 1, bytes.fromhex('001f'))]
        # Two horizontal tiles become one three-pixel original picture.
        entry = bytes([0, 0, 3, 1]) + struct.pack('>HH', 2, 4)
        records.append(b'\x04\x05\0\0\x06\0' + struct.pack('>IHH', 0, 8, 0) + entry)
    return pack_records(records), records


def pack_records(records):
    header = bytearray(78)
    header[:5] = b'Book\0'
    header[60:68] = b'SDocSilX'
    struct.pack_into('>H', header, 76, len(records))
    table, offset = bytearray(), 78 + len(records) * 8
    for number, record in enumerate(records):
        table.extend(struct.pack('>II', offset, number))
        offset += len(record)
    return bytes(header + table) + b''.join(records)


def png_pixels(data):
    at, compressed, dimensions = 8, bytearray(), None
    while at < len(data):
        size = struct.unpack_from('>I', data, at)[0]
        kind, payload = data[at + 4:at + 8], data[at + 8:at + 8 + size]
        assert zlib.crc32(kind + payload) & 0xffffffff == struct.unpack_from('>I', data, at + 8 + size)[0]
        if kind == b'IHDR':
            dimensions = struct.unpack('>IIBBBBB', payload)
        if kind == b'IDAT':
            compressed.extend(payload)
        at += size + 12
    return dimensions, zlib.decompress(compressed)


class ISiloInput(unittest.TestCase):
    def test_words_trees_backrefs_and_exact_block_lengths(self):
        for text in (b'All the text.\n', b'\0\xff' * 3500, bytes(range(256)) * 127):
            self.assertEqual(isilo.text_record(text_record(text), len(text)), text)
        self.assertEqual(isilo.text_record(text_record(b'AAAA', True), 4), b'AAAA')
        with self.assertRaises(isilo.ISiloError):
            isilo.text_record(text_record(b'AAAA', True), 3)

    def test_bitmap_tiles_and_rgb_pixels(self):
        _, records = fixture()
        images = list(isilo.Document(records).pictures())
        self.assertEqual(len(images), 1)
        dimensions, pixels = png_pixels(images[0])
        self.assertEqual(dimensions, (3, 1, 8, 2, 0, 0, 0))
        self.assertEqual(pixels, b'\0\xff\0\0\0\xff\0\0\0\xff')
        # Widths beginning with byte 0x0c are ordinary wide Palm bitmaps too.
        dimensions, pixels = png_pixels(isilo.bitmap(palm_bitmap(3075, 1, b'\xf8\0' * 3075)))
        self.assertEqual(dimensions[:2], (3075, 1))
        self.assertEqual(pixels, b'\0' + b'\xff\0\0' * 3075)

    def test_scanline_rle_and_recovery_of_mistagged_rasters(self):
        # RLE-tagged raster: four two-byte white scanlines.
        for method in (1, 2):
            header = struct.pack('>4H2BH2BH', 9, 4, 2, 0x8000, 1, 2, 0, 0, method, 0)
            image = b'\x04\x04\0\0' + header + b'\0\x04\x08\0'
            dimensions, pixels = png_pixels(isilo.bitmap(image))
            self.assertEqual(dimensions[:2], (9, 4))
            self.assertEqual(pixels, (b'\0' + b'\xff' * 27) * 4)
        header = struct.pack('>4H2BH2BH', 2, 2, 4, 0x8400, 16, 2, 0, 0, 2, 0)
        # Scanline masks: red/green first row, then replace green with blue.
        payload = bytes.fromhex('f0f80007e030001f')
        image = b'\x04\x04\0\0' + header + b'\x05\x06\x05\0\0\0\0\0' + struct.pack('>H', len(payload) + 2) + payload
        _, pixels = png_pixels(isilo.bitmap(image))
        self.assertEqual(pixels, bytes.fromhex('00ff000000ff0000ff00000000ff'))

    def test_conversion_false_suffix_and_clean_failures(self):
        for extension in ('.fb2', '.epub'):
            with self.subTest(extension=extension), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source, target = root / 'wrong-name.ibk', root / ('reading' + extension)
                source.write_bytes(fixture()[0])
                before = hashlib.sha256(source.read_bytes()).digest()
                self.assertEqual(c.detect_input(source), '.pdb')
                report = c.convert_book(source, target)
                self.assertIn('iSilo', ' '.join(report['warnings']))
                if extension == '.fb2':
                    document = ET.parse(target).getroot()
                    self.assertEqual(len(list(document.iter('{' + c.FB + '}binary'))), 1)
                else:
                    with zipfile.ZipFile(target) as archive:
                        self.assertIsNone(archive.testzip())
                        document = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                        self.assertEqual(sum(name.endswith('.png') for name in archive.namelist()), 1)
                text = ''.join(document.itertext())
                self.assertLess(text.index('Начало книги'), text.index('Последняя строка'))
                self.assertIn('Иллюстрации', text)
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                self.assertEqual(sorted(p.name for p in root.iterdir()), sorted([source.name, target.name]))
        data, records = fixture()
        records[2] = records[2][:4] + bytes.fromhex('0c034b00000300210024000017') + records[2][17:]
        with self.assertRaisesRegex(isilo.ISiloError, 'iSilo'):
            list(isilo.Document(records).pictures())
        for change in (lambda data: data[:-4], lambda data: data[:78] + b'\0' * 4 + data[82:]):
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source, target = root / 'source.pdb', root / 'reading.epub'
                source.write_bytes(change(data))
                with self.assertRaises(c.ConversionError):
                    c.convert_book(source, target)
                self.assertEqual(list(root.iterdir()), [source])

    def test_text_only_export_skips_unusable_images_but_keeps_full_text_and_markers(self):
        text = 'Начало. Ёж и ёлка.\n\nПоследняя строка — конец.'.encode('cp1251')
        original, records = fixture(text)
        # The image record has a damaged iSilo lossy header. Its bytes are
        # deliberately unavailable to the text-only path; normal reading fails.
        records[2] = b'\x04\x04\0\0' + bytes.fromhex('0c034b00000200010024000017') + b'unsupported raster'
        unsupported = pack_records(records)
        for data in (original, unsupported):
            for suffix in ('.fb2', '.epub'):
                with self.subTest(unsupported=data is unsupported, target=suffix), tempfile.TemporaryDirectory(prefix='HomeLibRu-isilo-none-') as folder:
                    root = Path(folder)
                    source, target = root/'wrong-suffix.ibk', root/('result'+suffix)
                    source.write_bytes(data)
                    before = hashlib.sha256(data).digest()
                    report = c.convert_book(source, target, image_quality='none', tools_root=root/'no-codecs')
                    if suffix == '.fb2':
                        document = ET.parse(target).getroot()
                        self.assertFalse([node for node in document.iter() if c.tag(node) in {'image','binary','coverpage'}])
                    else:
                        with zipfile.ZipFile(target) as archive:
                            self.assertIsNone(archive.testzip())
                            document = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                            package = ET.fromstring(archive.read(next(name for name in archive.namelist() if name.endswith('.opf'))))
                            self.assertFalse([node for node in package.iter() if node.get('media-type','').startswith('image/')])
                            self.assertFalse([name for name in archive.namelist() if name.endswith(('.png','.jpg','.jpeg'))])
                    paragraphs = [''.join(node.itertext()) for node in document.iter() if c.tag(node)=='p']
                    self.assertEqual([value for value in paragraphs if value][:2], ['Начало. Ёж и ёлка.','Последняя строка — конец.'])
                    self.assertEqual(paragraphs.count('[Изображение не включено в эту копию]'), 1)
                    self.assertTrue(any('без изображений' in warning for warning in report['warnings']))
                    self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                    self.assertEqual(sorted(p.name for p in root.iterdir()), sorted([source.name,target.name]))
                    existing = target.read_bytes()
                    with self.assertRaises(c.ConversionError):
                        c.convert_book(source,target,image_quality='none')
                    self.assertEqual(target.read_bytes(),existing)

    def test_text_only_checks_original_text_and_picture_references(self):
        empty, _ = fixture(b' \n\t')
        _, records = fixture()
        # A missing root is a corrupt table, not an unavailable raster decoder.
        records[-1] = records[-1][:-4] + struct.pack('>HH', 500, 4)
        for data in (empty, pack_records(records)):
            with tempfile.TemporaryDirectory(prefix='HomeLibRu-isilo-invalid-none-') as folder:
                root = Path(folder)
                source, target = root/'source.pdb', root/'result.epub'
                source.write_bytes(data)
                with self.assertRaises(c.ConversionError):
                    c.convert_book(source,target,image_quality='none')
                self.assertEqual(list(root.iterdir()),[source])

    def test_damaged_images_still_fail_reading_and_other_quality_modes(self):
        _, records = fixture()
        records[2] = b'\x04\x04\0\0' + bytes.fromhex('0c034b00000200010024000017') + b'unsupported raster'
        for profile,reading in [('original',False),('balanced',False),('economy',False),('ask',False),('none',True)]:
            with self.subTest(profile=profile,reading=reading), tempfile.TemporaryDirectory(prefix='HomeLibRu-isilo-reading-') as folder:
                root = Path(folder)
                source, target = root/'source.pdb', root/'result.epub'
                source.write_bytes(pack_records(records))
                with self.assertRaisesRegex(c.ConversionError,'iSilo'):
                    c.convert_book(source,target,image_quality=profile,reading=reading)
                self.assertEqual(list(root.iterdir()),[source])

    def test_invalid_tables_and_raster_bounds(self):
        record = text_record(b'Hello')
        for data in (record[:-1], record[:8] + b'\0\0' + record[10:], record[:12] + b'\xff\xff' + record[14:]):
            with self.assertRaises(isilo.ISiloError):
                isilo.text_record(data, 5)
        for lengths in ([1, 1, 1], [0, 0], [16]):
            with self.assertRaises(isilo.ISiloError):
                isilo.Huffman(lengths)
        with self.assertRaises(isilo.ISiloError):
            isilo.unpack_bitmap(b'\xff\0\0', 2, 1, 2, 2)
        with self.assertRaises(isilo.ISiloError):
            isilo.unpack_bitmap(b'\0\0\0', 2, 1, 1, 1)


if __name__ == '__main__':
    unittest.main()

"""B1 fixtures written independently from the published record schema."""
import base64
import hashlib
import importlib.util
import lzma
import os
from pathlib import Path
import tempfile
import struct
import unittest
import xml.etree.ElementTree as ET
from zipfile import ZipFile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


c, b1 = load('convert_book'), load('b1_input')
fixed = load('fixed_layout')
TOOLS = Path(os.environ.get('HOMELIB_TEST_TOOLS', ROOT.parents[1] / 'Program/Out/Bin64/tools'))
BOOK = b'''<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><genre>prose</genre><author><nickname>Writer</nickname></author><book-title>Book</book-title><lang>en</lang></title-info><document-info><author><nickname>Editor</nickname></author><date>2026-10-24</date><id>b1-fixture</id><version>1.0</version></document-info></description><body><section><title><p>First chapter</p></title><p>Beginning. <strong>Bold phrase.</strong> Tail.</p></section><section><p>The final original paragraph.</p></section></body></FictionBook>'''


def num(value, width=0):
    if value is None:
        result = bytearray(b'\1')
    else:
        sign, value = int(value < 0), abs(value)
        result = bytearray([((value & 63) << 1) | sign]); value >>= 6
        while value:
            result[-1] |= 128; result.append(value & 127); value >>= 7
    while len(result) < width:
        result[-1] |= 128; result.append(0)
    return bytes(result)


def binary(data):
    return num(len(data)) + data + num(0)


def block(data, kind):
    return num(kind) + binary(data) + zlib.adler32(data).to_bytes(4, 'big')


def chunk(data, compressed, split=False):
    if not compressed:
        return block(data, 1)
    packed = lzma.compress(data, format=lzma.FORMAT_ALONE)
    packed = packed[:5] + packed[13:]
    if split:
        middle = max(6, len(packed) // 2)
        return block(packed[:middle], 2) + block(packed[middle:], 3)
    return block(packed, 2)


def fixture(content=BOOK, *, compressed=True, split=False, name='book.wrong.doc',
            corrupt=False, wrong_size=False, wrong_header=False, unsafe=False,
            multiple=False, cycle=False):
    if unsafe: name = '../outside.fb2'

    def header(ident=0, altered=False):
        value = ('different.fb2' if altered else name).encode()
        return num(ident) + num(None) + num(len(value)) + value + num(0) + num(1423280990175) + num(2) + num(-1) + num(32) + num(None)

    complete = num(2) + header(altered=wrong_header) + binary(content) + num(None)
    # Non-minimal pointer integers reserve stable space while finding offsets.
    def catalogue(offset):
        pointer = num(1) + num(offset, 10) + num(0)
        if cycle:
            return num(0) + num(1) + num(256) + num(0)
        data = num(1) + pointer + header() + num(len(content) + int(wrong_size))
        if multiple: data += num(1) + pointer + header(1) + num(len(content))
        return data + num(None)

    offset = 4096
    catalog = chunk(catalogue(offset), compressed)
    if len(catalog) > offset - 256: raise AssertionError('fixture catalogue size')
    head = ('b1:as v:0.4 a:fixture n:1 t:' + ('2' if multiple else '1')).encode().ljust(255, b' ') + b'\xfc'
    # Arbitrary padding is skipped using the catalogue's complete-file pointer.
    data = head + catalog + b'\0' * (offset - 256 - len(catalog)) + chunk(complete, compressed, split) + num(None) + b'\xfcc:1/256/0 b1:ae'
    if corrupt:
        data = data[:offset + 10] + bytes([data[offset + 10] ^ 1]) + data[offset + 11:]
    return data


class B1Input(unittest.TestCase):
    def test_native_handoff_keeps_original_payload_and_never_overwrites_source(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-b1-test-') as folder:
            root = Path(folder); source = root / 'book.b1'; source.write_bytes(fixture())
            original = source.read_bytes(); target = root / 'reader.payload'
            self.assertEqual(b1.extract_file(source, target), 'book.wrong.doc')
            self.assertEqual(target.read_bytes(), BOOK)
            self.assertEqual(source.read_bytes(), original)
            for destination in (source, target):
                with self.assertRaises(b1.ArchiveError): b1.extract_file(source, destination)
                self.assertEqual(source.read_bytes(), original)
                self.assertEqual(target.read_bytes(), BOOK)

    def test_scan_layout_choice_reaches_the_book_inside_archive(self):
        row = bytes([180, 40, 20]) * 768 + bytes([40, 160, 80]) * 768
        picture = fixed.png(row * 768, 1536, 768)
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-b1-test-') as folder:
            root = Path(folder); source = root / 'spread.b1'
            source.write_bytes(fixture(picture, name='spread.png'))
            output = root / 'split.fb2'
            c.convert_book(source, output, tools_root=TOOLS, image_quality='high', scan_layout='split')
            tree = ET.parse(output).getroot()
            ns = '{http://www.gribuser.ru/xml/fictionbook/2.0}'
            images = [base64.b64decode(''.join(n.itertext())) for n in tree.findall(ns + 'binary')]
            self.assertEqual(len(list(tree.iter(ns + 'image'))), 2)
            self.assertEqual([struct.unpack('>II', data[16:24]) for data in images], [(768, 768), (768, 768)])

    def test_public_schema_plain_lzma_and_split_streams_follow_pointers(self):
        for compressed, split in ((False, False), (True, False), (True, True)):
            with self.subTest(compressed=compressed, split=split):
                name, data = b1.extract(fixture(compressed=compressed, split=split))
                self.assertEqual(name, 'book.wrong.doc')
                self.assertEqual(data, BOOK)

    def test_false_suffix_reading_and_both_exports_preserve_complete_book(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-b1-test-') as folder:
            root = Path(folder); source = root / 'actually-archive.pdf'; source.write_bytes(fixture())
            before = hashlib.sha256(source.read_bytes()).digest()
            self.assertEqual(c.detect_input(source), '.b1')
            for suffix, reading in (('.epub', True), ('.epub', False), ('.fb2', False)):
                output = root / (str(reading) + suffix)
                c.convert_book(source, output, reading=reading)
                if suffix == '.epub':
                    with ZipFile(output) as archive:
                        self.assertIsNone(archive.testzip())
                        text = ''.join(''.join(ET.fromstring(archive.read(n)).itertext()) for n in archive.namelist() if n.endswith('.xhtml'))
                else: text = ''.join(ET.parse(output).getroot().itertext())
                for fragment in ('Beginning. ', 'Bold phrase.', ' Tail.', 'The final original paragraph.'):
                    self.assertIn(fragment, text)
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
            self.assertEqual(len(list(root.iterdir())), 4)

    def test_corruption_wrong_record_size_paths_cycles_and_ambiguity_fail_atomic(self):
        for options in ({'corrupt': True}, {'wrong_size': True}, {'wrong_header': True}, {'unsafe': True}, {'multiple': True}, {'cycle': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix='HomeLibRu-b1-test-') as folder:
                root = Path(folder); source = root / 'source.b1'; source.write_bytes(fixture(**options))
                before = source.read_bytes()
                for suffix in ('.fb2', '.epub'):
                    with self.assertRaises(c.ConversionError): c.convert_book(source, root / ('result' + suffix))
                    self.assertEqual(list(root.iterdir()), [source])
                    self.assertEqual(source.read_bytes(), before)

    def test_numbers_null_nonminimal_signs_and_bad_volume_headers(self):
        for value in (None, 0, 1, -1, 128, -128, 2**63 - 1, -(2**63)):
            self.assertEqual(b1.number(b1.Bytes(num(value))), value)
        self.assertIsNone(b1.number(b1.Bytes(num(None, 9))))
        self.assertEqual(b1.number(b1.Bytes(num(0, 10))), 0)
        with self.assertRaises(b1.ArchiveError): b1.number(b1.Bytes(b'\x80' * 12))
        data = fixture()
        for broken in (data[:-1], data.replace(b'n:1', b'n:2', 1), data.replace(b'v:0.4', b'v:0.5', 1), data.replace(b'b1:ae', b'b1:ve')):
            with self.subTest(length=len(broken)), self.assertRaises(b1.ArchiveError): b1.extract(broken)


if __name__ == '__main__': unittest.main()

"""Independent saved-project fixtures: index order, rich text and atomic errors."""
import hashlib
from contextlib import closing
import importlib.util
from pathlib import Path
import sqlite3
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


c, jutoh = load('convert_book'), load('jutoh_input')


def u32(value):
    return struct.pack('<I', value)


def string(value):
    raw = value.encode('utf-8')
    return u32(len(raw)) + raw


def props(values):
    result = bytearray()
    for key, value in [*values.items(), ('*END*', '*END*')]:
        if isinstance(value, bool):
            result += string('bool') + string(key) + bytes([value])
        elif isinstance(value, int):
            result += string('long') + string(key) + struct.pack('<q', value)
        else:
            result += string('string') + string(key) + string(value)
    return bytes(result)


def node(kind, children=(), text='', attributes=None):
    header = {'richtext-object-class': kind, 'richtext-is-shown': True}
    if children:
        header['richtext-child-count'] = len(children)
    content = {'text': text} if kind == 'text' else {}
    return props(header) + props(attributes or {}) + props(content) + b''.join(children)


def section(content):
    # Empty string marker, then a size-delimited rich-text buffer. The notes
    # contain tempting HTML which must never become book text.
    raw = props({'properties-notes': '<p>PRIVATE NOTES</p>'})[:-len(props({}))]
    raw += string('string') + string('properties-content-binary') + u32(0) + u32(len(content)) + content
    raw += props({'properties-stylesheet': '', 'asset-text': 'SCRIPT SHOULD NOT RUN'})
    return string('ADVANCED_COMPRESSED') + zlib.compress(raw)


def index_group(values):
    result = bytearray()
    for key, value in [*values.items(), ('END', 'END')]:
        result += string(key)
        result += u32(1) + u32(value) if isinstance(value, int) else u32(3) + string(value)
    return bytes(result)


def fixture(path, *, cycle=False, missing=False, unknown=False, broken=False, image=False):
    documents = [
        {'id': 2, 'parent': 0, 'type': 'root-document', 'title': 'Название проекта'},
        {'id': 4, 'parent': 2, 'type': 'thumbnail-folder-document', 'title': 'Content'},
        {'id': 12, 'parent': 4, 'type': 'text-section-document', 'title': 'Первая'},
        {'id': 11, 'parent': 4, 'type': 'text-section-document', 'title': 'Вторая'},
        {'id': 5, 'parent': 2, 'type': 'thumbnail-folder-document', 'title': 'Scraps'},
        {'id': 20, 'parent': 5, 'type': 'text-section-document', 'title': 'Черновик'}]
    if cycle:
        documents[1]['parent'] = 12
    metadata = {'doc_count': len(documents), 'section_root_document': 4, 'scrap_root_document': 5,
                'title': '', 'author': 'Автор'}
    outline = string('pixie-utf8') + index_group(metadata) + b''.join(map(index_group, documents))
    one = node('text', text='Ё, ї, ў. 😀 Первая строка\x1dПродолжение', attributes={'attr-font-weight': 700, 'attr-font-style': 93})
    content = node('paragraphlayout', [node('paragraph', [one])])
    if image:
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        picture = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
        picture += chunk(b'IDAT', zlib.compress(b'\0\x11\x22\x33')) + chunk(b'IEND', b'')
        image_content = props({'image-type': 15, 'image-data-size': len(picture)})[:-len(props({}))]
        image_content += string('string') + string('image-data') + u32(0) + picture + props({})
        picture_node = props({'richtext-object-class': 'image'}) + props({}) + image_content
        content = node('paragraphlayout', [node('paragraph', [one, picture_node])])
    if unknown:
        content = node('equation', text='x')
    with closing(sqlite3.connect(path)) as database, database:
        database.executescript('CREATE TABLE ProjectObjects(Id TEXT PRIMARY KEY, ParentId TEXT, DataType TEXT, Title TEXT, Data BLOB);'
                               'CREATE TABLE ProjectIndex(Id TEXT PRIMARY KEY, DataType TEXT, Data BLOB);'
                               'CREATE TABLE ProjectVariables(Id TEXT PRIMARY KEY, HasAutoSave INTEGER);')
        database.execute('INSERT INTO ProjectIndex VALUES(?,?,?)', ('index', 'Index', outline))
        # Deliberately reverse physical row order relative to the book index.
        database.execute('INSERT INTO ProjectObjects VALUES(?,?,?,?,?)',
                         ('11', '4', 'joTextSectionScrap', 'old title', section(node('paragraphlayout', [node('paragraph', [node('text', text='Последняя строка')])]))))
        if not missing:
            blob = section(content)
            if broken:
                blob += b'junk'
            database.execute('INSERT INTO ProjectObjects VALUES(?,?,?,?,?)', ('12', '4', 'joTextSectionScrap', 'old title', blob))
        database.execute('INSERT INTO ProjectObjects VALUES(?,?,?,?,?)',
                         ('20', '5', 'joTextSectionScrap', 'Черновик', section(node('text', text='SECRET SCRAP'))))


class JutohInput(unittest.TestCase):
    def test_reading_and_exports_preserve_order_unicode_styles_and_image(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-jutoh-test-') as folder:
            root = Path(folder)
            source = root / 'wrong.pdf'
            fixture(source, image=True)
            before = hashlib.sha256(source.read_bytes()).digest()
            self.assertEqual(c.detect_input(source), '.jutoh')
            for extension, reading in (('.epub', True), ('.epub', False), ('.fb2', False)):
                output = root / (str(reading) + extension)
                warnings = c.convert_book(source, output, reading=reading)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        self.assertIsNone(archive.testzip())
                        body = next(name for name in archive.namelist() if name.endswith('.xhtml') and 'nav' not in name)
                        tree = ET.fromstring(archive.read(body))
                        self.assertEqual(sum(name.endswith('.png') for name in archive.namelist()), 1)
                        self.assertTrue(list(tree.iter('{' + c.XH + '}strong')))
                        self.assertTrue(list(tree.iter('{' + c.XH + '}em')))
                else:
                    tree = ET.parse(output).getroot()
                    self.assertEqual(len(list(tree.iter('{' + c.FB + '}binary'))), 1)
                    self.assertTrue(list(tree.iter('{' + c.FB + '}strong')))
                    self.assertTrue(list(tree.iter('{' + c.FB + '}emphasis')))
                text = ''.join(tree.itertext())
                self.assertLess(text.index('Первая строка'), text.index('Последняя строка'))
                self.assertIn('Ё, ї, ў. 😀', text)
                self.assertIn('Продолжение', text)
                for secret in ('PRIVATE NOTES', 'SECRET SCRAP', 'SCRIPT SHOULD NOT RUN'):
                    self.assertNotIn(secret, text)
                self.assertIn('Черновики', ' '.join(warnings['warnings']))
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
            self.assertEqual(len(list(root.iterdir())), 4)

    def test_corruption_unknown_elements_and_cycles_publish_nothing(self):
        for options in ({'cycle': True}, {'missing': True}, {'unknown': True}, {'broken': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix='HomeLibRu-jutoh-test-') as folder:
                root = Path(folder)
                source, output = root / 'source.jutoh', root / 'book.fb2'
                fixture(source, **options)
                original = source.read_bytes()
                with self.assertRaises(c.ConversionError):
                    c.convert_book(source, output)
                self.assertEqual(source.read_bytes(), original)
                self.assertEqual(list(root.iterdir()), [source])

    def test_catalogues_views_and_spoofed_suffix_are_not_books(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-jutoh-test-') as folder:
            source = Path(folder) / 'catalogue.jutoh'
            with closing(sqlite3.connect(source)) as database, database:
                database.executescript("CREATE TABLE Books(Id); CREATE VIEW ProjectObjects AS SELECT * FROM Books;"
                                       "CREATE TABLE ProjectIndex(DataType,Data); CREATE TABLE ProjectVariables(Id);")
                database.execute('INSERT INTO ProjectIndex VALUES(?,?)', ('Index', string('pixie-utf8')))
            before = source.read_bytes()
            self.assertEqual(c.detect_input(source), '.sqlite')
            with self.assertRaises(c.ConversionError):
                c.convert_book(source, source.with_suffix('.epub'))
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(list(source.parent.iterdir()), [source])

    def test_truncated_richtext_and_bounded_deflate(self):
        valid = section(node('paragraphlayout', [node('paragraph', [node('text', text='whole')])]))
        for data in (valid[:-1], valid + b'junk', string('ADVANCED_COMPRESSED') + zlib.compress(b'x' * (MAX_TEST + 1))):
            with self.subTest(size=len(data)):
                previous = jutoh.MAX_FILE
                try:
                    jutoh.MAX_FILE = MAX_TEST
                    with self.assertRaises(jutoh.JutohError):
                        jutoh.section(data)
                finally:
                    jutoh.MAX_FILE = previous


MAX_TEST = 8192

if __name__ == '__main__':
    unittest.main()

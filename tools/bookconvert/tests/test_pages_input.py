"""Independent IWA fixtures and Snappy vectors; no Apple application needed."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c, pages = load('convert_book'), load('pages_input')


def vint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def field(number, value):
    if isinstance(value, int):
        return vint(number << 3) + vint(value)
    return vint((number << 3) | 2) + vint(len(value)) + value


def record(ident, kind, body):
    info = field(1, ident) + field(2, field(1, kind) + field(3, len(body)))
    return vint(len(info)) + info + body


def fixture(path, *, nested=False, extra=False, attachment=False, wrong_kind=False, corrupt=False):
    text = 'Глава первая\n\nЁ, ї, ў. 😀 Полный текст.\nКонец книги.\n'
    if attachment:
        text += '\ufffc'
    raw = record(1, 10000 if not wrong_kind else 1, field(4, field(1, 2208)))
    raw += record(2208, 2001, field(1, 0) + field(3, text.encode()))
    raw += record(500, 2001, field(1, 1))  # Empty header is not another chapter.
    if extra:
        raw += record(501, 2001, field(1, 3) + field(3, b'Unordered text box'))
    # Literal-only Snappy, with the independently specified extended length.
    packed = vint(len(raw)) + bytes([60 << 2, len(raw) - 1]) + raw
    stream = b'\0' + len(packed).to_bytes(3, 'little') + packed
    if corrupt:
        stream = stream[:-1]
    content = io.BytesIO()
    with ZipFile(content, 'w') as archive:
        archive.writestr('Index/Document.iwa', stream)
    with ZipFile(path, 'w') as archive:
        if nested:
            archive.writestr('Index.zip', content.getvalue())
        else:
            archive.writestr('Index/Document.iwa', stream)
        archive.writestr('preview.jpg', b'A PREVIEW IS NOT THE BOOK')
    return text


class PagesInput(unittest.TestCase):
    def test_both_exports_and_reading_keep_complete_text_with_false_suffix(self):
        for nested in (False, True):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory(prefix='HomeLibRu-pages-test-') as folder:
                root = Path(folder)
                source = root / 'actually-pages.pdf'
                expected = fixture(source, nested=nested)
                before = hashlib.sha256(source.read_bytes()).digest()
                self.assertEqual(c.detect_input(source), '.pages')
                for target, reading in (('.epub', True), ('.epub', False), ('.fb2', False)):
                    output = root / (str(reading) + target)
                    report = c.convert_book(source, output, reading=reading)
                    if target == '.epub':
                        with ZipFile(output) as archive:
                            self.assertIsNone(archive.testzip())
                            tree = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                            self.assertFalse(any(name.endswith('.jpg') for name in archive.namelist()))
                    else:
                        tree = ET.parse(output).getroot()
                    text = ''.join(tree.itertext())
                    for line in expected.splitlines():
                        if line:
                            self.assertIn(line, text)
                    self.assertNotIn('A PREVIEW', text)
                    self.assertIn('Pages', ' '.join(report['warnings']))
                    self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
                self.assertEqual(len(list(root.iterdir())), 4)

    def test_unknown_layout_and_truncated_data_never_publish_partial_book(self):
        for options in ({'extra': True}, {'attachment': True}, {'wrong_kind': True}, {'corrupt': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix='HomeLibRu-pages-test-') as folder:
                root = Path(folder)
                source, output = root / 'source.pages', root / 'result.epub'
                fixture(source, **options)
                before = source.read_bytes()
                with self.assertRaises(c.ConversionError):
                    c.convert_book(source, output)
                self.assertEqual(source.read_bytes(), before)
                self.assertEqual(list(root.iterdir()), [source])

    def test_snappy_copy_forms_overlap_and_bounds(self):
        # One literal 'ab'; each of the three copy tags appends six bytes
        # at distance two, including overlapping matches.
        for copy in (bytes([9, 2]), bytes([22, 2, 0]), bytes([23, 2, 0, 0, 0])):
            self.assertEqual(pages.snappy(b'\x08\x04ab' + copy), b'abababab')
        for bad in (b'\x08\x04ab\x09\0', b'\x08\x04ab\x09\x03', b'\x07\x04ab\x09\x02', b'\x04\xf0', b'\x80' * 10):
            with self.subTest(data=bad), self.assertRaises(pages.PagesError):
                pages.snappy(bad)

    def test_corrupt_protobuf_and_nested_index_bounds(self):
        for raw in (b'\0', b'\x0a\x05x', b'\x0b', b'\x08' + b'\xff' * 10):
            with self.subTest(raw=raw), self.assertRaises(pages.PagesError):
                pages.fields(raw)
        class Book:
            def progress(self, *args):
                pass
        inner = io.BytesIO()
        with ZipFile(inner, 'w') as archive:
            archive.writestr('Index.zip', b'placeholder')
        outer = io.BytesIO()
        with ZipFile(outer, 'w') as archive:
            archive.writestr('Index.zip', inner.getvalue())
        with ZipFile(outer) as archive, self.assertRaises(pages.PagesError):
            pages.text_archive(archive, Book(), depth=1)


if __name__ == '__main__':
    unittest.main()

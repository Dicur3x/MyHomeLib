"""Independent cache writer fixtures, including mixed text and a saved cover."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
from zipfile import ZipFile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c, cr3 = load('convert_book'), load('cr3_input')
PICTURE = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0a8AAAAASUVORK5CYII=')
XML = ('''<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>prose</genre><author><nickname>Автор</nickname></author><book-title>Книга 😀</book-title><coverpage><image l:href="#cover"/></coverpage><lang>ru</lang></title-info><document-info><author><nickname>Editor</nickname></author><date>2026-10-24</date><id>cache-fixture</id><version>1.0</version></document-info></description>
<body><section id="first"><title><p>Глава</p></title><p>Начало <strong>жирный</strong> хвост ё ї ў.</p><p><a l:href="#note" type="note">Сноска</a></p></section><section><p>Последний абзац.</p></section></body>
<body name="notes"><section id="note"><p>Полный текст примечания.</p></section></body><binary id="cover" content-type="image/png">''' + base64.b64encode(PICTURE).decode() + '</binary></FictionBook>').encode()


def u16(value): return struct.pack('<H', value)
def u32(value): return struct.pack('<I', value)
def text(value):
    value = value.encode()
    return u16(len(value)) + value
def crc(value): return value + u32(zlib.crc32(value))


def fixture(*, alignment=48, compressed=True, corrupt=False, disconnected=False, cycle=False, missing_image=False):
    source = ET.fromstring(XML)
    if missing_image:
        source.remove(source.find('{' + cr3.FB + '}binary'))
    names, attrs = {'?xml': 1}, {}
    namespaces = {1: 'xmlns', 2: 'l'}
    values, nodes, counters = [], {}, {True: 0, False: 0}
    storages = {True: bytearray(), False: bytearray()}

    def name(table, value):
        if value not in table: table[value] = len(table) + 1
        return table[value]

    def value_id(value):
        if value not in values: values.append(value)
        return values.index(value)

    def allocate(is_element):
        counters[is_element] += 1
        return counters[is_element] * 16 + int(is_element)

    def save(ref, parent, tag='', attributes=(), children=(), value=''):
        is_element = bool(ref & 1)
        if is_element:
            attributes = [(ns, name(attrs, key), value_id(value)) for ns, key, value in attributes]
            payload = struct.pack('<HHhBBi', name(names, tag) if tag else 0, 0, len(attributes), 0, 0, len(children))
            payload += b''.join(u32(child) for child in children)
            payload += b''.join(struct.pack('<HHH', *attr) for attr in attributes)
        else:
            payload = text(value)
        units = (12 + len(payload) + 15) // 16
        data = struct.pack('<HHII', 1 if is_element else 2, units, ref | 2, parent) + payload
        storage = storages[is_element]
        address = len(storage) // 16
        storage.extend(data.ljust(units * 16, b'\0'))
        nodes[ref] = ((ref | 2) << 8 | 7, address)

    def visit(element, parent):
        ref = allocate(True)
        children = []
        if element.text:
            child = allocate(False); save(child, ref, value=element.text); children.append(child)
        for child in element:
            children.append(visit(child, ref))
            if child.tail:
                ident = allocate(False); save(ident, ref, value=child.tail); children.append(ident)
        attributes = []
        for key, value in element.attrib.items():
            if key.startswith('{http://www.w3.org/1999/xlink}'):
                attributes.append((2, key.split('}', 1)[1], value))
            else:
                attributes.append((0, key, value))
        if element is source:
            attributes += [(0, 'xmlns', cr3.FB), (1, 'l', 'http://www.w3.org/1999/xlink')]
        save(ref, parent, element.tag.split('}')[-1], attributes, children)
        return ref

    root = allocate(True)
    prolog = allocate(True); save(prolog, root, '?xml')
    book = visit(source, root)
    save(root, 0, children=(prolog, root if cycle else book))
    if disconnected:
        extra = allocate(False); save(extra, root, value='Unreachable original text')
    mapping = b'MAPS'
    for kind, table in ((b'ELEM', {v: k for k, v in names.items()}), (b'ATTR', {v: k for k, v in attrs.items()}), (b'NMSP', namespaces)):
        body = b'IMAP' + u16(len(table))
        for ident, value in sorted(table.items()): body += b'IDMI' + u16(ident) + text(value) + b'\0'
        mapping += kind + crc(body) + u16(512)
    mapping += b'ATTV' + crc(b'STRS' + u32(len(values)) + b''.join(text(value) for value in values))
    mapping += crc(b'NIDM' + u32(0) + b'NIDM')
    mapping = crc(mapping)
    contents = {(3, 0): bytes(storages[True]), (2, 0): bytes(storages[False]), (6, 0): mapping,
                (9, 0): struct.pack('<III', 0x19283746, counters[True], counters[False])}
    for kind, element in ((10, True), (11, False)):
        contents[kind, 0] = b'\0' * 8 + b''.join(struct.pack('<II', *nodes[i * 16 + int(element)]) for i in range(1, counters[element] + 1))
    fmt = struct.Struct('<IHHiiiiQQI' + ('4x' if alignment == 48 else ''))
    result, entries = bytearray(1024), []
    for number, ((kind, ident), data) in enumerate(contents.items()):
        packed = zlib.compress(data) if compressed else data
        offset, allocated = len(result), (len(packed) + 1023) // 1024 * 1024
        entries.append(fmt.pack(0xc007b00c, kind, ident, number, offset, allocated, len(packed), cr3.fnv(data), cr3.fnv(packed), len(data) if compressed else 0))
        result.extend(packed.ljust(allocated, b'\0'))
    offset = len(result); index_size = (len(entries) + 1) * fmt.size
    allocated = (index_size + 1023) // 1024 * 1024
    entries.append(fmt.pack(0xc007b00c, 1, 0, len(entries), offset, allocated, index_size, 0, 0, 0))
    index = b''.join(entries)
    result.extend(index.ljust(allocated, b'\0'))
    result[:len(cr3.MAGIC)] = cr3.MAGIC
    struct.pack_into('<I', result, 40, len(result))
    result[alignment:alignment + fmt.size] = fmt.pack(0xc007b00c, 1, 0, len(entries) - 1, offset, allocated, index_size, cr3.fnv(index), cr3.fnv(index), 0)
    if corrupt: result[1028] ^= 1
    return bytes(result)


class CacheInput(unittest.TestCase):
    def test_complete_dom_both_alignments_compressed_and_uncompressed(self):
        for alignment in (44, 48):
            for compressed in (False, True):
                with self.subTest(alignment=alignment, compressed=compressed):
                    restored = ET.fromstring(cr3.recover(fixture(alignment=alignment, compressed=compressed)))
                    self.assertEqual(ET.tostring(restored), ET.tostring(ET.fromstring(XML)))

    def test_reading_and_both_exports_false_suffix_preserve_notes_and_cover(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-cr3-test-') as folder:
            root = Path(folder); source = root / 'cache.wrong.pdf'; source.write_bytes(fixture())
            before = hashlib.sha256(source.read_bytes()).digest()
            self.assertEqual(c.detect_input(source), '.cr3')
            for suffix, reading in (('.epub', True), ('.epub', False), ('.fb2', False)):
                output = root / (str(reading) + suffix)
                report = c.convert_book(source, output, reading=reading)
                if suffix == '.epub':
                    with ZipFile(output) as archive:
                        self.assertIsNone(archive.testzip())
                        texts = ''.join(''.join(ET.fromstring(archive.read(n)).itertext()) for n in archive.namelist() if n.endswith('.xhtml'))
                        self.assertIn(PICTURE, [archive.read(n) for n in archive.namelist() if n.endswith('.png')])
                else:
                    tree = ET.parse(output).getroot(); texts = ''.join(tree.itertext())
                    self.assertEqual(base64.b64decode(tree.find('{' + cr3.FB + '}binary').text), PICTURE)
                for text in ('Начало ', 'жирный', ' хвост ё ї ў.', 'Последний абзац.', 'Полный текст примечания.'):
                    self.assertIn(text, texts)
                self.assertIn('CR3', ' '.join(report['warnings']))
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
            self.assertEqual(len(list(root.iterdir())), 4)

    def test_corrupt_or_incomplete_documents_never_publish(self):
        for options in ({'corrupt': True}, {'disconnected': True}, {'cycle': True}, {'missing_image': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix='HomeLibRu-cr3-test-') as folder:
                root = Path(folder); source = root / 'source.cr3'; source.write_bytes(fixture(**options))
                before = source.read_bytes()
                for suffix in ('.fb2', '.epub'):
                    with self.assertRaises(c.ConversionError): c.convert_book(source, root / ('result' + suffix))
                    self.assertEqual(source.read_bytes(), before)
                    self.assertEqual(list(root.iterdir()), [source])

    def test_other_versions_truncation_bounds_and_broken_tables_rejected(self):
        data = fixture()
        for broken in (data[:500], data[:-1], data.replace(b'v3.03.09', b'v3.03.12', 1), data[:40] + b'\xff' * 4 + data[44:]):
            with self.subTest(length=len(broken)), self.assertRaises(cr3.CacheError): cr3.recover(broken)


if __name__ == '__main__': unittest.main()

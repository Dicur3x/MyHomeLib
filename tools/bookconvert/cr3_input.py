"""Recover complete FB2 DOMs from CoolReader cache 3.03.09 (MIT).

Independent bounded reader of the on-disk structures documented by CoolReader
revision 489d680db4e0ace0d274aec4523c8d16cd934315, crengine/src/{lvtinydom,
lstridmap,lvstring}.cpp. No CoolReader code or executable is bundled. Other
cache versions and caches that depend on an external source are rejected.
"""
import base64
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET
import zlib

MAGIC = b'CoolReader 3 Cache File v3.03.09: c0m1\n\0'
MAX_SOURCE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_NODES = 200000
FB = 'http://www.gribuser.ru/xml/fictionbook/2.0'
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]*\Z')


class CacheError(ValueError):
    pass


def fail(message):
    raise CacheError('CR3: ' + message)


def fnv(data):
    value = 14695981039346656037
    for byte in data:
        value = ((value * 1099511628211) & 0xffffffffffffffff) ^ byte
    return value


class Cursor:
    def __init__(self, data):
        self.data, self.at = data, 0

    def take(self, size):
        if size < 0 or self.at + size > len(self.data):
            fail('оборваны таблицы имён.')
        value = self.data[self.at:self.at + size]
        self.at += size
        return value

    def number(self, width):
        return int.from_bytes(self.take(width), 'little')

    def magic(self, value):
        if self.take(len(value)) != value:
            fail('неверная структура таблиц имён.')

    def text(self):
        return self.take(self.number(2)).decode('utf-8')

    def crc(self, start):
        checksum = zlib.crc32(self.data[start:self.at])
        if self.number(4) != checksum:
            fail('повреждена таблица имён (CRC).')


def name_tables(data):
    c = Cursor(data)
    c.magic(b'MAPS')
    tables = []
    for kind in (b'ELEM', b'ATTR', b'NMSP'):
        c.magic(kind)
        start = c.at
        c.magic(b'IMAP')
        count, table = c.number(2), {}
        if count > 1024:
            fail('слишком большая таблица имён.')
        for _ in range(count):
            c.magic(b'IDMI')
            ident, text = c.number(2), c.text()
            if ident >= 1024 or ident in table:
                fail('повторяется или повреждён идентификатор имени.')
            table[ident] = text
            props = c.number(1)
            if props not in (0, 1):
                fail('неверное описание элемента.')
            if props:
                c.take(4)
        c.crc(start)
        c.number(2)  # Next unknown name ID; not needed to read existing nodes.
        tables.append(table)
    c.magic(b'ATTV')
    start = c.at
    c.magic(b'STRS')
    count = c.number(4)
    if count > 65535:
        fail('слишком много значений атрибутов.')
    values = [c.text() for _ in range(count)]
    c.crc(start)
    start = c.at
    c.magic(b'NIDM')
    count = c.number(4)
    if count > MAX_NODES:
        fail('слишком много ссылок на разделы.')
    c.take(count * 6)
    c.magic(b'NIDM')
    c.crc(start)
    c.crc(0)
    if c.at != len(data):
        fail('неизвестное продолжение таблиц имён.')
    return (*tables, values)


def read_blocks(data):
    if not data.startswith(MAGIC):
        fail('эта версия кэша пока не поддерживается. Нужен исходный файл книги.')
    # This cache was emitted by a native C++ ABI. Its index records have
    # either 4-byte or 8-byte alignment; hashes validate the selected layout.
    for entry_size, header_at in ((48, 48), (44, 44)):
        if len(data) < header_at + entry_size:
            continue
        fmt = struct.Struct('<IHHiiiiQQI' + ('4x' if entry_size == 48 else ''))
        header = fmt.unpack_from(data, header_at)
        if header[0:3] != (0xc007b00c, 1, 0):
            continue
        break
    else:
        fail('не найден индекс документа.')
    file_size = struct.unpack_from('<I', data, 40)[0]
    if file_size != len(data):
        fail('кэш сохранён не полностью.')

    def bounds(item):
        magic, kind, ident, number, off, allocated, size, dh, ph, expanded = item
        if (magic != 0xc007b00c or not 0 <= kind <= 14 or number < 0 or
                not 1024 <= off <= len(data) or off % 1024 or
                not 0 <= size <= allocated or allocated % 1024 or
                off + allocated > len(data) or expanded > MAX_SOURCE):
            fail('неверные размеры блока документа.')

    bounds(header)
    raw = data[header[4]:header[4] + header[6]]
    if (header[9] or not raw or len(raw) % entry_size or
            len(raw) // entry_size > 100000 or fnv(raw) != header[7]):
        fail('повреждён индекс документа.')
    blocks, ranges, total = {}, [], 0
    for at in range(0, len(raw), entry_size):
        item = fmt.unpack_from(raw, at)
        bounds(item)
        magic, kind, ident, number, off, allocated, size, dh, ph, expanded = item
        if allocated:
            ranges.append((off, off + allocated))
        if not kind:
            continue
        if (kind, ident) in blocks:
            fail('в индексе повторяется блок.')
        payload = data[off:off + size]
        if expanded:
            if fnv(payload) != ph:
                fail('повреждён сжатый блок документа.')
            decoder = zlib.decompressobj()
            payload = decoder.decompress(payload, expanded + 1)
            if (len(payload) != expanded or not decoder.eof or
                    decoder.unused_data or decoder.unconsumed_tail):
                fail('не удалось полностью распаковать блок документа.')
        total += len(payload)
        if total > MAX_TOTAL:
            fail('распакованный документ превышает 256 МБ.')
        if kind == 1:
            # The self-referencing index record retains the preceding hash.
            # Current index bytes were checked against the header above.
            if ident or item[3:7] != header[3:7] or expanded:
                fail('индекс не совпадает с заголовком.')
        elif fnv(payload) != dh:
            fail('повреждён блок документа.')
        blocks[kind, ident] = payload
    ranges.sort()
    if any(left[1] > right[0] for left, right in zip(ranges, ranges[1:])):
        fail('блоки документа перекрываются.')
    if (1, 0) not in blocks:
        fail('отсутствует индекс документа.')
    return blocks


def recover(data):
    """Return a complete reconstructed FB2; never a list of loose text chunks."""
    if len(data) > MAX_SOURCE:
        fail('исходный кэш превышает 64 МБ.')
    try:
        blocks = read_blocks(data)
        elements, attributes, namespaces, values = name_tables(blocks[6, 0])
        magic, element_count, text_count = struct.unpack('<III', blocks[9, 0])
        if magic != 0x19283746 or not (0 < element_count <= MAX_NODES and 0 < text_count <= MAX_NODES):
            fail('неверное число узлов документа.')
        for kind, count in ((10, element_count), (11, text_count)):
            expected = (count + 1 + 1023) // 1024
            if {i for k, i in blocks if k == kind} != set(range(expected)):
                fail('отсутствует часть дерева документа.')
            for ident in range(expected):
                if len(blocks[kind, ident]) != min(1024, count + 1 - ident * 1024) * 8:
                    fail('оборван список узлов документа.')
        seen = set()

        def node(ref, parent=0, depth=0):
            if depth > 128 or not ref or ref in seen or ref & 14:
                fail('повреждены связи разделов документа.')
            seen.add(ref)
            index, kind = ref >> 4, 10 if ref & 1 else 11
            count = element_count if ref & 1 else text_count
            if not 1 <= index <= count:
                fail('ссылка за пределами дерева документа.')
            handle, address = struct.unpack_from('<II', blocks[kind, index >> 10], (index & 1023) * 8)
            if (handle >> 8) != (ref | 2):
                fail('узел не сохранён в независимом виде.')
            storage = blocks[3 if ref & 1 else 2, address >> 16]
            offset = (address & 65535) * 16
            typ, units, ident, owner = struct.unpack_from('<HHII', storage, offset)
            size = units * 16
            if (ident & ~14 != ref or owner & ~14 != parent or
                    typ != (1 if ref & 1 else 2) or size < 16 or offset + size > len(storage)):
                fail('повреждено содержимое узла документа.')
            if not ref & 1:
                length = struct.unpack_from('<H', storage, offset + 12)[0]
                if length + 14 > size:
                    fail('оборвана строка книги.')
                return storage[offset + 14:offset + 14 + length].decode('utf-8')
            tag, ns, attr_count, method, reserved, child_count = struct.unpack_from('<HHhBBi', storage, offset + 12)
            if not 0 <= attr_count <= 1024 or not 0 <= child_count <= MAX_NODES or 24 + child_count * 4 + attr_count * 6 > size:
                fail('оборваны дочерние разделы или атрибуты.')
            children = struct.unpack_from('<' + 'I' * child_count, storage, offset + 24)
            attr_start = offset + 24 + child_count * 4
            attrs = []
            for i in range(attr_count):
                ans, aid, value = struct.unpack_from('<HHH', storage, attr_start + i * 6)
                attrs.append((namespaces[ans] if ans else '', attributes[aid], values[value]))
            name = elements[tag] if tag else ''
            if any(ch & 14 not in (0, 2) for ch in children):
                fail('неверный тип ссылки на дочерний раздел.')
            return name, namespaces[ns] if ns else '', attrs, [node(ch & ~14, ref, depth + 1) for ch in children]

        root = node(17)
        if len(seen) != element_count + text_count:
            fail('часть текста находится вне дерева книги.')
        if root[0] or root[1] or root[2]:
            fail('неизвестный корень дерева документа.')
        documents = []
        for item in root[3]:
            if isinstance(item, str):
                if item.strip():
                    fail('текст вне книги.')
            elif item[0] == '?xml' and not item[3]:
                continue
            else:
                documents.append(item)
        if len(documents) != 1 or documents[0][0] != 'FictionBook':
            fail('этот кэш не содержит независимую FB2-книгу. Нужен исходный файл.')

        def element(item, environment):
            name, prefix, attrs, children = item
            if not NAME.fullmatch(name):
                fail('неизвестный элемент дерева книги.')
            environment = environment.copy()
            for ans, key, value in attrs:
                if ans == 'xmlns':
                    environment[key] = value
                elif not ans and key == 'xmlns':
                    environment[''] = value
            uri = environment[prefix] if prefix else environment.get('', '')
            result = ET.Element('{' + uri + '}' + name if uri else name)
            for ans, key, value in attrs:
                if ans == 'xmlns' or not ans and key == 'xmlns':
                    continue
                if not NAME.fullmatch(key):
                    fail('неизвестный атрибут книги.')
                uri = environment[ans] if ans else ''
                qualified = '{' + uri + '}' + key if uri else key
                if qualified in result.attrib:
                    fail('повторяется атрибут книги.')
                result.set(qualified, value)
            previous = None
            for child in children:
                if isinstance(child, str):
                    if previous is None:
                        result.text = (result.text or '') + child
                    else:
                        previous.tail = (previous.tail or '') + child
                else:
                    previous = element(child, environment)
                    result.append(previous)
            return result

        document = element(documents[0], {'xml': 'http://www.w3.org/XML/1998/namespace'})
        if document.tag != '{' + FB + '}FictionBook' or document.find('{' + FB + '}body') is None:
            fail('в кэше нет читаемой FB2-книги.')
        binaries = {}
        for binary in document.findall('{' + FB + '}binary'):
            ident = binary.get('id', '')
            if not ident or ident in binaries:
                fail('повторяется или отсутствует имя вложенного изображения.')
            try:
                payload = base64.b64decode(re.sub(r'\s', '', ''.join(binary.itertext())), validate=True)
            except ValueError as error:
                raise CacheError('CR3: повреждено вложенное изображение.') from error
            if not payload or len(payload) > MAX_SOURCE:
                fail('неверный размер вложенного изображения.')
            binaries[ident] = True
        for picture in document.iter('{' + FB + '}image'):
            href = picture.get('{http://www.w3.org/1999/xlink}href', '')
            if not href.startswith('#') or href[1:] not in binaries:
                fail('в кэше отсутствует изображение. Нужен исходный файл книги.')
        return ET.tostring(document, encoding='utf-8', xml_declaration=True)
    except CacheError:
        raise
    except (KeyError, IndexError, struct.error, UnicodeError, zlib.error, RecursionError) as error:
        raise CacheError('CR3: повреждён или неполон сохранённый документ.') from error


def convert(api, source, output, target, warnings):
    try:
        data = recover(Path(source).read_bytes())
    except CacheError as error:
        raise api.ConversionError(str(error)) from error
    if target == '.fb2':
        api.validate_fb2_output(api.xml(data, MAX_TOTAL))
        Path(output).write_bytes(data)
    else:
        import tempfile
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-cr3-') as folder:
            restored = Path(folder) / 'restored.fb2'
            restored.write_bytes(data)
            api.fb2_to_epub(restored, output, warnings, maximum=MAX_TOTAL)
    warnings.add('CR3: восстановлена целая FB2-книга из кэша. Настройки страниц и шрифта CoolReader не переносятся.')

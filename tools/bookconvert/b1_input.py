"""Bounded single-volume B1 0.4 book reader, independently from its public spec.

MIT. Specification: b1-pack/b1-pack revision
eb2c91854082c37d1f3fcc4edcc7bdfd5806dfc1, standard/src/site/apt/.
Uses Python's standard LZMA decoder; no archiver, JVM or author binary needed.
Only one-file unencrypted archives are accepted, without guessing which of
several files the reader intended. Archive paths and attributes are never applied.
"""
import lzma
from pathlib import Path
import re
import tempfile
import zlib

MAX_SOURCE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_ENTRIES = 20000


class ArchiveError(ValueError):
    pass


def fail(message):
    raise ArchiveError('B1: ' + message)


def number(stream):
    first = byte = stream.take(1)[0]
    value, shift = (first >> 1) & 63, 6
    while byte & 128:
        if shift > 62:
            fail('слишком длинное целое число.')
        byte = stream.take(1)[0]
        value |= (byte & 127) << shift
        shift += 7
    if value > (1 << 63) - (1 if not first & 1 else 0):
        fail('целое число за пределами формата.')
    return (None if not value else -value) if first & 1 else value


def binary(stream, maximum=MAX_TOTAL):
    parts, total = [], 0
    for _ in range(MAX_ENTRIES):
        size = number(stream)
        if size == 0:
            return b''.join(parts)
        if size is None or size < 0 or size > maximum - total:
            fail('неверный размер двоичных данных.')
        parts.append(stream.take(size))
        total += size
    fail('слишком много частей двоичных данных.')


class Bytes:
    def __init__(self, data, at=0):
        self.data, self.at = data, at

    def take(self, size):
        if size < 0 or self.at + size > len(self.data):
            fail('архив оборван.')
        result = self.data[self.at:self.at + size]
        self.at += size
        return result


def tokens(raw):
    text = raw.decode('utf-8')
    result, token, quoted, at = [], [], False, 0
    while at < len(text):
        char = text[at]
        at += 1
        if char == "'":
            if quoted and at < len(text) and text[at] == "'":
                token.append("'"); at += 1
            else:
                quoted = not quoted
        elif char.isspace() and not quoted:
            if token:
                result.append(''.join(token)); token = []
        else:
            token.append(char)
    if quoted:
        fail('оборван заголовок тома.')
    if token:
        result.append(''.join(token))
    return result


def fields(items):
    result = {}
    for item in items:
        key, separator, value = item.partition(':')
        if not separator or not value or key in result:
            fail('неверный заголовок тома.')
        result[key] = value
    return result


def pointer(stream):
    value = tuple(number(stream) for _ in range(3))
    if value[0] != 1 or any(n is None or n < 0 for n in value[1:]):
        fail('нужен полный однотомный архив.')
    return value


def header(stream):
    ident, parent = number(stream), number(stream)
    size = number(stream)
    if ident is None or ident < 0 or parent is not None and parent < 0 or size is None or not 0 < size <= 4096:
        fail('неверное описание файла.')
    name = stream.take(size).decode('utf-8')
    if (name in ('.', '..') or any(c in name for c in '/\\:\0') or
            any(ord(c) < 32 for c in name)):
        fail('небезопасное имя файла в архиве.')
    attributes = []
    for _ in range(64):
        code = number(stream)
        if code is None:
            return ident, parent, name, tuple(attributes)
        if code == 0:
            value = number(stream)
        elif code in (1, 2):
            value = number(stream), number(stream)
        else:
            fail('неизвестный атрибут файла.')
        attributes.append((code, value))
    fail('слишком много атрибутов файла.')


class RecordStream:
    def __init__(self, archive, location):
        volume, offset, skip = location
        if volume != 1 or not archive.start <= offset < archive.end or skip > MAX_TOTAL:
            fail('ссылка вне тома архива.')
        self.archive, self.offset = archive, offset
        self.buffer, self.at, self.properties, self.total = b'', 0, None, 0
        self.take(skip)

    def _block(self):
        c = Bytes(self.archive.data[:self.archive.end], self.offset)
        for _ in range(1024):
            kind = number(c)
            if kind != 5:
                break
        else:
            fail('слишком много пустых блоков.')
        if kind == 0:
            fail('архив защищён паролем. Сначала откройте его с паролем в архиваторе.')
        if kind not in (1, 2, 3):
            fail('отсутствует нужный блок архива.')
        raw = binary(c, MAX_SOURCE)
        if not raw or int.from_bytes(c.take(4), 'big') != zlib.adler32(raw):
            fail('повреждён блок архива (Adler-32).')
        self.offset = c.at
        return kind, raw

    def _chunk(self):
        kind, raw = self._block()
        if kind == 1:
            self.properties = None
            result = raw
        else:
            if kind == 2:
                if len(raw) < 5:
                    fail('оборван заголовок LZMA.')
                self.properties, raw = raw[:5], raw[5:]
            elif self.properties is None:
                fail('отсутствует начало сжатой части.')
            result = bytearray()
            for _ in range(MAX_ENTRIES):
                decoder = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE, memlimit=MAX_SOURCE)
                packed = self.properties + b'\xff' * 8 + raw
                while True:
                    left = MAX_TOTAL - self.total - len(result)
                    if left < 0:
                        fail('распакованная книга превышает 256 МБ.')
                    result.extend(decoder.decompress(packed, max_length=left + 1))
                    if len(result) + self.total > MAX_TOTAL:
                        fail('распакованная книга превышает 256 МБ.')
                    if decoder.eof:
                        break
                    if not decoder.needs_input:
                        fail('слишком большой сжатый блок.')
                    following, packed = self._block()
                    if following != 3:
                        fail('оборвана сжатая часть архива.')
                raw = decoder.unused_data
                if not raw:
                    break
            else:
                fail('слишком много потоков LZMA.')
            result = bytes(result)
        self.total += len(result)
        self.archive.expanded += len(result)
        if self.total > MAX_TOTAL or self.archive.expanded > MAX_TOTAL * 2:
            fail('распакованный архив превышает безопасный предел.')
        self.buffer, self.at = result, 0

    def take(self, size):
        if not 0 <= size <= MAX_TOTAL:
            fail('неверная длина данных записи.')
        parts = []
        while size:
            if self.at == len(self.buffer):
                self._chunk()
                if not self.buffer:
                    fail('пустая часть архива.')
            count = min(size, len(self.buffer) - self.at)
            parts.append(self.buffer[self.at:self.at + count])
            self.at += count
            size -= count
        return b''.join(parts)


class Archive:
    def __init__(self, data):
        if len(data) > MAX_SOURCE:
            fail('исходный архив превышает 64 МБ.')
        self.data, self.expanded = data, 0
        first = data.find(b'\xfc', 0, 4096)
        last = data.rfind(b'\xfc', max(0, len(data) - 4096))
        if first < 0 or last <= first or not last or data[last - 1] != 1:
            fail('не найдено начало или окончание архива.')
        head, tail = tokens(data[:first]), tokens(data[last + 1:])
        if not head or head[0] != 'b1:as' or not tail or tail[-1] != 'b1:ae':
            fail('нужен полный однотомный архив B1.')
        info, ending = fields(head[1:]), fields(tail[:-1])
        if info.get('v') != '0.4' or info.get('n') != '1' or not info.get('a'):
            fail('эта версия или многотомный архив пока не поддерживается.')
        if not re.fullmatch(r'[0-9]{1,5}', info.get('t', '')):
            fail('в архиве не указано допустимое число файлов.')
        self.count = int(info['t'])
        if not 0 < self.count <= MAX_ENTRIES:
            fail('слишком много файлов архива.')
        location = ending.get('c', '').split('/')
        if len(location) != 3 or not all(re.fullmatch(r'[0-9]{1,10}', value) for value in location):
            fail('не найден каталог архива.')
        self.catalogue = tuple(map(int, location))
        self.start, self.end = first + 1, last - 1

    def book(self):
        stream = RecordStream(self, self.catalogue)
        folders, identifiers, files, locations = {None}, set(), [], {self.catalogue}
        for _ in range(MAX_ENTRIES * 2):
            if len(identifiers) == self.count:
                break
            kind = number(stream)
            if kind == 5:
                continue
            if kind == 0:
                location = pointer(stream)
                if location in locations:
                    fail('зациклен каталог архива.')
                locations.add(location); stream = RecordStream(self, location)
                continue
            if kind not in (1, 3):
                fail('каталог архива неполон.')
            location, entry = pointer(stream), header(stream)
            ident, parent, name, attrs = entry
            if ident in identifiers or parent not in folders:
                fail('повреждены связи файлов в каталоге.')
            identifiers.add(ident)
            if kind == 3:
                folders.add(ident)
            else:
                size = number(stream)
                if size is None or not 0 < size <= MAX_TOTAL:
                    fail('неверный размер книги.')
                files.append((location, entry, size))
        if len(identifiers) != self.count:
            fail('каталог архива неполон.')
        if len(files) != 1:
            fail('архив должен содержать один файл книги. Сначала извлеките нужную книгу из архива.')
        location, entry, size = files[0]
        stream = RecordStream(self, location)
        if number(stream) != 2 or header(stream) != entry:
            fail('содержимое книги не совпадает с каталогом.')
        content = binary(stream, size)
        if len(content) != size:
            fail('книга извлечена не полностью.')
        return entry[2], content


def extract(data):
    try:
        return Archive(data).book()
    except ArchiveError:
        raise
    except (UnicodeError, lzma.LZMAError, ValueError, OverflowError) as error:
        raise ArchiveError('B1: повреждены данные архива.') from error


def convert(api, source, output, target, warnings, metadata):
    try:
        name, content = extract(Path(source).read_bytes())
    except ArchiveError as error:
        raise api.ConversionError(str(error)) from error
    suffix = Path(name).suffix.lower()
    if not re.fullmatch(r'\.[a-z0-9]{1,10}', suffix):
        suffix = '.bin'
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-b1-') as folder:
        book = Path(folder) / ('book' + suffix)
        book.write_bytes(content)
        if api.detect_input(book) in {'.b1', '.ha'}:
            raise api.ConversionError('B1: вложенные архивы нужно предварительно распаковать.')
        result = Path(folder) / ('converted' + target)
        report = api.convert_book(book, result, **metadata)
        Path(output).write_bytes(result.read_bytes())
        warnings.update(report['warnings'])


def extract_file(source, output):
    """Native reader handoff: keep an inner PDF as PDF, without conversion."""
    source, output = Path(source).resolve(), Path(output).absolute()
    if source == output.resolve() or output.exists():
        fail('файл результата должен быть новым и отличаться от исходника.')
    if source.stat().st_size > MAX_SOURCE:
        fail('исходный архив превышает 64 МБ.')
    name, content = extract(source.read_bytes())
    with output.open('xb') as stream:
        stream.write(content)
    return name


if __name__ == '__main__':
    import sys
    try:
        if len(sys.argv) != 3:
            fail('нужны пути исходного архива и результата.')
        extract_file(sys.argv[1], sys.argv[2])
    except (ArchiveError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

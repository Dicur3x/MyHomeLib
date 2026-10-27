"""Read bounded ICEContainer book text without executing the original reader."""
import bz2
import importlib.util
from pathlib import Path
import struct

MAX_FILE = 64 * 1024 * 1024
MAX_TABLE = 8 * 1024 * 1024
MAX_FILES = 4096
MAX_PARTS = 65536
MAGIC = b'ICEContainer 1.0'


def crypto():
    if not hasattr(crypto, 'module'):
        spec = importlib.util.spec_from_file_location('homelib_ibk_crypto', Path(__file__).with_name('ibk_crypto.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        crypto.module = module
    return crypto.module


def expand(data, limit):
    c = crypto()
    if limit < 0 or limit > MAX_FILE:
        raise c.IBKError('Распакованный текст IBK превышает предел чтения (64 МБ).')
    try:
        decoder = bz2.BZ2Decompressor()
        result = decoder.decompress(data, max_length=limit + 1)
        if len(result) > limit or not decoder.eof or decoder.unused_data:
            raise ValueError('invalid BZip2 boundary')
        return result
    except (OSError, EOFError, ValueError) as error:
        raise c.IBKError('Не удалось распаковать блок IBK: он повреждён или превышает допустимый размер.') from error


class Container:
    def __init__(self, raw):
        self.c = crypto()
        self.raw = raw
        self.files = {}
        self.secured = False
        if not raw.startswith(MAGIC) or not 44 <= len(raw) <= MAX_FILE:
            raise self.c.IBKError('Это не поддерживаемый контейнер ICE Book Reader либо файл обрезан.')
        footer = None
        last_error = None
        for secured, size in ((True, 36), (False, 28)):
            try:
                block = self.c.read_block(raw[-size:], self.c.format_data()[1][1] if secured else None)
                if len(block) != 20 or block[:4] != b'ICE1':
                    continue
                marker, stored, decoded, base = struct.unpack('<4sIIQ', block)
                if base < 16 or base > len(raw) - size or not 8 <= stored <= MAX_TABLE or decoded > MAX_TABLE:
                    continue
                position = len(raw) - size - stored
                if position < base:
                    continue
                footer = (position, stored, decoded, base)
                self.secured = secured
                break
            except self.c.IBKError as error:
                last_error = error
        if footer is None:
            raise self.c.IBKError('Не удалось прочитать таблицу содержимого IBK. Файл повреждён либо имеет другую версию.') from last_error
        self.directory_start, stored, decoded, self.base = footer
        inverse = self.c.format_data()[1][1] if self.secured else None
        table = self.c.read_block(raw[self.directory_start:self.directory_start + stored], inverse)
        if decoded:
            table = expand(table, decoded)
            if len(table) != decoded:
                raise self.c.IBKError('Не совпал размер таблицы содержимого IBK.')
        self._directory(table)

    def _directory(self, table):
        if len(table) < 13:
            raise self.c.IBKError('Обрезана таблица содержимого IBK.')
        marker, free_count, count, flags = struct.unpack_from('<4sIIB', table)
        if marker != b'ICE1' or free_count > MAX_PARTS or not 0 < count <= MAX_FILES or flags not in (0, 1):
            raise self.c.IBKError('Не поддерживается структура таблицы IBK.')
        position = 13 + free_count * 16
        total_parts = 0

        def take(size):
            nonlocal position
            if size < 0 or position + size > len(table):
                raise self.c.IBKError('Обрезана запись таблицы IBK.')
            result = table[position:position + size]
            position += size
            return result

        take(0)
        for _ in range(count):
            size, clusters, name_size, extra, path_size, options = struct.unpack('<QIHHHB', take(19))
            if size > MAX_FILE or clusters > MAX_PARTS or name_size > 2048 or path_size > 2048:
                raise self.c.IBKError('Запись IBK превышает предел чтения.')
            try:
                name = take(name_size * 2).decode('utf-16-le')
                folder = take(path_size * 2).decode('utf-16-le')
            except UnicodeError as error:
                raise self.c.IBKError('Повреждено имя записи IBK.') from error
            parts = []
            for _ in range(clusters):
                descriptor = take(1)[0]
                fragments = descriptor & 127
                total_parts += fragments
                if not fragments or total_parts > MAX_PARTS:
                    raise self.c.IBKError('Некорректное число фрагментов IBK.')
                ranges = []
                stored_total = 0
                for _ in range(fragments):
                    offset, stored = struct.unpack('<QQ', take(16))
                    stored_total += stored
                    if offset < self.base or stored == 0 or offset + stored > self.directory_start or stored_total > MAX_FILE:
                        raise self.c.IBKError('Фрагмент IBK выходит за границы данных книги.')
                    ranges.append((offset, stored))
                parts.append((bool(descriptor & 128), ranges))
            if not folder:
                if name in self.files:
                    raise self.c.IBKError('Повторяется внутренняя запись IBK.')
                self.files[name] = (size, options, parts)
        if position != len(table):
            raise self.c.IBKError('В таблице IBK остались неизвестные данные.')
        if 'Text' not in self.files:
            raise self.c.IBKError('В контейнере ICE Book Reader нет текста книги.')

    def read_file(self, name, inverse=None):
        if name not in self.files:
            raise self.c.IBKError('В IBK отсутствует необходимая запись: ' + name + '.')
        size, options, clusters = self.files[name]
        if options & 128 and inverse is None:
            raise self.c.IBKError('Для защищённой записи IBK не выбран профиль чтения.')
        output = bytearray()
        for compressed, ranges in clusters:
            raw = b''.join(self.raw[offset:offset + stored] for offset, stored in ranges)
            data = self.c.read_block(raw, inverse if options & 128 else None)
            if compressed:
                data = expand(data, size - len(output))
            if len(output) + len(data) > size:
                raise self.c.IBKError('Распакованная запись IBK больше заявленного размера.')
            output.extend(data)
        if len(output) != size:
            raise self.c.IBKError('Не совпал размер распакованной записи IBK.')
        return bytes(output)

    def text_and_metadata(self, tools_root):
        common = self.c.format_data()[1][1]
        text_inverse = None
        if self.files['Text'][1] & 128:
            info = self.read_file('Info', common)
            text_inverse = self.c.text_context(info, tools_root)
        text = self.read_file('Text', text_inverse)
        metadata = {}
        if 'PubInfo' in self.files:
            _, fields = self.c.record_tree(self.read_file('PubInfo', common))
            for name, identity in (('author', 33), ('title', 34), ('genre', 35), ('series', 39)):
                if identity in fields:
                    try:
                        value = fields[identity][0].decode('utf-16-le').strip()
                    except UnicodeError as error:
                        raise self.c.IBKError('Повреждены текстовые сведения IBK.') from error
                    if any(ord(char) < 32 and char not in '\t\n\r' for char in value):
                        raise self.c.IBKError('Некорректные символы в сведениях IBK.')
                    if name == 'author' and value.startswith('&'):
                        value = '; '.join(part for part in value.split('&') if part)
                    metadata[name] = value
        return text, metadata


def paragraphs(raw):
    """Literal UTF-16 word atoms, paragraph breaks and known layout controls.

    Unknown control records fail explicitly instead of skipping possible text.
    Formatting state changes do not split a word (notably decorative initials).
    """
    c = crypto()
    output = []
    current = []
    position = 0
    while position < len(raw):
        code = raw[position]
        position += 1
        if 0 < code < 128:
            end = position + code * 2
            if end > len(raw):
                raise c.IBKError('Обрезано слово в тексте IBK.')
            try:
                word = raw[position:end].decode('utf-16-le')
            except UnicodeError as error:
                raise c.IBKError('Повреждён текст UTF-16 в IBK.') from error
            if any(ord(char) < 32 and char not in '\t\n\r' or ord(char) in (65534, 65535) for char in word):
                raise c.IBKError('Недопустимые управляющие символы в тексте IBK.')
            current.append(word)
            position = end
        elif code == 0:
            output.append(''.join(current))
            current = []
        elif code in (240, 246):
            current.append(' ')
        elif code in (128, 130, 131, 136):
            pass
        else:
            raise c.IBKError('В этой разновидности IBK найден неизвестный элемент текста. Исходная книга сохранена.')
    output.append(''.join(current))
    if not any(line.strip() for line in output):
        raise c.IBKError('В IBK не найден читаемый текст.')
    return output


def read(book):
    c = crypto()
    try:
        container = Container(book.source.read_bytes())
        text, metadata = container.text_and_metadata(book.tools_root)
        lines = paragraphs(text)
        if metadata.get('title') and book.title == book.source.stem:
            book.title = metadata['title']
        if not book.author:
            book.author = metadata.get('author', '')
        for line in lines:
            paragraph = book.el('p', line.strip(' \t'))
            if not line.strip():
                paragraph.append(book.el('br'))
            book.body.append(paragraph)
        book.warnings.add('Оформление IBK упрощено; текст и абзацы сохранены.')
    except c.RuntimeRequired as error:
        book.require('IBK', str(error))
    except (c.IBKError, OSError, UnicodeError, struct.error) as error:
        book.fail(str(error))

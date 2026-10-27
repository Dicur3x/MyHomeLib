"""Read-only Apple Pages IWA text input (MIT), without an Apple runtime.

Snappy follows google/snappy/format_description.txt. IWA object framing and
TP.DocumentArchive/TSWP.StorageArchive field numbers are documented by
obriensp/iWorkFileFormat and den-frie-vilje/cupertino-files. No vendor code,
macros or document instructions are executed.
"""
import io
import struct
import zipfile

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_OBJECTS = 200000


class PagesError(ValueError):
    pass


def varint(data, at):
    value = 0
    for shift in range(0, 70, 7):
        if at >= len(data):
            raise PagesError('Оборвано число IWA.')
        byte = data[at]
        at += 1
        if shift == 63 and byte > 1:
            raise PagesError('Слишком большое число IWA.')
        value |= (byte & 127) << shift
        if byte < 128:
            return value, at
    raise PagesError('Слишком длинное число IWA.')


def snappy(data):
    size, at = varint(data, 0)
    if size > MAX_FILE:
        raise PagesError('Распакованный блок Pages превышает 64 МБ.')
    output = bytearray()
    while at < len(data):
        code = data[at]
        at += 1
        kind = code & 3
        if kind == 0:
            length = code >> 2
            if length >= 60:
                width = length - 59
                if at + width > len(data):
                    raise PagesError('Оборвана длина блока Snappy.')
                length = int.from_bytes(data[at:at + width], 'little')
                at += width
            length += 1
            if at + length > len(data) or length > size - len(output):
                raise PagesError('Некорректный текстовый блок Snappy.')
            output.extend(data[at:at + length])
            at += length
        else:
            width = (1, 2, 4)[kind - 1]
            if at + width > len(data):
                raise PagesError('Оборвана ссылка Snappy.')
            distance = int.from_bytes(data[at:at + width], 'little')
            at += width
            if kind == 1:
                distance |= (code & 224) << 3
                length = 4 + ((code >> 2) & 7)
            else:
                length = 1 + (code >> 2)
            if not 0 < distance <= len(output) or length > size - len(output):
                raise PagesError('Некорректная ссылка Snappy.')
            start = len(output) - distance
            pattern = output[start:start + min(length, distance)]
            output.extend((pattern * ((length + len(pattern) - 1) // len(pattern)))[:length])
    if len(output) != size:
        raise PagesError('Не совпадает распакованная длина Snappy.')
    return bytes(output)


def fields(data):
    at, result, count = 0, {}, 0
    while at < len(data):
        count += 1
        if count > MAX_OBJECTS:
            raise PagesError('Слишком сложная структура IWA.')
        key, at = varint(data, at)
        number, kind = key >> 3, key & 7
        if not 0 < number < 1 << 29:
            raise PagesError('Некорректный номер поля IWA.')
        if kind == 0:
            value, at = varint(data, at)
        elif kind in (1, 2, 5):
            if kind == 2:
                size, at = varint(data, at)
            else:
                size = 8 if kind == 1 else 4
            if size > len(data) - at:
                raise PagesError('Оборвано поле IWA.')
            value = data[at:at + size]
            at += size
        else:
            raise PagesError('Неизвестный тип поля IWA.')
        result.setdefault(number, []).append(value)
    return result


def single(message, number, expected, default=None):
    values = message.get(number, [])
    if not values:
        return default
    if len(values) != 1 or not isinstance(values[0], expected):
        raise PagesError('Неоднозначное поле IWA.')
    return values[0]


def objects(data):
    chunks, at, total = [], 0, 0
    while at < len(data):
        if at + 4 > len(data) or data[at] != 0:
            raise PagesError('Неизвестный заголовок сжатия IWA.')
        size = int.from_bytes(data[at + 1:at + 4], 'little')
        at += 4
        if size > len(data) - at:
            raise PagesError('Оборван сжатый блок IWA.')
        chunk = snappy(data[at:at + size])
        total += len(chunk)
        if total > MAX_FILE:
            raise PagesError('Компонент Pages превышает 64 МБ.')
        chunks.append(chunk)
        at += size
    raw, at, count = b''.join(chunks), 0, 0
    while at < len(raw):
        size, at = varint(raw, at)
        if size > len(raw) - at:
            raise PagesError('Оборван заголовок объекта IWA.')
        info = fields(raw[at:at + size])
        at += size
        ident = single(info, 1, int)
        if ident is None or not info.get(2):
            raise PagesError('В IWA отсутствует номер или описание объекта.')
        for item in info[2]:
            if not isinstance(item, bytes):
                raise PagesError('Некорректное описание объекта IWA.')
            entry = fields(item)
            kind, length = single(entry, 1, int), single(entry, 3, int)
            if kind is None or length is None or length > len(raw) - at:
                raise PagesError('Оборвано содержимое объекта IWA.')
            count += 1
            if count > MAX_OBJECTS:
                raise PagesError('В Pages слишком много объектов.')
            yield ident, kind, fields(raw[at:at + length]), length
            at += length


def reference(message, number):
    value = single(message, number, bytes)
    if value is None:
        raise PagesError('В Pages отсутствует ссылка на основной текст.')
    result = single(fields(value), 1, int)
    if result is None:
        raise PagesError('Повреждена ссылка Pages.')
    return result


def text_archive(archive, book, depth=0):
    if depth > 1:
        raise PagesError('Слишком много вложенных каталогов Index в Pages.')
    entries = archive.infolist()
    names = {entry.filename for entry in entries}
    if len(names) != len(entries) or len(entries) > 20000 or any(
            entry.file_size > MAX_FILE or '\\' in entry.filename or
            entry.filename.startswith('/') or '..' in entry.filename.split('/') for entry in entries):
        raise PagesError('Некорректный или слишком большой пакет Pages.')
    if sum(entry.file_size for entry in entries) > MAX_TOTAL:
        raise PagesError('Пакет Pages превышает 256 МБ.')
    if 'Index.zip' in names:
        if depth >= 1:
            raise PagesError('Слишком много вложенных каталогов Index в Pages.')
        if any(name.startswith('Index/') for name in names):
            raise PagesError('Неоднозначное содержимое Pages: два каталога Index.')
        with zipfile.ZipFile(io.BytesIO(archive.read('Index.zip'))) as nested:
            return text_archive(nested, book, depth + 1)
    if 'Index/Document.iwa' not in names:
        raise PagesError('В файле Pages нет основного документа IWA.')
    objects_by_id, total = {}, 0
    iwa = [entry for entry in entries if entry.filename.startswith('Index/') and entry.filename.endswith('.iwa')]
    for number, entry in enumerate(iwa, 1):
        book.progress('reading', number, len(iwa))
        for ident, kind, value, size in objects(archive.read(entry)):
            total += size
            if total > MAX_TOTAL or len(objects_by_id) >= MAX_OBJECTS:
                raise PagesError('Распакованный проект Pages слишком велик.')
            if ident in objects_by_id:
                raise PagesError('Эта версия Pages хранит составные объекты; точный перенос пока не поддерживается.')
            objects_by_id[ident] = kind, value
    root = objects_by_id.get(1)
    if not root or root[0] != 10000:
        raise PagesError('Это документ iWork, но не текстовый документ Pages.')
    body_id = reference(root[1], 4)
    body = objects_by_id.get(body_id)
    if not body or body[0] != 2001 or single(body[1], 1, int) != 0:
        raise PagesError('В Pages не найден основной текст книги.')
    for ident, (kind, value) in objects_by_id.items():
        if kind == 2001 and ident != body_id and any(value.get(3, [])):
            raise PagesError('Pages содержит отдельные текстовые блоки или сноски. Их точный порядок пока не поддерживается; неполная книга не сохранена.')
        if kind in (2008, 2011, 3002, 3005, 3008, 6000, 6001):
            raise PagesError('Pages содержит встроенные объекты, таблицы или иллюстрации. Их перенос пока не поддерживается; неполная книга не сохранена.')
    parts = body[1].get(3, [])
    if not parts or not all(isinstance(part, bytes) for part in parts):
        raise PagesError('В Pages отсутствует сохранённый текст.')
    text = b''.join(parts).decode('utf-8', errors='strict')
    if '\ufffc' in text or any(ord(char) < 32 and char not in '\t\r\n' for char in text):
        raise PagesError('Pages содержит вложения или специальные поля, которые нельзя пропустить при переносе.')
    return text


def read(book):
    try:
        with zipfile.ZipFile(book.source) as archive:
            text = text_archive(archive, book)
        for line in text.replace('\r\n', '\n').replace('\r', '\n').split('\n'):
            paragraph = book.el('p', line)
            if not line:
                paragraph.append(book.el('br'))
            book.body.append(paragraph)
        book.warnings.add('Pages: сохранён весь основной текст и границы абзацев. Шрифты, стили и страничное оформление адаптированы для чтения. Картинка предпросмотра не используется вместо книги.')
    except (PagesError, zipfile.BadZipFile, UnicodeError, TypeError, struct.error) as error:
        book.fail('Не удалось прочитать Pages: ' + str(error))

"""Read saved Jutoh 2 rich-text sections; MIT, no Jutoh runtime or scripts.

The SQLite project, pixie index and typed wx rich-text streams are inspected
read-only. Only the Content tree is a book; Scraps and autosaves are not.
"""
from contextlib import contextmanager
import sqlite3
import struct
from urllib.parse import urlsplit
import zlib

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_ITEMS = 20000
TABLES = {'ProjectObjects', 'ProjectIndex', 'ProjectVariables'}


class JutohError(ValueError):
    pass


@contextmanager
def database(source):
    if source.stat().st_size > MAX_FILE:
        raise JutohError('Проект Jutoh превышает 64 МБ.')
    connection = sqlite3.connect(source.resolve().as_uri() + '?mode=ro&immutable=1', uri=True)
    try:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('PRAGMA trusted_schema=OFF')
        connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_FILE)
        connection.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, 16384)
        budget = [0]
        def progress():
            budget[0] += 1
            return budget[0] > 10000
        connection.set_progress_handler(progress, 1000)
        rows = connection.execute("SELECT name,type,sql FROM sqlite_master WHERE name IN "
                                  "('ProjectObjects','ProjectIndex','ProjectVariables')").fetchall()
        if {row[0] for row in rows} != TABLES or any(
                kind != 'table' or not sql or 'VIRTUAL' in sql.upper() for _, kind, sql in rows):
            raise JutohError('В базе данных не найден сохранённый проект Jutoh.')
        yield connection
    finally:
        connection.close()


def matches(source):
    try:
        with database(source) as connection:
            rows = connection.execute("SELECT Data FROM ProjectIndex WHERE DataType='Index' LIMIT 2").fetchall()
            return len(rows) == 1 and isinstance(rows[0][0], bytes) and rows[0][0].startswith(b'\x0a\0\0\0pixie-utf8')
    except (sqlite3.Error, JutohError, OSError):
        return False


class Stream:
    def __init__(self, data):
        if not isinstance(data, bytes) or len(data) > MAX_FILE:
            raise JutohError('Некорректный или слишком большой раздел Jutoh.')
        self.data, self.at, self.nodes = data, 0, 0

    def take(self, size):
        if not isinstance(size, int) or size < 0 or size > len(self.data) - self.at:
            raise JutohError('Оборван двоичный раздел Jutoh.')
        result = self.data[self.at:self.at + size]
        self.at += size
        return result

    def u32(self):
        return struct.unpack('<I', self.take(4))[0]

    def string(self):
        return self.take(self.u32()).decode('utf-8', errors='strict')

    def field(self):
        kind, key = self.string(), self.string()
        if kind == 'string':
            value = self.string()
        elif kind == 'long':
            value = struct.unpack('<q', self.take(8))[0]
        elif kind == 'bool':
            raw = self.take(1)
            if raw not in (b'\0', b'\1'):
                raise JutohError('Некорректное логическое поле Jutoh.')
            value = raw == b'\1'
        elif kind == 'double':
            # wxDataStream extended floating point; these are layout/timing
            # properties, never book text or executable instructions.
            value = self.take(10)
        else:
            raise JutohError('Неизвестный тип свойства Jutoh: ' + kind[:60])
        return key, value

    def properties(self):
        result = {}
        for _ in range(MAX_ITEMS):
            key, value = self.field()
            if key == '*END*' and value == '*END*':
                return result
            if key in result:
                raise JutohError('Повторное свойство раздела Jutoh.')
            if key == 'image-data':
                if value != '' or 'image-data-size' not in result:
                    raise JutohError('Неизвестное хранение изображения Jutoh.')
                value = self.take(result['image-data-size'])
            result[key] = value
        raise JutohError('Слишком много свойств раздела Jutoh.')

    def node(self, depth=0):
        self.nodes += 1
        if depth > 64 or self.nodes > 200000:
            raise JutohError('Слишком сложная структура текста Jutoh.')
        header, attributes, content = self.properties(), self.properties(), self.properties()
        count = header.get('richtext-child-count', 0)
        if not isinstance(count, int) or not 0 <= count <= 200000 - self.nodes:
            raise JutohError('Некорректное число элементов текста Jutoh.')
        children = [self.node(depth + 1) for _ in range(count)]
        return header, attributes, content, children

    def index_group(self):
        result = {}
        for _ in range(MAX_ITEMS):
            key, kind = self.string(), self.u32()
            if kind == 1:
                value = self.u32()
            elif kind == 3:
                value = self.string()
            else:
                raise JutohError('Неизвестная версия оглавления Jutoh.')
            if key == 'END' and value == 'END':
                return result
            if key in result:
                raise JutohError('Повторное поле оглавления Jutoh.')
            result[key] = value
        raise JutohError('Слишком большое оглавление Jutoh.')


def index(data):
    stream = Stream(data)
    if stream.string() != 'pixie-utf8':
        raise JutohError('Неподдерживаемое оглавление проекта Jutoh.')
    metadata = stream.index_group()
    count = metadata.get('doc_count', 0)
    if not isinstance(count, int) or not 0 < count <= MAX_ITEMS:
        raise JutohError('Некорректное число разделов Jutoh.')
    documents = [stream.index_group() for _ in range(count)]
    by_id = {}
    for document in documents:
        ident = document.get('id')
        if not isinstance(ident, int) or ident <= 0 or ident in by_id:
            raise JutohError('Некорректный номер раздела Jutoh.')
        by_id[ident] = document
    for document in documents:
        parent, visited = document.get('parent', 0), {document['id']}
        while parent:
            if parent in visited or parent not in by_id or len(visited) > 64:
                raise JutohError('Повреждена иерархия разделов Jutoh.')
            visited.add(parent)
            parent = by_id[parent].get('parent', 0)
    root, scraps = metadata.get('section_root_document'), metadata.get('scrap_root_document')
    if root not in by_id or root == scraps:
        raise JutohError('Не найдена основная часть книги Jutoh.')
    children = {}
    for document in documents:
        children.setdefault(document.get('parent', 0), []).append(document)
    result = []
    def visit(ident):
        if ident == scraps:
            raise JutohError('Черновики Jutoh ошибочно включены в основную книгу.')
        for document in children.get(ident, []):
            kind = document.get('type')
            if kind == 'text-section-document':
                result.append(document)
            elif kind not in ('thumbnail-folder-document', 'folder-document'):
                raise JutohError('В основной части Jutoh найден неподдерживаемый раздел: ' + str(kind)[:80])
            visit(document['id'])
    visit(root)
    if not result:
        raise JutohError('В основной части проекта Jutoh нет текстовых разделов.')
    return metadata, by_id, result


def section(data):
    stream = Stream(data)
    if stream.string() != 'ADVANCED_COMPRESSED':
        raise JutohError('Неизвестное сжатие раздела Jutoh.')
    decoder = zlib.decompressobj()
    try:
        raw = decoder.decompress(stream.data[stream.at:], MAX_FILE + 1)
    except zlib.error as error:
        raise JutohError('Повреждено сжатие раздела Jutoh.') from error
    if len(raw) > MAX_FILE or not decoder.eof or decoder.unused_data:
        raise JutohError('Повреждённый или слишком большой раздел Jutoh.')
    stream = Stream(raw)
    for _ in range(MAX_ITEMS):
        key, value = stream.field()
        if key == 'properties-content-binary':
            if value != '':
                raise JutohError('Неизвестное хранение текста Jutoh.')
            content = Stream(stream.take(stream.u32()))
            node = content.node()
            if content.at != len(content.data):
                raise JutohError('В разделе Jutoh остались нераспознанные данные книги.')
            return node, len(raw)
        if key == '*END*':
            break
    raise JutohError('В разделе Jutoh не найден сохранённый текст.')


def render(book, node, inherited=None):
    header, attributes, content, children = node
    kind = header.get('richtext-object-class')
    attrs = dict(inherited or {})
    attrs.update(attributes)
    if kind in ('paragraphlayout', 'paragraph'):
        element = book.el('div' if kind == 'paragraphlayout' else 'p')
        alignment = {1: 'left', 2: 'center', 3: 'right', 4: 'justify'}.get(attrs.get('attr-alignment'))
        if alignment:
            element.set('style', 'text-align:' + alignment)
        for child in children:
            element.append(render(book, child, attrs))
        if kind == 'paragraph' and not children:
            element.append(book.el('br'))
        return element
    if children:
        raise JutohError('Неизвестная вложенность элементов Jutoh.')
    if kind == 'image':
        if not isinstance(content.get('image-data'), bytes):
            raise JutohError('В разделе Jutoh отсутствует изображение.')
        return book.image(content['image-data'])
    if kind != 'text' or not isinstance(content.get('text'), str):
        raise JutohError('Неподдерживаемый элемент книги Jutoh: ' + str(kind)[:80])
    element = book.el('span')
    current = element
    weight = attrs.get('attr-font-weight', 0)
    wrappers = []
    if isinstance(weight, int) and (weight >= 700 or weight == 92):
        wrappers.append('strong')
    if attrs.get('attr-font-style') in (93, 94):
        wrappers.append('em')
    for name in wrappers:
        child = book.el(name)
        current.append(child)
        current = child
    # wxRichTextLineBreakChar is U+001D (wxWidgets richtextbuffer.cpp), a
    # deliberate soft line break, not a literal XML control character.
    text = content['text'].replace('\r\n', '\n').replace('\r', '\n').replace('\x1d', '\n')
    lines = text.split('\n')
    current.text = lines[0]
    for line in lines[1:]:
        child = book.el('br')
        child.tail = line
        current.append(child)
    url = attrs.get('attr-url', '')
    if url:
        parts = urlsplit(url)
        if parts.scheme.lower() in ('http', 'https', 'mailto'):
            link = book.el('a', href=url)
            link.append(element)
            return link
        book.warnings.add('Некоторые внутренние или служебные ссылки Jutoh сохранены обычным текстом.')
    return element


def read(book):
    try:
        with database(book.source) as connection:
            rows = connection.execute("SELECT Data FROM ProjectIndex WHERE DataType='Index' LIMIT 2").fetchall()
            if len(rows) != 1:
                raise JutohError('В проекте Jutoh нет единственного сохранённого оглавления.')
            metadata, documents, ordered = index(rows[0][0])
            if book.title == book.source.stem:
                book.title = metadata.get('title') or next((d.get('title', '') for d in documents.values()
                                                           if d.get('type') == 'root-document'), '') or book.title
            if not book.author:
                book.author = metadata.get('author', '')
            total = 0
            for number, document in enumerate(ordered, 1):
                book.progress('reading', number, len(ordered))
                rows = connection.execute('SELECT ParentId,Data FROM ProjectObjects WHERE Id=? LIMIT 2',
                                          (str(document['id']),)).fetchall()
                if len(rows) != 1 or str(rows[0][0]) != str(document['parent']):
                    raise JutohError('В проекте Jutoh отсутствует раздел из оглавления.')
                node, size = section(rows[0][1])
                total += size
                if total > MAX_TOTAL:
                    raise JutohError('Распакованная книга Jutoh превышает 256 МБ.')
                element = book.el('section', id='jutoh-' + str(document['id']))
                element.append(book.el('h2', document.get('title') or str(number)))
                element.append(render(book, node))
                book.body.append(element)
        book.warnings.add('Jutoh: перенесены сохранённые разделы основной книги в порядке оглавления, текст и встроенные изображения. Черновики, автосохранение, сценарии и издательское оформление проекта не переносятся; шрифты и вёрстка адаптированы для чтения.')
    except (JutohError, sqlite3.Error, UnicodeError, TypeError, struct.error) as error:
        book.fail('Не удалось прочитать проект Jutoh: ' + str(error))

"""Export prepared EPUB chapters to one self-contained Markdown file."""

from base64 import b64encode
from contextlib import closing
from copy import copy
from pathlib import Path
import re
import sys
from textwrap import indent
from urllib.parse import quote, urlsplit


EMPHASIS = {'b': 'strong', 'strong': 'strong', 'i': 'emphasis', 'em': 'emphasis',
            'del': 'strikethrough', 's': 'strikethrough', 'strike': 'strikethrough'}
BLOCKS = {'paragraph', 'heading', 'thematic_break', 'block_html', 'block_code', 'block_quote', 'list', 'table'}
CONTAINERS = {'body', 'div', 'article', 'section', 'aside', 'header', 'footer', 'main', 'nav',
              'figure', 'figcaption', 'details', 'summary', 'dl', 'dt', 'dd'}
OMIT = {'script', 'style', 'iframe', 'object', 'embed', 'video', 'audio'}
RASTER = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp', 'image/tiff'}
SVG = 'http://www.w3.org/2000/svg'
SVG_ELEMENTS = set(('svg g defs symbol use path rect circle ellipse line polyline polygon text tspan '
                    'title desc linearGradient radialGradient stop clipPath mask pattern marker').split())
SVG_ATTRIBUTES = set(('id version x y x1 x2 y1 y2 cx cy r rx ry fx fy width height viewBox '
                      'preserveAspectRatio d points transform fill fill-rule fill-opacity stroke '
                      'stroke-width stroke-linecap stroke-linejoin stroke-dasharray stroke-opacity '
                      'opacity color offset stop-color stop-opacity gradientUnits gradientTransform '
                      'spreadMethod clip-path clip-rule mask patternUnits patternContentUnits '
                      'patternTransform marker-start marker-mid marker-end markerUnits markerWidth '
                      'markerHeight refX refY orient text-anchor font-size font-family dx dy href').split())
SVG_PAINT = {'fill', 'stroke', 'clip-path', 'mask', 'marker-start', 'marker-mid', 'marker-end'}


def static_svg(api, root):
    if root.tag != '{' + SVG + '}svg':
        return None
    for node in root.iter():
        if not node.tag.startswith('{' + SVG + '}') or api.tag(node) not in SVG_ELEMENTS:
            return None
        for name, value in node.attrib.items():
            if name == '{' + api.XL + '}href':
                name = 'href'
            if name not in SVG_ATTRIBUTES:
                return None
            if name == 'href' and not re.fullmatch(r'#[\w:.-]+', value):
                return None
            if name in SVG_PAINT and not re.fullmatch(r'[\w #.,%()+-]+', value):
                return None
            if name in SVG_PAINT and 'url' in value.lower() and not re.fullmatch(r'url\(#[\w:.-]+\)', value):
                return None
    image = copy(root)
    image.tail = None
    return api.serialized(image)


def token(kind, children=None, raw=None, **attrs):
    result = {'type': kind}
    if children is not None:
        result['children'] = children
    if raw is not None:
        result['raw'] = raw
    if attrs:
        result['attrs'] = attrs
    return result


def literal(text):
    collapsed = re.sub(r'\s+', ' ', text or '')
    # Escape HTML/entity starts and Markdown delimiters in publisher prose.
    return token('text', raw=re.sub(r'([\\\x60*_{}\[\]<>~&!])', r'\\\1', collapsed))


def paragraph_tokens(tokens):
    pending = []
    for item in tokens:
        if item['type'] in BLOCKS:
            if pending:
                yield token('paragraph', pending)
                pending = []
            yield item
        elif pending or item['type'] != 'text' or item['raw'].strip():
            pending.append(item)
    if pending:
        yield token('paragraph', pending)


def renderer():
    vendor = str(Path(__file__).with_name('vendor'))
    sys.path.insert(0, vendor)
    try:
        from mistune.core import BlockState
        from mistune.renderers.markdown import MarkdownRenderer
    finally:
        sys.path.remove(vendor)

    class BookRenderer(MarkdownRenderer):
        def text(self, token, state):
            return token['raw']  # literal() has already escaped XHTML text.

        def strikethrough(self, token, state):
            return '~~' + self.render_children(token, state) + '~~'

        def paragraph(self, token, state):
            text = super().paragraph(token, state)
            if re.fullmatch(r' *-(?: *-){2,} *\n\n', text):
                first_dash = text.index('-')
                return text[:first_dash] + '\\' + text[first_dash:]
            return text

    return BookRenderer(), BlockState()


class Book:
    def __init__(self, api, archive, docs, media, warnings, check):
        self.api, self.archive, self.media, self.warnings = api, archive, media, warnings
        self.check = check
        self.targets, self.anchors, self.notes, self.images = {}, {}, {}, {}
        self.image_bytes = 0
        for chapter, (path, body) in enumerate(docs, 1):
            if self.check is not None:
                self.check()
            prefix = 'hl-chapter-' + str(chapter)
            self.targets[path, ''] = (prefix, body)
            for index, node in enumerate(body.iter(), 1):
                if node.get('id'):
                    self.targets[path, node.get('id')] = (prefix + '-' + str(index), node)
        for path, body in docs:
            for node in body.iter():
                if api.tag(node) == 'a' and ('noteref' in node.get('{' + api.EP + '}type', '').split() or
                                             node.get('role') == 'doc-noteref'):
                    location = archive.resolve(path, node.get('href', ''))
                    target = self.targets.get(location)
                    if target and target[1] is not body and api.tag(target[1]) != 'body':
                        self.notes.setdefault(target[1], (location[0], 'note-' + str(len(self.notes) + 1)))
        for path, body in docs:
            for node in body.iter():
                if api.tag(node) != 'a' or not node.get('href'):
                    continue
                target = self.targets.get(archive.resolve(path, node.get('href')))
                if target and target[1] not in self.notes:
                    self.anchors.setdefault(target[1], []).append(target[0])

    def content(self, path, node):
        yield literal(node.text)
        for child in node:
            yield from self.node(path, child)
            yield literal(child.tail)

    def anchor(self, node, block=False):
        return [token('block_html' if block else 'inline_html', raw=f'<a id="{name}"></a>')
                for name in dict.fromkeys(self.anchors.get(node, []))]

    def link(self, path, node, content):
        href = node.get('href', '')
        if not href:
            return content
        location = self.archive.resolve(path, href)
        if location[0] is None:
            if urlsplit(href).scheme.lower() in {'http', 'https', 'mailto'}:
                url = quote(href, safe=':/?&=#%+,;@!$-_.~')
                return [token('link', content, url=url)]
        elif location in self.targets:
            name, target = self.targets[location]
            if target in self.notes:
                return [token('inline_html', raw='[^' + self.notes[target][1] + ']')]
            return [token('link', content, url='#' + name)]
        self.warnings.add('Некоторые ссылки EPUB без доступной цели оставлены текстом.')
        return content

    def image(self, path, reference, alt):
        resolved, _ = self.archive.resolve(path, reference)
        mime = self.media.get(resolved)
        if resolved in self.images:
            return self.embedded_image(resolved, mime, None, alt)
        if (mime in RASTER or mime == 'image/svg+xml') and resolved in self.archive.names:
            data = self.archive.read(resolved)
            if mime == 'image/svg+xml':
                try:
                    data = static_svg(self.api, self.api.xml(data))
                except self.api.ConversionError:
                    data = None
            if data:
                return self.embedded_image(resolved, mime, data, alt)
        self.warnings.add('Внешние или неподдерживаемые изображения EPUB отмечены текстом в Markdown.')
        return [literal(alt or '[Изображение]')]

    def embedded_image(self, key, mime, data, alt):
        if key not in self.images:
            if self.check is not None:
                self.check()
            self.image_bytes += len(data)
            if self.image_bytes > self.api.MAX_TOTAL * 3 // 4:
                raise self.api.ConversionError('Встроенные изображения превышают предел размера Markdown.')
            label = 'hl-image-' + str(len(self.images) + 1)
            self.images[key] = (label, f'data:{mime};base64,' + b64encode(data).decode('ascii'))
        result = token('image', [literal(alt)])
        result['label'] = self.images[key][0]
        return [result]

    def table(self, path, node):
        rows = []
        # Rows of nested tables do not belong to the outer table.
        groups = [node] + [part for part in node if self.api.tag(part) in {'thead', 'tbody', 'tfoot'}]
        for group in groups:
            for row in self.api.children(group, 'tr'):
                cells = [cell for cell in row if self.api.tag(cell) in {'th', 'td'}]
                if any(cell.get('colspan') or cell.get('rowspan') for cell in cells):
                    self.warnings.add('Объединённые ячейки таблиц переданы отдельными ячейками Markdown.')
                if cells:
                    rows.append([token('table_cell', self.anchor(cell) + list(self.content(path, cell)))
                                 for cell in cells])
                    rows[-1][0]['children'][:0] = self.anchor(row)
        if not rows:
            return []
        width = max(map(len, rows))
        if width * len(rows) > self.api.MAX_ENTRIES:
            raise self.api.ConversionError('Таблица EPUB слишком велика для Markdown.')
        for cells in rows:
            cells.extend(token('table_cell', []) for _ in range(width - len(cells)))
        captions = [token('paragraph', list(self.content(path, part)))
                    for part in self.api.children(node, 'caption')]
        return captions + [token('table', [token('table_head', rows[0]),
                                           token('table_body', [token('table_row', cells) for cells in rows[1:]])])]

    def node(self, path, node):
        kind = self.api.tag(node)
        if node in self.notes:
            return
        if kind in OMIT:
            self.warnings.add('Скрипты, оформление CSS и мультимедиа EPUB в Markdown не выполняются.')
            return
        yield from self.anchor(node, kind in CONTAINERS or kind in {'p', 'pre', 'table', 'ul', 'ol', 'blockquote'}
                               or bool(re.fullmatch(r'h[1-6]', kind)))
        if kind in {'img', 'image'}:
            reference = node.get('src') or node.get('href') or node.get('{' + self.api.XL + '}href', '')
            yield from self.image(path, reference, node.get('alt', ''))
            return
        if kind == 'svg':
            data = static_svg(self.api, node)
            if data:
                alt = self.api.first(node, 'title')
                yield from self.embedded_image(node, 'image/svg+xml', data,
                                               self.api.plain(alt) if alt is not None else '')
                return
            self.warnings.add('Из SVG в Markdown перенесены доступные встроенные изображения и текст.')
        if kind == 'pre':
            yield token('block_code', raw=''.join(node.itertext()))
        elif kind == 'hr':
            yield token('thematic_break')
        elif kind == 'br':
            yield token('linebreak')
        elif kind == 'code':
            yield token('codespan', raw=' '.join(''.join(node.itertext()).split()))
        elif kind == 'table':
            yield from self.table(path, node)
        elif kind in {'ul', 'ol'}:
            items = [token('list_item', list(paragraph_tokens(self.anchor(item) + list(self.content(path, item)))))
                     for item in self.api.children(node, 'li')]
            value = node.get('start', '')
            start = int(value) if re.fullmatch(r'[1-9]\d{0,8}', value) else 1
            yield dict(token('list', items, ordered=kind == 'ol', start=start),
                       tight=False, bullet='.' if kind == 'ol' else '-')
        elif kind == 'blockquote':
            yield token('block_quote', list(paragraph_tokens(self.content(path, node))))
        else:
            content = list(self.content(path, node))
            if kind == 'a':
                yield from self.link(path, node, content)
            elif kind in EMPHASIS:
                yield token(EMPHASIS[kind], content)
            elif re.fullmatch(r'h[1-6]', kind):
                yield token('heading', content, level=int(kind[1]))
            elif kind == 'p':
                yield token('paragraph', content)
            elif kind in CONTAINERS:
                yield from paragraph_tokens(content)
            else:
                yield from content


def convert(api, source, output, warnings, check):
    with closing(api.EpubArchive(source)) as archive:
        if 'META-INF/encryption.xml' in archive.names:
            encryption = api.xml(archive.read('META-INF/encryption.xml'))
            if any(node.get('Algorithm') not in {'http://www.idpf.org/2008/embedding',
                                                  'http://ns.adobe.com/pdf/enc#RC'}
                   for node in encryption.iter() if api.tag(node) == 'EncryptionMethod'):
                raise api.ConversionError('Зашифрованная книга EPUB не поддерживается.')
        _, metadata, _, spine, items, paths, docs, _ = api.epub_reading_order(archive, warnings, check)
        media = {paths[identity]: item.get('media-type') for identity, item in items.items()}
        book = Book(api, archive, docs, media, warnings, check)
        emit, state = renderer()
        _, titles = api.epub_outline_headings(archive, items, paths, spine, dict(docs), warnings)
        title = next((api.plain(node) for node in metadata if api.tag(node) == 'title' and api.plain(node)), '')
        authors = ', '.join(api.plain(node) for node in metadata if api.tag(node) == 'creator' and api.plain(node))
        written = 0
        with output.open('x', encoding='utf-8', newline='\n') as stream:
            def write(text):
                nonlocal written
                written += len(text.encode('utf-8'))
                if written > api.MAX_TOTAL:
                    raise api.ConversionError('Результат Markdown превышает допустимый размер.')
                stream.write(text)

            if title:
                write(emit.render_token(token('heading', [literal(title)], level=1), state))
            if authors:
                write(emit.render_token(token('paragraph', [literal(authors)]), state))
            has_content = False
            for path, body in docs:
                if check is not None:
                    check()
                for anchor in book.anchor(body, True):
                    write(emit.render_token(anchor, state))
                if path in titles:
                    write(emit.render_token(token('heading', [literal(titles[path])], level=2), state))
                for part in paragraph_tokens(book.content(path, body)):
                    if check is not None:
                        check()
                    rendered = emit.render_token(part, state).rstrip()
                    if rendered:
                        has_content = has_content or part['type'] != 'block_html'
                        write(rendered + '\n\n')
            if not has_content:
                raise api.ConversionError('В книге нет содержимого для Markdown.')
            for note, (path, label) in book.notes.items():
                if check is not None:
                    check()
                text = emit.render_tokens(paragraph_tokens(book.content(path, note)), state).strip()
                first, _, rest = text.partition('\n')
                write('[^' + label + ']: ' + first + '\n' + indent(rest, '    ') + '\n\n')
            for label, url in book.images.values():
                write('[' + label + ']: <' + url + '>\n')
    warnings.add('Markdown передаёт структуру и текст книги. Страничная вёрстка, стили и шрифты EPUB не переносятся.')

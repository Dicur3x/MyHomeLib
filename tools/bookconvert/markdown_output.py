"""Export prepared EPUB chapters to one self-contained Markdown file."""

from base64 import b64encode
from contextlib import closing
from copy import copy
from html import escape
from pathlib import Path
import re
import sys
from textwrap import indent
from unicodedata import category
from urllib.parse import quote, urlsplit


EMPHASIS = {'b': 'strong', 'strong': 'strong', 'i': 'emphasis', 'em': 'emphasis',
            'del': 'strikethrough', 's': 'strikethrough', 'strike': 'strikethrough'}
BLOCKS = {'paragraph', 'heading', 'thematic_break', 'block_html', 'block_code', 'block_quote', 'list',
          'table', 'html_table'}
CONTAINERS = {'body', 'div', 'article', 'section', 'aside', 'header', 'footer', 'main', 'nav',
              'figure', 'figcaption', 'details', 'summary', 'dl', 'dt', 'dd'}
OMIT = {'script', 'style', 'iframe', 'object', 'embed'}
RASTER = {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp', 'image/tiff'}
TABLE_PARTS = {'thead', 'tbody', 'tfoot', 'tr', 'colgroup', 'col', 'caption', 'th', 'td'}
TABLE_CONTENT = {'caption', 'th', 'td'}
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
    return token('text', raw=re.sub(r'\s+', ' ', text or ''))


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


def renderers():
    vendor = str(Path(__file__).with_name('vendor'))
    sys.path.insert(0, vendor)
    try:
        from mistune.core import BlockState
        from mistune import create_markdown
        from mistune.renderers.html import HTMLRenderer
        from mistune.renderers.markdown import MarkdownRenderer
    finally:
        sys.path.remove(vendor)

    class BookRenderer(MarkdownRenderer):
        def __init__(self):
            super().__init__()
            self.image_labels = set()
            self.note_labels = set()

        def text(self, token, state):
            # Escape HTML/entity starts and Markdown delimiters in publisher prose.
            return re.sub(r'([\\\x60*_{}\[\]<>~&!])', r'\\\1', token['raw'])

        def image(self, token, state):
            self.image_labels.add(token['label'])
            return super().image(token, state)

        def html_table(self, token, state):
            return token['raw'] + '\n\n'

        def note_ref(self, token, state):
            label = token['attrs']['label']
            self.note_labels.add(label)
            return '[^' + label + ']'

        def decorated(self, token, state, marker, tag):
            text = self.render_children(token, state)
            if not text.strip():
                return text
            # Markdown delimiter rules depend on whitespace and punctuation
            # on both sides. Preserve the source span when those rules can
            # turn delimiters into visible text or leave the words unstyled.
            if any(edge.isspace() or category(edge)[0] in {'P', 'S'} for edge in (text[0], text[-1])):
                return '<' + tag + '>' + text + '</' + tag + '>'
            return marker + text + marker

        def strong(self, token, state):
            return self.decorated(token, state, '**', 'strong')

        def emphasis(self, token, state):
            return self.decorated(token, state, '*', 'em')

        def strikethrough(self, token, state):
            return self.decorated(token, state, '~~', 'del')

        def paragraph(self, token, state):
            text = super().paragraph(token, state)
            if re.fullmatch(r' *-(?: *-){2,} *\n\n', text):
                first_dash = text.index('-')
                return text[:first_dash] + '\\' + text[first_dash:]
            return text

    class TableRenderer(HTMLRenderer):
        GOOD_DATA_PROTOCOLS = tuple('data:' + mime + ';' for mime in sorted(RASTER | {'image/svg+xml'}))

        def __init__(self):
            super().__init__()
            self.note_links = set()

        # Only HTML generated by Book reaches these methods. XHTML from the
        # source is represented as escaped text and allowlisted markup tokens.
        def inline_html(self, text):
            return text

        block_html = inline_html
        html_table = inline_html

        def strikethrough(self, text):
            return '<del>' + text + '</del>'

        def block_code(self, code):
            return '<pre><code>' + escape(code).replace('\n', '&#10;') + '</code></pre>'

        def note_ref(self, text, label):
            self.note_links.add(label)
            return self.link(text, '#hl-' + label)

    html = TableRenderer()
    create_markdown(renderer=html, plugins=['table'])  # Register nested pipe-table rendering.
    return BookRenderer(), html, BlockState()


class Book:
    def __init__(self, api, archive, docs, media, warnings, check, html_renderer, state):
        self.api, self.archive, self.media, self.warnings = api, archive, media, warnings
        self.check = check
        self.html_renderer, self.state = html_renderer, state
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
                return [token('note_ref', content, label=self.notes[target][1])]
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
        label, url = self.images[key]
        result = token('image', [literal(alt)], url=url)
        result['label'] = label
        return [result]

    def html_table_part(self, path, node):
        kind = self.api.tag(node)
        attrs = []
        if kind != 'table' and node in self.anchors:
            attrs.append(f' id="{self.anchors[node][0]}"')
        for name in ('rowspan', 'colspan', 'span'):
            value = node.get(name, '')
            if re.fullmatch(r'[0-9]{1,4}', value):
                attrs.append(f' {name}="{value}"')
        if node.get('scope') in {'row', 'col', 'rowgroup', 'colgroup'}:
            attrs.append(f' scope="{node.get("scope")}"')
        align = node.get('align', '')
        if align in {'left', 'center', 'right', 'justify'}:
            attrs.append(f' style="text-align:{align}"')
        opening = '<' + kind + ''.join(attrs)
        if kind == 'col':
            return opening + ' />'
        if kind in TABLE_CONTENT:
            content = self.html_renderer.render_tokens(self.content(path, node), self.state)
        else:
            content = ''.join(self.html_table_part(path, part) for part in node if self.api.tag(part) in TABLE_PARTS)
        return opening + '>' + content + '</' + kind + '>'

    def table(self, path, node):
        rows = []
        groups = []
        for part in node:
            kind = self.api.tag(part)
            groups.append(kind)
            if kind == 'tr':
                rows.append(part)
            elif kind in {'thead', 'tbody', 'tfoot'}:
                rows.extend(self.api.children(part, 'tr'))
        cells = [[cell for cell in row if self.api.tag(cell) in {'th', 'td'}] for row in rows]
        count = sum(map(len, cells))
        if not count:
            return []
        if count > self.api.MAX_ENTRIES:
            raise self.api.ConversionError('Таблица EPUB слишком велика для Markdown.')
        simple = (len({len(row) for row in cells}) == 1 and
                  (all(kind == 'tr' for kind in groups) or groups in (['thead'], ['thead', 'tbody'])) and
                  all(self.api.tag(cell) == ('td' if i else 'th') and not cell.attrib.keys() & {
                      'rowspan', 'colspan', 'scope', 'align'} and
                      not any(self.api.tag(part) in CONTAINERS | {'p', 'br', 'pre', 'table', 'ul', 'ol', 'blockquote'}
                              for part in cell.iter()) for i, row in enumerate(cells) for cell in row))
        if simple:
            rendered = [[token('table_cell', self.anchor(cell) + list(self.content(path, cell))) for cell in row]
                        for row in cells]
            if all(part['type'] not in BLOCKS | {'linebreak'} for row in rendered for cell in row
                   for part in cell['children']):
                for row, converted in zip(rows, rendered):
                    converted[0]['children'][:0] = self.anchor(row)
                return [token('table', [token('table_head', rendered[0]),
                                        token('table_body', [token('table_row', row) for row in rendered[1:]])])]
        return [token('html_table', raw=self.html_table_part(path, node))]

    def node(self, path, node):
        kind = self.api.tag(node)
        if node in self.notes:
            return
        if kind in OMIT:
            self.warnings.add('Скрипты, оформление CSS и мультимедиа EPUB в Markdown не выполняются.')
            return
        yield from self.anchor(node, kind in CONTAINERS or kind in
                               {'p', 'pre', 'table', 'ul', 'ol', 'blockquote', 'video', 'audio'}
                               or bool(re.fullmatch(r'h[1-6]', kind)))
        if kind in {'video', 'audio'}:
            media, label = self.api.epub_media_label(node)
            self.warnings.add(f'{media} EPUB не перенесено: «{label}».')
            if poster := node.get('poster'):
                yield token('paragraph', self.image(path, poster, label))
            yield token('paragraph', [literal(f'[{media} «{label}» доступно в исходной книге.]')])
            yield from paragraph_tokens(self.content(path, node))
            for track in self.api.children(node, 'track'):
                for paragraph in self.api.epub_subtitle_paragraphs(self.archive, path, track, self.media, self.warnings):
                    yield from self.node(path, paragraph)
            return
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
            elif kind in {'sub', 'sup'}:
                yield token('inline_html', raw='<' + kind + '>')
                yield from content
                yield token('inline_html', raw='</' + kind + '>')
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
        _, metadata, _, spine, items, paths, docs, _, duplicate_anchors, _ = api.epub_reading_order(archive, warnings, check)
        media = {paths[identity]: item.get('media-type') for identity, item in items.items()}
        emit, html, state = renderers()
        book = Book(api, archive, docs, media, warnings, check, html, state)
        _, titles, _ = api.epub_outline_headings(archive, items, paths, spine, dict(docs), duplicate_anchors, warnings)
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
                if label in html.note_links:
                    anchor = f'<a id="hl-{label}"></a>'
                    if label not in emit.note_labels:
                        write(anchor + '\n\n' + text + '\n\n')
                        continue
                    first = anchor + first
                write('[^' + label + ']: ' + first + '\n' + indent(rest, '    ') + '\n\n')
            for label, url in book.images.values():
                if label in emit.image_labels:
                    write('[' + label + ']: <' + url + '>\n')
    warnings.add('Markdown передаёт структуру и текст книги. Страничная вёрстка, стили и шрифты EPUB не переносятся.')

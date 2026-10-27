"""Text document inputs for the local ebook converter (MIT).

Uses the standard library and bundled Mistune for Markdown. Produces a reading EPUB, not a facsimile
of an office page. Never runs macros, follows external resources or changes input.
"""
import base64
import codecs
import copy
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
import posixpath
import re
from urllib.parse import unquote, urlsplit, quote
import uuid
import xml.etree.ElementTree as ET
import zipfile

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
T = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
O = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
S = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0'
F = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0'
DRAW = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0'
XL = 'http://www.w3.org/1999/xlink'
SUPPORTED = {'.txt', '.html', '.htm', '.xhtml', '.rtf', '.docx', '.odt', '.fb3', '.md', '.markdown'}


def decode(data, encoding=None):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    if encoding:
        return data.decode(encoding, errors='strict')
    try:
        return data.decode('utf-8-sig')
    except UnicodeError:
        return data.decode('cp1251')


class Book:
    def __init__(self, api, source, warnings, title='', author='', language='', resource_root=None, tools_root=None, reading=False, progress=None, image_export=None, omit_images=False):
        self.c, self.source, self.warnings = api, source, warnings
        self.title, self.author, self.language = title or source.stem, author, language or 'und'
        self.body = self.el('body')
        self.resources, self.images = {}, {}
        self.resource_root = Path(resource_root).resolve() if resource_root else source.parent.resolve()
        self.tools_root = Path(tools_root).resolve() if tools_root else Path(__file__).resolve().parent.parent
        self.total = 0
        self.reading = reading
        self.omit_images = bool(omit_images) and not reading
        self.progress = progress or (lambda stage, completed, total: None)
        self.image_export = image_export if not reading else None
        self.scan_export = None

    def scan_page(self, data, number, total=0):
        if self.image_export:
            if self.scan_export is None:
                import importlib.util
                spec=importlib.util.spec_from_file_location('homelib_scan_export',Path(__file__).with_name('scan_export.py'))
                module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                self.scan_export=module.ScanExport(self,self.image_export)
            self.scan_export.add(data,number,total)
            return
        section=self.el('section',id='page-'+str(number));self.body.append(section)
        section.append(self.el('h2','Страница '+str(number)))
        paragraph=self.el('p');section.append(paragraph)
        picture=self.image(data);picture.set('alt','Страница '+str(number));paragraph.append(picture)

    def el(self, name, text=None, **attrs):
        return self.c.element(self.c.XH, name, text, **attrs)

    def fail(self, message):
        raise self.c.ConversionError(message)

    def require(self, component, message):
        raise self.c.ComponentRequired(component, message)

    def image(self, data, mime=''):
        if len(data) > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        import hashlib
        original_key = hashlib.sha256(data).hexdigest()
        if original_key in self.images:
            return self.el('img', src=self.images[original_key], alt='')
        signatures = [(b'\x89PNG\r\n\x1a\n', 'image/png', '.png'), (b'\xff\xd8\xff', 'image/jpeg', '.jpg'),
                      (b'GIF8', 'image/gif', '.gif')]
        match = next((s for s in signatures if data.startswith(s[0])), None)
        if match is None:
            import importlib.util
            if not hasattr(self, '_image_decoder'):
                spec = importlib.util.spec_from_file_location('homelib_office_images', Path(__file__).with_name('office_inputs.py'))
                self._image_decoder = importlib.util.module_from_spec(spec); spec.loader.exec_module(self._image_decoder)
            data = self._image_decoder.rasterize_image(self, data)
            match = signatures[0]
        if len(data) > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        key = hashlib.sha256(data).hexdigest()
        if key not in self.images:
            self.total += len(data)
            if self.total > self.c.MAX_TOTAL:
                self.fail('Иллюстрации книги превышают предел конвертации.')
            path = 'images/' + key[:32] + match[2]
            self.resources[path] = (data, match[1]); self.images[key] = path
        self.images[original_key] = self.images[key]
        return self.el('img', src=self.images[key], alt='')

    def local_image(self, href):
        if href.startswith('data:'):
            header, sep, payload = href.partition(',')
            if not sep or ';base64' not in header:
                self.fail('Изображение data: должно использовать base64.')
            try:
                return self.image(base64.b64decode(payload, validate=True))
            except ValueError as error:
                self.fail('Неверные данные изображения: ' + str(error))
        parts = urlsplit(href)
        if parts.scheme or parts.netloc:
            self.fail('Внешнее изображение не скачивается: ' + href[:200])
        relative = unquote(parts.path)
        if '\\' in relative or '\x00' in relative:
            self.fail('Некорректный путь изображения.')
        path = (self.resource_root / relative).resolve()
        if not path.is_relative_to(self.resource_root) or not path.is_file():
            self.fail('Не найдено локальное изображение: ' + href[:200])
        if path.stat().st_size > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        return self.image(path.read_bytes())

    def finish(self, output):
        if self.scan_export is not None: self.scan_export.finish()
        c = self.c
        if not c.plain(self.body) and not any(c.tag(n) == 'img' for n in self.body.iter()):
            self.fail('В документе нет текста или изображений для конвертации.')
        # Promote loose inline text to paragraphs, retaining its reading order.
        flow = self.el('div'); run = None
        if self.body.text and self.body.text.strip():
            run = self.el('p', self.body.text); flow.append(run)
        blocks = {'p', 'div', 'section', 'article', 'aside', 'blockquote', 'ul', 'ol', 'table', 'pre', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr'}
        for node in list(self.body):
            tail = node.tail; node.tail = None
            if c.tag(node) in blocks:
                flow.append(node); run = None
            else:
                if run is None: run = self.el('p'); flow.append(run)
                run.append(node)
            if tail and (tail.strip() or run is not None):
                if run is None: run = self.el('p'); flow.append(run)
                c.append_text(run, tail)
        self.body.text = None; self.body[:] = list(flow)
        # Resolve text properties from XML, where surrogate escapes are invalid.
        for n in self.body.iter():
            for prop in ('text', 'tail'):
                value = getattr(n, prop)
                if value is not None:
                    value = value.encode('utf-16-le', errors='surrogatepass').decode('utf-16-le')
                    if any(ord(ch) < 32 and ch not in '\t\r\n' for ch in value):
                        self.fail('Документ содержит недопустимые управляющие символы.')
                    setattr(n, prop, value)
        ids = set(); headings = []
        for node in self.body.iter():
            identity = node.get('id')
            if identity:
                if identity in ids: self.fail('В документе повторяется идентификатор: ' + identity)
                ids.add(identity)
        for node in self.body.iter():
            if re.fullmatch(r'h[1-6]', c.tag(node)) and c.plain(node):
                identity = node.get('id')
                if not identity:
                    identity = 'heading-' + str(len(headings) + 1)
                    while identity in ids: identity += '-h'
                    node.set('id', identity); ids.add(identity)
                headings.append((identity, c.plain(node), int(c.tag(node)[1])))
        for node in self.body.iter():
            if c.tag(node) == 'a' and node.get('href', '').startswith('#'):
                if unquote(node.get('href')[1:]) not in ids:
                    self.fail('Не найдена цель внутренней ссылки: ' + node.get('href'))
        html = self.el('html', lang=self.language)
        head = self.el('head'); head.append(self.el('title', self.title))
        head.append(self.el('link', rel='stylesheet', href='book.css', type='text/css'))
        html.extend([head, self.body])
        self.resources['book.xhtml'] = (c.serialized(html), 'application/xhtml+xml')
        css = 'body{line-height:1.35}p{margin:.45em 0}h1,h2,h3,h4,h5,h6{text-align:center}img{max-width:100%;height:auto}pre{white-space:pre-wrap}table{border-collapse:collapse}td,th{padding:.2em .4em}'
        self.resources['book.css'] = (css.encode(), 'text/css')
        nav = self.el('html', lang=self.language); nh = self.el('head'); nh.append(self.el('title', 'Содержание')); nav.append(nh)
        nb = self.el('body'); nav.append(nb); nt = self.el('nav', **{'{' + c.EP + '}type': 'toc'}); nb.append(nt)
        nt.append(self.el('h1', 'Содержание')); ol = self.el('ol'); nt.append(ol); stack = [(1, ol)]
        for identity, label, depth in headings or [('', self.title, 1)]:
            while len(stack) > 1 and stack[-1][0] > depth: stack.pop()
            if depth > stack[-1][0] and len(stack[-1][1]):
                child = self.el('ol'); stack[-1][1][-1].append(child); stack.append((depth, child))
            elif depth < stack[-1][0] or not len(stack[-1][1]): stack[-1] = (depth, stack[-1][1])
            li = self.el('li'); li.append(self.el('a', label, href='book.xhtml' + ('#' + identity if identity else ''))); stack[-1][1].append(li)
        self.resources['nav.xhtml'] = (c.serialized(nav), 'application/xhtml+xml')
        package = c.element(c.OP, 'package', version='3.0', **{'unique-identifier': 'book-id'})
        meta = c.element(c.OP, 'metadata'); package.append(meta)
        for name, value in [('identifier', 'urn:uuid:' + str(uuid.uuid4())), ('title', self.title), ('language', self.language), ('creator', self.author)]:
            if value: meta.append(c.element(c.DC, name, value, **({'id': 'book-id'} if name == 'identifier' else {})))
        meta.append(c.element(c.OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), property='dcterms:modified'))
        manifest = c.element(c.OP, 'manifest'); package.append(manifest)
        for index, (name, (_, mime)) in enumerate(self.resources.items()):
            attrs = {'id': 'r' + str(index), 'href': name, 'media-type': mime}
            if name == 'nav.xhtml': attrs['properties'] = 'nav'
            manifest.append(c.element(c.OP, 'item', **attrs))
        spine = c.element(c.OP, 'spine'); package.append(spine)
        spine.append(c.element(c.OP, 'itemref', idref=next(n.get('id') for n in manifest if n.get('href') == 'book.xhtml')))
        container = c.element(c.CN, 'container', version='1.0'); roots = c.element(c.CN, 'rootfiles'); container.append(roots)
        roots.append(c.element(c.CN, 'rootfile', **{'full-path': 'OEBPS/package.opf', 'media-type': 'application/oebps-package+xml'}))
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            archive.writestr('META-INF/container.xml', c.serialized(container)); archive.writestr('OEBPS/package.opf', c.serialized(package))
            for name, (data, _) in self.resources.items(): archive.writestr('OEBPS/' + name, data)


class HTMLInput(HTMLParser):
    VOID = {'br', 'hr', 'img', 'meta', 'link', 'input', 'source', 'wbr', 'area', 'base', 'embed', 'param', 'col'}
    BLOCK = {'p', 'div', 'section', 'article', 'blockquote', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'pre', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr'}
    def __init__(self, book):
        super().__init__(convert_charrefs=True)
        self.b = book; self.stack = [('root', book.body)]; self.hidden = []; self.in_head = False; self.title = []; self.in_title = False; self.nodes = 0

    def handle_starttag(self, name, attrs):
        attrs = dict(attrs)
        if self.hidden:
            if name not in self.VOID: self.hidden.append(name)
            return
        if name in {'script', 'style', 'iframe', 'object', 'embed', 'noscript'}:
            self.b.warnings.add('Сценарии, внешние стили и встроенные объекты HTML не переносятся.')
            if name not in self.VOID: self.hidden.append(name)
            return
        if name == 'head': self.in_head = True; return
        if name == 'title': self.in_title = True; return
        if name == 'html':
            self.b.language = attrs.get('lang') or attrs.get('xml:lang') or self.b.language; return
        if name in {'body', 'meta', 'link', 'base'} or self.in_head: return
        if len(self.stack) > 128 or self.nodes > 500000: self.b.fail('HTML слишком сложен для конвертации.')
        self.nodes += 1
        if name in self.BLOCK and self.stack[-1][0] == 'p': self.stack.pop()
        if name == 'li' and self.stack[-1][0] == 'li': self.stack.pop()
        mapped = {'b': 'strong', 'i': 'em', 'strike': 's', 'font': 'span', 'center': 'div'}.get(name, name)
        allowed = self.BLOCK | {'a', 'strong', 'em', 's', 'u', 'span', 'sub', 'sup', 'code', 'br', 'img', 'caption', 'dl', 'dt', 'dd', 'aside', 'header', 'footer', 'figure', 'figcaption'}
        if mapped not in allowed: mapped = 'span'
        node = self.b.local_image(attrs.get('src', '')) if mapped == 'img' else self.b.el(mapped)
        keys = ['id', 'class']
        if mapped in {'td', 'th'}: keys += ['colspan', 'rowspan']
        if mapped == 'ol': keys.append('start')
        if mapped == 'li' and next((name for name, _ in reversed(self.stack) if name in {'ol', 'ul'}), '') == 'ol': keys.append('value')
        for key in keys:
            if attrs.get(key): node.set(key, attrs[key])
        if name == 'a':
            if not node.get('id') and attrs.get('name'): node.set('id', attrs['name'])
            href = attrs.get('href', '')
            if hasattr(self.b, 'local_link'): node.set('href', self.b.local_link(href))
            elif href.startswith('#') or urlsplit(href).scheme.lower() in {'https', 'http', 'mailto'}: node.set('href', quote(href, safe=":/?#[]@!$&'()*+,;=%"))
            elif href: self.b.warnings.add('Ссылки на другие локальные HTML-файлы не перенесены; конвертируется выбранный документ.')
        # Preserve only text formatting; no url(), imports or executable CSS.
        declarations = []
        for key, value in re.findall(r'([\w-]+)\s*:\s*([^;]+)', attrs.get('style', '')):
            if key.lower() in {'font-weight', 'font-style', 'text-decoration', 'text-align', 'vertical-align', 'white-space'} and re.fullmatch(r'[\w\s%-]+', value):
                declarations.append(key.lower() + ':' + value)
        if name == 'center': declarations.append('text-align:center')
        if declarations: node.set('style', ';'.join(declarations))
        self.stack[-1][1].append(node)
        if name not in self.VOID: self.stack.append((name, node))

    def handle_startendtag(self, name, attrs):
        self.handle_starttag(name, attrs)
        if name not in self.VOID: self.handle_endtag(name)

    def handle_endtag(self, name):
        if self.hidden:
            if name in self.hidden:
                at = len(self.hidden) - 1 - self.hidden[::-1].index(name); self.hidden = self.hidden[:at]
            return
        if name == 'title': self.in_title = False; return
        if name == 'head': self.in_head = False; return
        for at in range(len(self.stack) - 1, 0, -1):
            if self.stack[at][0] == name: self.stack = self.stack[:at]; break

    def handle_data(self, value):
        if self.hidden: return
        if self.in_title: self.title.append(value)
        elif not self.in_head: self.b.c.append_text(self.stack[-1][1], value)


def read_html(book, data, html5=False):
    declaration = re.search(br'<meta\b[^>]*charset\s*=\s*[\'\"]?\s*([\w-]+)', data[:8192], re.I)
    text = decode(data, declaration[1].decode('ascii') if declaration else None)
    if html5:
        import sys
        vendor = str(Path(__file__).with_name('vendor')); sys.path.insert(0, vendor)
        try:
            import html5lib
            tree = html5lib.parse(text, namespaceHTMLElements=False)
            text = html5lib.serialize(tree, quote_attr_values='always', omit_optional_tags=False)
        finally: sys.path.remove(vendor)
    parser = HTMLInput(book); parser.feed(text); parser.close()
    if html5:
        blocks = HTMLInput.BLOCK | {'figure', 'figcaption', 'aside', 'header', 'footer', 'dl', 'dt', 'dd'}
        for node in reversed(list(book.body.iter())):
            name = book.c.tag(node)
            if name in {'p', 'span', 'strong', 'em', 's', 'u', 'sub', 'sup', 'code', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}:
                if any(child is not node and book.c.tag(child) in blocks for child in node.iter()):
                    node.tag = '{' + book.c.XH + '}div'
                    style = {'strong':'font-weight:bold', 'em':'font-style:italic', 's':'text-decoration:line-through', 'u':'text-decoration:underline'}.get(name)
                    if style: node.set('style', node.get('style', '') + ';' + style)
    if ''.join(parser.title).strip(): book.title = ''.join(parser.title).strip()


def read_markdown(book, data):
    import sys
    vendor = str(Path(__file__).with_name('vendor'))
    sys.path.insert(0, vendor)
    try:
        import mistune
        parser = mistune.create_markdown(escape=True, plugins=['table', 'footnotes', 'strikethrough', 'url'])
        html = parser(decode(data))
    finally:
        sys.path.remove(vendor)
    read_html(book, html.encode('utf-8'))
    notes = set()
    for section in book.body.iter():
        if 'footnotes' not in section.get('class', '').split(): continue
        for node in section.iter():
            if book.c.tag(node) == 'li' and node.get('id'):
                node.set('{' + book.c.EP + '}type', 'footnote'); notes.add(node.get('id'))
    for node in book.body.iter():
        if book.c.tag(node) == 'a' and node.get('href', '').lstrip('#') in notes:
            node.set('{' + book.c.EP + '}type', 'noteref')


def read_fb3(book):
    p = Package(book); c = book.c
    namespace = 'http://www.fictionbook.org/FictionBook3/body'
    try:
        part = 'fb3/body.xml'; root = p.xml(part); rels = p.relationships(part)
        if root.tag != '{' + namespace + '}fb3-body': book.fail('В FB3 не найден основной текст.')
        description = p.xml('fb3/description.xml', True)
        if description is not None:
            for node in description:
                if c.tag(node) == 'title' and c.plain(node): book.title = c.plain(node)
                elif c.tag(node) == 'lang' and c.plain(node): book.language = c.plain(node)
        mapping = {'section':'section', 'p':'p', 'strong':'strong', 'em':'em', 'strikethrough':'s', 'underline':'u',
                   'sub':'sub', 'sup':'sup', 'code':'code', 'span':'span', 'spacing':'span', 'smallcaps':'span',
                   'subtitle':'p', 'subscription':'div', 'annotation':'div', 'epigraph':'blockquote', 'blockquote':'blockquote',
                   'pre':'div', 'ol':'ol', 'ul':'ul', 'li':'li', 'table':'table', 'tr':'tr', 'td':'td', 'th':'th',
                   'div':'div', 'poem':'div', 'stanza':'div', 'v':'p', 'notes':'div', 'notebody':'aside', 'marker':'div'}
        note_count = 0
        def convert(node, depth=0, in_note=False):
            nonlocal note_count
            name = c.tag(node)
            if not node.tag.startswith('{' + namespace + '}'):
                if name in {'fb3-relations', 'fb3-classification'}: return None
                book.fail('Неподдерживаемое пространство имён FB3: ' + name)
            if name in {'clipped', 'paper-page-break'}:
                if name == 'clipped': book.warnings.add('Исходный FB3 содержит сокращённый фрагмент книги.')
                return book.el('br')
            if name == 'img':
                relation = rels.get(node.get('src'))
                if not relation or relation[1]: book.fail('Не найдено локальное изображение FB3: ' + node.get('src', ''))
                out = book.image(p.data(relation[0])); out.set('alt', node.get('alt', ''))
            elif name == 'title':
                out = book.el('p' if in_note else 'h' + str(min(6, max(1, depth))))
                for index, child in enumerate(node):
                    if index: out.append(book.el('br'))
                    if child.text: c.append_text(out, child.text)
                    for inline in child:
                        converted = convert(inline, depth, in_note)
                        if converted is not None: out.append(converted)
                        c.append_text(out, inline.tail)
                return out
            elif name in {'a', 'note'}:
                href = node.get('href') or node.get('{' + XL + '}href', '')
                if name == 'note': href = '#' + href.lstrip('#')
                if not href: book.fail('В FB3 отсутствует адрес ссылки или сноски.')
                out = book.el('a')
                if href.startswith('#') or urlsplit(href).scheme.lower() in {'http', 'https', 'mailto'}: out.set('href', href)
                else: book.fail('Неподдерживаемая внешняя ссылка FB3: ' + href)
                if name == 'note':
                    out.set('{' + c.EP + '}type', 'noteref'); note_count += 1
                    if not c.plain(node): out.text = str(note_count)
            elif name in mapping:
                out = book.el(mapping[name])
                if name == 'notebody': out.set('{' + c.EP + '}type', 'footnote'); in_note = True
                if name in {'v', 'pre'}: out.set('style', 'white-space:pre-wrap')
                if name == 'smallcaps': out.set('style', 'font-variant:small-caps')
            else: book.fail('Неподдерживаемый элемент FB3: ' + name)
            for key in ('id', 'colspan', 'rowspan'):
                if node.get(key): out.set(key, node.get(key))
            if node.get('align') in {'left', 'right', 'center', 'justify'}: out.set('style', 'text-align:' + node.get('align'))
            if node.text: c.append_text(out, node.text)
            for child in node:
                converted = book.el('caption', c.plain(child)) if name == 'table' and c.tag(child) == 'title' else convert(child, depth + (name == 'section'), in_note)
                if converted is not None: out.append(converted)
                c.append_text(out, child.tail)
            return out
        for node in root:
            out = convert(node, 0)
            if out is not None: book.body.append(out)
        book.warnings.add('Оформление FB3 адаптировано к электронной книге; точная страничная вёрстка и встроенные шрифты не переносятся.')
    finally: p.z.close()


class Package:
    def __init__(self, book):
        self.b = book; self.z = zipfile.ZipFile(book.source); self.names = {}; total = 0
        try:
            if len(self.z.infolist()) > book.c.MAX_ENTRIES: book.fail('В документе слишком много ресурсов.')
            for item in self.z.infolist():
                if item.filename in self.names: book.fail('В документе повторяется имя ресурса: ' + item.filename)
                self.names[item.filename] = item; total += item.file_size
                if item.file_size > book.c.MAX_FILE or total > book.c.MAX_TOTAL or item.flag_bits & 1:
                    book.fail('Документ зашифрован или превышает предел распаковки.')
        except BaseException:
            self.z.close(); raise
    def data(self, path):
        if path not in self.names: self.b.fail('Не найден ресурс документа: ' + path)
        return self.z.read(path)
    def xml(self, path, optional=False):
        if optional and path not in self.names: return None
        return self.b.c.xml(self.data(path))
    def relationships(self, part):
        path = posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')
        root = self.xml(path, True); result = {}
        if root is not None:
            for node in root:
                href = node.get('Target', ''); external = node.get('TargetMode') == 'External'
                decoded = unquote(href)
                # OPC absolute part names start at the package root, not the
                # filesystem root. DocSharp and Word both emit these forms.
                dest = href if external else posixpath.normpath(decoded.lstrip('/') if decoded.startswith('/') else posixpath.join(posixpath.dirname(part), decoded))
                if not external and (dest.startswith('../') or '\\' in dest or ':' in dest or '\x00' in dest): self.b.fail('Некорректный путь ресурса DOCX.')
                result[node.get('Id')] = (dest, external)
        return result


def read_docx(book):
    p = Package(book); c = book.c
    try:
        root = p.xml('word/document.xml'); styles = p.xml('word/styles.xml', True); props = p.xml('docProps/core.xml', True)
        if props is not None:
            for n in props:
                if c.tag(n) == 'title' and c.plain(n): book.title = c.plain(n)
                elif c.tag(n) == 'creator' and c.plain(n): book.author = c.plain(n)
        style_map = {n.get('{' + W + '}styleId'): n for n in (styles if styles is not None else [])}
        notes = []; note_ids = set(); numbering = {}; abstract = {}
        nums = p.xml('word/numbering.xml', True)
        def val(node, name='val', default=''):
            return node.get('{' + W + '}' + name, default) if node is not None else default
        if nums is not None:
            for n in nums:
                if c.tag(n) == 'abstractNum': abstract[val(n, 'abstractNumId')] = n
                elif c.tag(n) == 'num': numbering[val(n, 'numId')] = val(n.find('{' + W + '}abstractNumId'))
        counters = {}
        def inherited(style_id, prop):
            result = []; seen = set()
            while style_id and style_id not in seen:
                seen.add(style_id); style = style_map.get(style_id)
                if style is None: break
                result.insert(0, style.find('{' + W + '}' + prop)); style_id = val(style.find('{' + W + '}basedOn'))
            return [n for n in result if n is not None]
        def properties(nodes):
            result = {}
            for n in nodes:
                for child in n: result[c.tag(child)] = val(child, default='1')
            return result
        def add_inline(src, dst, part, rels, paragraph_style=''):
            for n in src:
                name = c.tag(n)
                if name in {'pPr', 'rPr', 'sdtPr', 'proofErr', 'bookmarkEnd', 'commentRangeStart', 'commentRangeEnd'}: continue
                if name in {'del', 'moveFrom'}:
                    book.warnings.add('Удалённые исправления DOCX не перенесены; сохранён итоговый текст.'); continue
                if name in {'oMath', 'oMathPara', 'object', 'altChunk'}: book.fail('Формулы и встроенные объекты DOCX пока не поддерживаются.')
                if name == 'r':
                    rp = n.find('{' + W + '}rPr'); sid = val(rp.find('{' + W + '}rStyle')) if rp is not None else ''
                    values = properties(inherited(paragraph_style, 'rPr') + inherited(sid, 'rPr') + ([rp] if rp is not None else []))
                    if values.get('vanish') not in {None, '0', 'false', 'off'}: continue
                    target = dst
                    for prop, mapped in [('b', 'strong'), ('i', 'em'), ('strike', 's'), ('u', 'u')]:
                        if values.get(prop) not in {None, '0', 'false', 'off', 'none'}:
                            child = book.el(mapped); target.append(child); target = child
                    if values.get('vertAlign') in {'superscript', 'subscript'}:
                        child = book.el('sup' if values['vertAlign'] == 'superscript' else 'sub'); target.append(child); target = child
                    add_inline(n, target, part, rels)
                elif name == 't': c.append_text(dst, n.text or '')
                elif name == 'tab': c.append_text(dst, '\t')
                elif name in {'br', 'cr'}: dst.append(book.el('br'))
                elif name == 'noBreakHyphen': c.append_text(dst, '\u2011')
                elif name == 'softHyphen': c.append_text(dst, '\u00ad')
                elif name == 'hyperlink':
                    href = '#' + val(n, 'anchor') if val(n, 'anchor') else ''
                    relation = rels.get(n.get('{' + R + '}id'))
                    if relation:
                        if relation[1] and urlsplit(relation[0]).scheme in {'https', 'http', 'mailto'}: href = relation[0]
                        elif not relation[1]: book.warnings.add('Ссылка на отдельный документ DOCX не перенесена.')
                    child = book.el('a', **({'href': href} if href else {})); dst.append(child); add_inline(n, child, part, rels)
                elif name == 'bookmarkStart':
                    identity = val(n, 'name')
                    if identity and identity != '_GoBack': dst.append(book.el('span', id=identity))
                elif name in {'drawing', 'pict'}:
                    found = False
                    for image in n.iter():
                        identity = image.get('{' + R + '}embed') or image.get('{' + R + '}id')
                        if c.tag(image) not in {'blip', 'imagedata'} or not identity: continue
                        relation = rels.get(identity)
                        if not relation or relation[1]: book.fail('Внешнее или отсутствующее изображение DOCX не переносится.')
                        dst.append(book.image(p.data(relation[0]))); found = True
                    if not found: book.fail('Неподдерживаемый рисунок или диаграмма DOCX.')
                elif name in {'footnoteReference', 'endnoteReference'}:
                    identity = name[:name.index('Reference')] + '-' + val(n, 'id')
                    child = book.el('a', str(len(notes) + 1), href='#' + identity, **{'{' + c.EP + '}type': 'noteref'}); dst.append(child)
                    if identity not in note_ids: note_ids.add(identity); notes.append((name, val(n, 'id'), identity))
                elif name in {'instrText', 'fldChar', 'footnoteRef', 'endnoteRef', 'lastRenderedPageBreak'}: continue
                else: add_inline(n, dst, part, rels, paragraph_style)
        def block(src, dst, part):
            rels = p.relationships(part)
            for n in src:
                name = c.tag(n)
                if name == 'p':
                    pp = n.find('{' + W + '}pPr'); sid = val(pp.find('{' + W + '}pStyle')) if pp is not None else ''
                    ps = properties(inherited(sid, 'pPr') + ([pp] if pp is not None else []))
                    depth = ps.get('outlineLvl'); heading = re.search(r'(?:Heading|Заголовок)\s*([1-6])', sid, re.I)
                    if depth is not None and depth.isdigit() and int(depth) < 6: depth = int(depth) + 1
                    elif heading: depth = int(heading[1])
                    else: depth = None
                    out = book.el('h' + str(depth) if depth else 'p')
                    if ps.get('jc') in {'center', 'right', 'left', 'both'}: out.set('style', 'text-align:' + ('justify' if ps['jc'] == 'both' else ps['jc']))
                    num = pp.find('{' + W + '}numPr') if pp is not None else None
                    if num is not None:
                        numid = val(num.find('{' + W + '}numId')); level = val(num.find('{' + W + '}ilvl'), default='0')
                        definition = abstract.get(numbering.get(numid)); lvl = next((x for x in (definition if definition is not None else []) if val(x, 'ilvl') == level), None)
                        fmt = val(lvl.find('{' + W + '}numFmt')) if lvl is not None else 'bullet'
                        start = val(lvl.find('{' + W + '}start'), default='1') if lvl is not None else '1'
                        key = (numid, level); counters[key] = counters.get(key, int(start) - 1 if start.isdigit() else 0) + 1
                        out.text = '• ' if fmt == 'bullet' else str(counters[key]) + '. '
                        book.warnings.add('Списки DOCX перенесены абзацами; сложная многоуровневая нумерация упрощается.')
                    add_inline(n, out, part, rels, sid)
                    if not c.plain(out) and not len(out): out.append(book.el('br'))
                    dst.append(out)
                elif name == 'tbl':
                    table = book.el('table'); dst.append(table)
                    for row in n.findall('{' + W + '}tr'):
                        tr = book.el('tr'); table.append(tr)
                        for cell in row.findall('{' + W + '}tc'):
                            td = book.el('td'); tr.append(td); block(cell, td, part)
                            span = cell.find('{' + W + '}tcPr/{' + W + '}gridSpan')
                            if span is not None: td.set('colspan', val(span))
                elif name in {'sdt', 'sdtContent', 'customXml', 'ins'}: block(n, dst, part)
                elif name not in {'sectPr', 'tcPr', 'sdtPr', 'tblPr', 'tblGrid'}: add_inline([n], dst, part, rels)
        body = root.find('{' + W + '}body')
        if body is None: book.fail('В DOCX нет основного текста.')
        block(body, book.body, 'word/document.xml')
        for kind, identity, anchor in notes:
            part = 'word/footnotes.xml' if kind == 'footnoteReference' else 'word/endnotes.xml'; nr = p.xml(part)
            note = next((n for n in nr if val(n, 'id') == identity), None)
            if note is None: book.fail('Не найдена сноска DOCX: ' + identity)
            out = book.el('aside', id=anchor, **{'{' + c.EP + '}type': 'footnote'}); block(note, out, part); book.body.append(out)
        book.warnings.add('Страничная вёрстка, колонтитулы и шрифты DOCX заменены оформлением электронной книги.')
    finally: p.z.close()


def read_odt(book, legacy=False):
    p = Package(book); c = book.c
    try:
        manifest = p.xml('META-INF/manifest.xml', True)
        if manifest is not None and any(c.tag(n) == 'encryption-data' for n in manifest.iter()): book.fail('Зашифрованный ODT не поддерживается.')
        root = p.xml('content.xml'); sr = p.xml('styles.xml', True); meta = p.xml('meta.xml', True)
        if legacy:
            namespaces={f'http://openoffice.org/2000/{name}':value for name,value in
                        [('office',O),('style',S),('text',T),('drawing',DRAW),('table','urn:oasis:names:tc:opendocument:xmlns:table:1.0')]}
            namespaces['http://www.w3.org/1999/XSL/Format']=F
            def mapped(name):
                if name.startswith('{'):
                    uri,local=name[1:].split('}',1)
                    return '{'+namespaces.get(uri,uri)+'}'+local
                return name
            for tree in [root,sr,meta]:
                if tree is not None:
                    for node in tree.iter():
                        node.tag=mapped(node.tag)
                        node.attrib={mapped(key):value for key,value in node.attrib.items()}
        if meta is not None:
            for n in meta.iter():
                if n.tag == '{' + c.DC + '}title' and c.plain(n): book.title = c.plain(n)
                elif n.tag == '{' + c.DC + '}creator' and c.plain(n): book.author = c.plain(n)
                elif n.tag == '{' + c.DC + '}language' and c.plain(n): book.language = c.plain(n)
        styles = {}
        for tree in [sr, root]:
            if tree is not None:
                for n in tree.iter('{' + S + '}style'): styles[n.get('{' + S + '}name')] = n
        def style_values(name):
            result = {}; seen = set()
            while name and name not in seen:
                seen.add(name); n = styles.get(name)
                if n is None: break
                for child in n:
                    for key, value in child.attrib.items(): result.setdefault(key, value)
                name = n.get('{' + S + '}parent-style-name')
            return result
        def fill(src, out):
            c.append_text(out, src.text)
            for n in src:
                name = c.tag(n); target = out
                if n.tag in {'{' + T + '}p', '{' + T + '}h'}:
                    level = n.get('{' + T + '}outline-level', '1'); level = int(level) if level.isdigit() else 1
                    target = book.el('h' + str(min(6, max(1, level))) if name == 'h' else 'p'); out.append(target)
                elif name in {'span', 'a'}:
                    target = book.el(name); out.append(target)
                    if name == 'a':
                        href = n.get('{' + XL + '}href', '')
                        if href.startswith('#') or urlsplit(href).scheme in {'https', 'http', 'mailto'}: target.set('href', href)
                elif n.tag == '{' + T + '}s':
                    count = n.get('{' + T + '}c', '1')
                    if not count.isdigit() or not 1 <= int(count) <= 10000: book.fail('Слишком длинная последовательность пробелов ODT.')
                    c.append_text(out, ' ' * int(count)); c.append_text(out, n.tail); continue
                elif n.tag == '{' + T + '}tab': c.append_text(out, '\t'); c.append_text(out, n.tail); continue
                elif name == 'line-break': out.append(book.el('br')); c.append_text(out, n.tail); continue
                elif n.tag == '{' + DRAW + '}image':
                    href = unquote(n.get('{' + XL + '}href', '')); href = posixpath.normpath(href)
                    if href.startswith(('/', '../')) or ':' in href: book.fail('Внешнее изображение ODT не скачивается.')
                    out.append(book.image(p.data(href))); c.append_text(out, n.tail); continue
                elif name == 'note':
                    identity = n.get('{' + T + '}id') or 'odt-note-' + str(len(notes) + 1)
                    citation = n.find('{' + T + '}note-citation'); body = n.find('{' + T + '}note-body')
                    if body is None: book.fail('В ODT отсутствует текст сноски.')
                    out.append(book.el('a', c.plain(citation) or str(len(notes) + 1), href='#' + identity, **{'{' + c.EP + '}type': 'noteref'}))
                    note = book.el('aside', id=identity, **{'{' + c.EP + '}type': 'footnote'}); fill(body, note); notes.append(note); c.append_text(out, n.tail); continue
                elif name in {'bookmark', 'bookmark-start'}:
                    identity = n.get('{' + T + '}name')
                    if identity: out.append(book.el('span', id=identity))
                elif name == 'list': target = book.el('ul'); out.append(target); book.warnings.add('Списки ODT перенесены с маркерами; сложная нумерация упрощается.')
                elif name == 'list-item': target = book.el('li'); out.append(target)
                elif name in {'table', 'table-row', 'table-cell', 'table-header-rows'}:
                    target = book.el({'table': 'table', 'table-row': 'tr', 'table-cell': 'td', 'table-header-rows': 'thead'}[name]); out.append(target)
                    for key, value in n.attrib.items():
                        if key.endswith('}number-columns-spanned'): target.set('colspan', value)
                        if key.endswith('}number-columns-repeated') or key.endswith('}number-rows-repeated'):
                            if value != '1': book.fail('Повторяющиеся ячейки ODT пока не поддерживаются.')
                elif name in {'annotation', 'tracked-changes', 'bookmark-end', 'soft-page-break'}: c.append_text(out, n.tail); continue
                elif name in {'object', 'object-ole', 'formula'}: book.fail('Формулы и встроенные объекты ODT пока не поддерживаются.')
                values = style_values(n.get('{' + T + '}style-name', ''))
                if values.get('{' + F + '}text-align') in {'center', 'end', 'start', 'justify'}:
                    target.set('style', 'text-align:' + {'end': 'right', 'start': 'left'}.get(values['{' + F + '}text-align'], values['{' + F + '}text-align']))
                inner = target
                for prop, expected, mapped in [('{'+F+'}font-weight', 'bold', 'strong'), ('{'+F+'}font-style', 'italic', 'em'), ('{'+S+'}text-line-through-style', 'solid', 's'), ('{'+S+'}text-underline-style', 'solid', 'u')]:
                    if values.get(prop) == expected:
                        child = book.el(mapped); inner.append(child); inner = child
                fill(n, inner); c.append_text(out, n.tail)
        text = root.find('{' + O + '}body/{' + O + '}text'); notes = []
        if text is None and legacy:text=root.find('{'+O+'}body')
        if text is None: book.fail('В ODT нет основного текста.')
        fill(text, book.body); book.body.extend(notes)
        book.warnings.add('Страничная вёрстка, колонтитулы и шрифты ODT заменены оформлением электронной книги.')
    finally: p.z.close()


def read_abw(book):
    c=book.c;root=c.xml(book.source.read_bytes())
    if c.tag(root)!='abiword':book.fail('Файл не является документом AbiWord.')
    styles={node.get('name'):node for parent in root if c.tag(parent)=='styles' for node in parent}
    assets={node.get('name'):node for parent in root if c.tag(parent)=='data' for node in parent}
    for parent in root:
        if c.tag(parent)=='metadata':
            for node in parent:
                key=node.get('key','');value=c.plain(node)
                if key=='dc.title' and value:book.title=value
                elif key=='dc.creator' and value and not book.author:book.author=value
                elif key=='dc.language' and value:book.language=value
    def properties(node):
        values={};style=styles.get(node.get('style'));seen=set()
        while style is not None and id(style) not in seen:
            seen.add(id(style))
            for field in style.get('props','').split(';'):
                key,sep,value=field.partition(':')
                if sep:values.setdefault(key.strip(),value.strip())
            style=styles.get(style.get('basedon'))
        for field in node.get('props','').split(';'):
            key,sep,value=field.partition(':')
            if sep:values[key.strip()]=value.strip()
        return values
    def fill(src,out):
        c.append_text(out,src.text)
        for node in src:
            name=c.tag(node);target=out
            if name in {'section','p','table','cell','footnote','endnote'}:
                tag='p' if name=='p' else 'section' if name in {'section','footnote','endnote'} else 'div'
                style=node.get('style','')
                heading=re.fullmatch(r'Heading\s*([1-6])',style,re.I)
                if name=='p' and heading:tag='h'+heading[1]
                target=book.el(tag);out.append(target)
                if node.get('listid'):
                    target.text='• ';book.warnings.add('Нумерация списков AbiWord заменена маркерами; текст пунктов сохранён.')
            elif name=='image':
                resource=assets.get(node.get('dataid'))
                if resource is None:book.fail('В AbiWord отсутствует встроенное изображение.')
                payload=''.join(resource.itertext())
                if resource.get('base64','yes')=='yes':
                    try:data=base64.b64decode(re.sub(r'\s+','',payload),validate=True)
                    except ValueError:book.fail('Повреждены данные изображения AbiWord.')
                else:data=payload.encode('utf-8')
                out.append(book.image(data));c.append_text(out,node.tail);continue
            elif name in {'br','break'}:
                out.append(book.el('br'));c.append_text(out,node.tail);continue
            elif name=='a':
                target=book.el('a');out.append(target);href=node.get('{'+XL+'}href',node.get('href',''))
                if href.startswith('#') or urlsplit(href).scheme in {'https','http','mailto'}:target.set('href',href)
            elif name=='bookmark':
                if node.get('name'):out.append(book.el('span',id=node.get('name')))
            elif name in {'math','embed','object'}:book.fail('Встроенный объект AbiWord требует отдельного преобразования; неполная книга не сохранена.')
            elif name not in {'c','field'}:book.warnings.add('AbiWord: упрощён элемент '+name+'. Его текст сохранён.')
            values=properties(node)
            for key,test,tag in [('font-weight',lambda v:v in {'bold','700','800','900'},'strong'),('font-style',lambda v:v=='italic','em'),('text-decoration',lambda v:'underline' in v,'u')]:
                if test(values.get(key,'')):
                    child=book.el(tag);target.append(child);target=child
            fill(node,target);c.append_text(out,node.tail)
    sections=[node for node in root if c.tag(node)=='section']
    if not sections:book.fail('В AbiWord нет основного текста.')
    for node in sections:fill(node,book.body)
    book.warnings.add('AbiWord: текст, основные выделения, ссылки и встроенные изображения сохранены; страничная вёрстка адаптирована.')


def read_rtf(book, data):
    # Stateful token reader: group-scoped destinations/formatting/codepage/uc,
    # Unicode fallback bytes, escaped braces and binary blocks are distinct.
    if not data.lstrip().startswith(b'{\\rtf'): book.fail('Файл не является RTF.')
    text = data.decode('latin1'); at = 0; stack = []; state = {'skip': False, 'uc': 1, 'cp': 'cp1252', 'b': False, 'i': False, 's': False, 'u': False, 'sup': False, 'sub': False, 'fonttable': False, 'fontid': None, 'pict': None}
    fonts = {}; default_font = None
    charsets = {204: 'cp1251', 238: 'cp1250', 161: 'cp1253', 162: 'cp1254', 177: 'cp1255', 178: 'cp1256', 186: 'cp1257', 163: 'cp1258', 128: 'cp932', 129: 'cp949', 134: 'cp936', 136: 'cp950', 222: 'cp874'}
    paragraph = book.el('p'); book.body.append(paragraph); fallback = 0; buffer = bytearray(); node_count = 0
    run_parent = run_style = run_target = None
    run_parts = []
    formatting = [('b', 'strong'), ('i', 'em'), ('s', 's'), ('u', 'u'), ('sup', 'sup'), ('sub', 'sub')]
    token = re.compile(r'([a-zA-Z]+)(-?\d+)? ?')
    destinations = {'fonttbl', 'colortbl', 'stylesheet', 'info', 'filetbl', 'listtable', 'listoverridetable', 'revtbl', 'rsidtbl', 'generator', 'header', 'headerl', 'headerr', 'footer', 'footerl', 'footerr', 'annotation', 'datastore', 'themedata', 'colorschememapping', 'fldinst', 'objdata', 'nonshppict'}
    def finish_run():
        if run_parts:
            book.c.append_text(run_target, ''.join(run_parts)); run_parts.clear()
    def emit(value):
        nonlocal node_count, run_parent, run_style, run_target
        if state['skip'] or state['pict'] is not None or not value: return
        node_count += 1
        if node_count > 500000: book.fail('RTF слишком сложен для конвертации.')
        style = tuple(state[prop] for prop, _ in formatting)
        # Adjacent Unicode controls belong to one text run. In particular, a
        # surrogate pair must reach XML as one value even inside bold/italic.
        if run_parent is not paragraph or run_style != style:
            finish_run()
            target = paragraph
            for (_, name), enabled in zip(formatting, style):
                if enabled:
                    child = book.el(name); target.append(child); target = child
            run_parent, run_style, run_target = paragraph, style, target
        run_parts.append(value)
    def flush():
        if buffer:
            try: emit(buffer.decode(state['cp']))
            except (UnicodeError, LookupError): book.fail('Неподдерживаемая кодировка RTF: ' + state['cp'])
            buffer.clear()
    def char(value):
        nonlocal fallback
        if fallback: fallback -= 1
        elif state['pict'] is not None: state['pict']['hex'].append(value)
        else: buffer.extend(value.encode('latin1'))
    while at < len(text):
        ch = text[at]; at += 1
        if ch == '{':
            flush(); fallback = 0; stack.append(state.copy())
            if len(stack) > 128: book.fail('Слишком глубокая структура RTF.')
        elif ch == '}':
            flush(); fallback = 0
            if not stack: book.fail('Нарушена структура групп RTF.')
            parent = stack.pop()
            if state['pict'] is not None and state['pict'] is not parent['pict']:
                pic = state['pict']
                if not state['skip']:
                    try: raw = bytes.fromhex(''.join(pic['hex'])) if pic['bin'] is None else pic['bin']
                    except ValueError: book.fail('Некорректное изображение RTF.')
                    finish_run()
                    paragraph.append(book.image(raw))
                    run_parent = None
            was_fonts = state['fonttable']; state = parent
            if was_fonts and not state['fonttable'] and default_font in fonts: state['cp'] = fonts[default_font]
            if not stack:
                if text[at:].strip(): book.fail('Посторонние данные после документа RTF.')
                break
        elif ch == '\\':
            if at >= len(text): book.fail('Оборванный управляющий код RTF.')
            symbol = text[at]
            if symbol in '\\{}': at += 1; char(symbol); continue
            if symbol == "'":
                if len(text[at+1:at+3]) != 2: book.fail('Оборванный байтовый код RTF.')
                try: value = chr(int(text[at+1:at+3], 16))
                except ValueError: book.fail('Некорректный байтовый код RTF.')
                at += 3; char(value); continue
            match = token.match(text, at)
            if not match:
                at += 1
                if fallback: fallback -= 1; continue
                if symbol == '*': flush(); state['skip'] = True
                elif symbol in {'~', '_', '-'}:
                    flush(); emit({'~': '\u00a0', '_': '\u2011', '-': '\u00ad'}[symbol])
                continue
            flush(); at = match.end(); word = match[1]; arg = int(match[2]) if match[2] else None
            if word == 'bin':
                if arg is None or arg < 0 or at + arg > len(text): book.fail('Оборванный двоичный блок RTF.')
                if fallback: fallback -= 1
                elif state['pict'] is not None: state['pict']['bin'] = text[at:at+arg].encode('latin1')
                at += arg; continue
            # A fallback control word counts as one character, including its
            # delimiter. It must neither render nor consume the following text.
            if fallback: fallback -= 1; continue
            if word == 'fonttbl': state['skip'] = True; state['fonttable'] = True
            elif word == 'deff': default_font = arg
            elif word == 'f':
                if state['fonttable']: state['fontid'] = arg
                elif arg in fonts: state['cp'] = fonts[arg]
            elif word in {'fcharset', 'cpg'} and state['fonttable']:
                cp = charsets.get(arg) if word == 'fcharset' else ('cp' + str(arg) if arg else None)
                if cp: fonts[state['fontid']] = cp
            elif word in destinations: state['skip'] = True
            elif word == 'object': book.fail('Встроенные объекты RTF пока не поддерживаются.')
            elif word == 'footnote': book.warnings.add('Сноски RTF перенесены в основной текст возле ссылки.')
            elif word == 'pict': state['pict'] = {'hex': [], 'bin': None}
            elif word == 'ansicpg' and arg:
                state['cp'] = 'cp' + str(arg)
                try: codecs.lookup(state['cp'])
                except LookupError: book.fail('Неизвестная кодировка RTF.')
            elif word == 'uc' and arg is not None:
                if not 0 <= arg <= 16: book.fail('Некорректный Unicode fallback RTF.')
                state['uc'] = arg
            elif word == 'u' and arg is not None: emit(chr(arg & 0xffff)); fallback = state['uc']
            elif word in {'b', 'i', 'strike', 'ul', 'ulnone', 'super', 'sub', 'nosupersub'}:
                prop = {'strike': 's', 'ul': 'u', 'ulnone': 'u', 'super': 'sup', 'nosupersub': 'sup'}.get(word, word)
                state[prop] = arg != 0 and word not in {'ulnone', 'nosupersub'}
                if word == 'nosupersub': state['sub'] = False
            elif word == 'plain':
                for key in ('b', 'i', 's', 'u', 'sup', 'sub'): state[key] = False
            elif word == 'outlinelevel' and arg is not None and 0 <= arg < 6:
                paragraph.tag = '{' + book.c.XH + '}h' + str(arg + 1)
            elif word in {'par', 'page', 'sect', 'row'} and not state['skip'] and state['pict'] is None:
                finish_run()
                paragraph = book.el('p'); book.body.append(paragraph)
            elif word in {'line', 'tab', 'cell', 'emdash', 'endash', 'lquote', 'rquote', 'ldblquote', 'rdblquote', 'bullet'}:
                if word == 'line' and not state['skip']:
                    finish_run(); paragraph.append(book.el('br')); run_parent = None
                else: emit({'tab': '\t', 'cell': '\t', 'emdash': '—', 'endash': '–', 'lquote': '‘', 'rquote': '’', 'ldblquote': '“', 'rdblquote': '”', 'bullet': '•'}.get(word, ''))
        elif ch not in '\r\n': char(ch)
    flush(); finish_run()
    if stack: book.fail('RTF обрывается внутри группы.')
    book.warnings.add('Страничная вёрстка, таблицы и сложные поля RTF упрощаются до текста; основные выделения сохраняются.')


def to_epub(source, output, warnings, api, input_extension=None, **metadata):
    book = Book(api, source, warnings, **metadata)
    book.work_root = output.parent
    extension = input_extension or source.suffix.lower()
    if extension == '.docx': read_docx(book)
    elif extension == '.odt': read_odt(book)
    elif extension == '.sxw': read_odt(book,legacy=True)
    elif extension == '.abw': read_abw(book)
    elif extension == '.fb3': read_fb3(book)
    elif extension == '.ibk':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_ibk_input', Path(__file__).with_name('ibk_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book)
    elif extension == '.rgo':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_rgo_input', Path(__file__).with_name('rgo_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book, source.read_bytes())
    elif extension == '.jutoh':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_jutoh_input', Path(__file__).with_name('jutoh_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book)
    elif extension == '.pages':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_pages_input', Path(__file__).with_name('pages_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book)
    elif extension in {'.doc', '.dot', '.docm', '.dotx', '.dotm', '.ppt', '.pps', '.pot', '.pptx', '.pptm', '.ppsx', '.ppsm', '.potx', '.potm', '.xls', '.xlt', '.xlsx', '.xlsm', '.xltx', '.xltm', '.ods', '.ots', '.odp', '.otp', '.ott', '.wps', '.wpd'}:
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_office_inputs', Path(__file__).with_name('office_inputs.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book, extension, Package, read_docx, read_odt, read_html)
    elif extension in {'.mht', '.mhtml', '.wri', '.pdb', '.tcr', '.chm', '.lit', '.lrf', '.rb'}:
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_legacy_inputs', Path(__file__).with_name('legacy_inputs.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book, extension, lambda b, d: read_html(b, d, html5=True), decode)
    elif extension in {'.pdf', '.djvu', '.djv', '.dju', '.djvm', '.djm'}:
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_fixed_layout', Path(__file__).with_name('fixed_layout.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book, extension)
    elif extension == '.xps':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_xps_input', Path(__file__).with_name('xps_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book)
    elif extension in {'.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.cbz','.cbr','.cb7'}:
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_image_input', Path(__file__).with_name('image_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.read(book, extension)
    else:
        data = source.read_bytes()
        if extension in {'.txt', '.text', '.faq'}:
            # Preserve explicit line and blank paragraph boundaries; do not guess
            # chapters from arbitrary short lines or merge poetry into prose.
            for line in decode(data).splitlines():
                paragraph = book.el('p', line)
                if not line: paragraph.append(book.el('br'))
                book.body.append(paragraph)
        elif extension in {'.html', '.htm', '.xhtml', '.shtml'}: read_html(book, data)
        elif extension == '.rtf': read_rtf(book, data)
        elif extension in {'.md', '.markdown'}: read_markdown(book, data)
        else: book.fail('Этот текстовый формат пока не поддерживается.')
    book.progress('finalizing', 0, 0)
    book.finish(output)

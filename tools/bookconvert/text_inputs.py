"""Text document inputs for the local ebook converter (MIT).

Uses the standard library and bundled Mistune for Markdown. Produces a reading EPUB, not a facsimile
of an office page. Never runs macros, follows external resources or changes input.
"""
import base64
import codecs
import copy
import html
from contextlib import ExitStack
from datetime import datetime, timezone
from fractions import Fraction
from functools import lru_cache
from itertools import groupby
from html.parser import HTMLParser
from pathlib import Path
import posixpath
import re
import shutil
import tempfile
from typing import NamedTuple
from urllib.parse import unquote, urlsplit, quote
import uuid
import xml.etree.ElementTree as ET
import zipfile

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
MC = '{http://schemas.openxmlformats.org/markup-compatibility/2006}'
A = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
WP = '{http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing}'
WORD_DRAWING_GROUP = '{http://schemas.microsoft.com/office/word/2010/wordprocessingGroup}wgp'
WORD_DRAWING_SHAPE = '{http://schemas.microsoft.com/office/word/2010/wordprocessingShape}wsp'
WORD_DRAWING_CANVAS = '{http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas}wpc'
WORD_DRAWING_GROUPS = {WORD_DRAWING_GROUP,
                       WORD_DRAWING_CANVAS, '{urn:schemas-microsoft-com:vml}group'}
T = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
O = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
S = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0'
F = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0'
DRAW = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0'
XL = 'http://www.w3.org/1999/xlink'
SUPPORTED = {'.txt', '.html', '.htm', '.xhtml', '.rtf', '.docx', '.odt', '.fb3', '.md', '.markdown'}


def _table_cell_has_content(cell):
    return (any(text.strip() for text in cell.itertext()) or
            any(node.get('id') or node.tag.rpartition('}')[2] in {'img', 'table'} for node in cell.iter()))


def decode(data, encoding=None):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    if encoding:
        return data.decode(encoding, errors='strict')
    try:
        return data.decode('utf-8-sig')
    except UnicodeError:
        return data.decode('cp1251')


_CYRILLIC_WORDS = frozenset(
    'без был была были будет для его если еще ещё или как когда кто между может можно над надо наш '
    'него нее неё они она оно при после перед про раз себя так там тебе тоже только хотя через что '
    'чтобы этот эта это'.split()
)


def plain_text_encoding(data):
    """Choose a legacy code page only with strong evidence from Russian words."""
    # Keep this bounded test in sync with PlainTextLegacyCodePage in the reader.
    sample = data[:65536]
    encodings = ('cp1251', 'cp866', 'koi8-r')
    scores = []
    for encoding in encodings:
        words = re.findall(r'[а-яё]+', sample.decode(encoding, errors='replace').lower())
        common = [word for word in words if word in _CYRILLIC_WORDS]
        scores.append((len(common), len(set(common)), sum(map(len, words))))
    utf8_letters = sum(map(len, re.findall(r'[а-яё]+', sample.decode('utf-8', errors='replace').lower())))
    for index in (1, 2):
        hits, distinct, letters = scores[index]
        competitor = max(score[0] for other, score in enumerate(scores) if other != index)
        if distinct >= 3 and hits >= 2 * competitor + 4 and letters >= max(24, 4 * utf8_letters):
            return encodings[index]
    return 'cp1251'


def decode_plain_text(data, warnings):
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    try:
        text = data.decode(encoding)
    except UnicodeDecodeError:
        if encoding == 'utf-8-sig' and not data.startswith(b'\xef\xbb\xbf'):
            encoding = plain_text_encoding(data)
        try:
            text = data.decode(encoding)
        except UnicodeDecodeError:
            text = data.decode(encoding, errors='replace')
            warnings.add('Нечитаемые символы исходника отмечены знаком �.')
    # Some DOS texts use the display glyph for byte 07 as a list bullet.
    if encoding == 'cp866' and (markers := text.count('\x07')) >= 3:
        if len(re.findall(r'(?:^|[\r\n])[ \t]*\x07(?=[ \t]*[A-Za-zА-Яа-яЁё0-9])', text)) == markers:
            text = text.replace('\x07', '•')
    # DOS text files may place a single Ctrl+Z after the final line ending.
    if text.endswith(('\r\x1a', '\n\x1a')):
        return text[:-1]
    return text


_BOX_DRAWING = re.compile(r'[\u2500-\u257f]')
_COLUMN_GAPS = re.compile(r'(?<=[^ \t]) {2,}(?=[^ \t])')
_DRAWING_LABEL = re.compile(r' {2,}([0-9]+) *\Z')


def _aligned_columns(first, second, third=None):
    # Intersect the whitespace between fields. Cell content may be aligned
    # either left or right, so the preceding and following text can move.
    rows = (first, second, second if third is None else third)
    positions = [0, 0, 0]
    gaps = 0
    while all(position < len(row) for row, position in zip(rows, positions)):
        current = [row[position] for row, position in zip(rows, positions)]
        end = min(gap[1] for gap in current)
        width = end - max(gap[0] for gap in current)
        if width >= 5:
            return True
        if width >= 2:
            gaps += 1
            if gaps >= 3:
                return True
        for index, gap in enumerate(current):
            if gap[1] == end:
                positions[index] += 1
    return False


def plain_text_fixed_rows(lines):
    fixed = bytearray(len(lines))
    older = previous = None
    for index, line in enumerate(lines):
        if not line.strip(' \t'):
            continue
        box = bool(_BOX_DRAWING.search(line))
        if box:
            fixed[index] = 1
        columns = [(match.start(), match.end()) for match in _COLUMN_GAPS.finditer(line)]
        if previous is not None and index - previous[0] <= 2:
            # Two rows suffice when a drawing marks the layout. Otherwise
            # require three to avoid treating interword spacing as columns.
            start = index
            if box or previous[1]:
                label = lines[previous[0]] if box else line
                drawing = line if box else lines[previous[0]]
                match = _DRAWING_LABEL.fullmatch(label)
                if (_aligned_columns(previous[2], columns) or
                        (match and _BOX_DRAWING.search(drawing[match.start(1):match.end(1)]))):
                    start = previous[0]
            if (older is not None and previous[0] - older[0] <= 2
                    and _aligned_columns(older[2], previous[2], columns)):
                start = older[0]
            if start < index:
                fixed[start:index + 1] = b'\1' * (index + 1 - start)
        older, previous = previous, (index, box, columns)
    return fixed


class Book:
    def __init__(self, api, source, warnings, title='', author='', language='', resource_root=None, tools_root=None, reading=False, progress=None, image_export=None, omit_images=False, resource_scope=None, static_gifs=False, cancel_check=None, document_outline=None):
        self.c, self.source, self.warnings = api, source, warnings
        self.title, self.author, self.language = title or source.stem, author, language or 'und'
        self.fb3_description = None
        self.publication_metadata = None
        self.body = self.el('body')
        self.resources, self.images = {}, {}
        self.resource_root = Path(resource_root).resolve() if resource_root else source.parent.resolve()
        self.resource_scope = Path(resource_scope).resolve() if resource_scope else self.resource_root
        self.tools_root = Path(tools_root).resolve() if tools_root else Path(__file__).resolve().parent.parent
        self.total = 0
        self.unreadable_images = 0
        self.image_store = None
        self.section_store = None
        self.reading = reading
        self.omit_images = bool(omit_images) and not reading
        self.progress = progress or (lambda stage, completed, total: None)
        self.image_export = image_export if not reading else None
        self.scan_export = None
        self.page_outline = None
        self.document_outline = document_outline
        self.framed_pages = None
        self.static_gifs = static_gifs
        self.cancel_check = cancel_check

    def scan_processor(self):
        if self.scan_export is None:
            import importlib.util
            spec = importlib.util.spec_from_file_location('homelib_scan_export', Path(__file__).with_name('scan_export.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.scan_export = module.ScanExport(self, self.image_export)
        return self.scan_export

    def fixed_illustration(self, data):
        if self.image_export:
            profile = self.image_export['profile']
            if self.scan_export is not None and self.scan_export.chosen:
                profile = self.scan_export.profile
            if profile != 'ask' and (profile not in {'original', 'high'} or self.image_export.get('grayscale')):
                return self.scan_processor().add_illustration(data)
        return self.image(data)

    def scan_page(self, data, number, total=0):
        if self.image_export:
            if (self.image_export['profile'] in {'original','high'} and self.image_export.get('layout','keep')=='keep'
                    and not self.image_export.get('grayscale', False)):
                # The PDF/DjVu renderer has already produced the page image.
                # Keeping it untouched requires no separate image processor.
                self.image_export['handled']=True
            else:
                return self.scan_processor().add(data,number,total)
        picture=self.image(data)
        section = self.scan_section(number)
        paragraph=self.el('p');section.append(paragraph)
        picture.set('alt','Страница '+str(number));paragraph.append(picture)
        return section

    def scan_section(self, number):
        section = self.el('section', id=f'page-{number}')
        section.append(self.el('p', f'Страница {number}', style='text-align:center;font-weight:bold'))
        self.body.append(section)
        return section

    def el(self, name, text=None, **attrs):
        return self.c.element(self.c.XH, name, text, **attrs)

    def fail(self, message):
        raise self.c.ConversionError(message)

    def require(self, component, message):
        raise self.c.ComponentRequired(self.c.optional_component_id(component, self.tools_root), message)

    def office_image_decoder(self):
        if not hasattr(self, '_image_decoder'):
            import importlib.util
            spec = importlib.util.spec_from_file_location('homelib_office_images', Path(__file__).with_name('office_inputs.py'))
            self._image_decoder = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self._image_decoder)
        return self._image_decoder

    def image(self, data, mime=''):
        if len(data) > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        import hashlib
        original_key = hashlib.sha256(data).hexdigest()
        if original_key in self.images:
            return self.el('img', src=self.images[original_key], alt='')
        if self.static_gifs and data.startswith((b'GIF87a', b'GIF89a')):
            import sys
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            try:
                from gif_static import first_frame, GifFrameDecoder, WARNING
                resources = getattr(self, 'work_resources', None)
                if resources is None:
                    data = first_frame(self.c, data, self.tools_root, self.work_root, self.cancel_check)
                else:
                    if not hasattr(self, '_gif_decoder'):
                        self._gif_decoder = resources.enter_context(
                            GifFrameDecoder(self.c, self.tools_root, self.work_root, self.cancel_check))
                    data = self._gif_decoder.decode(data)
                self.warnings.add(WARNING)
            finally:
                sys.path.pop(0)
        signatures = [(b'\x89PNG\r\n\x1a\n', 'image/png', '.png'), (b'\xff\xd8\xff', 'image/jpeg', '.jpg'),
                      (b'GIF8', 'image/gif', '.gif')]
        match = next((s for s in signatures if data.startswith(s[0])), None)
        if mime == 'image/svg+xml':
            self.c.validate_epub_inline_svg(data)
            match = (b'', mime, '.svg')
        if match is None:
            data = self.office_image_decoder().rasterize_image(self, data)
            match = signatures[0]
        if len(data) > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        key = hashlib.sha256(data).hexdigest()
        if key not in self.images:
            self.total += len(data)
            limit = self.c.MAX_SCAN_EPUB_RESOURCES if self.image_store is not None else self.c.MAX_TOTAL
            if self.total > limit:
                if self.image_export and self.image_export['profile'] in {'original', 'high', 'balanced', 'economy'}:
                    self.fail('Изображения книги превышают предел конвертации. Выберите более сильное сжатие изображений или сохраните книгу в исходном формате.')
                self.fail('Иллюстрации книги превышают предел конвертации.')
            path = 'images/' + key[:32] + match[2]
            if self.image_store is not None:
                # The writer releases each staged resource as it goes. Leave
                # room for the largest member, ZIP overhead and book markup.
                if shutil.disk_usage(self.image_store).free < len(data) + 128 * 1024 * 1024:
                    self.fail('Недостаточно места для сохранения изображений в EPUB. Выберите папку с большим запасом места.')
                resource = self.image_store / Path(path).name
                resource.write_bytes(data)
                data = resource
            self.resources[path] = (data, match[1]); self.images[key] = path
        self.images[original_key] = self.images[key]
        return self.el('img', src=self.images[key], alt='')

    def local_image(self, href):
        if href.startswith('data:'):
            header, sep, payload = href.partition(',')
            if not sep or ';base64' not in header:
                self.fail('Изображение data: должно использовать base64.')
            try:
                data = base64.b64decode(payload, validate=True)
            except ValueError:
                return self.unreadable_image()
            return self.optional_image(data)
        parts = urlsplit(href)
        if parts.scheme or parts.netloc:
            return self.unreadable_image(parts.path)
        relative = unquote(parts.path)
        if '\\' in relative or '\x00' in relative:
            self.fail('Некорректный путь изображения.')
        path = (self.resource_root / relative).resolve()
        if not path.is_relative_to(self.resource_scope):
            self.fail('Не найдено локальное изображение: ' + href[:200])
        if not path.is_file():
            return self.unreadable_image(relative)
        if path.stat().st_size > 16 * 1024 * 1024:
            self.fail('Изображение превышает 16 МБ.')
        return self.optional_image(path.read_bytes(), relative)

    def unreadable_image(self, resource=''):
        self.unreadable_images += 1
        path = unquote(resource).replace('\\', '/')
        filename = posixpath.basename(path)
        filename = ''.join(ch for ch in filename if ch.isprintable()).strip()[:100]
        record = re.fullmatch(r'homelibre-missing-mobi-image-(\d+)\.img', filename)
        detail = f' Отсутствует запись MOBI № {record[1]}.' if record else (f' Файл «{filename}».' if filename else '')
        if path.endswith('/'):
            directory = ''.join(ch for ch in path if ch.isprintable())[:100]
            detail = f' Адрес «{directory}» указывает на папку без имени файла.'
        self.warnings.add('Часть изображений исходника недоступна. На их местах стоят отметки.')
        self.warnings.add(f'Изображение {self.unreadable_images} недоступно.' + detail)
        return self.el('span', f'[Изображение {self.unreadable_images} недоступно.]')

    def optional_image(self, data, resource=''):
        try:
            name = posixpath.basename(resource.replace('\\', '/'))
            data, note = self.c.recover_book_jpeg(data, self.warnings, name, self.cancel_check)
            self.c.check_embedded_raster(data)
            picture = self.image(data)
            if note and self.c.tag(picture) == 'img':
                picture.tail = f' [{note}]'
            return picture
        except self.c.UnreadableImage:
            return self.unreadable_image(resource)

    def clean_xml_text(self, root):
        # Resolve text properties from XML, where surrogate escapes are invalid.
        controls = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]')
        for n in root.iter():
            for prop in ('text', 'tail'):
                value = getattr(n, prop)
                if value is not None:
                    raw = value.encode('utf-16-le', errors='surrogatepass')
                    try:
                        value = raw.decode('utf-16-le')
                    except UnicodeDecodeError:
                        value = raw.decode('utf-16-le', errors='replace')
                        self.warnings.add('Нечитаемые символы исходника отмечены знаком �.')
                    value, replacements = controls.subn('\ufffd', value)
                    if replacements:
                        self.warnings.add('Нечитаемые символы исходника отмечены знаком �.')
                    setattr(n, prop, value)

    def finish(self, output):
        if self.scan_export is not None: self.scan_export.finish()
        c = self.c
        outline = []
        if self.section_store is None:
            if not any(text.strip() for text in self.body.itertext()) and not any(c.tag(n) == 'img' for n in self.body.iter()):
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
            flow.clear()
            if self.page_outline:
                headings_in_body = (self.image_export or {}).get('target') == '.fb2'
                pages = {page.get('id'): page for page in self.body if c.tag(page) == 'section'}
                page_headings = []
                for index, (target, label, depth) in enumerate(self.page_outline, 1):
                    if isinstance(target, str):
                        # An EPUB table of contents must point inside the spine.
                        # Put the original web link in a readable section of the book.
                        identity = f'outline-link-{index}'
                        section = self.el('section', id=identity)
                        section.append(self.el(f'h{min(depth, 6)}', label))
                        paragraph = self.el('p')
                        paragraph.append(self.el('a', target, href=target))
                        section.append(paragraph)
                        self.body.append(section)
                    else:
                        identity = f'page-{target}'
                        if headings_in_body and identity in pages:
                            page_headings.append((pages[identity], self.el(f'h{min(depth, 6)}', label)))
                    outline.append((identity, label, depth))
                for page, heading in reversed(page_headings):
                    page.insert(0, heading)
            self.clean_xml_text(self.body)

        def sections():
            if self.section_store is None:
                yield from self.body
            else:
                for path in self.section_store:
                    if self.cancel_check is not None:
                        self.cancel_check()
                    yield ET.parse(path).getroot()

        def heading_parts(node):
            if node.text:
                yield node.text
            for child in node:
                if c.tag(child) == 'br':
                    yield ' '
                else:
                    yield from heading_parts(child)
                if child.tail:
                    yield child.tail

        ids = set(); headings = []
        has_content = False
        for section in sections():
            has_content = has_content or any(text.strip() for text in section.itertext())
            for node in section.iter():
                has_content = has_content or c.tag(node) == 'img'
                identity = node.get('id')
                if identity:
                    if identity in ids: self.fail('В документе повторяется идентификатор: ' + identity)
                    ids.add(identity)
        if not has_content:
            self.fail('В документе нет текста или изображений для конвертации.')
        if self.page_outline is not None:
            headings = [(identity, label, depth) for identity, label, depth in outline if identity in ids]
        elif self.document_outline:
            headings = [(identity, label, depth) for identity, label, depth in self.document_outline if identity in ids]
            if len(headings) != len(self.document_outline):
                self.warnings.add(c.MOBI_NAVIGATION_LOSS + '. Некоторые адреса в исходном оглавлении недоступны.')
        # Large scanned books can contain hundreds of thousands of paragraph
        # nodes. Keep each generated XHTML within the reader's parsing bounds.
        parts = []
        part = self.el('body')
        part_nodes = 0

        def save_part():
            if self.section_store is None:
                parts.append(part)
            else:
                path = self.image_store / f'body-part-{len(parts)}.xml'
                ET.ElementTree(part).write(path, encoding='utf-8')
                parts.append(path)

        targets = {}
        for section in sections():
            count = sum(1 for _ in section.iter())
            if part_nodes and (self.framed_pages is not None or part_nodes + count > 100000):
                save_part()
                part = self.el('body')
                part_nodes = 0
            name = 'book.xhtml' if not parts else f'book-{len(parts) + 1}.xhtml'
            for node in section.iter():
                level = c.html_heading_level(node) if self.page_outline is None and not self.document_outline else 0
                if level and (label := ''.join(heading_parts(node)).strip()):
                    identity = node.get('id')
                    if not identity:
                        identity = 'heading-' + str(len(headings) + 1)
                        while identity in ids: identity += '-h'
                        node.set('id', identity); ids.add(identity)
                    headings.append((identity, label, level))
                if identity := node.get('id'):
                    targets[identity] = name
            part.append(section)
            part_nodes += count
        save_part()
        if self.section_store is not None:
            part.clear()
        ids.clear()
        names = ['book.xhtml'] + [f'book-{n}.xhtml' for n in range(2, len(parts) + 1)]
        if self.image_store is not None:
            self.body.clear()
        for index, (name, part) in enumerate(zip(names, parts)):
            if isinstance(part, Path):
                path = part
                part = ET.parse(path).getroot()
                path.unlink()
                if self.cancel_check is not None:
                    self.cancel_check()
            for node in part.iter('{' + c.XH + '}a'):
                href = node.get('href', '')
                if href.startswith('#'):
                    target = targets.get(unquote(href[1:]))
                    if target is None:
                        node.attrib.pop('href')
                        self.warnings.add(f'Не найдена цель внутренней ссылки «{href[:160]}». Текст ссылки сохранён.')
                    elif target != name:
                        node.set('href', target + href)
            c.layout_margin_rules(part)
            html = self.el('html', lang=self.language)
            head = self.el('head'); head.append(self.el('title', self.title))
            head.append(self.el('link', rel='stylesheet', href='book.css', type='text/css'))
            if self.framed_pages is not None:
                width, height = self.framed_pages[index]
                viewport = self.el('meta', content=f'width={width}, height={height}')
                viewport.set('name', 'viewport')
                head.append(viewport)
                part.set('class', 'word-frame-page')
            html.extend([head, part])
            if self.image_store is not None:
                content = self.image_store / name
                ET.ElementTree(html).write(content, encoding='utf-8', xml_declaration=True)
                part.clear()
            else:
                content = c.serialized(html)
            self.resources[name] = (content, 'application/xhtml+xml')
        css = 'body{line-height:1.35}p{margin:.45em 0}h1,h2,h3,h4,h5,h6{text-align:center}img{max-width:100%;height:auto}pre{white-space:pre-wrap}table{border-collapse:collapse}td,th{padding:.2em .4em}'
        css += f'.{c.TEXT_FRAME_STYLE}{{{c.TEXT_FRAME_CSS}}}'
        if self.framed_pages is not None:
            css += 'body.word-frame-page,body.word-frame-page p{margin:0}body.word-frame-page img{display:block;width:100%}'
        self.resources['book.css'] = (css.encode(), 'text/css')
        nav = self.el('html', lang=self.language); nh = self.el('head'); nh.append(self.el('title', 'Содержание')); nav.append(nh)
        nb = self.el('body'); nav.append(nb); nt = self.el('nav', **{'{' + c.EP + '}type': 'toc'}); nb.append(nt)
        nt.append(self.el('h1', 'Содержание'))
        c.append_navigation_list(nt, [(targets[identity] + '#' + identity, label, depth)
                                      for identity, label, depth in headings] or [(names[0], self.title, 1)],
                                 start_only=not headings)
        self.resources['nav.xhtml'] = (c.serialized(nav), 'application/xhtml+xml')
        package = c.element(c.OP, 'package', version='3.0', **{'unique-identifier': 'book-id'})
        meta = c.element(c.OP, 'metadata'); package.append(meta)
        if self.publication_metadata is not None:
            meta.extend(self.publication_metadata)
            if any(n.get('property', '').startswith('mhl:') for n in meta):
                package.set('prefix', 'mhl: ' + c.MHL)
        book_id = c.fb3_document_id(self.fb3_description) if self.fb3_description is not None else ''
        if not any(n.get('id') == 'book-id' for n in meta):
            meta.insert(0, c.element(c.DC, 'identifier', 'urn:uuid:' + (book_id or str(uuid.uuid4())), id='book-id'))
        for name, value in (('title', self.title), ('language', self.language)):
            if value and c.first(meta, name) is None:
                meta.append(c.element(c.DC, name, value))
        if self.fb3_description is not None:
            package.set('prefix', 'mhl: ' + c.MHL)
            c.write_epub_fb3_metadata(meta, self.fb3_description)
        if self.author and c.first(meta, 'creator') is None:
            meta.append(c.element(c.DC, 'creator', self.author))
        meta.append(c.element(c.OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), property='dcterms:modified'))
        if self.framed_pages is not None:
            meta.append(c.element(c.OP, 'meta', 'pre-paginated', property='rendition:layout'))
        manifest = c.element(c.OP, 'manifest'); package.append(manifest)
        for index, (name, (_, mime)) in enumerate(self.resources.items()):
            attrs = {'id': 'r' + str(index), 'href': name, 'media-type': mime}
            if name == getattr(self, 'cover_image', None): attrs['properties'] = 'cover-image'
            if name == 'nav.xhtml': attrs['properties'] = 'nav'
            manifest.append(c.element(c.OP, 'item', **attrs))
        spine = c.element(c.OP, 'spine'); package.append(spine)
        manifest_ids = {node.get('href'): node.get('id') for node in manifest}
        for name in names:
            spine.append(c.element(c.OP, 'itemref', idref=manifest_ids[name]))
        container = c.element(c.CN, 'container', version='1.0'); roots = c.element(c.CN, 'rootfiles'); container.append(roots)
        roots.append(c.element(c.CN, 'rootfile', **{'full-path': 'OEBPS/package.opf', 'media-type': 'application/oebps-package+xml'}))
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            archive.writestr('META-INF/container.xml', c.serialized(container)); archive.writestr('OEBPS/package.opf', c.serialized(package))
            resource_count = len(self.resources)
            if self.image_store is not None:
                self.progress('writing-epub', 0, resource_count)
            for index, (name, (data, _)) in enumerate(self.resources.items(), 1):
                if isinstance(data, Path):
                    archive.write(data, 'OEBPS/' + name)
                    if self.image_store is not None and data.parent == self.image_store:
                        data.unlink()
                else:
                    archive.writestr('OEBPS/' + name, data)
                if self.image_store is not None and (index % 8 == 0 or index == resource_count):
                    self.progress('writing-epub', index, resource_count)


def empty_layout_image(attrs, raw):
    source=(attrs.get('src') or '').strip()
    dimensions={name:(attrs.get(name) or '').strip() for name in ('width','height')}
    missing=not source
    if not missing:
        # Old CHM menus contain <img height=1 src= width=4>. Keep quoted
        # literal filenames such as src="width=4" as real resource paths.
        tokens=re.findall(r'''[^\s/>=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?''',raw)
        for token in tokens:
            match=re.fullmatch(r'src\s*=\s+(width|height)=(\d{1,4})',token,re.I)
            if match and source.lower()==match[1].lower()+'='+match[2]:
                dimensions[match[1].lower()]=match[2];missing=True;break
    try: width,height=(int(dimensions[name]) for name in ('width','height'))
    except ValueError:return False
    return (missing and not (attrs.get('alt') or '').strip() and
            (attrs.get('border') or '0').strip()=='0' and
            min(width,height)==1 and 0<width*height<=32)


class HTMLInput(HTMLParser):
    VOID = {'br', 'hr', 'img', 'meta', 'link', 'input', 'source', 'wbr', 'area', 'base', 'embed', 'param', 'col'}
    BLOCK = {'p', 'div', 'section', 'article', 'blockquote', 'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'pre', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr'}
    def __init__(self, book, root=None):
        super().__init__(convert_charrefs=True)
        self.b = book; self.stack = [('root', book.body if root is None else root, 0)]
        self.hidden = []; self.in_head = False; self.title = []; self.in_title = False; self.nodes = 0
        self.named_anchors=set()

    def empty_layout_image(self, attrs):
        return empty_layout_image(attrs,self.get_starttag_text() or '')

    def handle_starttag(self, name, attrs):
        attrs = dict(attrs)
        if self.hidden:
            if name not in self.VOID: self.hidden.append(name)
            return
        # The static reading view can show the fallback in the document body.
        if name in {'script', 'style', 'iframe', 'object', 'embed', 'template'} or (name == 'noscript' and self.in_head):
            self.b.warnings.add('Сценарии, внешние стили и встроенные объекты HTML не переносятся.')
            if name not in self.VOID: self.hidden.append(name)
            return
        if name == 'head': self.in_head = True; return
        if name == 'title': self.in_title = True; return
        if name == 'html':
            self.b.language = attrs.get('lang') or attrs.get('xml:lang') or self.b.language; return
        if name in {'meta', 'link', 'base'}: return
        # In old HTML the closing head and opening body tags are often omitted.
        # Rendering content implicitly closes the head, just as in a browser.
        self.in_head = False
        if name == 'body': return
        if name in {'dt', 'dd'}:
            for at in range(len(self.stack) - 1, 0, -1):
                opened = self.stack[at][0]
                if opened in {'dt', 'dd'}:
                    del self.stack[at:]
                    break
                if opened in self.BLOCK and opened != 'p': break
        if self.nodes > 500000: self.b.fail('HTML слишком сложен для конвертации.')
        self.nodes += 1
        if name in self.BLOCK and self.stack[-1][0] == 'p': self.stack.pop()
        if name == 'li' and self.stack[-1][0] == 'li': self.stack.pop()
        mapped = {'b': 'strong', 'i': 'em', 'strike': 's', 'font': 'span', 'center': 'div'}.get(name, name)
        allowed = self.BLOCK | {'a', 'strong', 'em', 's', 'u', 'span', 'sub', 'sup', 'code', 'br', 'img', 'caption', 'aside', 'header', 'footer', 'figure', 'figcaption'}
        if mapped not in allowed: mapped = 'span'
        if mapped == 'img':
            image_url = attrs.get('src') or ''
            description = (attrs.get('alt') or '').strip()
            if (attrs.get('width') == attrs.get('height') == '1' and not description
                    and (image_url.startswith('//') or urlsplit(image_url).scheme.lower() in {'http', 'https'})
                    and not getattr(self.b, 'has_embedded_html_image', lambda _: False)(image_url)):
                self.b.warnings.add('Внешнее изображение размером 1 × 1 пропущено.')
                return
            if self.empty_layout_image(attrs):
                self.b.warnings.add('Пустое служебное изображение HTML заменено пробелом.')
                node = self.b.el('span', ' ')
            elif not image_url.strip():
                node = self.b.el('span', description)
            else:
                layout_image = getattr(self.b, 'local_layout_image', None)
                sidebar_image = getattr(self.b, 'local_sidebar_image', None)
                title = attrs.get('title')
                if (sidebar_image is not None and image_url == '_.gif' and attrs.get('width') == '1'
                        and attrs.get('height') == '2' and title in {'Start Sidebar', 'End Sidebar'}
                        and 'bluecell' in next((cell.get('class', '') for tag, cell, _ in reversed(self.stack)
                                                if tag in {'td', 'th'}), '').split()):
                    node = sidebar_image(image_url)
                    if self.b.c.tag(node) == 'img':
                        node.set('title', title)
                elif (layout_image is not None and self.stack[-1][0] == 'td'
                        and attrs.get('width') == attrs.get('height') == '1'
                        and (attrs.get('border') or '0').strip() == '0'
                        and not any(attrs.get(key) for key in ('alt', 'title', 'aria-label', 'aria-labelledby',
                            'aria-describedby', 'longdesc', 'srcset', 'class', 'style', 'hspace', 'vspace'))):
                    node = layout_image(image_url)
                else:
                    node = self.b.local_image(image_url)
                if description:
                    if self.b.c.tag(node) == 'img':
                        node.set('alt', description)
                    else:
                        self.b.c.append_text(node, ' ' + description)
                if self.b.c.tag(node) == 'img':
                    for dimension in ('width', 'height'):
                        pixels = self.b.c.html_image_pixels(attrs.get(dimension))
                        if pixels:
                            node.set(dimension, str(pixels))
        else:
            node = self.b.el(mapped)
        keys = ['id', 'class']
        if name == 'table' and attrs.keys() <= {'id', 'width', 'border', 'cellpadding', 'cellspacing'}:
            if ((attrs.get('width') or '').strip() == '100%' and attrs.get('border', '0') == '0' and
                    attrs.get('cellpadding') == '0' and attrs.get('cellspacing') == '0'):
                node.set('data-homelib-layout-wrapper', '1')
        if mapped in {'td', 'th'}: keys += ['colspan', 'rowspan']
        if mapped == 'ol': keys.append('start')
        if mapped == 'li' and next((name for name, _, _ in reversed(self.stack) if name in {'ol', 'ul'}), '') == 'ol': keys.append('value')
        for key in keys:
            if attrs.get(key): node.set(key, attrs[key])
        if mapped == 'p':
            if attrs.get('role') == 'heading' and (level := attrs.get('aria-level')) in {'1', '2', '3', '4', '5', '6', '7', '8', '9'}:
                node.set('role', 'heading')
                node.set('aria-level', level)
            if level := self.b.c.html_heading_level(node):
                node.set('role', 'heading')
                node.set('aria-level', str(level))
        if name == 'a':
            if (legacy_name := attrs.get('name')) and legacy_name != node.get('id'):
                target = node
                if node.get('id'):
                    if self.nodes >= 500000: self.b.fail('HTML слишком сложен для конвертации.')
                    self.nodes += 1
                    target = self.b.el('span')
                    node.append(target)
                target.set('id', legacy_name)
                self.named_anchors.add(target)
            href = attrs.get('href', '')
            if 'href' in attrs and hasattr(self.b, 'local_link'): node.set('href', self.b.local_link(href))
            elif href.startswith('#') or urlsplit(href).scheme.lower() in {'https', 'http', 'mailto'}: node.set('href', quote(href, safe=":/?#[]@!$&'()*+,;=%"))
            elif href: self.b.warnings.add('Ссылки на другие локальные HTML-файлы не перенесены; конвертируется выбранный документ.')
        # Preserve only text formatting; no url(), imports or executable CSS.
        declarations = []
        for key, value in re.findall(r'([\w-]+)\s*:\s*([^;]+)', attrs.get('style', '')):
            if key.lower() in {'font-weight', 'font-style', 'text-decoration', 'text-align', 'vertical-align', 'white-space'} and re.fullmatch(r'[\w\s%-]+', value):
                declarations.append(key.lower() + ':' + value)
        if name == 'center': declarations.append('text-align:center')
        if declarations: node.set('style', ';'.join(declarations))
        opened, parent, span_count = self.stack[-1]
        # Legacy documents can stack hundreds of anonymous inline wrappers
        # with no attributes that survive conversion. Count each closing tag
        # without growing a subtree of identically styled spans.
        if name == opened == 'span' and not (node.attrib or parent.attrib):
            self.stack[-1] = (opened, parent, span_count + 1)
            return
        if len(self.stack) > 128: self.b.fail('HTML слишком сложен для конвертации.')
        parent.append(node)
        if name not in self.VOID: self.stack.append((name, node, 0))

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
            opened, node, span_count = self.stack[at]
            if opened != name: continue
            if span_count:
                self.stack[at] = (opened, node, span_count - 1)
                del self.stack[at + 1:]
            else:
                del self.stack[at:]
            break

    def handle_data(self, value):
        if self.hidden: return
        if self.in_title: self.title.append(value)
        elif not self.in_head or value.strip():
            self.in_head = False
            self.b.c.append_text(self.stack[-1][1], value)


def repair_empty_layout_images(text, book):
    """Recognize original empty src before HTML5 turns it into a quoted URL."""
    class Repair(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.parts=[];self.last=0;self.line=1;self.line_start=0;self.nodes=0
        def handle_starttag(self,name,attrs):
            self.nodes+=1
            if self.nodes>500000:book.fail('HTML слишком сложен для конвертации.')
            attrs=dict(attrs);raw=self.get_starttag_text() or ''
            if name!='img' or not empty_layout_image(attrs,raw):return
            line,column=self.getpos()
            while self.line<line:
                self.line_start=text.index('\n',self.line_start)+1;self.line+=1
            at=self.line_start+column
            self.parts.append(text[self.last:at])
            attributes=''.join(' '+key+'="'+html.escape(attrs[key],quote=True)+'"'
                               for key in ('id','class') if attrs.get(key))
            self.parts.append('<span'+attributes+'> </span>');self.last=at+len(raw)
            book.warnings.add('Пустое служебное изображение HTML заменено пробелом.')
    parser=Repair();parser.feed(text);parser.close()
    if not parser.parts:return text
    parser.parts.append(text[parser.last:]);return ''.join(parser.parts)


def deduplicate_anchors(book, named_anchors=()):
    # Preserve the first target and keep later marks distinct. HTML treats
    # explicit IDs as targets before its legacy named anchors.
    reserved={node.get('id') for node in book.body.iter() if node.get('id')}
    first={};numbers={};renamed=0
    for node in book.body.iter():
        identity=node.get('id')
        if not identity:continue
        if identity not in first or (first[identity] in named_anchors and node not in named_anchors):
            first[identity]=node
    for node in book.body.iter():
        identity=node.get('id')
        if not identity or first[identity] is node:continue
        number=numbers.get(identity,2);candidate=identity+'-homelibre-'+str(number)
        while candidate in reserved:
            number+=1;candidate=identity+'-homelibre-'+str(number)
        node.set('id',candidate);reserved.add(candidate);numbers[identity]=number+1;renamed+=1
    return renamed


def read_html(book, data, html5=False):
    declaration = re.search(br'<meta\b[^>]*charset\s*=\s*[\'\"]?\s*([\w-]+)', data[:8192], re.I)
    encoding = declaration[1].decode('ascii') if declaration else None
    if encoding and (alias := re.fullmatch(r'win(?:dows)?[-_]?(125[0-8])', encoding, re.I)):
        encoding = 'cp' + alias[1]
    try:
        text = decode(data, encoding or 'utf-8-sig')
    except UnicodeDecodeError:
        encoding = encoding or 'cp1251'
        text = data.decode(encoding, errors='replace')
    if '\ufffd' in text:
        book.warnings.add('Нечитаемые символы HTML отмечены знаком �.')
    if html5:
        text=repair_empty_layout_images(text,book)
        import sys
        vendor = str(Path(__file__).with_name('vendor')); sys.path.insert(0, vendor)
        try:
            import html5lib
            tree = html5lib.parse(text, namespaceHTMLElements=False)
            text = html5lib.serialize(tree, quote_attr_values='always', omit_optional_tags=False)
        finally: sys.path.remove(vendor)
    parser = HTMLInput(book); parser.feed(text); parser.close()
    renamed = deduplicate_anchors(book, parser.named_anchors)
    if renamed:book.warnings.add('Повторяющиеся метки переходов HTML переименованы: '+str(renamed)+'. Ссылки ведут к первой метке.')
    if (encoding and not data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE, codecs.BOM_UTF8))
            and not codecs.lookup(encoding).name.startswith('utf-')):
        anchors = {node.get('id') for node in book.body.iter() if node.get('id')}
        for link in book.body.iter('{' + book.c.XH + '}a'):
            href = link.get('href', '')
            if not href.startswith('#') or '%' not in href or unquote(href[1:]) in anchors:
                continue
            # Old generators escaped fragments in the document's code page.
            # Some also wrote spaces as '+'. Keep a real literal '+' first.
            fragment = href[1:]
            for encoded in (fragment, fragment.replace('+', ' ')):
                try:
                    target = unquote(encoded, encoding=encoding, errors='strict')
                except UnicodeDecodeError:
                    break
                if target in anchors:
                    link.set('href', '#' + quote(target, safe=''))
                    break
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
        # Markdown permits static HTML (including the anchors emitted by our
        # writer). All of it still goes through HTMLInput's active-content,
        # attribute and local-resource checks before entering the reading book.
        parser = mistune.create_markdown(escape=False, plugins=['table', 'footnotes', 'strikethrough', 'url'])
        html = parser(decode_plain_text(data, book.warnings))
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


def fb3_part_lookup(package):
    def key(path):
        decoded = unquote(path).lstrip('/')
        name = posixpath.normpath(decoded)
        if name in {'.', '..'} or name.startswith('../') or any(char in decoded for char in '\\:\x00'):
            return None
        return name.casefold()

    names = {}
    ambiguous = set()
    for name in package.names:
        if name.endswith('/') or (canonical := key(name)) is None:
            continue
        if canonical in names:
            ambiguous.add(canonical)
        names[canonical] = name

    def resolve(target, source=''):
        path = target if target.startswith('/') else posixpath.join(posixpath.dirname(source), target)
        canonical = key(path)
        return None if canonical in ambiguous else names.get(canonical)

    return resolve


FB3_SVG_DTD = re.compile(
    br'''(?m)^[ \t]*<!DOCTYPE\s+svg\s+PUBLIC\s+["']-//W3C//DTD SVG 1\.1//EN["']\s+'''
    br'''["']https?://www\.w3\.org/Graphics/SVG/1\.1/DTD/svg11\.dtd["']\s*>[ \t]*(?:\r?\n)?''')


def fb3_image(book, data, resource):
    if re.search(br'<(?:[\w.-]+:)?svg\b', data[:4096].replace(b'\0', b'')):
        try:
            static, declarations = FB3_SVG_DTD.subn(b'', data, count=1)
            picture = book.image(static, 'image/svg+xml')
            if declarations:
                book.warnings.add('Из SVG в FB3 удалена ссылка на внешнюю схему W3C. Разметка рисунка сохранена.')
            return picture
        except book.c.UnreadableImage:
            return book.unreadable_image(resource)
    return book.optional_image(data, resource)


def read_fb3(book):
    p = Package(book); c = book.c
    namespace = 'http://www.fictionbook.org/FictionBook3/body'
    try:
        find_part = fb3_part_lookup(p)
        parts = c.fb3_declared_parts(p.z)
        part = find_part(parts.get('body', 'fb3/body.xml'))
        if part is None:
            book.fail('В FB3 не найдена однозначная часть с текстом книги.')
        root = p.xml(part)
        rels = p.relationships(part, resolve_part=find_part)
        if root.tag != '{' + namespace + '}fb3-body': book.fail('В FB3 не найден основной текст.')
        description_part = find_part(parts.get('description', 'fb3/description.xml'))
        try:
            description = p.xml(description_part, True)
        except (c.ConversionError, zipfile.BadZipFile):
            description = None
        if description is not None and c.tag(description) == 'fb3-description':
            book.fb3_description = description
            book.title = c.fb3_title(c.first(description, 'title')) or book.title
            book.language = c.plain(c.first(description, 'lang')) or book.language
        elif 'description' in parts or description_part is not None:
            book.warnings.add('Описание FB3 недоступно. Сведения о книге сохранены из каталога, если они заданы.')
        if not book.omit_images:
            root_rels = p.xml(find_part('_rels/.rels'), True)
            thumbnails = [node for node in (() if root_rels is None else root_rels)
                          if node.get('Type') == 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail']
            if len(thumbnails) == 1:
                thumbnail = thumbnails[0]
                resource = find_part(thumbnail.get('Target', '')) if thumbnail.get('TargetMode') != 'External' else None
                if resource is not None:
                    cover = fb3_image(book, p.data(resource), resource)
                    book.cover_image = cover.get('src')
                if not getattr(book, 'cover_image', None):
                    book.warnings.add('Повреждённая или недоступная обложка FB3. Текст книги сохранён.')
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
            if name in {'br', 'clipped', 'paper-page-break'}:
                if name == 'br' and (len(node) or (node.text or '').strip()):
                    book.fail('В FB3 внутри переноса строки обнаружено содержимое.')
                if name == 'clipped': book.warnings.add('Исходный FB3 содержит сокращённый фрагмент книги.')
                return book.el('br')
            if name == 'img':
                reference = node.get('src', '')
                resource, external = rels.get(reference, (None, False))
                if resource is None or external:
                    out = book.unreadable_image(resource or reference)
                else:
                    out = fb3_image(book, p.data(resource), resource)
                if c.tag(out) == 'img':
                    out.set('alt', node.get('alt', ''))
                elif alt := node.get('alt', '').strip():
                    c.append_text(out, ' ' + alt)
            elif name == 'title':
                out = book.el('p' if in_note else 'h' + str(min(6, max(1, depth))))
                if identity := node.get('id'):
                    out.set('id', identity)
                for index, child in enumerate(node):
                    if index: out.append(book.el('br'))
                    if identity := child.get('id'):
                        out.append(book.el('span', id=identity))
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
        if renamed := deduplicate_anchors(book):
            book.warnings.add(f'Повторяющиеся метки FB3 переименованы ({renamed}). Ссылки ведут к первой метке.')
        book.warnings.add('Оформление FB3 адаптировано к электронной книге; точная страничная вёрстка и встроенные шрифты не переносятся.')
    finally: p.z.close()


class Package:
    def __init__(self, book, streamed_part=None):
        self.b = book; self.z = zipfile.ZipFile(book.source); self.names = {}; total = 0
        try:
            if len(self.z.infolist()) > book.c.MAX_ENTRIES: book.fail('В документе слишком много ресурсов.')
            for item in self.z.infolist():
                if item.filename in self.names: book.fail('В документе повторяется имя ресурса: ' + item.filename)
                self.names[item.filename] = item; total += item.file_size
                limit = book.c.MAX_TOTAL if item.filename == streamed_part else book.c.MAX_FILE
                if item.file_size > limit or total > book.c.MAX_TOTAL or item.flag_bits & 1:
                    book.fail('Документ зашифрован или превышает предел распаковки.')
        except BaseException:
            self.z.close(); raise
    def data(self, path):
        if path not in self.names: self.b.fail('Не найден ресурс документа: ' + path)
        return self.z.read(path)
    def xml(self, path, optional=False):
        if optional and path not in self.names: return None
        return self.b.c.xml(self.data(path))
    def relationships(self, part, resolve_part=None, *, typed_parts=None):
        path = posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')
        if resolve_part is not None:
            path = resolve_part(path)
        root = self.xml(path, True); result = {}
        if root is not None:
            for node in root:
                href = node.get('Target', ''); external = node.get('TargetMode') == 'External'
                if resolve_part is not None:
                    identity = node.get('Id')
                    relation = (href if external else resolve_part(href, part), external)
                    result[identity] = relation if result.get(identity, relation) == relation else (None, False)
                    continue
                decoded = unquote(href)
                # OPC absolute part names start at the package root, not the
                # filesystem root. DocSharp and Word both emit these forms.
                dest = href if external else posixpath.normpath(decoded.lstrip('/') if decoded.startswith('/') else posixpath.join(posixpath.dirname(part), decoded))
                if not external and (dest.startswith('../') or '\\' in dest or ':' in dest or '\x00' in dest): self.b.fail('Некорректный путь ресурса DOCX.')
                result[node.get('Id')] = (dest, external)
                if typed_parts is not None:
                    kind = node.get('Type', '').rsplit('/', 1)[-1]
                    if kind in typed_parts:
                        typed_parts[kind] = None if external else dest
        return result


def read_docx_blocks(book, package, part, container, container_depth, consume, start_table=None):
    """Read individual body or note blocks, keeping only one source subtree.

    In the body, top-level tables are streamed a row at a time. Package,
    depth and subtree limits also apply to each note definition.
    """
    child_depth = container_depth + 1

    class BlockParser:
        depth = block_depth = block_nodes = 0
        seen_container = in_container = False
        block = table = None

        def start(self, tag, attrs):
            self.depth += 1
            if self.depth > 129:
                book.fail('XML книги слишком сложен для конвертации.')
            if self.depth == container_depth and tag == f'{{{W}}}{container}':
                if self.seen_container: book.fail(f'В DOCX повторяется раздел «{part}».')
                self.seen_container = self.in_container = True
            if start_table is not None and self.in_container and self.depth == child_depth and tag == f'{{{W}}}tbl':
                self.table = start_table()
                return
            if self.in_container and self.depth == child_depth + (self.table is not None):
                self.block = ET.TreeBuilder()
                self.block_depth = self.depth
                self.block_nodes = 0
            if self.block is not None:
                self.block_nodes += 1
                if self.block_nodes > 500000:
                    book.fail('Один блок DOCX слишком сложен для конвертации.')
                self.block.start(tag, attrs)

        def end(self, tag):
            if self.block is not None:
                self.block.end(tag)
                if self.depth == self.block_depth:
                    node = self.block.close()
                    self.block = None
                    (self.table if self.table is not None else consume)(node)
            if self.depth == child_depth: self.table = None
            if self.depth == container_depth: self.in_container = False
            self.depth -= 1

        def data(self, text):
            if self.block is not None: self.block.data(text)

        def doctype(self, name, public_id, system_id):
            book.fail('Объявления DTD в DOCX не поддерживаются.')

        def close(self):
            if not self.seen_container: book.fail(f'В DOCX отсутствует разметка раздела «{part}».')

    if part not in package.names: book.fail('Не найден ресурс документа: ' + part)
    parser = ET.XMLParser(target=BlockParser())
    chunk_size = 65536
    main_body = container == 'body'
    total = (package.names[part].file_size + chunk_size - 1) // chunk_size if main_body else 0
    stage = 'preparing-docx' if main_body else 'preparing-docx-notes'
    try:
        with package.z.open(part) as source:
            completed = 0
            if total:
                book.progress(stage, 0, total)
            while chunk := source.read(chunk_size):
                parser.feed(chunk)
                completed += 1
                book.progress(stage, completed, total)
        parser.close()
    except (ET.ParseError, LookupError) as error:
        book.fail('Некорректная структура XML: ' + str(error))


_VML = '{urn:schemas-microsoft-com:vml}'
_OFFICE = '{urn:schemas-microsoft-com:office:office}'
_VML_FALSE = {'f', 'false', '0'}


def word_picture_spacer(node, templates):
    """An inline, unpainted picture frame with no picture or alternative text."""
    for template in node.findall(_VML + 'shapetype'):
        identity = template.get('id')
        if identity:
            templates[identity] = (template.get(_OFFICE + 'spt') == '75'
                                   and template.attrib.keys() <= {'id', 'coordsize', 'path', 'filled', 'stroked',
                                                                 _OFFICE + 'spt', _OFFICE + 'preferrelative'}
                                   and all(template.get(flag, '').lower() in _VML_FALSE for flag in ('filled', 'stroked'))
                                   and all(child.tag in {_VML + 'path', _VML + 'formulas', _VML + 'stroke', _OFFICE + 'lock'}
                                           for child in template)
                                   and all(stroke.attrib.keys() <= {'joinstyle'} for stroke in template.findall(_VML + 'stroke')))
    shapes = node.findall(_VML + 'shape')
    if len(shapes) != 1 or any(child.tag not in {_VML + 'shape', _VML + 'shapetype'} for child in node):
        return None
    shape = shapes[0]
    reference = shape.get('type', '')
    if (len(shape) or (shape.text or '').strip() or (shape.get('alt') or '').strip()
            or shape.attrib.keys() - {'id', 'type', 'alt', 'style', 'filled', 'stroked'}
            or not reference.startswith('#') or not templates.get(reference[1:])
            or any(shape.get(flag, 'f').lower() not in _VML_FALSE for flag in ('filled', 'stroked'))):
        return None
    measures = {}
    for part in shape.get('style', '').split(';'):
        if not part.strip(): continue
        match = re.fullmatch(r'\s*(width|height)\s*:\s*([0-9]{1,3}(?:\.[0-9]{1,3})?)pt\s*', part, re.I)
        if not match or match[1].lower() in measures:
            return None
        measures[match[1].lower()] = round(float(match[2]) * 20)
    width, height = measures.get('width', 0), measures.get('height', 0)
    if 10 <= width <= 14400 and 10 <= height <= 14400:
        return width, height


def empty_docx_textbox(node):
    """Recognize an unpainted VML textbox containing only empty paragraphs.

    Filled/stroked default to true. Do not drop text, symbols, fields, images,
    bookmarks or unknown shape children as if they were empty decoration.
    """
    vml = '{urn:schemas-microsoft-com:vml}'
    shapes = [child for child in node if child.tag == vml+'shape']
    if len(shapes) != 1 or any(child.tag not in {vml+'shapetype', vml+'shape'} for child in node):
        return False
    shape = shapes[0]
    if any(shape.get(name, '').lower() not in {'f','false','0'} for name in ('filled','stroked')):
        return False
    boxes = [child for child in shape if child.tag == vml+'textbox']
    if len(boxes) != 1 or any(child.tag not in {vml+'textbox','{urn:schemas-microsoft-com:office:word}wrap'} for child in shape):
        return False
    box = boxes[0]
    if any(name not in {'style','inset'} for name in box.attrib):
        return False
    if any(declaration.strip() and declaration.split(':',1)[0].strip().lower() != 'mso-next-textbox'
           for declaration in box.get('style','').split(';')):
        return False
    if len(box) != 1 or box[0].tag != '{'+W+'}txbxContent':
        return False
    visible_properties = {'{'+W+'}'+name for name in ('pBdr','shd','bdr','numPr')}
    def empty_content(item):
        if (item.text or '').strip() or (item.tail or '').strip():
            return False
        if item.tag == '{'+W+'}t':
            return not len(item)
        if item.tag in {'{'+W+'}pPr','{'+W+'}rPr'}:
            return not any(prop.tag in visible_properties for prop in item.iter())
        return item.tag in {'{'+W+'}txbxContent','{'+W+'}p','{'+W+'}r'} and all(empty_content(child) for child in item)
    return empty_content(box[0])


def docx_white_page_overlay(node):
    """Identify an opaque white VML rectangle above the original page."""
    if len(node) != 1 or node.attrib or node[0].tag != _VML + 'rect':
        return False
    rectangle = node[0]
    if (len(rectangle) or (rectangle.text or '').strip() or
            rectangle.attrib.keys() - {'id', 'type', 'style', 'fillcolor', 'filled', 'stroked', 'strokeweight'} or
            rectangle.get('type', '#_x0000_t1') != '#_x0000_t1' or
            rectangle.get('stroked', '').lower() not in {'f', 'false', '0'} or
            rectangle.get('filled', 't').lower() not in {'t', 'true', '1'} or
            rectangle.get('fillcolor', 'white').lower() not in {'white', '#fff', '#ffffff'}):
        return False
    position = {}
    for part in filter(None, map(str.strip, rectangle.get('style', '').split(';'))):
        key, sep, value = part.lower().partition(':')
        key = key.strip()
        if not sep or key in position:
            return False
        position[key] = value.strip()
    if (position.keys() != {'position', 'mso-position-horizontal-relative', 'mso-position-vertical-relative',
                           'z-index', 'margin-left', 'margin-top', 'width', 'height'} or
            position['position'] != 'absolute' or
            any(position['mso-position-' + axis + '-relative'] != 'page' for axis in ('horizontal', 'vertical')) or
            not re.fullmatch(r'[1-9][0-9]{0,9}', position['z-index'])):
        return False
    distance = r'[+-]?[0-9]{1,4}(?:\.[0-9]{1,4})?pt'
    return (all(re.fullmatch(distance, position[key]) for key in ('margin-left', 'margin-top', 'width', 'height'))
            and all(float(position[key][:-2]) > 0 for key in ('width', 'height')))


def empty_docx_wordart(node):
    """Check for an unpainted, floating VML plain-text WordArt placeholder."""
    vml = '{urn:schemas-microsoft-com:vml}'
    office = '{urn:schemas-microsoft-com:office:office}'
    if len(node) != 2 or node.attrib:
        return False
    preset, shape = node
    if (preset.tag != vml + 'shapetype' or shape.tag != vml + 'shape' or
            preset.get(office + 'spt') != '136' or not preset.get('id') or
            shape.get('type') != '#' + preset.get('id') or
            preset.get('path') != 'm@7,l@8,m@5,21600l@6,21600e' or
            preset.attrib.keys() - {'id', office + 'spt', 'coordsize', 'adj', 'path'} or
            shape.attrib.keys() - {'id', 'type', 'style'}):
        return False
    path = preset.find(vml + 'path')
    template_text = preset.find(vml + 'textpath')
    if (path is None or path.get('textpathok') != 't' or template_text is None or
            (template_text.get('string', '')).strip() or template_text.get('style') or
            any(child.tag not in {vml + name for name in ('path', 'textpath', 'formulas', 'handles')}
                for child in preset)):
        return False
    position = dict(declaration.split(':', 1) for declaration in shape.get('style', '').split(';')
                    if ':' in declaration)
    if (position.get('position') != 'absolute' or
            position.keys() - {'position', 'margin-left', 'margin-top', 'width', 'height', 'z-index'}):
        return False
    paths = shape.findall(vml + 'textpath')
    if len(paths) != 1 or any(child.tag not in {vml + 'textpath', vml + 'shadow'} for child in shape):
        return False
    text = paths[0]
    # A return with the same preset can still paint a thin line.
    return (not len(text) and text.get('string') is not None and
            not text.get('string').strip(' ') and
            not (text.text or '').strip() and
            not text.attrib.keys() - {'string', 'fitpath', 'fitshape', 'trim', 'style', 'on'} and
            all(not declaration.strip() or declaration.split(':', 1)[0].strip().lower() in {'font-family', 'v-text-kern'}
                for declaration in text.get('style', '').split(';')))


def empty_docx_connector(node):
    """Recognize an unpainted floating connector described by both Word branches."""
    word = '{' + W + '}'
    office = '{urn:schemas-microsoft-com:office:office}'
    vml_anchor = '{urn:schemas-microsoft-com:office:word}wrap'
    shape_namespace = WORD_DRAWING_SHAPE.removesuffix('wsp')
    if [child.tag for child in node] != [MC + 'Choice', MC + 'Fallback']:
        return False
    modern, legacy = node
    if ([child.tag for child in modern] != [word + 'drawing'] or
            [child.tag for child in legacy] != [word + 'pict']):
        return False
    if len(modern[0]) != 1:
        return False
    anchor = modern[0][0]
    if (anchor.tag != WP + 'anchor' or anchor.get('behindDoc') != '1' or
            [child.tag for child in anchor] != [WP + name for name in (
                'simplePos', 'positionH', 'positionV', 'extent', 'effectExtent',
                'wrapNone', 'docPr', 'cNvGraphicFramePr')] + [A + 'graphic']):
        return False
    graphic = anchor.find(A + 'graphic')
    drawing = graphic.find(A + 'graphicData')
    properties = anchor.find(WP + 'docPr')
    if (len(graphic) != 1 or drawing is None or [child.tag for child in drawing] != [WORD_DRAWING_SHAPE] or
            properties is None or len(properties) or properties.attrib.keys() - {'id', 'name'}):
        return False
    shape = drawing[0]
    if ([child.tag for child in shape] != [shape_namespace + name for name in ('cNvCnPr', 'spPr', 'bodyPr')] or
            any(len(shape[i]) or shape[i].attrib for i in (0, 2))):
        return False
    appearance = shape[1]
    if [child.tag for child in appearance] != [A + name for name in ('xfrm', 'prstGeom', 'ln')]:
        return False
    geometry, line = appearance[1], appearance[2]
    if (geometry.get('prst') != 'straightConnector1' or len(line) or line.attrib.keys() - {'w'} or
            any(child.tag != A + 'avLst' or len(child) for child in geometry)):
        return False
    picture = legacy[0]
    if [child.tag for child in picture] not in ([_VML + 'shape'], [_VML + 'shapetype', _VML + 'shape']):
        return False
    shape = picture[-1]
    if len(picture) == 2 and (picture[0].get('id') != '_x0000_t32' or picture[0].get('filled') != 'f' or
                              picture[0].get('path') != 'm,l21600,21600e' or
                              [child.tag for child in picture[0]] != [_VML + 'path', office + 'lock'] or
                              picture[0][0].get('fillok') != 'f'):
        return False
    version_anchor = '{http://schemas.microsoft.com/office/word/2010/wordml}anchorId'
    return (shape.get('type') == '#_x0000_t32' and shape.get('stroked') == 'f' and
            not shape.attrib.keys() - {'id', 'style', 'type', 'stroked', 'strokeweight', version_anchor,
                                       office + 'spid', office + 'gfxdata'} and
            [child.tag for child in shape] == [vml_anchor] and not len(shape[0]) and
            not any((part.tail or '').strip() or (part.tag != WP + 'posOffset' and (part.text or '').strip())
                    for part in node.iter()))


def docx_horizontal_rule(node):
    vml = '{urn:schemas-microsoft-com:vml}'
    office = '{urn:schemas-microsoft-com:office:office}'
    if len(node) != 1 or node[0].tag != vml + 'rect' or len(node[0]) or (node[0].text or '').strip():
        return None
    shape = node[0]
    if any(shape.get(office + name, '').lower() not in {'1', 't', 'true'}
           for name in ('hr', 'hrstd', 'hrnoshade')):
        return None
    if (shape.get('stroked', '').lower() not in {'0', 'f', 'false'} or
            shape.attrib.keys() - {'id', 'style', 'fillcolor', 'stroked',
                                   *(office + name for name in ('hr', 'hrstd', 'hrnoshade', 'hralign'))}):
        return None
    parts = [part.partition(':') for part in shape.get('style', '').lower().split(';') if part.strip()]
    style = {key.strip(): value.strip() for key, separator, value in parts if separator}
    color = shape.get('fillcolor', '')
    height = re.fullmatch(r'(?:[0-9]{1,2}(?:\.[0-9]{1,4})?|\.[0-9]{1,4})pt', style.get('height', ''))
    if (len(parts) != 2 or style.keys() != {'width', 'height'} or style['width'] not in {'0', '0pt'} or
            not height or not re.fullmatch(r'#[0-9a-fA-F]{6}', color)):
        return None
    thickness = round(float(height[0][:-2]) * 20)
    return (thickness, bytes.fromhex(color[1:])) if 0 < thickness <= 720 else None


def docx_anchored_horizontal_rule(picture):
    if len(picture) != 1 or picture[0].tag != _VML + 'line':
        return None
    line = picture[0]
    office = '{urn:schemas-microsoft-com:office:office}'
    anchor = '{http://schemas.microsoft.com/office/word/2010/wordml}anchorId'
    if (line.attrib.keys() - {'id', 'style', 'from', 'to', 'strokeweight', 'strokecolor', 'stroked',
                             office + 'spid', office + 'gfxdata', anchor} or
            line.get('stroked', 't').lower() not in {'1', 't', 'true'} or
            any(child.tag != office + 'lock' or len(child) for child in line) or
            any((child.text or '').strip() or (child.tail or '').strip() for child in line) or
            (line.text or '').strip()):
        return None
    style = {}
    for part in line.get('style', '').lower().split(';'):
        key, _, value = map(str.strip, part.partition(':'))
        if key:
            if key in style and style[key] != value:
                return None
            style[key] = value
    required = {'position': 'absolute', 'mso-position-horizontal-relative': 'text',
                'mso-position-vertical-relative': 'text'}
    optional = {'visibility': {'visible'}, 'z-index': None, 'mso-wrap-style': {'square', 'none'},
                'mso-position-horizontal': {'absolute'}, 'mso-position-vertical': {'absolute'},
                'mso-width-relative': {'page'}, 'mso-height-relative': {'page'},
                'mso-width-percent': {'0'}, 'mso-height-percent': {'0'},
                **{'mso-wrap-distance-' + edge: {'0', '0pt', '9pt'} for edge in ('left', 'top', 'right', 'bottom')}}
    if (any(style.get(key) != value for key, value in required.items()) or
            not re.fullmatch(r'-[0-9]{1,10}', style.get('z-index', '')) or
            any(key not in required and (key not in optional or optional[key] is not None and
                                         value not in optional[key]) for key, value in style.items())):
        return None

    def twips(value):
        value = value.strip().lower()
        if value == '0':
            return 0
        match = re.fullmatch(r'(-?(?:[0-9]{1,4}(?:\.[0-9]{1,4})?|\.[0-9]{1,4}))pt', value)
        return round(float(match[1]) * 20) if match else None

    values = (*line.get('from', '').split(','), *line.get('to', '').split(','), line.get('strokeweight', ''))
    if len(values) != 5:
        return None
    coordinates = tuple(map(twips, values))
    if None in coordinates:
        return None
    start, top, end, bottom, weight = coordinates
    width = abs(end - start)
    left = min(start, end)
    color = line.get('strokecolor', '#000000').lower()
    if color == 'black':
        color = '#000000'
    if (top != bottom or not 0 <= top <= 720 or not 0 < weight <= 720 or
            not 0 < width <= 28800 or abs(left) > 1440 or not re.fullmatch(r'#[0-9a-f]{6}', color)):
        return None
    height = top + (weight + 1) // 2
    if height <= 720:
        return (width, height, left), top, weight, bytes.fromhex(color[1:])
    return None


def word_hyperlink_instruction(instruction):
    tokens = re.compile(r'"((?:[^"\\]|\\.)*)"|([^\s"]+)')
    match = re.match(r'\s*HYPERLINK(?=\s|$)', instruction, re.I)
    if not match or len(instruction) > 8192:
        return '', ''
    arguments = instruction[match.end():]
    if tokens.sub('', arguments).strip():
        return '', ''
    values = iter(re.sub(r'\\(["\\])', r'\1', quoted) if not bare else bare
                  for quoted, bare in tokens.findall(arguments))
    address = bookmark = title = ''
    for arg in values:
        flag = arg.lower()
        if flag in {r'\n', r'\m'}:
            continue
        if flag in {r'\l', r'\o', r'\t'}:
            value = next(values, '')
            if flag == r'\l':
                bookmark = value
            elif flag == r'\o':
                title = value
        elif not address and not arg.startswith('\\'):
            address = arg
        else:
            return '', ''
    if any(ord(char) < 32 for char in address + bookmark) or '\\' in address:
        return '', ''
    if address and not address.startswith('#'):
        try:
            parsed = urlsplit(address)
        except ValueError:
            return '', ''
        if not ((parsed.scheme in {'http', 'https'} and parsed.netloc) or
                (parsed.scheme == 'mailto' and parsed.path)):
            return '', ''
    if bookmark:
        address = address.split('#', 1)[0] + '#' + bookmark
    return address, title


def word_paragraph_field_links(paragraph, relationships):
    """Expose complete hyperlink fields without changing their cached result runs."""
    word = '{' + W + '}'
    run_tag, properties, field_char = word + 'r', word + 'rPr', word + 'fldChar'
    markers = list(paragraph.iter(field_char))
    if not markers:
        return paragraph, relationships
    direct = {marker for run in paragraph.findall(run_tag) for marker in run.findall(field_char)}
    if len(markers) != len(direct):
        return paragraph, relationships

    pieces = []
    for run in paragraph:
        if run.tag != run_tag or run.find(field_char) is None:
            pieces.append((run, ''))
            continue
        styling = run.find(properties)
        segment = None
        for element in run:
            if element.tag == properties:
                continue
            marker = element.get(word + 'fldCharType', '') if element.tag == field_char else ''
            if segment is None or element.tag == field_char:
                segment = ET.Element(run_tag, run.attrib)
                if styling is not None:
                    segment.append(styling)
                pieces.append((segment, marker))
            segment.append(element)
            if element.tag == field_char:
                segment = None

    fields = []
    replacements = []
    for index, (_, marker) in enumerate(pieces):
        if marker == 'begin':
            fields.append([index, None])
            if len(fields) > 64:
                return paragraph, relationships
        elif marker == 'separate' and fields:
            fields[-1][1] = index
        elif marker == 'end' and fields:
            begin, separator = fields.pop()
            if separator is None or any(parent_separator is None for _, parent_separator in fields):
                continue
            code = []
            for run, boundary in pieces[begin + 1:separator]:
                if boundary or run.tag != run_tag or any(child.tag not in {properties, word + 'instrText'} for child in run):
                    break
                code.extend(child.text or '' for child in run.findall(word + 'instrText'))
            else:
                href, title = word_hyperlink_instruction(''.join(code))
                if href and separator + 1 < index and not any(
                        node.tag == word + 'hyperlink' for node, _ in pieces[separator + 1:index]):
                    replacements.append((begin, separator, index, href, title))
    if not replacements:
        return paragraph, relationships
    links = relationships.copy()
    result = []
    cursor = 0
    for begin, separator, end, href, title in sorted(replacements):
        if begin < cursor:
            continue
        result.extend(node for node, _ in pieces[cursor:begin])
        link = ET.Element(word + 'hyperlink')
        if href.startswith('#'):
            link.set(word + 'anchor', href[1:])
        else:
            identity = f'HomeLibreWordField{begin}'
            while identity in links:
                identity += '_'
            links[identity] = (href, True)
            link.set('{' + R + '}id', identity)
        if title:
            link.set(word + 'tooltip', title)
        link.extend(node for node, _ in pieces[separator + 1:end])
        result.append(link)
        cursor = end + 1
    result.extend(node for node, _ in pieces[cursor:])
    return result, links


WORD_NS = '{' + W + '}'
WORD_LEGACY_NUMBER_FORMATS = {'msonfc58': 'russianlower', 'msonfc59': 'russianupper'}
WORD_RUSSIAN_LIST_LETTERS = 'абвгдежзиклмнопрстуфхцчшщыэюя'
WORD_LIST_NUMBER_FORMATS = {'decimal', 'decimalzero', 'lowerroman', 'upperroman', 'lowerletter', 'upperletter',
                            'russianlower', 'russianupper', *WORD_LEGACY_NUMBER_FORMATS}


def word_number(value, form, api):
    form = WORD_LEGACY_NUMBER_FORMATS.get(form, form)
    if form in {'lowerroman', 'upperroman'}:
        return api.epub_list_label(form.removesuffix('roman') + '-roman', value).removesuffix('. ')
    if form in {'lowerletter', 'upperletter'} and 1 <= value <= 702:
        repeat, letter = divmod(value - 1, 26)
        return chr(ord('A' if form == 'upperletter' else 'a') + letter) * (repeat + 1)
    if form in {'russianlower', 'russianupper'} and value > 0:
        digits = []
        while value:
            value, letter = divmod(value - 1, len(WORD_RUSSIAN_LIST_LETTERS))
            digits.append(WORD_RUSSIAN_LIST_LETTERS[letter])
        label = ''.join(reversed(digits))
        return label.capitalize() if form == 'russianupper' else label
    if form == 'decimalzero':
        return str(value).zfill(2)
    return str(value)


class WordListLevel(NamedTuple):
    text: str
    form: str
    start: int
    restart: int
    style: str
    suffix: str
    legal: bool
    indent: dict
    picture: str


class WordLists:
    def __init__(self, book, document, styles):
        self.book, self.styles = book, styles
        self.definitions = {}
        self.instances = {}
        self.pictures = {}
        self.counts = {}
        self.resolved_levels = {}
        for node in document if document is not None else ():
            if node.tag == WORD_NS + 'abstractNum':
                self.definitions[node.get(WORD_NS + 'abstractNumId')] = node
            elif node.tag == WORD_NS + 'num':
                self.instances[node.get(WORD_NS + 'numId')] = node
            elif node.tag == WORD_NS + 'numPicBullet':
                self.pictures[node.get(WORD_NS + 'numPicBulletId')] = node

    @staticmethod
    def value(node, name, default=''):
        child = node.find(WORD_NS + name)
        return child.get(WORD_NS + 'val', default) if child is not None else default

    @staticmethod
    def integer(value, default=0):
        if re.fullmatch(r'[+-]?[0-9]{1,7}', value):
            return min(1_000_000, max(-1_000_000, int(value)))
        return default

    @staticmethod
    def indent(node):
        match = node.find(WORD_NS + 'pPr/' + WORD_NS + 'ind')
        return {key.removeprefix(WORD_NS): value for key, value in match.items()} if match is not None else {}

    def read_level(self, node, restart):
        level_text = node.find(WORD_NS + 'lvlText')
        text = self.value(node, 'lvlText') if level_text is not None and level_text.get(WORD_NS + 'null') not in {'1', 'true', 'on'} else ''
        legal = node.find(WORD_NS + 'isLgl')
        return WordListLevel(text, self.value(node, 'numFmt', 'decimal').casefold(),
                             self.integer(self.value(node, 'start'), 1), restart,
                             self.value(node, 'pStyle'), self.value(node, 'suff', 'tab'),
                             legal is not None and legal.get(WORD_NS + 'val') not in {'0', 'false', 'off'},
                             self.indent(node), self.value(node, 'lvlPicBulletId'))

    def abstract(self, identity):
        seen = set()
        while identity and identity not in seen and len(seen) < 24:
            seen.add(identity)
            definition = self.definitions.get(identity)
            if definition is None or not (linked := self.value(definition, 'numStyleLink')):
                return definition
            style = self.styles.get(linked)
            instance = self.instances.get(self.value(style, 'pPr/' + WORD_NS + 'numPr/' + WORD_NS + 'numId')) if style is not None else None
            identity = self.value(instance, 'abstractNumId') if instance is not None else ''
        return None

    def levels(self, num_id):
        if num_id in self.resolved_levels:
            return self.resolved_levels[num_id]
        levels = {}
        instance = self.instances.get(num_id)
        if instance is None:
            return levels
        definition = self.abstract(self.value(instance, 'abstractNumId'))
        if definition is not None:
            for node in definition.findall(WORD_NS + 'lvl'):
                index = self.integer(node.get(WORD_NS + 'ilvl', ''), -1)
                if 0 <= index <= 8:
                    restart = self.integer(self.value(node, 'lvlRestart'), index)
                    levels[index] = self.read_level(node, restart if 0 <= restart <= index else index)
        for node in instance.findall(WORD_NS + 'lvlOverride'):
            index = self.integer(node.get(WORD_NS + 'ilvl', ''), -1)
            if not 0 <= index <= 8:
                continue
            if (definition := node.find(WORD_NS + 'lvl')) is not None:
                restart = levels[index].restart if index in levels else index
                levels[index] = self.read_level(definition, restart)
            if index in levels and (start := self.value(node, 'startOverride')):
                entry = levels[index]
                levels[index] = entry._replace(start=self.integer(start, entry.start))
        self.resolved_levels[num_id] = levels
        return levels

    def place_marker(self, output, paragraph, style_id, part, picture):
        num_id = self.value(paragraph, 'pPr/' + WORD_NS + 'numPr/' + WORD_NS + 'numId')
        index = self.integer(self.value(paragraph, 'pPr/' + WORD_NS + 'numPr/' + WORD_NS + 'ilvl'), -1)
        chain = []
        while style_id and style_id not in chain and len(chain) < 24:
            style = self.styles.get(style_id)
            if style is None:
                break
            chain.append(style_id)
            if not num_id:
                num_id = self.value(style, 'pPr/' + WORD_NS + 'numPr/' + WORD_NS + 'numId')
            style_id = self.value(style, 'basedOn')
        if not num_id or num_id == '0':
            return
        levels = self.levels(num_id)
        if index < 0:
            index = next((n for style in chain for n, entry in levels.items() if entry.style == style), 0)
        entry = levels.get(index)
        if entry is None:
            self.book.warnings.add(f'Не восстановлена метка списка DOCX {num_id[:24]}, уровень {index + 1}. Нет определения нумерации.')
            return
        counters = self.counts.setdefault((part, num_id), {})
        counters[index] = counters.get(index, entry.start - 1) + 1
        for level in list(counters):
            if level > index and levels[level].restart > index:
                del counters[level]

        def substitution(match):
            level = int(match[1]) - 1
            if level > index or level not in levels:
                return ''
            referenced = levels[level]
            number = counters.get(level, referenced.start)
            form = 'decimal' if entry.legal else referenced.form
            if form not in WORD_LIST_NUMBER_FORMATS:
                self.book.warnings.add(f'Не восстановлена метка списка DOCX в формате «{form[:60]}». Показан её номер цифрами.')
            return word_number(number, form, self.book.c)

        text = re.sub(r'%([1-9])', substitution, entry.text) if entry.form != 'none' else ''
        if entry.form == 'bullet':
            text = text.translate({0xF0B7: '•', 0xF0A7: '▪'})
        gap = '' if entry.suffix == 'nothing' else ' '
        if entry.picture and not self.book.omit_images:
            marker = picture(self.pictures.get(entry.picture))
            if marker is not None:
                marker.tail = gap
                output.append(marker)
            else:
                self.book.warnings.add(f'Не восстановлена метка списка DOCX: недоступен рисунок «{entry.picture[:60]}».')
                output.text = text + gap if text else None
        elif text:
            output.text = text + gap

        indent = dict(entry.indent)
        for style in [*(self.styles[name] for name in reversed(chain)), paragraph]:
            values = self.indent(style)
            if 'start' in values or 'left' in values:
                indent.pop('start', None)
            if 'firstLine' in values or 'hanging' in values:
                indent.pop('hanging', None)
                indent.pop('firstLine', None)
            indent.update(values)
        left = self.integer(indent.get('start', indent.get('left', '')))
        first = -self.integer(indent['hanging']) if 'hanging' in indent else self.integer(indent.get('firstLine', ''))
        if left or first:
            c = self.book.c
            marker = f'{c.WORD_LIST_PARAGRAPH}{left}:{first}'
            output.set('class', ' '.join((*output.get('class', '').split(), marker)))
            output.set('style', ';'.join(filter(None, (output.get('style'), c.word_list_css(marker)))))


def read_docx(book):
    p = Package(book, streamed_part='word/document.xml'); c = book.c
    try:
        styles = p.xml('word/styles.xml', True); props = p.xml('docProps/core.xml', True)
        if props is not None:
            for n in props:
                if c.tag(n) == 'title' and c.plain(n): book.title = c.plain(n)
                elif c.tag(n) == 'creator' and c.plain(n): book.author = c.plain(n)
        style_map = {n.get('{' + W + '}styleId'): n for n in (styles if styles is not None else [])}
        notes = []; note_labels = {}; note_counters = {}
        note_body_marker = None
        main_part = 'word/document.xml'
        word_parts = {kind: f'word/{kind}.xml' for kind in ('settings', 'footnotes', 'endnotes', 'numbering')}
        relationships = {main_part: p.relationships(main_part, typed_parts=word_parts)}
        numbering_path = word_parts['numbering']
        try:
            nums = p.xml(numbering_path, True)
        except (c.ConversionError, zipfile.BadZipFile):
            nums = None
        lists = WordLists(book, nums, style_map)
        def val(node, name='val', default=''):
            return node.get('{' + W + '}' + name, default) if node is not None else default

        def automatic_note_label(family):
            if not note_counters:
                try:
                    settings = p.xml(word_parts['settings'], True)
                except (c.ConversionError, zipfile.BadZipFile):
                    settings = None
                    book.warnings.add('Нумерация сносок DOCX заменена обычной. Файл настроек повреждён.')
                if settings is None and word_parts['settings'] != 'word/settings.xml' and word_parts['settings'] not in p.names:
                    book.warnings.add('Нумерация сносок DOCX заменена обычной. Файл настроек недоступен.')
                for kind in ('footnote', 'endnote'):
                    props = settings.find(f'{{{W}}}{kind}Pr') if settings is not None else None
                    values = {c.tag(node): val(node) for node in props} if props is not None else {}
                    try:
                        start = min(1_000_000, max(0, int(values.get('numStart', '1'))))
                    except ValueError:
                        start = 1
                    note_counters[kind] = start, values.get('numFmt', 'decimal').casefold()
            number, pattern = note_counters[family]
            note_counters[family] = number + 1, pattern
            return word_number(number, pattern, c)

        omitted_objects = 0; has_content = False
        picture_templates = {}
        omitted_margin_lines = 0
        omitted_page_overlays = 0
        saved_margin_lines = 0
        table_count = 0
        field_depth = instruction_depth = 0
        drawing_resources = None
        rendered_canvas = {}
        rule_png = None

        def encode_rule_png(rgb, width, height, *, alpha=None):
            nonlocal rule_png
            if rule_png is None:
                import importlib.util
                spec = importlib.util.spec_from_file_location('homelib_fixed_layout', Path(__file__).with_name('fixed_layout.py'))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                rule_png = module.png
            return rule_png(rgb, width, height, alpha=alpha)

        def render_horizontal_rule(thickness, color):
            width, height = 1024, max(1, round(thickness / 15))
            picture = book.image(encode_rule_png(color * (width * height), width, height))
            c.style_word_rule(picture, thickness)
            return picture

        def render_anchored_rule(geometry, top, weight, color):
            width, height, left = geometry
            pixels_w, pixels_h = (width + 14) // 15, (height * 2 + 14) // 15
            start = max(0, 2 * top - weight) * pixels_h
            end = (2 * top + weight) * pixels_h
            stride = 2 * height
            opacity = bytes(round(255 * max(0, min(end, (row + 1) * stride) - max(start, row * stride)) / stride)
                            for row in range(pixels_h))
            alpha = b''.join(bytes([value]) * pixels_w for value in opacity)
            picture = book.image(encode_rule_png(color * (pixels_w * pixels_h), pixels_w, pixels_h, alpha=alpha))
            c.style_word_line(picture, f'{c.WORD_LINE_CLASS}{width}:{height}:{left}', geometry)
            return picture

        def omit_object(dst, label, preserved='', replacement=''):
            nonlocal omitted_objects
            omitted_objects += 1
            detail = f' {preserved}' if preserved else ''
            c.append_text(dst, replacement or f'[{label} DOCX № {omitted_objects} не перенесён.{detail}]')
            book.warnings.add(f'Не перенесён объект DOCX № {omitted_objects} ({label.lower()}).{detail}')

        def choice(node, rels):
            # Choice and Fallback describe the same object. Use a readable
            # embedded preview when present and keep textual structure otherwise.
            best = fallback = None
            best_score = -1
            for branch in node:
                if branch.tag == MC + 'Fallback':
                    fallback = branch
                elif branch.tag != MC + 'Choice':
                    continue
                if not book.omit_images and len(branch) == 1 and branch[0].tag == WORD_NS + 'drawing':
                    drawing = branch[0]
                    if drawing.find(f'{WP}inline/{A}graphic/{A}graphicData/{WORD_DRAWING_CANVAS}') is not None:
                        result = rendered_canvas.get(drawing)
                        if result is None:
                            items = list(drawing_items(drawing, rels))
                            description = next((item.get('descr', '') for item in items if item.tag == WP + 'docPr'), '')
                            result = drawing_picture(items, description, rels)
                        if result is not None:
                            rendered_canvas[drawing] = result
                            return branch
                score = 0
                for item in branch.iter():
                    if c.tag(item) in {'blip', 'imagedata'}:
                        identity = item.get('{' + R + '}embed') or item.get('{' + R + '}id')
                        relation = rels.get(identity)
                        if relation and not relation[1] and relation[0] in p.names:
                            score = 2
                            break
                    if item.tag == '{' + W + '}tbl' or (item.tag == '{' + W + '}t' and (item.text or '').strip()):
                        score = 1
                if score > best_score:
                    best, best_score = branch, score
                if score == 2:
                    break
            return fallback if best_score == 0 and fallback is not None else best

        def drawing_items(node, rels):
            for child in node:
                if child.tag == MC + 'AlternateContent':
                    branch = choice(child, rels)
                    if branch is not None:
                        yield from drawing_items(branch, rels)
                else:
                    yield child
                    if child.tag != '{' + W + '}txbxContent':
                        yield from drawing_items(child, rels)

        def word_link(node, rels):
            href = '#' + val(node, 'anchor') if val(node, 'anchor') else ''
            relation = rels.get(node.get('{' + R + '}id'))
            if relation:
                if relation[1] and urlsplit(relation[0]).scheme in {'https', 'http', 'mailto'}:
                    href = relation[0]
                elif not relation[1]:
                    book.warnings.add('Ссылка на отдельный документ DOCX не перенесена.')
            return href

        def drawing_context():
            nonlocal drawing_resources
            if drawing_resources is None:
                relations = p.xml('word/_rels/document.xml.rels', True)
                targets = p.relationships('word/document.xml')
                theme_id = next((node.get('Id') for node in relations if node.get('Type', '').endswith('/theme')), '') if relations is not None else ''
                theme_path, external = targets.get(theme_id, ('word/theme/theme1.xml', False))
                theme = None if external else p.xml(theme_path, True)
                settings = p.xml('word/settings.xml', True)
                mapping = settings.find('{' + W + '}clrSchemeMapping') if settings is not None else None
                drawing_resources = tuple(node for node in (styles, theme, mapping) if node is not None)
            return drawing_resources

        def add_drawing_assets(request, drawings, rels):
            assets = dict.fromkeys(node.get('{' + R + '}embed') for drawing in drawings for node in drawing.iter(A + 'blip'))
            assets.update(dict.fromkeys(node.get('{' + R + '}id') for drawing in drawings for node in drawing.iter(_VML + 'imagedata')))
            remaining = 3 * 1024 * 1024
            for identity in assets:
                if not identity:
                    return False
                target, external = rels.get(identity, ('', True))
                if external or target not in p.names or p.names[target].file_size > remaining:
                    return False
                try:
                    data = p.data(target)
                except zipfile.BadZipFile:
                    return False
                if not (data.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff')) or
                        (data.startswith(b'\x01\x00\x00\x00') and data[40:44] == b' EMF')):
                    return False
                remaining -= len(data)
                ET.SubElement(request, 'asset', id=identity).text = base64.b64encode(data).decode('ascii')
            return True

        def drawing_picture(items, description, rels, legacy_drawing=None):
            graphics = [item for item in items if item.tag == A + 'graphicData']
            if legacy_drawing is None:
                if len(graphics) != 1 or len(graphics[0]) != 1:
                    return None
                drawing = graphics[0][0]
                if drawing.tag not in {WORD_DRAWING_GROUP, WORD_DRAWING_SHAPE, WORD_DRAWING_CANVAS}:
                    return None
            else:
                drawing = legacy_drawing
            boxes = list(drawing.iter('{' + W + '}txbxContent'))
            if drawing.tag == WORD_DRAWING_SHAPE and not boxes:
                return None
            has_tables = next(drawing.iter('{' + W + '}tbl'), None) is not None
            request = ET.Element('figure')
            request.append(drawing)
            if drawing.tag == WORD_DRAWING_CANVAS:
                inline = next((item for item in items if item.tag == WP + 'inline'), None)
                extent = inline.find(WP + 'extent') if inline is not None else None
                if extent is None:
                    return None
                effects = inline.find(WP + 'effectExtent')
                request.append(extent)
                if effects is not None:
                    request.append(effects)
            request.extend(drawing_context())
            list_ids = {val(item, 'val') for item in drawing.iter('{' + W + '}numId')}
            if list_ids and nums is not None:
                instances = [lists.instances[key] for key in sorted(list_ids) if key in lists.instances]
                definitions = sorted({val(node.find('{' + W + '}abstractNumId')) for node in instances})
                selected = ET.SubElement(request, '{' + W + '}numbering')
                selected.extend(lists.definitions[key] for key in definitions if key in lists.definitions)
                selected.extend(instances)
            if not add_drawing_assets(request, (drawing,), rels):
                return None
            picture = book.office_image_decoder().rasterize_word_drawing(book, ET.tostring(request, encoding='utf-8'))
            if picture is None:
                return None
            image = book.image(picture)
            legacy_box = drawing.tag == '{' + W + '}pict'
            if not has_tables and drawing.tag in WORD_DRAWING_GROUPS:
                image.set('class', 'word-diagram')
            if drawing.tag == WORD_DRAWING_CANVAS:
                margins = effects.attrib if effects is not None else {}
                for axis, measurement, before, after in (('width', 'cx', 'l', 'r'), ('height', 'cy', 't', 'b')):
                    dimensions = int(extent.get(measurement, '0')) + int(margins.get(before, '0')) + int(margins.get(after, '0'))
                    image.set(axis, str(max(1, (dimensions + 4762) // 9525)))
                image.set('class', 'word-diagram ' + c.WORD_CANVAS_STYLE)
            if not has_tables and (drawing.tag == WORD_DRAWING_SHAPE or legacy_box):
                image.set('class', 'word-textbox')
                anchor = next((item for item in items if item.tag == WP + 'anchor'), None)
                if legacy_box:
                    shape = drawing.find(_VML + 'shape')
                    offset = re.search(r'(?:^|;)\s*margin-left\s*:\s*([0-9]{1,3}(?:\.[0-9]+)?)pt\s*(?:;|$)',
                                       shape.get('style', ''), re.I)
                    if offset and float(offset[1]) <= 36:
                        image.set('class', 'word-textbox-left')
                elif anchor is not None:
                    offset = anchor.findtext(f'{WP}positionH[@relativeFrom="margin"]/{WP}posOffset', '')
                    left_margin = anchor.findtext(f'{WP}positionH[@relativeFrom="leftMargin"]/{WP}align', '')
                    if left_margin == 'left' or (re.fullmatch(r'[0-9]{1,6}', offset) and int(offset) <= 36 * 12700):
                        image.set('class', 'word-textbox-left')
                    else:
                        image.set('style', 'display:block;margin-left:auto;margin-right:auto')
                if legacy_box or anchor is not None:
                    book.warnings.add('Плавающие текстовые рамки DOCX сохранены как изображения у исходных абзацев. '
                                      'Положение на печатной странице может отличаться.')
            caption_text = '{' + W + '}t'
            caption_parts = {caption_text, '{' + W + '}br', '{' + W + '}cr'}
            captions = [''.join((text.text or '') if text.tag == caption_text else '\n'
                                for text in paragraph.iter() if text.tag in caption_parts).strip()
                        for box in boxes for paragraph in box.iter('{' + W + '}p')]
            image.set('alt', '\n'.join(label for label in [description, *captions] if label))
            links = {}
            if not has_tables:
                for node in drawing.iter('{' + W + '}hyperlink'):
                    href = word_link(node, rels)
                    caption = ''.join(text.text or '' for text in node.iter('{' + W + '}t')).strip()
                    if href and caption:
                        links[href, caption] = book.el('a', caption, href=href)
            return image, links.values(), boxes if has_tables else ()

        def is_text_box(node):
            return c.tag(node) == 'div' and node.get('class') == 'docx-textbox'

        def read_text_box(source, destination, part):
            nonlocal field_depth, instruction_depth
            outer_field = field_depth, instruction_depth
            field_depth = instruction_depth = 0
            try:
                block(source, destination, part)
            finally:
                field_depth, instruction_depth = outer_field

        def has_text_box(node):
            return any(is_text_box(item) for item in node.iter())

        def paragraph_flow(node):
            # Split at extracted blocks while retaining surrounding run styles
            # and keeping tables out of XHTML paragraphs and headings.
            if is_text_box(node):
                node.tail = None
                yield node
                return
            name = c.tag(node)
            segment = book.el(name, node.text, **node.attrib)
            continuation = {key:value for key,value in node.attrib.items() if key != 'id'}
            if c.html_heading_level(node):
                name = 'p'
                continuation.pop('role', None)
                continuation.pop('aria-level', None)
            for child in node:
                if not has_text_box(child):
                    segment.append(child)
                    continue
                tail = child.tail
                for part in paragraph_flow(child):
                    if is_text_box(part):
                        if c.plain(segment) or len(segment) or segment.get('id'):
                            yield segment
                        yield part
                        segment = book.el(name, **continuation)
                    else:
                        segment.append(part)
                c.append_text(segment, tail)
            if c.plain(segment) or len(segment) or segment.get('id'):
                yield segment
        def document_image(identity, rels, crop=None):
            nonlocal has_content
            relation = rels.get(identity)
            if not relation or relation[1] or relation[0] not in p.names:
                return book.unreadable_image(relation[0] if relation and not relation[1] else identity)
            try:
                data = p.data(relation[0])
                if crop and not book.omit_images:
                    try:
                        data = book.office_image_decoder().picture_crop(book, data, crop)
                    except (ValueError, OSError, book.c.UnreadableImage):
                        name = posixpath.basename(relation[0])
                        book.warnings.add(f'Обрезка изображения DOCX не перенесена: «{name}». Сохранено исходное изображение.')
                image = book.optional_image(data, relation[0])
            except zipfile.BadZipFile:
                return book.unreadable_image(relation[0])
            if c.tag(image) == 'img':
                has_content = True
            return image
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

        def visibility(run_properties):
            vanish = run_properties.find(f'{{{W}}}vanish') if run_properties is not None else None
            if vanish is None: return None
            value = val(vanish, default='1').lower()
            if value in {'1', 'on', 'true'}: return True
            if value in {'0', 'off', 'false'}: return False
            return None

        default_styles = {val(style, 'type'): identity for identity, style in style_map.items()
                          if identity and val(style, 'default').lower() in {'1', 'on', 'true'}}
        default_run = styles.find(f'{{{W}}}docDefaults/{{{W}}}rPrDefault/{{{W}}}rPr') if styles is not None else None
        default_hidden = visibility(default_run) is True

        @lru_cache(maxsize=512)
        def style_visibility(identity, kind):
            for _ in range(24):
                style = style_map.get(identity)
                if not identity or val(style, 'type') != kind: break
                hidden = visibility(style.find(f'{{{W}}}rPr'))
                if hidden is not None: return hidden
                identity = val(style.find(f'{{{W}}}basedOn'))
            return None

        def run_hidden(run_properties, paragraph_style, character_style):
            direct = visibility(run_properties)
            if direct is not None: return direct
            paragraph = style_visibility(paragraph_style or default_styles.get('paragraph'), 'paragraph')
            hidden = default_hidden if paragraph is None else paragraph
            character = style_visibility(character_style or default_styles.get('character'), 'character')
            if character is None: return hidden
            return not hidden if character else False

        def add_inline(src, dst, part, rels, paragraph_style=''):
            nonlocal has_content, field_depth, instruction_depth, omitted_margin_lines, saved_margin_lines
            nonlocal omitted_page_overlays
            consumed_marker = -1
            for position, n in enumerate(src):
                if position == consumed_marker:
                    continue
                name = c.tag(n)
                if name in {'pPr', 'rPr', 'sdtPr', 'proofErr', 'bookmarkEnd', 'commentRangeStart', 'commentRangeEnd'}: continue
                if name in {'del', 'moveFrom'}:
                    book.warnings.add('Удалённые исправления DOCX не перенесены; сохранён итоговый текст.'); continue
                if name in {'oMath', 'oMathPara', 'altChunk'}:
                    omit_object(dst, 'Блок формулы' if name in {'oMath', 'oMathPara'} else 'Встроенный объект')
                    continue
                if name == 'object':
                    # Word stores a separate, static VML preview for many OLE objects.
                    # The preview is enough to show a formula without loading its object.
                    vml = '{urn:schemas-microsoft-com:vml}'
                    previews = [(shape, image.get('{' + R + '}id')) for shape in n.findall(vml + 'shape')
                                for image in shape.findall(vml + 'imagedata')]
                    previews = [(shape, identity) for shape, identity in previews if identity]
                    if not previews:
                        omit_object(dst, 'Встроенный объект')
                    for shape, identity in previews:
                        image = document_image(identity, rels)
                        if c.tag(image) == 'img':
                            width = re.search(r'(?:^|;)\s*width:\s*(\d{1,4}(?:\.\d+)?)pt\s*(?:;|$)', shape.get('style', ''), re.I)
                            if width:
                                image.set('width', str(max(1, round(float(width[1]) * 96 / 72))))
                            book.warnings.add('Встроенные объекты DOCX перенесены как изображения. Данные для редактирования объектов не перенесены.')
                        dst.append(image)
                    continue
                if name == 'r':
                    rp = n.find('{' + W + '}rPr'); sid = val(rp.find('{' + W + '}rStyle')) if rp is not None else ''
                    if run_hidden(rp, paragraph_style, sid):
                        # The field state is independent of the run's display formatting.
                        add_inline(n.findall(f'{{{W}}}fldChar'), dst, part, rels, paragraph_style)
                        continue
                    values = properties(inherited(paragraph_style, 'rPr') + inherited(sid, 'rPr') + ([rp] if rp is not None else []))
                    target = dst
                    for prop, mapped in [('b', 'strong'), ('i', 'em'), ('strike', 's'), ('u', 'u')]:
                        if values.get(prop) not in {None, '0', 'false', 'off', 'none'}:
                            child = book.el(mapped); target.append(child); target = child
                    if values.get('vertAlign') in {'superscript', 'subscript'}:
                        child = book.el('sup' if values['vertAlign'] == 'superscript' else 'sub'); target.append(child); target = child
                    add_inline(n, target, part, rels, paragraph_style)
                elif name == 'fldChar':
                    marker = val(n, 'fldCharType')
                    if marker == 'begin':
                        field_depth += 1
                        if not instruction_depth:
                            instruction_depth = field_depth
                    elif field_depth and marker in {'separate', 'end'}:
                        if instruction_depth == field_depth:
                            instruction_depth = 0
                        if marker == 'end':
                            field_depth -= 1
                elif name == 't' or (name == 'instrText' and not instruction_depth):
                    # Only the instruction region of a complex field hides this text.
                    # DocSharp can leave ordinary prose tagged as instrText after OLE.
                    if (n.text or '').strip(): has_content = True
                    c.append_text(dst, n.text or '')
                elif name == 'tab': c.append_text(dst, '\t')
                elif name in {'br', 'cr'}: dst.append(book.el('br'))
                elif name == 'noBreakHyphen': c.append_text(dst, '\u2011')
                elif name == 'softHyphen': c.append_text(dst, '\u00ad')
                elif name == 'hyperlink':
                    href = word_link(n, rels)
                    attributes = {'href': href} if href else {}
                    if href and (title := val(n, 'tooltip')):
                        attributes['title'] = title
                    child = book.el('a', **attributes); dst.append(child)
                    add_inline(n, child, part, rels, paragraph_style)
                elif name == 'fldSimple' and not instruction_depth:
                    href, title = word_hyperlink_instruction(val(n, 'instr'))
                    if href:
                        attributes = {'title': title} if title else {}
                        child = book.el('a', href=href, **attributes); dst.append(child)
                        add_inline(n, child, part, rels, paragraph_style)
                    else:
                        add_inline(n, dst, part, rels, paragraph_style)
                elif name == 'bookmarkStart':
                    identity = val(n, 'name')
                    if identity and identity != '_GoBack': dst.append(book.el('span', id=identity))
                elif n.tag == MC + 'AlternateContent':
                    if empty_docx_connector(n):
                        continue
                    branch = choice(n, rels)
                    if branch is not None:
                        add_inline(branch, dst, part, rels, paragraph_style)
                elif name in {'drawing', 'pict'}:
                    if name == 'pict' and docx_white_page_overlay(n):
                        # Page coordinates do not identify an area in a reflowed paragraph.
                        omitted_page_overlays += 1
                        continue
                    if name == 'pict' and (space := word_picture_spacer(n, picture_templates.setdefault(part, {}))):
                        marker = f'{c.WORD_SPACER_CLASS}{space[0]}-{space[1]}'
                        dst.append(book.el('span', **{'class': marker, 'style': c.word_spacer_css(marker),
                                                      'aria-hidden': 'true'}))
                        continue
                    if name == 'pict' and (rule := docx_horizontal_rule(n)):
                        if not book.omit_images:
                            dst.append(render_horizontal_rule(*rule))
                            has_content = True
                        continue
                    if name == 'pict' and len(n) == 1 and n[0].tag == _VML + 'oval':
                        if book.omit_images:
                            continue
                        rendered = drawing_picture([], '', rels, n[0])
                        if rendered is not None:
                            dst.append(rendered[0])
                            has_content = True
                            continue
                    if name == 'drawing':
                        anchor = n.find(f'{WP}anchor')
                        props = anchor.find(f'{WP}docPr') if anchor is not None else None
                        match = re.fullmatch(r'HomeLibreMarginRule-(left|right)-([0-9]{1,5})-([0-9]{1,5})',
                                             props.get('name', '')) if props is not None else None
                        if match:
                            extent = anchor.find(f'{WP}extent')
                            left = anchor.findtext(f'{WP}positionH[@relativeFrom="margin"]/{WP}posOffset', '')
                            top = anchor.findtext(f'{WP}positionV[@relativeFrom="paragraph"]/{WP}posOffset', '')
                            height = extent.get('cy', '') if extent is not None else ''
                            width = extent.get('cx', '') if extent is not None else ''
                            marker = c.MARGIN_RULE_PREFIX + ':'.join((*match.groups(), left, top, height, width))
                            if (anchor.get('behindDoc') in {'0', '1'} and anchor.find(f'{WP}wrapNone') is not None
                                    and c.margin_rule_geometry(marker)):
                                dst.append(book.el('span', **{'class': marker}))
                                saved_margin_lines += 1
                            else:
                                omitted_margin_lines += 1
                            continue
                    if name == 'pict' and empty_docx_wordart(n):
                        continue
                    if name == 'pict' and empty_docx_textbox(n):
                        book.warnings.add('Пустая прозрачная рамка DOCX пропущена при переносе страничной вёрстки.')
                        continue
                    # Keep text reflow independent of page-relative rule geometry,
                    # while giving export callers an exact count of the loss.
                    if name == 'pict' and len(n) == 1:
                        line = n[0]
                        x1, sep1, y1 = line.get('from', '').partition(',')
                        x2, sep2, y2 = line.get('to', '').partition(',')
                        if (line.tag == '{urn:schemas-microsoft-com:vml}line' and not len(line) and
                                not (line.text or '').strip() and sep1 and sep2 and x1.strip() == x2.strip() and
                                y1.strip() != y2.strip() and re.search(r'(?:^|;)\s*mso-position-horizontal-relative:\s*margin\s*(?:;|$)',
                                                                      line.get('style', ''), re.I)):
                            omitted_margin_lines += 1
                            continue
                    found = False
                    items = list(drawing_items(n, rels))
                    legacy_group = n[0] if name == 'pict' and len(n) == 1 and n[0].tag == _VML + 'group' else None
                    legacy_box = name == 'pict' and any(
                        shape.get('type') == '#_x0000_t202' and shape.find(_VML + 'textbox') is not None
                        for shape in n.findall(_VML + 'shape'))
                    legacy_drawing = n if legacy_box else legacy_group
                    grouped = any(item.tag in WORD_DRAWING_GROUPS for item in items)
                    has_picture = False
                    description = next((item.get('descr', '') for item in items
                                        if c.tag(item) == 'docPr'), '') if name == 'drawing' else ''
                    if (legacy_box or grouped or any(item.tag == WORD_DRAWING_SHAPE for item in items)) and not book.omit_images:
                        rendered = rendered_canvas.pop(n, None) or drawing_picture(items, description, rels, legacy_drawing)
                        if rendered is not None:
                            image, links, boxes = rendered
                            dst.append(image)
                            for link in links:
                                c.append_text(dst, ' ')
                                dst.append(link)
                            if boxes:
                                # The image preserves the original arrangement, while
                                # ordinary ebook tables keep cells selectable.
                                extracted = book.el('div', **{'class': 'docx-textbox'})
                                extracted.append(book.el('p', 'Текст и таблицы схемы'))
                                for box in boxes:
                                    read_text_box(box, extracted, part)
                                dst.append(extracted)
                            has_content = True
                            notice = ('Составные рисунки' if grouped else 'Текстовые рамки')
                            book.warnings.add(notice + ' DOCX сохранены как иллюстрации с текстовым описанием.')
                            anchor = n.find(WP + 'anchor')
                            if legacy_group is not None or grouped and anchor is not None and any(
                                    position.get('relativeFrom') == 'page' for position in anchor
                                    if position.tag in {WP + 'positionH', WP + 'positionV'}):
                                book.warnings.add('Положение составного рисунка DOCX на печатной странице может измениться. '
                                                  'Рисунок и подписи сохранены у связанного абзаца. Обтекание текстом может отличаться.')
                            continue
                    textboxes = []
                    crops = {}
                    for fill in items:
                        if c.tag(fill) == 'blipFill':
                            crop = fill.find(A + 'srcRect')
                            if crop is not None and crop.attrib:
                                crops[fill.find(A + 'blip')] = crop.attrib
                    for image in items:
                        if image.tag == '{' + W + '}txbxContent':
                            textboxes.append(image)
                            continue
                        identity = image.get('{' + R + '}embed') or image.get('{' + R + '}id')
                        if c.tag(image) not in {'blip', 'imagedata'} or not identity: continue
                        if book.omit_images and description and identity.startswith('rIdHomeLibreCompoundCaptioned'):
                            for index, line in enumerate(description.splitlines()):
                                if index:
                                    dst.append(book.el('br'))
                                c.append_text(dst, line)
                            found = True
                            continue
                        resolved = document_image(identity, rels, crops.get(image))
                        if c.tag(resolved) == 'img':
                            has_picture = True
                            if description:
                                resolved.set('alt', description)
                            if identity.startswith('rIdHomeLibreFigure'):
                                book.warnings.add('Графики старого DOC перенесены как изображения. Положение линий и подписей может немного отличаться.')
                            elif identity.startswith('rIdHomeLibreCompound'):
                                legend = identity.startswith('rIdHomeLibreCompoundLegend')
                                resolved.set('class', 'word-diagram-legend' if legend else 'word-diagram')
                                resolved.set('style', 'display:block;margin-right:auto;margin-left:' + ('0' if legend else 'auto'))
                                if identity.startswith('rIdHomeLibreCompoundCaptioned'):
                                    book.warnings.add('Схемы старого DOC сохранены как иллюстрации. '
                                                      'Подписи входят в рисунок и его текстовое описание. '
                                                      'Положение схемы на странице может измениться.')
                                else:
                                    book.warnings.add('Схемы старого DOC сохранены как иллюстрации. '
                                                      'Расположение на печатной странице и рядом с текстом может отличаться.')
                            elif identity.startswith('rIdHomeLibreParagraphRule') and (geometry := c.word_line_geometry(description)):
                                resolved.attrib.pop('alt', None)
                                c.style_word_line(resolved, description, geometry)
                                if identity.startswith('rIdHomeLibreParagraphRuleStart'):
                                    book.warnings.add('Разделители страниц DOC сохранены перед текстом. '
                                                      'Исходный отступ от края печатного листа может измениться.')
                                elif identity.startswith('rIdHomeLibreParagraphRuleBefore'):
                                    book.warnings.add('Разделитель DOC сохранён перед соответствующим абзацем. '
                                                      'Отступы могут измениться при перевёрстке.')
                                elif identity.startswith('rIdHomeLibreParagraphRuleHeading'):
                                    book.warnings.add('Подчёркивание заголовка DOC сохранено отдельной линией. '
                                                      'Отступы могут измениться при перевёрстке.')
                                else:
                                    book.warnings.add('Линии старого DOC сохранены возле связанных абзацев. '
                                                      'Отступ под текстом может измениться при перевёрстке.')
                            elif identity.startswith(('rIdHomeLibreParagraphRule', 'rIdHomeLibreFloatingLineGroup')):
                                resolved.set('class', 'paragraph-rule')
                                resolved.set('style', 'display:block;margin-left:0;margin-right:auto')
                                if identity.startswith('rIdHomeLibreParagraphRuleMargin'):
                                    book.warnings.add('Горизонтальные линии на полях DOC сохранены перед абзацами. Их положение на странице может отличаться.')
                                elif identity.startswith('rIdHomeLibreFloatingLineGroup'):
                                    book.warnings.add('Линии старого DOC сохранены возле связанных абзацев. Их положение на печатной странице может отличаться.')
                            elif identity.startswith('rIdHomeLibreLinePage'):
                                book.warnings.add('Страница схемы старого DOC сохранена как изображение с исходными пропорциями.')
                        dst.append(resolved)
                        found = True
                    rendered_boxes = []
                    for textbox in textboxes:
                        content = book.el('div', **{'class': 'docx-textbox'})
                        read_text_box(textbox, content, part)
                        if len(content):
                            rendered_boxes.append(content)
                    if grouped and not book.omit_images:
                        details = ['Взаимное расположение элементов и контуры фигур не перенесены.']
                        if has_picture:
                            details.append('Встроенные изображения сохранены отдельно.')
                        if rendered_boxes:
                            details.append('Текст и таблицы рамки сохранены.')
                        notice = book.el('p') if rendered_boxes else dst
                        omit_object(notice, 'Составной рисунок', ' '.join(details))
                        if rendered_boxes:
                            rendered_boxes[0].insert(0, notice)
                    elif rendered_boxes and not grouped:
                        notice = book.el('p')
                        omit_object(notice, 'Внешний вид рисунка', 'Текст и таблицы рамки сохранены.')
                        rendered_boxes[0].insert(0, notice)
                    if rendered_boxes:
                        dst.extend(rendered_boxes)
                    elif not found and not grouped:
                        shape = n.find('{urn:schemas-microsoft-com:vml}shape[@type="#_x0000_t75"]')
                        alternative = ((shape.get('alt') or '').strip()
                                       if shape is not None and not len(shape) and not (shape.text or '').strip() else '')
                        if alternative:
                            has_content = True
                            omit_object(dst, 'Изображение без данных',
                                        f'Сохранён альтернативный текст ({alternative}).', replacement=alternative)
                        else:
                            omit_object(dst, 'Рисунок или диаграмма')
                elif name in {'footnoteReference', 'endnoteReference'}:
                    family, identifier = name.removesuffix('Reference'), val(n, 'id')
                    identity = f'{family}-{identifier}'
                    label = note_labels.get(identity)
                    if val(n, 'customMarkFollows').casefold() in {'1', 'on', 'true'}:
                        marker = src[position + 1] if position + 1 < len(src) else None
                        if marker is not None and marker.tag == f'{{{W}}}t' and (marker.text or '').strip():
                            label = marker.text
                            consumed_marker = position + 1
                        elif label is None:
                            label = '*'
                    if label is None:
                        label = automatic_note_label(family)
                    if identity not in note_labels:
                        note_labels[identity] = label
                        notes.append((name, identifier, identity))
                    dst.append(book.el('a', label, href='#' + identity, **{'{' + c.EP + '}type': 'noteref'}))
                elif name in {'footnoteRef', 'endnoteRef'}:
                    if note_body_marker and name == note_body_marker[0]:
                        c.append_text(dst, note_body_marker[1])
                elif name in {'instrText', 'lastRenderedPageBreak'}: continue
                else: add_inline(n, dst, part, rels, paragraph_style)
        def table_consumer(dst, part):
            nonlocal table_count
            table_count += 1
            table_number = table_count
            table = book.el('table')
            dst.append(table)
            grid_size = row_number = 0
            previous_merges = {}

            def grid_number(node, default):
                try:
                    return max(default, int(val(node, default=str(default))))
                except ValueError:
                    return default

            def pad(row, columns):
                if columns > 0:
                    cell = book.el('td')
                    if columns > 1:
                        cell.set('colspan', str(columns))
                    row.append(cell)

            def consume(source_row):
                nonlocal grid_size, row_number, previous_merges
                if source_row.tag == f'{{{W}}}tblGrid':
                    grid_size = len(source_row.findall(f'{{{W}}}gridCol'))
                if source_row.tag != f'{{{W}}}tr':
                    return
                row_number += 1
                row = book.el('tr')
                table.append(row)
                before = grid_number(source_row.find(f'{{{W}}}trPr/{{{W}}}gridBefore'), 0)
                if grid_size and before > grid_size:
                    before = 0
                column = before
                pad(row, before)
                current_merges = {}
                for source_cell in source_row.findall(f'{{{W}}}tc'):
                    width = grid_number(source_cell.find(f'{{{W}}}tcPr/{{{W}}}gridSpan'), 1)
                    columns = (column, width)
                    column += width
                    cell = book.el('td')
                    if width > 1:
                        cell.set('colspan', str(width))
                    block(source_cell, cell, part)
                    merge = source_cell.find(f'{{{W}}}tcPr/{{{W}}}vMerge')
                    if merge is not None:
                        mode = val(merge, default='continue')
                        origin = previous_merges.get(columns)
                        if mode == 'continue' and origin is not None and not _table_cell_has_content(cell):
                            origin.set('rowspan', str(int(origin.get('rowspan', '1')) + 1))
                            current_merges[columns] = origin
                            continue
                        if mode != 'restart':
                            book.warnings.add(
                                f'Вертикальное объединение ячеек DOCX не восстановлено: таблица {table_number}, '
                                f'строка {row_number}, столбец {columns[0] + 1}. Ячейка сохранена отдельно.')
                        current_merges[columns] = cell
                    row.append(cell)
                after = grid_number(source_row.find(f'{{{W}}}trPr/{{{W}}}gridAfter'), 0)
                if not grid_size or column + after == grid_size:
                    pad(row, after)
                if not len(row) and current_merges:
                    row.set('data-homelib-merged-row', '1')
                previous_merges = current_merges

            return consume

        def paragraph_rule(paragraph, rels, style):
            word = '{' + W + '}'
            runs = [node for node in paragraph if node.tag != word + 'pPr']
            if len(runs) != 1 or runs[0].tag != word + 'r':
                return None
            run = runs[0]
            properties = run.find(word + 'rPr')
            nodes = [node for node in run if node.tag != word + 'rPr']
            if len(nodes) != 1 or run_hidden(properties, style, val(run.find(word + 'rPr/' + word + 'rStyle'))):
                return None
            picture = nodes[0]
            if picture.tag == MC + 'AlternateContent':
                branch = choice(picture, rels)
                if branch is None or len(branch) != 1:
                    return None
                picture = branch[0]
            return docx_anchored_horizontal_rule(picture) if picture.tag == word + 'pict' else None

        def numbering_picture(definition):
            if definition is None:
                return None
            identifiers = {identity for node in definition.iter()
                           if (identity := node.get('{' + R + '}embed') or node.get('{' + R + '}id'))}
            if len(identifiers) != 1 or numbering_path is None:
                return None
            if numbering_path not in relationships:
                relationships[numbering_path] = p.relationships(numbering_path)
            [identity] = identifiers
            picture = document_image(identity, relationships[numbering_path])
            if c.tag(picture) != 'img':
                return None
            picture.set('class', c.EPUB_LIST_MARKER_STYLE)
            picture.set('style', 'max-width:1em;max-height:1em;vertical-align:baseline')
            return picture

        def block(src, dst, part, legend=None):
            nonlocal has_content
            if part not in relationships:
                relationships[part] = p.relationships(part)
            rels = relationships[part]
            for n in src:
                name = c.tag(n)
                if name == 'p':
                    pp = n.find('{' + W + '}pPr'); sid = val(pp.find('{' + W + '}pStyle')) if pp is not None else ''
                    ps = properties(inherited(sid, 'pPr') + ([pp] if pp is not None else []))
                    outline = ps.get('outlineLvl')
                    if outline in {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'}:
                        # Word uses level 9 for an ordinary paragraph, even in a heading style.
                        level = int(outline) + 1 if outline != '9' else 0
                    elif sid.casefold() == 'title':
                        level = 1
                    else:
                        heading = re.fullmatch(r'(?:Heading|Заголовок)\s*([1-9])', sid, re.I)
                        level = int(heading[1]) if heading else 0
                    out = book.el(f'h{level}' if 1 <= level <= 6 else 'p')
                    if level > 6:
                        # HTML has six heading elements. Keep the remaining
                        # Word levels available to EPUB navigation and FB2.
                        out.attrib.update(role='heading', **{'aria-level': str(level)})
                    if ps.get('jc') in {'center', 'right', 'left', 'both'}: out.set('style', 'text-align:' + ('justify' if ps['jc'] == 'both' else ps['jc']))
                    if legend is None:
                        lists.place_marker(out, n, sid or default_styles.get('paragraph', ''), part, numbering_picture)
                    else:
                        out.set('style', 'text-align:left;text-indent:0')
                        out.append(legend)
                    if not instruction_depth:
                        nodes, local_rels = word_paragraph_field_links(n, rels)
                    else:
                        nodes, local_rels = n, rels
                    if not instruction_depth and (rule := paragraph_rule(n, local_rels, sid)):
                        if not book.omit_images:
                            out.append(render_anchored_rule(*rule))
                            has_content = True
                        book.warnings.add('Линии DOCX сохранены у исходных абзацев. Положение на печатной странице может отличаться.')
                    else:
                        add_inline(nodes, out, part, local_rels, sid)
                    if any(c.word_spacer_dimensions(child.get('class', '')) for child in out.iter('{' + c.XH + '}span')):
                        alignment = {'center': 'center', 'right': 'right', 'both': 'justify'}.get(ps.get('jc'), 'left')
                        shade = pp.find('{' + W + '}shd') if pp is not None else None
                        color = val(shade, 'fill').lower() if val(shade) == 'clear' else ''
                        if not re.fullmatch('[0-9a-f]{6}', color): color = 'none'
                        marker = f'{c.WORD_SPACER_PARAGRAPH}{alignment}-{color}'
                        out.set('class', ' '.join((*out.get('class', '').split(), marker)))
                        out.set('style', ';'.join(filter(None, (out.get('style'), c.word_spacer_css(marker)))))
                    has_title = c.plain(out)
                    if level and not has_title:
                        # A heading style on an empty or image-only paragraph
                        # must not create an untitled section in FB2.
                        out.tag = '{' + c.XH + '}p'
                        out.attrib.pop('role', None)
                        out.attrib.pop('aria-level', None)
                    if not has_title and not len(out): out.append(book.el('br'))
                    if has_text_box(out):
                        dst.extend(paragraph_flow(out))
                    else:
                        dst.append(out)
                elif n.tag == MC + 'AlternateContent':
                    branch = choice(n, rels)
                    if branch is not None:
                        block(branch, dst, part)
                elif name == 'tbl':
                    consume = table_consumer(dst, part)
                    for child in n:
                        consume(child)
                elif name in {'sdt', 'sdtContent', 'customXml', 'ins'}: block(n, dst, part)
                elif name not in {'sectPr', 'tcPr', 'sdtPr', 'tblPr', 'tblGrid'}: add_inline([n], dst, part, rels)
        part = main_part
        if not book.omit_images and part in p.names and p.names[part].file_size <= 4 * 1024 * 1024:
            with p.z.open(part) as source:
                framed = b'mso-position-horizontal-relative:page' in source.read(65536)
            if framed:
                word = '{' + W + '}'
                body = p.xml(part).find(word + 'body')
                if body is not None and 2 <= len(body) <= 256 and len(body) % 2 == 0:
                    request = ET.Element('figures')
                    request.extend(drawing_context())
                    if nums is not None:
                        request.append(nums)
                    request.append(body)
                    pages = book.office_image_decoder().rasterize_word_frame_pages(book, ET.tostring(request), len(body) // 2)
                    if pages is not None:
                        book.framed_pages = [c.raster_header_size(page) for page in pages]
                        breaks = {word + 'br': '\n', word + 'cr': '\n', word + 'tab': '\t'}
                        for anchor, data in zip(list(body)[::2], pages):
                            caption = '\n'.join(''.join((node.text or '') if node.tag == word + 't' else breaks.get(node.tag, '')
                                                        for node in paragraph.iter())
                                                for frame in anchor.iter(word + 'txbxContent') for paragraph in frame).strip()
                            image = book.image(data)
                            image.attrib.update({'class': 'word-diagram', 'alt': caption})
                            page = book.el('section'); page.append(image); book.body.append(page)
                        book.warnings.add('Страницы DOCX с рамками сохранены как изображения. Текст страниц доступен для поиска в HomeLibre Reader.')
                        return
        def floating_anchors(paragraph):
            if paragraph.tag != WORD_NS + 'p':
                return None
            anchors = []
            for run in paragraph:
                if run.tag == WORD_NS + 'pPr':
                    continue
                if run.tag != WORD_NS + 'r':
                    return None
                for token in run:
                    if token.tag in (WORD_NS + 'rPr', WORD_NS + 'tab', WORD_NS + 'lastRenderedPageBreak'):
                        continue
                    if token.tag == WORD_NS + 't' and not (token.text or '').strip():
                        continue
                    if token.tag == MC + 'AlternateContent':
                        branches = token.findall(MC + 'Choice')
                        if len(branches) != 1 or len(branches[0]) != 1:
                            return None
                        token = branches[0][0]
                    if token.tag != WORD_NS + 'drawing':
                        return None
                    anchor = token.find(f'{WP}anchor')
                    if anchor is None or anchor.find(f'{A}graphic/{A}graphicData/{WORD_DRAWING_SHAPE}') is None:
                        return None
                    anchors.append(anchor)
            return anchors

        pending = []
        pending_size = 0

        def consume_legend(node):
            nonlocal has_content
            if node.tag != WORD_NS + 'p' or book.omit_images or instruction_depth:
                return False
            text_runs = node.findall(f'{WORD_NS}r/{WORD_NS}t')
            if len(text_runs) != 1 or not re.match(r' {2,24}[-–—] ', text_runs[0].text or ''):
                return False
            direct = (f'{WORD_NS}r/{WORD_NS}drawing/{WP}anchor',
                      f'{WORD_NS}r/{MC}AlternateContent/{MC}Choice/{WORD_NS}drawing/{WP}anchor')
            anchors = [anchor for path in direct for anchor in node.findall(path)]
            previous = not anchors and len(pending) == 1 and len(pending[0][1]) == 1
            if len(anchors) != 1 and not previous:
                return False
            request = ET.Element('figure')
            layout = ET.SubElement(request, 'legend')
            if previous:
                layout.append(pending[0][0])
            layout.append(node)
            request.extend(drawing_context())
            data = book.office_image_decoder().rasterize_word_drawing(book, ET.tostring(request, encoding='utf-8'))
            if data is None:
                return False
            width, height = c.raster_header_size(data)
            if not width or not height:
                return False
            marker_anchor = pending[0][1][0] if previous else anchors[0]
            properties = marker_anchor.find(WP + 'docPr')
            image = book.image(data)
            image.attrib.update({'class': c.WORD_CANVAS_STYLE + ' ' + c.WORD_LEGEND_STYLE,
                                 'alt': properties.get('descr', '') if properties is not None else '',
                                 'style': 'vertical-align:middle',
                                 'width': str((width+1)//3), 'height': str((height+1)//3)})
            if previous:
                pending.clear()
            flush_floating()
            for run in node.findall(WORD_NS + 'r'):
                for child in list(run):
                    if child.tag in {WORD_NS + 'drawing', MC + 'AlternateContent'}:
                        run.remove(child)
            text_runs[0].text = text_runs[0].text.lstrip(' ')
            block((node,), book.body, part, legend=image)
            book.warnings.add('Положение составного рисунка DOCX на печатной странице может измениться. '
                              'Условные обозначения сохранены рядом с подписями.')
            has_content = True
            return True

        def flush_floating():
            nonlocal has_content, pending_size
            if not pending:
                return
            last = next((i for i in range(len(pending)-1, -1, -1) if pending[i][1]), -1)
            anchors = [a for _, group in pending[:last+1] for a in group]
            if len(anchors) >= 2:
                request = ET.Element('figure')
                ET.SubElement(request, 'floating').extend(node for node, _ in pending[:last+1])
                request.extend(drawing_context())
                if nums is not None and any(anchor.find(f'.//{WORD_NS}numPr') is not None for anchor in anchors):
                    request.append(nums)
                if part not in relationships:
                    relationships[part] = p.relationships(part)
                if add_drawing_assets(request, anchors, relationships[part]):
                    data = book.office_image_decoder().rasterize_word_drawing(book, ET.tostring(request, encoding='utf-8'))
                    if data:
                        width, height = c.raster_header_size(data)
                        if width and height:
                            labels = [''.join(node.text or '' for node in paragraph.iter(WORD_NS + 't'))
                                      for anchor in anchors for box in anchor.iter(WORD_NS + 'txbxContent') for paragraph in box]
                            labels.extend(props.get('descr', '') for anchor in anchors if (props := anchor.find(WP + 'docPr')) is not None)
                            image = book.image(data)
                            image.attrib.update({'alt': '\n'.join(label for label in labels if label.strip()),
                                                 'class': 'word-diagram ' + c.WORD_CANVAS_STYLE,
                                                 'style': 'display:block;margin-left:0;margin-right:auto',
                                                 'width': str(max(1, (width+1)//3)), 'height': str(max(1, (height+1)//3))})
                            figure = book.el('p')
                            figure.append(image)
                            book.body.append(figure)
                            book.warnings.add('Положение составного рисунка DOCX на печатной странице может измениться. '
                                              'Фигуры и подписи сохранены вместе у связанного абзаца.')
                            del pending[:last+1]
                            has_content = True
            block((node for node, _ in pending), book.body, part)
            pending.clear()
            pending_size = 0

        def consume_body(node):
            nonlocal pending_size
            if consume_legend(node):
                pending_size = 0
                return
            anchors = None if book.omit_images or instruction_depth else floating_anchors(node)
            if anchors is not None and (anchors or pending):
                size = len(ET.tostring(node, encoding='utf-8'))
                if len(pending) >= 32 or pending_size+size > 1024 * 1024:
                    flush_floating()
                if size <= 1024 * 1024 and (anchors or pending):
                    pending.append((node, anchors))
                    pending_size += size
                    return
            flush_floating()
            block((node,), book.body, part)

        def consume_body_table():
            flush_floating()
            return table_consumer(book.body, part)

        read_docx_blocks(book, p, part, 'body', 2, consume_body, consume_body_table)
        flush_floating()

        def index_notes(part, family, storage):
            # Keep positions on disk so even references introduced by another
            # note can be resolved without keeping the source XML trees alive.
            index = {}

            def record(node):
                identity = val(node, 'id')
                if node.tag != f'{{{W}}}{family}' or identity in index:
                    return
                data = ET.tostring(node, encoding='utf-8')
                index[identity] = storage.tell(), len(data)
                storage.write(data)

            if part in p.names:
                storage.seek(0, 2)
                read_docx_blocks(book, p, part, family + 's', 1, record)
            return index

        if notes:
            book.progress('preparing-docx-notes', 0, 0)
            note_indices = {}
            with tempfile.TemporaryFile(dir=getattr(book, 'work_root', None)) as storage:
                for kind, identity, anchor in notes:
                    family = kind.removesuffix('Reference')
                    part = word_parts[family + 's']
                    if family not in note_indices:
                        note_indices[family] = index_notes(part, family, storage)
                    location = note_indices[family].get(identity)
                    out = book.el('aside', id=anchor, **{'{' + c.EP + '}type': family})
                    if location is None:
                        out.append(book.el('p', '[Сноска отсутствует в исходном документе.]'))
                        book.warnings.add(f'Сноска DOCX отсутствует (идентификатор «{identity[:80]}»).')
                    else:
                        position, size = location
                        storage.seek(position)
                        note = ET.fromstring(storage.read(size))
                        field_depth = instruction_depth = 0
                        note_body_marker = family + 'Ref', note_labels[anchor]
                        block(note, out, part)
                        note_body_marker = None
                    book.body.append(out)
        if not has_content:
            book.fail('В DOCX нет читаемого текста или изображений для конвертации.')
        if omitted_page_overlays:
            book.warnings.add(f'{c.DOCX_PAGE_OVERLAYS} ({omitted_page_overlays}). '
                              'Номера страниц или другие закрытые ими элементы могут выглядеть иначе. '
                              'Чтобы сохранить исходный вид, выберите исходный формат.')
        if omitted_margin_lines:
            book.warnings.add(f'Не перенесены вертикальные линии на полях DOCX. Пропущено линий: {omitted_margin_lines}.')
        if saved_margin_lines:
            book.warnings.add(f'Вертикальные линии на полях ({saved_margin_lines}) перенесены к исходным абзацам. '
                              'При перелистывании и изменении ширины страницы положение линий может отличаться.')
        renamed = deduplicate_anchors(book)
        if renamed:
            book.warnings.add(f'Повторяющиеся закладки DOCX переименованы: {renamed}. Ссылки ведут к первой закладке.')
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
                    resource = n.get('{' + XL + '}href', '')
                    href = posixpath.normpath(unquote(resource))
                    label = urlsplit(resource).path
                    if href.startswith(('/', '../')) or ':' in href or href not in p.names:
                        image = book.unreadable_image(label)
                    else:
                        try:
                            image = book.optional_image(p.data(href), label)
                        except zipfile.BadZipFile:
                            image = book.unreadable_image(label)
                    out.append(image); c.append_text(out, n.tail); continue
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
        headings = {}
        identifiers = {node.get('id') for node in book.body.iter() if node.get('id')}
        for heading in book.body.iter():
            if re.fullmatch('h[1-6]', c.tag(heading)):
                label = ' '.join(c.plain(heading).split())
                headings.setdefault(label, []).append(heading)
        next_id = 1
        for link in book.body.iter('{' + c.XH + '}a'):
            href = unquote(link.get('href', ''))
            match = re.fullmatch(r'#(?:\d+\.)*(.+)\|outline', href)
            if not match or href[1:] in identifiers:
                continue
            candidates = headings.get(' '.join(match[1].split()), [])
            if len(candidates) != 1:
                link.attrib.pop('href')
                book.warnings.add('Некоторые ссылки ODT на заголовки не имеют однозначной цели. Текст ссылок сохранён.')
                continue
            heading = candidates[0]
            identity = heading.get('id')
            if not identity:
                identity = f'odt-outline-{next_id}'
                while identity in identifiers:
                    next_id += 1
                    identity = f'odt-outline-{next_id}'
                identifiers.add(identity)
                heading.set('id', identity)
            link.set('href', '#' + identity)
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


class _RtfRowFormat:
    def __init__(self):
        self.left = 0
        self.header = False
        self.cells = []
        self.horizontal = self.vertical = ''

    def apply(self, word, value):
        if word == 'trleft' and value is not None:
            self.left = value
        elif word == 'trhdr':
            self.header = value != 0
        elif word == 'cellx' and value is not None:
            self.cells.append((value, self.horizontal, self.vertical))
            self.horizontal = self.vertical = ''
        elif word in {'clmgf', 'clmrg'}:
            self.horizontal = word
        elif word in {'clvmgf', 'clvmrg'}:
            self.vertical = word


class _RtfCellSpan(NamedTuple):
    element: ET.Element
    left: int | None
    right: int | None
    vertical_merge: str
    horizontal_origin: bool
    colspan: int = 1


class _RtfTable:
    def __init__(self, book, parent):
        self.book = book
        self.node = book.el('table', **{'data-homelib-rtf-table': '1'})
        parent.append(self.node)
        self.row = self.cell = None
        self.rows = []

    def open_cell(self):
        if self.row is None:
            self.row = self.book.el('tr')
            self.node.append(self.row)
        if self.cell is None:
            self.cell = self.book.el('td')
            self.row.append(self.cell)
        return self.cell

    def end_cell(self):
        self.open_cell()
        self.cell = None

    def end_row(self, layout):
        if self.row is None:
            self.open_cell()
        if self.cell is not None:
            self.book.warnings.add('Строка таблицы RTF заканчивается без границы последней ячейки. Содержимое ячейки сохранено.')
        if layout.cells and len(layout.cells) != len(self.row):
            self.book.warnings.add('В строке таблицы RTF число описаний ячеек отличается от числа ячеек. Доступное содержимое сохранено.')
            for _ in range(len(self.row), len(layout.cells)):
                self.row.append(self.book.el('td'))
        self.rows.append((self.row, layout))
        self.row = self.cell = None

    def finish(self):
        previous_vertical = {}
        formatted_rows = []
        for row, layout in self.rows:
            edges = [layout.left] + [cell[0] for cell in layout.cells]
            left = layout.left
            positioned = len(edges) == len(row) + 1 and all(start < end for start, end in zip(edges, edges[1:]))
            # End-of-row properties repeat the initial definition in Word.
            # Each cell gets the final properties once.
            entries = []
            for index, cell in enumerate(list(row)):
                right, horizontal, vertical = layout.cells[index] if index < len(layout.cells) else (None, '', '')
                if layout.header:
                    cell.tag = '{' + self.book.c.XH + '}th'
                if horizontal == 'clmrg' and entries and entries[-1].horizontal_origin:
                    first = entries[-1]
                    first.element.extend(cell)
                    row.remove(cell)
                    entries[-1] = first._replace(right=right, colspan=first.colspan + 1)
                else:
                    if horizontal == 'clmrg':
                        self.book.warnings.add('У горизонтального объединения ячеек RTF отсутствует начало. Ячейки сохранены отдельно.')
                    entries.append(_RtfCellSpan(cell, left, right, vertical, horizontal == 'clmgf'))
                left = right
            current_vertical = {}
            for index, entry in enumerate(entries):
                cell, left, right, vertical, _, colspan = entry
                if colspan > 1:
                    cell.set('colspan', str(colspan))
                position = (left, right) if positioned else ('column', index)
                if vertical == 'clvmgf':
                    current_vertical[position] = cell
                elif vertical == 'clvmrg':
                    origin = previous_vertical.get(position)
                    if origin is not None and not _table_cell_has_content(cell):
                        origin.set('rowspan', str(int(origin.get('rowspan', '1')) + 1))
                        current_vertical[position] = origin
                        row.remove(cell)
                    else:
                        self.book.warnings.add('Вертикальное объединение ячеек RTF не восстановлено. Доступные ячейки и их содержимое сохранены.')
                        current_vertical[position] = cell
            previous_vertical = current_vertical
            if positioned:
                formatted_rows.append((row, entries, edges))

        if not formatted_rows:
            return
        # Use one column grid when rows share the same outer edges. If row
        # widths differ, keep their own widths and explicit merges.
        outer = {(edges[0], edges[-1]) for _, _, edges in formatted_rows}
        boundaries = sorted({edge for _, _, edges in formatted_rows for edge in edges})
        grid = {edge: index for index, edge in enumerate(boundaries)} if len(outer) == 1 and len(boundaries) <= 256 else {}
        for row, entries, edges in formatted_rows:
            row_width = edges[-1] - edges[0]
            retained = set(row)
            for cell, left, right, _, _, _ in entries:
                if cell not in retained:
                    continue
                cell.set('style', f'width:{(right-left)*100/row_width:.4f}%')
                if grid:
                    span = grid[right] - grid[left]
                    if span > 1:
                        cell.set('colspan', str(span))


class _RtfTables:
    def __init__(self, book):
        self.book = book
        self.tables = []
        self.layouts = {}

    def control(self, level, word, value):
        if word == 'trowd' or level not in self.layouts:
            self.layouts[level] = _RtfRowFormat()
        self.layouts[level].apply(word, value)

    def close_after(self, level):
        while len(self.tables) > level:
            depth = len(self.tables)
            table = self.tables.pop()
            layout = self.layouts.pop(depth, None)
            if table.row is not None:
                self.book.warnings.add('Строка таблицы RTF обрывается. Доступные ячейки сохранены.')
                table.end_row(layout or _RtfRowFormat())
            table.finish()

    def table(self, level):
        self.close_after(level)
        while len(self.tables) < level:
            parent = self.tables[-1].open_cell() if self.tables else self.book.body
            self.tables.append(_RtfTable(self.book, parent))
        return self.tables[-1]

    def paragraph(self, node, level):
        if level:
            self.table(level).open_cell().append(node)
        else:
            self.close_after(0)
            self.book.body.append(node)

    def end_cell(self, level):
        self.table(level).end_cell()

    def end_row(self, level):
        self.table(level).end_row(self.layouts.pop(level, _RtfRowFormat()))


def rtf_horizontal_rule(group):
    instance = re.fullmatch(r'\{\s*\\shp\s*\{\s*\\\*\s*\\shpinst\s*(.*?)\}\s*\}', group, re.S)
    if not instance:
        return None
    geometry, _, properties = instance[1].partition('{')
    control = re.compile(r'\\([a-zA-Z]+)(-?\d{1,8})?\s*')
    matches = list(control.finditer(geometry))
    if control.sub('', geometry).strip() or any(m[1] not in {
            'shpleft', 'shptop', 'shpright', 'shpbottom', 'shpfhdr', 'shpwr', 'shpwrk', 'shplid', 'shpz',
            'shpbxpage', 'shpbxmargin', 'shpbxcolumn', 'shpbypara', 'shpfblwtxt'} for m in matches):
        return None
    bounds = [(m[1], m[2]) for m in matches if m[1] in ('shpleft', 'shptop', 'shpright', 'shpbottom')]
    if len(bounds) != 4 or len({name for name, _ in bounds}) != 4 or any(value is None for _, value in bounds):
        return None
    values = {name: int(value) for name, value in bounds}
    prop = re.compile(r'\{\s*\\sp\s*\{\s*\\sn\s+([a-zA-Z0-9]+)\s*\}\s*\{\s*\\sv\s+([^{}\\]+)\}\s*\}\s*')
    properties = '{' + properties
    fields = [(m[1], m[2].strip()) for m in prop.finditer(properties)]
    values_by_name = dict(fields)
    if prop.sub('', properties).strip() or len(values_by_name) != len(fields):
        return None
    controls = {match[1]: match[2] for match in matches}
    if values_by_name.get('shapeType') == '20':
        # The native OfficeArt line needs no path vertices. Preserve only a
        # solid horizontal stroke whose origin is an ordinary body paragraph.
        x, top, right, bottom = (values['shp'+key] for key in ('left', 'top', 'right', 'bottom'))
        reference = controls.keys() & {'shpbxmargin', 'shpbxcolumn'}
        weight = values_by_name.get('lineWidth', '')
        color = values_by_name.get('lineColor', '0')
        if (len(controls) != len(matches) or len(reference) != 1 or 'shpbxpage' in controls or
                'shpbypara' not in controls or any(controls[key] is not None for key in reference | {'shpbypara'}) or
                controls.get('shpwr') != '3' or controls.get('shpfhdr', '0') != '0' or
                controls.get('shpwrk', '0') != '0' or controls.get('shpfblwtxt', '0') not in {'0', '1'} or
                values_by_name.keys() - {'shapeType', 'lineWidth', 'lineColor', 'fLine', 'lineType'} or
                values_by_name.get('fLine', '1') != '1' or values_by_name.get('lineType', '0') != '0' or
                not re.fullmatch(r'[0-9]{1,6}', weight) or not re.fullmatch(r'[0-9]{1,8}', color) or
                top != bottom or not 0 <= x < right <= 28800 or not 0 <= int(color) <= 0xffffff):
            return None
        thickness = round(int(weight) / 635)
        if 0 < thickness and abs(top) + thickness <= 720:
            return right-x, thickness, int(color).to_bytes(3, 'little'), (x, top)
        return None
    if 'shpbxmargin' in controls or 'shpbxcolumn' in controls:
        return None
    if values_by_name.keys() - {
        'shapeType', 'shapePath', 'pVerticies', 'pVertices', 'pSegmentInfo', 'geoLeft', 'geoTop', 'geoRight',
        'geoBottom', 'fFillOK', 'fFilled', 'fillColor', 'fLine', 'lineWidth', 'lineType', 'lineColor',
        'fArrowheadsOK', 'rotation', 'fFlipH', 'fFlipV', 'dxWrapDistLeft', 'dxWrapDistRight', 'posrelh', 'posrelv'
    }:
        return None
    if values_by_name.get('shapeType') != '0' or values_by_name.get('shapePath') != '4' or any(
            values_by_name.get(key, '0') != '0' for key in ('rotation', 'fFlipH', 'fFlipV', 'lineType')):
        return None

    def number(key, default='0'):
        value = values_by_name.get(key, default)
        if value is None:
            raise ValueError
        if not re.fullmatch(r'-?\d{1,8}', value):
            raise ValueError
        return int(value)

    vertices = values_by_name.get('pVerticies', values_by_name.get('pVertices', '')).split(';')
    if len(vertices) not in (4, 7) or vertices[:2] != ['8', str(len(vertices) - 2)]:
        return None
    points = [re.fullmatch(r'\((-?\d{1,8}),(-?\d{1,8})\)', vertex.strip()) for vertex in vertices[2:]]
    if not all(points):
        return None
    coordinates = [(int(point[1]), int(point[2])) for point in points]
    # Only an explicit horizontal stroke or a closed, solid rectangular strip
    # has the same geometry as a flat raster rule.
    xs, ys = map(set, zip(*coordinates))
    if len(xs) != 2:
        return None
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    segments = values_by_name.get('pSegmentInfo')
    try:
        geo_left, geo_top = number('geoLeft'), number('geoTop')
        geo_right, geo_bottom = number('geoRight'), number('geoBottom')
        width = values['shpright'] - values['shpleft']
        height = values['shpbottom'] - values['shptop']
        if not (0 < width <= 240000 and 0 <= height <= 240000 and
                geo_left <= left < right <= geo_right and geo_top <= top <= bottom <= geo_bottom):
            return None
        width = round(width * (right - left) / (geo_right - geo_left))
        if (segments == '2;5;16384;45824;1;45824;32768' and len(points) == 2 and top == bottom
                and number('fFilled') == 0 and number('fLine') == 1):
            thickness = round(number('lineWidth', None) / 635)
            color = number('lineColor', None)
        elif (segments == '2;12;16384;45824;1;45824;1;45824;1;45824;1;45824;24577;32768'
                and len(points) == 5 and top < bottom and coordinates[0] == coordinates[-1]
                and set(coordinates[:-1]) == {(x, y) for x in xs for y in ys}
                and all(a[0] == b[0] or a[1] == b[1] for a, b in zip(coordinates, coordinates[1:]))
                and number('fFilled') == 1 and number('fLine') == 0):
            thickness = round(height * (bottom - top) / (geo_bottom - geo_top))
            color = number('fillColor', None)
        else:
            return None
    except (KeyError, ValueError):
        return None
    if 0 < width <= 240000 and 0 < thickness <= 720 and 0 <= color <= 0xffffff:
        return width, thickness, color.to_bytes(3, 'little')
    return None


def rtf_compatibility_line(group, *, horizontal=False):
    instance = re.fullmatch(
        r'\{\s*\\shp\s*\{\s*\\\*\s*\\shpinst\s*(.*?)\}\s*'
        r'\{\s*\\shprslt\s*\{\s*\\\*\s*\\do\s*([^{}]*)\}\s*\}\s*\}', group, re.S)
    if not instance:
        return None
    geometry, _, properties = instance[1].partition('{')
    control = re.compile(r'\\([a-zA-Z]+)(-?[0-9]{1,8})?\s*')
    modern_fields = control.findall(geometry)
    modern = dict(modern_fields)
    switches = {'shpbxcolumn', 'shpbxignore', 'shpbypara', 'shpbyignore'}
    if (len(modern) != len(modern_fields) or control.sub('', geometry).strip() or modern.keys() - {
            'shpleft', 'shptop', 'shpright', 'shpbottom', 'shpfhdr', 'shpbxcolumn', 'shpbxignore',
            'shpbypara', 'shpbyignore', 'shpwr', 'shpwrk', 'shpfblwtxt', 'shpz', 'shplid'} or
            not {'shpbxcolumn', 'shpbypara'}.issubset(modern) or modern.get('shpwr') != '3' or
            modern.get('shpfhdr', '0') != '0' or
            modern.get('shpfblwtxt', '0') not in ({'0', '1'} if horizontal else {'0'}) or
            any((value == '') != (key in switches) for key, value in modern_fields)):
        return None
    if horizontal and modern.get('shpwrk', '0') != '0':
        return None
    property_pattern = re.compile(r'\{\s*\\sp\s*\{\s*\\sn\s+([a-zA-Z0-9]+)\s*\}\s*'
                                  r'\{\s*\\sv\s+(-?[0-9]{1,10})\s*\}\s*\}\s*')
    properties = '{' + properties
    fields = property_pattern.findall(properties)
    shape = dict(fields)
    supported = {'shapeType', 'shapePath', 'fFlipH', 'fFlipV', 'fFillOK', 'fFilled', 'fArrowheadsOK',
                 'dhgt', 'fLayoutInCell', 'fPseudoInline'}
    if horizontal:
        supported.update({'lineWidth', 'lineColor', 'fLine', 'lineType'})
    if (property_pattern.sub('', properties).strip() or shape.keys() - supported or
            any(shape[key] != value for key, value in fields) or
            shape.get('shapeType') != '20' or shape.get('fFilled', '0') != '0'):
        return None
    # This compatibility drawing states the line thickness and RGB color. Its
    # placement must agree with the newer shape before using either geometry.
    fallback = instance[2]
    legacy_fields = control.findall(fallback)
    legacy = dict(legacy_fields)
    switches = {'dobxcolumn', 'dobypara', 'dpline', 'dplinesolid'}
    if (len(legacy_fields) != len(legacy) + 2 or control.sub('', fallback).strip() or legacy.keys() - {
            'dobxcolumn', 'dobypara', 'dodhgt', 'dpline', 'dpptx', 'dppty', 'dpx', 'dpy', 'dpxsize',
            'dpysize', 'dplinew', 'dplinecor', 'dplinecog', 'dplinecob', 'dplinesolid'} or
            not {'dobxcolumn', 'dobypara', 'dpline'}.issubset(legacy) or
            any((value == '') != (key in switches) for key, value in legacy_fields)):
        return None
    try:
        x, top, right, bottom = (int(modern['shp' + key]) for key in ('left', 'top', 'right', 'bottom'))
        width, height = right - x, bottom - top
        if horizontal:
            if (height or not -1440 <= x < right or not 0 < right <= 28800 + min(x, 0) or
                    any(shape.get(key, '0') != '0' for key in ('fFlipH', 'fFlipV', 'fPseudoInline', 'lineType'))):
                return None
            if shape.get('fLine', '1') != '1' or shape.get('shapePath', '4') != '4':
                return None
        elif width or max(abs(x), abs(top), abs(bottom)) > 240000 or not 0 < height <= 240000:
            return None
        if ([int(value) for key, value in legacy_fields if key == 'dpptx'] != [0, width] or
                [int(value) for key, value in legacy_fields if key == 'dppty'] != [0, height]):
            return None
        bounds = tuple(int(legacy[key]) for key in ('dpx', 'dpy', 'dpxsize', 'dpysize'))
        thickness = int(legacy['dplinew'])
        if bounds != (x, top, width, height) or not 0 < thickness <= 720:
            return None
        color = bytes(int(legacy['dplineco' + channel]) for channel in 'rgb')
        if horizontal:
            if (abs(top) + thickness > 720 or
                    ('lineWidth' in shape and round(int(shape['lineWidth']) / 635) != thickness) or
                    ('lineColor' in shape and int(shape['lineColor']) != int.from_bytes(color, 'little'))):
                return None
            return width, thickness, color, (x, top)
    except (KeyError, ValueError):
        return None
    return x, top, bottom, thickness, color


def read_rtf(book, data):
    # Stateful token reader: group-scoped destinations/formatting/codepage/uc,
    # Unicode fallback bytes, escaped braces and binary blocks are distinct.
    if not data.lstrip().startswith(b'{\\rtf'): book.fail('Файл не является RTF.')
    text = data.decode('latin1'); at = 0; stack = []; state = {'skip': False, 'uc': 1, 'cp': 'cp1252', 'b': False, 'i': False, 's': False, 'u': False, 'sup': False, 'sub': False, 'fonttable': False, 'fontid': None, 'pict': None,
                'object': None, 'object_data': False, 'group_start': 0, 'destination': '',
                'shape': None, 'shape_property': None, 'shape_variant': '', 'shape_group': None,
                'group_picture_value': False,
                'primary_picture': None, 'table_level': 0, 'nested_table_properties': False,
                'paragraph_alignment': None, 'frame': {}}
    fonts = {}; default_font = None
    charsets = {204: 'cp1251', 238: 'cp1250', 161: 'cp1253', 162: 'cp1254', 177: 'cp1255', 178: 'cp1256', 186: 'cp1257', 163: 'cp1258', 128: 'cp932', 129: 'cp949', 134: 'cp936', 136: 'cp950', 222: 'cp874'}
    tables = _RtfTables(book)
    paragraph = book.el('p'); paragraph_level = None; fallback = 0; buffer = bytearray(); run_count = 0
    object_count = shape_count = 0
    rule_png = None
    rule_bitmaps = {}
    vertical_rules = []
    floating_notice = 'Положение плавающих объектов RTF изменено. Они перенесены к месту привязки в тексте.'
    alignment_commands = {'ql': 'left', 'qr': 'right', 'qc': 'center', 'qj': 'justify'}
    frame_commands = {'phpg': 'horizontal', 'phmrg': 'horizontal', 'phcol': 'horizontal',
                      'pvpg': 'vertical', 'pvmrg': 'vertical', 'pvpara': 'vertical',
                      'posx': 'x', 'posnegx': 'x', 'posy': 'y', 'posnegy': 'y', 'absw': 'width'}
    paragraph_alignment = None
    positioned_text = False
    positioned_paragraphs = 0
    run_parent = run_style = run_target = None
    run_parts = []
    formatting = [('b', 'strong'), ('i', 'em'), ('s', 's'), ('u', 'u'), ('sup', 'sup'), ('sub', 'sub')]
    token = re.compile(r'([a-zA-Z]+)(-?\d+)? ?')
    picture_literal = re.compile(r'[^{}\\]{1,262144}')
    destination_prefix = re.compile(r'[ \t\r\n]*(?:\\\*[ \t\r\n]*)?')
    visible_starred = re.compile(r'[ \t\r\n]*\\(?:pict|shppict|nonshppict|nesttableprops)(?![a-zA-Z])')
    backup_picture = re.compile(r'[ \t\r\n]*\{[ \t\r\n]*(?:\\\*[ \t\r\n]*)?\\nonshppict(?![a-zA-Z])')
    image_property = re.compile(r'[ \t\r\n]*pib[ \t\r\n]*\}')
    picture_id = re.compile(r'[ \t\r\n]*([0-9a-fA-F]{32})[ \t\r\n]*\}')
    word_picture_class = re.compile(r'[ \t\r\n]*Word\.Picture\.[0-9]+[ \t\r\n]*\}')
    skip_backup_end = -1
    destinations = {'fonttbl', 'colortbl', 'stylesheet', 'info', 'filetbl', 'listtable', 'listoverridetable', 'revtbl', 'rsidtbl', 'generator', 'header', 'headerl', 'headerr', 'footer', 'footerl', 'footerr', 'annotation', 'datastore', 'themedata', 'colorschememapping', 'fldinst', 'do', 'nonesttables'}
    shape_destinations = {'shp', 'shpgrp', 'shpinst', 'sp', 'sn', 'sv', 'shptxt', 'shprslt'}
    picture_dimensions = {'picwgoal', 'pichgoal', 'picscalex', 'picscaley',
                          'piccropl', 'piccropr', 'piccropt', 'piccropb'}
    row_controls = {'trowd', 'trleft', 'trhdr', 'cellx', 'clmgf', 'clmrg', 'clvmgf', 'clvmrg'}
    def finish_run():
        if run_parts:
            book.c.append_text(run_target, ''.join(run_parts)); run_parts.clear()
    def content_level():
        depth = state['table_level']
        if depth:
            return depth
        # Some Word writers reset paragraph properties inside a cell.
        # Its text remains in that cell until the actual cell boundary.
        if paragraph_level:
            return paragraph_level
        if tables.tables and tables.tables[-1].cell is not None:
            return len(tables.tables)
        return 0
    def finish_paragraph(level=None, keep_empty=False):
        nonlocal paragraph, paragraph_level, run_parent, paragraph_alignment, positioned_text, positioned_paragraphs
        finish_run()
        if vertical_rules:
            place_vertical_rules()
            vertical_rules.clear()
        if keep_empty or paragraph.text or len(paragraph):
            if paragraph_alignment is not None:
                marker = f'{book.c.WORD_SPACER_PARAGRAPH}{paragraph_alignment}-none'
                paragraph.set('class', marker)
                paragraph.set('style', book.c.word_spacer_css(marker))
            if positioned_text:
                positioned_paragraphs += 1
            depth = paragraph_level if level is None else level
            tables.paragraph(paragraph, content_level() if depth is None else depth)
        paragraph = book.el('p')
        paragraph_level = run_parent = None
        paragraph_alignment = None
        positioned_text = False
    def paragraph_content():
        nonlocal paragraph_level
        depth = content_level()
        if paragraph_level is not None and paragraph_level != depth:
            finish_paragraph()
        paragraph_level = depth
    def emit(value, preview=True):
        nonlocal run_count, run_parent, run_style, run_target, paragraph_alignment, positioned_text
        if state['skip'] or state['pict'] is not None or not value: return
        if state['nested_table_properties']: return
        paragraph_content()
        if preview and value.strip():
            paragraph_alignment = state['paragraph_alignment']
            if not positioned_text and (frame := state['frame']):
                positioned_text = (frame.get('horizontal') == 'phpg' and frame.get('vertical') == 'pvpg'
                                   and 'x' in frame and 'y' in frame and frame.get('width', 0) > 0)
            if state['object'] is not None:
                state['object']['visible'] = True
            if state['shape'] is not None:
                state['shape']['text'] = True
        style = tuple(state[prop] for prop, _ in formatting)
        # Adjacent Unicode controls belong to one text run. In particular, a
        # surrogate pair must reach XML as one value even inside bold/italic.
        if run_parent is not paragraph or run_style != style:
            run_count += 1
            if run_count > 500000:
                book.fail('В RTF слишком много отдельных фрагментов текста для конвертации.')
            finish_run()
            target = paragraph
            for (_, name), enabled in zip(formatting, style):
                if enabled:
                    child = book.el(name); target.append(child); target = child
            run_parent, run_style, run_target = paragraph, style, target
        run_parts.append(value)
    def flush():
        if buffer:
            try:
                decoded = buffer.decode(state['cp'])
            except UnicodeDecodeError:
                decoded = buffer.decode(state['cp'], errors='replace')
                book.warnings.add('Нечитаемые символы RTF отмечены знаком �.')
            except LookupError:
                book.fail('Неподдерживаемая кодировка RTF: ' + state['cp'])
            emit(decoded)
            buffer.clear()
    def char(value):
        nonlocal fallback
        if fallback: fallback -= 1
        elif state['skip']:
            if state['object_data'] and value.strip():
                state['object']['has_data'] = True
        elif state['pict'] is not None:
            state['pict']['hex'].append(value)
        else: buffer.extend(value.encode('latin1'))
    def append_picture(image):
        nonlocal run_parent
        paragraph_content()
        finish_run()
        paragraph.append(image)
        run_parent = None
    def encode_rule(rgb, pixels, rows, alpha=None):
        nonlocal rule_png
        if rule_png is None:
            import importlib.util
            spec = importlib.util.spec_from_file_location('homelib_fixed_layout', Path(__file__).with_name('fixed_layout.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            rule_png = module.png
        return rule_png(rgb, pixels, rows, alpha=alpha)

    def rule_image(width, height, color):
        pixels, rows = max(1, round(width / 15)), max(1, round(height / 15))
        key = pixels, rows, color
        if key not in rule_bitmaps:
            rule_bitmaps[key] = encode_rule(color * (pixels * rows), pixels, rows)
        image = book.image(rule_bitmaps[key])
        book.c.set_html_image_extent(image, pixels, rows)
        return image

    def render_rule(width, thickness, color, position=None):
        if position is not None:
            # Reflow cannot keep a drawing behind the original fixed page.
            # Include the authored offsets in a transparent strip near its
            # paragraph so the stroke never paints over reflowed text.
            left, top = position
            origin = min(0, left)
            left -= origin
            right, height = left + width, abs(top) + thickness
            y = max(0, top)
            pixels, rows = (right + 14) // 15, (height + 14) // 15
            horizontal = [max(0, min((x + 1) * right, right * pixels) - max(x * right, left * pixels))
                          for x in range(pixels)]
            vertical = [max(0, min((row + 1) * height, (y + thickness) * rows) - max(row * height, y * rows))
                        for row in range(rows)]
            alpha = bytes(round(255 * vx * vy / (right * height)) for vy in vertical for vx in horizontal)
            image = book.image(encode_rule(color * (pixels * rows), pixels, rows, alpha))
            book.c.style_word_line(image, f'{book.c.WORD_LINE_CLASS}{right}:{height}:{origin}', (right, height, origin))
            append_picture(image)
            return
        image = rule_image(width, thickness, color)
        image.set('class', 'paragraph-rule')
        image.set('style', (image.get('style', '') +
                            f';display:block;width:{width / 20:g}pt;height:{thickness / 20:g}pt;max-width:100%').lstrip(';'))
        append_picture(image)

    def place_vertical_rules():
        markers = {marker for marker, _ in vertical_rules}
        contents = [node for node in paragraph if node not in markers]
        if (len(contents) == 1 and book.c.tag(contents[0]) == 'img' and
                not (paragraph.text or '').strip() and not any((node.tail or '').strip() for node in paragraph)):
            image = contents[0]
            width, height = (book.c.html_image_pixels(image.get(key)) * 15 for key in ('width', 'height'))
            resource = book.resources.get(image.get('src'))
            if width and height and resource and resource[1] != 'image/gif':
                rectangles = [(Fraction(2*x-thickness, 2), top, Fraction(2*x+thickness, 2), bottom, color)
                              for _, (x, top, bottom, thickness, color) in vertical_rules]
                left = min([0] + [rect[0] for rect in rectangles])
                top = min([0] + [rect[1] for rect in rectangles])
                right = max([width] + [rect[2] for rect in rectangles])
                bottom = max([height] + [rect[3] for rect in rectangles])
                if right-left <= width*2 and bottom-top <= height*2:
                    data = resource[0].read_bytes() if isinstance(resource[0], Path) else resource[0]
                    fills = [(x/width, Fraction(y, height), end_x/width, Fraction(end_y, height), color)
                             for x, y, end_x, end_y, color in rectangles]
                    offsets = (Fraction(left, width), Fraction(top, height),
                               Fraction(width-right, width), Fraction(height-bottom, height))
                    try:
                        data = book.office_image_decoder().crop_raster_image(book, data, offsets, fills=fills)
                        combined = book.image(data)
                    except (ValueError, OSError, book.c.UnreadableImage):
                        pass
                    else:
                        combined.set('alt', image.get('alt', ''))
                        book.c.set_html_image_extent(combined, round((right-left)/15), round((bottom-top)/15))
                        index = list(paragraph).index(image)
                        paragraph.text = (paragraph.text or '') + ''.join(node.tail or '' for node in paragraph[:index])
                        combined.tail = ''.join(node.tail or '' for node in paragraph[index:])
                        paragraph[:] = [combined]
                        return
        # Keep the stroke in reading order when text, several images or an
        # unavailable decoder prevent composing a single anchored picture.
        for marker, (_, top, bottom, thickness, color) in vertical_rules:
            image = rule_image(thickness, bottom-top, color)
            image.tail = marker.tail
            index = list(paragraph).index(marker)
            paragraph[index] = image

    def render_picture(picture, report_failure=True, raster_only=False):
        shape = state['shape']; primary = state['primary_picture']
        sizing = picture['size']
        goals = (sizing.get('picwgoal', 0), sizing.get('pichgoal', 0))
        scales = (sizing.get('picscalex', 100), sizing.get('picscaley', 100))
        crop = tuple(sizing.get(edge, 0) for edge in ('piccropl', 'piccropt', 'piccropr', 'piccropb'))
        try:
            raw = picture['bin'] if picture['bin'] is not None else bytes.fromhex(''.join(picture['hex']))
            if not raw: raise ValueError('Empty picture')
            if raster_only and (len(raw) > 16 * 1024 * 1024 or
                                not raw.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'GIF8'))):
                return False
            book.c.check_embedded_raster(raw)
            if any(crop):
                try:
                    raster = raw
                    natural = book.c.raster_header_size(raster)
                    if min(goals) <= 0 and min(natural) <= 0:
                        raster = book.office_image_decoder().rasterize_image(book, raw)
                        natural = book.c.raster_header_size(raster)
                    width, height = (min(240000, goal if goal > 0 else pixels * 15)
                                     for goal, pixels in zip(goals, natural))
                    if min(width, height) <= 0:
                        raise ValueError('Unknown RTF picture size')
                    cropped_width = width - crop[0] - crop[2]
                    cropped_height = height - crop[1] - crop[3]
                    offsets = [Fraction(edge, extent) for edge, extent in zip(crop, (width, height, width, height))]
                    raw = book.office_image_decoder().crop_raster_image(book, raster, offsets)
                    goals = (cropped_width, cropped_height)
                except (ValueError, OSError, book.c.UnreadableImage):
                    book.warnings.add('Обрезка иллюстраций RTF не перенесена. Изображения сохранены целиком.')
            image = book.image(raw)
        except (ValueError, book.c.UnreadableImage):
            # A valid alternate can render the same illustration without a gap.
            if report_failure and primary is None:
                if shape is not None: shape['failed'] = True
                else: append_picture(book.unreadable_image())
            return False
        if primary is not None: primary['rendered'] = True
        if shape is not None: shape['picture'] = True
        if state['object'] is not None: state['object']['visible'] = True
        if any(goal > 0 for goal in goals) or scales != (100, 100):
            natural = (0, 0)
            if min(goals) <= 0:
                data, _ = book.resources[image.get('src')]
                natural = book.c.raster_header_size(data)
            extent = []
            for goal, scale, pixels in zip(goals, scales, natural):
                twips = min(240000, goal if goal > 0 else pixels * 15)
                scale = min(1000, max(1, scale))
                extent.append(max(1, (twips * scale + 750) // 1500) if twips else 0)
            largest = max(16384, *extent)
            width, height = (max(1, (pixels * 16384 + largest // 2) // largest) if pixels else 0
                             for pixels in extent)
            book.c.set_html_image_extent(image, width, height)
        append_picture(image)
        if shape is not None:
            if state['shape_variant'] == 'pib':
                shape['property_picture'] = paragraph, image, crop
            elif (state['shape_variant'] == 'text' and state['object'] is not None
                  and state['object']['depth'] > shape['depth']
                  and state['object'].get('picture_preview')
                  and (stored := shape.get('property_picture')) is not None):
                parent, picture, property_crop = stored
                if image.attrib == picture.attrib and crop == property_crop:
                    # Word can keep the same graphic in the shape and the
                    # displayed result of its embedded Word.Picture object.
                    position = list(parent).index(picture)
                    if picture.tail:
                        if position:
                            previous = parent[position - 1]
                            previous.tail = (previous.tail or '') + picture.tail
                        else:
                            parent.text = (parent.text or '') + picture.tail
                    parent.remove(picture)
                    del shape['property_picture']
        return True

    def render_group_preview(group, picture):
        # A Word blip UID identifies the same source graphic. Check that the
        # two entries also specify the same placement size, scale and crop.
        original = group['picture_ids'].get(picture.get('uid'))
        if (original is not None and original['size'] == picture['size'] and
                render_picture(original, report_failure=False, raster_only=True)):
            book.warnings.add(floating_notice)
            group['has_preview'] = True
        elif render_picture(picture, report_failure=False):
            group['has_preview'] = True
        else:
            group['unreadable_previews'] += 1

    def finish_picture_group(group):
        if not group['has_preview'] and group['originals']:
            recovered = False
            for picture in group['originals']:
                recovered = render_picture(picture) or recovered
            book.warnings.add(floating_notice)
            if recovered and group['unreadable_previews']:
                book.warnings.add('Часть изображений RTF в запасном представлении не читается. '
                                  'Использованы изображения исходной группы.')
        else:
            for _ in range(group['unreadable_previews']):
                append_picture(book.unreadable_image())

    while at < len(text):
        if state['pict'] is not None and not fallback:
            literal = picture_literal.match(text, at)
            if literal:
                if not state['skip']:
                    state['pict']['hex'].append(literal[0].replace('\r', '').replace('\n', ''))
                at = literal.end()
                continue
        ch = text[at]; at += 1
        if ch == '{':
            flush(); fallback = 0; stack.append(state.copy())
            if len(stack) > 128: book.fail('Слишком глубокая структура RTF.')
            state['group_start'] = at
            state['destination'] = ''
        elif ch == '}':
            flush(); fallback = 0
            if not stack: book.fail('Нарушена структура групп RTF.')
            parent = stack.pop()
            group = state['shape_group']
            if (picture := state['pict']) is not None and picture is not parent['pict'] and not state['skip']:
                if picture.get('group_original'):
                    group['originals'].append(picture)
                    if uid := picture.get('uid'):
                        ids = group['picture_ids']
                        ids[uid] = None if uid in ids else picture
                elif picture.get('group_preview'):
                    render_group_preview(group, picture)
                else:
                    render_picture(picture)
            embedded = state['object']
            shape = state['shape']
            primary = state['primary_picture']
            was_fonts = state['fonttable']; state = parent
            if was_fonts and not state['fonttable'] and default_font in fonts: state['cp'] = fonts[default_font]
            if group is not None and group is not state['shape_group']:
                finish_picture_group(group)
            if primary is not None and primary is not state['primary_picture']:
                alternate = primary['may_use_backup'] and backup_picture.match(text, at)
                if primary['rendered'] and alternate:
                    skip_backup_end = alternate.end()
                if not primary['rendered'] and not alternate:
                    if shape is not None: shape['failed'] = True
                    else: append_picture(book.unreadable_image())
            if shape is not None and shape is not state['shape']:
                omit_rule = False
                if not shape['picture'] and not shape['text'] and not shape['failed'] and at - shape['start'] <= 4096:
                    group = text[shape['start']:at]
                    if rule := rtf_horizontal_rule(group) or rtf_compatibility_line(group, horizontal=True):
                        omit_rule = book.omit_images
                        if not omit_rule:
                            render_rule(*rule)
                            shape['picture'] = True
                    elif rule := rtf_compatibility_line(group):
                        omit_rule = book.omit_images
                        if not omit_rule:
                            marker = book.el('span')
                            append_picture(marker)
                            vertical_rules.append((marker, rule))
                            shape['picture'] = True
                if shape['picture'] or shape['text']:
                    book.warnings.add(floating_notice)
                if shape['failed'] and not shape['picture']:
                    append_picture(book.unreadable_image())
                elif not shape['picture'] and not shape['text'] and not omit_rule:
                    index = shape['index']
                    emit(f'[Фигура RTF № {index} не перенесена.]', preview=False)
                    book.warnings.add(f'Не перенесена фигура RTF № {index}.')
            if embedded is not None and embedded is not state['object']:
                if embedded['visible']:
                    if state['object'] is not None:
                        state['object']['visible'] = True
                    if embedded['has_data']:
                        book.warnings.add('Встроенные объекты RTF перенесены как статическое содержимое. Данные для редактирования объектов не перенесены.')
                else:
                    index = embedded['index']
                    emit(f'[Встроенный объект RTF № {index} не перенесён.]', preview=False)
                    book.warnings.add(f'Не перенесён встроенный объект RTF № {index}.')
            if not stack:
                if text[at:].strip(' \t\r\n\0'):
                    finish_paragraph()
                    tables.close_after(0)
                    book.body.append(book.el('p', '[После окончания RTF обнаружены нечитаемые данные.]'))
                    book.warnings.add('После окончания RTF обнаружены данные, которые не удалось прочитать.')
                break
        elif ch == '\\':
            if at >= len(text): book.fail('Оборванный управляющий код RTF.')
            control_start = at - 1
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
                if symbol == '*':
                    flush()
                    # Word stores the primary picture in a starred destination
                    # and may also store a duplicate WMF fallback in nonshppict.
                    if not visible_starred.match(text, at): state['skip'] = True
                elif symbol in {'~', '_', '-'}:
                    flush(); emit({'~': '\u00a0', '_': '\u2011', '-': '\u00ad'}[symbol])
                continue
            flush(); at = match.end(); word = match[1]; arg = int(match[2]) if match[2] else None
            if word == 'bin':
                if arg is None or arg < 0 or at + arg > len(text): book.fail('Оборванный двоичный блок RTF.')
                if fallback: fallback -= 1
                elif state['pict'] is not None and not state['skip']: state['pict']['bin'] = text[at:at+arg].encode('latin1')
                elif arg and state['object_data']: state['object']['has_data'] = True
                at += arg; continue
            # A fallback control word counts as one character, including its
            # delimiter. It must neither render nor consume the following text.
            if fallback: fallback -= 1; continue
            if word in shape_destinations and destination_prefix.fullmatch(text, state['group_start'], control_start):
                parent_destination = stack[-1]['destination'] if stack else ''
                state['destination'] = word
                shape = state['shape']
                group = state['shape_group']
                depth_in_group = len(stack) - group['depth'] if group is not None else -1
                if word == 'shpgrp' and not state['skip'] and shape is None:
                    state['shape_group'] = {'depth': len(stack), 'originals': [], 'picture_ids': {},
                                            'has_preview': False, 'unreadable_previews': 0}
                elif word == 'shpinst' and depth_in_group == 1 and parent_destination == 'shpgrp':
                    state['skip'] = True
                elif depth_in_group == 4 and [frame['destination'] for frame in stack[-4:]] == [
                        'shpgrp', 'shpinst', 'shp', 'shpinst']:
                    if word == 'shptxt':
                        # The legacy picture can omit editable labels.
                        state['skip'] = False
                        book.warnings.add(floating_notice)
                    elif word == 'sp':
                        state['shape_property'] = {}
                elif depth_in_group == 5 and parent_destination == 'sp' and state['shape_property'] is not None:
                    if word == 'sn':
                        state['shape_property']['picture'] = bool(image_property.match(text, at))
                    elif word == 'sv' and state['shape_property'].get('picture'):
                        state['group_picture_value'] = True
                elif word == 'shp' and not state['skip']:
                    shape_count += 1
                    state['shape'] = {'index': shape_count, 'depth': len(stack), 'start': state['group_start'] - 1,
                                      'text': False, 'picture': False, 'failed': False}
                    state['shape_variant'] = ''
                    state['skip'] = True
                elif shape is not None:
                    depth = len(stack) - shape['depth']
                    if word == 'sp' and depth == 2 and parent_destination == 'shpinst':
                        state['shape_property'] = {}
                    elif depth == 3 and parent_destination == 'sp' and state['shape_property'] is not None:
                        if word == 'sn':
                            state['shape_property']['picture'] = bool(image_property.match(text, at))
                        elif word == 'sv' and state['shape_property'].get('picture'):
                            state['skip'] = shape['picture']
                            state['shape_variant'] = 'pib'
                    elif word == 'shptxt' and depth == 2 and parent_destination == 'shpinst':
                        state['skip'] = False
                        state['shape_variant'] = 'text'
                    elif word == 'shprslt' and depth == 1 and parent_destination == 'shp':
                        state['skip'] = shape['picture'] or shape['text']
            elif word in {'shppict', 'nonshppict'} and destination_prefix.fullmatch(text, state['group_start'], control_start):
                if word == 'nonshppict' and skip_backup_end == control_start + len(word) + 1:
                    state['skip'] = True
                elif not state['skip']:
                    state['primary_picture'] = {'rendered': False, 'may_use_backup': word == 'shppict'}
            elif word in {'object', 'objclass', 'objdata', 'result'}:
                starts_group = destination_prefix.fullmatch(text, state['group_start'], control_start) is not None
                embedded = state['object']
                direct_child = embedded is not None and len(stack) == embedded['depth'] + 1
                if word == 'object' and starts_group and not state['skip']:
                    object_count += 1
                    state['object'] = {'index': object_count, 'depth': len(stack), 'has_data': False, 'visible': False}
                    state['skip'] = True
                elif word == 'objclass' and starts_group and direct_child:
                    embedded['picture_preview'] = bool(word_picture_class.match(text, at))
                elif word == 'objdata':
                    if starts_group and direct_child:
                        state['object_data'] = True
                    state['skip'] = True
                elif word == 'result' and starts_group and direct_child:
                    # The result is stored RTF. Object data is never rendered.
                    state['skip'] = False
            elif word == 'fonttbl': state['skip'] = True; state['fonttable'] = True
            elif word == 'deff': default_font = arg
            elif word == 'f':
                if state['fonttable']: state['fontid'] = arg
                elif arg in fonts: state['cp'] = fonts[arg]
            elif word in {'fcharset', 'cpg'} and state['fonttable']:
                cp = charsets.get(arg) if word == 'fcharset' else ('cp' + str(arg) if arg else None)
                if cp: fonts[state['fontid']] = cp
            elif word in destinations: state['skip'] = True
            elif word == 'pard' and not state['skip'] and state['pict'] is None:
                state['table_level'] = 0
                state['paragraph_alignment'] = None
                state['frame'] = {}
            elif word in alignment_commands and not state['skip'] and state['pict'] is None:
                state['paragraph_alignment'] = alignment_commands[word]
            elif word in frame_commands and not state['skip'] and state['pict'] is None:
                field = frame_commands[word]
                if field in {'horizontal', 'vertical'} or arg is not None:
                    state['frame'] = {**state['frame'], field: word if arg is None else arg}
            elif word == 'intbl' and not state['skip'] and state['pict'] is None:
                state['table_level'] = max(1, state['table_level']) if arg != 0 else 0
            elif word == 'itap' and arg is not None and not state['skip'] and state['pict'] is None:
                if not 0 <= arg <= 63: book.fail('Недопустимый уровень вложенности таблицы RTF.')
                state['table_level'] = arg
            elif word == 'nesttableprops' and not state['skip']:
                state['nested_table_properties'] = True
            elif word in row_controls and not state['skip'] and state['pict'] is None:
                level = max(2, state['table_level'], len(tables.tables)) if state['nested_table_properties'] else 1
                tables.control(level, word, arg)
            elif word in {'cell', 'nestcell', 'row', 'nestrow'} and not state['skip'] and state['pict'] is None:
                level = max(2, state['table_level'], paragraph_level or 0, len(tables.tables)) if word.startswith('nest') else 1
                finish_paragraph(level)
                if word.endswith('cell'):
                    tables.end_cell(level)
                else:
                    tables.end_row(level)
            elif word == 'footnote': book.warnings.add('Сноски RTF перенесены в основной текст возле ссылки.')
            elif word == 'pict':
                picture = state['pict'] = {'hex': [], 'bin': None, 'size': {}}
                group = state['shape_group']
                if group is not None and destination_prefix.fullmatch(text, state['group_start'], control_start):
                    depth = len(stack) - group['depth']
                    if depth == 6 and stack[-1]['destination'] == 'sv' and state['group_picture_value']:
                        picture['group_original'] = True
                        state['skip'] = False
                    elif depth == 2 and stack[-1]['destination'] == 'shprslt':
                        picture['group_preview'] = True
            elif word == 'blipuid' and state['pict'] is not None:
                if destination_prefix.fullmatch(text, state['group_start'], control_start) and (uid := picture_id.match(text, at)):
                    state['pict']['uid'] = uid[1].lower()
                    state['skip'] = True
            elif word in picture_dimensions and state['pict'] is not None and arg is not None:
                state['pict']['size'][word] = arg
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
            elif word in {'par', 'page', 'sect'} and not state['skip'] and state['pict'] is None:
                finish_paragraph(keep_empty=True)
            elif word in {'line', 'tab', 'emdash', 'endash', 'lquote', 'rquote', 'ldblquote', 'rdblquote', 'bullet'}:
                if word == 'line' and not state['skip'] and state['pict'] is None:
                    paragraph_content()
                    finish_run(); paragraph.append(book.el('br')); run_parent = None
                else: emit({'tab': '\t', 'emdash': '—', 'endash': '–', 'lquote': '‘', 'rquote': '’', 'ldblquote': '“', 'rdblquote': '”', 'bullet': '•'}.get(word, ''))
        elif ch not in '\r\n': char(ch)
    flush(); finish_paragraph(keep_empty=not tables.tables)
    tables.close_after(0)
    if stack: book.fail('RTF обрывается внутри группы.')
    if positioned_paragraphs:
        book.warnings.add('Рамки RTF с привязкой к странице перенесены в основной текст. '
                          f'Положение на странице изменится. Затронуто абзацев — {positioned_paragraphs}.')
    book.warnings.add('Страничная вёрстка и сложные поля RTF упрощаются. Сохранены текст, таблицы и основные выделения.')


def to_epub(source, output, warnings, api, input_extension=None, stream_docx_images=False, *, cover_asset=None,
            publication_metadata=None, **metadata):
    book = Book(api, source, warnings, **metadata)
    if publication_metadata is not None:
        book.publication_metadata = publication_metadata
        if not metadata.get('title'):
            book.title = api.plain(api.first(publication_metadata, 'title')) or book.title
        if not metadata.get('language'):
            book.language = api.plain(api.first(publication_metadata, 'language')) or book.language
    book.work_root = output.parent
    with ExitStack() as resources:
        book.work_resources = resources
        if cover_asset is not None and not book.omit_images:
            try:
                if not cover_asset.is_relative_to(book.resource_scope) or cover_asset.stat().st_size > 16 * 1024 * 1024:
                    raise api.UnreadableImage('Недоступный файл обложки.')
                data, _ = api.recover_book_jpeg(cover_asset.read_bytes(), warnings, cover_asset.name, book.cancel_check)
                api.check_embedded_raster(data)
                book.cover_image = book.image(data).get('src')
            except (OSError, api.UnreadableImage):
                warnings.add('Повреждённая обложка MOBI: изображение прочитать не удалось.')
        write_reading_epub(book, output, input_extension or source.suffix.lower(), stream_docx_images)
        return book.section_store is not None


def write_reading_epub(book, output, extension, stream_docx_images):
    source, api = book.source, book.c
    if book.image_export and 'resource_limit' in book.image_export:
        paged_reader = ('fixed_layout' if extension in {'.pdf', '.djvu', '.djv', '.dju', '.djvm', '.djm'}
                        else 'image_input')
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_' + paged_reader, Path(__file__).with_name(paged_reader + '.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='homelibre-page-images-', dir=book.work_root) as folder:
            book.image_store = Path(folder)
            module.read(book, extension)
            book.progress('finalizing', 0, 0)
            book.finish(output)
        return
    if extension == '.docx':
        if stream_docx_images:
            with tempfile.TemporaryDirectory(prefix='homelibre-docx-images-', dir=book.work_root) as folder:
                book.image_store = Path(folder)
                read_docx(book)
                book.finish(output)
            return
        read_docx(book)
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
        if extension == '.chm' and source.stat().st_size > api.MAX_FILE:
            with tempfile.TemporaryDirectory(prefix='homelibre-chm-images-', dir=book.work_root) as folder:
                book.image_store = Path(folder)
                module.read(book, extension, lambda b, d: read_html(b, d, html5=True), decode)
                book.finish(output)
            return
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
            text = decode_plain_text(data, book.warnings)
            lines = text.splitlines()
            for fixed, rows in groupby(zip(plain_text_fixed_rows(lines), lines), key=lambda row: row[0]):
                if fixed:
                    book.body.append(book.el('pre', '\n'.join(line for _, line in rows),
                                             **{'class': api.TEXT_FRAME_STYLE}))
                else:
                    for _, line in rows:
                        paragraph = book.el('p', line)
                        if not line: paragraph.append(book.el('br'))
                        book.body.append(paragraph)
        elif extension in {'.html', '.htm', '.xhtml', '.shtml'}: read_html(book, data)
        elif extension == '.rtf': read_rtf(book, data)
        elif extension in {'.md', '.markdown'}: read_markdown(book, data)
        else: book.fail('Этот текстовый формат пока не поддерживается.')
    book.progress('finalizing', 0, 0)
    book.finish(output)

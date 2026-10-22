"""Local FB2/EPUB conversion. MIT license; see LICENSE.txt.

Standard library only; source files are read-only.

EPUB can describe layouts that FB2 cannot. Such features are reported explicitly.
This module never downloads resources, rewrites the source or replaces a target.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import importlib.util
from html.entities import name2codepoint
import json
import mimetypes
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit
import uuid
import xml.etree.ElementTree as ET
import zipfile

FB = 'http://www.gribuser.ru/xml/fictionbook/2.0'
XL = 'http://www.w3.org/1999/xlink'
XH = 'http://www.w3.org/1999/xhtml'
EP = 'http://www.idpf.org/2007/ops'
OP = 'http://www.idpf.org/2007/opf'
DC = 'http://purl.org/dc/elements/1.1/'
CN = 'urn:oasis:names:tc:opendocument:xmlns:container'
MHL = 'https://github.com/Dicur3x/MyHomeLib/conversion/'
MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_ENTRIES = 20000


class ConversionError(ValueError):
    pass


def tag(node):
    return node.tag.rsplit('}', 1)[-1] if isinstance(node.tag, str) else ''


def xml(data):
    if len(data) > MAX_FILE:
        raise ConversionError('Файл превышает предел конвертации (64 МБ).')
    # ElementTree never fetches external entities. Reject internal entities too.
    probe = data.replace(b'\x00', b'')  # UTF-16/32 declarations must not bypass the gate.
    if re.search(br'<!\s*ENTITY\b|<!\s*DOCTYPE\b[^>]*\[', probe, re.I):
        raise ConversionError('Документ с внутренними сущностями DTD нельзя безопасно преобразовать.')
    try:
        root = ET.fromstring(data)
        pending = [(root, 0)]; nodes = 0
        while pending:
            node, depth = pending.pop(); nodes += 1
            if depth > 128 or nodes > 500000:
                raise ConversionError('XML книги слишком сложен для конвертации.')
            pending.extend((child, depth + 1) for child in node)
        return root
    except (ET.ParseError, LookupError) as error:
        raise ConversionError('Некорректная структура XML: ' + str(error)) from error


def xhtml(data):
    """Legacy XHTML may use the named HTML entities from its external DTD.

    Expand that fixed, local table only; never load a DTD or fetch any resource.
    Decoding by the XML declaration preserves non-UTF-8 EPUB 2 chapters.
    """
    try:
        return xml(data)
    except ConversionError:
        probe = data.replace(b'\x00', b'')
        if not re.search(br'<!DOCTYPE\s+html\b', probe, re.I):
            raise
        if re.search(br'<!\s*ENTITY\b|<!\s*DOCTYPE\b[^>]*\[', probe, re.I):
            raise
        if data.startswith((b'\xff\xfe', b'\xfe\xff')):
            encoding = 'utf-16'
        else:
            declaration = re.match(br'\s*<\?xml[^>]*encoding=[\'\"]([^\'\"]+)', data)
            encoding = declaration[1].decode('ascii') if declaration else 'utf-8-sig'
        try:
            text = data.decode(encoding)
        except (LookupError, UnicodeError) as error:
            raise ConversionError('Неизвестная кодировка главы EPUB.') from error
        text = re.sub(r'&([A-Za-z][A-Za-z0-9]+);',
                      lambda m: '&#' + str(name2codepoint[m[1]]) + ';' if m[1] in name2codepoint and m[1] not in {'amp', 'lt', 'gt', 'quot', 'apos'} else m[0], text)
        text = re.sub(r'(<\?xml[^>]*encoding=[\'\"])[^\'\"]+', r'\1utf-8', text, count=1)
        return xml(text.encode('utf-8'))


def serialized(node):
    return ET.tostring(node, encoding='utf-8', xml_declaration=True)


def element(namespace, local_name, text=None, **attributes):
    node = ET.Element('{' + namespace + '}' + local_name, attributes)
    node.text = text
    return node


def plain(node):
    return ''.join(node.itertext()).strip() if node is not None else ''


def children(node, name):
    return [child for child in node if tag(child) == name]


def first(node, name):
    return next((n for n in node if tag(n) == name), None)


def append_text(node, text):
    if not text:
        return
    if len(node):
        node[-1].tail = (node[-1].tail or '') + text
    else:
        node.text = (node.text or '') + text


def normalize_fb2(book, preserved_bodies=()):
    """Split flow at line breaks; FB2 sections cannot mix children and prose."""
    inline = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
    paragraphs = {'p', 'subtitle', 'v', 'text-author'}
    def split_paragraph(node):
        result, current, chain = [], element(FB, tag(node), **node.attrib), []
        def append(value):
            parent = current
            for wrapper in chain:
                if len(parent) and parent[-1].tag == wrapper.tag and parent[-1].attrib == wrapper.attrib and not parent[-1].tail:
                    parent = parent[-1]
                else:
                    clone = element(FB, tag(wrapper), **wrapper.attrib); parent.append(clone); parent = clone
            if isinstance(value, str): append_text(parent, value)
            else:
                clone = copy.deepcopy(value); clone.tail = None; parent.append(clone)
        def flush():
            nonlocal current
            had_content = bool(plain(current) or len(current) or current.get('id'))
            if had_content: result.append(current)
            current = element(FB, tag(node), **{k:v for k,v in node.attrib.items() if k != 'id'})
            return had_content
        def walk(parent):
            append(parent.text or '')
            for child in parent:
                if tag(child) == 'empty-line':
                    if not flush(): result.append(element(FB, 'empty-line'))
                elif tag(child) not in inline:
                    flush(); clone = copy.deepcopy(child); clone.tail = None; result.append(clone)
                elif tag(child) == 'image': append(child)
                else:
                    chain.append(child); walk(child); chain.pop()
                append(child.tail or '')
        walk(node); flush()
        return result or [element(FB, tag(node), **node.attrib)]
    def fix(node):
        updated = []
        for child in list(node):
            fix(child)
            updated.extend(split_paragraph(child) if tag(child) in paragraphs else [child])
        node[:] = updated
        if tag(node) in {'body', 'section'}:
            content = []
            if node.text and node.text.strip(): content.append(element(FB, 'p', node.text))
            # Mixed text can occur in HTML block containers. FB2 sections must
            # carry it in paragraphs, including text between two blocks.
            run = None
            for child in node:
                tail = child.tail; child.tail = tail if tail and not tail.strip() else None
                if tag(child) in inline - {'image'}:
                    if run is None: run = element(FB, 'p'); content.append(run)
                    run.append(child); append_text(run, tail)
                else:
                    run = None; content.append(child)
                    if tail and tail.strip(): content.append(element(FB, 'p', tail))
            node.text = None
            prefix = []
            allowed = {'image', 'title', 'epigraph'} if tag(node) == 'body' else {'title', 'epigraph', 'image', 'annotation'}
            while content and tag(content[0]) in allowed: prefix.append(content.pop(0))
            if tag(node) == 'body' or any(tag(n) == 'section' for n in content):
                groups, run = [], []
                for child in content:
                    if tag(child) == 'section':
                        if run:
                            section = element(FB, 'section'); section.extend(run); groups.append(section); run = []
                        groups.append(child)
                    else: run.append(child)
                if run:
                    section = element(FB, 'section'); section.extend(run); groups.append(section)
                node[:] = prefix + groups
            else: node[:] = prefix + content
            if not any(tag(n) in {'section', 'p', 'subtitle', 'poem', 'cite', 'table', 'empty-line'} for n in node):
                node.append(element(FB, 'section') if tag(node) == 'body' else element(FB, 'empty-line'))
        if tag(node) in {'cite', 'epigraph'}:
            def flatten(section):
                for item in section:
                    if tag(item) == 'section': yield from flatten(item)
                    elif tag(item) == 'title':
                        for p in item:
                            p.tag = '{' + FB + '}p'; yield p
                    else: yield item
            node[:] = [part for child in node for part in (list(flatten(child)) if tag(child) == 'section' else [child])]
    for body in children(book, 'body'):
        if body not in preserved_bodies: fix(body)


def validate_fb2_output(book):
    """Reject broken generated structure before naming it as a user's result.

    This small runtime guard is deliberately dependency-free. The regression
    suite additionally validates output against the complete official XSD.
    """
    inline = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
    prose = {'p', 'poem', 'subtitle', 'cite', 'empty-line', 'table', 'image'}
    rules = {'body': {'title', 'epigraph', 'image', 'section'},
             'section': prose | {'title', 'epigraph', 'annotation', 'section'},
             'title': {'p', 'empty-line'}, 'table': {'tr'}, 'tr': {'td', 'th'},
             'cite': {'p', 'poem', 'empty-line', 'subtitle', 'table', 'text-author'},
             'epigraph': {'p', 'poem', 'cite', 'empty-line', 'text-author'},
             'annotation': {'p', 'poem', 'cite', 'subtitle', 'table', 'empty-line'},
             'poem': {'title', 'epigraph', 'subtitle', 'stanza', 'text-author', 'date'},
             'stanza': {'title', 'subtitle', 'v'}}
    for name in {'p', 'subtitle', 'v', 'text-author', 'td', 'th'} | (inline - {'image'}): rules[name] = inline
    identities = set()
    for node in book.iter():
        value = node.get('id')
        if value:
            if value in identities: raise ConversionError('В результате повторяется идентификатор FB2: ' + value)
            identities.add(value)
    link_styles = {id(n) for link in book.iter('{' + FB + '}a') for n in link.iter('{' + FB + '}style')}
    for body in children(book, 'body'):
        for node in body.iter():
            name = tag(node)
            if node.tag != '{' + FB + '}' + name or name not in rules and name not in {'image', 'empty-line', 'date'}:
                raise ConversionError('Нельзя сохранить элемент в FB2: ' + name)
            allowed = rules.get(name, set())
            if any(tag(child) not in allowed for child in node):
                raise ConversionError('Структуру EPUB нельзя представить в FB2 без потери содержимого: ' + name)
            if name not in inline | {'p', 'subtitle', 'v', 'text-author', 'td', 'th', 'date'}:
                if node.text and node.text.strip() or any(child.tail and child.tail.strip() for child in node):
                    raise ConversionError('В результате FB2 остался текст вне абзаца: ' + name)
            if name == 'section':
                parts = list(node)
                while parts and tag(parts[0]) in {'title', 'epigraph', 'image', 'annotation'}: parts.pop(0)
                if any(tag(n) == 'section' for n in parts) and any(tag(n) != 'section' for n in parts):
                    raise ConversionError('В результате FB2 смешаны главы и абзацы.')
            if name == 'style' and id(node) not in link_styles and not node.get('name'): raise ConversionError('В результате FB2 у стиля отсутствует имя.')
            if name in {'a', 'image'}:
                href = node.get('{' + XL + '}href', '')
                if href.startswith('#') and href[1:] not in identities:
                    raise ConversionError('В результате FB2 отсутствует цель ссылки: ' + href)


class EpubArchive:
    def __init__(self, path):
        self.archive = zipfile.ZipFile(path)
        entries = self.archive.infolist()
        if len(entries) > MAX_ENTRIES or sum(e.file_size for e in entries) > MAX_TOTAL:
            self.archive.close()
            raise ConversionError('EPUB слишком велик для конвертации.')
        self.names = {e.filename for e in entries}
        if len(self.names) != len(entries):
            self.archive.close()
            raise ConversionError('В EPUB повторяются имена файлов.')
        for entry in entries:
            if entry.file_size > MAX_FILE or '\\' in entry.filename or entry.filename.startswith('/') or '..' in entry.filename.split('/'):
                self.archive.close()
                raise ConversionError('Некорректный путь или слишком большой файл EPUB.')

    def read(self, name):
        if name not in self.names:
            raise ConversionError('В EPUB отсутствует файл: ' + name)
        try:
            return self.archive.read(name)
        except RuntimeError as error:
            raise ConversionError('Зашифрованный файл EPUB не поддерживается: ' + name) from error

    def resolve(self, current, reference):
        parts = urlsplit(reference)
        if parts.scheme or parts.netloc:
            return None, parts.fragment
        path = posixpath.normpath(posixpath.join(posixpath.dirname(current), unquote(parts.path))) if parts.path else current
        if path.startswith('../') or path.startswith('/') or '\\' in path:
            raise ConversionError('Ссылка EPUB выходит за пределы книги.')
        return path, unquote(parts.fragment)

    def close(self):
        self.archive.close()


def fb2_to_epub(source, output, warnings):
    book = xml(Path(source).read_bytes())
    if book.tag != '{' + FB + '}FictionBook':
        raise ConversionError('Файл не является книгой FB2.')
    description = first(book, 'description')
    title_info = first(description, 'title-info') if description is not None else None
    if title_info is None:
        raise ConversionError('В FB2 отсутствует описание книги.')
    title = plain(first(title_info, 'book-title')) or Path(source).stem
    language = plain(first(title_info, 'lang')) or 'und'
    bodies = children(book, 'body')
    if not bodies:
        raise ConversionError('В FB2 отсутствует текст книги.')
    ids, resources = {}, {}
    for index, body in enumerate(bodies):
        filename = f'body-{index + 1}.xhtml'
        for node in body.iter():
            identity = node.get('id')
            if identity:
                if identity in ids:
                    raise ConversionError('В FB2 повторяется идентификатор: ' + identity)
                ids[identity] = filename
    image_files = {}
    for index, binary in enumerate(children(book, 'binary')):
        identity = binary.get('id', '')
        if not identity or identity in image_files:
            raise ConversionError('Некорректный идентификатор изображения FB2.')
        try:
            data = base64.b64decode(re.sub(r'\s+', '', plain(binary)), validate=True)
        except ValueError as error:
            raise ConversionError('Повреждено изображение FB2: ' + identity) from error
        mime = binary.get('content-type', 'application/octet-stream')
        extension = {'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/svg+xml': '.svg', 'image/webp': '.webp'}.get(mime)
        if extension is None:
            raise ConversionError('Изображение FB2 имеет неподдерживаемый тип: ' + mime)
        filename = f'images/image-{index + 1}{extension}'
        resources[filename] = (data, mime)
        image_files[identity] = filename
    headings = []
    generated_ids = set(ids)
    mapping = {'section': 'section', 'p': 'p', 'subtitle': 'h3', 'poem': 'div',
               'stanza': 'div', 'v': 'p', 'cite': 'blockquote', 'epigraph': 'blockquote',
               'text-author': 'p', 'date': 'p', 'strong': 'strong', 'emphasis': 'em',
               'strikethrough': 's', 'sub': 'sub', 'sup': 'sup', 'code': 'code',
               'style': 'span', 'annotation': 'div', 'a': 'a', 'table': 'table', 'tr': 'tr', 'td': 'td', 'th': 'th'}

    def convert(node, filename, depth=0, navigation_depth=0):
        name = tag(node)
        section_title = first(node, 'title') if name == 'section' else None
        has_section_title = section_title is not None and bool(plain(section_title))
        if name == 'image':
            identity = node.get('{' + XL + '}href', '').lstrip('#')
            if identity not in image_files:
                raise ConversionError('Не найдено изображение FB2: ' + identity)
            result = element(XH, 'img', src=image_files[identity], alt=node.get('alt', ''))
            result.set('data-fb2-image-id', identity)
        elif name == 'empty-line':
            result = element(XH, 'p'); result.append(element(XH, 'br'))
        elif name == 'title':
            result = element(XH, 'header')
            result.text = node.text
            for paragraph in node:
                heading = convert(paragraph, filename, depth, navigation_depth)
                heading.tag = '{' + XH + '}h' + str(min(6, max(1, depth)))
                heading.tail = paragraph.tail
                result.append(heading)
        elif name == 'body':
            result = element(XH, 'div')
        elif name in mapping:
            result = element(XH, mapping[name])
        else:
            raise ConversionError('Неизвестный элемент FB2: ' + name)
        result.set('data-fb2', name)
        if node.attrib:
            result.set('data-fb2-attributes', json.dumps(node.attrib, ensure_ascii=False, separators=(',', ':')))
        result.set('class', 'fb2-' + name + ((' ' + node.get('name', '')) if name == 'style' else ''))
        if node.get('id'):
            result.set('id', node.get('id'))
        if name == 'a':
            href = node.get('{' + XL + '}href', '')
            if href.startswith('#'):
                if href[1:] not in ids:
                    raise ConversionError('Не найдена цель ссылки FB2: ' + href)
                href = ids[href[1:]] + href
            result.set('href', href)
            if node.get('type') == 'note':
                result.set('{' + EP + '}type', 'noteref')
        for key in ('colspan', 'rowspan'):
            if node.get(key):
                result.set(key, node.get(key))
        if node.get('align'): result.set('style', 'text-align:' + node.get('align'))
        if name not in {'image', 'empty-line', 'title'}:
            result.text = node.text
            for child in node:
                mapped = convert(child, filename, depth + (name == 'body' or name == 'section'), navigation_depth + has_section_title)
                mapped.tail = child.tail
                result.append(mapped)
        if name == 'section':
            if has_section_title:
                identity = result.get('id')
                if not identity:
                    index = len(headings) + 1
                    while 'chapter-' + str(index) in generated_ids: index += 1
                    identity = 'chapter-' + str(index); generated_ids.add(identity)
                result.set('id', identity)
                # Untitled grouping sections affect layout, but must not make
                # unrelated chapter names children of the previous TOC item.
                headings.append((filename + '#' + identity, plain(section_title), navigation_depth + 1))
        return result

    for index, body in enumerate(bodies):
        filename = f'body-{index + 1}.xhtml'
        html = element(XH, 'html', **{'lang': language})
        head = element(XH, 'head'); head.append(element(XH, 'title', title))
        head.append(element(XH, 'link', rel='stylesheet', href='book.css', type='text/css'))
        html.append(head)
        html_body = element(XH, 'body'); html_body.append(convert(body, filename))
        html.append(html_body)
        resources[filename] = (serialized(html), 'application/xhtml+xml')
    css = ('body{line-height:1.35}p{margin:.45em 0;text-indent:1.3em}'
           'h1,h2,h3,h4,h5,h6{text-align:center;text-indent:0}'
           'img{max-width:100%;height:auto}.fb2-v{text-indent:0;margin:.1em 0;white-space:pre-wrap}'
           '.fb2-poem,.fb2-stanza{margin:1em 2em}.fb2-text-author{text-align:right}'
           '.fb2-epigraph,.fb2-cite{margin:1em 2em}.fb2-subtitle{text-align:center}'
           'code{white-space:pre-wrap}table{border-collapse:collapse}td,th{padding:.2em .4em}')
    for stylesheet in children(book, 'stylesheet'):
        if stylesheet.get('type', 'text/css') == 'text/css':
            extra_css = plain(stylesheet)
            # FB2 has no packaged font resources. Do not emit an EPUB stylesheet
            # containing dangling publisher URLs carried in a source FB2.
            extra_css, font_faces = re.subn(r'@font-face\s*\{[^{}]*\}', '', extra_css, flags=re.I)
            if font_faces: warnings.add('Объявления внешних шрифтов FB2 не перенесены в EPUB; используются шрифты читалки.')
            if re.search(r'@import\b', extra_css, re.I):
                raise ConversionError('Внешнюю таблицу стилей FB2 нельзя перенести в EPUB без её файла.')
            def css_resource(match):
                reference = match[1].strip().strip('\'\"')
                if reference.startswith('#') and reference[1:] in image_files:
                    return 'url("' + image_files[reference[1:]] + '")'
                raise ConversionError('Не найден ресурс оформления FB2: ' + reference)
            extra_css = re.sub(r'url\s*\(\s*([^)]*)\)', css_resource, extra_css, flags=re.I)
            css += '\n' + extra_css
    resources['book.css'] = (css.encode('utf-8'), 'text/css')
    nav = element(XH, 'html', lang=language)
    head = element(XH, 'head'); head.append(element(XH, 'title', 'Содержание')); nav.append(head)
    body = element(XH, 'body'); nav.append(body)
    toc = element(XH, 'nav', **{'{' + EP + '}type': 'toc', 'id': 'toc'})
    body.append(toc); toc.append(element(XH, 'h1', 'Содержание'))
    root_list = element(XH, 'ol'); toc.append(root_list)
    # Headings were collected after children: restore reading order from each DOM.
    heading_order = []
    heading_labels = {href: (label, depth) for href, label, depth in headings}
    for index in range(len(bodies)):
        filename = f'body-{index + 1}.xhtml'
        for node in xml(resources[filename][0]).iter():
            href = filename + '#' + node.get('id', '')
            if href in heading_labels:
                label, depth = heading_labels[href]; heading_order.append((href, label, depth))
    stack = [(1, root_list)]
    for href, label, depth in heading_order or [('body-1.xhtml', title, 1)]:
        while len(stack) > 1 and stack[-1][0] >= depth:
            stack.pop()
        if depth > stack[-1][0] and len(stack[-1][1]):
            parent_item = stack[-1][1][-1]
            nested = first(parent_item, 'ol')
            if nested is None: nested = element(XH, 'ol'); parent_item.append(nested)
            stack.append((depth, nested))
        item = element(XH, 'li'); item.append(element(XH, 'a', label, href=href)); stack[-1][1].append(item)
    resources['nav.xhtml'] = (serialized(nav), 'application/xhtml+xml')
    package = element(OP, 'package', version='3.0', **{'unique-identifier': 'book-id', 'prefix': 'mhl: ' + MHL})
    metadata = element(OP, 'metadata'); package.append(metadata)
    metadata.append(element(DC, 'identifier', 'urn:uuid:' + str(uuid.uuid4()), id='book-id'))
    metadata.append(element(DC, 'title', title)); metadata.append(element(DC, 'language', language))
    from datetime import datetime, timezone
    metadata.append(element(OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), property='dcterms:modified'))
    metadata.append(element(OP, 'meta', base64.b64encode(serialized(description)).decode(), property='mhl:fb2-description'))
    metadata.append(element(OP, 'meta', json.dumps({image_files[n.get('id')]: n.get('id') for n in children(book, 'binary')}, ensure_ascii=False), property='mhl:fb2-images'))
    metadata.append(element(OP, 'meta', json.dumps([base64.b64encode(serialized(n)).decode() for n in children(book, 'stylesheet')]), property='mhl:fb2-stylesheets'))
    for author in children(title_info, 'author'):
        name = ' '.join(plain(n) for n in author if tag(n) in {'first-name', 'middle-name', 'last-name', 'nickname'})
        if name:
            metadata.append(element(DC, 'creator', name))
    manifest = element(OP, 'manifest'); package.append(manifest)
    cover = first(title_info, 'coverpage')
    cover_id = next((n.get('{' + XL + '}href', '').lstrip('#') for n in cover if tag(n) == 'image'), '') if cover is not None else ''
    for index, (filename, (data, mime)) in enumerate(resources.items()):
        attributes = {'id': 'resource-' + str(index), 'href': filename, 'media-type': mime}
        if filename == 'nav.xhtml': attributes['properties'] = 'nav'
        if filename == image_files.get(cover_id): attributes['properties'] = 'cover-image'
        manifest.append(element(OP, 'item', **attributes))
    spine = element(OP, 'spine'); package.append(spine)
    by_name = {item.get('href'): item.get('id') for item in manifest}
    for index in range(len(bodies)):
        spine.append(element(OP, 'itemref', idref=by_name[f'body-{index + 1}.xhtml']))
    container = element(CN, 'container', version='1.0'); rootfiles = element(CN, 'rootfiles'); container.append(rootfiles)
    rootfiles.append(element(CN, 'rootfile', **{'full-path': 'OEBPS/package.opf', 'media-type': 'application/oebps-package+xml'}))
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', serialized(container))
        archive.writestr('OEBPS/package.opf', serialized(package))
        for filename, (data, mime) in resources.items(): archive.writestr('OEBPS/' + filename, data)


def epub_to_fb2(source, output, warnings):
    archive = EpubArchive(source)
    try:
        if 'META-INF/encryption.xml' in archive.names:
            encrypted = xml(archive.read('META-INF/encryption.xml'))
            algorithms = [n.get('Algorithm', '') for n in encrypted.iter() if tag(n) == 'EncryptionMethod']
            if any(a not in {'http://www.idpf.org/2008/embedding', 'http://ns.adobe.com/pdf/enc#RC'} for a in algorithms):
                raise ConversionError('Зашифрованная книга EPUB не поддерживается.')
            warnings.add('Встроенные шрифты EPUB не переносятся в FB2.')
        container = xml(archive.read('META-INF/container.xml'))
        package_path = next((n.get('full-path') for n in container.iter() if tag(n) == 'rootfile'), '')
        if not package_path: raise ConversionError('В EPUB отсутствует пакет книги.')
        package = xml(archive.read(package_path)); metadata = first(package, 'metadata')
        manifest = first(package, 'manifest'); spine = first(package, 'spine')
        if metadata is None or manifest is None or spine is None: raise ConversionError('Неполный пакет EPUB.')
        items = {}
        for item in manifest:
            key = item.get('id')
            if not key: raise ConversionError('В EPUB отсутствует идентификатор ресурса.')
            if key in items:
                if serialized(item).strip() != serialized(items[key]).strip():
                    raise ConversionError('Один идентификатор EPUB обозначает разные ресурсы: ' + key)
                warnings.add('Повторяющиеся одинаковые записи каталога EPUB учтены один раз.')
            else: items[key] = item
        paths = {identity: archive.resolve(package_path, item.get('href', ''))[0] for identity, item in items.items()}
        documents = []
        documents_by_path = {}
        def load_document(path):
            if path in documents_by_path: return
            if path is None: raise ConversionError('Внешняя глава EPUB не скачивается.')
            document = xhtml(archive.read(path))
            if document.tag not in {'{' + XH + '}html', 'html'}:
                raise ConversionError('Глава EPUB не является XHTML.')
            body = first(document, 'body')
            if body is None: raise ConversionError('В главе EPUB отсутствует текст.')
            ids = [n.get('id') for n in body.iter() if n.get('id')]
            if len(ids) != len(set(ids)): raise ConversionError('В главе EPUB повторяются идентификаторы: ' + path)
            documents.append((path, body)); documents_by_path[path] = body
            # Publisher styles may be embedded in each chapter's head too.
            head = first(document, 'head')
            if head is not None:
                embedded_css.extend(''.join(n.itertext()) for n in head.iter() if tag(n) == 'style')
        embedded_css = []
        for itemref in spine:
            identity = itemref.get('idref'); item = items.get(identity)
            if item is None: raise ConversionError('EPUB ссылается на отсутствующую главу.')
            if item.get('media-type') != 'application/xhtml+xml':
                raise ConversionError('Нетекстовая глава EPUB не поддерживается: ' + item.get('media-type', ''))
            if 'nav' in item.get('properties', '').split(): continue
            load_document(paths[identity])
        if not documents: raise ConversionError('В EPUB отсутствуют главы для чтения.')
        # A valid EPUB may keep referenced notes or appendices outside the spine.
        # Include only linked local XHTML resources, never download external ones.
        text_resources = {paths[k] for k, item in items.items()
                          if item.get('media-type') == 'application/xhtml+xml' and 'nav' not in item.get('properties', '').split()}
        for path, body in documents:
            for link in body.iter():
                if tag(link) == 'a' and link.get('href'):
                    target, _ = archive.resolve(path, link.get('href'))
                    if target in text_resources: load_document(target)
        aliases = {}
        def base_identity(path, fragment=''):
            return 'id_' + hashlib.sha256((path + '#' + fragment).encode('utf-8')).hexdigest()[:24]
        def identity(path, fragment=''):
            return aliases.get((path, fragment), base_identity(path, fragment))
        # Several inline anchors may denote the same paragraph. FB2 IDs belong
        # to blocks, so point all such references at their containing block.
        block_tags = {'p', 'div', 'section', 'article', 'aside', 'li', 'td', 'th', 'table', 'figure', 'pre', 'blockquote', 'ul', 'ol', 'dl', 'dd', 'dt', 'figcaption', 'caption', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}
        for path, body in documents:
            if any(n.get('data-fb2') == 'body' for n in body): continue
            parents = {child: parent for parent in body.iter() for child in parent}
            for index, node in enumerate(body.iter()):
                if not node.get('id'): continue
                host = node
                while host is not body and tag(host) not in block_tags: host = parents[host]
                anchor = host.get('data-homelib-anchor')
                if not anchor:
                    # NUL cannot occur in an XML ID; keep synthetic block keys
                    # disjoint from all publisher-provided identifiers.
                    anchor = base_identity(path, host.get('id') or ('\x00block-' + str(index))) if host is not body else base_identity(path)
                    host.set('data-homelib-anchor', anchor)
                aliases[path, node.get('id')] = anchor
        available = {(path, '') for path, body in documents}
        notes = set()
        for path, body in documents:
            for node in body.iter():
                if node.get('id'): available.add((path, node.get('id')))
                if tag(node) == 'a' and ('noteref' in node.get('{' + EP + '}type', '').split() or node.get('role') == 'doc-noteref'):
                    target, fragment = archive.resolve(path, node.get('href', ''))
                    if target: notes.add((target, fragment))
        note_anchors = {identity(path, fragment) for path, fragment in notes if fragment}
        book = element(FB, 'FictionBook'); preserved_description = None
        original = next((plain(n) for n in metadata if n.get('property') == 'mhl:fb2-description'), '')
        if original:
            try: preserved_description = xml(base64.b64decode(original, validate=True))
            except (ValueError, ConversionError) as error: raise ConversionError('Повреждено исходное описание FB2.') from error
            if preserved_description.tag != '{' + FB + '}description': raise ConversionError('Неверное исходное описание FB2.')
        description = preserved_description if preserved_description is not None else element(FB, 'description')
        book.append(description)
        if preserved_description is None:
            ti = element(FB, 'title-info'); description.append(ti)
            ti.append(element(FB, 'genre', 'unrecognised'))
            creators = [plain(n) for n in metadata if tag(n) == 'creator' and plain(n)]
            for name in creators or ['Не указан']:
                author = element(FB, 'author'); author.append(element(FB, 'nickname', name)); ti.append(author)
            ti.append(element(FB, 'book-title', next((plain(n) for n in metadata if tag(n) == 'title'), Path(source).stem)))
            annotation_text = next((plain(n) for n in metadata if tag(n) == 'description' and plain(n)), '')
            if annotation_text:
                annotation = element(FB, 'annotation'); annotation.append(element(FB, 'p', annotation_text)); ti.append(annotation)
            subjects = [plain(n) for n in metadata if tag(n) == 'subject' and plain(n)]
            if subjects: ti.append(element(FB, 'keywords', ', '.join(subjects)))
            ti.append(element(FB, 'lang', next((plain(n) for n in metadata if tag(n) == 'language'), 'und')))
            info = element(FB, 'document-info'); description.append(info)
            author = element(FB, 'author'); author.append(element(FB, 'nickname', 'HomeLib Ru')); info.append(author)
            info.append(element(FB, 'program-used', 'HomeLib Ru — FB2/EPUB'))
            from datetime import date
            info.append(element(FB, 'date', date.today().isoformat(), value=date.today().isoformat()))
            info.append(element(FB, 'id', str(uuid.uuid4()))); info.append(element(FB, 'version', '1.0'))
            # Keep all source metadata, including values without a direct FB2
            # counterpart (identifier, publisher, rights and EPUB refinements).
            description.append(element(FB, 'custom-info', base64.b64encode(serialized(metadata)).decode('ascii'), **{'info-type': 'HomeLib Ru: EPUB metadata (XML/base64)'}))
        image_ids, binaries = {}, []
        def image(path, reference, preferred=''):
            resolved, fragment = archive.resolve(path, reference)
            if resolved is None: raise ConversionError('Внешнее изображение EPUB не скачивается: ' + reference)
            if resolved not in image_ids:
                data = archive.read(resolved)
                mime = next((n.get('media-type') for n in manifest if archive.resolve(package_path, n.get('href', ''))[0] == resolved), None)
                mime = mime or mimetypes.guess_type(resolved)[0] or ''
                if not mime.startswith('image/'): raise ConversionError('Неизвестный тип изображения EPUB: ' + resolved)
                name = preferred or 'image_' + str(len(image_ids) + 1)
                if name in image_ids.values(): raise ConversionError('Повторяется идентификатор изображения.')
                binary = element(FB, 'binary', base64.b64encode(data).decode('ascii'), id=name, **{'content-type': mime})
                image_ids[resolved] = name; binaries.append(binary)
            return image_ids[resolved]
        # EPUB 2 commonly identifies its cover through OPF metadata instead of
        # the EPUB 3 cover-image manifest property.
        cover_items = {n.get('content') for n in metadata if tag(n) == 'meta' and n.get('name') == 'cover'}
        for item in manifest:
            if 'cover-image' in item.get('properties', '').split() or item.get('id') in cover_items:
                ti = first(description, 'title-info')
                old_cover = first(ti, 'coverpage')
                preferred = next((n.get('{' + XL + '}href', '').lstrip('#') for n in old_cover if tag(n) == 'image'), '') if old_cover is not None else ''
                name = image(package_path, item.get('href', ''), preferred)
                if old_cover is None:
                    old_cover = element(FB, 'coverpage'); old_cover.append(element(FB, 'image', **{'{' + XL + '}href': '#' + name}))
                    # FB2 title-info puts coverpage before lang.
                    at = next((i for i, n in enumerate(ti) if tag(n) == 'lang'), len(ti)); ti.insert(at, old_cover)
        if preserved_description is not None:
            try:
                saved_images = json.loads(next((plain(n) for n in metadata if n.get('property') == 'mhl:fb2-images'), '{}'))
                for reference, preferred in saved_images.items(): image(package_path, reference, preferred)
                saved_styles = json.loads(next((plain(n) for n in metadata if n.get('property') == 'mhl:fb2-stylesheets'), '[]'))
                for value in reversed(saved_styles):
                    stylesheet = xml(base64.b64decode(value, validate=True))
                    if stylesheet.tag != '{' + FB + '}stylesheet': raise ConversionError('Неверная исходная таблица стилей.')
                    book.insert(0, stylesheet)
            except (ValueError, AttributeError, TypeError) as error: raise ConversionError('Повреждены исходные ресурсы FB2.') from error
        inline_mapping = {'strong': 'strong', 'b': 'strong', 'em': 'emphasis', 'i': 'emphasis',
                          's': 'strikethrough', 'del': 'strikethrough', 'strike': 'strikethrough',
                          'sub': 'sub', 'sup': 'sup', 'code': 'code', 'a': 'a'}
        block_mapping = {'p': 'p', 'blockquote': 'cite', 'table': 'table', 'tr': 'tr', 'td': 'td', 'th': 'th', 'caption': 'subtitle', 'dt': 'subtitle'}
        # Preserve simple CSS emphasis, including publisher classes on paragraphs.
        css_rules = []
        css_text = list(embedded_css)
        for item in manifest:
            if item.get('media-type') == 'text/css':
                css = archive.read(archive.resolve(package_path, item.get('href', ''))[0]).decode('utf-8-sig', errors='replace')
                css_text.append(css)
        for css in css_text:
            for selector, properties in re.findall(r'([^{}]+)\{([^{}]*)\}', re.sub(r'/\*.*?\*/', '', css, flags=re.S)):
                for simple in selector.split(','):
                    if re.fullmatch(r'(?:[a-zA-Z][\w-]*)?(?:\.[\w-]+)*', simple.strip()):
                        css_rules.append((simple.strip(), properties))
            if re.search(r'\b(?:display\s*:\s*(?:grid|flex)|float\s*:|position\s*:\s*(?:absolute|fixed))', css, re.I):
                warnings.add('Сложное расположение блоков EPUB упрощено до последовательного текста FB2.')
        if css_text and preserved_description is None:
            stylesheet = element(FB, 'stylesheet', '\n'.join(css_text), type='text/css'); book.insert(0, stylesheet)
            warnings.add('FB2 передаёт основные стили текста; точное оформление CSS и встроенные шрифты EPUB зависят от читалки.')
        def styled(node, result):
            if tag(result) not in {'p', 'subtitle', 'v', 'text-author', 'style', 'a', 'strong', 'emphasis', 'td', 'th'}: return result
            classes = set(node.get('class', '').split())
            matched = []
            for index, (selector, properties) in enumerate(css_rules):
                bits = selector.split('.'); name = bits[0]
                if (not name or name == tag(node)) and set(bits[1:]).issubset(classes):
                    matched.append((len(bits[1:]) * 100 + bool(name), index, properties))
            style_text = ';'.join(properties for _, _, properties in sorted(matched)) + ';' + node.get('style', '')
            declarations = {}
            for entry in style_text.split(';'):
                if ':' in entry:
                    key, value = entry.split(':', 1); declarations[key.strip().lower()] = value.strip().lower()
            wrappers = []
            if re.fullmatch(r'(?:bold|[6-9]00)(?:\s*!important)?', declarations.get('font-weight', '')): wrappers.append('strong')
            if re.match(r'(?:italic|oblique)\b', declarations.get('font-style', '')): wrappers.append('emphasis')
            if 'line-through' in declarations.get('text-decoration', '') + declarations.get('text-decoration-line', ''): wrappers.append('strikethrough')
            for name in wrappers:
                wrapped = element(FB, name); wrapped.text = result.text; result.text = None
                for child in list(result): result.remove(child); wrapped.append(child)
                result.append(wrapped)
            return result
        inline_fb = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
        def flow(node, result, path):
            """Build heading sections at every HTML container depth, not only body."""
            current, stack, paragraph = result, [(0, result)], None
            if node.text and node.text.strip():
                paragraph = element(FB, 'p', node.text); current.append(paragraph)
            for child in node:
                if re.fullmatch('h[1-6]', tag(child)):
                    level = int(tag(child)[1])
                    while len(stack) > 1 and stack[-1][0] >= level: stack.pop()
                    section = element(FB, 'section'); section.extend(convert(child, path)); stack[-1][1].append(section)
                    stack.append((level, section)); current = section; paragraph = None
                else:
                    for mapped in convert(child, path):
                        if tag(mapped) in inline_fb:
                            if paragraph is None: paragraph = element(FB, 'p'); current.append(paragraph)
                            paragraph.append(mapped)
                        else:
                            current.append(mapped); paragraph = None
                if child.tail and (child.tail.strip() or paragraph is not None):
                    if paragraph is None: paragraph = element(FB, 'p'); current.append(paragraph)
                    append_text(paragraph, child.tail)
            return result
        def table_cell(result):
            """FB2 cells permit inline markup, but no nested HTML paragraphs."""
            def ending(node):
                if len(node): return node[-1].tail[-1:] if node[-1].tail else ending(node[-1])
                return (node.text or '')[-1:]
            def line_break(target):
                if ending(target) and ending(target) != '\n': append_text(target, '\n')
            def flatten(source, target):
                append_text(target, source.text)
                for child in source:
                    if tag(child) == 'table': raise ConversionError('Вложенную таблицу EPUB нельзя сохранить в FB2.')
                    if tag(child) in inline_fb:
                        clone = element(FB, tag(child), **child.attrib)
                        flatten(child, clone); target.append(clone)
                    else:
                        warnings.add('Абзацы внутри ячеек таблицы EPUB разделены переносами строк.')
                        line_break(target)
                        flatten(child, target)
                        line_break(target)
                    append_text(target, child.tail)
            flattened = element(FB, tag(result), **result.attrib)
            flatten(result, flattened)
            return flattened
        def convert(node, path):
            name, original_name = tag(node), node.get('data-fb2', '')
            captions = []
            if original_name:
                allowed = {'body', 'section', 'title', 'p', 'subtitle', 'poem', 'stanza', 'v', 'cite', 'epigraph', 'annotation', 'text-author', 'date', 'strong', 'emphasis', 'strikethrough', 'sub', 'sup', 'code', 'style', 'a', 'table', 'tr', 'td', 'th', 'image', 'empty-line'}
                if original_name not in allowed: raise ConversionError('Неизвестный исходный элемент FB2.')
                try: attributes = json.loads(node.get('data-fb2-attributes', '{}'))
                except ValueError as error: raise ConversionError('Повреждены исходные атрибуты FB2.') from error
                if not isinstance(attributes, dict) or not all(isinstance(k, str) and isinstance(v, str) for k,v in attributes.items()): raise ConversionError('Неверные атрибуты FB2.')
                result = element(FB, original_name, **attributes)
                if original_name == 'image':
                    image(path, node.get('src', ''), node.get('data-fb2-image-id', ''))
                    return [result]
                if original_name == 'empty-line': return [result]
                result.text = node.text
                for child in node:
                    for mapped in convert(child, path): result.append(mapped)
                    append_text(result, child.tail)
                return [result]
            if name in {'script', 'style'}: return []
            if name == 'table' and any(tag(child) == 'table' for child in node.iter() if child is not node):
                # FB2 cannot nest a table inside a cell. Keep the complete row /
                # cell reading order as ordinary blocks, including every ID,
                # link, image and inline emphasis, rather than dropping a book.
                linear = copy.deepcopy(node)
                for part in linear.iter():
                    if tag(part) in {'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th'}:
                        part.tag = '{' + XH + '}div'
                warnings.add('Вложенные таблицы представлены последовательными блоками FB2. Текст, изображения и ссылки сохранены; расположение строк и столбцов изменилось.')
                return convert(linear, path)
            if name in {'tbody', 'thead', 'tfoot'}:
                return [mapped for child in node for mapped in convert(child, path)]
            if name == 'svg':
                images = [n for n in node if tag(n) == 'image']
                if len(images) == 1 and all(tag(n) in {'image', 'title', 'desc'} for n in node):
                    picture = images[0]
                    if any(picture.get(key) for key in {'transform', 'clip-path', 'mask', 'filter', 'style'}) or picture.get('x', '0') not in {'0', '0.0'} or picture.get('y', '0') not in {'0', '0.0'}:
                        raise ConversionError('Преобразованное изображение SVG нельзя сохранить в FB2 без потери оформления.')
                    if node.get('viewBox'):
                        try:
                            left, top, width, height = map(float, node.get('viewBox').split())
                            if left != 0 or top != 0 or width != float(picture.get('width', str(width))) or height != float(picture.get('height', str(height))):
                                raise ValueError('cropped viewport')
                        except ValueError as error: raise ConversionError('Обрезанное изображение SVG нельзя сохранить в FB2.') from error
                    reference = picture.get('{' + XL + '}href') or picture.get('href', '')
                    attributes = {'{' + XL + '}href': '#' + image(path, reference)}
                    label = ' '.join(plain(n) for n in node if tag(n) in {'title', 'desc'} and plain(n))
                    if label: attributes['alt'] = label
                    warnings.add('SVG-обёртка изображения EPUB заменена исходным изображением без изменения его данных.')
                    return [element(FB, 'image', **attributes)]
                raise ConversionError('Векторную композицию SVG нельзя сохранить в FB2 без потери содержимого.')
            if name in {'audio', 'video', 'math', 'object', 'iframe'}:
                raise ConversionError('Элемент EPUB нельзя сохранить в FB2 без потери содержимого: ' + name)
            is_note = node.get('data-homelib-anchor') in note_anchors or bool(set(node.get('{' + EP + '}type', '').split()) & {'footnote', 'endnote'}) or node.get('role') in {'doc-footnote', 'doc-endnote'}
            mapped_name = 'section' if is_note or name in {'section', 'article'} else block_mapping.get(name) or inline_mapping.get(name)
            if name == 'img':
                attributes = {'{' + XL + '}href': '#' + image(path, node.get('src', ''))}
                if node.get('alt'): attributes['alt'] = node.get('alt')
                return [element(FB, 'image', **attributes)]
            if name == 'br':
                return [element(FB, 'empty-line')]
            if name in {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}:
                result = element(FB, 'title'); paragraph = element(FB, 'p'); result.append(paragraph)
                paragraph.text = node.text
                for child in node:
                    for mapped in convert(child, path): paragraph.append(mapped)
                    append_text(paragraph, child.tail)
            elif mapped_name:
                result = element(FB, mapped_name)
                if mapped_name in {'section', 'cite'}: flow(node, result, path)
                else:
                    result.text = node.text
                    for child in node:
                        if name == 'table' and tag(child) == 'caption': captions.extend(convert(child, path))
                        else:
                            for mapped in convert(child, path): result.append(mapped)
                            append_text(result, child.tail)
                if mapped_name == 'cite' and any(tag(child) not in {'p', 'poem', 'empty-line', 'subtitle', 'table', 'text-author'} for child in result):
                    result.tag = '{' + FB + '}section'
                    warnings.add('Сложная цитата EPUB представлена разделом FB2. Текст, подзаголовки и ссылки сохранены; оформление отступов может отличаться.')
            elif name in {'ul', 'ol'}:
                warnings.add('Списки EPUB записаны отдельными абзацами с сохранением нумерации.')
                result = element(FB, 'section')
                entries = children(node, 'li'); reverse = 'reversed' in node.attrib
                try: index = int(node.get('start', str(len(entries) if reverse else 1)))
                except ValueError: raise ConversionError('Некорректная нумерация списка EPUB.')
                for child in entries:
                    try: index = int(child.get('value', str(index)))
                    except ValueError: raise ConversionError('Некорректный номер пункта EPUB.')
                    entry = flow(child, element(FB, 'section'), path)
                    if child.get('data-homelib-anchor'): entry.set('id', child.get('data-homelib-anchor'))
                    paragraph = next((n for n in entry.iter() if tag(n) == 'p'), None)
                    if paragraph is None: paragraph = element(FB, 'p'); entry.insert(0, paragraph)
                    paragraph.text = ((str(index) + '. ') if name == 'ol' else '• ') + (paragraph.text or '')
                    result.append(entry); index += -1 if reverse else 1
            elif name == 'pre':
                result = element(FB, 'p'); result.append(element(FB, 'code', ''.join(node.itertext())))
            else:
                # Formatting containers are transparent; keep all their text/tails.
                result = element(FB, 'section' if name in {'div', 'aside', 'header', 'footer', 'figure', 'dl', 'dd'} else 'p' if name in {'figcaption', 'li', 'hr'} else 'style')
                if tag(result) == 'style': result.set('name', 'epub-inline')
                if tag(result) == 'section': flow(node, result, path)
                else:
                    result.text = node.text
                    for child in node:
                        for mapped in convert(child, path): result.append(mapped)
                        append_text(result, child.tail)
            anchor = node.get('data-homelib-anchor')
            if anchor:
                if tag(result) == 'title': result[0].set('id', anchor)
                else: result.set('id', anchor)
            if is_note: result.set('data-homelib-note', '1')
            if name == 'a':
                href = node.get('href', '')
                target, fragment = archive.resolve(path, href)
                if target:
                    if (target, fragment) not in available:
                        raise ConversionError('Не найдена цель ссылки EPUB: ' + href)
                    href = '#' + identity(target, fragment)
                result.set('{' + XL + '}href', href)
                if (target, fragment) in notes: result.set('type', 'note')
            for key in ('colspan', 'rowspan', 'align'):
                if node.get(key) and tag(result) in {'td', 'th', 'tr'}: result.set(key, node.get(key))
            if tag(result) in {'td', 'th'}: result = table_cell(result)
            return captions + [styled(node, result)]
        preserved_bodies = set()
        for path, source_body in documents:
            original_body = next((n for n in source_body if n.get('data-fb2') == 'body'), None)
            if original_body is not None:
                converted_bodies = convert(original_body, path)
                book.extend(converted_bodies); preserved_bodies.update(converted_bodies)
                continue
            body = first(book, 'body')
            if body is None: body = element(FB, 'body'); book.append(body)
            root = element(FB, 'section', id=identity(path)); body.append(root)
            flow(source_body, root, path)
            if (path, '') in notes: root.set('data-homelib-note', '1')
        detached_notes = []
        def detach(parent):
            for child in list(parent):
                if child.attrib.pop('data-homelib-note', ''):
                    parent.remove(child)
                    for nested in child.iter(): nested.attrib.pop('data-homelib-note', None)
                    detached_notes.append(child)
                else: detach(child)
        for body in children(book, 'body'): detach(body)
        if detached_notes:
            note_body = element(FB, 'body', name='notes'); note_body.extend(detached_notes); book.append(note_body)
        # FB2 permits unreferenced binaries. Keep local publisher image
        # resources too, even when an alternate cover or decoration is unused.
        if preserved_description is None:
            for item in manifest:
                if item.get('media-type', '').startswith('image/') and archive.resolve(package_path, item.get('href', ''))[0] is not None:
                    image(package_path, item.get('href', ''))
        book.extend(binaries)
        normalize_fb2(book, preserved_bodies)
        # FB2 styleLinkType deliberately has no attributes, unlike the same
        # style element outside a link (namedStyleType).
        for link in book.iter('{' + FB + '}a'):
            for node in link.iter('{' + FB + '}style'): node.attrib.pop('name', None)
        output.write_bytes(serialized(book))
    finally:
        archive.close()


def text_to_book(source, output, warnings, target_extension, **metadata):
    spec = importlib.util.spec_from_file_location('homelib_text_inputs', Path(__file__).with_name('text_inputs.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    # The CLI is launched with -I: load the adjacent, shipped module explicitly.
    # Tests can import this file under an arbitrary module name too.
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    if target_extension == '.epub': module.to_epub(source, output, warnings, api, **metadata)
    else:
        with tempfile.TemporaryDirectory(prefix='homelib-text-') as directory:
            intermediate = Path(directory) / 'reading.epub'
            module.to_epub(source, intermediate, warnings, api, **metadata)
            epub_to_fb2(intermediate, output, warnings)


def kindle_epub(source, output):
    """Keep KindleUnpack resources, repair its known EPUB 3 packaging omissions."""
    archive = EpubArchive(source)
    try:
        container = xml(archive.read('META-INF/container.xml'))
        roots = [n for n in container.iter() if tag(n) == 'rootfile']
        if len(roots) != 1: raise ConversionError('В результате KindleUnpack нет однозначного описания EPUB.')
        package_path = archive.resolve('container.xml', roots[0].get('full-path', ''))[0]
        package = xml(archive.read(package_path))
        changed = {}
        for item in first(package, 'manifest'):
            if item.get('media-type') != 'application/xhtml+xml': continue
            part = archive.resolve(package_path, item.get('href', ''))[0]
            document = xml(archive.read(part)); dirty = False
            for node in document.iter():
                if 'cid' in node.attrib: node.attrib.pop('cid'); dirty = True
            if any(n.tag == '{http://www.w3.org/2000/svg}svg' for n in document.iter()):
                properties = set(item.get('properties', '').split()); properties.add('svg')
                item.set('properties', ' '.join(sorted(properties)))
            if dirty: changed[part] = serialized(document)
        changed[package_path] = serialized(package)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as result:
            result.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            for entry in archive.archive.infolist():
                if entry.filename == 'mimetype': continue
                result.writestr(entry.filename, changed.get(entry.filename, archive.read(entry.filename)))
    finally:
        archive.archive.close()


def kindle_to_book(source, output, warnings, target_extension, **metadata):
    with tempfile.TemporaryDirectory(prefix='homelib-kindle-convert-') as directory:
        root = Path(directory); manifest = root / 'result.json'; work = root / 'unpack'
        args = [sys.executable, '-I', '-B', str(Path(__file__).with_name('kindle_input.py')), str(source), str(manifest), str(work)]
        try:
            process = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
                                     creationflags=0x08000000 if os.name == 'nt' else 0)
        except subprocess.TimeoutExpired as error: raise ConversionError('Подготовка Kindle-книги превысила 90 секунд.') from error
        if process.returncode:
            detail = process.stdout.decode('utf-8', errors='replace')[-1500:]
            raise ConversionError('Не удалось прочитать незашифрованную Kindle-книгу. ' + detail)
        result = json.loads(manifest.read_text(encoding='utf-8')); path = Path(result['path']).resolve()
        if not path.is_relative_to(work) or not path.is_file(): raise ConversionError('Некорректный результат KindleUnpack.')
        if result['format'] == 'epub':
            if target_extension == '.fb2': epub_to_fb2(path, output, warnings)
            else: kindle_epub(path, output)
        elif result['format'] == 'html':
            metadata['resource_root'] = str(path.parent)
            text_to_book(path, output, warnings, target_extension, **metadata)
            warnings.add('Старый MOBI преобразован из HTML; Kindle-вёрстка и служебные сведения могут упрощаться.')
        else: raise ConversionError('Неподдерживаемый результат KindleUnpack.')


def detect_input(source):
    """Bounded signature inspection, also for numeric/mistyped extensions."""
    with source.open('rb') as stream: prefix = stream.read(131072)
    if b'%PDF-' in prefix[:1024]: return '.pdf'
    if prefix.startswith(b'AT&TFORM'): return '.djvu'
    if prefix.startswith(b'ITSF'): return '.chm'
    if prefix.startswith(b'ITOLITLS'): return '.lit'
    if prefix.startswith(b'L\0R\0F\0\0\0'): return '.lrf'
    if prefix.startswith(b'!!8-Bit!!'): return '.tcr'
    if prefix[:2] in (b'1\xbe', b'2\xbe'): return '.wri'
    if prefix.startswith(b'{\\rtf'): return '.rtf'
    if len(prefix) >= 78:
        if prefix[60:68] == b'BOOKMOBI': return '.mobi'
        if prefix[60:68] in (b'TEXtREAd', b'zTXTGPlm', b'SDocSilX', b'PNRdPPrs'): return '.pdb'
    if prefix.startswith(b'PK'):
        with zipfile.ZipFile(source) as archive:
            if len(archive.infolist()) > MAX_ENTRIES: raise ConversionError('В контейнере слишком много файлов.')
            names = set(archive.namelist())
            for marker, extension in [('META-INF/container.xml', '.epub'), ('word/document.xml', '.docx'), ('ppt/presentation.xml', '.pptx'), ('xl/workbook.xml', '.xlsx'), ('fb3/body.xml', '.fb3')]:
                if marker in names: return extension
            if 'mimetype' in names and archive.getinfo('mimetype').file_size < 1024:
                mime = archive.read('mimetype')
                for name, extension in [('text', '.odt'), ('spreadsheet', '.ods'), ('presentation', '.odp'), ('text-template', '.ott'), ('spreadsheet-template', '.ots'), ('presentation-template', '.otp')]:
                    if mime == ('application/vnd.oasis.opendocument.' + name).encode('ascii'): return extension
    probe = prefix.replace(b'\0', b'')
    if re.search(br'<(?:\w+:)?FictionBook\b', probe, re.I): return '.fb2'
    if re.search(br'^MIME-Version:', probe, re.M | re.I) and re.search(br'multipart/|text/html', probe, re.I): return '.mht'
    if re.search(br'<html\b|<!DOCTYPE\s+html', probe, re.I): return '.html'
    return source.suffix.lower()


def convert_book(source, destination, **metadata):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    if source == destination.resolve(): raise ConversionError('Исходная книга и результат должны быть разными файлами.')
    if destination.exists(): raise ConversionError('Файл результата уже существует. Выберите другое имя.')
    if source.stat().st_size > MAX_FILE: raise ConversionError('Книга превышает предел конвертации (64 МБ).')
    extension, target_extension = detect_input(source), destination.suffix.lower()
    conversion = {('.fb2', '.epub'): fb2_to_epub, ('.epub', '.fb2'): epub_to_fb2}.get((extension, target_extension))
    text_input = extension in {'.txt', '.text', '.faq', '.html', '.htm', '.xhtml', '.shtml', '.rtf', '.docx', '.odt', '.fb3', '.md', '.markdown',
                               '.docm', '.dotx', '.dotm', '.ppt', '.pps', '.pot', '.pptx', '.pptm', '.ppsx', '.ppsm', '.potx', '.potm', '.xls', '.xlt', '.xlsx', '.xlsm', '.xltx', '.xltm', '.ods', '.ots', '.odp', '.otp', '.ott', '.wps', '.wpd', '.mht', '.mhtml', '.wri', '.pdb', '.tcr', '.chm', '.pdf', '.djvu', '.djv', '.dju', '.djm', '.djvm'} and target_extension in {'.epub', '.fb2'}
    kindle_input = extension in {'.mobi', '.azw', '.azw3', '.prc'} and target_extension in {'.epub', '.fb2'}
    if conversion is None and not text_input and not kindle_input: raise ConversionError('Этот формат пока не поддерживается конвертером FB2/EPUB.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix='.homelib-convert-', suffix='.tmp', dir=destination.parent)
    os.close(handle); temporary = Path(temporary_name); warnings = set()
    try:
        if kindle_input: kindle_to_book(source, temporary, warnings, target_extension, **metadata)
        elif text_input: text_to_book(source, temporary, warnings, target_extension, input_extension=extension, **metadata)
        else: conversion(source, temporary, warnings)
        # Ensure the generated artifact is readable before publishing its name.
        if destination.suffix.lower() == '.epub':
            with zipfile.ZipFile(temporary) as archive:
                if archive.testzip() is not None: raise ConversionError('Ошибка записи EPUB.')
                for name in archive.namelist():
                    if name.lower().endswith(('.xhtml', '.opf', '.ncx', '.xml')):
                        xml(archive.read(name))
        else: validate_fb2_output(xml(temporary.read_bytes()))
        with temporary.open('r+b') as stream: stream.flush(); os.fsync(stream.fileno())
        if os.name == 'nt': os.rename(temporary, destination)  # Windows never replaces an existing name.
        else: os.link(temporary, destination); temporary.unlink()
        return {'output': str(destination), 'warnings': sorted(warnings), 'size': destination.stat().st_size}
    finally:
        if temporary.exists(): temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description='HomeLib Ru — локальная конвертация книг')
    parser.add_argument('source'); parser.add_argument('destination'); parser.add_argument('--report')
    parser.add_argument('--title', default=''); parser.add_argument('--author', default=''); parser.add_argument('--language', default='')
    parser.add_argument('--resource-root')
    parser.add_argument('--tools-root')
    parser.add_argument('--progress-file', help='Internal bounded page-progress channel')
    parser.add_argument('--reading', action='store_true', help='Internal reading view with visible placeholders for unsupported office objects')
    options = parser.parse_args()
    progress_path = Path(options.progress_file).absolute() if options.progress_file else None
    if progress_path is not None and (progress_path.exists() or progress_path.resolve() in {
            Path(options.source).resolve(), Path(options.destination).resolve(),
            Path(options.report).resolve() if options.report else None}):
        print(json.dumps({'error': 'Файл прогресса уже существует или совпадает с книгой или отчётом.'}, ensure_ascii=False))
        return 1
    progress_sequence = 0
    progress_pages = (0, 0)
    def progress(stage, completed, total):
        nonlocal progress_sequence, progress_pages
        if progress_path is None:
            return
        if stage == 'pages':
            progress_pages = (completed, total)
        elif stage == 'finalizing':
            completed, total = progress_pages
        progress_sequence += 1
        value = json.dumps({'sequence': progress_sequence, 'stage': stage,
                            'completed': completed, 'total': total})
        # The parent owns a private operation directory. Atomic replacement
        # avoids a partially read record while the native worker polls it.
        handle, temporary_name = tempfile.mkstemp(prefix=progress_path.name + '.', dir=progress_path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(handle, 'w', encoding='utf-8') as stream:
                stream.write(value)
            os.replace(temporary, progress_path)
        finally:
            if temporary.exists(): temporary.unlink()
    report = Path(options.report).absolute() if options.report else None
    if report is not None and (report.exists() or report.resolve() in {Path(options.source).resolve(), Path(options.destination).resolve()}):
        print(json.dumps({'error': 'Файл отчёта уже существует или совпадает с книгой.'}, ensure_ascii=False))
        return 1
    def publish_report(text):
        if report is not None:
            # The report also belongs to this operation; never replace a file
            # created by the user or another operation during conversion.
            with report.open('x', encoding='utf-8') as stream:
                stream.write(text); stream.flush(); os.fsync(stream.fileno())
    try:
        result = convert_book(options.source, options.destination, title=options.title, author=options.author,
                              language=options.language, resource_root=options.resource_root, tools_root=options.tools_root,
                              reading=options.reading, progress=progress)
        text = json.dumps(result, ensure_ascii=False)
        publish_report(text)
        print(text)
        return 0
    except (ConversionError, OSError, UnicodeError, LookupError, zipfile.BadZipFile, RecursionError, ValueError) as error:
        text = json.dumps({'error': str(error)}, ensure_ascii=False)
        try: publish_report(text)
        except OSError: pass
        print(text)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

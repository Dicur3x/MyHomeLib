"""Optional MOBI7 and AZW3 writer, powered by the native Kindling tool.

The shared converter prepares EPUB; this independently packaged module owns
only Kindle output. Sources remain read-only and publication never overwrites.
"""
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET
import zipfile


def jpeg_without_record_padding(data):
    """Drop only 1..3 zero bytes from four-byte-aligned Kindle JPEG records."""
    if not data.startswith(b'\xff\xd8\xff') or len(data) % 4:
        return data
    end = data.rfind(b'\xff\xd9')
    if end >= 3:
        padding = data[end + 2:]
        if 1 <= len(padding) <= 3 and not padding.strip(b'\0'):
            return data[:end + 2]
    return data


def gif_without_record_padding(data):
    """Trim alignment only after a structurally complete GIF trailer."""
    if not data.startswith((b'GIF87a', b'GIF89a')) or len(data) < 14 or len(data) % 4:
        return data
    end = len(data.rstrip(b'\0'))
    if not 1 <= len(data) - end <= 3 or data[end - 1] != 0x3b:
        return data
    position = 13 + (3 * (2 ** ((data[10] & 7) + 1)) if data[10] & 0x80 else 0)
    try:
        while position < end:
            marker = data[position]
            position += 1
            if marker == 0x3b:
                return data[:end] if position == end else data
            if marker == 0x2c:
                if position + 9 >= end:
                    return data
                packed = data[position + 8]
                position += 9 + (3 * (2 ** ((packed & 7) + 1)) if packed & 0x80 else 0)
                position += 1  # LZW minimum code size, before image sub-blocks.
            elif marker == 0x21:
                position += 1  # Extension label, before extension sub-blocks.
            else:
                return data
            while position < end:
                size = data[position]
                position += 1
                if not size:
                    break
                position += size
            else:
                return data
    except IndexError:
        pass
    return data


XLINK_HREF = '{http://www.w3.org/1999/xlink}href'
CSS_COMMENT = rb'/\*[^*]*(?:\*(?!/)[^*]*)*\*/'
CSS_STRING = rb'"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\''
CSS_LITERAL = CSS_COMMENT + b'|' + CSS_STRING
CSS_FONT_FACE = re.compile(
    CSS_LITERAL + rb'|(?<![\w-])@font-face\s*\{(?P<body>[^{}]*)\}', re.I)
CSS_DESCRIPTORS = re.compile(CSS_LITERAL + b'|;')
CSS_SINGLE_FONT = re.compile(
    rb'''\s*src\s*:\s*url\(\s*(?:"([^"\\]+)"|'([^'\\]+)'|([^\s"'()\\]+))'''
    rb'''\s*\)(?:\s+format\(\s*(?:"[^"\\]+"|'[^'\\]+'|[\w-]+)\s*\))?\s*''', re.I)


def remove_missing_fonts(api, archive, name, data):
    def repair(match):
        body = match['body']
        if body is None:
            return match[0]
        # Only touch rules with one unambiguous URL. Leave valid fonts and
        # more complex source lists for the writer to handle.
        body = CSS_DESCRIPTORS.sub(lambda token: b' ' if token[0].startswith(b'/*') else token[0], body)
        start = 0
        sources = []
        for token in CSS_DESCRIPTORS.finditer(body + b';'):
            if token[0] == b';':
                descriptor = body[start:token.start()]
                if re.match(rb'\s*src\s*:', descriptor, re.I):
                    sources.append(CSS_SINGLE_FONT.fullmatch(descriptor))
                start = token.end()
        if len(sources) != 1 or sources[0] is None:
            return match[0]
        reference = next(value for value in sources[0].groups() if value is not None)
        try:
            path, _ = archive.resolve(name, reference.decode('utf-8'))
        except (api.ConversionError, UnicodeError, ValueError):
            return match[0]
        return b'' if path is not None and path not in archive.names else match[0]

    return CSS_FONT_FACE.sub(repair, data)


def redundant_cover(api, archive, name, images):
    document = api.xhtml(archive.read(name))
    body = document.find('{' + api.XH + '}body')
    if body is None or ''.join(body.itertext()).strip():
        return False
    wrapper_tags = {'{' + api.XH + '}' + tag for tag in ('body', 'div', 'p', 'span')}
    picture_count = 0
    for node in body.iter():
        if node.get('id') or node.get('name'):
            return False
        if node.tag == '{' + api.XH + '}img' and 'srcset' not in node.attrib:
            path, fragment = archive.resolve(name, node.get('src', ''))
            if path not in images or fragment:
                return False
            picture_count += 1
        elif node.tag not in wrapper_tags:
            return False
    return picture_count == 1


def regular_language_case(value):
    # RFC 5646 section 2.1.1: case never changes a tag's meaning. Kindling's
    # publishing validator nevertheless rejects e.g. UND; use conventional
    # casing in this private copy, without guessing or replacing a language.
    if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*', value):
        return value
    parts = value.split('-')
    extension = False
    for index, part in enumerate(parts):
        if index == 0 or extension:
            parts[index] = part.lower()
        elif len(part) == 2 and part.isalpha():
            parts[index] = part.upper()
        elif len(part) == 4 and part.isalpha():
            parts[index] = part.title()
        else:
            parts[index] = part.lower()
        extension = extension or len(part) == 1
    return '-'.join(parts)


def png_cover(api, data, tools, directory):
    tool = api.image_processor_path(tools)
    if not tool.is_file():
        raise api.ComponentRequired('ImageProcessing', 'Для подготовки обложки Kindle нужен модуль HomeLibre Images.')
    with tempfile.TemporaryDirectory(prefix='homelibre-kindle-cover-', dir=directory) as folder:
        root=Path(folder); source=root/'cover.gif'; output=root/'frames.zip'; source.write_bytes(data)
        try:
            done=subprocess.run([str(tool),'--image-pages',str(source),str(output)], capture_output=True,
                                timeout=30,creationflags=0x08000000 if os.name=='nt' else 0)
        except subprocess.TimeoutExpired as error:
            raise api.ConversionError('Подготовка обложки Kindle превысила 30 секунд.') from error
        if done.returncode or not output.is_file():
            raise api.ConversionError('Не удалось подготовить обложку Kindle без изменения качества.')
        with zipfile.ZipFile(output) as archive:
            entries=archive.infolist()
            if len(entries)!=1 or entries[0].file_size>16*1024*1024:
                raise api.ConversionError('Обложка Kindle содержит несколько кадров или превышает предел размера.')
            png=archive.read(entries[0])
            if not png.startswith(b'\x89PNG\r\n\x1a\n'):
                raise api.ConversionError('Модуль изображений не вернул обложку PNG.')
            return png


def publication_records(api, package):
    metadata = api.first(package, 'metadata')
    if metadata is None:
        return []
    dc = '{' + api.DC + '}'
    opf = '{' + api.OP + '}'
    field_types = {'creator': 100, 'publisher': 101, 'description': 103, 'subject': 105,
                   'date': 106, 'contributor': 108, 'rights': 109}
    isbn_ids = {node.get('refines', '').removeprefix('#') for node in metadata
                if node.get('property') == 'identifier-type' and node.get('scheme') == 'onix:codelist5'
                and api.plain(node) in {'02', '15'}}
    records = []
    for node in metadata:
        if not node.tag.startswith(dc) or not (value := api.plain(node)):
            continue
        name = api.tag(node)
        identity = field_types.get(name)
        if name == 'identifier':
            if value.casefold().startswith('urn:isbn:'):
                identity, value = 104, value[9:]
            elif node.get(opf + 'scheme', node.get('scheme', '')).casefold() == 'isbn' or node.get('id') in isbn_ids:
                identity = 104
        elif name == 'date' and node.get(opf + 'event', node.get('event', '')).casefold() not in {'', 'publication'}:
            continue
        if identity is not None and value:
            records.append((identity, value.encode('utf-8')))
    return records


LEGACY_ALIGNMENT = {'left', 'right', 'center', 'justify'}
LEGACY_LENGTH = re.compile(r'0|(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:em|pt|px)')
LEGACY_PROPERTIES = {'text-align', 'text-indent', 'margin-left', 'margin-right', 'margin-top'}
LEGACY_PARAGRAPHS = {'p', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}
LEGACY_BLOCKS = LEGACY_PARAGRAPHS | {'div', 'blockquote', 'section', 'td', 'th'}


def legacy_declarations(api, css):
    parts = re.finditer(api.CSS_QUOTED + r'|;', css)
    start = 0
    for token in parts:
        if token[0] != ';':
            continue
        key, _, value = css[start:token.start()].partition(':')
        start = token.end()
        key = key.strip().lower()
        value, important = re.subn(r'\s*!\s*important\s*$', '', value.strip().lower())
        if key in LEGACY_PROPERTIES:
            yield key, value, bool(important)
        elif key == 'margin':
            values = value.split()
            if 1 <= len(values) <= 4:
                top = values[0]
                right = values[1] if len(values) > 1 else top
                left = values[3] if len(values) == 4 else right
                for prop, part in (('margin-top', top), ('margin-right', right), ('margin-left', left)):
                    yield prop, part, bool(important)


def legacy_styles(api, archive, path, document, cache):
    result = []
    head = api.first(document, 'head')
    for part in (() if head is None else head):
        kind = api.tag(part)
        if part.get('media', '').strip().lower() not in {'', 'all', 'screen'}:
            continue
        if kind == 'style':
            css = ''.join(part.itertext())
        elif kind == 'link' and 'stylesheet' in part.get('rel', '').lower().split():
            try:
                origin, _ = archive.resolve(path, part.get('href', ''))
            except api.EpubOutsideResource:
                continue
            if origin not in archive.names:
                continue
            if origin not in cache:
                cache[origin] = archive.read(origin).decode('utf-8-sig', errors='replace')
            css = cache[origin]
        else:
            continue
        css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
        depth = start = opening = 0
        for token in re.finditer(api.CSS_QUOTED + r'|[{}]', css):
            if token[0] == '{':
                if depth == 0:
                    opening = token.start()
                depth += 1
            elif token[0] == '}' and depth:
                depth -= 1
                if depth:
                    continue
                selectors = css[start:opening].rsplit(';', 1)[-1].strip()
                declarations = css[opening + 1:token.start()]
                start = token.end()
                if selectors.startswith('@'):
                    continue
                values = tuple(legacy_declarations(api, declarations + ';'))
                if not values:
                    continue
                for selector in selectors.split(','):
                    match = re.fullmatch(r'([\w-]+|\*)?((?:[.#][\w-]+)*)', selector.strip())
                    if match:
                        name, suffix = match.groups()
                        checks = tuple(re.findall(r'([.#])([\w-]+)', suffix))
                        priority = (0, suffix.count('#'), suffix.count('.'), int(name not in (None, '*')))
                        result.append((name, checks, priority, values))
    return result


def apply_legacy_presentation(api, archive, path, document, cache):
    """Translate representable paragraph CSS before Kindling assigns link offsets."""
    rules = legacy_styles(api, archive, path, document, cache)
    replacements = []
    for node in document.iter():
        name = api.tag(node)
        if node.tag != '{' + api.XH + '}' + name or name not in LEGACY_BLOCKS:
            continue
        classes, identity = set(node.get('class', '').split()), node.get('id', '')
        chosen = {}

        def apply(declarations, specificity):
            for prop, value, important in declarations:
                rank = (important, *specificity)
                if prop not in chosen or rank >= chosen[prop][0]:
                    chosen[prop] = rank, value

        for tag, checks, priority, declarations in rules:
            if tag in {None, '*', name} and all(value == identity if mark == '#' else value in classes
                                                  for mark, value in checks):
                apply(declarations, priority)
        inline = node.get('style', '')
        apply(legacy_declarations(api, inline + ';'), (1, 0, 0, 0))
        values = {prop: value for prop, (_, value) in chosen.items()}
        alignment = values.get('text-align')
        if alignment in LEGACY_ALIGNMENT:
            node.set('align', alignment)
            # The native writer converts an isolated text-align:center style
            # into align itself. Avoid two copies of the same attribute.
            if re.fullmatch(r'\s*text-align\s*:\s*center\s*;?\s*', inline, re.I):
                node.attrib.pop('style')
        indent, spacing = values.get('text-indent', ''), values.get('margin-top', '')
        if name in LEGACY_PARAGRAPHS:
            if LEGACY_LENGTH.fullmatch(indent):
                node.set('width', indent if indent != '0' else '0pt')
            if LEGACY_LENGTH.fullmatch(spacing):
                node.set('height', spacing if spacing != '0' else '0pt')
        left, right = values.get('margin-left', ''), values.get('margin-right', '')
        if name in {'div', 'section'} and left == right and left not in {'0', '0pt', '0px', '0em'} and LEGACY_LENGTH.fullmatch(left):
            replacements.append(node)
    for node in replacements:
        node.tag = '{' + api.XH + '}blockquote'


def canonical_input(api, source, destination, warnings=None, tools_root=None, metadata_records=None, *, legacy=False):
    """Adapt a private copy, keeping images, CSS and standard book metadata.

    Kindling removes root namespace declarations from its KF8 skeleton, so
    normalize XHTML to its default namespace first. Our FB2 restoration hints
    describe pre-Kindle resource names and must not survive that transformation.
    """
    archive = api.EpubArchive(source)
    namespaces = ET._namespace_map.copy()
    try:
        container = api.xml(archive.read('META-INF/container.xml'))
        documents, styles, navigation = set(), set(), set()
        packages, image_items, duplicate_covers = {}, {}, {}
        declared_cover_images = set()
        cover_declared = False
        for rootfile in (node for node in container.iter() if api.tag(node) == 'rootfile'):
            name = archive.resolve('container.xml', rootfile.get('full-path', ''))[0]
            package = api.xml(archive.read(name))
            packages[name] = package
            cover_ids = {node.get('content') for node in package.iter()
                         if api.tag(node) == 'meta' and node.get('name') == 'cover' and node.get('content')}
            items = {}
            cover_images = set()
            for item in (node for node in package.iter() if api.tag(node) == 'item'):
                kind = item.get('media-type', '')
                identity = item.get('id')
                href = item.get('href', '')
                member = archive.resolve(name, href)[0]
                items[identity] = member, href
                if 'cover-image' in item.get('properties', '').split():
                    cover_ids.add(identity)
                if identity in cover_ids and kind.startswith('image/') and member in archive.names:
                    cover_images.add(member)
                if kind == 'application/xhtml+xml':
                    if member not in archive.names:
                        raise api.ConversionError('В EPUB отсутствует глава книги.')
                    documents.add(member)
                elif kind.startswith('image/'):
                    image_items.setdefault(member, []).append(item)
                elif kind == 'text/css':
                    styles.add(member)
                elif kind == 'application/x-dtbncx+xml':
                    navigation.add(member)
            declared_cover_images.update(cover_images)
            cover_declared = cover_declared or bool(cover_ids)
            spine = next((node for node in package if api.tag(node) == 'spine'), None)
            if spine is not None and len(spine) > 1:
                page, _ = items.get(spine[0].get('idref'), (None, ''))
                if cover_images and page in documents and redundant_cover(api, archive, page, cover_images):
                    for following in spine[1:]:
                        target, href = items.get(following.get('idref'), (None, ''))
                        if target != page and target in documents and following.get('linear') != 'no':
                            duplicate_covers[name] = (spine, spine[0], page, href)
                            break
        if not packages or not documents:
            raise api.ConversionError('В EPUB отсутствует текст книги.')
        if metadata_records is not None:
            metadata_records.extend(publication_records(api, next(iter(packages.values()))))
        ET.register_namespace('', api.XH)
        ET.register_namespace('epub', api.EP)
        cover_pages = {page for _, _, page, _ in duplicate_covers.values()}
        linked_covers = set()
        style_cache = {}

        def keep_linked_covers(name, nodes):
            for node in nodes:
                for attribute in ('href', XLINK_HREF, 'src'):
                    reference = node.get(attribute)
                    if not reference:
                        continue
                    try:
                        path, _ = archive.resolve(name, reference)
                    except (api.ConversionError, ValueError):
                        continue
                    if path != name and path in cover_pages:
                        linked_covers.add(path)

        with zipfile.ZipFile(destination, 'x') as target:
            for member in archive.archive.infolist():
                name = member.filename
                if name in packages:
                    continue  # OPF records also depend on the actual resource bytes.
                data = archive.read(name)
                if name in documents:
                    root = api.xhtml(data)
                    if root.tag != '{' + api.XH + '}html':
                        raise api.ConversionError('Некорректная глава EPUB.')
                    if legacy:
                        apply_legacy_presentation(api, archive, name, root, style_cache)
                    for node in root.iter():
                        for attribute in list(node.attrib):
                            if attribute == 'data-fb2' or attribute.startswith('data-fb2-'):
                                del node.attrib[attribute]
                            elif attribute in {'href', XLINK_HREF, 'src'}:
                                reference = node.get(attribute)
                                if urlsplit(reference).scheme.lower() in {'http', 'https', 'mailto'}:
                                    node.set(attribute, quote(reference, safe=":/?#[]@!$&'()*+,;=%"))
                    if cover_pages:
                        keep_linked_covers(name, root.iter())
                    normalize = getattr(api, 'local_foreign_namespaces', None)
                    if normalize is None:
                        raise api.ComponentRequired('BookProcessing', 'Обновите модуль обработки книг для сохранения Kindle.')
                    normalize(root, api.XH)
                    # XHTML permits <p/>, but Kindling's HTML-oriented checks
                    # treat it as an unclosed paragraph. Pair non-void tags;
                    # keep void elements self-closing so <br></br> cannot turn
                    # into two line breaks in an HTML reader.
                    data = ET.tostring(root, encoding='utf-8', xml_declaration=True,
                                       short_empty_elements=False)
                    data = re.sub(rb'(<(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)\b[^<>]*?)></\2>',
                                  rb'\1 />', data)
                elif name in image_items:
                    if name in declared_cover_images and data.startswith((b'GIF87a', b'GIF89a')):
                        data=png_cover(api,data,Path(tools_root or Path(__file__).resolve().parent.parent),destination.parent)
                        if warnings is not None:
                            warnings.add('Обложка GIF подготовлена для Kindle в PNG без уменьшения изображения.')
                    for item in image_items[name]:
                        try:
                            mime, _ = api.fb2_image_type(data, item.get('media-type'))
                        except api.ConversionError:
                            continue  # Unknown types remain subject to Kindling's checks.
                        item.set('media-type', mime)
                    # Keep the encoded image, trimming only Kindle record alignment.
                    data = gif_without_record_padding(jpeg_without_record_padding(data))
                elif name in styles:
                    cleaned = remove_missing_fonts(api, archive, name, data)
                    if cleaned != data and warnings is not None:
                        warnings.add('В EPUB отсутствуют некоторые встроенные шрифты. Kindle использует доступные шрифты.')
                    data = cleaned
                elif cover_pages and name in navigation:
                    try:
                        nav = api.xml(data)
                    except api.ConversionError:
                        linked_covers.update(cover_pages)
                    else:
                        keep_linked_covers(name, nav.iter())
                target.writestr(member, data)
            startup_references = {}
            for name, package in packages.items():
                if cover_pages:
                    redirects = []
                    guide = api.first(package, 'guide')
                    if name in duplicate_covers and guide is not None:
                        page = duplicate_covers[name][2]
                        for node in guide:
                            if api.tag(node) != 'reference' or node.get('type') != 'text':
                                continue
                            href = node.get('href', '')
                            try:
                                path, fragment = archive.resolve(name, href)
                                if path == page and not fragment and not urlsplit(href).query:
                                    redirects.append(node)
                            except (api.ConversionError, ValueError):
                                continue
                    startup_references[name] = redirects
                    keep_linked_covers(name, (node for node in package.iter()
                        if api.tag(node) == 'reference' and node not in redirects))
            for name, package in packages.items():
                if name in duplicate_covers:
                    spine, reference, page, start_href = duplicate_covers[name]
                    if page not in linked_covers:
                        spine.remove(reference)
                        for node in startup_references[name]:
                            node.set('href', start_href)
                for metadata in (node for node in package if api.tag(node) == 'metadata'):
                    for item in list(metadata):
                        if item.get('property', '').startswith('mhl:fb2-'):
                            metadata.remove(item)
                        elif item.tag == '{' + api.DC + '}language' and item.text:
                            item.text = regular_language_case(item.text)
                target.writestr(archive.archive.getinfo(name),
                                ET.tostring(package, encoding='utf-8', xml_declaration=True))
        return cover_declared
    finally:
        ET._namespace_map.clear()
        ET._namespace_map.update(namespaces)
        archive.close()


def only_publication_cover_required(completed, cover_declared):
    """Accept one KDP publishing requirement, never a malformed-book error.

    A personal Kindle file may have no cover, especially after the explicit
    no-images choice. Run the writer's full pre-flight first; only its sole
    missing-cover finding can permit a second build. The HTML self-check and
    our EPUB/Palm checks remain enabled. Any other error still aborts.
    """
    if cover_declared or completed.returncode != 1:
        return False
    findings = re.findall(r'^\[error\s+([^\]]+)\]', completed.stdout or '', flags=re.MULTILINE)
    return findings == ['R4.2.1'] and 'Build aborted: 1 validation errors.' in (completed.stderr or '')


MOBI_EOF = b'\xe9\x8e\x0d\x0a'


def palm_records(api, stream, size):
    if size < 94 or size > api.MAX_TOTAL:
        raise api.ConversionError('Некорректный размер результата Kindle.')
    header = stream.read(78)
    count = struct.unpack_from('>H', header, 76)[0]
    if header[60:68] != b'BOOKMOBI' or not count or 78 + count * 8 > size:
        raise api.ConversionError('Конвертер не создал книгу Kindle.')
    table = stream.read(count * 8)
    offsets = [offset for offset, _ in struct.iter_unpack('>II', table)]
    if offsets[0] < 78 + count * 8 or any(a > b for a, b in zip(offsets, offsets[1:])) or offsets[-1] >= size:
        raise api.ConversionError('Повреждён каталог записей книги Kindle.')
    return header, table, offsets


def mobi_version(stream, offset):
    stream.seek(offset)
    record = stream.read(40)
    if len(record) == 40 and record[16:20] == b'MOBI':
        return struct.unpack_from('>I', record, 36)[0]
    return None


def mobi_exth(api, record):
    error = api.ConversionError('Повреждены метаданные экспортированной книги MOBI.')
    if len(record) < 232 or record[16:20] != b'MOBI':
        raise error
    start = 16 + struct.unpack_from('>I', record, 20)[0]
    if start < 232 or start + 12 > len(record) or record[start:start + 4] != b'EXTH':
        raise error
    length, count = struct.unpack_from('>II', record, start + 4)
    position = start + 12
    end = start + length
    title, title_size = struct.unpack_from('>II', record, 84)
    if not position <= end <= title <= len(record) - title_size or count > (end - position) // 8:
        raise error
    items = []
    for _ in range(count):
        if position + 8 > end:
            raise error
        identity, size = struct.unpack_from('>II', record, position)
        if not 8 <= size <= end - position:
            raise error
        items.append((identity, record[position + 8:position + size]))
        position += size
    return start, position, length, title, items


def update_publication_records(api, source, destination, additions, check=None):
    """Update EXTH without changing the text, indices, images or their records."""
    with source.open('rb') as stream:
        size = source.stat().st_size
        header, table, offsets = palm_records(api, stream, size)
        if len(offsets) < 2 or mobi_version(stream, offsets[0]) not in {6, 8}:
            raise api.ConversionError('Невозможно перенести сведения об издании в файл Kindle.')
        stream.seek(78 + len(table))
        gap = stream.read(offsets[0] - 78 - len(table))
        record = stream.read(offsets[1] - offsets[0])
        start, _, old_length, title, current = mobi_exth(api, record)
        updated_types = {identity for identity, _ in additions}
        items = [item for item in current if item[0] not in updated_types] + additions
        if items == current:
            return source

        payload = b''.join(struct.pack('>II', identity, 8 + len(value)) + value for identity, value in items)
        payload += b'\0' * (-len(payload) % 4)
        block = b'EXTH' + struct.pack('>II', 12 + len(payload), len(items)) + payload
        record_header = bytearray(record[:start])
        struct.pack_into('>I', record_header, 84, title + len(block) - old_length)
        # Kindling reserves zero padding after the title for metadata growth.
        # Reuse it when possible so old readers see the same record offsets.
        title_length = struct.unpack_from('>I', record_header, 88)[0]
        tail = record[start + old_length:]
        padding = len(record) - len(record.rstrip(b'\0'))
        useful_tail_size = max(title + title_length - start - old_length, len(tail) - padding)
        replacement = record_header + block + tail[:useful_tail_size]
        replacement.extend(b'\0' * (max(len(record), (len(replacement) + 3) & ~3) - len(replacement)))
        shift = len(replacement) - len(record)
        if size + shift > api.MAX_TOTAL:
            raise api.ConversionError('Файл Kindle со сведениями об издании превышает допустимый размер.')
        directory = bytearray(table)
        for index, offset in enumerate(offsets[1:], 1):
            struct.pack_into('>I', directory, 8 * index, offset + shift)
        with destination.open('xb') as output:
            output.write(header + directory + gap + replacement)
            while chunk := stream.read(1024 * 1024):
                if check is not None:
                    check()
                output.write(chunk)
    return destination


def extract_legacy_mobi(api, dual, destination, check=None):
    """Write the old Kindle records from a Kindling MOBI without re-encoding them."""
    size = dual.stat().st_size
    with dual.open('rb') as stream:
        header, table, offsets = palm_records(api, stream, size)
        error = api.ConversionError('Модуль записи не создал совместимую часть MOBI для старых Kindle.')
        if len(offsets) < 4 or mobi_version(stream, offsets[0]) != 6:
            raise error
        stream.seek(78 + len(table))
        if offsets[0] != 80 + len(table) or stream.read(2) != b'\0\0':
            raise error
        stream.seek(offsets[0])
        record = stream.read(offsets[1] - offsets[0])
        start, item_end, exth_length, title, items = mobi_exth(api, record)
        boundaries = [value for identity, value in items if identity == 121]
        if len(boundaries) != 1 or len(boundaries[0]) != 4:
            raise error
        kf8 = int.from_bytes(boundaries[0], 'big')
        if not 2 < kf8 < len(offsets) - 1 or offsets[kf8] - offsets[kf8 - 1] != 8:
            raise error
        stream.seek(offsets[kf8 - 1])
        if stream.read(8) != b'BOUNDARY' or mobi_version(stream, offsets[kf8]) != 8:
            raise error
        stream.seek(offsets[-1])
        if stream.read(5) != MOBI_EOF or struct.unpack_from('>I', record, 228)[0] != 0:
            raise error

        legacy_items = []
        for identity, value in items:
            if identity == 121:
                value = b'\xff' * 4  # No second MOBI header.
            elif identity == 129:
                value = b''  # Drop the KF8 thumbnail URI. Legacy image indices stay intact.
            elif identity == 536:
                continue  # The HD image container belongs to the discarded section.
            legacy_items.append(struct.pack('>II', identity, 8 + len(value)) + value)
        exth_payload = b''.join(legacy_items)
        shift = start + 12 + len(exth_payload) - item_end
        record_header = bytearray(record[:start])
        struct.pack_into('>I', record_header, 84, title + shift)
        flags = struct.unpack_from('>I', record_header, 128)[0]
        struct.pack_into('>I', record_header, 128, flags & ~0x1800)
        legacy_record = (record_header + b'EXTH' + struct.pack('>II', exth_length + shift, len(legacy_items)) +
                         exth_payload + record[item_end:])

        legacy_count = kf8  # Everything before BOUNDARY, plus one EOF record.
        pdb_header = bytearray(header)
        struct.pack_into('>I', pdb_header, 68, 2 * legacy_count + 1)
        struct.pack_into('>H', pdb_header, 76, legacy_count)
        first = 80 + 8 * legacy_count
        delta = first - offsets[0] + shift
        directory = bytearray(table[:8 * legacy_count])
        struct.pack_into('>I', directory, 0, first)
        for index in range(1, legacy_count):
            struct.pack_into('>I', directory, 8 * index, offsets[index] + delta)

        with destination.open('xb') as output:
            output.write(pdb_header + directory + b'\0\0')
            output.write(legacy_record)
            stream.seek(offsets[1])
            remaining = offsets[kf8 - 1] - offsets[1]
            while remaining:
                if check is not None:
                    check()
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise error
                output.write(chunk)
                remaining -= len(chunk)
            output.write(MOBI_EOF)


def validate_output(api, path, extension):
    """Check the actual Palm/MOBI records, rather than trusting a suffix."""
    with path.open('rb') as stream:
        _, _, offsets = palm_records(api, stream, path.stat().st_size)
        expected = 6 if extension == '.mobi' else 8
        if mobi_version(stream, offsets[0]) != expected:
            raise api.ConversionError('Версия книги Kindle не соответствует выбранному формату.')
        if extension == '.mobi':
            if len(offsets) < 2:
                raise api.ConversionError('В MOBI отсутствуют записи книги.')
            stream.seek(offsets[0])
            _, _, _, _, items = mobi_exth(api, stream.read(offsets[1] - offsets[0]))
            stream.seek(offsets[-1])
            if any(identity == 121 and value != b'\xff' * 4 for identity, value in items) or stream.read(5) != MOBI_EOF:
                raise api.ConversionError('Результат MOBI не является самостоятельной книгой для старых Kindle.')


def convert(api, source, destination, options):
    source, destination = Path(source), Path(destination)
    extension = destination.suffix.lower()
    if extension not in {'.mobi', '.azw3'}:
        raise api.ConversionError('Неизвестный формат сохранения Kindle.')
    if destination.exists() or destination.resolve() == source.resolve():
        raise api.ConversionError('Исходная книга и результат должны быть разными файлами; результат уже не должен существовать.')
    tools = Path(options.get('tools_root') or Path(__file__).resolve().parent.parent)
    writer = tools / 'kindle-export/kindling-cli.exe'
    if not writer.is_file():
        raise api.ComponentRequired('KindleExport',
            'Для сохранения в MOBI и AZW3 нужен модуль записи Kindle — Kindling.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    warnings = set()
    with tempfile.TemporaryDirectory(prefix='homelibre-kindle-output-', dir=destination.parent) as folder:
        work = Path(folder)
        prepared = work / 'prepared.epub'
        # Reuse all input decoders, image choices and scan controls. This also
        # validates an existing EPUB without a lossy FB2 round trip.
        # EPUB is only a private intermediate: Kindle embeds image records
        # directly, so ZIP-oriented candidate selection would be misleading.
        result = api.convert_book(source, prepared, **dict(options,image_container='raw',_static_gifs=True))
        warnings.update(result.get('warnings', []))
        adapted = work / 'kindle-input.epub'
        metadata_records = []
        cover_declared = canonical_input(api, prepared, adapted, warnings, tools, metadata_records,
                                         legacy=extension == '.mobi')
        output = work / ('book' + extension)
        command = [str(writer), 'build', str(adapted), '-o', str(output),
                   '--no-embed-source', '--creator-tag']
        if extension == '.mobi':
            command.append('--legacy-mobi')
        progress = options.get('progress') or (lambda *_: None)
        progress('kindle-writing', 0, 1)
        exemptions = []
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace',
                                       timeout=300, creationflags=0x08000000 if os.name == 'nt' else 0)
            if not output.exists() and only_publication_cover_required(completed, cover_declared):
                # All KPG checks have run. Do not invent an image just to satisfy
                # a store-submission rule for a user's personal, coverless book.
                remaining = max(1, 300 - (time.monotonic() - started))
                completed = subprocess.run(command + ['--no-validate'], capture_output=True,
                    encoding='utf-8', errors='replace', timeout=remaining,
                    creationflags=0x08000000 if os.name == 'nt' else 0)
                exemptions.append('R4.2.1')
        except subprocess.TimeoutExpired as error:
            raise api.ConversionError('Модуль записи Kindle не завершил работу за 5 минут.') from error
        if completed.returncode or not output.is_file():
            detail = '\n'.join(part.strip() for part in (completed.stdout, completed.stderr) if part).strip()
            if len(detail) > 4500:
                errors = [line for line in detail.splitlines() if line.startswith('[error ')]
                detail = '\n'.join(errors)[:4500] if errors else detail[-4500:]
            raise api.ConversionError('Не удалось сохранить книгу Kindle.' + (' ' + detail if detail else ''))
        if extension == '.mobi':
            legacy = work / 'legacy.mobi'
            extract_legacy_mobi(api, output, legacy, options.get('cancel_check'))
            output = legacy
        if metadata_records:
            output = update_publication_records(api, output, work / ('metadata' + extension),
                                                metadata_records, options.get('cancel_check'))
        validate_output(api, output, extension)
        # Publication and cleanup follow the shared converter's no-replace
        # contract, including a name created by another process during work.
        with output.open('r+b') as stream:
            stream.flush()
            os.fsync(stream.fileno())
        if os.name == 'nt':
            os.rename(output, destination)
        else:
            os.link(output, destination)
            output.unlink()
        progress('kindle-writing', 1, 1)
    return dict(output=str(destination), warnings=sorted(warnings), size=destination.stat().st_size,
                publication_rule_exemptions=exemptions)

"""Optional MOBI7/KF8 and AZW3 writer, powered by the native Kindling tool.

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
from urllib.parse import urlsplit
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


def local_foreign_namespaces(root, xhtml_uri):
    """Keep actual QName bindings when the writer replaces the HTML root."""
    xml_uri = 'http://www.w3.org/XML/1998/namespace'

    def namespaces(node):
        return {name[1:].split('}', 1)[0] for name in [node.tag, *node.attrib]
                if isinstance(name, str) and name.startswith('{')
                and name[1:].split('}', 1)[0] not in {xhtml_uri, xml_uri}}

    uris = set()
    for node in root.iter():
        uris.update(namespaces(node))
    if not uris:
        return
    preferred = {'http://www.w3.org/2000/svg': 'svg',
                 'http://www.w3.org/1999/xlink': 'xlink',
                 'http://www.w3.org/1998/Math/MathML': 'math',
                 'http://www.idpf.org/2007/ops': 'epub'}
    prefixes, used = {}, {'', 'xml', 'xmlns'}
    for uri in sorted(uris):
        prefix = preferred.get(uri, 'hlns' + str(len(prefixes)))
        while prefix in used:
            prefix += '_'
        used.add(prefix)
        ET.register_namespace(prefix, uri)
        prefixes[uri] = prefix

    def visit(node, inherited):
        scope = inherited | namespaces(node)
        for uri in scope - inherited:
            node.set('xmlns:' + prefixes[uri], uri)
        for child in node:
            visit(child, scope)

    # Root declarations alone are lost by the writer. Start the scope again
    # on each retained subtree; QName URIs come from parsed XML, not guesses.
    for child in root:
        visit(child, set())


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


def canonical_input(api, source, destination, warnings=None):
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
        ET.register_namespace('', api.XH)
        ET.register_namespace('epub', api.EP)
        cover_pages = {page for _, _, page, _ in duplicate_covers.values()}
        linked_covers = set()

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
                    for node in root.iter():
                        for attribute in list(node.attrib):
                            if attribute == 'data-fb2' or attribute.startswith('data-fb2-'):
                                del node.attrib[attribute]
                    if cover_pages:
                        keep_linked_covers(name, root.iter())
                    local_foreign_namespaces(root, api.XH)
                    # XHTML permits <p/>, but Kindling's HTML-oriented checks
                    # treat it as an unclosed paragraph. Pair non-void tags;
                    # keep void elements self-closing so <br></br> cannot turn
                    # into two line breaks in an HTML reader.
                    data = ET.tostring(root, encoding='utf-8', xml_declaration=True,
                                       short_empty_elements=False)
                    data = re.sub(rb'(<(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)\b[^<>]*?)></\2>',
                                  rb'\1 />', data)
                elif name in image_items:
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


def validate_output(api, path, extension):
    """Check the actual Palm/MOBI records, rather than trusting a suffix."""
    size = path.stat().st_size
    if size < 94 or size > api.MAX_TOTAL:
        raise api.ConversionError('Некорректный размер результата Kindle.')
    with path.open('rb') as stream:
        header = stream.read(78)
        count = struct.unpack_from('>H', header, 76)[0]
        if header[60:68] != b'BOOKMOBI' or not count or 78 + count * 8 > size:
            raise api.ConversionError('Конвертер не создал книгу Kindle.')
        table = stream.read(count * 8)
        offsets = [struct.unpack_from('>I', table, i * 8)[0] for i in range(count)]
        if offsets[0] < 78 + count * 8 or any(a > b for a, b in zip(offsets, offsets[1:])) or offsets[-1] >= size:
            raise api.ConversionError('Повреждён каталог записей книги Kindle.')
        stream.seek(offsets[0])
        record = stream.read(40)
        expected = 6 if extension == '.mobi' else 8
        if record[16:20] != b'MOBI' or len(record) != 40 or struct.unpack_from('>I', record, 36)[0] != expected:
            raise api.ConversionError('Версия книги Kindle не соответствует выбранному формату.')
        if extension == '.mobi':
            for i, offset in enumerate(offsets[:-1]):
                stream.seek(offset)
                if stream.read(8) == b'BOUNDARY':
                    stream.seek(offsets[i + 1])
                    next_record = stream.read(40)
                    if len(next_record) == 40 and next_record[16:20] == b'MOBI' and struct.unpack_from('>I', next_record, 36)[0] == 8:
                        break
            else:
                raise api.ConversionError('В MOBI отсутствует совместимая часть KF8.')


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
        result = api.convert_book(source, prepared, **dict(options,image_container='raw'))
        warnings.update(result.get('warnings', []))
        adapted = work / 'kindle-input.epub'
        cover_declared = canonical_input(api, prepared, adapted, warnings)
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

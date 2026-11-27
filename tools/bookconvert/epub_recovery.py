"""Recover EPUB entries and readable fragments into a private copy."""

from codecs import getincrementaldecoder
from datetime import datetime, timezone
import posixpath
import re
import struct
from urllib.parse import quote, unquote, urlsplit
from xml.parsers import expat
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile
import zlib


CONTAINER = 'META-INF/container.xml'
MIME = b'application/epub+zip'
MEDIA = {
    '.css': 'text/css', '.gif': 'image/gif', '.jpeg': 'image/jpeg',
    '.jpg': 'image/jpeg', '.png': 'image/png', '.svg': 'image/svg+xml',
}


def restore_metadata(api, data, allowed_open, error):
    """Complete an XML suffix only when every missing token is a closing tag."""
    if len(data) > 4 * 1024 * 1024 or b'\x00' in data:
        raise error
    stack = []
    parser = expat.ParserCreate()

    def opened(name, attributes):
        if len(stack) >= 128:
            raise error
        stack.append(name)

    def doctype(name, system, public, internal):
        if internal:
            raise error

    parser.StartElementHandler = opened
    parser.EndElementHandler = lambda name: stack.pop()
    parser.StartDoctypeDeclHandler = doctype
    try:
        parser.Parse(data, True)
    except expat.ExpatError as parse_error:
        if parse_error.code not in (expat.errors.codes[expat.errors.XML_ERROR_UNCLOSED_TOKEN],
                                    expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS]):
            raise error
        position = parser.ErrorByteIndex
        if not stack or any(not name.isascii() or name.rsplit(':', 1)[-1] not in allowed_open for name in stack):
            raise error
        suffix = ''.join(f'</{name}>' for name in reversed(stack)).encode('ascii')
        if not suffix.startswith(data[position:]):
            raise error
        repaired = data[:position] + suffix
        return api.xml(repaired), repaired
    raise error


def restore_navigation_links(api, archive, ncx, navigation, chapters, parts, warnings, check):
    """Use matching labels and anchors from the book's declared NCX to repair dead links."""
    def address(origin, reference):
        try:
            if not reference or urlsplit(reference).query:
                return None, ''
            return archive.resolve(origin, reference)
        except (ValueError, api.ConversionError):
            return None, ''

    def title(node):
        return ' '.join(api.plain(node).split()).casefold() if node is not None else ''

    def chapter(path):
        if check is not None:
            check()
        notices = set()
        try:
            data = parts[path] if path in parts else archive.read(path)
            document = api.read_epub_content(data, notices, part=path, allow_partial_epub=True)
        except (api.ConversionError, api.zipfile.BadZipFile):
            return None, notices
        return document, notices

    lookup, anchors = {}, {}
    for point in navigation.iter():
        if api.tag(point) != 'navPoint':
            continue
        content, label = api.first(point, 'content'), title(api.first(point, 'navLabel'))
        target, fragment = address(ncx, content.get('src')) if content is not None else (None, '')
        if target in chapters and fragment and label:
            lookup.setdefault((fragment, label), set()).add(target)
    if not lookup:
        return

    for path in sorted(chapters):
        document, notices = chapter(path)
        if document is None:
            continue
        fixed = 0
        for link in document.iter():
            if api.tag(link) != 'a':
                continue
            missing, fragment = address(path, link.get('href'))
            if not missing or missing in archive.names or not fragment:
                continue
            candidates = lookup.get((fragment, title(link)), ())
            if len(candidates) != 1:
                continue
            target, = candidates
            key = (target, fragment)
            if key not in anchors:
                target_document = document if target == path else chapter(target)[0]
                body = api.first(target_document, 'body') if target_document is not None else None
                anchors[key] = body is not None and sum(node.get('id') == fragment or
                    (api.tag(node) == 'a' and node.get('name') == fragment) for node in body.iter()) == 1
            if anchors[key]:
                relative = quote(posixpath.relpath(target, posixpath.dirname(path) or '.')) if target != path else ''
                link.set('href', relative + '#' + quote(fragment, safe=''))
                fixed += 1
        if fixed:
            parts[path] = api.serialized(document)
            warnings.update(notices)
            warnings.add(f'Восстановлены переходы EPUB в «{posixpath.basename(path)[:100]}»: {fixed}. '
                         'Цели подтверждены по исходному оглавлению.')


def recover_metadata(api, source, check, *, allow_large_jpeg=False, permitted=False):
    """Read complete ZIP members where only the XML closing tags were cut off."""
    archive = api.EpubArchive(source, allow_large_jpeg=allow_large_jpeg)
    parts, warnings, navigations = {}, set(), []

    def read(name, root, allowed_open, optional=False):
        if check is not None:
            check()
        try:
            data = archive.read(name)
        except (api.ConversionError, api.zipfile.BadZipFile):
            if optional:
                return None
            raise
        try:
            return api.xml(data, namespace_warnings=set())
        except api.ConversionError as error:
            try:
                document, repaired = restore_metadata(api, data, allowed_open, error)
            except api.ConversionError:
                if optional:
                    return None
                raise
        if api.tag(document) != root:
            raise api.ConversionError('Неполные метаданные EPUB не удалось проверить.')
        parts[name] = repaired
        return document

    try:
        container = read(CONTAINER, 'container', {'container', 'rootfiles'})
        rootfiles = [n for n in container.iter() if api.tag(n) == 'rootfile']
        for entry in rootfiles:
            package_name, _ = archive.resolve('container.xml', entry.get('full-path', ''))
            if not package_name:
                continue
            package = read(package_name, 'package', {'package', 'guide'})
            manifest, spine = api.first(package, 'manifest'), api.first(package, 'spine')
            if package_name in parts and (manifest is None or spine is None or not len(spine) or
                                          api.first(package, 'metadata') is None):
                raise api.ConversionError('Не удалось подтвердить исходный порядок страниц EPUB.')
            if manifest is None or spine is None:
                continue
            ncx = None
            chapters = set()
            for item in manifest:
                if item.get('media-type') in api.EPUB_XHTML_TYPES:
                    path, fragment = archive.resolve(package_name, item.get('href', ''))
                    if path in archive.names and not fragment:
                        chapters.add(path)
                if (item.get('media-type') == 'application/x-dtbncx+xml' and item.get('id') == spine.get('toc')):
                    ncx, _ = archive.resolve(package_name, item.get('href', ''))
            if ncx in archive.names:
                navigation = read(ncx, 'ncx', {'ncx', 'navMap', 'navPoint'}, optional=True)
                if navigation is not None:
                    navigations.append((ncx, navigation, chapters))
        if not parts:
            return parts, warnings
        if not rootfiles:
            raise api.ConversionError('В повреждённом EPUB отсутствует адрес основного пакета.')
        if not permitted:
            raise api.ConversionError('Архив EPUB повреждён. Для сохранения доступной части нужно подтверждение.')
        labels = ', '.join(posixpath.basename(name) for name in parts)
        warnings.add(f'Архив EPUB повреждён. Восстановлены оборванные закрывающие теги: {labels}. '
                     'Использованы сохранившиеся порядок чтения и оглавление.')
        for ncx, navigation, chapters in navigations:
            restore_navigation_links(api, archive, ncx, navigation, chapters, parts, warnings, check)
        return parts, warnings
    finally:
        archive.close()


def safe_name(name):
    return bool(name) and not any(c in name for c in '\\:\0') and all(
        part not in {'', '.', '..'} for part in name.rstrip('/').split('/'))


def recoverable_entries(api, source, check):
    total, seen = 0, set()
    with source.open('rb') as stream:
        while True:
            if check is not None:
                check()
            header = stream.read(30)
            if len(header) != 30 or header[:4] != b'PK\x03\x04':
                return
            _, flags, method, _, _, crc, packed, size, name_len, extra_len = struct.unpack('<5H3I2H', header[4:])
            if flags & ~0x806 or method not in (ZIP_STORED, ZIP_DEFLATED):
                raise api.ConversionError('Повреждённый EPUB использует неподдерживаемые записи ZIP.')
            if packed > api.MAX_FILE or size > api.MAX_FILE or total + size > api.MAX_TOTAL or len(seen) >= api.MAX_ENTRIES:
                raise api.ConversionError('Доступные части повреждённого EPUB слишком велики.')
            raw_name = stream.read(name_len)
            if len(raw_name) != name_len or len(stream.read(extra_len)) != extra_len:
                return
            name = raw_name.decode('utf-8' if flags & 0x800 else 'cp437')
            if not safe_name(name) or name in seen:
                raise api.ConversionError('В повреждённом EPUB есть повторяющиеся или некорректные пути.')
            data = stream.read(packed)
            if len(data) != packed:
                if method == ZIP_DEFLATED and posixpath.splitext(name)[1].lower() in ('.html', '.htm', '.xhtml', '.xml'):
                    try:
                        decoder = zlib.decompressobj(-15)
                        prefix = decoder.decompress(data, size + 1)
                        if prefix and len(prefix) <= size and not decoder.unused_data and not decoder.unconsumed_tail:
                            yield name, prefix, False
                    except zlib.error:
                        pass
                return
            if method == ZIP_DEFLATED:
                try:
                    decoder = zlib.decompressobj(-15)
                    data = decoder.decompress(data, size + 1)
                    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                        continue
                except zlib.error:
                    continue
            if len(data) != size or zlib.crc32(data) != crc:
                continue
            total += size
            seen.add(name)
            yield name, data, True


def rebuild_scanned_package(api, archive, package_name, warnings, metadata):
    """The ABBYY scan writer numbers pages independently of the missing OPF."""
    directory = posixpath.dirname(package_name)
    prefix = directory + '/' if directory else ''
    candidates = [(name, name[len(prefix):]) for name in archive.namelist()
                  if name.startswith(prefix) and name.lower().endswith(('.html', '.htm', '.xhtml'))]
    pages, referenced_images = {}, set()
    for name, relative in candidates:
        match = re.fullmatch(r'leaf(\d{4})\.html', relative)
        if not match or archive.getinfo(name).file_size > 65536:
            pages.clear()
            break
        chapter = api.xhtml(archive.read(name))
        number = int(match[1])
        has_generator = any(api.tag(n) == 'meta' and n.get('name') == 'generator'
                            and n.get('content', '').casefold().startswith('abbyy to epub tool')
                            for n in chapter.iter())
        if not has_generator:
            pages.clear()
            break
        pages[number] = name
        for node in chapter.iter():
            if api.tag(node) == 'img':
                url = urlsplit(node.get('src', ''))
                if not url.scheme and not url.netloc:
                    referenced_images.add(posixpath.normpath(posixpath.join(directory, unquote(url.path))))
    if not pages or max(pages) - min(pages) >= 5000:
        raise api.ConversionError('В повреждённом EPUB отсутствует порядок чтения. Его нельзя надёжно восстановить.')

    title = metadata.get('title') or metadata['source_name']
    package = api.element(api.OP, 'package', version='3.0', **{'unique-identifier': 'recovered-id'})
    info = api.element(api.OP, 'metadata')
    package.append(info)
    info.append(api.element(api.DC, 'identifier', 'urn:homelibre:recovered:' + metadata['source_digest'], id='recovered-id'))
    info.append(api.element(api.DC, 'title', title))
    info.append(api.element(api.DC, 'language', metadata.get('language') or 'und'))
    info.append(api.element(api.OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                            property='dcterms:modified'))
    if metadata.get('author'):
        info.append(api.element(api.DC, 'creator', metadata['author']))
    manifest, spine = api.element(api.OP, 'manifest'), api.element(api.OP, 'spine')
    package.extend((manifest, spine))

    def add(name, mime, **attributes):
        identity = f'recovered-{len(manifest)}'
        manifest.append(api.element(api.OP, 'item', id=identity,
                                    href=quote(posixpath.relpath(name, directory or '.')),
                                    **{'media-type': mime}, **attributes))
        return identity

    extra_images = []
    for name in sorted(archive.namelist()):
        if name.startswith(prefix) and (mime := MEDIA.get(posixpath.splitext(name)[1].lower())):
            add(name, mime)
            if mime.startswith('image/') and name not in referenced_images:
                extra_images.append(name)

    missing = []
    for number in range(min(pages), max(pages) + 1):
        if number in pages:
            name = pages[number]
        else:
            missing.append(number)
            basename = f'leaf{number:04}.html'
            name = prefix + basename
            page = api.element(api.XH, 'html')
            head, body = api.element(api.XH, 'head'), api.element(api.XH, 'body')
            head.append(api.element(api.XH, 'title', 'Утраченная страница'))
            body.append(api.element(api.XH, 'p', f'[Исходная страница {basename} отсутствует.]'))
            page.extend((head, body))
            archive.writestr(name, api.serialized(page))
        identity = add(name, 'application/xhtml+xml')
        spine.append(api.element(api.OP, 'itemref', idref=identity))

    if extra_images:
        gallery = api.element(api.XH, 'html')
        head, body = api.element(api.XH, 'head'), api.element(api.XH, 'body')
        caption = 'Иллюстрации без привязки к странице'
        head.append(api.element(api.XH, 'title', caption))
        body.append(api.element(api.XH, 'p', caption))
        for image in extra_images:
            body.append(api.element(api.XH, 'img', alt=posixpath.basename(image),
                                    src=quote(posixpath.relpath(image, directory or '.'))))
        gallery.extend((head, body))
        name = prefix + 'homelibre-recovered-images.xhtml'
        archive.writestr(name, api.serialized(gallery))
        spine.append(api.element(api.OP, 'itemref', idref=add(name, 'application/xhtml+xml')))
        warnings.add(f'Архив EPUB повреждён. Иллюстрации без привязки к странице вынесены в конец книги: {len(extra_images)}.')

    nav = api.element(api.XH, 'html')
    head, body = api.element(api.XH, 'head'), api.element(api.XH, 'body')
    head.append(api.element(api.XH, 'title', 'Оглавление'))
    section = api.element(api.XH, 'nav', **{'{' + api.EP + '}type': 'toc'})
    listing = api.element(api.XH, 'ol')
    entry = api.element(api.XH, 'li')
    entry.append(api.element(api.XH, 'a', title, href=quote(posixpath.basename(pages[min(pages)]))))
    listing.append(entry)
    section.append(listing)
    body.append(section)
    nav.extend((head, body))
    name = prefix + 'homelibre-recovered-nav.xhtml'
    add(name, 'application/xhtml+xml', properties='nav')
    archive.writestr(name, api.serialized(nav))
    archive.writestr(package_name, api.serialized(package))
    warnings.add('Архив EPUB повреждён. Исходные метаданные и оглавление утрачены. Страницы расположены по номерам файлов.')
    if missing:
        examples = ', '.join(f'leaf{n:04}.html' for n in missing[:20])
        rest = f' и ещё {len(missing) - 20}' if len(missing) > 20 else ''
        warnings.add(f'Архив EPUB повреждён. Отсутствуют файлы страниц: {examples}{rest}. На их месте стоят отметки.')


def recover_chapter_prefix(api, name, data, warnings):
    """Keep the decodable text and HTML from the last, incomplete ZIP record."""
    try:
        encoding = api.epub_xhtml_encoding(data)
        prefix = getincrementaldecoder(encoding)().decode(data, final=False).encode(encoding)
        try:
            document = api.xhtml(prefix)
        except api.ConversionError:
            document = api.html5_epub_document(prefix)
    except (LookupError, UnicodeError, api.ConversionError):
        return None
    body = api.first(document, 'body')
    if api.tag(document) != 'html' or body is None or not (
            api.plain(body) or any(api.tag(node) in {'img', 'svg'} for node in body.iter())):
        return None
    body.append(api.element(api.XH, 'p', f'[Конец раздела EPUB «{name}» отсутствует в архиве.]'))
    warnings.add(f'Архив EPUB повреждён. Сохранено доступное начало раздела «{name}». '
                 'Полную контрольную сумму раздела проверить нельзя.')
    return api.serialized(document)


def recover_declared_package(api, archive, package_name, last_entry, warnings, check):
    """Keep the surviving manifest and mark gaps in the original spine."""
    data = archive.read(package_name)
    package = api.xml(data)
    manifest, spine = api.first(package, 'manifest'), api.first(package, 'spine')
    if manifest is None or spine is None:
        raise api.ConversionError('В повреждённом EPUB не сохранился порядок чтения.')
    paths = {}
    for item in api.children(manifest, 'item'):
        if check is not None:
            check()
        path, fragment = archive.resolve(package_name, item.get('href', ''))
        if path is not None and (not safe_name(path) or any(ord(character) < 32 for character in path)):
            raise api.ConversionError('В повреждённом EPUB есть некорректный адрес ресурса.')
        if path is not None and not fragment:
            paths[item.get('id')] = (path, item)

    linear = dict.fromkeys(entry.get('idref') for entry in api.children(spine, 'itemref')
                           if entry.get('linear', '').lower() != 'no')
    chapters = dict.fromkeys(paths[identity][0] for identity in linear if identity in paths and
                             paths[identity][1].get('media-type') in api.EPUB_XHTML_TYPES and
                             'nav' not in paths[identity][1].get('properties', '').split())
    additions = {}
    if last_entry is not None and last_entry[0] in chapters:
        name, prefix = last_entry
        if recovered := recover_chapter_prefix(api, name, prefix, warnings):
            additions[name] = recovered

    missing = [name for name in chapters if name not in archive.names and name not in additions]
    if not additions and not any(name in archive.names for name in chapters):
        raise api.ConversionError('В повреждённом EPUB не сохранилось ни одной главы для чтения.')
    if len(archive.names) + len(additions) + len(missing) > api.MAX_ENTRIES:
        raise api.ConversionError('В EPUB слишком много разделов для восстановления.')
    metadata = api.first(package, 'metadata')
    cover_ids = ({meta.get('content') for meta in api.children(metadata, 'meta') if meta.get('name') == 'cover'}
                 if metadata is not None else set())
    cover = next((path for identity, (path, item) in paths.items() if path in archive.names and
                  (identity in cover_ids or 'cover-image' in item.get('properties', '').split()) and
                  item.get('media-type', '').startswith('image/') and
                  item.get('media-type') not in api.EPUB_MISLABELED_XHTML_TYPES), None)
    cover_pages = set()
    guide = api.first(package, 'guide')
    if cover and guide is not None:
        for item in api.children(guide, 'reference'):
            if item.get('type') == 'cover':
                try:
                    path, fragment = archive.resolve(package_name, item.get('href', ''))
                except (api.ConversionError, ValueError):
                    continue
                if path in missing and not fragment:
                    cover_pages.add(path)
    for name in missing:
        document = api.element(api.XH, 'html')
        head, body = api.element(api.XH, 'head'), api.element(api.XH, 'body')
        head.append(api.element(api.XH, 'title', 'Раздел EPUB отсутствует'))
        if name in cover_pages:
            body.append(api.element(api.XH, 'img', alt='Сохранившаяся обложка EPUB',
                                    src=quote(posixpath.relpath(cover, posixpath.dirname(name) or '.'))))
        body.append(api.element(api.XH, 'p', f'[В архиве EPUB отсутствует раздел «{name}».]'))
        document.extend((head, body))
        additions[name] = api.serialized(document)
    if missing:
        warnings.add(f'В архиве EPUB отсутствуют файлы из порядка чтения ({len(missing)}). '
                     'В книге отмечены следующие пропуски: ' + ', '.join(missing) + '.')

    removed = {identity: path for identity, (path, _) in paths.items()
               if path not in archive.names and path not in additions}
    if not removed:
        return additions, {}
    for identity in removed:
        manifest.remove(paths[identity][1])
    for entry in api.children(spine, 'itemref'):
        if entry.get('idref') in removed:
            spine.remove(entry)
    if spine.get('toc') in removed:
        del spine.attrib['toc']
    for item in api.children(manifest, 'item'):
        for name in ('fallback', 'fallback-style', 'media-overlay'):
            if item.get(name) in removed:
                del item.attrib[name]
    warnings.add('Архив EPUB повреждён. Отсутствуют ресурсы: ' + ', '.join(dict.fromkeys(removed.values())) + '.')
    return additions, {package_name: api.serialized(package)}


def recover(api, source, output, warnings, metadata, check=None):
    verified = output.with_name('verified.epub')
    names, last_entry = set(), None
    with ZipFile(verified, 'x', compression=ZIP_DEFLATED) as archive:
        for name, data, complete in recoverable_entries(api, source, check):
            if not complete:
                last_entry = (name, data)
                break
            if not names and (name != 'mimetype' or data != MIME):
                raise api.ConversionError('Не удалось подтвердить формат повреждённого EPUB.')
            archive.writestr(name, data, compress_type=ZIP_STORED if name == 'mimetype' else ZIP_DEFLATED)
            names.add(name)
    if CONTAINER not in names:
        raise api.ConversionError('В повреждённом EPUB не сохранилось описание контейнера.')
    archive = api.EpubArchive(verified)
    try:
        container = api.xml(archive.read(CONTAINER))
        packages = [unquote(node.get('full-path', '')) for node in container.iter() if api.tag(node) == 'rootfile']
        if len(packages) != 1 or not safe_name(packages[0]) or not packages[0].endswith('.opf'):
            raise api.ConversionError('В повреждённом EPUB не найден основной пакет книги.')
        package = packages[0]
        additions, replacements = (recover_declared_package(api, archive, package, last_entry, warnings, check)
                                   if package in names else ({}, {}))
    finally:
        archive.close()
    if package not in names:
        with ZipFile(verified, 'a', compression=ZIP_DEFLATED) as archive:
            rebuild_scanned_package(api, archive, package, warnings, metadata)
    if additions or replacements:
        api.copy_epub_with_repaired_markup(verified, output, {}, check, additions=additions, replacements=replacements)
    else:
        verified.rename(output)
    warnings.add('Архив EPUB повреждён. Сохранены записи с подтверждённой контрольной суммой. Конец книги мог не сохраниться.')

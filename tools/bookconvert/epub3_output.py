"""Upgrade the EPUB package and navigation while retaining its reading resources."""

from datetime import datetime, timezone
import posixpath
import re
from urllib.parse import quote


XML_NS = 'http://www.w3.org/XML/1998/namespace'
NCX_NS = 'http://www.daisy.org/z3986/2005/ncx/'
SVG_NS = 'http://www.w3.org/2000/svg'
MATHML_NS = 'http://www.w3.org/1998/Math/MathML'
LEGACY_FONT_TYPES = {
    'application/vnd.ms-opentype', 'application/x-font-otf', 'application/x-font-ttf',
    'application/x-font-truetype', 'application/font-sfnt',
}


def navigation(api, archive, ncx_path, nav_path, title, language, readable_paths):
    ncx = api.xml(archive.read(ncx_path))
    if ncx.tag != '{' + NCX_NS + '}ncx' or any(
            '{' + XML_NS + '}base' in node.attrib for node in ncx.iter()):
        raise api.ConversionError('Не удалось перенести оглавление NCX в EPUB 3.')
    document = api.element(api.XH, 'html', lang=language, **{'{' + XML_NS + '}lang': language})
    head = api.element(api.XH, 'head')
    head.append(api.element(api.XH, 'title', title))
    body = api.element(api.XH, 'body')
    document.extend((head, body))

    def items(parent, source, element_name):
        for entry in api.children(source, element_name):
            li = api.element(api.XH, 'li')
            label = api.plain(api.first(entry, 'navLabel'))
            target = api.first(entry, 'content')
            href = '' if target is None else target.get('src', '')
            if not label or not href:
                raise api.ConversionError('В оглавлении NCX отсутствует название или ссылка.')
            path, fragment = archive.resolve(ncx_path, href)
            if path not in readable_paths:
                raise api.ConversionError('Не найдена глава из оглавления EPUB: ' + href)
            relative = quote(posixpath.relpath(path, posixpath.dirname(nav_path) or '.'))
            if fragment:
                relative += '#' + quote(fragment, safe='')
            li.append(api.element(api.XH, 'a', label, href=relative))
            parent.append(li)
            if element_name == 'navPoint' and api.first(entry, 'navPoint') is not None:
                nested = api.element(api.XH, 'ol')
                li.append(nested)
                items(nested, entry, 'navPoint')

    for name, item_name, kind, caption in (
            ('navMap', 'navPoint', 'toc', 'Contents'),
            ('pageList', 'pageTarget', 'page-list', 'Pages')):
        section = api.first(ncx, name)
        if section is None or api.first(section, item_name) is None:
            if kind == 'toc':
                raise api.ConversionError('В EPUB 2 отсутствует оглавление NCX.')
            continue
        nav = api.element(api.XH, 'nav', **{'{' + api.EP + '}type': kind})
        nav.append(api.element(api.XH, 'h1', caption))
        listing = api.element(api.XH, 'ol')
        nav.append(listing)
        body.append(nav)
        items(listing, section, item_name)
    return api.serialized(document)


def upgrade_metadata(api, package, metadata, used_ids, warnings):
    title, language = (api.plain(metadata.find('{' + api.DC + '}' + key))
                       for key in ('title', 'language'))
    identifier = package.get('unique-identifier')
    if not title or not language or not identifier or not any(
            entry.get('id') == identifier and api.plain(entry)
            for entry in metadata.findall('{' + api.DC + '}identifier')):
        raise api.ConversionError('Для EPUB 3 нужны название, язык и идентификатор книги.')
    refinements = []
    opf = '{' + api.OP + '}'
    for entry in list(metadata):
        for name in tuple(entry.attrib):
            if not name.startswith(opf):
                continue
            value = entry.attrib.pop(name)
            property_name = name[len(opf):]
            if property_name not in {'role', 'file-as', 'scheme'} or not value:
                warnings.add('Часть служебных полей EPUB 2 не имеет прямого аналога в EPUB 3.')
                continue
            identity = entry.get('id')
            if not identity:
                identity = free_name('hl-metadata', used_ids)
                used_ids.add(identity)
                entry.set('id', identity)
            attrs = {'property': 'identifier-type' if property_name == 'scheme' else property_name,
                     'refines': '#' + identity}
            if property_name == 'role' and re.fullmatch('[a-z]{3}', value):
                attrs['scheme'] = 'marc:relators'
            refinements.append(api.element(api.OP, 'meta', value, **attrs))
    metadata.extend(refinements)
    metadata.append(api.element(api.OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                                property='dcterms:modified'))
    return title, language


def free_name(base, used, suffix=''):
    value = base + suffix
    number = 1
    while value in used:
        value = f'{base}-{number}{suffix}'
        number += 1
    return value


def chapter_properties(api, archive, path, doc):
    if doc.tag != '{' + api.XH + '}html':
        raise api.ConversionError('Глава EPUB не является XHTML: ' + path)
    properties = set()
    for node in doc.iter():
        if node.tag.startswith('{' + SVG_NS + '}'):
            properties.add('svg')
        elif node.tag.startswith('{' + MATHML_NS + '}'):
            properties.add('mathml')
        if api.tag(node) == 'script' or any(name.startswith('on') for name in node.attrib):
            properties.add('scripted')
        for attribute in ('src', 'poster', 'data', '{' + api.XL + '}href'):
            value = node.get(attribute)
            if value and archive.resolve(path, value)[0] is None and not value.startswith('data:'):
                properties.add('remote-resources')
    return properties


def upgrade_package(api, archive, package_path, package, warnings, check):
    metadata, manifest, spine = (api.first(package, key) for key in ('metadata', 'manifest', 'spine'))
    if metadata is None or manifest is None or spine is None:
        raise api.ConversionError('Неполное описание EPUB 2.')
    if package.tag != '{' + api.OP + '}package' or any(
            '{' + XML_NS + '}base' in node.attrib for node in package.iter()):
        raise api.ConversionError('Структура OPF не позволяет безопасно изменить версию EPUB.')
    used_ids = {entry.get('id') for entry in package.iter() if entry.get('id')}
    title, language = upgrade_metadata(api, package, metadata, used_ids, warnings)
    ncx, readable_paths, replacements = None, set(), {}
    cover_ids = {item.get('content') for item in api.children(metadata, 'meta') if item.get('name') == 'cover'}
    if len(cover_ids) > 1:
        raise api.ConversionError('В EPUB 2 указано несколько разных обложек.')
    for item in api.children(manifest, 'item'):
        if check is not None:
            check()
        path, fragment = archive.resolve(package_path, item.get('href', ''))
        media = item.get('media-type')
        if not item.get('href') or fragment or path not in archive.names:
            raise api.ConversionError('В EPUB отсутствует ресурс: ' + item.get('href', ''))
        properties = set(item.get('properties', '').split())
        if item.get('id') in cover_ids and media and media.startswith('image/'):
            properties.add('cover-image')
        if item.get('id') == spine.get('toc') and media == 'application/x-dtbncx+xml':
            ncx = path
        if media == 'application/xhtml+xml':
            readable_paths.add(path)
            data = archive.read(path)
            chapter = api.xhtml(data)
            properties.update(chapter_properties(api, archive, path, chapter))
            if re.search(br'<!DOCTYPE\s+html\b', data.replace(b'\0', b''), re.I):
                # EPUB 2 XHTML may depend on named entities from an external DTD.
                # The existing parser expands these locally without network access.
                replacements[path] = api.serialized(chapter)
        elif media == 'image/svg+xml':
            readable_paths.add(path)
        elif media in LEGACY_FONT_TYPES:
            signature = archive.read(path)[:4]
            if signature in {b'OTTO', b'ttcf', b'\x00\x01\x00\x00', b'true'}:
                item.set('media-type', {b'OTTO': 'font/otf', b'ttcf': 'font/collection'}.get(signature, 'font/ttf'))
        if properties:
            item.set('properties', ' '.join(sorted(properties)))

    if ncx is None:
        raise api.ConversionError('В EPUB 2 не найден файл оглавления NCX.')
    directory = posixpath.dirname(package_path)
    used_names = {posixpath.basename(name).casefold() for name in archive.names
                  if posixpath.dirname(name).casefold() == directory.casefold()}
    nav_name = free_name('homelibre-nav', used_names, '.xhtml')
    nav_path = posixpath.join(directory, nav_name)
    nav_id = free_name('hl-nav', used_ids)
    manifest.append(api.element(api.OP, 'item', id=nav_id, href=quote(nav_name),
                                properties='nav', **{'media-type': 'application/xhtml+xml'}))
    package.set('version', '3.0')
    replacements[package_path] = api.serialized(package)
    replacements[nav_path] = navigation(api, archive, ncx, nav_path, title, language, readable_paths)
    return replacements


def convert(api, source, output, warnings, check):
    def transform(archive, path, package, notes, cancel):
        return upgrade_package(api, archive, path, package, notes, cancel)

    api.rewrite_epub_version(source, output, '3', transform, warnings, check)

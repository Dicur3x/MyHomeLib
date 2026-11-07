"""Write an EPUB 2 package from compatible reflowable EPUB content."""

import posixpath
from urllib.parse import quote


XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'
XML_BASE = '{http://www.w3.org/XML/1998/namespace}base'
NCX = 'http://www.daisy.org/z3986/2005/ncx/'
SVG = '{http://www.w3.org/2000/svg}'
XHTML = 'application/xhtml+xml'
NCX_MEDIA = 'application/x-dtbncx+xml'
BOOK_MEDIA = {XHTML, NCX_MEDIA, 'text/css', 'image/jpeg', 'image/png', 'image/gif',
              'image/svg+xml', 'application/vnd.ms-opentype'}
FONT_MEDIA = {'font/ttf', 'font/otf', 'application/font-sfnt', 'application/x-font-ttf',
              'application/x-font-otf'}
BLOCK_WRAPPERS = {'article', 'aside', 'figcaption', 'figure', 'footer', 'header', 'main', 'nav', 'section'}
INLINE_WRAPPERS = {'mark', 'time'}
XHTML_ELEMENTS = set(('a abbr acronym address area b base bdo big blockquote body br caption cite code col colgroup '
                      'dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 head hr html i img ins kbd li link map meta '
                      'ol p pre q samp small span strong style sub sup table tbody td tfoot th thead title tr tt ul var').split())
INLINE_DECORATIONS = {'s': 'line-through', 'strike': 'line-through', 'u': 'underline'}
HTML_COMPATIBLE = XHTML_ELEMENTS | BLOCK_WRAPPERS | INLINE_WRAPPERS | INLINE_DECORATIONS.keys()
UNSUPPORTED = {'audio', 'button', 'canvas', 'details', 'embed', 'form', 'iframe', 'input', 'meter',
               'object', 'picture', 'progress', 'ruby', 'script', 'select', 'summary', 'template', 'textarea', 'video'}


def relative_href(source, target, fragment=''):
    href = quote(posixpath.relpath(target, posixpath.dirname(source) or '.'))
    return href + ('#' + quote(fragment, safe='') if fragment else '')


def append_style(node, value):
    style = node.get('style', '').rstrip('; ')
    node.set('style', (style + ';' if style else '') + value)


def epub2_chapter(api, archive, path, document, resources, warnings):
    changed = False
    for node in document.iter():
        name = api.tag(node)
        is_html = node.tag.startswith('{' + api.XH + '}')
        if (not is_html and not node.tag.startswith(SVG)) or name in UNSUPPORTED or XML_BASE in node.attrib:
            raise api.ConversionError('Этот элемент нельзя перенести в EPUB 2: ' + name)
        if is_html and name not in HTML_COMPATIBLE:
            raise api.ConversionError('Этот элемент нельзя перенести в EPUB 2: ' + name)
        if any(attr.startswith('on') for attr in node.attrib) or 'srcset' in node.attrib:
            raise api.ConversionError('Интерактивное или адаптивное содержимое нельзя перенести в EPUB 2.')
        if node.tag.startswith(SVG) and 'href' in node.attrib:
            node.set('{' + api.XL + '}href', node.attrib.pop('href'))
            changed = True
        for attr in ('src', '{' + api.XL + '}href'):
            reference = node.get(attr)
            if reference and archive.resolve(path, reference)[0] not in resources:
                raise api.ConversionError('Для EPUB 2 нужен локальный ресурс: ' + reference[:150])
        if is_html and (name in BLOCK_WRAPPERS or name in INLINE_WRAPPERS or name in INLINE_DECORATIONS):
            node.tag = '{' + api.XH + '}' + ('div' if name in BLOCK_WRAPPERS else 'span')
            if name == 'time':
                node.attrib.pop('datetime', None)
            if name in INLINE_DECORATIONS:
                append_style(node, 'text-decoration:' + INLINE_DECORATIONS[name])
            warnings.add('В EPUB 2 упрощены структурные элементы. Часть оформления и семантики может отличаться.')
            changed = True
        if is_html and 'lang' in node.attrib:
            language = node.attrib.pop('lang')
            if XML_LANG not in node.attrib:
                node.set(XML_LANG, language)
            changed = True
        if 'hidden' in node.attrib:
            node.attrib.pop('hidden')
            append_style(node, 'display:none!important')
            changed = True
        for attr in tuple(node.attrib):
            if attr.startswith(('{' + api.EP + '}', 'aria-', 'data-')) or attr == 'role':
                node.attrib.pop(attr)
                warnings.add('Ссылки и текст сохранены. Служебные метки EPUB 3 в EPUB 2 не переносятся.')
                changed = True
        if is_html and name in ('style', 'link') and not node.get('type') and (
                name == 'style' or 'stylesheet' in node.get('rel', '').split()):
            node.set('type', 'text/css')
            changed = True
        if is_html and name == 'meta' and 'charset' in node.attrib:
            node.set('http-equiv', 'Content-Type')
            node.set('content', 'application/xhtml+xml; charset=' + node.attrib.pop('charset'))
            changed = True
        if is_html and name == 'img' and 'alt' not in node.attrib:
            node.set('alt', '')
            changed = True
    return changed


def ncx_navigation(api, archive, nav_path, nav, ncx_path, title, identifier, chapters):
    epub_type = '{' + api.EP + '}type'
    sections = {kind: [node for node in nav.iter('{' + api.XH + '}nav')
                       if kind in node.get(epub_type, '').split()]
                for kind in ('toc', 'page-list')}
    if len(sections['toc']) != 1 or len(sections['page-list']) > 1:
        raise api.ConversionError('Не удалось определить оглавление или список страниц EPUB 3.')
    depth = 0
    page_values = []
    count = 0

    def children(parent, listing, page_list=False, level=1):
        nonlocal depth, count
        for item in api.children(listing, 'li'):
            label = next((child for child in item if api.tag(child) in ('a', 'span')), None)
            if label is None:
                raise api.ConversionError('В оглавлении EPUB отсутствует заголовок.')
            text = api.plain(label) or label.get('title') or ' '.join(
                img.get('alt', '') for img in label.iter('{' + api.XH + '}img')).strip()
            if not text:
                raise api.ConversionError('Не удалось прочитать заголовок оглавления EPUB.')
            nested = api.first(item, 'ol')
            href = label.get('href')
            if href is None and nested is not None:
                href = next((child.get('href') for child in nested.iter('{' + api.XH + '}a') if child.get('href')), None)
            if not href:
                raise api.ConversionError('В оглавлении EPUB отсутствует ссылка на главу.')
            path, fragment = archive.resolve(nav_path, href)
            if path not in chapters or (fragment and fragment not in chapters[path]):
                raise api.ConversionError('Не найдена цель ссылки в оглавлении EPUB: ' + href)
            count += 1
            attrs = {'id': 'entry-' + str(count)}
            if page_list:
                number = int(text) if text.isascii() and text.isdecimal() and len(text) <= 9 else 0
                attrs.update(type='normal' if number else 'special')
                if number:
                    attrs['value'] = str(number)
                    page_values.append(number)
            else:
                depth = max(depth, level)
            entry = api.element(NCX, 'pageTarget' if page_list else 'navPoint', **attrs)
            name = api.element(NCX, 'navLabel')
            name.append(api.element(NCX, 'text', text))
            entry.extend((name, api.element(NCX, 'content', src=relative_href(ncx_path, path, fragment))))
            parent.append(entry)
            if nested is not None and not page_list:
                children(entry, nested, level=level+1)

    navigation = api.element(NCX, 'ncx', version='2005-1')
    head = api.element(NCX, 'head')
    doc_title = api.element(NCX, 'docTitle')
    doc_title.append(api.element(NCX, 'text', title))
    toc = api.element(NCX, 'navMap')
    navigation.extend((head, doc_title, toc))
    listing = api.first(sections['toc'][0], 'ol')
    if listing is not None:
        children(toc, listing)
    if not len(toc):
        raise api.ConversionError('В EPUB отсутствуют пункты оглавления.')
    page_count = 0
    if sections['page-list']:
        pages = api.element(NCX, 'pageList')
        listing = api.first(sections['page-list'][0], 'ol')
        if listing is not None:
            children(pages, listing, page_list=True)
        if len(pages):
            page_count = len(pages)
            navigation.append(pages)
    for name, value in [('uid', identifier), ('depth', depth), ('totalPageCount', page_count),
                        ('maxPageNumber', max(page_values, default=0))]:
        head.append(api.element(NCX, 'meta', name='dtb:' + name, content=str(value)))
    return api.serialized(navigation)


def legacy_metadata(api, metadata, cover_id, warnings):
    dc, opf = '{' + api.DC + '}', '{' + api.OP + '}'
    by_id = {node.get('id'): node for node in metadata if node.tag.startswith(dc) and node.get('id')}
    fields = {'role': 'role', 'file-as': 'file-as', 'identifier-type': 'scheme'}
    for node in list(metadata):
        if node.tag.startswith(dc):
            continue
        if node.tag == opf + 'meta' and node.get('name') and node.get('content') is not None:
            if cover_id and node.get('name') == 'cover':
                metadata.remove(node)
            continue
        property_name = node.get('property', '')
        if property_name == 'rendition:layout' and api.plain(node) != 'reflowable':
            raise api.ConversionError('Фиксированную вёрстку EPUB 3 нельзя перенести в EPUB 2.')
        target = by_id.get(node.get('refines', '')[1:]) if node.get('refines', '').startswith('#') else None
        field = fields.get(property_name)
        if (field and target is not None and api.plain(node) and
                (field == 'scheme' and api.tag(target) == 'identifier' or
                 field != 'scheme' and api.tag(target) in ('creator', 'contributor'))):
            target.set(opf + field, api.plain(node))
        elif property_name != 'dcterms:modified':
            warnings.add('Часть дополнительных сведений EPUB 3 не имеет аналога в EPUB 2.')
        metadata.remove(node)
    if cover_id:
        metadata.append(api.element(api.OP, 'meta', name='cover', content=cover_id))


def downgrade_package(api, archive, package_path, package, warnings, check):
    metadata, manifest, spine = (api.first(package, key) for key in ('metadata', 'manifest', 'spine'))
    if (package.tag != '{' + api.OP + '}package' or metadata is None or manifest is None or spine is None
            or any(XML_BASE in node.attrib for node in package.iter())):
        raise api.ConversionError('Структура OPF не позволяет безопасно сохранить EPUB 2.')
    by_id, by_path = {}, {}
    nav_path, cover_id = None, None
    for item in manifest:
        identity, href, media = (item.get(key) for key in ('id', 'href', 'media-type'))
        path, fragment = archive.resolve(package_path, href or '')
        properties = set(item.attrib.pop('properties', '').split())
        if not identity or identity in by_id or not href or fragment or path not in archive.names or path in by_path:
            raise api.ConversionError('В EPUB отсутствует или повторяется ресурс: ' + (href or ''))
        if properties & {'scripted', 'mathml', 'remote-resources'} or item.get('media-overlay'):
            raise api.ConversionError('Сценарии, формулы MathML, аудиосинхронизацию или внешние ресурсы нельзя перенести в EPUB 2.')
        if media in FONT_MEDIA:
            item.set('media-type', 'application/vnd.ms-opentype')
        elif media not in BOOK_MEDIA:
            raise api.ConversionError('Этот ресурс не поддерживается EPUB 2: ' + path)
        if 'nav' in properties:
            if nav_path is not None or media != XHTML:
                raise api.ConversionError('Не удалось определить оглавление EPUB 3.')
            nav_path = path
        if 'cover-image' in properties:
            if cover_id is not None:
                raise api.ConversionError('В EPUB 3 указано несколько обложек.')
            cover_id = identity
        by_id[identity], by_path[path] = item, item
    for itemref in spine:
        item = by_id.get(itemref.get('idref'))
        if item is None or item.get('media-type') != XHTML:
            raise api.ConversionError('В EPUB 2 для каждой страницы нужен документ XHTML.')
        properties = itemref.attrib.pop('properties', '')
        if 'layout-pre-paginated' in properties:
            raise api.ConversionError('Фиксированную вёрстку EPUB 3 нельзя перенести в EPUB 2.')
        if properties:
            warnings.add('Особые параметры разворотов EPUB 3 могут отличаться на старой читалке.')
    if spine.attrib.pop('page-progression-direction', '') == 'rtl':
        warnings.add('Направление перелистывания справа налево зависит от старой читалки.')
    spine.attrib.pop('id', None)
    identifier = next((api.plain(node) for node in metadata.findall('{' + api.DC + '}identifier')
                       if node.get('id') == package.get('unique-identifier')), '')
    title = api.plain(metadata.find('{' + api.DC + '}title'))
    language = api.plain(metadata.find('{' + api.DC + '}language'))
    if not identifier or not title or not language or not len(spine):
        raise api.ConversionError('Для EPUB 2 нужны название, язык, идентификатор и главы книги.')
    legacy_metadata(api, metadata, cover_id, warnings)

    replacements, chapters, nav = {}, {}, None
    for path, item in by_path.items():
        if check is not None:
            check()
        if item.get('media-type') != XHTML:
            continue
        document = api.xhtml(archive.read(path))
        if document.tag != '{' + api.XH + '}html':
            raise api.ConversionError('Глава EPUB не является XHTML: ' + path)
        if path == nav_path:
            # Parse the original nav before simplifying it as a visible XHTML page.
            nav = api.xhtml(archive.read(path))
        chapters[path] = {node.get('id') for node in document.iter() if node.get('id')}
        if epub2_chapter(api, archive, path, document, by_path, warnings):
            replacements[path] = api.serialized(document)
    existing_toc = by_id.get(spine.get('toc'))
    if existing_toc is None:
        existing_toc = next((item for item in manifest if item.get('media-type') == NCX_MEDIA), None)
    if nav is not None:
        if existing_toc is None:
            base_path = posixpath.join(posixpath.dirname(package_path), 'homelibre-toc')
            ncx_path = base_path + '.ncx'
            identity = 'hl-ncx'
            used_paths = {path.casefold() for path in archive.names}
            used_ids = {node.get('id') for node in package.iter() if node.get('id')}
            index = 0
            while ncx_path.casefold() in used_paths or identity in used_ids:
                index += 1
                ncx_path = f'{base_path}-{index}.ncx'
                identity = f'hl-ncx-{index}'
            existing_toc = api.element(api.OP, 'item', id=identity,
                                       href=relative_href(package_path, ncx_path), **{'media-type': NCX_MEDIA})
            manifest.append(existing_toc)
        else:
            ncx_path = archive.resolve(package_path, existing_toc.get('href'))[0]
        replacements[ncx_path] = ncx_navigation(api, archive, nav_path, nav, ncx_path, title, identifier, chapters)
    if existing_toc is None or existing_toc.get('media-type') != NCX_MEDIA:
        raise api.ConversionError('В EPUB не найдено оглавление для старых читалок.')
    spine.set('toc', existing_toc.get('id'))
    package.attrib.pop('prefix', None)
    package.set('version', '2.0')
    replacements[package_path] = api.serialized(package)
    return replacements


def convert(api, source, output, warnings, check):
    def transform(archive, path, package, notes, cancel):
        return downgrade_package(api, archive, path, package, notes, cancel)

    api.rewrite_epub_version(source, output, '2', transform, warnings, check)

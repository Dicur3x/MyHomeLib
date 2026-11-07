"""Prepare SVG illustrations in a private EPUB for the KFX writer."""

from base64 import b64encode
from contextlib import closing
from copy import deepcopy
from hashlib import sha256
import posixpath
import re
import struct
from urllib.parse import quote
import zipfile

from markdown_output import SVG, static_svg


VECTOR = '{' + SVG + '}'
PNG = b'\x89PNG\r\n\x1a\n'
CSS_URL = re.compile(r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''', re.I)


def vector_input(api, archive, path, vector, decode_webp):
    vector = deepcopy(vector)
    vector.tail = None
    images = []
    image_bytes = 0
    for node in vector.iter():
        if node.tag in (VECTOR + 'text', VECTOR + 'tspan'):
            raise api.ConversionError('KFX: пока нельзя перенести SVG с текстом и сохранить его шрифт.')
        if node.tag != VECTOR + 'image':
            continue
        href = node.attrib.pop('{' + api.XL + '}href', '') or node.get('href', '')
        target, fragment = archive.resolve(path, href)
        if target not in archive.names or fragment:
            raise api.ConversionError('KFX: рисунок SVG использует недоступное изображение.')
        data = archive.read(target)
        if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
            data = webp_image(api, data, decode_webp)
        image_bytes += 4 * ((len(data) + 2) // 3)
        if image_bytes > api.MAX_FILE:
            raise api.ConversionError('KFX: вложенные изображения SVG слишком велики.')
        if data.startswith(PNG):
            mime = 'image/png'
        elif data.startswith(b'\xff\xd8\xff'):
            mime = 'image/jpeg'
        else:
            raise api.ConversionError('KFX: внутри рисунка SVG требуется изображение PNG или JPEG.')
        # Validate the element's geometry and all other attributes first.
        node.tag = VECTOR + 'g'
        node.set('href', '#embedded')
        images.append((node, 'data:' + mime + ';base64,' + b64encode(data).decode('ascii')))
    if static_svg(api, vector) is None:
        raise api.ConversionError('KFX: у рисунка SVG есть оформление или ссылки, которые пока нельзя перенести.')
    for node, href in images:
        node.tag = VECTOR + 'image'
        node.set('href', href)
    data = api.serialized(vector)
    if len(data) > api.MAX_FILE:
        raise api.ConversionError('KFX: рисунок SVG слишком велик.')
    return data


def webp_image(api, data, decode):
    if not data.startswith(b'RIFF') or data[8:12] != b'WEBP':
        raise api.ConversionError('KFX: рисунок заявлен как WebP, но не содержит данных WebP.')
    if len(data) > 20 and data[12:16] == b'VP8X' and data[20] & 2:
        raise api.ConversionError('KFX: анимированный WebP нельзя перенести без потери кадров.')
    if decode is None:
        raise api.ComponentRequired('WebP', 'Для рисунков WebP в книге нужен декодер WebP.')
    return decode(data)


def prepare(api, source, destination, render, check=None, decode_webp=None):
    """Convert supported SVG and WebP to PNG in a private EPUB."""
    with closing(api.EpubArchive(source)) as archive:
        container = api.xml(archive.read('META-INF/container.xml'))
        roots = [node.get('full-path') for node in container.iter() if api.tag(node) == 'rootfile']
        if len(roots) != 1 or not roots[0]:
            raise api.ConversionError('KFX: для подготовки изображений нужен один пакет EPUB.')
        package_path = roots[0]
        package = api.xml(archive.read(package_path))
        if any((node.get('property') == 'rendition:layout' and api.plain(node) == 'pre-paginated')
               or 'rendition:layout-pre-paginated' in node.get('properties', '').split()
               or (node.get('name') == 'fixed-layout' and node.get('content') == 'true')
               for node in package.iter()):
            raise api.ConversionError('KFX: фиксированную вёрстку EPUB пока нельзя сохранить без изменений.')
        manifest = api.first(package, 'manifest')
        if manifest is None:
            raise api.ConversionError('KFX: в EPUB нет списка ресурсов.')
        members = [(item, archive.resolve(package_path, item.get('href', ''))[0]) for item in manifest]
        names = set(archive.names)
        ids = {item.get('id') for item in manifest}
        updates, added, replacements = {}, {}, {}
        added_bytes = 0

        def relative(path, target):
            return quote(posixpath.relpath(target, posixpath.dirname(path) or '.'))

        def require_rewrite():
            if check is not None:
                check()
            if 'META-INF/signatures.xml' in archive.names:
                raise api.ConversionError('KFX: замена рисунков нарушила бы подпись EPUB.')

        def add_png(image, maximum, item=None):
            nonlocal added_bytes
            if not 33 <= len(image) <= api.MAX_FILE or not image.startswith(PNG) or image[12:16] != b'IHDR':
                raise api.ConversionError('KFX: не удалось подготовить PNG допустимого размера.')
            width, height = struct.unpack_from('>II', image, 16)
            if not (0 < width <= maximum and 0 < height <= maximum):
                raise api.ConversionError('KFX: рисунок превышает допустимые размеры.')
            added_bytes += len(image)
            if added_bytes > api.MAX_TOTAL:
                raise api.ConversionError('KFX: обработанные изображения превышают допустимый объём.')
            stem = 'hl-kfx-image-' + sha256(image).hexdigest()[:20]
            name = stem
            suffix = 0
            target = posixpath.join(posixpath.dirname(package_path), name + '.png')
            while name in ids or target in names:
                suffix += 1
                name = f'{stem}-{suffix}'
                target = posixpath.join(posixpath.dirname(package_path), name + '.png')
            names.add(target)
            ids.add(name)
            added[target] = image
            if item is None:
                item = api.element(api.OP, 'item', id=name)
                manifest.append(item)
            item.set('href', relative(package_path, target))
            item.set('media-type', 'image/png')
            return target

        for item, path in members:
            mime = item.get('media-type')
            if not path or mime not in ('image/svg+xml', 'image/webp'):
                continue
            if path in replacements:
                raise api.ConversionError('KFX: рисунок несколько раз указан в списке ресурсов.')
            require_rewrite()
            data = archive.read(path)
            if mime == 'image/svg+xml':
                vector = vector_input(api, archive, path, api.xml(data), decode_webp)
                replacements[path] = add_png(render(vector), 2048, item)
            else:
                replacements[path] = add_png(webp_image(api, data, decode_webp), 16384, item)

        def remap(path, href):
            if not replacements:
                return href
            target, fragment = archive.resolve(path, href)
            if target not in replacements:
                return href
            if fragment:
                raise api.ConversionError('KFX: ссылка ведёт на отдельную часть рисунка.')
            return relative(path, replacements[target])

        def stylesheet(path, css):
            def replace(match):
                href = match[2].strip()
                mapped = remap(path, href)
                return 'url("' + mapped + '")' if mapped != href else match[0]
            return CSS_URL.sub(replace, css) if replacements else css

        for item, path in members:
            if check is not None:
                check()
            if not path or path in updates:
                continue
            if item.get('media-type') == 'text/css' and replacements:
                css = archive.read(path).decode('utf-8-sig')
                changed = stylesheet(path, css)
                if changed != css:
                    updates[path] = changed.encode('utf-8')
            if item.get('media-type') != 'application/xhtml+xml':
                continue
            chapter = api.xhtml(archive.read(path))
            if any(api.tag(node) in {'audio', 'video', 'script', 'iframe', 'object', 'embed'}
                   for node in chapter.iter()):
                raise api.ConversionError('KFX: в EPUB есть интерактивные или мультимедийные элементы.')
            pending = [chapter]
            changed = False
            while pending:
                parent = pending.pop()
                for name in ('src', 'href', 'data', 'poster'):
                    href = parent.get(name)
                    if href and (mapped := remap(path, href)) != href:
                        parent.set(name, mapped)
                        changed = True
                if api.tag(parent) == 'style' and parent.text:
                    css = stylesheet(path, parent.text)
                    changed |= css != parent.text
                    parent.text = css
                if parent.get('style'):
                    css = stylesheet(path, parent.get('style'))
                    changed |= css != parent.get('style')
                    parent.set('style', css)
                for index, node in enumerate(list(parent)):
                    if node.tag != VECTOR + 'svg':
                        pending.append(node)
                        continue
                    require_rewrite()
                    vector = vector_input(api, archive, path, node, decode_webp)
                    image = api.element(api.XH, 'img', src=relative(path, add_png(render(vector), 2048)),
                                        alt=api.plain(api.first(node, 'title')))
                    image.tail = node.tail
                    for name in ('id', 'width', 'height'):
                        if name in node.attrib:
                            image.set(name, node.get(name))
                    parent.remove(node)
                    parent.insert(index, image)
                    changed = True
            if changed:
                updates[path] = api.serialized(chapter)
                properties = item.get('properties', '').split()
                if 'svg' in properties:
                    properties.remove('svg')
                    if properties:
                        item.set('properties', ' '.join(properties))
                    else:
                        item.attrib.pop('properties')
        if not added:
            return 0
        updates[package_path] = api.serialized(package)
        entries = [entry for entry in archive.archive.infolist() if entry.filename not in replacements]
        sizes = [len(updates[entry.filename]) if entry.filename in updates else entry.file_size for entry in entries]
        if (len(entries) + len(added) > api.MAX_ENTRIES or max(sizes, default=0) > api.MAX_FILE
                or sum(sizes) + added_bytes > api.MAX_TOTAL):
            raise api.ConversionError('KFX: подготовленная книга превышает допустимый объём.')
        with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as result:
            for entry in entries:
                if check is not None:
                    check()
                name = entry.filename
                result.writestr(entry, updates[name] if name in updates else archive.read(name))
            for name, image in added.items():
                result.writestr(name, image)
        return len(added)

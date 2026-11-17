"""Prepare SVG illustrations in a private EPUB for the KFX writer."""

from base64 import b64decode, b64encode
from contextlib import closing
from copy import deepcopy
from hashlib import sha256
import posixpath
import re
import struct
from urllib.parse import quote, unquote
import zipfile

from markdown_output import SVG, static_svg


VECTOR = '{' + SVG + '}'
PNG = b'\x89PNG\r\n\x1a\n'
CSS_URL = re.compile(r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''', re.I)


def vector_input(api, archive, path, vector, decode_webp, decode_gif=None):
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
        if data.startswith((b'GIF87a', b'GIF89a')):
            if decode_gif is None:
                raise api.ComponentRequired('ImageProcessing', 'Для GIF внутри SVG нужен модуль HomeLibre Images.')
            data = decode_gif(data)
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


def remap_srcset(value, resolve):
    # Preserve descriptors, spacing and data-URL commas. A source URL
    # ends at ASCII whitespace; trailing commas delimit candidates.
    spans = []
    at = 0
    while at < len(value):
        while at < len(value) and value[at] in ' \t\n\r\f,':
            at += 1
        start = at
        while at < len(value) and value[at] not in ' \t\n\r\f':
            at += 1
        end = at
        while end > start and value[end-1] == ',':
            end -= 1
        if end > start:
            mapped = resolve(value[start:end])
            if mapped != value[start:end]:
                spans.append((start, end, mapped))
        if end != at:
            continue
        depth = 0
        while at < len(value):
            char = value[at]
            at += 1
            if char == '(':
                depth += 1
            elif char == ')':
                depth = max(0, depth-1)
            elif char == ',' and depth == 0:
                break
    for start, end, mapped in reversed(spans):
        value = value[:start] + mapped + value[end:]
    return value


def prepare(api, source, destination, render, check=None, decode_webp=None, decode_gif=None, only_gif=False):
    """Convert supported SVG/WebP and a static GIF frame to private PNGs."""
    label = 'GIF' if only_gif else 'KFX'
    with closing(api.EpubArchive(source)) as archive:
        container = api.xml(archive.read('META-INF/container.xml'))
        roots = [node.get('full-path') for node in container.iter() if api.tag(node) == 'rootfile']
        if not roots or any(not root for root in roots) or len(set(roots)) != len(roots) or (not only_gif and len(roots) != 1):
            message = 'некорректный список пакетов EPUB.' if only_gif else 'для подготовки изображений нужен один пакет EPUB.'
            raise api.ConversionError(f'{label}: {message}')
        package_path = roots[0]
        packages = {path: api.xml(archive.read(path)) for path in roots}
        package = packages[package_path]
        if not only_gif and any((node.get('property') == 'rendition:layout' and api.plain(node) == 'pre-paginated')
               or 'rendition:layout-pre-paginated' in node.get('properties', '').split()
               or (node.get('name') == 'fixed-layout' and node.get('content') == 'true')
               for node in package.iter()):
            raise api.ConversionError(f'{label}: фиксированную вёрстку EPUB пока нельзя сохранить без изменений.')
        manifests = {path: api.first(value, 'manifest') for path, value in packages.items()}
        if any(value is None for value in manifests.values()):
            raise api.ConversionError(f'{label}: в EPUB нет списка ресурсов.')
        owners = {id(item): path for path, manifest in manifests.items() for item in manifest}
        members = [(item, archive.resolve(path, item.get('href', ''))[0])
                   for path, manifest in manifests.items() for item in manifest]
        names = set(archive.names)
        ids = {item.get('id') for manifest in manifests.values() for item in manifest}
        updates, added, replacements = {}, {}, {}
        png_targets, inline_gifs = {}, {}
        added_bytes = 0

        def relative(path, target):
            return quote(posixpath.relpath(target, posixpath.dirname(path) or '.'))

        def require_rewrite():
            if check is not None:
                check()
            if 'META-INF/signatures.xml' in archive.names:
                raise api.ConversionError(f'{label}: замена рисунков нарушила бы подпись EPUB.')

        def add_png(image, maximum, item=None):
            nonlocal added_bytes
            if not 33 <= len(image) <= api.MAX_FILE or not image.startswith(PNG) or image[12:16] != b'IHDR':
                raise api.ConversionError(f'{label}: не удалось подготовить PNG допустимого размера.')
            width, height = struct.unpack_from('>II', image, 16)
            if not (0 < width <= maximum and 0 < height <= maximum):
                raise api.ConversionError(f'{label}: рисунок превышает допустимые размеры.')
            added_bytes += len(image)
            if added_bytes > api.MAX_TOTAL:
                raise api.ConversionError(f'{label}: обработанные изображения превышают допустимый объём.')
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
            png_targets.setdefault(sha256(image).digest(), target)
            if item is None:
                # A shared content/CSS document may belong to several
                # renditions. Register its inline image in each package.
                for path, manifest in manifests.items():
                    entry = api.element(api.OP, 'item', id=name, href=relative(path, target))
                    entry.set('media-type', 'image/png')
                    manifest.append(entry)
            else:
                item.set('href', relative(owners[id(item)], target))
                item.set('media-type', 'image/png')
            return target

        for item, path in members:
            mime = item.get('media-type')
            if only_gif:
                if not path or not (mime or '').startswith('image/'):
                    continue
                with archive.archive.open(path) as stream:
                    if stream.read(6) not in (b'GIF87a', b'GIF89a'):
                        continue
                mime = 'image/gif'
            if not path or mime not in ('image/svg+xml', 'image/webp', 'image/gif'):
                continue
            if path in replacements:
                if only_gif and len(packages) > 1:
                    item.set('href', relative(owners[id(item)], replacements[path]))
                    item.set('media-type', 'image/png')
                    continue
                raise api.ConversionError(f'{label}: рисунок несколько раз указан в списке ресурсов.')
            require_rewrite()
            data = archive.read(path)
            if mime == 'image/svg+xml':
                vector = vector_input(api, archive, path, api.xml(data), decode_webp, decode_gif)
                replacements[path] = add_png(render(vector), 2048, item)
            elif mime == 'image/webp':
                replacements[path] = add_png(webp_image(api, data, decode_webp), 16384, item)
            else:
                if decode_gif is None:
                    raise api.ComponentRequired('ImageProcessing', 'Для подготовки GIF нужен модуль HomeLibre Images.')
                replacements[path] = add_png(decode_gif(data), 16384, item)

        def remap(path, href):
            header, separator, payload = href.partition(',')
            if decode_gif is not None and separator and header.lower().startswith('data:image/') and ';base64' in header.lower():
                payload = ''.join(unquote(payload).split())
                try:
                    signature = b64decode(payload[:12], validate=True)
                except ValueError as error:
                    if header.lower().startswith('data:image/gif;'):
                        raise api.ConversionError(f'{label}: некорректные данные встроенного GIF.') from error
                    return href
                if signature.startswith((b'GIF87a', b'GIF89a')):
                    require_rewrite()
                    if len(payload) > 4 * ((16 * 1024 * 1024 + 2) // 3):
                        raise api.ConversionError(f'{label}: встроенное изображение GIF превышает 16 МБ.')
                    try:
                        data = b64decode(payload, validate=True)
                    except ValueError as error:
                        raise api.ConversionError(f'{label}: некорректные данные встроенного GIF.') from error
                    key = sha256(data).digest()
                    if key not in inline_gifs:
                        image = decode_gif(data)
                        # Existing resources may be declared in only one of
                        # several packages. A fresh inline entry is registered
                        # in all of them, keeping every rendition self-contained.
                        existing = png_targets.get(sha256(image).digest()) if len(packages) == 1 else None
                        inline_gifs[key] = existing or add_png(image, 16384)
                    return relative(path, inline_gifs[key])
            if not replacements:
                return href
            target, fragment = archive.resolve(path, href)
            if target not in replacements:
                return href
            if fragment:
                raise api.ConversionError(f'{label}: ссылка ведёт на отдельную часть рисунка.')
            return relative(path, replacements[target])

        def stylesheet(path, css):
            def replace(match):
                href = match[2].strip()
                mapped = remap(path, href)
                return 'url("' + mapped + '")' if mapped != href else match[0]
            return CSS_URL.sub(replace, css) if replacements or only_gif else css



        for item, path in members:
            if check is not None:
                check()
            if not path or path in updates:
                continue
            if item.get('media-type') == 'text/css' and (replacements or only_gif):
                css = archive.read(path).decode('utf-8-sig')
                changed = stylesheet(path, css)
                if changed != css:
                    updates[path] = changed.encode('utf-8')
            xml_resource = only_gif and item.get('media-type') in ('image/svg+xml', 'application/x-dtbncx+xml')
            if item.get('media-type') != 'application/xhtml+xml' and not xml_resource:
                continue
            chapter = api.xml(archive.read(path)) if xml_resource else api.xhtml(archive.read(path))
            if not only_gif and any(api.tag(node) in {'audio', 'video', 'script', 'iframe', 'object', 'embed'}
                   for node in chapter.iter()):
                raise api.ConversionError(f'{label}: в EPUB есть интерактивные или мультимедийные элементы.')
            pending = [chapter]
            changed = False
            while pending:
                parent = pending.pop()
                for name in ('src', 'href', 'data', 'poster', '{' + api.XL + '}href'):
                    href = parent.get(name)
                    if href and (mapped := remap(path, href)) != href:
                        parent.set(name, mapped)
                        if parent.get('type') == 'image/gif':
                            parent.set('type', 'image/png')
                        changed = True
                if parent.get('srcset'):
                    value = remap_srcset(parent.get('srcset'), lambda href: remap(path, href))
                    changed |= value != parent.get('srcset')
                    parent.set('srcset', value)
                    if changed and parent.get('type') == 'image/gif':
                        parent.set('type', 'image/png')
                if api.tag(parent) == 'style' and parent.text:
                    css = stylesheet(path, parent.text)
                    changed |= css != parent.text
                    parent.text = css
                if parent.get('style'):
                    css = stylesheet(path, parent.get('style'))
                    changed |= css != parent.get('style')
                    parent.set('style', css)
                for index, node in enumerate(list(parent)):
                    if node.tag != VECTOR + 'svg' or only_gif:
                        pending.append(node)
                        continue
                    require_rewrite()
                    vector = vector_input(api, archive, path, node, decode_webp, decode_gif)
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
                if 'svg' in properties and not only_gif:
                    properties.remove('svg')
                    if properties:
                        item.set('properties', ' '.join(properties))
                    else:
                        item.attrib.pop('properties')
        if only_gif:
            for path, package in packages.items():
                for node in package.iter():
                    href = node.get('href')
                    if href:
                        node.set('href', remap(path, href))
        if not added:
            return 0
        for path, package in packages.items():
            updates[path] = api.serialized(package)
        entries = [entry for entry in archive.archive.infolist() if entry.filename not in replacements]
        sizes = [len(updates[entry.filename]) if entry.filename in updates else entry.file_size for entry in entries]
        if (len(entries) + len(added) > api.MAX_ENTRIES or max(sizes, default=0) > api.MAX_FILE
                or sum(sizes) + added_bytes > api.MAX_TOTAL):
            raise api.ConversionError(f'{label}: подготовленная книга превышает допустимый объём.')
        with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as result:
            for entry in entries:
                if check is not None:
                    check()
                name = entry.filename
                result.writestr(entry, updates[name] if name in updates else archive.read(name))
            for name, image in added.items():
                result.writestr(name, image)
        return len(added)

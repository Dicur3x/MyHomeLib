"""Optional export image compression; local Windows codec, no source changes (MIT)."""
import base64
import copy
import json
from pathlib import Path
import posixpath
import re
import subprocess
import tempfile
import time
import zipfile
import zlib

PROFILES = ('high', 'balanced', 'economy')
SCAN_PROFILES = ('original', *PROFILES)
OMITTED_IMAGE = '[Изображение не включено в эту копию]'


class NoTextContent(ValueError):
    pass


def deflated_size(source):
    """Count raw ZIP deflate bytes without a second full-size temporary file."""
    encoder = zlib.compressobj(6, zlib.DEFLATED, -15)
    count = 0
    if isinstance(source, (bytes, bytearray)):
        blocks = (source[at:at+256*1024] for at in range(0,len(source),256*1024))
        for block in blocks: count += len(encoder.compress(block))
    else:
        with Path(source).open('rb') as stream:
            while True:
                block = stream.read(256*1024)
                if not block: break
                count += len(encoder.compress(block))
    return count + len(encoder.flush())


def remove_nodes(root, predicate, replacement=None):
    """Keep the text following an inline picture, including its exact spaces."""
    removed = 0
    for parent in root.iter():
        for child in list(parent):
            if predicate(child):
                at = list(parent).index(child)
                substitute = replacement(parent,child) if replacement is not None else None
                if substitute is not None:
                    substitute.tail = child.tail
                    parent.remove(child); parent.insert(at,substitute)
                    removed += 1
                    continue
                if child.tail:
                    if at: parent[at-1].tail = (parent[at-1].tail or '') + child.tail
                    else: parent.text = (parent.text or '') + child.tail
                parent.remove(child); removed += 1
    return removed


def image_note(api, parent, fb2):
    if fb2 and api.tag(parent) == 'coverpage': return None
    namespace = api.FB if fb2 else api.XH
    inline = {'p','strong','emphasis','style','a','strikethrough','sub','sup','code','v','text-author',
              'subtitle','td','th','span','em','b','i','small','label'}
    note = api.element(namespace,'emphasis' if fb2 else 'em',OMITTED_IMAGE)
    if api.tag(parent) in inline: return note
    paragraph = api.element(namespace,'p'); paragraph.append(note)
    if fb2 and api.tag(parent) == 'body':
        section = api.element(namespace,'section'); section.append(paragraph)
        return section
    return paragraph


def readable_text(api, root, fb2):
    # A cover, page heading, image alt label or hidden SVG text is not a book's
    # textual body. Never turn an image-only book into an apparently valid stub.
    bodies = [n for n in root.iter() if api.tag(n) == 'body']
    for body in bodies:
        probe = copy.deepcopy(body)
        excluded = {'title','image','binary'} if fb2 else {
            'h1','h2','h3','h4','h5','h6','img','svg','picture','script','style','nav','head'}
        remove_nodes(probe, lambda n: api.tag(n) in excluded)
        if ''.join(probe.itertext()).strip(): return True
    return False


def strip_fb2(api, root):
    references = {n.get('{'+api.XL+'}href', '').lstrip('#')
                  for n in root.iter() if api.tag(n) == 'image'}
    references.update(n.get('id','') for n in root.iter() if api.tag(n) == 'binary' and
                      n.get('content-type','').lower().startswith('image/'))
    references.discard('')
    count = remove_nodes(root, lambda n: api.tag(n) == 'image',
                         lambda parent,_: image_note(api,parent,True))
    binaries = remove_nodes(root, lambda n: api.tag(n) == 'binary' and
                            (n.get('content-type','').lower().startswith('image/') or n.get('id') in references))
    count = max(count,binaries)
    remove_nodes(root, lambda n: api.tag(n) == 'coverpage' and not len(n))
    for node in root.iter():
        if api.tag(node) == 'stylesheet' and node.text:
            node.text = re.sub(r'url\(\s*([^)]*?)\s*\)',
                lambda m: 'none' if m[1].strip().strip('\"\'').lstrip('#') in references or
                          m[1].strip().strip('\"\'').lower().startswith('data:image/') else m[0],node.text,flags=re.I)
    # Links to illustrations may still have useful captions. Keep that text,
    # while removing only their now missing image target. Footnotes stay links.
    for parent in list(root.iter()):
        for node in list(parent):
            if node.get('{'+api.XL+'}href','').lstrip('#') not in references: continue
            at = list(parent).index(node)
            if node.text:
                if at: parent[at-1].tail = (parent[at-1].tail or '') + node.text
                else: parent.text = (parent.text or '') + node.text
            nested = list(node)
            parent.remove(node)
            for offset, child in enumerate(nested): parent.insert(at+offset,child)
            if node.tail:
                if at+len(nested): parent[at+len(nested)-1].tail = (parent[at+len(nested)-1].tail or '') + node.tail
                else: parent.text = (parent.text or '') + node.tail
    return count


def without_images(api, book, destination, target_extension):
    """Write a complete text-only candidate; caller publishes it atomically."""
    if target_extension == '.fb2':
        original = book.read_bytes()
        root = api.xml(original, api.MAX_TOTAL)
        has_text = readable_text(api,root,True)
        count = strip_fb2(api, root)
        if count and not has_text:
            raise NoTextContent('В книге нет отдельного текста: изображения содержат сами страницы. Для режима без изображений сначала нужно распознать текст.')
        declaration = re.match(br'\s*<\?xml[^>]*encoding=[\'\"]([^\'\"]+)',original.lstrip(b'\xef\xbb\xbf'))
        encoding = declaration[1].decode('ascii') if declaration else 'utf-8'
        # Keep legacy Cyrillic encodings: deleting a small cover should not
        # double the text payload just because UTF-8 uses two bytes per letter.
        destination.write_bytes(api.ET.tostring(root,encoding=encoding,xml_declaration=True))
        return count
    with zipfile.ZipFile(book) as source:
        packages, resources, image_ids, changed, removed = {}, {}, {}, {}, set()
        covers = set()
        count = 0
        for entry in source.infolist():
            if not entry.filename.lower().endswith('.opf'): continue
            package = api.xml(source.read(entry)); packages[entry.filename] = package
            covers.update(source_name(entry.filename,n.get('href','')) for n in package.iter()
                          if api.tag(n) == 'reference' and n.get('type') == 'cover')
            image_ids[entry.filename] = set()
            for node in package.iter():
                if api.tag(node) != 'item': continue
                name = source_name(entry.filename, node.get('href',''))
                media = node.get('media-type','').lower()
                resources[name] = media
                if media.startswith('image/'):
                    removed.add(name); image_ids[entry.filename].add(node.get('id',''))
        if not packages: raise api.ConversionError('В EPUB отсутствует каталог ресурсов.')
        # Include unlisted image resources too, without guessing that a font or
        # an arbitrary attachment with a numeric name must be an illustration.
        image_suffixes = {'.png','.jpg','.jpeg','.gif','.webp','.jxl','.bmp','.tif','.tiff','.svg','.avif','.ico'}
        removed.update(e.filename for e in source.infolist()
                       if posixpath.splitext(e.filename.lower())[1] in image_suffixes)
        count += len(removed)
        has_text = False
        documents = {}
        for name, media in resources.items():
            if media != 'application/xhtml+xml' or name in removed: continue
            root = api.xhtml(source.read(name)); documents[name] = root
            textual = readable_text(api, root, False)
            has_text = has_text or textual
            if name in covers and not textual:
                removed.add(name)
                continue
            deleted = remove_nodes(root, lambda n: api.tag(n) in {'img','svg','picture'} or
                                  (api.tag(n) in {'object','embed'} and
                                   (n.get('type','').startswith('image/') or source_name(name,n.get('data',n.get('src',''))) in removed)),
                                   lambda parent,_: image_note(api,parent,False))
            count = max(count,deleted)
        if count and not has_text:
            raise NoTextContent('В книге нет отдельного текста: изображения содержат сами страницы. Для режима без изображений сначала нужно распознать текст.')
        def missing(base, value):
            return bool(value) and (source_name(base, value) in removed or value.lower().startswith('data:image/'))
        def css(text, base):
            def replace(match):
                path = match[1].strip().strip('\"\'')
                return 'none' if missing(base,path) else match[0]
            return re.sub(r'url\(\s*([^)]*?)\s*\)', replace, text, flags=re.I)
        for name, root in documents.items():
            if name in removed: continue
            remove_nodes(root, lambda n: api.tag(n) == 'link' and missing(name,n.get('href','')))
            for node in root.iter():
                for attribute in ('href','src','poster','data','{'+api.XL+'}href'):
                    if missing(name,node.get(attribute,'')):
                        node.attrib.pop(attribute,None)
                        if api.tag(node) == 'a': node.tag = '{'+api.XH+'}span'
                if 'style' in node.attrib: node.set('style',css(node.get('style'),name))
                if api.tag(node) == 'style' and node.text: node.text = css(node.text,name)
            changed[name] = api.serialized(root)
        for name, package in packages.items():
            ids = image_ids[name]
            ids.update(n.get('id','') for n in package.iter()
                       if api.tag(n) == 'item' and missing(name,n.get('href','')))
            remove_nodes(package, lambda n:
                (api.tag(n) == 'item' and n.get('id','') in ids) or
                (api.tag(n) == 'itemref' and n.get('idref','') in ids) or
                (api.tag(n) == 'reference' and missing(name,n.get('href',''))) or
                (api.tag(n) == 'meta' and n.get('name') == 'cover' and n.get('content') in ids))
            for node in package.iter():
                if node.get('property') == 'mhl:fb2-images' and node.text:
                    saved = json.loads(node.text)
                    if not isinstance(saved,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in saved.items()):
                        raise api.ConversionError('Повреждены исходные ресурсы FB2 в EPUB.')
                    node.text = json.dumps({path:identity for path,identity in saved.items()
                                            if not missing(name,path)},ensure_ascii=False)
                if node.get('property') == 'mhl:fb2-description' and node.text:
                    description = api.xml(base64.b64decode(node.text,validate=True))
                    strip_fb2(api,description)
                    node.text = base64.b64encode(api.serialized(description)).decode('ascii')
            changed[name] = api.serialized(package)
        for name, media in resources.items():
            if name in removed: continue
            if media == 'application/x-dtbncx+xml':
                root = api.xml(source.read(name))
                remove_nodes(root, lambda n: api.tag(n) == 'navPoint' and
                             any(api.tag(c) == 'content' and missing(name,c.get('src','')) for c in n))
                changed[name] = api.serialized(root)
            elif media == 'text/css':
                data = source.read(name)
                try: changed[name] = css(data.decode('utf-8-sig'),name).encode('utf-8')
                except UnicodeError:
                    raise api.ConversionError('Неизвестная кодировка CSS при удалении изображений.')
        with zipfile.ZipFile(destination,'w',compression=zipfile.ZIP_DEFLATED) as output:
            for entry in source.infolist():
                if entry.filename in removed: continue
                output.writestr(entry.filename,changed.get(entry.filename,source.read(entry)),
                                compress_type=zipfile.ZIP_STORED if entry.filename=='mimetype' else zipfile.ZIP_DEFLATED)
    return count


def mime(data):
    if data.startswith(b'\xff\xd8\xff'): return 'image/jpeg'
    if data.startswith(b'\x89PNG\r\n\x1a\n'): return 'image/png'
    return None


def run(api, tool, pictures, directory, profile, progress, layout=None):
    source, output, log = directory/'images.zip', directory/'encoded.zip', directory/'codec.log'
    source.unlink(missing_ok=True); output.unlink(missing_ok=True)
    with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
        for index, data in enumerate(pictures): archive.writestr(f'{index:05d}', data)
    with log.open('wb') as stream:
        arguments = [str(tool), '--scan-images' if layout else '--export-images', str(source), str(output), profile]
        if layout: arguments.append(layout)
        process = subprocess.Popen(arguments,
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        started = time.monotonic(); last = 0
        try:
            while process.poll() is None:
                if time.monotonic()-started > 1800: raise api.ConversionError('Сжатие изображений превысило 30 минут.')
                if log.stat().st_size > 1024*1024: raise api.ConversionError('Слишком большой отчёт сжатия изображений.')
                lines = [s.split() for s in log.read_text(encoding='utf-8', errors='replace').splitlines() if s.startswith('IMAGE ')]
                if lines and len(lines[-1]) == 3:
                    completed, total = map(int, lines[-1][1:])
                    if completed > last:
                        stage = ('scan-estimates' if layout else 'image-estimates') if profile=='estimate' else 'optimizing-images'
                        progress(stage, completed, total); last = completed
                time.sleep(.05)
        finally:
            if process.poll() is None: process.kill()
            process.wait()
    if process.returncode or not output.is_file():
        detail = '\n'.join(s for s in log.read_bytes()[-1800:].decode('utf-8', errors='replace').splitlines() if not s.startswith('IMAGE '))
        raise api.ConversionError('Не удалось подготовить изображения для экспорта. '+detail)
    profiles = (SCAN_PROFILES if layout else PROFILES) if profile == 'estimate' else (profile,)
    with zipfile.ZipFile(output) as archive:
        if layout:
            allowed = {f'{p}/{i:05d}-{half}' for p in profiles for i in range(len(pictures)) for half in (0,1)}
            required = {f'{p}/{i:05d}-0' for p in profiles for i in range(len(pictures))}
            names = set(archive.namelist())
            if not required <= names <= allowed or len(archive.infolist()) != len(names):
                raise api.ConversionError('Неполный результат обработки сканов.')
            result = {}
            for p in profiles:
                result[p] = []
                for i in range(len(pictures)):
                    pages = []
                    for half in (0,1):
                        name = f'{p}/{i:05d}-{half}'
                        if name not in names: continue
                        if not 0 < archive.getinfo(name).file_size <= 16*1024*1024:
                            raise api.ConversionError('Некорректный размер страницы скана.')
                        data = archive.read(name)
                        if not mime(data): raise api.ConversionError('Некорректная страница скана.')
                        pages.append(data)
                    result[p].append(pages)
            if len({tuple(map(len, result[p])) for p in profiles}) != 1:
                raise api.ConversionError('Число разделённых страниц зависит от качества.')
            result['_unsplit'] = [int(line.split()[1]) for line in log.read_text(encoding='utf-8').splitlines()
                                  if line.startswith('SCAN_UNSPLIT ')]
            if any(not 0 <= index < len(pictures) for index in result['_unsplit']):
                raise api.ConversionError('Некорректный отчёт границ сканов.')
            return result
        expected = {f'{p}/{i:05d}' for p in profiles for i in range(len(pictures))}
        if set(archive.namelist()) != expected or len(archive.infolist()) != len(expected):
            raise api.ConversionError('Неполный результат сжатия изображений.')
        result = {}
        for p in profiles:
            result[p] = []
            for i, original in enumerate(pictures):
                entry = archive.getinfo(f'{p}/{i:05d}')
                if not 0 < entry.file_size <= len(original): raise api.ConversionError('Некорректный размер сжатого изображения.')
                data = archive.read(entry)
                if not mime(data): raise api.ConversionError('Некорректное сжатое изображение.')
                result[p].append(data)
    return result


def apply(api, book, target_extension, profile, tools_root, progress, options_file=None, choice_file=None, warnings=None):
    if profile == 'original': return
    if profile not in (*PROFILES, 'ask', 'none'): raise api.ConversionError('Неизвестное качество изображений.')
    if profile == 'none':
        with tempfile.TemporaryDirectory(prefix='homelib-image-quality-', dir=book.parent) as temporary:
            candidate = Path(temporary)/('text-only'+target_extension)
            try: removed = without_images(api,book,candidate,target_extension)
            except NoTextContent as error: raise api.ConversionError(str(error)) from error
            candidate.replace(book)
            if removed and warnings is not None:
                warnings.add('Книга сохранена без изображений и обложки. Исходная книга сохранена.')
        return
    pictures, identities = [], []
    root = None
    if target_extension == '.fb2':
        root = api.xml(book.read_bytes(), api.MAX_TOTAL)
        for node in root:
            if api.tag(node) != 'binary': continue
            data = base64.b64decode(''.join((node.text or '').split()), validate=True)
            if mime(data): pictures.append(data); identities.append(node)
        # Rewritten FB2 binaries use one base64 string. Do not count the source's
        # formatting whitespace as text that will survive image re-encoding.
        texts = [node.text for node in identities]
        for node in identities: node.text = None
        stripped = api.serialized(root)
        overhead = len(stripped)
        zip_overhead = deflated_size(stripped)
        for node,text in zip(identities,texts): node.text = text
        del texts
    else:
        with zipfile.ZipFile(book) as archive:
            for entry in archive.infolist():
                # Only raster resources: SVG, fonts and text are never rasterized.
                if entry.file_size > 16*1024*1024: continue
                with archive.open(entry) as stream: header = stream.read(12)
                if mime(header): pictures.append(archive.read(entry)); identities.append(entry.filename)
            overhead = book.stat().st_size - sum(archive.getinfo(name).compress_size for name in identities)
    small = not pictures or sum(map(len, pictures)) < 128*1024
    if small and profile != 'ask': return
    if sum(map(len, pictures)) > api.MAX_TOTAL or len(pictures) > 5000:
        raise api.ConversionError('Изображения превышают предел экспорта.')
    runtime_root = Path(tools_root or Path(__file__).resolve().parents[1])
    tool = api.image_processor_path(runtime_root)
    if not small and not tool.is_file():
        raise api.ComponentRequired(api.optional_component_id('ImageProcessing', runtime_root),
                                    'Для сжатия изображений нужен модуль обработки изображений HomeLibre Images.')
    with tempfile.TemporaryDirectory(prefix='homelib-image-quality-', dir=book.parent) as temporary:
        directory = Path(temporary); samples = None; sample_indices = []
        if profile == 'ask':
            candidate = directory/('text-only'+target_extension)
            try:
                removed = without_images(api,book,candidate,target_extension)
                text_only_size = candidate.stat().st_size if removed else 0
                if not removed and small: return
            except NoTextContent:
                text_only_size = 0
                if small: return
            if not options_file or not choice_file: raise api.ConversionError('Не указан канал выбора качества.')
            ordered = sorted(range(len(pictures)), key=lambda i: len(pictures[i]))
            count = min(9, len(ordered))
            sample_indices = sorted({ordered[round(i*(len(ordered)-1)/max(1,count-1))] for i in range(count)})
            samples = ({p:[pictures[i] for i in sample_indices] for p in PROFILES} if small else
                       run(api, tool, [pictures[i] for i in sample_indices], directory, 'estimate', progress))
            # Stratify by source resource size, rather than multiplying one cover
            # by the page count. EPUB compression and FB2 base64 have different costs.
            weights = [0]*len(sample_indices)
            for data in pictures:
                nearest = min(range(len(sample_indices)), key=lambda n: abs(len(data)-len(pictures[sample_indices[n]])))
                weights[nearest] += 1
            sizes = {'original': book.stat().st_size}
            # Includes a small allowance for UTF-8 member names and ZIP headers.
            # All are estimates, not a promise of byte-identical final lengths.
            zip_sizes = {'original': 512 + deflated_size(book)}
            for p in PROFILES:
                costs = [4*((len(data)+2)//3) if target_extension == '.fb2' else len(zlib.compress(data)) for data in samples[p]]
                sizes[p] = book.stat().st_size if small else max(1, overhead + sum(a*b for a,b in zip(costs,weights)))
                if small:
                    zip_sizes[p] = zip_sizes['original']
                elif target_extension == '.fb2':
                    packed = [deflated_size(base64.b64encode(data)) for data in samples[p]]
                    zip_sizes[p] = max(1,512+zip_overhead+sum(a*b for a,b in zip(packed,weights)))
                else:
                    # EPUB already deflates each member. The outer archive
                    # usually has little additional image compression to do.
                    zip_sizes[p] = max(1,512+round(sizes[p]*
                        max(.5,min(1.05,zip_sizes['original']/max(1,sizes['original'])))))
            sizes['none'] = text_only_size
            zip_sizes['none'] = 512+deflated_size(candidate) if text_only_size else 0
            options = Path(options_file); choice = Path(choice_file)
            if options.exists() or choice.exists(): raise api.ConversionError('Канал выбора качества уже занят.')
            payload = json.dumps({'format': target_extension[1:].upper(), 'images': len(pictures) or removed,
                                  'sampled': len(sample_indices), 'sizes': sizes, 'zip_sizes': zip_sizes}, ensure_ascii=False)
            pending = options.with_suffix('.new'); pending.write_text(payload, encoding='utf-8'); pending.rename(options)
            started = time.monotonic()
            while not choice.is_file():
                if time.monotonic()-started > 21600: raise api.ConversionError('Выбор качества не завершён. Экспорт отменён.')
                time.sleep(.1)
            if choice.stat().st_size > 32: raise api.ConversionError('Некорректный выбор качества.')
            profile = choice.read_text(encoding='utf-8-sig').strip()
            if profile == 'cancel': raise api.ConversionError('Экспорт отменён.')
            if profile == 'original': return
            if profile == 'none':
                if not text_only_size: raise api.ConversionError('Нельзя удалить изображения: в книге нет отдельного текста.')
                candidate.replace(book)
                if warnings is not None: warnings.add('Книга сохранена без изображений и обложки. Исходная книга сохранена.')
                return
            if profile not in PROFILES: raise api.ConversionError('Неизвестное качество изображений.')
        if small: return
        # Reuse already encoded samples; do not decode them a second time.
        encoded = [None]*len(pictures)
        if profile == 'high': encoded = list(pictures)
        if samples is not None:
            for index, data in zip(sample_indices, samples[profile]): encoded[index] = data
        remaining = [i for i,data in enumerate(encoded) if data is None]
        # Batches bound additional memory and disk usage even for a long scan.
        for at in range(0,len(remaining),12):
            indices = remaining[at:at+12]
            result = run(api, tool, [pictures[i] for i in indices], directory, profile, lambda *_: None)[profile]
            for index,data in zip(indices,result): encoded[index] = data
            progress('optimizing-images', min(len(pictures), at+len(indices)+len(sample_indices)), len(pictures))
        if target_extension == '.fb2':
            for node,data in zip(identities,encoded):
                node.text = base64.b64encode(data).decode('ascii'); node.set('content-type', mime(data))
            book.write_bytes(api.serialized(root))
        else:
            replacements = dict(zip(identities,encoded)); rewritten = directory/'book.epub'
            with zipfile.ZipFile(book) as source, zipfile.ZipFile(rewritten,'w',compression=zipfile.ZIP_DEFLATED) as output:
                for entry in source.infolist():
                    data = replacements.get(entry.filename)
                    if data is None:
                        data = source.read(entry)
                        if entry.filename.lower().endswith('.opf'):
                            package = api.xml(data)
                            for item in package.iter():
                                if api.tag(item) != 'item': continue
                                name = source_name(entry.filename,item.get('href',''))
                                if name in replacements: item.set('media-type',mime(replacements[name]))
                            data = api.serialized(package)
                    output.writestr(entry.filename,data,compress_type=zipfile.ZIP_STORED if entry.filename=='mimetype' else zipfile.ZIP_DEFLATED)
            rewritten.replace(book)
        if warnings is not None: warnings.add('Изображения подготовлены для экспорта: '+{'high':'высокое качество','balanced':'сбалансированный режим','economy':'экономный режим'}[profile]+'. Исходная книга сохранена.')


def source_name(package, href):
    from urllib.parse import unquote, urlsplit
    return posixpath.normpath(posixpath.join(posixpath.dirname(package), unquote(urlsplit(href).path)))

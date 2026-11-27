"""Small legacy text containers. MIT; no network or source modification."""
from collections import Counter
from email import policy
from email.parser import BytesParser
from html.parser import HTMLParser
from pathlib import Path, PureWindowsPath
import json
import posixpath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from urllib.parse import quote, unquote, urldefrag, urljoin, urlsplit
import zlib
import zipfile
import xml.etree.ElementTree as ET

SUPPORTED = {'.mht', '.mhtml', '.wri', '.pdb', '.tcr', '.chm', '.lit', '.lrf', '.rb'}
CHM_HTML_TOPICS = {'.htm', '.html', '.xhtml', '.shtml'}
CHM_LINKED_IMAGES = {'.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp',
                     '.tif', '.tiff', '.webp', '.wmf', '.emf'}
CHM_INDEX_ANCHOR = re.compile(r'I_indexterm[0-9]+_d[0-9]+e[0-9]+').fullmatch
CHM_LETTER_INDEX = re.compile(r'index_[a-z]\.html?').fullmatch
CHM_DOCBOOK_INDEX_ANCHOR = re.compile(r'idd[0-9]+e[0-9]+').fullmatch


def read_lit_lrf(book, read_html):
    helper=Path(__file__).with_name('legacy_helper.py')
    native=book.tools_root/'bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll'
    if not native.is_file():
        book.require('LegacyBooks', 'Для чтения LIT/LRF нужен модуль старых книжных форматов (calibre).')
    with tempfile.TemporaryDirectory(prefix='legacy-',dir=book.work_root) as directory:
        target=Path(directory)/'reading.zip'
        try:
            result=subprocess.run([sys.executable,'-I','-B','-X','utf8',str(helper),str(book.source),str(target),
                                   '--native-library',str(native)],capture_output=True,timeout=90,creationflags=0x08000000)
        except subprocess.TimeoutExpired:book.fail('Чтение старого книжного формата превысило 90 секунд.')
        if result.returncode or not target.is_file():
            book.fail('Не удалось прочитать LIT/LRF: '+result.stderr.decode('utf-8',errors='replace')[-1200:])
        with zipfile.ZipFile(target) as package:
            entries=package.infolist()
            if len(entries)>20002 or len({entry.filename for entry in entries})!=len(entries) or \
                    any(entry.file_size>book.c.MAX_FILE for entry in entries) or sum(entry.file_size for entry in entries)>book.c.MAX_TOTAL:
                book.fail('Подготовленный LIT/LRF превышает предел конвертации.')
            metadata=json.loads(package.read('metadata.json'))
            for value in metadata.get('warnings',[]):book.warnings.add(str(value))
            if book.title==book.source.stem and metadata.get('title'):book.title=metadata['title']
            if not book.author:book.author=metadata.get('creator','')
            if book.language=='und':book.language=metadata.get('language','und')
            original=book.local_image
            def image(href):
                if href.startswith('data:'):return original(href)
                if href not in package.namelist():book.fail('В LIT/LRF отсутствует изображение: '+href[:160])
                return book.image(package.read(href))
            book.local_image=image
            try:
                read_html(book,package.read('book.html'))
                if metadata.get('cover'):
                    cover=image(metadata['cover']);book.cover_image=cover.get('src')
                    if not any(node.get('src')==book.cover_image for node in book.body.iter()):
                        paragraph=book.el('p');paragraph.append(cover);book.body.insert(0,paragraph)
            finally:book.local_image=original


def paragraphs(book, text):
    for line in text.replace('\x00', '').splitlines():
        p = book.el('p', line)
        if not line: p.append(book.el('br'))
        book.body.append(p)


def legacy_decode(data):
    try: return data.decode('utf-8-sig')
    except UnicodeError:
        # PalmDoc has no encoding declaration. Western punctuation is sparse;
        # Russian legacy books normally have whole words in the upper half.
        high = sum(ch >= 128 for ch in data)
        return data.decode('cp1251' if high > len(data) * .12 else 'cp1252', errors='strict')


def palmdoc(data, fail):
    output = bytearray(); at = 0
    while at < len(data):
        code = data[at]; at += 1
        if 1 <= code <= 8:
            if at + code > len(data): fail('Повреждён блок PalmDoc: оборван литерал.')
            output.extend(data[at:at + code]); at += code
        elif 128 <= code <= 191:
            if at == len(data): fail('Повреждён блок PalmDoc: оборвана ссылка.')
            pair = ((code & 63) << 8) | data[at]; at += 1
            distance, length = pair >> 3, (pair & 7) + 3
            if distance == 0 or distance > len(output): fail('Повреждённая ссылка PalmDoc.')
            for _ in range(length): output.append(output[-distance])
        elif code >= 192: output.extend((32, code ^ 128))
        else: output.append(code)
        if len(output) > 65536: fail('Распакованный блок PalmDoc слишком велик.')
    return bytes(output)


def read_pdb(book, data):
    if len(data) < 78: book.fail('Оборван заголовок PDB.')
    kind = data[60:68]; count = int.from_bytes(data[76:78], 'big')
    if count == 0 or count > 20000 or 78 + count * 8 > len(data): book.fail('Повреждён каталог записей PDB.')
    offsets = [int.from_bytes(data[78 + n * 8:82 + n * 8], 'big') for n in range(count)] + [len(data)]
    if offsets[0] < 78 + count * 8 or any(a > b or b > len(data) for a, b in zip(offsets, offsets[1:])):
        book.fail('Некорректные границы записей PDB.')
    records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
    header = records[0]
    if kind == b'SDocSilX':
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_isilo', Path(__file__).with_name('isilo_input.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.read(book, records, legacy_decode, paragraphs)
        return
    if kind == b'TEXtREAd':
        if len(header) < 16: book.fail('Оборван заголовок PalmDoc.')
        compression, _, length, nrecords, _ = struct.unpack('>HHIHH', header[:12])
        if compression not in (1, 2, 258): book.fail('Неподдерживаемое сжатие PalmDoc.')
        if length > book.c.MAX_FILE or nrecords == 0 or nrecords >= len(records): book.fail('Некорректная длина PalmDoc.')
        chunks = []
        for record in records[1:1 + nrecords]:
            chunks.append(record if compression == 1 else palmdoc(record, book.fail))
            if sum(map(len, chunks)) > book.c.MAX_FILE: book.fail('Текст PalmDoc превышает 64 МБ.')
        text = b''.join(chunks)
        if len(text) != length:
            book.warnings.add('В заголовке PalmDoc указана неточная длина текста. Перенесены все целые текстовые записи; проверьте окончание по оригиналу.')
    elif kind == b'zTXTGPlm':
        if len(header) < 14: book.fail('Оборван заголовок zTXT.')
        nrecords = int.from_bytes(header[2:4], 'big'); length = int.from_bytes(header[4:8], 'big')
        if not 0 < nrecords < len(records) or length > book.c.MAX_FILE: book.fail('Некорректная длина zTXT.')
        decoder = zlib.decompressobj()
        try: text = decoder.decompress(b''.join(records[1:1 + nrecords]), book.c.MAX_FILE + 1)
        except zlib.error: book.fail('Повреждённое сжатие zTXT.')
        if len(text) > book.c.MAX_FILE or not decoder.eof or len(text) != length: book.fail('Повреждённый или слишком большой текст zTXT.')
    else:
        book.fail('Этот PDB — не PalmDoc и не zTXT (' + kind.decode('ascii', errors='replace') + '). Контейнер PDB имеет разные несовместимые варианты.')
    paragraphs(book, legacy_decode(text))
    book.warnings.add('PalmDoc/zTXT: переносится текст; исходный формат не хранит обычную книжную вёрстку. Кодировка старых книг определяется автоматически.')


def read_tcr(book, data):
    if not data.startswith(b'!!8-Bit!!'): book.fail('Не найден заголовок TCR.')
    at = 9; dictionary = []
    for _ in range(256):
        if at >= len(data): book.fail('Оборван словарь TCR.')
        size = data[at]; at += 1
        if at + size > len(data): book.fail('Оборвана запись словаря TCR.')
        dictionary.append(data[at:at + size]); at += size
    size = sum(len(dictionary[code]) for code in data[at:])
    if size > book.c.MAX_FILE: book.fail('Распакованный TCR превышает 64 МБ.')
    paragraphs(book, legacy_decode(b''.join(dictionary[code] for code in data[at:])))


def read_wri(book, data):
    if len(data) < 128 or data[:2] not in (b'1\xbe', b'2\xbe'): book.fail('Некорректный заголовок Microsoft Write.')
    end = int.from_bytes(data[14:18], 'little')
    if not 128 <= end <= len(data): book.fail('Повреждённая длина текста Microsoft Write.')
    text = data[128:end]
    if any(ch < 32 and ch not in (9, 10, 12, 13) for ch in text):
        book.fail('Write содержит встроенные объекты или нетекстовые данные. Этот вариант нельзя преобразовать без потерь.')
    paragraphs(book, legacy_decode(text))
    book.warnings.add('Microsoft Write: переносится текст; шрифты и страничное оформление упрощаются.')


def read_mhtml(book, data, read_html):
    message = BytesParser(policy=policy.default).parsebytes(data)
    parts = []; pending = [(message, 0)]; total = 0
    while pending:
        part, depth = pending.pop()
        if depth > 32 or len(parts) + len(pending) > 20000: book.fail('MHTML имеет слишком сложную структуру.')
        if part.is_multipart(): pending.extend((p, depth + 1) for p in reversed(part.get_payload()))
        else:
            payload = part.get_payload(decode=True) or b''; total += len(payload)
            if total > book.c.MAX_TOTAL: book.fail('Распакованный MHTML превышает предел конвертации.')
            parts.append((part, payload))
    html_types = {'text/html', 'application/xhtml+xml'}
    roots = [(p, d) for p, d in parts if p.get_content_type() in html_types | {'text/plain'}]
    start = message.get_param('start')
    if start: roots = [(p, d) for p, d in roots if p.get('Content-ID', '').strip('<>') == start.strip('<>')]
    if not roots: book.fail('В MHTML не найден основной документ.')
    roots.sort(key=lambda entry: entry[0].get_content_type() not in html_types)
    root, html = roots[0]; base = root.get('Content-Location', '')
    document_url = urldefrag(base).url
    resources = {}
    for part, payload in parts:
        for key in (part.get('Content-Location', ''), 'cid:' + part.get('Content-ID', '').strip('<>')):
            if key and key != 'cid:':
                for candidate in (key, urljoin(base, key)):
                    if candidate in resources and resources[candidate] != payload: book.fail('В MHTML повторяется адрес разных вложений.')
                    resources[candidate] = payload
    def embedded_image(href):
        # Content-Location can use the same percent-encoded URI as the HTML.
        payload = resources.get(href, resources.get(urljoin(base, href)))
        if payload is not None: return payload
        key = unquote(href)
        return resources.get(key, resources.get(urljoin(base, key)))
    def image(href):
        if href.startswith('data:'): return original(href)
        label = urlsplit(href).path
        payload = embedded_image(href)
        if payload is None: return book.unreadable_image(label)
        return book.optional_image(payload, label)
    def link(href):
        if href.startswith('#'): return quote(href, safe=":/?#[]@!$&'()*+,;=%")
        location, fragment = urldefrag(urljoin(base, href))
        if document_url and location == document_url and fragment:
            return quote('#' + fragment, safe=":/?#[]@!$&'()*+,;=%")
        if urlsplit(href).scheme.lower() in {'https', 'http', 'mailto'}:
            return quote(href, safe=":/?#[]@!$&'()*+,;=%")
        if href:
            book.warnings.add('Ссылки на другие локальные HTML-файлы не перенесены; конвертируется выбранный документ.')
        return ''
    original = book.local_image; book.local_image = image
    original_link = getattr(book, 'local_link', None); book.local_link = link
    book.has_embedded_html_image = lambda href: embedded_image(href) is not None
    try:
        encoding = root.get_content_charset()
        if root.get_content_type() == 'text/plain':
            if encoding:
                text = html.decode(encoding, errors='replace')
            else:
                try: text = html.decode('utf-8-sig')
                except UnicodeDecodeError: text = html.decode('cp1251', errors='replace')
            book.body.append(book.el('pre', text))
            if '\ufffd' in text: book.warnings.add('Нечитаемые символы HTML отмечены знаком �.')
        else:
            if encoding:
                html = html.decode(encoding, errors='replace').encode('utf-8')
                html = re.sub(br'(?i)(charset\s*=\s*[\'\"]?)[\w-]+', br'\1utf-8', html)
            read_html(book, html)
    finally:
        book.local_image = original
        del book.has_embedded_html_image
        if original_link is None: del book.local_link
        else: book.local_link = original_link
    if sum(part.get_content_type() in html_types for part, _ in roots) > 1:
        book.warnings.add('MHTML содержит несколько HTML-документов; переносится основной документ и его иллюстрации.')


class Contents(HTMLParser):
    def __init__(self): super().__init__(); self.links = []; self.item = {}; self.depth = 0
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'ul': self.depth += 1
        elif tag == 'object': self.item = {}
        elif tag == 'param': self.item[attrs.get('name', '').lower()] = attrs.get('value', '')
    def handle_endtag(self, tag):
        if tag == 'ul': self.depth = max(0, self.depth - 1)
        elif tag == 'object' and self.item.get('local'): self.links.append((self.item['local'], self.item.get('name', ''), self.depth))


def read_chm(book, read_html, decode):
    with __import__('tempfile').TemporaryDirectory(prefix='homelibre-chm-', dir=book.work_root) as temporary:
        read_chm_package(book, read_html, decode, Path(temporary))


def chm_member_path(origin, reference):
    if not reference:
        return origin
    path = unquote(reference).replace('\\', '/')
    return posixpath.normpath(posixpath.join('/', posixpath.dirname(origin), path)).lstrip('/')


def chm_scoped_image_path(origin, reference, target):
    """Rebase a misplaced relative image path within the topic's top-level folder."""
    folder, separator, _ = origin.partition('/')
    if not separator or '/' not in target:
        return None
    parts = unquote(reference).replace('\\', '/').split('/')
    parents = 0
    for part in parts:
        if part != '..':
            break
        parents += 1
    if parents <= origin.count('/') or any(part in {'', '.', '..'} for part in parts[parents:]):
        return None
    return posixpath.join(folder, target)


def chm_transparent_gif_pixel(data):
    """Recognize a complete single-pixel transparent GIF without an image decoder."""
    if len(data) < 39 or not data.startswith(b'GIF89a\x01\x00\x01\x00') or not data[10] & 0x80:
        return False
    colors = 2 << (data[10] & 7)
    blocks = data[13 + 3 * colors:]
    if (len(blocks) < 24 or not blocks.startswith(b'\x21\xf9\x04')
            or not blocks[3] & 1 or blocks[6] >= colors
            or blocks[7:18] != b'\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00'):
        return False
    # Clear code, one literal transparent palette index, then end of image.
    minimum, count = blocks[18:20]
    if not 2 <= minimum <= 8 or blocks[6] >= (1 << minimum):
        return False
    bits = minimum + 1
    if (count != (3 * bits + 7) // 8 or len(blocks) != 22 + count
            or blocks[20 + count:] != b'\x00\x3b'):
        return False
    clear = 1 << minimum
    expected = clear | (blocks[6] << bits) | ((clear + 1) << (2 * bits))
    return int.from_bytes(blocks[20:20 + count], 'little') == expected


def chm_topic_reference(name, decode):
    try:
        address = urlsplit(decode(name))
    except ValueError:
        return '', ''
    if address.scheme or address.netloc or address.query or not address.path:
        return '', ''
    return chm_member_path('', address.path).casefold(), address.fragment


def chm_default_topic(data, decode):
    """Read the compiler's default HTML topic from the #SYSTEM records."""
    if len(data) < 4 or struct.unpack_from('<I', data)[0] not in {2, 3}:
        return '', ''
    topic = None
    offset = 4
    while offset + 4 <= len(data):
        kind, count = struct.unpack_from('<HH', data, offset)
        start, offset = offset + 4, offset + 4 + count
        if offset > len(data):
            return '', ''
        if kind != 2:
            continue
        name, terminator, tail = data[start:offset].partition(b'\0')
        if not name or not terminator or tail.strip(b'\0'):
            return '', ''
        candidate = chm_topic_reference(name, decode)
        if not candidate[0] or (topic is not None and topic != candidate):
            return '', ''
        topic = candidate
    return topic if offset == len(data) and topic is not None else ('', '')


def chm_window_topic(windows, strings, decode):
    """A topic agreed on by the window records can fill an empty #SYSTEM topic."""
    if len(windows) < 8:
        return '', ''
    count, size = struct.unpack_from('<II', windows)
    if not count or size < 0x6c or 8 + count * size > len(windows):
        return '', ''
    topic = None
    for index in range(count):
        offset = struct.unpack_from('<I', windows, 8 + index * size + 0x68)[0]
        if not 0 < offset < len(strings):
            return '', ''
        end = strings.find(b'\0', offset)
        if end <= offset:
            return '', ''
        candidate = chm_topic_reference(strings[offset:end], decode)
        if not candidate[0] or (topic is not None and topic != candidate):
            return '', ''
        topic = candidate
    return topic


def read_chm_package(book, read_html, decode, temporary):
    tool = book.tools_root / '7zip' / '7z.exe'
    if not tool.is_file(): book.require('7-Zip', 'Для чтения CHM нужен компонент 7-Zip.')
    damaged_archive = False
    class UnreadableMember(Exception):
        pass

    def run(args, limit, optional=False, member=False, directory=False):
        nonlocal damaged_archive
        # The enclosing native job limits CPU time/memory and kills child tools
        # on cancellation. Neither executable content nor an HTML engine runs.
        with __import__('tempfile').TemporaryFile() as out:
            try:
                p = subprocess.run([str(tool), '-sccUTF-8', *args], stdout=out, stderr=subprocess.PIPE,
                                   timeout=40, creationflags=0x08000000)
            except subprocess.TimeoutExpired:
                if optional: return None
                book.fail('Чтение CHM превысило 40 секунд.')
            if out.tell() > limit: book.fail('Содержимое CHM превышает предел конвертации.')
            if p.returncode:
                if optional: return None
                details = p.stderr.decode('utf-8', errors='replace')[-500:]
                if member and ('Data Error' in details or 'CRC Failed' in details):
                    raise UnreadableMember
                out.seek(0)
                if directory and p.returncode == 2 and out.read(7) == b'Path = ':
                    damaged_archive = True
                elif not (member and damaged_archive and 'Unexpected end of archive' in details):
                    book.fail('7-Zip не смог прочитать CHM: ' + details)
            out.seek(0); return out.read()
    listing = run(['l', '-slt', '-ba', '--', str(book.source)], 8 * 1024**2, directory=True).decode('utf-8').replace('\r\r\n', '\n').replace('\r\n', '\n')
    if damaged_archive:
        book.warnings.add('Архив CHM повреждён. Сохранены доступные разделы. Часть разделов может отсутствовать в списке архива.')
    entries = {}; sizes = {}; total = 0
    safe_names = {}
    for block in re.split(r'\r?\n\s*\r?\n', listing):
        props = dict(line.split(' = ', 1) for line in block.splitlines() if ' = ' in line)
        if 'Path' not in props: continue
        name = props['Path'].replace('\\', '/'); normalized = posixpath.normpath(name).lstrip('/')
        if '..' in normalized.split('/') or ':' in normalized or '\x00' in normalized: book.fail('Некорректный путь в CHM.')
        size = int(props.get('Size', '0')); total += size
        if size < 0 or size > book.c.MAX_FILE or total > 2 * book.c.MAX_TOTAL or len(entries) >= 20000:
            book.fail('Распакованный CHM слишком велик.')
        if size:
            if normalized.casefold() in entries: book.fail('В CHM повторяется путь документа.')
            entries[normalized.casefold()] = (normalized, props['Path'])
            sizes[normalized.casefold()] = size
            parts = normalized.split('/')
            if (normalized == name and all(part and not part.endswith(('.', ' ')) and
                    not PureWindowsPath(part).is_reserved() and not re.search(r'[<>:"|?*~\x00-\x1f]', part)
                    for part in parts)):
                safe_names[normalized.casefold()] = (normalized, size)
    # CHM compresses many resources together. Reopening the same block for each
    # HTML/image member can turn reading an ordinary book into several minutes.
    extracted = temporary / 'members'
    if not damaged_archive and len(safe_names) >= 16:
        if shutil.disk_usage(temporary).free < total + book.c.MAX_FILE:
            book.fail('Для распаковки большой CHM недостаточно места в рабочей папке.')
        listing_path = temporary / 'members.txt'
        listing_path.write_text('\n'.join(path for path, _ in safe_names.values()), encoding='utf-8')
        result = run(['x', '-y', '-spd', '-scsUTF-8', '-bso0', '-bsp0', f'-o{extracted}',
                      f'-i@{listing_path}', '--', str(book.source)], 1024, optional=True)
        if result is None: safe_names.clear()
    else:
        safe_names.clear()
    def get(path, optional=False):
        key = path.casefold()
        if key not in entries: book.fail('В CHM не найдено вложение: ' + path[:160])
        staged = safe_names.get(key)
        local = extracted / staged[0] if staged else None
        if (local is not None and local.is_file() and local.resolve().is_relative_to(extracted.resolve())
                and local.stat().st_size == staged[1]):
            return local.read_bytes()
        data = run(['e', '-so', '-spd', '--', str(book.source), entries[key][1]], book.c.MAX_FILE,
                   optional=optional, member=True)
        if data is None or len(data) != sizes[key]:
            raise UnreadableMember
        return data

    def optional_metadata(path, limit):
        if 0 < sizes.get(path, 0) <= limit:
            try:
                return get(path, optional=True)
            except UnreadableMember:
                pass
        return b''

    htmls = [p for p, _ in entries.values() if Path(p).suffix.lower() in CHM_HTML_TOPICS]
    if not htmls: book.fail('В CHM нет HTML-текста для конвертации.')
    if sum(sizes[path.casefold()] for path in htmls) > book.c.MAX_FILE:
        if shutil.disk_usage(temporary).free < 2 * total + book.c.MAX_FILE:
            book.fail('Для подготовки большого CHM недостаточно места в рабочей папке.')
        if book.image_store is None:
            book.image_store = Path(book.work_resources.enter_context(
                tempfile.TemporaryDirectory(prefix='homelibre-chm-resources-', dir=book.work_root)))
        book.section_store = []
    order = []
    included = set()
    for p, _ in entries.values():
        if p.lower().endswith('.hhc'):
            try:
                data = get(p)
            except UnreadableMember:
                book.warnings.add('Повреждено оглавление CHM «' + Path(p).name[:100] + '».')
                continue
            try:
                text = decode(data)
            except UnicodeDecodeError:
                text = data.decode('cp1251', errors='replace')
                book.warnings.add('Нечитаемые символы HTML в оглавлении CHM отмечены знаком �.')
            toc = Contents(); toc.feed(text); toc.close()
            for link, label, depth in toc.links:
                address = urlsplit(link)
                if address.scheme or address.netloc:
                    continue
                path = chm_member_path(p, address.path)
                key = path.casefold()
                if key in entries and key not in included and Path(path).suffix.lower() in {'.htm', '.html', '.xhtml', '.shtml'}:
                    order.append((path, label, min(6, max(1, depth))))
                    included.add(key)
            if order: break
    order += [(p, '', 1) for p in sorted(htmls, key=str.casefold) if p.casefold() not in included]
    if not included and len(order) > 1: book.warnings.add('В CHM не найдено оглавление; HTML-разделы расположены по именам файлов.')
    prefixes = {p.casefold(): 'chm-' + str(i) for i, (p, _, _) in enumerate(order)}
    letter_indexes = {path for path in prefixes if CHM_LETTER_INDEX(posixpath.basename(path))}
    original_image, original_body = book.local_image, book.body; title = book.title
    image_sources = {}
    sidebar_pixels = {}
    missing_layout_images = Counter()
    chapter_starts = {}
    new_heading_ids = {}
    topic_headings = {}
    printed_pages = {}
    index_anchors = {}
    index_requests = set()
    numeric_anchor = re.compile(r'[0-9]{1,9}').fullmatch
    printed_page_label = re.compile(r'[0-9]{1,9}(?:\s*[-–—]\s*[0-9]{1,9})?').fullmatch
    numbered_topic = re.compile(r'(.*\b(?:bbl|lib))([0-9]{1,9})(\.html?)').fullmatch
    print_boundary = re.compile(r'beginpage\.(?:-homelibre-[0-9]+)?').fullmatch

    def headings_in(section):
        return (node for node in section.iter() if book.c.html_heading_level(node) and book.c.plain(node))

    def heading_label(value):
        return ' '.join(value.replace(':', ' ').casefold().split())

    def append_section(section):
        if book.section_store is None:
            original_body.append(section)
        else:
            path = book.image_store / f'chapter-{len(book.section_store)}.xml'
            book.clean_xml_text(section)
            ET.ElementTree(section).write(path, encoding='utf-8')
            book.section_store.append(path)

    def section_nodes(rewrite=False):
        files = book.section_store
        for item in original_body if files is None else files:
            if book.cancel_check is not None:
                book.cancel_check()
            section = item if files is None else ET.parse(item).getroot()
            if rewrite and (identities := new_heading_ids.get(section.get('id'))):
                for number, heading in enumerate(headings_in(section)):
                    if number in identities:
                        heading.set('id', identities[number])
            yield from section.iter()
            if rewrite and files is not None:
                ET.ElementTree(section).write(item, encoding='utf-8')

    def image_source(target):
        key = target.casefold()
        if key not in image_sources:
            try:
                data = get(target)
                book.c.check_embedded_raster(data)
                image_sources[key] = book.image(data).get('src')
            except (UnreadableMember, book.c.UnreadableImage):
                image_sources[key] = None
        return image_sources[key]

    def contained_image(path, href, *, layout=False, sidebar=False):
        if href.startswith('data:'):
            return original_image(href)
        parts = urlsplit(href)
        target = chm_member_path(path, parts.path)
        key = target.casefold()
        if parts.scheme or parts.netloc or unquote(parts.path).replace('\\', '/').endswith('/'):
            return book.unreadable_image(parts.path)
        if key not in entries:
            scoped = chm_scoped_image_path(path, parts.path, target)
            if scoped and scoped.casefold() in entries:
                target, key = scoped, scoped.casefold()
        if sidebar and key not in entries and href == '_.gif' and numbered_topic(path.casefold()):
            # Books24x7 sidebar rules omit the images/ directory used by
            # the same bundle's table of contents.
            alternate = posixpath.join(posixpath.dirname(path), 'images', '_.gif')
            alternate_key = alternate.casefold()
            if alternate_key not in sidebar_pixels:
                sidebar_pixels[alternate_key] = False
                if 0 < sizes.get(alternate_key, 0) <= 1024:
                    try:
                        sidebar_pixels[alternate_key] = chm_transparent_gif_pixel(get(alternate))
                    except UnreadableMember:
                        pass
            if sidebar_pixels[alternate_key]:
                target, key = alternate, alternate_key
        # Repeated references share the extracted resource and retain their own markup.
        if key in entries and (source := image_source(target)):
            return book.el('img', src=source, alt='')
        if layout:
            name = entries[key][0] if key in entries else target
            missing_layout_images[name] += 1
            return book.el('span')
        return book.unreadable_image(target if key in entries else parts.path)

    def contained_link(path, href):
        parts = urlsplit(href)
        if parts.scheme or parts.netloc:
            return href
        target = chm_member_path(path, parts.path)
        key = target.casefold()
        fragment = unquote(parts.fragment)
        origin = path.casefold()
        missing_topic = (key not in entries and posixpath.splitext(key)[1] in CHM_HTML_TOPICS
                         and CHM_INDEX_ANCHOR(fragment))
        index_reference = (key in letter_indexes and origin in letter_indexes
                           and posixpath.dirname(key) == posixpath.dirname(origin)
                           and CHM_DOCBOOK_INDEX_ANCHOR(fragment))
        if not parts.query and (missing_topic or index_reference):
            index_requests.add((key, fragment))
        return ('chm-local:' + quote(target, safe='/') + ('?' + parts.query if parts.query else '') +
                ('#' + parts.fragment if parts.fragment else ''))

    try:
        usable_sections = set()
        for index, (path, label, depth) in enumerate(order, 1):
            path_key = path.casefold()
            chapter_prefix = prefixes[path_key]
            section = book.el('section', id=chapter_prefix); book.body = section
            book.local_image = lambda href: contained_image(path, href)
            book.local_layout_image = lambda href: contained_image(path, href, layout=True)
            book.local_sidebar_image = lambda href: contained_image(path, href, sidebar=True)
            # Keep intra-container links; fix targets after all sections exist.
            book.local_link = lambda href: contained_link(path, href)
            try:
                data = get(path)
            except UnreadableMember:
                resource = (label or path)[:160]
                section.append(book.el('p', f'[Раздел «{resource}» не читается.]'))
                book.warnings.add(f'Раздел CHM «{resource}» не читается. На его месте стоит отметка.')
            else:
                read_html(book, data)
                usable_sections.add(path_key)
                headings = list(headings_in(section))
                first_number = next((node.get('id') for node in section.iter()
                                     if numeric_anchor(node.get('id', ''))), None)
                if numbered_topic(path_key) and first_number is not None:
                    # Books24x7 split scrolling HTML topics separately from
                    # their printed pages. A numbered mark beside beginpage
                    # carries the original printed-page position.
                    marks = {}
                    for parent in section.iter():
                        for marker, boundary in zip(parent, parent[1:]):
                            identifier = marker.get('id', '')
                            if (numeric_anchor(identifier) and print_boundary(boundary.get('id', ''))
                                    and book.c.tag(marker) == book.c.tag(boundary) == 'a'
                                    and not book.c.plain(marker) and not book.c.plain(boundary)):
                                marks[identifier] = chapter_prefix + '-' + identifier
                    printed_pages[path_key] = (int(first_number), marks)
            folder = posixpath.dirname(path_key)
            for node in section.iter():
                if node is not section and (identifier := node.get('id')):
                    destination = chapter_prefix + '-' + identifier
                    node.set('id', destination)
                    if CHM_INDEX_ANCHOR(identifier) or (letter_indexes and CHM_DOCBOOK_INDEX_ANCHOR(identifier)):
                        key = (folder, identifier)
                        index_anchors[key] = None if key in index_anchors else (chapter_prefix, destination)
            if path_key in usable_sections:
                labels = {}
                for number, heading in enumerate(headings):
                    normalized = heading_label(book.c.plain(heading))
                    entry = (number, heading.get('id'))
                    labels[normalized] = None if normalized in labels else entry
                    if number == 0 and first_number is not None:
                        title = book.c.plain(heading)
                        chapter_starts[chapter_prefix] = (title, int(first_number), entry)
                if labels:
                    topic_headings[chapter_prefix] = labels
            if label and not any(re.fullmatch('h[1-6]', book.c.tag(n)) for n in section): section.insert(0, book.el('h' + str(depth), label))
            append_section(section)
            if index % 8 == 0 or index == len(order):
                book.progress('preparing-chm', index, len(order))
        if not usable_sections:
            book.fail('В повреждённом CHM нет разделов, которые можно прочитать.')
        for name, count in missing_layout_images.items():
            label = re.sub(r'[\x00-\x1f\x7f]', ' ', name)[:160]
            book.warnings.add(f'Изображение CHM размером 1 × 1 недоступно. Файл «{label}». '
                              f'На его месте в таблицах оставлены пустые места. Число размещений — {count}.')
        anchors = {node.get('id') for node in section_nodes() if node.get('id')}
        folded_anchors = {}
        for anchor in anchors:
            key = anchor.casefold()
            folded_anchors[key] = None if key in folded_anchors else anchor

        moved_topics = {}
        relocated_index = {}
        for path, fragment in index_requests:
            if location := index_anchors.get((posixpath.dirname(path), fragment)):
                prefix, destination = location
                relocated_index[path, fragment] = destination
                if path not in entries:
                    moved_topics.setdefault(path, set()).add(prefix)

        def chapter_anchor(prefix, encoded_fragment):
            if not prefix:
                return None
            if not encoded_fragment:
                return prefix
            literal = prefix + '-' + encoded_fragment
            if literal in anchors:
                return literal
            decoded = prefix + '-' + unquote(encoded_fragment)
            return decoded if decoded in anchors else folded_anchors.get(decoded.casefold())

        def heading_target(prefix, entry):
            number, identity = entry
            if identity:
                return identity
            assigned = new_heading_ids.setdefault(prefix, {})
            if number not in assigned:
                target = prefix + '-heading-' + str(number + 1)
                while target.casefold() in folded_anchors:
                    target += '-h'
                assigned[number] = target
                anchors.add(target)
                folded_anchors[target.casefold()] = target
            return assigned[number]

        def preceding_print_boundary(path, fragment, node):
            if (path not in printed_pages or not numeric_anchor(fragment)
                    or not printed_page_label(book.c.plain(node))):
                return None
            match = numbered_topic(path)
            stem, counter, extension = match.groups()
            if int(counter) == 0:
                return None
            preceding = stem + str(int(counter) - 1).zfill(len(counter)) + extension
            first_number, _ = printed_pages[path]
            if preceding in printed_pages and int(fragment) < first_number:
                return printed_pages[preceding][1].get(fragment)
            return None

        chapter_aliases = {}
        if chapter_starts:
            for parent in section_nodes():
                if len(parent) != 2: continue
                first, second = parent
                if book.c.tag(first) != 'a' or book.c.tag(second) != 'a': continue
                href = first.get('href', '')
                if not href.startswith('chm-local:') or href != second.get('href'): continue
                parts = urlsplit(href[len('chm-local:'):])
                path, fragment = unquote(parts.path).casefold(), unquote(parts.fragment)
                prefix = prefixes.get(path)
                if (prefix not in chapter_starts or parts.query or not numeric_anchor(fragment)
                        or chapter_anchor(prefix, parts.fragment)):
                    continue
                title, first_number, entry = chapter_starts[prefix]
                labels = [heading_label(book.c.plain(link)) for link in (first, second)]
                # Some split books remove the first numbered anchor with the
                # running header. Two adjacent links must jointly spell the
                # actual first heading and its next numeric anchor must agree.
                if not all(labels) or ' '.join(labels) != heading_label(title) or int(fragment) + 1 != first_number:
                    continue
                chapter_aliases[path, fragment] = heading_target(prefix, entry)

        word_note = re.compile(r'(_(?:ftn|edn))(ref)?([0-9]+)', re.I).fullmatch
        note_backlinks = {}
        heading_candidates = {}
        for node in section_nodes():
            if node.tag != '{' + book.c.XH + '}a':
                continue
            identity = node.get('id', '')
            name = identity.rsplit('-', 1)[-1]
            href = node.get('href', '')
            if not href.startswith('chm-local:'):
                continue
            parts = urlsplit(href[len('chm-local:'):])
            path, fragment = unquote(parts.path).casefold(), unquote(parts.fragment)
            prefix = prefixes.get(path)
            if (prefix in topic_headings and not parts.query and numeric_anchor(fragment)
                    and not chapter_anchor(prefix, parts.fragment)):
                label = heading_label(book.c.plain(node))
                # A numeric target can be absent even though the explicitly
                # named heading survives in that same topic.
                entry = topic_headings[prefix].get(label) if any(char.isalpha() for char in label) else None
                if (entry is None and path in printed_pages and prefix in chapter_starts
                        and 'chapterjump' in node.get('class', '').split()):
                    title, first_number, first_heading = chapter_starts[prefix]
                    descriptor, separator, _ = title.partition(':')
                    # This generator links to a chapter by its numbered
                    # caption and leaves the next sequential mark in its body.
                    if (separator and int(fragment) + 1 == first_number
                            and re.fullmatch(r'(?:chapter|part|appendix)\s+[a-z0-9]+', label)
                            and label == heading_label(descriptor)):
                        entry = first_heading
                if entry:
                    heading_candidates.setdefault((path, fragment), set()).add(entry)
            if not (note := word_note(name)):
                continue
            counterpart = note[1] + ('' if note[2] else 'ref') + note[3]
            if fragment.casefold() != counterpart.casefold():
                continue
            source = chapter_anchor(prefix, parts.fragment)
            if source:
                key = (name.casefold(), source)
                note_backlinks[key] = None if key in note_backlinks else identity

        for (path, fragment), candidates in heading_candidates.items():
            if len(candidates) == 1 and (path, fragment) not in chapter_aliases:
                chapter_aliases[path, fragment] = heading_target(prefixes[path], next(iter(candidates)))

        linked_images = {}
        image_sections = []
        missing_links = Counter()
        omitted_attachments = Counter()
        restored_index_links = 0
        restored_topic_links = 0
        restored_print_links = 0
        default_topic = None
        for node in section_nodes(rewrite=True):
            href = node.get('href', '')
            if href.startswith('chm-local:'):
                parts = urlsplit(href[len('chm-local:'):])
                path, fragment = unquote(parts.path), unquote(parts.fragment)
                key = path.casefold()
                # Some CHM publishers put a numeric suffix in the actual image name.
                # Keep it in the lookup key while recognizing the underlying image type.
                extension = re.sub(r';[0-9]+$', '', posixpath.splitext(path)[1]).lower()
                prefix = prefixes.get(key)
                target = chapter_anchor(prefix, parts.fragment)
                if not path:
                    if default_topic is None:
                        default_topic = chm_default_topic(optional_metadata('#system', 65536), decode)
                        if not default_topic[0]:
                            default_topic = chm_window_topic(optional_metadata('#windows', 65536),
                                                             optional_metadata('#strings', 1024 * 1024), decode)
                    topic_path, topic_fragment = default_topic
                    prefix = prefixes.get(topic_path) if topic_path in usable_sections else None
                    target = chapter_anchor(prefix, parts.fragment or topic_fragment)
                if not target and prefix and fragment.casefold() == 'top':
                    target = prefix
                if not target:
                    target = chapter_aliases.get((key, fragment))
                if not target:
                    # Word's split pages can retain an old filename. A uniquely
                    # matching note which links back to this very anchor proves
                    # the relationship without choosing between repeated IDs.
                    target = note_backlinks.get((fragment.casefold(), node.get('id', '')))
                if not target and not parts.query and (key, fragment) in relocated_index:
                    target = relocated_index[key, fragment]
                    restored_index_links += 1
                if not target and fragment and not parts.query and not CHM_INDEX_ANCHOR(fragment) and key in moved_topics:
                    # An exact generated index ID establishes where an older topic
                    # went. Other IDs must be present in one of those topics only.
                    candidates = [prefix + '-' + fragment for prefix in moved_topics[key]]
                    matches = [candidate for candidate in candidates if candidate in anchors]
                    target = matches[0] if len(matches) == 1 else None
                    if target:
                        restored_topic_links += 1
                if not target and not parts.query:
                    target = preceding_print_boundary(key, fragment, node)
                    if target:
                        restored_print_links += 1
                if not prefix and not fragment and key in entries and extension in CHM_LINKED_IMAGES:
                    if book.omit_images:
                        node.attrib.pop('href')
                        continue
                    if key not in linked_images:
                        linked_images[key] = None
                        # A CHM link can open an image in its own view. Put these
                        # targets after the original chapters in both EPUB and FB2.
                        if sizes[key] <= 16 * 1024 * 1024 and (source := image_source(path)):
                            identity = 'chm-image-' + str(len(image_sections) + 1)
                            linked_images[key] = identity
                            section = book.el('section', id=identity)
                            paragraph = book.el('p')
                            paragraph.append(book.el('img', src=source, alt=posixpath.basename(entries[key][0])))
                            section.append(paragraph)
                            image_sections.append(section)
                    target = linked_images[key]
                if target:
                    node.set('href', '#' + quote(target, safe=''))
                else:
                    node.attrib.pop('href')
                    if not fragment and not prefix and key in entries and extension not in CHM_LINKED_IMAGES:
                        omitted_attachments[entries[key][0]] += 1
                    else:
                        missing_links[(path or '/') + ('#' + fragment if fragment else '')] += 1
        for section in image_sections:
            append_section(section)
        if chapter_aliases:
            book.warnings.add(f'В CHM восстановлены переходы к заголовкам глав. Число целей — {len(chapter_aliases)}.')
        if restored_index_links:
            book.warnings.add(f'В CHM восстановлены ссылки предметного указателя. Переходов — {restored_index_links}.')
        if restored_topic_links:
            book.warnings.add(f'В CHM восстановлены переходы к перемещённым разделам. Переходов — {restored_topic_links}.')
        if restored_print_links:
            book.warnings.add(f'В CHM восстановлены переходы к меткам печатных страниц. Переходов — {restored_print_links}.')
        def link_label(address):
            label = re.sub(r'[\x00-\x1f\x7f]', ' ', address)
            return label if len(label) <= 160 else label[:159] + '…'

        if missing_links:
            book.warnings.add('У некоторых ссылок CHM недоступна цель. Текст ссылок сохранён.')
            for address, count in sorted(missing_links.items())[:24]:
                book.warnings.add(f'Не найдена цель ссылки CHM «{link_label(address)}» (переходов {count}).')
            if len(missing_links) > 24:
                book.warnings.add(f'Не найдены остальные цели ссылок CHM ({len(missing_links) - 24}).')
        if omitted_attachments:
            book.warnings.add('Подписи ссылок на вложения сохранены. Файлы можно извлечь из исходного CHM.')
            for address, count in sorted(omitted_attachments.items())[:24]:
                book.warnings.add(f'Вложение CHM «{link_label(address)}» осталось в исходнике (переходов {count}).')
            if len(omitted_attachments) > 24:
                book.warnings.add(f'В исходнике остались другие вложения CHM ({len(omitted_attachments) - 24}).')
    finally:
        book.local_image = original_image; book.body = original_body; book.title = title
        if hasattr(book, 'local_layout_image'): del book.local_layout_image
        if hasattr(book, 'local_sidebar_image'): del book.local_sidebar_image
        if hasattr(book, 'local_link'): del book.local_link


def read(book, extension, read_html, decode):
    if extension in {'.lit','.lrf','.rb'}:read_lit_lrf(book,read_html)
    elif extension == '.chm':
        # The HTML parser has already repaired each chapter. Keep its grid and
        # lists for the reader and EPUB, and let the FB2 writer handle its limits.
        return read_chm(book, read_html, decode)
    else:
        data = book.source.read_bytes()
        if extension in {'.mht', '.mhtml'}: return read_mhtml(book, data, read_html)
        elif extension == '.wri': read_wri(book, data)
        elif extension == '.pdb': read_pdb(book, data)
        elif extension == '.tcr': read_tcr(book, data)
    # Saved web pages use tables/lists for page navigation as well as layout.
    # A reading copy keeps their complete text/images/links in order. Flatten
    # this web layout explicitly; do not emit invalid EPUB or empty FB2 rows.
    for node in list(book.body.iter()):
        name = book.c.tag(node)
        if name in {'ol', 'ul'}:
            number = int(node.get('start', '1')) if node.get('start', '1').lstrip('-').isdigit() else 1
            for child in node:
                if book.c.tag(child) != 'li': continue
                prefix = str(number) + '. ' if name == 'ol' else '• '
                child.text = prefix + (child.text or ''); number += 1
        if name in {'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'ul', 'ol', 'li'}:
            node.tag = '{' + book.c.XH + '}div'
            for key in list(node.attrib):
                if key not in {'id', 'class', 'style'}: node.attrib.pop(key)
            book.warnings.add('Таблицы и списки веб-страницы развёрнуты в последовательность блоков: текст, ссылки, номера пунктов и иллюстрации сохраняются; вёрстка упрощена.')

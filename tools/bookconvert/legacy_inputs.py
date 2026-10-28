"""Small legacy text containers. MIT; no network or source modification."""
from email import policy
from email.parser import BytesParser
from html.parser import HTMLParser
from pathlib import Path
import json
import posixpath
import re
import struct
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urljoin, urlsplit
import zlib
import zipfile

SUPPORTED = {'.mht', '.mhtml', '.wri', '.pdb', '.tcr', '.chm', '.lit', '.lrf', '.rb'}


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
            try:read_html(book,package.read('book.html'))
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
    roots = [(p, d) for p, d in parts if p.get_content_type() == 'text/html']
    start = message.get_param('start')
    if start: roots = [(p, d) for p, d in roots if p.get('Content-ID', '').strip('<>') == start.strip('<>')]
    if not roots: book.fail('В MHTML не найден основной HTML-документ.')
    root, html = roots[0]; base = root.get('Content-Location', '')
    resources = {}
    for part, payload in parts:
        for key in (part.get('Content-Location', ''), 'cid:' + part.get('Content-ID', '').strip('<>')):
            if key and key != 'cid:':
                for candidate in (key, urljoin(base, key)):
                    if candidate in resources and resources[candidate] != payload: book.fail('В MHTML повторяется адрес разных вложений.')
                    resources[candidate] = payload
    def image(href):
        if href.startswith('data:'): return original(href)
        key = unquote(href)
        payload = resources.get(key, resources.get(urljoin(base, key)))
        if payload is None: book.fail('Изображение отсутствует среди вложений MHTML: ' + href[:160])
        return book.image(payload)
    original = book.local_image; book.local_image = image
    try:
        encoding = root.get_content_charset()
        if encoding: html = html.decode(encoding).encode('utf-8'); html = re.sub(br'(?i)(charset\s*=\s*[\'\"]?)[\w-]+', br'\1utf-8', html)
        read_html(book, html)
    finally: book.local_image = original
    if len(roots) > 1: book.warnings.add('MHTML содержит несколько HTML-документов; переносится основной документ и его иллюстрации.')


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
    tool = book.tools_root / '7zip' / '7z.exe'
    if not tool.is_file(): book.require('7-Zip', 'Для чтения CHM нужен компонент 7-Zip.')
    def run(args, limit):
        # The enclosing native job limits CPU time/memory and kills child tools
        # on cancellation. No disk extraction, executable content or HTML engine.
        with __import__('tempfile').TemporaryFile() as out:
            try:
                p = subprocess.run([str(tool), '-sccUTF-8', *args], stdout=out, stderr=subprocess.PIPE,
                                   timeout=40, creationflags=0x08000000)
            except subprocess.TimeoutExpired: book.fail('Чтение CHM превысило 40 секунд.')
            if p.returncode: book.fail('7-Zip не смог прочитать CHM: ' + p.stderr.decode('utf-8', errors='replace')[-500:])
            if out.tell() > limit: book.fail('Содержимое CHM превышает предел конвертации.')
            out.seek(0); return out.read()
    listing = run(['l', '-slt', '-ba', '--', str(book.source)], 8 * 1024**2).decode('utf-8').replace('\r\r\n', '\n').replace('\r\n', '\n')
    entries = {}; total = 0
    for block in re.split(r'\r?\n\s*\r?\n', listing):
        props = dict(line.split(' = ', 1) for line in block.splitlines() if ' = ' in line)
        if 'Path' not in props: continue
        name = props['Path'].replace('\\', '/'); normalized = posixpath.normpath(name).lstrip('/')
        if '..' in normalized.split('/') or ':' in normalized or '\x00' in normalized: book.fail('Некорректный путь в CHM.')
        size = int(props.get('Size', '0')); total += size
        if size > book.c.MAX_FILE or total > book.c.MAX_TOTAL or len(entries) >= 20000: book.fail('Распакованный CHM слишком велик.')
        if size:
            if normalized.casefold() in entries: book.fail('В CHM повторяется путь документа.')
            entries[normalized.casefold()] = (normalized, props['Path'])
    cache = {}; loaded = 0
    def get(path):
        nonlocal loaded
        key = posixpath.normpath(unquote(path).replace('\\', '/')).lstrip('/').casefold()
        if key not in entries: book.fail('В CHM не найдено вложение: ' + path[:160])
        if key not in cache:
            cache[key] = run(['e', '-so', '-spd', '--', str(book.source), entries[key][1]], book.c.MAX_FILE)
            loaded += len(cache[key])
            if loaded > book.c.MAX_TOTAL: book.fail('Содержимое CHM слишком велико.')
        return cache[key]
    htmls = [p for p, _ in entries.values() if Path(p).suffix.lower() in {'.htm', '.html', '.xhtml', '.shtml'}]
    if not htmls: book.fail('В CHM нет HTML-текста для конвертации.')
    order = []
    for p, _ in entries.values():
        if p.lower().endswith('.hhc'):
            toc = Contents(); toc.feed(decode(get(p))); toc.close()
            for link, label, depth in toc.links:
                path = posixpath.normpath(posixpath.join(posixpath.dirname(p), unquote(urlsplit(link).path))).lstrip('/')
                if path.casefold() in entries and Path(path).suffix.lower() in {'.htm', '.html', '.xhtml', '.shtml'}:
                    if not any(x[0].casefold() == path.casefold() for x in order): order.append((path, label, min(6, max(1, depth))))
            if order: break
    included = {p.casefold() for p, _, _ in order}
    order += [(p, '', 1) for p in sorted(htmls, key=str.casefold) if p.casefold() not in included]
    if not included and len(order) > 1: book.warnings.add('В CHM не найдено оглавление; HTML-разделы расположены по именам файлов.')
    prefixes = {p.casefold(): 'chm-' + str(i) for i, (p, _, _) in enumerate(order)}
    original_image, original_body = book.local_image, book.body; title = book.title
    try:
        for path, label, depth in order:
            section = book.el('section', id=prefixes[path.casefold()]); book.body = section
            book.local_image = lambda href: original_image(href) if href.startswith('data:') else book.image(get(posixpath.join(posixpath.dirname(path), urlsplit(href).path)))
            # Keep intra-container links; fix targets after all sections exist.
            book.local_link = lambda href: href if urlsplit(href).scheme else 'chm-local:' + posixpath.join(posixpath.dirname(path), href)
            read_html(book, get(path))
            for node in section.iter():
                if node is not section and node.get('id'): node.set('id', prefixes[path.casefold()] + '-' + node.get('id'))
            if label and not any(re.fullmatch('h[1-6]', book.c.tag(n)) for n in section): section.insert(0, book.el('h' + str(depth), label))
            original_body.append(section)
        for node in original_body.iter():
            href = node.get('href', '')
            if href.startswith('chm-local:'):
                parts = urlsplit(href[len('chm-local:'):]); key = posixpath.normpath(unquote(parts.path)).lstrip('/').casefold()
                prefix = prefixes.get(key)
                if prefix: node.set('href', '#' + prefix + ('-' + unquote(parts.fragment) if parts.fragment else ''))
                else: node.attrib.pop('href'); book.warnings.add('Некоторые служебные ссылки CHM не имеют текстового раздела и не перенесены.')
    finally:
        book.local_image = original_image; book.body = original_body; book.title = title
        if hasattr(book, 'local_link'): del book.local_link


def read(book, extension, read_html, decode):
    if extension in {'.lit','.lrf','.rb'}:read_lit_lrf(book,read_html)
    elif extension == '.chm': read_chm(book, read_html, decode)
    else:
        data = book.source.read_bytes()
        if extension in {'.mht', '.mhtml'}: read_mhtml(book, data, read_html)
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

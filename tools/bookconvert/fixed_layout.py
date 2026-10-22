"""Reflow readable PDF/DjVu text, preserving detected illustration regions.

MIT. Uses only the PDFium and DjVuLibre already shipped with HomeLib Ru.
No OCR, network requests, source edits or new third-party runtime.
"""
import ctypes as C
from pathlib import Path
import re
import statistics
import struct
import subprocess
import tempfile
import unicodedata
import zlib

SUPPORTED = {'.pdf', '.djvu', '.djv', '.dju', '.djvm', '.djm'}


def png(rgb, width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\0' + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def readable(text):
    chars = [ch for ch in text if not ch.isspace()]
    bad = sum(ch == '\ufffd' or unicodedata.category(ch) in {'Co', 'Cs', 'Cc', 'Cn'} for ch in chars)
    letters = sum(ch.isalpha() for ch in chars)
    # Quality gate catches broken character maps, not spelling/OCR mistakes.
    return letters >= 3 and bad <= max(1, len(chars) * .02) and letters >= len(chars) * .30


def order_lines(lines):
    """Recursive whitespace cuts: retain headers, then read columns separately."""
    if len(lines) < 3: return sorted(lines, key=lambda n: (n['box'][1], n['box'][0]))
    heights = [n['box'][3] - n['box'][1] for n in lines if n['box'][3] > n['box'][1]]
    typical = statistics.median(heights) if heights else 10
    def gap(axis):
        spans = sorted((n['box'][axis], n['box'][axis + 2]) for n in lines)
        end = spans[0][1]; best = (0, 0)
        for left, right in spans[1:]:
            if left - end > best[0]: best = (left - end, (left + end) / 2)
            end = max(end, right)
        return best
    vertical, horizontal = gap(0), gap(1)
    # A column gutter must be much wider than ordinary letter/word spacing.
    if vertical[0] > typical * 1.6:
        axis, cut = 0, vertical[1]
    elif horizontal[0] > typical * .7:
        axis, cut = 1, horizontal[1]
    else: return sorted(lines, key=lambda n: (round(n['box'][1] / max(1, typical * .4)), n['box'][0]))
    left = [n for n in lines if n['box'][axis] < cut]; right = [n for n in lines if n['box'][axis] >= cut]
    if not left or not right: return lines
    return order_lines(left) + order_lines(right)


def illustration_regions(rgb, width, height, lines, page_width, page_height):
    """Find non-text ink on a small grid; crop from the untouched render.

    This is layout analysis, not OCR. Text boxes mask only the analysis image.
    Original pixels (including labels in diagrams) remain in each illustration.
    """
    cell = max(3, round(max(width, height) / 300)); gw = (width + cell - 1) // cell; gh = (height + cell - 1) // cell
    mask = bytearray(gw * gh)
    sx, sy = width / page_width, height / page_height
    for line in lines:
        l, t, r, b = line['box']
        x0, x1 = max(0, int((l * sx - 2) // cell)), min(gw, int((r * sx + 2) // cell) + 1)
        y0, y1 = max(0, int((t * sy - 2) // cell)), min(gh, int((b * sy + 2) // cell) + 1)
        for y in range(y0, y1): mask[y * gw + x0:y * gw + x1] = b'\1' * (x1 - x0)
    # Scan paper can be yellow/grey. Estimate paper from the four corner areas.
    corners = []
    for y in (height // 30, height - 1 - height // 30):
        for x in (width // 30, width - 1 - width // 30):
            at = (y * width + x) * 3; corners.append(rgb[at:at + 3])
    paper = [statistics.median(p[k] for p in corners) for k in range(3)]
    # Classify channels in the interpreter's native byte operations. OR the
    # 0/1 bytes as integers (there are no carries) to get one flag per pixel.
    # This preserves the exact >48 threshold, including fractional medians.
    channels = [rgb[k::3].translate(bytes(int(abs(value - paper[k]) > 48)
                                        for value in range(256))) for k in range(3)]
    dark = (int.from_bytes(channels[0], 'little') |
            int.from_bytes(channels[1], 'little') |
            int.from_bytes(channels[2], 'little')).to_bytes(width * height, 'little')
    ink = bytearray(gw * gh); total_ink = 0
    for gy in range(gh):
        for gx in range(gw):
            pos = gy * gw + gx
            if mask[pos]: continue
            count = 0
            for y in range(gy * cell, min(height, (gy + 1) * cell), 2):
                count += dark[y * width + gx * cell:y * width + min(width, (gx + 1) * cell):2].count(1)
            if count >= 2: ink[pos] = 1; total_ink += 1
    regions = []
    for pos in range(len(ink)):
        if not ink[pos]: continue
        stack = [pos]; ink[pos] = 0; xs = []; ys = []
        while stack:
            p = stack.pop(); x, y = p % gw, p // gw; xs.append(x); ys.append(y)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < gw and 0 <= yy < gh and ink[yy * gw + xx]:
                        ink[yy * gw + xx] = 0; stack.append(yy * gw + xx)
        l, t, r, b = min(xs) * cell, min(ys) * cell, min(width, (max(xs) + 1) * cell), min(height, (max(ys) + 1) * cell)
        # Discard isolated punctuation, rules and scan-edge noise, not pictures.
        if len(xs) >= 25 and r - l >= width * .035 and b - t >= height * .018:
            regions.append((max(0, l - cell), max(0, t - cell), min(width, r + cell), min(height, b + cell)))
    # Coalesce nearby fragments of a figure before embedding it.
    changed = True
    while changed:
        changed = False; merged = []
        for region in regions:
            for i, other in enumerate(merged):
                gap = cell * 3
                if region[0] <= other[2] + gap and region[2] + gap >= other[0] and region[1] <= other[3] + gap and region[3] + gap >= other[1]:
                    merged[i] = (min(region[0], other[0]), min(region[1], other[1]), max(region[2], other[2]), max(region[3], other[3])); changed = True; break
            else: merged.append(region)
        regions = merged
    return sorted(regions, key=lambda r: (r[1], r[0])), total_ink / max(1, gw * gh)


def emit_page(book, number, lines, rgb, width, height, page_width, page_height):
    lines = [n for n in lines if n['text'].strip()]
    text = '\n'.join(n['text'] for n in lines)
    if text.strip() and not readable(text): book.fail(f'На странице {number} непригодный текстовый слой. Проверьте распознавание или кодировку PDF/DjVu.')
    # A sparse bad OCR glyph must not invalidate XML for the entire book.
    # Keep its position AND original code visible, rather than guessing a
    # letter or silently removing it. Apply the quality gate above first.
    invalid = {ch for ch in text if (ord(ch) < 32 and ch not in '\t\r\n') or ord(ch) in {0xfffe, 0xffff}}
    if invalid:
        replacements = {ch: f'[OCR U+{ord(ch):04X}]' for ch in invalid}
        lines = [{**line, 'text': ''.join(replacements.get(ch, ch) for ch in line['text'])} for line in lines]
        book.warnings.add(f'Страница {number}: нечитаемые символы исходного текстового слоя помечены ' +
                          ', '.join(replacements[ch] for ch in sorted(invalid)) + '. Сверьте эти места с оригиналом.')
    regions, ink = illustration_regions(rgb, width, height, lines, page_width, page_height)
    if not text.strip():
        if ink < .002: return 0
        # Do not silently turn a missing OCR page in the middle into a picture.
        if number != 1: book.fail(f'На странице {number} есть изображение, но нет пригодного текста. Это может быть нераспознанный скан. Конвертация остановлена, чтобы не потерять текст.')
        regions = [(0, 0, width, height)]
    section = book.el('section', id='page-' + str(number)); book.body.append(section)
    events = [(n['box'][1], 'text', n) for n in order_lines(lines)]
    # Reading order is decided by columns, so place each illustration before the
    # closest following line rather than globally re-sorting the text by Y.
    for l, t, r, b in regions:
        crop = b''.join(rgb[(y * width + l) * 3:(y * width + r) * 3] for y in range(t, b))
        image = book.image(png(crop, r - l, b - t)); image.set('alt', 'Иллюстрация, страница ' + str(number))
        insert = next((i for i, (_, kind, n) in enumerate(events) if kind == 'text' and n['box'][1] >= b * page_height / height), len(events))
        events.insert(insert, (t * page_height / height, 'image', image))
    for _, kind, item in events:
        if kind == 'image':
            p = book.el('p'); p.append(item); section.append(p)
        else:
            p = book.el('p'); text = item['text'].strip()
            if item.get('bold'): p.append(book.el('strong', text))
            elif item.get('italic'): p.append(book.el('em', text))
            else: p.text = text
            section.append(p)
    return sum(ch.isalpha() for ch in text) if not lines else sum(ch.isalpha() for n in lines for ch in n['text'])


class PDF:
    def __init__(self, tools, fail):
        path = tools / 'pdfium' / 'pdfium.dll'
        if not path.is_file(): fail('Не найден встроенный PDFium.')
        try: self.dll = C.WinDLL(str(path))
        except OSError: fail('PDFium не удалось загрузить. Проверьте комплектность и разрядность программы.')
        P, I, D, F = C.c_void_p, C.c_int, C.c_double, C.c_float
        signatures = {
            'FPDF_InitLibrary': (None, []), 'FPDF_DestroyLibrary': (None, []),
            'FPDF_LoadMemDocument64': (P, [P, C.c_size_t, C.c_char_p]), 'FPDF_CloseDocument': (None, [P]),
            'FPDF_GetPageCount': (I, [P]), 'FPDF_LoadPage': (P, [P, I]), 'FPDF_ClosePage': (None, [P]),
            'FPDF_GetPageWidth': (D, [P]), 'FPDF_GetPageHeight': (D, [P]),
            'FPDFText_LoadPage': (P, [P]), 'FPDFText_ClosePage': (None, [P]),
            'FPDFText_CountChars': (I, [P]), 'FPDFText_GetUnicode': (C.c_uint, [P, I]),
            'FPDFText_GetCharBox': (I, [P, I, *[C.POINTER(D)] * 4]),
            'FPDFText_GetFontSize': (D, [P, I]), 'FPDFText_GetFontWeight': (I, [P, I]),
            'FPDFBitmap_Create': (P, [I, I, I]), 'FPDFBitmap_Destroy': (None, [P]),
            'FPDFBitmap_FillRect': (I, [P, I, I, I, I, C.c_uint]),
            'FPDFBitmap_GetBuffer': (P, [P]), 'FPDFBitmap_GetStride': (I, [P]),
            'FPDF_RenderPageBitmap': (None, [P, P, I, I, I, I, I, I]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.dll, name); function.restype = result; function.argtypes = args; setattr(self, name, function)

    def page(self, page, fail):
        width, height = self.FPDF_GetPageWidth(page), self.FPDF_GetPageHeight(page)
        if not 0 < width < 100000 or not 0 < height < 100000: fail('Некорректные размеры страницы PDF.')
        text = self.FPDFText_LoadPage(page)
        if not text: fail('Не удалось прочитать текст страницы PDF.')
        lines = []; chars = []; boxes = []; weights = []; hidden = False
        def flush():
            if chars and ''.join(chars).strip() and boxes:
                lines.append({'text': ''.join(chars), 'box': (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)),
                              'bold': bool(weights) and statistics.median(weights) >= 600})
            chars.clear(); boxes.clear(); weights.clear()
        try:
            count = self.FPDFText_CountChars(text)
            if not 0 <= count <= 1000000: fail('Текстовая страница PDF слишком сложна.')
            for i in range(count):
                code = self.FPDFText_GetUnicode(text, i)
                if code > 0x10ffff: code = 0xfffd
                ch = chr(code)
                if ch in '\r\n': flush(); continue
                if not code: ch = '\ufffd'
                if code < 32 and ch != '\t': ch = '\ufffd'
                l, r, b, t = C.c_double(), C.c_double(), C.c_double(), C.c_double()
                if not self.FPDFText_GetCharBox(text, i, C.byref(l), C.byref(r), C.byref(b), C.byref(t)): continue
                box = (l.value, height - t.value, r.value, height - b.value)
                if box[2] < 0 or box[0] > width or box[3] < 0 or box[1] > height: continue
                size = max(1, self.FPDFText_GetFontSize(text, i))
                if boxes and not ch.isspace() and (abs(box[1] - boxes[-1][1]) > size * .7 or box[0] - boxes[-1][2] > size * 3 or box[2] < boxes[-1][0] - size): flush()
                chars.append(ch)
                if not ch.isspace(): boxes.append(box); weights.append(self.FPDFText_GetFontWeight(text, i))
            flush()
        finally: self.FPDFText_ClosePage(text)
        scale = min(2, 1600 / max(width, height)); w, h = max(1, round(width * scale)), max(1, round(height * scale))
        bitmap = self.FPDFBitmap_Create(w, h, 0)
        if not bitmap: fail('Недостаточно памяти для иллюстраций PDF.')
        try:
            self.FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xffffffff)
            self.FPDF_RenderPageBitmap(bitmap, page, 0, 0, w, h, 0, 0)
            stride = self.FPDFBitmap_GetStride(bitmap); data = C.string_at(self.FPDFBitmap_GetBuffer(bitmap), stride * h)
            rgb = bytearray(w * h * 3)
            for y in range(h):
                row = data[y * stride:y * stride + w * 4]
                rgb[y * w * 3:(y + 1) * w * 3:3] = row[2::4]
                rgb[y * w * 3 + 1:(y + 1) * w * 3:3] = row[1::4]
                rgb[y * w * 3 + 2:(y + 1) * w * 3:3] = row[0::4]
            return lines, rgb, w, h, width, height, hidden
        finally: self.FPDFBitmap_Destroy(bitmap)


def read_pdf(book, tools):
    api = PDF(tools, book.fail); api.FPDF_InitLibrary()
    try:
        data = book.source.read_bytes(); buffer = C.create_string_buffer(data)
        document = api.FPDF_LoadMemDocument64(buffer, len(data), None)
        if not document: book.fail('PDF повреждён или защищён паролем. Текст не прочитан.')
        try:
            count = api.FPDF_GetPageCount(document)
            if not 0 < count <= 5000: book.fail('Недопустимое число страниц PDF (предел 5000).')
            book.progress('pages', 0, count)
            letters = 0
            for i in range(count):
                page = api.FPDF_LoadPage(document, i)
                if not page: book.fail(f'Не удалось открыть страницу PDF {i + 1}.')
                try:
                    lines, rgb, w, h, pw, ph, hidden = api.page(page, book.fail)
                    letters += emit_page(book, i + 1, lines, rgb, w, h, pw, ph)
                    if any('\ufffd' in line['text'] for line in lines):
                        book.warnings.add('В PDF встречаются символы без пригодного Unicode-соответствия; они отмечены знаком �. Проверьте эти места в оригинале.')
                    book.warnings.add('Текстовый слой PDF может содержать результат OCR. Возможны ошибки распознавания; сверьте важные цитаты с оригиналом.')
                finally: api.FPDF_ClosePage(page)
                book.progress('pages', i + 1, count)
            if letters < 20: book.fail('В PDF нет пригодного для чтения текста. Сканы без текстового слоя не конвертируются.')
        finally: api.FPDF_CloseDocument(document)
    finally: api.FPDF_DestroyLibrary()


def sexpressions(text, fail):
    tokens = re.finditer(r'\(|\)|"(?:\\.|[^"\\])*"|[^\s()]+', text.lstrip('\ufeff'))
    roots = []; stack = []; nodes = 0
    for token in tokens:
        item = token[0]; nodes += 1
        if nodes > 3000000 or len(stack) > 64: fail('Текст DjVu слишком сложен.')
        if item == '(':
            value = []
            if stack: stack[-1].append(value)
            else: roots.append(value)
            stack.append(value)
        elif item == ')':
            if not stack: fail('Повреждён текстовый слой DjVu.')
            stack.pop()
        elif stack:
            if item.startswith('"'):
                # DjVu C escapes include octal bytes (UTF-8) as well as Unicode.
                value = bytearray()
                for match in re.finditer(r'\\([0-7]{1,3}|.)|([^\\]+)', item[1:-1]):
                    escape = match[1]
                    if escape and re.fullmatch('[0-7]{1,3}', escape):
                        code = int(escape, 8)
                        if code > 255: fail('Некорректная escape-последовательность DjVu.')
                        value.append(code)
                    else: value.extend(({'n':'\n', 'r':'\r', 't':'\t'}.get(escape, escape) if escape else match[2]).encode('utf-8'))
                try: stack[-1].append(value.decode('utf-8'))
                except UnicodeError: fail('Текстовый слой DjVu имеет некорректную UTF-8 кодировку.')
            else:
                try: stack[-1].append(int(item))
                except ValueError: stack[-1].append(item)
    if stack: fail('Оборван текстовый слой DjVu.')
    return roots


def ppm(data, fail):
    at = 0; fields = []
    while len(fields) < 4:
        match = re.match(br'\s*(?:#[^\r\n]*(?:\r?\n)|([^\s#]+))', data[at:])
        if not match: fail('Некорректный растр DjVu.')
        at += match.end()
        if match[1]: fields.append(match[1])
    if fields[0] != b'P6' or fields[3] != b'255': fail('Неподдерживаемый растр DjVu.')
    width, height = int(fields[1]), int(fields[2])
    if not 0 < width <= 1600 or not 0 < height <= 1600: fail('Слишком большой растр DjVu.')
    if data[at:at + 2] == b'\r\n': at += 2
    elif data[at:at + 1].isspace(): at += 1
    else: fail('Оборван заголовок растра DjVu.')
    if len(data) - at != width * height * 3: fail('Оборван растр DjVu.')
    return data[at:], width, height


def read_djvu(book, tools):
    used, renderer = tools / 'djvu' / 'djvused.exe', tools / 'djvu' / 'ddjvu.exe'
    if not used.is_file() or not renderer.is_file(): book.fail('Не найден встроенный DjVuLibre.')
    def run(args, limit):
        with tempfile.TemporaryFile() as out:
            try: result = subprocess.run([str(a) for a in args], stdout=out, stderr=subprocess.PIPE, timeout=40, creationflags=0x08000000)
            except subprocess.TimeoutExpired: book.fail('Чтение страницы DjVu превысило 40 секунд.')
            if result.returncode: book.fail('DjVuLibre не смог прочитать документ: ' + result.stderr.decode('utf-8', errors='replace')[-500:])
            if out.tell() > limit: book.fail('Текст или растр DjVu превышает предел конвертации.')
            out.seek(0); return out.read()
    count = int(run([used, '-n', '-e', 'n', book.source], 1024).decode('utf-8-sig').strip())
    if not 0 < count <= 5000: book.fail('Недопустимое число страниц DjVu (предел 5000).')
    book.progress('pages', 0, count)
    def page_size(number):
        size = run([used, '-n', '-e', f'select {number}; size', book.source], 1024).decode('utf-8-sig')
        match = re.search(r'width=(\d+)\s+height=(\d+)', size)
        if not match or any(int(value) <= 0 for value in match.groups()):
            book.fail('Не удалось определить размер страницы DjVu.')
        return tuple(map(int, match.groups()))
    letters = 0
    for i in range(count):
        raw = run([used, '-n', '-u', '-e', f'select {i + 1}; print-txt', book.source], book.c.MAX_FILE).decode('utf-8-sig')
        roots = sexpressions(raw, book.fail); lines = []
        if roots and len(roots[0]) >= 5 and roots[0][0] == 'page':
            page = roots[0]; pw, ph = page[3], page[4]
            # DjVuLibre can expose an empty OCR page as (page 0 0 0 0).
            # The image still has valid dimensions; use its geometry so the
            # normal no-text/scan check reports the limitation without a crash.
            if pw <= 0 or ph <= 0: pw, ph = page_size(i + 1)
            def collect(node):
                if not isinstance(node, list) or len(node) < 5: return
                if node[0] == 'line':
                    words = []
                    def words_of(n):
                        for value in n[5:]:
                            if isinstance(value, list): words_of(value)
                            elif isinstance(value, str): words.append(value)
                    words_of(node)
                    lines.append({'text': ' '.join(words), 'box': (node[1], ph - node[4], node[3], ph - node[2])})
                else:
                    for child in node[5:]: collect(child)
            collect(page)
        else:
            pw, ph = page_size(i + 1)
        raster = run([renderer, '-format=ppm', '-page=' + str(i + 1), '-size=1600x1600', book.source], 1600 * 1600 * 3 + 1024)
        rgb, w, h = ppm(raster, book.fail)
        letters += emit_page(book, i + 1, lines, rgb, w, h, pw, ph)
        book.progress('pages', i + 1, count)
    if letters < 20: book.fail('В DjVu нет пригодного для чтения текста. Сканы без текстового слоя не конвертируются.')
    book.warnings.add('Текстовый слой DjVu обычно получен OCR. Возможны ошибки распознавания; сверьте важные цитаты с оригиналом.')


def read(book, extension):
    tools = book.tools_root
    if extension == '.pdf': read_pdf(book, tools)
    else: read_djvu(book, tools)
    book.warnings.add('PDF/DjVu: текст перенесён в порядке чтения, строки и обнаруженные области иллюстраций сохранены. Страничная вёрстка, сложные таблицы и формулы могут отличаться; проверьте результат по оригиналу.')

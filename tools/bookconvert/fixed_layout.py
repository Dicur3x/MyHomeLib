"""Reflow readable PDF/DjVu text, preserving detected illustration regions.

MIT. Uses only the PDFium and DjVuLibre already shipped with HomeLib Ru.
No OCR, network requests, source edits or new third-party runtime.
"""
from collections import defaultdict
from contextlib import ExitStack, contextmanager
import ctypes as C
import importlib.util
from math import ceil, floor, isfinite
import os
from pathlib import Path
import re
import statistics
import struct
import subprocess
import tempfile
import unicodedata
from urllib.parse import quote, unquote, urlsplit
import zlib

SUPPORTED = {'.pdf', '.djvu', '.djv', '.dju', '.djvm', '.djm'}
PDF_PAGES_PER_DOCUMENT = 24


def png_up(samples, stride):
    # PNG's Up filter stores the difference from the previous row.
    # Use each high bit as a borrow guard for independent byte subtraction.
    high_bits = int.from_bytes(b'\x80' * stride, 'little')
    low_bits = int.from_bytes(b'\x7f' * stride, 'little')
    compressor = zlib.compressobj()
    previous = 0
    compressed = bytearray()
    for start in range(0, len(samples), stride):
        row = int.from_bytes(samples[start:start + stride], 'little')
        delta = ((row | high_bits) - (previous & low_bits)) ^ ((row ^ previous ^ high_bits) & high_bits)
        compressed.extend(compressor.compress(b'\x02' + delta.to_bytes(stride, 'little')))
        previous = row
    compressed.extend(compressor.flush())
    return compressed


def png(rgb, width, height, *, alpha=None):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    gray = rgb[::3]
    if alpha is not None:
        color_type = 6
        rgba = bytearray(width * height * 4)
        for channel in range(3):
            rgba[channel::4] = rgb[channel::3]
        rgba[3::4] = alpha
        compressed = png_up(rgba, width * 4)
    elif gray == rgb[1::3] and gray == rgb[2::3]:
        color_type = 0
        compressed = png_up(gray, width)
    else:
        color_type = 2
        stride = width * 3
        rows = b''.join(b'\0' + rgb[start:start + stride] for start in range(0, len(rgb), stride))
        compressed = zlib.compress(rows)
        if len(rgb) >= 256 * 1024:
            # Large color scans often have similar adjacent rows. Keep the
            # shorter lossless encoding, without changing pixels or dimensions.
            predicted = png_up(rgb, stride)
            if len(predicted) < len(compressed):
                compressed = predicted
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color_type, 0, 0, 0)) + chunk(b'IDAT', compressed) + chunk(b'IEND', b'')


def readable(text, plain_text=False):
    chars = [ch for ch in text if not ch.isspace()]
    bad = sum(ch == '\ufffd' or unicodedata.category(ch) in {'Co', 'Cs', 'Cc', 'Cn'} for ch in chars)
    if plain_text:
        # A native text layer can contain a short label or a numeric table.
        return any(ch.isalnum() for ch in chars) and bad <= max(1, len(chars) * .02)
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


def unreadable_page(book, number, saved_text=False):
    section = book.el('section', id='page-' + str(number))
    message = (f'[Изображение страницы {number} не читается. Текст сохранён.]' if saved_text
               else f'[Страница {number} не читается.]')
    section.append(book.el('p', message))
    book.body.append(section)
    return section


def original_scan_line(book, rgb, width, height, page_width, page_height, box, number, source_format):
    sx, sy = width / page_width, height / page_height
    l, t, r, b = box
    if not all(map(isfinite, box)):
        return None
    l, r = max(0, floor(l * sx) - 2), min(width, ceil(r * sx) + 2)
    t, b = max(0, floor(t * sy) - 2), min(height, ceil(b * sy) + 2)
    if r <= l or b <= t:
        return None
    pixels = b''.join(rgb[(y * width + l) * 3:(y * width + r) * 3] for y in range(t, b))
    if pixels == pixels[:3] * ((r - l) * (b - t)):
        return None
    image = book.fixed_illustration(png(pixels, r - l, b - t))
    image.set('alt', f'Исходная строка {source_format}, страница {number}')
    return image


def emit_page(book, number, lines, rgb, width, height, page_width, page_height, *,
              missing_raster=False, saved_source_lines=None, djvu_control_pages=None,
              source_format='PDF', preserve_line_order=False):
    lines = [n for n in lines if n['text'].strip(' \t\r\n')]
    text = '\n'.join(n['text'] for n in lines)
    # A missing or unusable OCR layer is not a reason to discard a readable
    # page. Preserve the complete rendered page, never fabricate searchable
    # text or keep a misleading fragment of the broken character map.
    if not readable(text, book.omit_images):
        if missing_raster:
            unreadable_page(book, number)
            return 0
        if book.omit_images:
            section = book.el('section', id='page-' + str(number))
            section.append(book.el('p', f'[Страница {number} без пригодного текстового слоя]'))
            book.body.append(section)
            book.missing_text_pages = getattr(book, 'missing_text_pages', 0) + 1
            return 0
        book.scan_page(png(rgb,width,height),number,getattr(book,'page_count',number))
        book.fixed_image_pages=getattr(book,'fixed_image_pages',0)+1
        book.warnings.add('Страницы без пригодного текстового слоя сохранены изображениями. Поиск и изменение размера текста на этих страницах недоступны; для текста требуется OCR.')
        return 0
    # A sparse bad OCR glyph must not invalidate XML for the entire book.
    # Keep its position AND original code visible, rather than guessing a
    # letter or silently removing it. Apply the quality gate above first.
    invalid = {ch for ch in text if (ord(ch) < 32 and ch not in '\t\r\n') or ord(ch) in {0xfffe, 0xffff}}
    if invalid:
        replacements = {ch: f'[OCR U+{ord(ch):04X}]' for ch in invalid}
        lines = [{**line, 'text': ''.join(replacements.get(ch, ch) for ch in line['text']),
                  'invalid_control': not invalid.isdisjoint(line['text'])} for line in lines]
    keep_full_scan = (not book.omit_images and not missing_raster and
                      any(line.get('coarse_zone') for line in lines))
    regions = []
    if not book.omit_images and not missing_raster and not keep_full_scan:
        regions, _ = illustration_regions(rgb, width, height, lines, page_width, page_height)
    if missing_raster:
        section = unreadable_page(book, number, saved_text=True)
    elif keep_full_scan:
        section = book.scan_page(png(rgb,width,height), number, getattr(book,'page_count',number))
        book.fixed_image_pages = getattr(book,'fixed_image_pages',0) + 1
        section.append(book.el('p', 'Текстовый слой страницы', style='font-weight:bold'))
        book.warnings.add('Страницы DjVu без координат строк сохранены целиком изображениями вместе с текстовым слоем.')
    else:
        section = book.el('section', id='page-' + str(number)); book.body.append(section)
    reading_order = lines if preserve_line_order else order_lines(lines)
    events = [(n['box'][1], 'text', n) for n in reading_order]
    # Reading order is decided by columns, so place each illustration before the
    # closest following line rather than globally re-sorting the text by Y.
    for l, t, r, b in regions:
        crop = b''.join(rgb[(y * width + l) * 3:(y * width + r) * 3] for y in range(t, b))
        image = book.fixed_illustration(png(crop, r - l, b - t)); image.set('alt', 'Иллюстрация, страница ' + str(number))
        insert = next((i for i, (_, kind, n) in enumerate(events) if kind == 'text' and n['box'][1] >= b * page_height / height), len(events))
        events.insert(insert, (t * page_height / height, 'image', image))
    copied_control_line = False
    for _, kind, item in events:
        if kind == 'image':
            p = book.el('p'); p.append(item); section.append(p)
        else:
            text = item['text'].strip()
            for paragraph in (text.splitlines() if item.get('coarse_zone') else [text]):
                p = book.el('p')
                if item.get('bold'): p.append(book.el('strong', paragraph))
                elif item.get('italic'): p.append(book.el('em', paragraph))
                else: p.text = paragraph
                section.append(p)
            save_replacement = saved_source_lines is not None and '\ufffd' in text
            save_control = djvu_control_pages is not None and item.get('invalid_control')
            if (save_replacement or save_control) and rgb is not None and not keep_full_scan:
                image = original_scan_line(book, rgb, width, height, page_width, page_height, item['box'], number,
                                           source_format)
                if image is not None:
                    visible_line = book.el('p')
                    visible_line.append(image)
                    section.append(visible_line)
                    if save_replacement:
                        saved_source_lines[number] += 1
                    copied_control_line |= bool(save_control)
    if invalid:
        if djvu_control_pages is not None:
            djvu_control_pages[tuple(replacements[ch] for ch in sorted(invalid))].append((number, copied_control_line))
        else:
            book.warnings.add(f'Страница {number}: нечитаемые символы исходного текстового слоя помечены ' +
                              ', '.join(replacements[ch] for ch in sorted(invalid)) + '. Сверьте эти места с оригиналом.')
    if book.omit_images:
        return sum(ch.isalnum() for n in lines for ch in n['text'])
    return sum(ch.isalpha() for n in lines for ch in n['text'])


def check_content(book, text_count, format_name):
    if book.omit_images:
        save_scans = 'Выберите FB2 или EPUB, чтобы сохранить страницы как изображения.'
        if not text_count:
            book.fail(f'В {format_name} нет пригодного текстового слоя для сохранения в TXT. {save_scans}')
        missing = getattr(book, 'missing_text_pages', 0)
        if missing:
            book.warnings.add(f'Страниц без текста: {missing}. Их места отмечены в TXT. {save_scans}')
    elif text_count < 20 and not getattr(book, 'fixed_image_pages', 0):
        book.fail(f'В {format_name} нет текста или изображений для конвертации.')


PDFGetBlock = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_ulong, C.c_void_p, C.c_ulong)


def warn_about_missing_outline(warnings, format_name, titles):
    message = f'Не удалось перенести все переходы оглавления {format_name}.'
    if titles:
        names = ', '.join(f'«{title[:120]}{"…" if len(title) > 120 else ""}»' for title in titles[:5])
        if len(titles) > 5:
            names += f' и ещё {len(titles) - 5}'
        message += f' Пункты без доступной страницы — {names}.'
    warnings.add(message + ' Доступные переходы сохранены.')


class PDFFileAccess(C.Structure):
    _fields_ = [('length', C.c_ulong), ('get_block', PDFGetBlock), ('parameter', C.c_void_p)]


class PDF:
    def __init__(self, tools, fail):
        self.tools = tools
        path = tools / 'pdfium' / 'pdfium.dll'
        if not path.is_file(): fail('Не найден встроенный PDFium.')
        try: self.dll = C.WinDLL(str(path))
        except OSError: fail('PDFium не удалось загрузить. Проверьте комплектность и разрядность программы.')
        P, I, D, F = C.c_void_p, C.c_int, C.c_double, C.c_float
        signatures = {
            'FPDF_InitLibrary': (None, []), 'FPDF_DestroyLibrary': (None, []),
            'FPDF_LoadCustomDocument': (P, [C.POINTER(PDFFileAccess), C.c_char_p]), 'FPDF_CloseDocument': (None, [P]),
            'FPDF_GetLastError': (C.c_ulong, []),
            'FPDF_GetPageCount': (I, [P]), 'FPDF_LoadPage': (P, [P, I]), 'FPDF_ClosePage': (None, [P]),
            'FPDF_GetPageWidth': (D, [P]), 'FPDF_GetPageHeight': (D, [P]),
            'FPDFBookmark_GetFirstChild': (P, [P, P]), 'FPDFBookmark_GetNextSibling': (P, [P, P]),
            'FPDFBookmark_GetTitle': (C.c_ulong, [P, P, C.c_ulong]),
            'FPDFBookmark_GetDest': (P, [P, P]), 'FPDFDest_GetDestPageIndex': (I, [P, P]),
            'FPDFBookmark_GetAction': (P, [P]), 'FPDFAction_GetType': (C.c_ulong, [P]),
            'FPDFAction_GetDest': (P, [P, P]),
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
        for name in ('FPDFText_IsHyphen', 'FPDFText_HasUnicodeMapError'):
            function = getattr(self.dll, name, None)
            if function is not None:
                function.restype = I
                function.argtypes = [P, I]
            setattr(self, name, function)

    def page_outline(self, document, count, warnings):
        pending = [(self.FPDFBookmark_GetFirstChild(document, None), 1)]
        seen, entries = set(), []
        missing = False
        missing_titles = []
        while pending and len(seen) < 4096:
            item, depth = pending.pop()
            if not item:
                continue
            if item in seen or depth > 64:
                missing = True
                continue
            seen.add(item)
            pending.append((self.FPDFBookmark_GetNextSibling(document, item), depth))
            pending.append((self.FPDFBookmark_GetFirstChild(document, item), depth + 1))
            size = self.FPDFBookmark_GetTitle(item, None, 0)
            if not 2 < size <= 8194 or size % 2:
                if size > 2: missing = True
                continue
            buffer = C.create_string_buffer(size)
            written = self.FPDFBookmark_GetTitle(item, buffer, size)
            if written != size:
                missing = True
                continue
            label = ' '.join(buffer.raw[:-2].decode('utf-16le', 'replace').split())
            dest = self.FPDFBookmark_GetDest(document, item)
            if not dest:
                action = self.FPDFBookmark_GetAction(item)
                if action and self.FPDFAction_GetType(action) == 1:  # Internal go-to action.
                    dest = self.FPDFAction_GetDest(document, action)
            page = self.FPDFDest_GetDestPageIndex(document, dest) if dest else -1
            if label and 0 <= page < count:
                entries.append((page + 1, label, depth))
            elif label:
                missing_titles.append(label)
        if missing or missing_titles or any(item for item, _ in pending):
            warn_about_missing_outline(warnings, 'PDF', missing_titles)
        return entries

    def estimate_object_functions(self):
        try:
            object_count = self.dll.FPDFPage_CountObjects
            page_object = self.dll.FPDFPage_GetObject
            object_type = self.dll.FPDFPageObj_GetType
            image_size = self.dll.FPDFImageObj_GetImageDataRaw
        except AttributeError:
            return None
        pointer = C.c_void_p
        object_count.argtypes, object_count.restype = [pointer], C.c_int
        page_object.argtypes, page_object.restype = [pointer, C.c_int], pointer
        object_type.argtypes, object_type.restype = [pointer], C.c_int
        image_size.argtypes, image_size.restype = [pointer, pointer, C.c_ulong], C.c_ulong
        return object_count, page_object, object_type, image_size

    def scan_sample_groups(self, load_page, count, check):
        """Pick typical raster pages from separate parts of the PDF."""
        if count <= 20:
            return []
        functions = self.estimate_object_functions()
        if functions is None:
            return []
        object_count, page_object, object_type, image_size = functions
        page_sizes = []
        uniform_short_scan = count <= 128
        dimensions = None
        for index in range(count):
            if check is not None: check()
            page = load_page(index)
            if not page: return []
            try:
                objects = object_count(page)
                if not 0 < objects <= 64: return []
                if uniform_short_scan:
                    shape = self.FPDF_GetPageWidth(page), self.FPDF_GetPageHeight(page)
                    if dimensions is None: dimensions = shape
                    uniform_short_scan = objects == 1 and shape == dimensions
                size = 0
                for position in range(objects):
                    image = page_object(page, position)
                    if not image or object_type(image) != 3: return []  # FPDF_PAGEOBJ_IMAGE
                    size += image_size(image, None, 0)
                if not size: return []
                page_sizes.append((size, index+1))
            finally:
                self.FPDF_ClosePage(page)
        groups = []
        if uniform_short_scan:
            # Keep the fast two-band estimate for small, uniform scans.
            ranked = sorted(page_sizes)
            middle = count//2
            for band in (ranked[:middle], ranked[middle:]):
                size, page = band[len(band)//2]
                groups.append((page, sum(value for value, _ in band)/size))
            return groups
        # Two samples keep smaller books fast, including costly high-DPI scans.
        parts = 2 if count <= 128 else 4
        for part in range(parts):
            start = part*count//parts
            end = (part+1)*count//parts
            middle = (start+end+1)//2
            band = sorted(page_sizes[start:end], key=lambda item: (item[0], abs(item[1]-middle)))
            _, page = band[len(band)//2]
            # Source compression helps choose a typical page, but its byte
            # count is not proportional to the size after re-encoding.
            groups.append((page, end-start))
        return groups

    def has_readable_text(self, page, get_text):
        text_page = self.FPDFText_LoadPage(page)
        if not text_page:
            return False
        try:
            count = self.FPDFText_CountChars(text_page)
            if not 0 < count <= 1000000:
                return False
            data = (C.c_ushort * (count + 1))()
            written = get_text(text_page, 0, count, data)
            if not 1 < written <= len(data):
                return False
            return readable(C.string_at(data, 2 * (written - 1)).decode('utf-16le', 'replace'))
        finally:
            self.FPDFText_ClosePage(text_page)

    def mixed_sample_groups(self, load_page, count, check):
        if count <= 20:
            return [], False
        functions = self.estimate_object_functions()
        get_text = getattr(self.dll, 'FPDFText_GetText', None)
        if functions is None or get_text is None:
            return [], False
        object_count, page_object, object_type, image_size = functions
        get_text.argtypes = [C.c_void_p, C.c_int, C.c_int, C.POINTER(C.c_ushort)]
        get_text.restype = C.c_int
        classes = defaultdict(list)
        census_count = min(count, 120) if count > 130 else count
        for band in range(census_count):
            start = count * band // census_count
            stop = count * (band + 1) // census_count
            # Vary the representative's position so an alternating page
            # pattern cannot always be sampled on the same side of a spread.
            index = start + ((band * 37) % 101) * (stop - start) // 101
            if check is not None:
                check()
            page = load_page(index)
            if not page:
                return [], False
            try:
                objects = object_count(page)
                if not 0 <= objects <= 10000:
                    return [], False
                size = 0
                may_have_text = False
                for position in range(objects):
                    obj = page_object(page, position)
                    if not obj:
                        continue
                    kind = object_type(obj)
                    if kind == 3:  # FPDF_PAGEOBJ_IMAGE
                        size += image_size(obj, None, 0)
                    elif kind in (1, 5):  # FPDF_PAGEOBJ_TEXT / FPDF_PAGEOBJ_FORM
                        may_have_text = True
                key = may_have_text and self.has_readable_text(page, get_text), size > 0
                classes[key].append((size, index, stop - start))
            finally:
                self.FPDF_ClosePage(page)

        plain = sum(weight for _, _, weight in classes[True, False])
        if plain == count:
            return [], False
        scan_majority = count <= 130 and 2 * len(classes[False, True]) >= count
        text_majority = count <= 130 and 2 * plain >= count
        allocations = {(False, True): 12 if scan_majority else 2,
                       (False, False): 3 if count <= 130 else 1,
                       (True, True): 4, (True, False): 4 if text_majority else 1}
        # Leave a sample in each nonempty class before assigning extra bands.
        available = 18 - sum(bool(rows) for rows in classes.values())
        groups = []
        for key, limit in allocations.items():
            rows = sorted(classes[key])
            if not rows:
                continue
            bands = min(len(rows), limit, available + 1)
            available -= bands - 1
            for band in range(bands):
                subset = rows[len(rows) * band // bands:len(rows) * (band + 1) // bands]
                _, index, _ = subset[len(subset) // 2]
                groups.append((index, sum(weight for _, _, weight in subset)))
        return groups, text_majority

    @contextmanager
    def open_document(self, source, fail):
        # PDFium may request blocks lazily while loading individual pages.
        # Keep the stream and its C callback alive until CloseDocument.
        with source.open('rb') as stream:
            length = os.fstat(stream.fileno()).st_size

            @PDFGetBlock
            def read_block(_parameter, position, buffer, size):
                if position + size > length or (size and not buffer):
                    return 0
                if not size:
                    return 1
                try:
                    stream.seek(position)
                    return int(stream.readinto((C.c_ubyte * size).from_address(buffer)) == size)
                except (OSError, ValueError, OverflowError):
                    return 0

            access = PDFFileAccess(length, read_block, None)
            document = self.FPDF_LoadCustomDocument(C.byref(access), None)
            if not document:
                error = self.FPDF_GetLastError()
                fail({
                    3: 'Не удалось прочитать структуру PDF. Проверьте, полностью ли скачан файл.',
                    4: 'PDF требует пароль для открытия. Для преобразования нужна доступная вам копия без пароля.',
                    5: 'PDF использует неподдерживаемую защиту. Для преобразования нужна доступная вам копия без этой защиты.',
                }.get(error, 'Не удалось открыть PDF.'))
            try:
                yield document
            finally:
                self.FPDF_CloseDocument(document)

    def page_lines(self, page, width, height):
        text = self.FPDFText_LoadPage(page)
        if not text:
            return None
        lines = []; chars = []; boxes = []; weights = []
        def flush():
            if chars and ''.join(chars).strip() and boxes:
                lines.append({'text': ''.join(chars), 'box': (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)),
                              'bold': bool(weights) and statistics.median(weights) >= 600})
            chars.clear(); boxes.clear(); weights.clear()
        try:
            count = self.FPDFText_CountChars(text)
            if not 0 <= count <= 1000000:
                return None
            next_index = 0
            while next_index < count:
                i = next_index
                next_index += 1
                code = self.FPDFText_GetUnicode(text, i)
                # PDFium uses U+0002 for a recognized line-end hyphen.
                # The exported lines retain the visible hyphen in its place.
                if code == 2 and self.FPDFText_IsHyphen is not None and self.FPDFText_IsHyphen(text, i) == 1:
                    code = ord('-')
                elif (self.FPDFText_HasUnicodeMapError is not None and
                      self.FPDFText_HasUnicodeMapError(text, i) == 1):
                    # PDFium may return a printable raw font index on failure.
                    # Keep the source line as an image via the damaged-text path.
                    code = 0xfffd
                elif 0xd800 <= code <= 0xdbff and next_index < count:
                    following = self.FPDFText_GetUnicode(text, next_index)
                    if (0xdc00 <= following <= 0xdfff and
                        (self.FPDFText_HasUnicodeMapError is None or
                         self.FPDFText_HasUnicodeMapError(text, next_index) != 1)):
                        code = 0x10000 + ((code - 0xd800) << 10) + following - 0xdc00
                        next_index += 1
                if code > 0x10ffff or 0xd800 <= code <= 0xdfff: code = 0xfffd
                ch = chr(code)
                if ch in '\r\n': flush(); continue
                if not code: ch = '\ufffd'
                if code < 32 and ch != '\t': ch = '\ufffd'
                l, r, b, t = C.c_double(), C.c_double(), C.c_double(), C.c_double()
                if not self.FPDFText_GetCharBox(text, i, C.byref(l), C.byref(r), C.byref(b), C.byref(t)): continue
                box = (l.value, height - t.value, r.value, height - b.value)
                if box[2] < 0 or box[0] > width or box[3] < 0 or box[1] > height: continue
                size = max(1, self.FPDFText_GetFontSize(text, i))
                if boxes and not ch.isspace():
                    previous = boxes[-1]
                    # A substituted PDF font can report a near-zero box for
                    # one alphabet. The baseline still aligns with its row.
                    vertical_jump = min(abs(box[1] - previous[1]), abs(box[3] - previous[3]))
                    if vertical_jump > size * .7 or box[0] - previous[2] > size * 3 or box[2] < previous[0] - size:
                        flush()
                chars.append(ch)
                if not ch.isspace(): boxes.append(box); weights.append(self.FPDFText_GetFontWeight(text, i))
            flush()
        finally: self.FPDFText_ClosePage(text)
        return lines

    def page(self, page, fail, spread_detail=False, render=True):
        width, height = self.FPDF_GetPageWidth(page), self.FPDF_GetPageHeight(page)
        if not 0 < width < 100000 or not 0 < height < 100000: fail('Некорректные размеры страницы PDF.')
        lines = self.page_lines(page, width, height)
        if not render:
            return lines, None, 0, 0, width, height
        edge=3200 if spread_detail and width>height*1.10 else 1600
        scale = min(2, edge / max(width, height)); w, h = max(1, round(width * scale)), max(1, round(height * scale))
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
            return lines, rgb, w, h, width, height
        finally: self.FPDFBitmap_Destroy(bitmap)


def estimate_mixed_pdf(book, convert_page, groups, count, measure_text, check):
    def sample_book(omit_images=False):
        sample = type(book)(book.c, book.source, set(), title=book.title, author=book.author,
                            language=book.language, tools_root=book.tools_root, omit_images=omit_images)
        sample.work_root = book.work_root
        return sample

    samples = []
    retained = 0
    for position, (index, weight) in enumerate(sorted(groups), 1):
        if check is not None:
            check()
        sample = sample_book()
        convert_page(index, sample)
        pictures = [data for data, _mime in sample.resources.values()]
        retained += sum(map(len, pictures))
        if retained > 48 * 1024 * 1024:
            return  # The streaming full-page path has a smaller working set.
        samples.append((weight, bool(getattr(sample, 'fixed_image_pages', 0)),
                        book.c.serialized(sample.body), pictures))
        book.progress('pages', position, count)
    pictures = [data for _, _, _, images in samples for data in images]
    if not pictures:
        return
    export = book.scan_processor()
    text_baseline = None
    # When pictures are shared across pages, text can account for most of the
    # final file. Measuring its real markup avoids magnifying per-page overhead.
    measure_text = measure_text or (count <= 130 and 2 * len(set(pictures)) <= len(pictures))
    if measure_text:
        text = sample_book(omit_images=True)
        for index in range(count):
            if check is not None:
                check()
            convert_page(index, text)
        with tempfile.TemporaryDirectory(prefix='homelib-pdf-text-', dir=book.work_root) as directory:
            epub = Path(directory) / 'text.epub'
            text.finish(epub)
            if book.image_export['target'] == '.fb2':
                fb2 = epub.with_suffix('.fb2')
                book.c.epub_to_fb2(epub, fb2, text.warnings, use_navigation=False)
                image_references = sum(weight * len(images) for weight, _, _, images in samples)
                text_baseline = (fb2.stat().st_size + 56 * image_references,
                                 export.codec.deflated_size(fb2.read_bytes()) + 512)
            else:
                text_baseline = epub.stat().st_size, epub.stat().st_size + 512
    export.finish_mixed_measurement(samples, count, text_baseline)


def read_pdf(book, tools):
    if not (tools / 'pdfium' / 'pdfium.dll').is_file():
        book.require('PDFium', 'Для этой книги нужен модуль чтения PDF.')
    api = PDF(tools, book.fail); api.FPDF_InitLibrary()
    try:
        with ExitStack() as working_files, ExitStack() as documents:
            source = book.source
            document = documents.enter_context(api.open_document(source, book.fail))
            count = api.FPDF_GetPageCount(document)
            if not 0 < count <= 5000: book.fail('Недопустимое число страниц PDF (предел 5000).')
            work_root = getattr(book, 'work_root', None)
            for script, name, warning in (
                ('pdf_legacy_encoding', 'legacy-cyrillic.pdf',
                 'В копии исправлена кириллица PDF, записанная в Windows-1251. Исходный PDF сохранён.'),
                ('pdf_font_encoding', 'pdf-font-encoding.pdf', None),
            ):
                if work_root is None:
                    break
                spec = importlib.util.spec_from_file_location(script, Path(__file__).with_name(script + '.py'))
                repair = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(repair)
                repaired = work_root / name
                options = {'warnings': book.warnings, 'check': book.cancel_check} if warning is None else {}
                if repair.prepare(source, repaired, api, document, **options):
                    working_files.callback(repaired.unlink, missing_ok=True)
                    documents.close()
                    document = documents.enter_context(api.open_document(repaired, book.fail))
                    source = repaired
                    if warning is not None:
                        book.warnings.add(warning)
            book.page_count=count
            if not book.omit_images:
                book.page_outline = api.page_outline(document, count, book.warnings)
            book.progress('pages', 0, count)
            loaded = 0
            unreadable = []
            unreadable_text = []
            incomplete_text = []
            rasterized_text = []
            saved_pdf_lines = defaultdict(int)

            def load_page(index):
                nonlocal document, loaded
                # PDFium can retain document resources after closing individual
                # pages. Release them in batches, including during sampling
                # and text-only conversion.
                if loaded == PDF_PAGES_PER_DOCUMENT:
                    documents.close()
                    document = documents.enter_context(api.open_document(source, book.fail))
                    if api.FPDF_GetPageCount(document) != count:
                        book.fail('Число страниц PDF изменилось во время конвертации.')
                    loaded = 0
                loaded += 1
                return api.FPDF_LoadPage(document, index)

            def convert_page(i, target=book):
                page = load_page(i)
                if not page:
                    unreadable.append(i + 1)
                    unreadable_page(target, i + 1)
                    return 0
                try:
                    lines, rgb, w, h, pw, ph = api.page(
                        page, book.fail, bool(book.image_export), render=not target.omit_images)
                    missing_characters = lines is not None and any('\ufffd' in line['text'] for line in lines)
                    fragments = saved_pdf_lines if target is book else defaultdict(int)
                    letters = emit_page(target, i + 1, lines or [], rgb, w, h, pw, ph,
                                        saved_source_lines=fragments if not target.omit_images else None)
                    if target is book:
                        if lines is None or (missing_characters and not letters and book.omit_images):
                            unreadable_text.append(i + 1)
                        elif missing_characters:
                            # Keep a usable text layer even if some glyphs cannot
                            # be decoded. emit_page renders the entire page when
                            # the text does not pass its readability check.
                            (incomplete_text if letters else rasterized_text).append(i + 1)
                    book.warnings.add('Текстовый слой PDF может содержать результат OCR. Возможны ошибки распознавания; сверьте важные цитаты с оригиналом.')
                finally: api.FPDF_ClosePage(page)
                return letters
            groups = []
            if book.image_export and book.image_export.get('measure_scans'):
                check = book.image_export.get('check')
                groups = api.scan_sample_groups(load_page, count, check)
                if not groups:
                    mixed, measure_text = api.mixed_sample_groups(load_page, count, check)
                    if mixed:
                        estimate_mixed_pdf(book, convert_page, mixed, count, measure_text, check)
            sampled = sorted(number-1 for number, _weight in groups)
            letters = 0
            if groups:
                book.image_export['sample_groups'] = groups
                for position, i in enumerate(sampled, 1):
                    letters += convert_page(i)
                    book.progress('pages', position, count)
                if book.scan_export is not None and book.scan_export.can_use_samples():
                    book.progress('pages', count, count)
                    return
                book.image_export.pop('sample_groups')
            sampled = set(sampled)
            completed = len(sampled)
            for i in range(count):
                if i in sampled: continue
                letters += convert_page(i)
                completed += 1
                book.progress('pages', completed, count)
            check_content(book, letters, 'PDF')
            warn_about_unreadable_pages(book, unreadable)
            if unreadable_text:
                details = ('В TXT на их местах стоят отметки. Выберите FB2 или EPUB, чтобы сохранить изображения.'
                           if book.omit_images else 'Страницы сохранены целиком изображениями.')
                book.warnings.add(f'Не удалось прочитать текстовый слой страниц PDF: {describe_pages(unreadable_text)}. {details}')
            if incomplete_text:
                message = (f'Нечитаемые символы PDF на страницах {describe_pages(incomplete_text)} отмечены знаком �. '
                           'Разборчивый текст сохранён.')
                if saved_pdf_lines:
                    message += (f' На страницах {describe_pages(saved_pdf_lines)} рядом с текстом сохранены '
                                'изображения исходных строк с такими знаками.')
                book.warnings.add(message)
            if rasterized_text:
                book.warnings.add(f'Нечитаемые символы PDF на страницах {describe_pages(rasterized_text)} сохранены '
                                  'в изображениях страниц. Поиск по тексту этих страниц недоступен.')
    finally: api.FPDF_DestroyLibrary()


def sexpressions(text, fail, *, keep_string_bytes=False):
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
                    else:
                        literal = {'n':'\n', 'r':'\r', 't':'\t'}.get(escape, escape) if escape else match[2]
                        value.extend(literal.encode('utf-8', errors='surrogateescape'))
                if keep_string_bytes:
                    stack[-1].append(bytes(value))
                else:
                    try: stack[-1].append(value.decode('utf-8'))
                    except UnicodeError: fail('Текстовый слой DjVu имеет некорректную UTF-8 кодировку.')
            else:
                try: stack[-1].append(int(item))
                except ValueError: stack[-1].append(item)
    if stack: fail('Оборван текстовый слой DjVu.')
    return roots


_DJVU_RUSSIAN_WORDS = set(
    'и в на не по как для что это из от с у о за при или его к году до после журнал наук ссср '
    'лет век только между является чтобы котором мы они может так все'.split()
)


def djvu_text_encoding(data):
    try:
        data.decode('utf-8')
        return 'utf-8'
    except UnicodeDecodeError:
        pass
    try:
        legacy = data.decode('cp1251')
    except UnicodeDecodeError:
        return 'utf-8'

    def words(text):
        return re.findall(r'[а-яё]+', text.lower())

    # Do not turn isolated bad bytes in otherwise valid UTF-8 into Cyrillic.
    cyrillic = words(legacy)
    letters = sum(map(len, cyrillic))
    if letters < 24 or sum(map(len, words(data.decode('utf-8', 'replace')))) * 4 > letters:
        return 'utf-8'
    frequent = [word for word in cyrillic if word in _DJVU_RUSSIAN_WORDS]
    if len(frequent) < 5 or len(set(frequent)) < 3:
        return 'utf-8'
    # Other old Cyrillic encodings can decode the same bytes into gibberish
    # without errors. Require a clear preference for actual Russian words.
    for encoding in ('cp866', 'koi8-r'):
        alternative = [word for word in words(data.decode(encoding)) if word in _DJVU_RUSSIAN_WORDS]
        if len(alternative) * 3 >= len(frequent) and len(set(alternative)) * 2 >= len(set(frequent)):
            return 'utf-8'
    return 'cp1251'


def djvu_text_lines(page):
    lines = []

    def content(node):
        text = []
        previous_word = False
        for child in node[5:]:
            is_word = isinstance(child, list) and bool(child) and child[0] == 'word'
            part = content(child) if isinstance(child, list) else child
            if not isinstance(part, bytes) or not part:
                continue
            if is_word and previous_word and not text[-1][-1:].isspace() and not part[:1].isspace():
                text.append(b' ')
            text.append(part)
            previous_word = is_word
        return b''.join(text)

    def collect(node):
        if not isinstance(node, list) or len(node) < 5:
            return
        children = [child for child in node[5:] if isinstance(child, list)]
        if node[0] == 'line' or not children or all(child and child[0] in {'word', 'char'} for child in children):
            text = content(node)
            box = tuple(node[1:5])
            if text.strip() and all(isinstance(value, int) for value in box):
                line = {'text': text, 'box': box}
                if node[0] != 'line':
                    line['coarse_zone'] = True
                lines.append(line)
        else:
            for child in children:
                collect(child)

    collect(page)
    return lines


_DJVU_ZONE_SEPARATORS = b'\x0b\x1d\x1f'
_DJVU_ZONE_BREAKS = bytes.maketrans(_DJVU_ZONE_SEPARATORS, b'\n\n\n')
_DJVU_TEXT_SPACING = b' \t\r\n' + _DJVU_ZONE_SEPARATORS


def djvu_plain_lines(text, page):
    if page is not None and any(separator in text for separator in _DJVU_ZONE_SEPARATORS):
        zones = djvu_text_lines(page)
        detail = b'\n'.join(line['text'] for line in zones)
        if detail.translate(None, _DJVU_TEXT_SPACING) == text.translate(None, _DJVU_TEXT_SPACING):
            # DjVuLibre adds separators to the flat dump. The same bytes
            # inside a text zone may be stored in place of a visible character.
            if any(separator in detail for separator in _DJVU_ZONE_SEPARATORS):
                return zones
            text = text.translate(_DJVU_ZONE_BREAKS)
    return [{'text': line, 'box': (0, i, 1, i + 1)} for i, line in enumerate(text.splitlines())]


_PPM_FIELD = re.compile(br'\s*(?:#[^\r\n]*(?:\r?\n)|([^\s#]+))')


def ppm_page(data, fail, offset=0):
    """Read one exact P6 frame, without scanning pixels for the next header."""
    at = offset; fields = []
    while len(fields) < 4:
        match = _PPM_FIELD.match(data, at, min(len(data), offset + 1024))
        if not match: fail('Некорректный растр DjVu.')
        at = match.end()
        if match[1]: fields.append(match[1])
    if fields[0] != b'P6' or fields[3] != b'255': fail('Неподдерживаемый растр DjVu.')
    if not all(value.isdigit() for value in fields[1:3]): fail('Некорректный размер растра DjVu.')
    width, height = int(fields[1]), int(fields[2])
    if not 0 < width <= 3200 or not 0 < height <= 1600: fail('Слишком большой растр DjVu.')
    if data[at:at + 2] == b'\r\n': at += 2
    elif data[at:at + 1].isspace(): at += 1
    else: fail('Оборван заголовок растра DjVu.')
    end = at + width * height * 3
    if end > len(data): fail('Оборван растр DjVu.')
    return data[at:end], width, height, end


def ppm(data, fail):
    rgb, width, height, end = ppm_page(data, fail)
    if end != len(data): fail('Лишние данные после растра DjVu.')
    return rgb, width, height


def describe_pages(numbers):
    numbers = sorted(set(numbers))
    ranges = []
    start = end = numbers[0]
    for number in numbers[1:]:
        if number == end + 1:
            end = number
            continue
        ranges.append(str(start) if start == end else f'{start}–{end}')
        start = end = number
    ranges.append(str(start) if start == end else f'{start}–{end}')
    return f'{", ".join(ranges)} (всего {len(numbers)})'


def warn_about_unreadable_pages(book, numbers):
    if numbers:
        book.warnings.add(f'В исходнике не удалось прочитать страницы {describe_pages(numbers)}. '
                          'В книге на их местах стоят отметки.')


def djvu_page_outline(book, run, used, count, source=None):
    def metadata(command):
        raw = run([used, '-n', '-u', '-e', command, source if source is not None else book.source], 8 * 1024**2,
                  step='оглавление', retry_individually=True)
        if raw is None:
            book.fail('Команда DjVuLibre не вернула оглавление.')
        return raw.decode('utf-8-sig')

    entries = []
    page_ids = None
    missing = False
    missing_titles = []

    def page_number(target):
        nonlocal page_ids
        if not target.startswith('#'):
            return 0
        target = unquote(target[1:])
        if re.fullmatch(r'[0-9]{1,7}', target):
            return int(target)
        if page_ids is None:
            page_ids = {}
            for row in re.finditer(r'^[ \t]*(\d+) P +\d+ +([^\r\n]+)', metadata('ls'), re.M):
                for name in re.split(r' [FT]=', row[2]):
                    page_ids.setdefault(name, int(row[1]))
        return page_ids.get(target, 0)

    def web_address(target):
        if (not re.match(r'https?://', target, re.I) or len(target) > 4096 or
                re.search(r'[\s\\\x00-\x1f\x7f]', target)):
            return None
        try:
            address = urlsplit(target)
            if not address.hostname or address.username is not None or address.password is not None:
                return None
        except ValueError:
            return None
        return quote(target, safe=":/?#[]@!$&'()*+,;=%")

    def walk(nodes, depth):
        nonlocal missing
        for node in nodes:
            if not isinstance(node, list) or len(node) < 2 or not all(isinstance(value, str) for value in node[:2]):
                missing = True
                continue
            if len(entries) == 4096:
                missing = True
                return
            label = ' '.join(node[0].split())
            if label:
                target = node[1]
                page = page_number(target)
                if 0 < page <= count:
                    entries.append((page, label, depth))
                elif address := web_address(target):
                    entries.append((address, label, depth))
                else:
                    missing_titles.append(label)
            walk(node[2:], depth + 1)

    try:
        raw = metadata('print-outline')
        if raw.strip():
            roots = sexpressions(raw, book.fail)
            if len(roots) == 1 and roots[0] and roots[0][0] == 'bookmarks':
                walk(roots[0][1:], 1)
            else:
                missing = True
    except (book.c.ConversionError, UnicodeError):
        missing = True
    if missing or missing_titles:
        warn_about_missing_outline(book.warnings, 'DjVu', missing_titles)
    return entries


def djvu_bundled_scan_pages(dump, count):
    if (not re.search(rb'^[ \t]+DIRM \[\d+\][ \t]+Document directory \(bundled,', dump, re.M)
            or re.search(rb'^[ \t]+TXT[az][ \t]+\[', dump, re.M)):
        return []
    # Do not infer the absence of text from a partial or indirect directory.
    pages = [(int(number), int(length)) for length, number in
             re.findall(rb'^[ \t]+FORM:DJVU \[(\d+)\][^\r\n]* \[P(\d+)\][ \t]*\r?$', dump, re.M)]
    return pages if [number for number, _ in pages] == list(range(1, count + 1)) else []


def djvu_raster_sample_groups(pages):
    count = len(pages)
    groups = []
    for part in range(8):
        start, end = part*count//8, (part+1)*count//8
        ranked = sorted(pages[start:end], key=lambda page: page[1])
        middle = len(ranked)//2
        for band in (ranked[:middle], ranked[middle:]):
            groups.append((band[len(band)//2][0], len(band)))
    return sorted(groups)


def djvu_bundled_dimensions(dump, count):
    if not dump or not re.search(rb'^[ \t]+DIRM \[\d+\][ \t]+Document directory \(bundled,', dump, re.M):
        return {}
    # Both the dump and the individual size command report the raw INFO
    # dimensions. Accept only a complete, ordered page list with page-level INFO.
    entries = re.findall(
        rb'^([ \t]+)FORM:DJVU \[\d+\][^\r\n]* \[P(\d+)\][ \t]*\r?\n'
        rb'\1  INFO \[\d+\][ \t]+DjVu (\d+)x(\d+)(?:,|[ \t]*\r?$)', dump, re.M)
    sizes = [(int(page), int(width), int(height)) for _, page, width, height in entries]
    if ([page for page, _, _ in sizes] != list(range(1, count + 1)) or
            not all(width > 0 and height > 0 for _, width, height in sizes)):
        return {}
    return {page: (width, height) for page, width, height in sizes}


@contextmanager
def djvu_source(source, helper, work_root):
    if helper.is_file():
        try:
            with Path(source).open('rb') as stream:
                header = stream.read(16)
                stream.seek(0, os.SEEK_END)
                truncated_bundle = (len(header) == 16 and header.startswith(b'AT&TFORM') and
                                    header[12:16] == b'DJVM' and
                                    int.from_bytes(header[8:12], 'big') + 12 > stream.tell())
        except OSError:
            truncated_bundle = False
        if truncated_bundle:
            with tempfile.TemporaryDirectory(prefix='homelibre-djvu-repair-', dir=work_root) as directory:
                index = Path(directory) / 'index.djvu'
                try:
                    trial = subprocess.run([str(helper), '--recover-bundled', str(source), directory],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                           timeout=30, creationflags=0x08000000)
                except (OSError, subprocess.TimeoutExpired):
                    trial = None
                if trial is not None and trial.returncode == 0 and index.is_file():
                    yield index, True
                    return
    yield source, False


def read_djvu(book, tools):
    used, renderer = tools / 'djvu' / 'djvused.exe', tools / 'djvu' / 'ddjvu.exe'
    if not used.is_file() or (not book.omit_images and not renderer.is_file()):
        book.require('DjVuLibre', 'Для этой книги нужен модуль чтения DjVu.')
    with djvu_source(book.source, tools / 'djvu' / 'HomeLibDjvu.exe',
                     getattr(book, 'work_root', None)) as (source, recovered):
        read_djvu_pages(book, used, renderer, source, recovered)
        if recovered:
            book.warnings.add('Восстановлена часть страниц DjVu: данные контейнера повреждены. '
                              'Исходные номера страниц сохранены.')


def read_djvu_pages(book, used, renderer, source, recovered):
    def run(args, limit, timeout=40, step='сведения о книге', retry_individually=False,
            allow_damaged_text=False, allow_damaged_page=False):
        with tempfile.TemporaryFile() as out:
            for attempt in range(2):
                try:
                    result = subprocess.run([str(a) for a in args], stdout=out, stderr=subprocess.PIPE,
                                            timeout=timeout, creationflags=0x08000000)
                except subprocess.TimeoutExpired:
                    if retry_individually:
                        return None
                    book.fail(f'Чтение DjVu: {step} — превышено допустимое время ({timeout} с).')
                if not result.returncode or attempt or b'DjVuDocEditor.open_fail' not in result.stderr:
                    break
                # A reopen can fail transiently in the middle of a good book.
                # Restart exactly this request, keeping its page numbers.
                out.seek(0)
                out.truncate()
            if result.returncode:
                if retry_individually:
                    return None
                details = result.stderr.decode('utf-8', errors='replace').strip()[-500:]
                if allow_damaged_page and ('Cannot decode page' in details or 'DjVuFile.corrupt_' in details or
                                           recovered and 'Cannot access page' in details):
                    return None
                # A bundled document can advertise pages whose chunks extend
                # past EOF. At this point the request is for one page's text;
                # leave recovery of the corresponding raster to the renderer.
                if allow_damaged_text and ('ByteStream.corrupt' in details or 'IFFByteStream.not_ready' in details or
                                           recovered and 'ByteStream.open_fail' in details or
                                           re.search(r'(?m)^[ \t]*\*\* Message name:[ \t]*\x03EOF\r?$', details)):
                    return None
                if 'DjVuText.corrupt_text' in details:
                    if allow_damaged_text:
                        return None
                    if book.omit_images:
                        book.fail(f'Чтение DjVu: {step} — повреждён текстовый слой. '
                                  'Выберите FB2 или EPUB, чтобы сохранить страницы как изображения.')
                message = f'Чтение DjVu: {step} — DjVuLibre завершился с кодом {result.returncode}.'
                book.fail(message + (' ' + details if details else ''))
            if out.tell() > limit: book.fail('Текст или растр DjVu превышает предел конвертации.')
            out.seek(0); return out.read()
    count = int(run([used, '-n', '-e', 'n', source], 1024).decode('utf-8-sig').strip())
    if not 0 < count <= 5000: book.fail('Недопустимое число страниц DjVu (предел 5000).')
    book.page_count=count
    if not book.omit_images:
        book.page_outline = djvu_page_outline(book, run, used, count, source=source)
    book.progress('pages', 0, count)
    letters = 0
    damaged_text_pages = []
    damaged_symbols, legacy_pages = set(), set()
    saved_source_lines = defaultdict(int)
    djvu_control_pages = defaultdict(list)
    unreadable, unreadable_rasters = [], []
    # Reopening a large document and its shared dictionaries for every page
    # costs much more than decoding four pages in one invocation. Keep batches
    # small: at most four frames. Wide export scans retain enough pixels for
    # splitting into two readable pages; ordinary reading keeps its old size.
    raster_width=3200 if getattr(book,'image_export',None) else 1600
    maximum_frame = raster_width * 1600 * 3 + 1024
    def render(selection, pages, step):
        return run([renderer, '-format=ppm', f'-page={selection}', f'-size={raster_width}x1600', source],
                   pages * maximum_frame, timeout=40 * pages, step=step, retry_individually=pages > 1,
                   allow_damaged_page=pages==1)

    def preview_raster_pages(groups):
        for start in range(0, len(groups), 4):
            numbers = [number for number, _ in groups[start:start+4]]
            selection = ','.join(map(str, numbers))
            try:
                frames = render(selection, len(numbers), 'образцы страниц для оценки размера')
                if frames is None:
                    return
                decoded, offset = [], 0
                for number in numbers:
                    rgb, width, height, offset = ppm_page(frames, book.fail, offset)
                    decoded.append((number, png(rgb, width, height)))
                if offset != len(frames):
                    return
            except book.c.ConversionError:
                # A preview must not block the ordinary per-page recovery.
                return
            yield from decoded

    dump = None
    dimensions = None

    def document_dump():
        nonlocal dump
        if dump is None:
            try:
                dump = run([used, '-n', '-e', 'dump', source], 8*1024*1024,
                           timeout=12, step='каталог страниц', retry_individually=True) or b''
            except book.c.ConversionError:
                dump = b''
        return dump

    context = book.image_export
    scan_pages = djvu_bundled_scan_pages(document_dump(), count) if count >= 128 and not recovered else []
    if scan_pages and book.omit_images:
        check_content(book, 0, 'DjVu')
    if scan_pages and context and context['profile'] == 'ask':
        groups = djvu_raster_sample_groups(scan_pages)
        book.scan_processor().offer_sampled_scan_choice(preview_raster_pages(groups), groups, count)

    def extract_text(start, end, *, report_damage=True):
        script = '; '.join(f'select {number}; print-txt' for number in range(start, end + 1))
        pages = end - start + 1
        try:
            raw = run([used, '-n', '-u', '-e', script, source], book.c.MAX_FILE,
                      timeout=40 * pages, step=f'текст сканов {start}–{end}',
                      retry_individually=pages > 1 or not report_damage, allow_damaged_text=True)
        except book.c.ConversionError:
            if report_damage:
                raise
            return [None] * pages
        roots = None
        if raw is not None:
            try:
                roots = sexpressions(raw.decode('utf-8-sig', 'surrogateescape'), book.fail,
                                     keep_string_bytes=True)
            except book.c.ConversionError:
                pass
        if roots is None or len(roots) != pages or any(
                len(page) < 5 or page[0] != 'page' or not all(isinstance(value, int) for value in page[1:5])
                for page in roots):
            if start == end:
                if report_damage:
                    damaged_text_pages.append(start)
                return [None]
            return [extract_text(number, number, report_damage=report_damage)[0] for number in range(start, end + 1)]
        return roots

    def page_dimensions(numbers):
        nonlocal dimensions
        if count >= 128:
            if dimensions is None:
                dimensions = djvu_bundled_dimensions(document_dump(), count)
            if dimensions:
                return {number: dimensions[number] for number in numbers}
        script = '; '.join(f'select {number}; size' for number in numbers)
        multiple = len(numbers) > 1
        step = (f'размеры сканов {numbers[0]}–{numbers[-1]}' if multiple else
                f'размеры страницы {numbers[0]}')
        raw = run([used, '-n', '-e', script, source], 1024 * len(numbers),
                  timeout=40 * len(numbers), step=step, retry_individually=multiple)
        sizes = [(int(width), int(height)) for width, height in
                 re.findall(rb'width=([0-9]+)\s+height=([0-9]+)', raw or b'')]
        if len(sizes) == len(numbers) and all(width > 0 and height > 0 for width, height in sizes):
            return dict(zip(numbers, sizes))
        if not multiple:
            book.fail(f'Не удалось определить размеры страницы {numbers[0]} DjVu.')
        # A partial batch response cannot establish which pages its entries describe.
        return {number: page_dimensions([number])[number] for number in numbers}

    def decode_lines(number, lines):
        encoding = djvu_text_encoding(b'\n'.join(line['text'] for line in lines))
        if encoding == 'cp1251':
            legacy_pages.add(number)
        for line in lines:
            line['text'] = line['text'].decode(encoding, 'replace')
        combined = '\n'.join(line['text'] for line in lines)
        if '\ufffd' in combined:
            if readable(combined, book.omit_images):
                damaged_symbols.add(number)
            else:
                damaged_text_pages.append(number)
        return lines

    for first in range(0, count, 4):
        last = min(count, first + 4); batch_size = last - first
        if book.omit_images:
            # The author's plain output includes even text stored directly on
            # a page or paragraph, and emits a form feed for every page.
            script = '; '.join(f'select {number}; print-pure-txt' for number in range(first + 1, last + 1))
            raw = run([used, '-n', '-u', '-e', script, source], book.c.MAX_FILE,
                      timeout=40*batch_size, step=f'текст страниц {first+1}–{last}',
                      retry_individually=batch_size>1, allow_damaged_text=True)
            if raw is None:
                pages = []
                for number in range(first + 1, last + 1):
                    raw = run([used, '-n', '-u', '-e', f'select {number}; print-pure-txt', source],
                              book.c.MAX_FILE, step=f'текст страницы {number}', allow_damaged_text=True)
                    pages.append(None if raw is None else raw.removeprefix(b'\xef\xbb\xbf').removesuffix(b'\f'))
            else:
                pages = raw.removeprefix(b'\xef\xbb\xbf').split(b'\f')
                if len(pages) != batch_size + 1 or pages.pop():
                    book.fail('Число текстовых страниц DjVu не совпало с запрошенным. Конвертация остановлена, чтобы не перепутать страницы.')
            has_separators = any(page and any(code in page for code in _DJVU_ZONE_SEPARATORS) for page in pages)
            zones = extract_text(first + 1, last, report_damage=False) if has_separators else [None] * batch_size
            for number, (page, tree) in enumerate(zip(pages, zones), first + 1):
                if page is None:
                    unreadable_page(book, number)
                    damaged_text_pages.append(number)
                    book.progress('pages', number, count)
                    continue
                lines = decode_lines(number, djvu_plain_lines(page, tree))
                letters += emit_page(book, number, lines, None, 0, 0, 0, 0, preserve_line_order=True,
                                     djvu_control_pages=djvu_control_pages)
                book.progress('pages', number, count)
            continue
        # Both text and pixels decode a batch of up to four pages. Give text
        # the same per-page budget as the raster, within the native idle limit.
        roots = [None] * batch_size if scan_pages else extract_text(first + 1, last)
        page_lines = [decode_lines(number, djvu_text_lines(page))
                      for number, page in enumerate(roots, first + 1)]
        # Some creators store the text bounding box in the root zone. Its
        # right and top coordinates are then smaller than the raster page.
        missing = [i for i, (page, lines) in enumerate(zip(roots, page_lines), first + 1)
                   if lines and (any(page[1:3]) or page[3] <= 0 or page[4] <= 0 or i in legacy_pages)]
        geometry = page_dimensions(missing) if missing else {}
        raster = render(f'{first+1}-{last}', batch_size, f'изображения сканов {first+1}–{last}')
        offset = 0
        for i, (page, lines) in enumerate(zip(roots, page_lines), first):
            pw, ph = (page[3], page[4]) if page is not None else (0, 0)
            if i + 1 in geometry:
                pw, ph = geometry[i + 1]
            for line in lines:
                left, bottom, right, top = line['box']
                line['box'] = (left, ph - top, right, ph - bottom)
            layout = dict(source_format='DjVu', djvu_control_pages=djvu_control_pages)
            # The DjVu text zones may describe logical columns and regions
            # whose reading order cannot be inferred from vertical positions.
            if page is not None and any(isinstance(zone, list) and zone and
                                        zone[0] in {'column', 'region', 'para'} for zone in page[5:]):
                layout['preserve_line_order'] = True
            if i + 1 in damaged_symbols:
                layout['saved_source_lines'] = saved_source_lines
            missing_raster = False
            if raster is None:
                # A failed batch may contain valid pages. Retry individually so
                # the error identifies the page and recover if every page decodes.
                frame = render(i + 1, 1, f'изображение скана, страница {i+1}')
                missing_raster = frame is None
                if missing_raster:
                    rgb, w, h = None, 0, 0
                else:
                    rgb, w, h = ppm(frame, book.fail)
            else:
                rgb, w, h, offset = ppm_page(raster, book.fail, offset)
            if missing_raster:
                saved = emit_page(book, i + 1, lines, rgb, w, h, pw, ph, missing_raster=True, **layout)
                (unreadable_rasters if saved else unreadable).append(i + 1)
                letters += saved
            else:
                letters += emit_page(book, i + 1, lines, rgb, w, h, pw, ph, **layout)
            book.progress('pages', i + 1, count)
        if raster is not None and offset != len(raster): book.fail('Число растровых страниц DjVu не совпало с запрошенным.')
    check_content(book, letters, 'DjVu')
    warn_about_unreadable_pages(book, unreadable)
    if unreadable_rasters:
        book.warnings.add(f'Изображения страниц исходника не читаются: {describe_pages(unreadable_rasters)}. '
                          'Текст страниц сохранён. В книге на этих страницах стоят отметки.')
    without_raster = set(unreadable + unreadable_rasters)
    damaged_text_pages = [page for page in damaged_text_pages if page not in without_raster]
    if damaged_text_pages:
        listing = describe_pages(damaged_text_pages)
        if book.omit_images:
            book.warnings.add(f'Не удалось прочитать текстовый слой страниц DjVu: {listing}. '
                              'В TXT на их местах стоят отметки. В FB2 или EPUB можно сохранить эти страницы изображениями.')
        else:
            book.warnings.add(f'Страницы DjVu с повреждённым текстовым слоем сохранены целиком изображениями: {listing}.')
    if damaged_symbols:
        message = (f'Нечитаемые символы DjVu на страницах {describe_pages(damaged_symbols)} отмечены знаком �. '
                   'Разборчивый текст сохранён.')
        if saved_source_lines:
            message += (f' На страницах {describe_pages(saved_source_lines)} рядом с текстом сохранены '
                        'изображения исходных строк с такими знаками.')
        book.warnings.add(message)
    for codes, pages in djvu_control_pages.items():
        numbers = describe_pages([number for number, _ in pages])
        message = f'Нечитаемые символы DjVu на страницах {numbers} помечены {", ".join(codes)}.'
        visible = [number for number, copied in pages if copied]
        if visible:
            message += f' На страницах {describe_pages(visible)} рядом сохранены изображения исходных строк.'
        book.warnings.add(message)
    if legacy_pages:
        book.warnings.add(f'Текстовый слой DjVu на страницах {describe_pages(legacy_pages)} прочитан в Windows-1251.')
    if not scan_pages:
        book.warnings.add('Текстовый слой DjVu обычно получен OCR. Возможны ошибки распознавания; сверьте важные цитаты с оригиналом.')


def read(book, extension):
    tools = book.tools_root
    if extension == '.pdf': read_pdf(book, tools)
    else: read_djvu(book, tools)
    if book.omit_images:
        book.warnings.add('В TXT сохранён исходный текстовый слой. Иллюстрации, расположение элементов и оформление таблиц не переносятся.')
    else:
        book.warnings.add('PDF/DjVu: текст перенесён в порядке чтения, строки и обнаруженные области иллюстраций сохранены. Страничная вёрстка, сложные таблицы и формулы могут отличаться; проверьте результат по оригиналу.')

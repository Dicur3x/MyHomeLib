"""Read-only RepliGo Palm database input (MIT).

The container carries glyph indexes and explicit line/run/word lengths. Text is
rebuilt from those lengths, never by guessing spaces from a language dictionary.
Raster strips and JPEG resources are decoded locally; no legacy viewer is run.
"""
import struct
import zlib

_OUTLINES = None


def outline_module():
    global _OUTLINES
    if _OUTLINES is None:
        import importlib.util
        from pathlib import Path
        spec = importlib.util.spec_from_file_location('homelib_rgo_outline', Path(__file__).with_name('rgo_outline.py'))
        _OUTLINES = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_OUTLINES)
    return _OUTLINES


class RGOError(ValueError):
    pass


class Bits:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def get(self, width):
        if self.pos + width > len(self.data) * 8:
            raise RGOError('Оборван числовой поток RGO.')
        value = 0
        for _ in range(width):
            value = (value << 1) | ((self.data[self.pos // 8] >> (7 - self.pos % 8)) & 1)
            self.pos += 1
        return value

    def unsigned(self, width):
        value = self.get(width)
        if width == 2 and value == 3:
            value = self.get(6)
            if value == 63:
                value = self.get(16)
        elif width == 4 and value == 15:
            value = self.get(8)
            if value == 255:
                value = self.get(16)
        elif width == 8 and value == 255:
            value = self.get(16)
        return value

    def signed(self, width):
        value = self.get(width)
        if value == 1 << (width - 1):
            if width == 2:
                return self.signed(6)
            if width == 4:
                high = self.get(4)
                if high == 8:
                    high = self.get(4)
                    if high == 8:
                        high = self.get(4)
                    value = (high << 12) | self.get(12)
                    return value - 65536 if value & 32768 else value
                value = (high << 4) | self.get(4)
                return value - 256 if value & 128 else value
            if width != 16:
                return self.signed(16)
        return value - (1 << width) if value & (1 << (width - 1)) else value


def integers(record, prefix=None):
    """Structural streams, including signed relative glyph positions."""
    _, codec, count, data = record
    full_count = count
    if prefix is not None:
        if prefix > count or prefix < 0:
            raise RGOError('Оборвана таблица разметки RGO.')
        count = prefix
    bits = Bits(data)
    if codec in (2, 4, 6):
        width = {2: 8, 4: 4, 6: 2}[codec]
        values = [bits.unsigned(width) for _ in range(count)]
    elif codec in (1, 3, 5):
        width = {1: 8, 3: 4, 5: 2}[codec]
        values = [bits.signed(width) for _ in range(count)]
    elif codec in (7, 8):
        values = []
        while len(values) < count:
            if codec == 7:
                value = bits.signed(4)
            else:
                value = bits.get(4)
                if value == 15:
                    high = bits.get(4)
                    value = bits.get(16) if high == 15 else (high << 4) | bits.get(4)
            repeat = bits.signed(4) if codec == 7 else bits.unsigned(4)
            if repeat == 0 or repeat > full_count - len(values):
                raise RGOError('Некорректная длина повтора RGO.')
            values.extend([value] * min(repeat, count - len(values)))
    elif codec == 12:
        if len(data) != full_count * 2:
            raise RGOError('Некорректная длина массива RGO.')
        return list(struct.unpack('>' + str(count) + 'H', data[:count * 2]))
    elif codec == 11:
        if len(data) != full_count:
            raise RGOError('Некорректная длина байтов RGO.')
        return list(data[:count])
    else:
        raise RGOError('Неизвестный числовой поток RGO: ' + str(codec) + '.')
    if prefix is None and len(data) * 8 - bits.pos > 7:
        raise RGOError('Лишние данные в числовом потоке RGO.')
    return values


class Document:
    def __init__(self, data):
        if len(data) < 80 or data[60:68] != b'.rgoCERI':
            raise RGOError('Это не документ RepliGo RGO.')
        count = struct.unpack_from('>H', data, 76)[0]
        if not count or 78 + count * 8 > len(data):
            raise RGOError('Оборвана таблица записей RGO.')
        offsets = [struct.unpack_from('>I', data, 78 + i * 8)[0] for i in range(count)] + [len(data)]
        if offsets[0] < 78 + count * 8 or any(a >= b for a, b in zip(offsets, offsets[1:])):
            raise RGOError('Некорректные границы записей RGO.')
        self.records, self.pages, self.palettes, self.image_info = [], [], [], []
        dictionary, total, page = [], 0, None
        for start, end in zip(offsets, offsets[1:]):
            raw = data[start:end]
            if len(raw) < 6:
                raise RGOError('Оборвана запись RGO.')
            kind, codec, size = struct.unpack('>HHH', raw[:6])
            if codec & 128:
                if len(raw) < 8:
                    raise RGOError('Оборван заголовок сжатия RGO.')
                expected = struct.unpack_from('>H', raw, 6)[0]
                inflater = zlib.decompressobj()
                try:
                    body = inflater.decompress(raw[8:], 65537)
                except zlib.error as error:
                    raise RGOError('Повреждено сжатие RGO.') from error
                if len(body) != expected or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
                    raise RGOError('Некорректная распакованная длина RGO.')
            else:
                body = raw[6:]
            total += len(body)
            if total > 256 * 1024 * 1024:
                raise RGOError('Распакованный RGO превышает 256 МБ.')
            record = (kind, codec & 127, size, body)
            self.records.append(record)
            if kind == 5:
                try:
                    dictionary.append(body.decode('utf-8'))
                except UnicodeError as error:
                    raise RGOError('Повреждена таблица символов RGO.') from error
            elif kind == 6:
                self.palettes.append(body)
            elif kind == 39:
                values = integers(record)
                if len(values) % 7:
                    raise RGOError('Оборвано описание изображения RGO.')
                self.image_info.extend(tuple(values[i:i + 7]) for i in range(0, len(values), 7))
            elif kind == 2:
                if len(body) != 44:
                    raise RGOError('Неизвестный заголовок страницы RGO.')
                page = {'header': struct.unpack('>22H', body), 'records': {}}
                self.pages.append(page)
            elif page is not None:
                page['records'].setdefault(kind, []).append(record)
        self.dictionary = ''.join(dictionary)
        self._outline_glyphs = None
        if not self.pages:
            raise RGOError('В RGO нет страниц.')

    @staticmethod
    def one(page, kind, optional=False):
        matches = page['records'].get(kind, [])
        if len(matches) != 1:
            if optional and not matches:
                return []
            raise RGOError('Неоднозначный поток страницы RGO: ' + str(kind) + '.')
        return integers(matches[0])

    def text_lines(self, page):
        header = page['header']
        lines, runs, words, glyphs = header[9:13]
        if not lines:
            if runs or words or glyphs:
                raise RGOError('В RGO отсутствуют границы текстовых строк.')
            return []
        records = page['records'].get(11, [])
        if len(records) != 1 or records[0][2] != header[17]:
            raise RGOError('Повреждена таблица разметки RGO.')
        lengths = integers(records[0], lines + runs + words)
        indices = self.one(page, 22)
        if len(indices) != glyphs:
            raise RGOError('Не совпадают длины текста и разметки RGO.')
        line_runs, run_words = lengths[:lines], lengths[lines:lines + runs]
        word_glyphs = lengths[lines + runs:lines + runs + words]
        if sum(line_runs) != runs or sum(run_words) != words or sum(word_glyphs) != glyphs:
            raise RGOError('Повреждены границы слов RGO.')
        if any(index >= len(self.dictionary) for index in indices):
            raise RGOError('Символ RGO отсутствует в таблице шрифта.')
        text = ''.join(self.dictionary[index] for index in indices)
        outlined = any(ord(char) < 32 and char not in '\t\r\n' for char in text)
        if outlined:
            module = outline_module()
            glyphs = self.outline_glyphs()
            typography = self.one(page, 12)
            offsets_y, offsets_x = self.one(page, 19), self.one(page, 20)
            if len(typography) != lines * 5 or len(offsets_x) != len(text) or len(offsets_y) != len(text):
                raise RGOError('Не совпадают длины разметки контурного текста RGO.')
        result, run, word, letter = [], 0, 0, 0
        for paragraph, run_count in enumerate(line_runs):
            word_count = sum(run_words[run:run + run_count])
            parts = []
            start = letter
            for length in word_glyphs[word:word + word_count]:
                parts.append(text[letter:letter + length])
                letter += length
            if not any(ord(char) < 32 and char not in '\t\r\n' for char in text[start:letter]):
                result.append(' '.join(parts))
            else:
                flow, at, wi = [], start, word
                for count in run_words[run:run + run_count]:
                    words, labels = [], []
                    for size in word_glyphs[wi:wi + count]:
                        words.append([(p, indices[p]) for p in range(at, at + size)])
                        labels.append(text[at:at + size])
                        at += size
                    wi += count
                    label = ' '.join(labels)
                    if any(ord(char) < 32 and char not in '\t\r\n' for char in label):
                        try:
                            picture = module.line_png(words, glyphs, offsets_x, offsets_y,
                                                      typography[lines * 3 + paragraph], typography[lines * 2 + paragraph])
                        except module.OutlineError as error:
                            raise RGOError(str(error)) from error
                        flow.append(('outline', picture))
                    else:
                        flow.append(('text', label))
                result.append(flow)
            run += run_count
            word += word_count
        return result

    def outline_glyphs(self):
        if self._outline_glyphs is not None:
            return self._outline_glyphs
        module = outline_module()
        outlines = [r for r in self.records if r[0] == 37]
        counts = [integers(r) for r in self.records if r[0] == 35]
        dictionaries = [r[3].decode('utf8') for r in self.records if r[0] == 5]
        if not outlines or len(outlines) != len(counts) or len(counts) != len(dictionaries):
            raise RGOError('В RGO отсутствуют контуры встроенных букв.')
        glyphs = []
        try:
            for record, group, letters in zip(outlines, counts, dictionaries):
                if record[1] != 13 or len(group) != len(letters):
                    raise RGOError('Не совпадают таблицы встроенного шрифта RGO.')
                decoder = module.Decoder(record[3])
                for count in group:
                    glyphs.append(module.raster(decoder.glyph(count)))
                if decoder.pos != len(record[3]) * 2:
                    raise RGOError('Лишние данные в контурах шрифта RGO.')
        except module.OutlineError as error:
            raise RGOError(str(error)) from error
        self._outline_glyphs = glyphs
        return glyphs

    def blocks(self, page):
        """Reading ranks refer to physical text blocks; zero marks graphics."""
        header = page['header']
        lines, order, boxes = self.text_lines(page), self.one(page, 8), self.one(page, 7)
        ranks = [rank for rank in order if rank]
        if (len(order) != header[5] or len(boxes) != len(order) * 4 or
                sorted(ranks) != list(range(1, len(ranks) + 1))):
            raise RGOError('Неизвестный порядок блоков RGO.')
        refs = self.one(page, 38, optional=True)
        if len(refs) != header[6] * 5:
            raise RGOError('Не совпадает число иллюстраций страницы RGO.')
        contents = self.one(page, 10)
        result, line, image, cursor = [], 0, 0, 0
        for position, rank in enumerate(order):
            if cursor >= len(contents):
                raise RGOError('Оборван список элементов страницы RGO.')
            count = contents[cursor]
            cursor += 1
            if count > len(contents) - cursor:
                raise RGOError('Оборван состав блока RGO.')
            kinds = contents[cursor:cursor + count]
            cursor += count
            if rank == 0:
                before = next((rank for rank in order[position + 1:] if rank), len(ranks) + 1)
                rank = before - 0.5
                width, height = boxes[position * 4 + 2:position * 4 + 4]
                if width * height >= header[0] * header[1] * .8:
                    rank = 0  # Full-page cover/background before its text.
            block = []
            for kind in kinds:
                if kind == 2:
                    if line >= len(lines):
                        raise RGOError('Лишний текстовый элемент RGO.')
                    value = lines[line]
                    block.extend(value if isinstance(value, list) else [('text', value)])
                    line += 1
                elif kind == 1:
                    if image >= header[6]:
                        raise RGOError('Лишний графический элемент RGO.')
                    block.append(('image', refs[image * 5 + 2]))
                    image += 1
                elif kind not in (3, 4, 5, 6):
                    raise RGOError('Неизвестный элемент RGO: ' + str(kind) + '.')
            result.append((rank, block))
        if cursor != len(contents) or line != len(lines) or image != header[6]:
            raise RGOError('Не совпадает состав страницы RGO.')
        return [item for _, block in sorted(result, key=lambda item: item[0]) for item in block]

    def raster(self, index):
        if index >= len(self.image_info):
            raise RGOError('Изображение RGO отсутствует в таблице ресурсов.')
        width, height, _, _, depth, palette_id, start = self.image_info[index]
        if not width or not height or width * height > 16000000:
            raise RGOError('Недопустимые размеры изображения RGO.')
        if start >= len(self.records) or self.records[start][0] != 40:
            raise RGOError('Отсутствуют данные изображения RGO.')
        codec = self.records[start][1]
        chunks, rows = [], 0
        for kind, encoding, size, data in self.records[start:]:
            if kind != 40 or encoding != codec:
                break
            chunks.append(data)
            rows += size
            if sum(map(len, chunks)) > 16 * 1024 * 1024:
                raise RGOError('Изображение RGO превышает 16 МБ.')
            if codec == 16 and data.rstrip(b'\r\n\t ').endswith(b'\xff\xd9'):
                result = b''.join(chunks)
                if not result.startswith(b'\xff\xd8\xff'):
                    raise RGOError('Повреждено JPEG-изображение RGO.')
                return result
            if codec == 0 and rows >= height:
                break
        data = b''.join(chunks)
        if codec != 0 or rows != height or depth not in (8, 24) or len(data) != width * height * (depth // 8):
            raise RGOError('Неизвестное или оборванное изображение RGO.')
        if depth == 8:
            if palette_id >= len(self.palettes):
                raise RGOError('Отсутствует палитра изображения RGO.')
            palette = self.palettes[palette_id]
            if len(palette) % 3 or len(palette) > 768:
                raise RGOError('Некорректная палитра RGO.')
            # 255 represents the paper behind a palette image.
            colors = [palette[i:i + 3] for i in range(0, len(palette), 3)]
            if any(value != 255 and value >= len(colors) for value in data):
                raise RGOError('Цвет изображения RGO отсутствует в палитре.')
            palette += b'\xff\xff\xff' * (256 - len(colors))
            return png(width, height, data, palette)
        return png(width, height, data)


def png(width, height, pixels, palette=None):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    stride = width if palette is not None else width * 3
    rows = b''.join(b'\0' + pixels[i:i + stride] for i in range(0, len(pixels), stride))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 3 if palette is not None else 2, 0, 0, 0)) +
            (chunk(b'PLTE', palette) if palette is not None else b'') +
            chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def read(book, data):
    try:
        document = Document(data)
        for number, page in enumerate(document.pages, 1):
            book.progress('reading', number, len(document.pages))
            header = page['header']
            section = book.el('section', id='rgo-page-' + str(number))
            section.append(book.el('h2', 'Страница ' + str(number)))
            book.body.append(section)
            for kind, value in document.blocks(page):
                if kind == 'text':
                    section.append(book.el('p', value))
                else:
                    if kind == 'outline' and book.omit_images:
                        book.fail('В этой RGO-книге текст сохранён контурами букв. Режим без изображений удалит сам текст; выберите сохранение изображений.')
                    paragraph = book.el('p')
                    paragraph.append(book.image(value if kind == 'outline' else document.raster(value)))
                    section.append(paragraph)
                    if kind == 'outline':
                        book.warnings.add('RGO: буквы без таблицы Unicode сохранены чёткими изображениями строк из встроенного шрифта. Текст этих строк можно читать, но нельзя выделять, искать или менять размер букв отдельно от изображения. OCR не выполняется.')
        book.warnings.add('RGO: сохранены текст, границы строк, порядок страниц и растровые иллюстрации; исходные шрифты и расположение элементов адаптированы для чтения.')
        if any(page['header'][7] for page in document.pages):
            book.warnings.add('RGO содержит векторные элементы оформления: их исходный вид пока не перенесён. Текст и растровые иллюстрации сохранены.')
    except RGOError as error:
        book.fail(str(error))

"""Read-only iSilo 3 text streams (MIT).

The Huffman alphabet, repeat codes and LZ lengths follow RFC 1951. iSilo
stores a shared tree separately from its 4 KiB blocks, in big-endian words
whose bits are consumed from the least significant end. No viewer is run.
"""
import struct
import zlib

_IMAGE_DECODER = None


class ISiloError(ValueError):
    pass


class Bits:
    def __init__(self, data):
        if len(data) % 4:
            raise ISiloError('Оборвано 32-битное слово iSilo.')
        self.data = b''.join(data[i:i + 4][::-1] for i in range(0, len(data), 4))
        self.position = 0

    def read(self, count):
        if count < 0 or self.position + count > len(self.data) * 8:
            raise ISiloError('Оборван сжатый поток iSilo.')
        value = 0
        for shift in range(count):
            at = self.position
            value |= ((self.data[at // 8] >> (at % 8)) & 1) << shift
            self.position += 1
        return value

    def finish(self, unused):
        remaining = len(self.data) * 8 - self.position
        if unused > 3 or remaining // 8 != unused:
            raise ISiloError('Неверная граница сжатого блока iSilo.')
        # These bits are explicitly outside the coded stream; historical
        # writers leave their values unspecified rather than clearing them.
        self.position += remaining


class Huffman:
    def __init__(self, lengths):
        if not lengths or not any(lengths) or any(n < 0 or n > 15 for n in lengths):
            raise ISiloError('Неверная таблица Хаффмана iSilo.')
        self.maximum = max(lengths)
        counts = [lengths.count(n) for n in range(16)]
        counts[0] = 0
        code, codes = 0, [0] * 16
        for width in range(1, 16):
            code = (code + counts[width - 1]) << 1
            if code + counts[width] > 1 << width:
                raise ISiloError('Пересекающиеся коды Хаффмана iSilo.')
            codes[width] = code
        self.table = {}
        for symbol, width in enumerate(lengths):
            if width:
                self.table[width, codes[width]] = symbol
                codes[width] += 1

    def read(self, bits):
        value = 0
        for width in range(1, self.maximum + 1):
            value = (value << 1) | bits.read(1)
            result = self.table.get((width, value))
            if result is not None:
                return result
        raise ISiloError('Неизвестный код Хаффмана iSilo.')


ORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)
LENGTHS = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
           35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258)
LENGTH_BITS = (0,) * 8 + (1,) * 4 + (2,) * 4 + (3,) * 4 + (4,) * 4 + (5,) * 4 + (0,)
DISTANCES = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
             257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577)
DISTANCE_BITS = (0,) * 4 + tuple(n for n in range(1, 14) for _ in range(2))


def code_lengths(bits, master, count):
    values = []
    while len(values) < count:
        symbol = master.read(bits)
        if symbol < 16:
            values.append(symbol)
            continue
        if symbol == 16:
            if not values:
                raise ISiloError('Повтор без предыдущего кода iSilo.')
            value, repeat = values[-1], bits.read(2) + 3
        elif symbol == 17:
            value, repeat = 0, bits.read(3) + 3
        else:
            value, repeat = 0, bits.read(7) + 11
        if repeat > count - len(values):
            raise ISiloError('Повтор выходит за границу таблицы iSilo.')
        values.extend([value] * repeat)
    return values


def trees(bits):
    literals, distances, master_count = bits.read(5) + 257, bits.read(5) + 1, bits.read(4) + 4
    if literals > 286 or distances > 30:
        raise ISiloError('Слишком большая таблица сжатия iSilo.')
    lengths = [0] * 19
    for symbol in ORDER[:master_count]:
        lengths[symbol] = bits.read(3)
    master = Huffman(lengths)
    lengths = code_lengths(bits, master, literals + distances)
    if not lengths[256]:
        raise ISiloError('Нет кода окончания текста iSilo.')
    return Huffman(lengths[:literals]), Huffman(lengths[literals:])


def inflate(bits, text, distance, expected):
    result = bytearray()
    while True:
        symbol = text.read(bits)
        if symbol == 256:
            if len(result) != expected:
                raise ISiloError('Длина распакованного текста iSilo не совпадает с заголовком.')
            return bytes(result)
        if symbol < 256:
            result.append(symbol)
        else:
            index = symbol - 257
            count = LENGTHS[index] + bits.read(LENGTH_BITS[index])
            index = distance.read(bits)
            if index >= len(DISTANCES):
                raise ISiloError('Неверная дальность ссылки iSilo.')
            back = DISTANCES[index] + bits.read(DISTANCE_BITS[index])
            if back > len(result) or count > expected - len(result):
                raise ISiloError('Ссылка выходит за границы текста iSilo.')
            for _ in range(count):
                result.append(result[-back])
        if len(result) > expected:
            raise ISiloError('Распакованный блок iSilo слишком велик.')


def text_record(record, expected):
    if len(record) < 12 or record[:2] != b'\x04\0' or record[4:6] != b'\x02\0':
        raise ISiloError('Неизвестное сжатие текстовой записи iSilo.')
    count = struct.unpack_from('>H', record, 6)[0]
    if not 2 <= count <= 9 or not 0 < expected <= (count - 1) * 4096:
        raise ISiloError('Неверное число блоков iSilo.')
    first_tree = (8 + count * 3 + 3) // 4 * 4
    if len(record) < first_tree:
        raise ISiloError('Оборвана таблица блоков iSilo.')
    offsets = [struct.unpack_from('>H', record, 8 + 2 * n)[0] * 4 for n in range(count)]
    padding = record[8 + count * 2:8 + count * 3]
    if (offsets[0] < first_tree or offsets[-1] != len(record) or
            any(a > b for a, b in zip(offsets, offsets[1:]))):
        raise ISiloError('Неверные смещения блоков iSilo.')
    bits = Bits(record[first_tree:offsets[0]])
    text, distance = trees(bits)
    bits.finish(padding[0])
    result = bytearray()
    for number, (start, end) in enumerate(zip(offsets, offsets[1:]), 1):
        if len(result) == expected:
            if start != end or padding[number]:
                raise ISiloError('Лишний блок после текста iSilo.')
            continue
        if start == end:
            raise ISiloError('Отсутствует текстовый блок iSilo.')
        bits = Bits(record[start:end])
        result.extend(inflate(bits, text, distance, min(4096, expected - len(result))))
        bits.finish(padding[number])
    if len(result) != expected:
        raise ISiloError('Оборван текст iSilo.')
    return bytes(result)


class Document:
    def __init__(self, records, maximum=64 * 1024 * 1024):
        if not records or len(records[0]) < 56 or records[0][2:6] != b'\x03\0\x03\0':
            raise ISiloError('Неизвестный заголовок iSilo 3.')
        self.records = records
        self.length = struct.unpack_from('>I', records[0], 20)[0]
        if not 0 < self.length <= maximum:
            raise ISiloError('Длина текста iSilo превышает допустимый предел.')

    def text(self):
        chunks, remaining = [], self.length
        for record in self.records[1:]:
            if record[:2] != b'\x04\0':
                continue
            if not remaining:
                raise ISiloError('Лишние текстовые записи iSilo.')
            expected = min(32768, remaining)
            chunks.append(text_record(record, expected))
            remaining -= expected
        if remaining:
            raise ISiloError('В iSilo отсутствуют текстовые записи.')
        return b''.join(chunks)

    def picture_groups(self):
        """Validate image references without decoding an explicitly omitted raster."""
        indexes = [i for i, record in enumerate(self.records) if record[:2] == b'\x04\x04']
        if not indexes:
            return
        image_indexes = set(indexes)
        roots = {}
        for record in self.records:
            if record[:2] != b'\x04\x05' or record[4:6] != b'\x06\0':
                continue
            if len(record) < 12:
                raise ISiloError('Оборвана таблица изображений iSilo.')
            count = struct.unpack_from('>I', record, 6)[0] + 1
            size = struct.unpack_from('>H', record, 10)[0]
            start = 14 if self.records[0][1] & 128 else 12
            if size != count * 8 or start + size > len(record):
                raise ISiloError('Неверная длина таблицы изображений iSilo.')
            for position in range(start, start + size, 8):
                entry = record[position:position + 8]
                index = struct.unpack_from('>H', entry, 4)[0]
                if index not in image_indexes:
                    raise ISiloError('В iSilo отсутствует часть изображения.')
                roots.setdefault(index, tuple(entry[2:4]))
        keys = sorted(roots)
        if not keys or keys[0] != indexes[0]:
            raise ISiloError('В iSilo отсутствует таблица размеров изображений.')
        for position, first in enumerate(keys):
            end = keys[position + 1] if position + 1 < len(keys) else indexes[-1] + 1
            group = self.records[first:end]
            if not group or any(record[:2] != b'\x04\x04' for record in group):
                raise ISiloError('Оборвана последовательность частей изображения iSilo.')
            yield group, roots[first]

    def pictures(self):
        for group, dimensions in self.picture_groups():
            parts = [bitmap_raster(record) for record in group]
            horizontal = len({part[1] for part in parts}) == 1
            vertical = len({part[0] for part in parts}) == 1
            options = []
            if horizontal:
                options.append((sum(part[0] for part in parts), parts[0][1], True))
            if vertical and len(parts) > 1:
                options.append((parts[0][0], sum(part[1] for part in parts), False))
            options = [value for value in options if (value[0] % 256, value[1] % 256) == dimensions]
            if len(options) != 1 or options[0][0] * options[0][1] > 16000000:
                raise ISiloError('Неизвестное расположение частей изображения iSilo.')
            width, height, horizontal = options[0]
            alpha = any(part[3] for part in parts)
            if alpha:
                parts = [(w, h, bytes(v for i in range(0, len(pixels), 3) for v in (*pixels[i:i + 3], 255)) if not has_alpha else pixels, True)
                         for w, h, pixels, has_alpha in parts]
            unit = 4 if alpha else 3
            if horizontal:
                pixels = b''.join(pixels[y * w * unit:(y + 1) * w * unit]
                                  for y in range(height) for w, _, pixels, _ in parts)
            else:
                pixels = b''.join(part[2] for part in parts)
            yield png(width, height, pixels, alpha)


def unpack_bitmap(data, stride, height, method, unit):
    expected, at, output = stride * height, 0, bytearray()
    if method == 0:
        previous = bytearray(stride)
        for _ in range(height):
            row = bytearray(previous)
            for start in range(0, stride, 8):
                if at == len(data):
                    raise ISiloError('Оборвана маска строки Palm Bitmap.')
                flags = data[at]
                at += 1
                for bit in range(min(8, stride - start)):
                    if flags & (128 >> bit):
                        if at == len(data):
                            raise ISiloError('Оборвана строка Palm Bitmap.')
                        row[start + bit] = data[at]
                        at += 1
            output.extend(row)
            previous = row
    else:
        while at < len(data) and len(output) < expected:
            count = data[at]
            at += 1
            if method == 1:
                if not count or at == len(data):
                    raise ISiloError('Оборван повтор Palm Bitmap.')
                output.extend(data[at:at + 1] * count)
                at += 1
            elif count < 128:
                count = (count + 1) * unit
                if count > len(data) - at:
                    raise ISiloError('Оборван литерал Palm Bitmap.')
                output.extend(data[at:at + count])
                at += count
            elif count > 128:
                if unit > len(data) - at:
                    raise ISiloError('Оборван цвет Palm Bitmap.')
                output.extend(data[at:at + unit] * (257 - count))
                at += unit
            else:
                # TIFF's reserved no-op is also emitted by some Palm writers.
                continue
            if len(output) > expected:
                raise ISiloError('Растр Palm Bitmap превышает размер из заголовка.')
    if len(output) != expected or at != len(data):
        raise ISiloError('Размер растра Palm Bitmap не совпадает с заголовком.')
    return bytes(output)


def bitmap_raster(record):
    if len(record) < 20 or record[:2] != b'\x04\x04':
        raise ISiloError('Оборвано изображение iSilo.')
    if record[4:6] == b'\x0c\x03' and record[13] != 2:
        global _IMAGE_DECODER
        if _IMAGE_DECODER is None:
            import importlib.util
            from pathlib import Path
            spec = importlib.util.spec_from_file_location('homelib_isilo_image', Path(__file__).with_name('isilo_image.py'))
            _IMAGE_DECODER = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(_IMAGE_DECODER)
        try:
            return _IMAGE_DECODER.grayscale(record, Huffman, ORDER, code_lengths)
        except ValueError as error:
            raise ISiloError(str(error)) from error
    width, height, stride, flags, depth, version, next_depth, transparent, method, reserved = struct.unpack('>4H2BH2BH', record[4:20])
    if (version != 2 or depth not in (1, 2, 4, 16) or not width or not height or
            width * height > 16000000 or stride < (width * depth + 7) // 8 or
            stride * height > 32 * 1024 * 1024 or next_depth or
            flags & ~0xa400 or reserved):
        raise ISiloError('Неподдерживаемый или повреждённый Palm Bitmap в iSilo.')
    at, transparent_color = 20, None
    if depth == 16:
        if not flags & 0x400 or len(record) < 28 or record[20:23] != b'\x05\x06\x05':
            raise ISiloError('Неизвестное представление цвета Palm Bitmap.')
        if flags & 0x2000:
            transparent_color = tuple(record[25:28])
        at = 28
    elif flags & 0x400:
        raise ISiloError('Неверная глубина прямого цвета Palm Bitmap.')
    if flags & 0x8000:
        if len(record) < at + 2 or struct.unpack_from('>H', record, at)[0] != len(record) - at:
            raise ISiloError('Оборвано сжатое изображение Palm Bitmap.')
        payload = record[at + 2:]
        if method not in (0, 1, 2):
            raise ISiloError('Неизвестное сжатие Palm Bitmap.')
        # Real iSilo writers also store scanline/RLE rasters with the PackBits
        # tag. Accept a fallback only when the complete byte count validates
        # uniquely; conflicting successful decoders are never guessed between.
        candidates = []
        for algorithm in ((0, 1, 2) if method == 2 else (method,)):
            try:
                raw = unpack_bitmap(payload, stride, height, algorithm, 2 if depth == 16 else 1)
                if raw not in candidates:
                    candidates.append(raw)
            except ISiloError:
                pass
        if len(candidates) != 1:
            raise ISiloError('Сжатие изображения iSilo повреждено или неоднозначно.')
        raw = candidates[0]
    else:
        raw = record[at:]
        if len(raw) != stride * height:
            raise ISiloError('Оборван несжатый Palm Bitmap.')
    alpha = bool(flags & 0x2000)
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            if depth == 16:
                value = struct.unpack_from('>H', raw, y * stride + x * 2)[0]
                red, green, blue = value >> 11, (value >> 5) & 63, value & 31
                color = ((red << 3) | (red >> 2), (green << 2) | (green >> 4), (blue << 3) | (blue >> 2))
                opaque = color != transparent_color
            else:
                value = (raw[y * stride + x * depth // 8] >> (8 - depth - x * depth % 8)) & ((1 << depth) - 1)
                shade = 255 - value * 255 // ((1 << depth) - 1)
                color, opaque = (shade,) * 3, value != transparent
            pixels.extend(color)
            if alpha:
                pixels.append(255 if opaque else 0)
    return width, height, bytes(pixels), alpha


def bitmap(record):
    return png(*bitmap_raster(record))


def png(width, height, pixels, alpha=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    stride = width * (4 if alpha else 3)
    rows = b''.join(b'\0' + pixels[i:i + stride] for i in range(0, len(pixels), stride))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6 if alpha else 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def read(book, records, decode, paragraphs):
    try:
        document = Document(records, book.c.MAX_FILE)
        text = decode(document.text())
        omit_images = book.omit_images
        if omit_images and not text.replace('\x00', '').strip():
            book.fail('В iSilo нет читаемого текста. Режим без изображений оставил бы пустую книгу.')
        paragraphs(book, text)
        section = None
        # Explicit text-only export validates the image table, but never needs
        # the raster codec or buffers for pictures which the user has omitted.
        pictures = (None for _ in document.picture_groups()) if omit_images else document.pictures()
        for number, data in enumerate(pictures, 1):
            if section is None:
                section = book.el('section', id='isilo-illustrations')
                section.append(book.el('h2', 'Иллюстрации'))
                book.body.append(section)
            paragraph = book.el('p')
            if omit_images:
                paragraph.append(book.el('em', '[Изображение не включено в эту копию]'))
            else:
                image = book.image(data)
                image.set('alt', 'Иллюстрация ' + str(number))
                paragraph.append(image)
            section.append(paragraph)
        book.warnings.add('iSilo: сохранён весь текст. Исходные шрифты, таблицы и гиперссылки представлены обычным текстом; кодировка старой книги определяется автоматически.')
        if section is not None and omit_images:
            book.warnings.add('iSilo сохранён без изображений по выбранному режиму. Пометки об иллюстрациях помещены в конце книги; исходная книга сохранена.')
        elif section is not None:
            book.warnings.add('Иллюстрации iSilo собраны из всех частей без уменьшения и помещены в отдельный раздел в конце книги; исходное расположение в тексте не перенесено.')
    except ISiloError as error:
        book.fail(str(error))

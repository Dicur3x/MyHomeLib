"""Bounded decoder for the nibble-coded rectilinear glyphs in RepliGo (MIT).

Coordinates describe horizontal-then-vertical edges, not diagonal line segments.
Every glyph starts at (0, 0), on a byte boundary; later contours have relative
origins. Character identities are deliberately not inferred from glyph shapes.
"""


class OutlineError(ValueError):
    pass


SMALL = ((1, 1), (2, 1), (3, 1), (4, 1), (1, 2), (1, 3),
         (1, 4), (-1, 1), (-1, 2), (-1, 3), (1, -1), (2, -1), (3, -1))
EXTENDED = ((5, 1), (6, 1), (7, 1), (2, 2), (1, 5), (1, 6), (1, 7),
            (-2, 1), (-3, 1), (-2, 2), (-1, 4), (4, -1),
            (1, -2), (2, -2), (1, -3), (-1, -1))


def _long_table():
    rows = (
        (1, 1, ((8, 20), (3, 12), (2, 10), (2, 10), (2, 8), (2, 6),
                (2, 6), (1, 5), (1, 4), (1, 4), (1, 3), (1, 3), (1, 2),
                (1, 2), (1, 2)) + ((1, 1),) * 5),
        (-1, 1, ((4, 15), (3, 10), (2, 10), (2, 8), (1, 6), (1, 5),
                 (1, 5), (1, 4), (1, 3), (1, 3), (1, 2), (1, 2)) + ((1, 1),) * 3),
        (1, -1, ((5, 15), (3, 10), (2, 8), (1, 4), (1, 3), (1, 1), (1, 1))),
        (-1, -1, ((2, 15), (1, 10), (1, 8), (1, 4), (1, 3), (1, 1), (1, 1))),
    )
    return tuple((sx * x, sy * y) for sx, sy, ranges in rows
                 for y, (lo, hi) in enumerate(ranges, 1)
                 for x in range(lo, hi + 1)) + ((0, -256),)


LONG = _long_table()
assert len(LONG) == 234


class Decoder:
    def __init__(self, data, offset=0, max_steps=2000000):
        if not 0 <= offset <= len(data):
            raise OutlineError('Недопустимое начало контура RGO.')
        self.data, self.pos = data, offset * 2
        self.sx = self.sy = 1
        self.x = self.y = self.mode = self.stop_x = 0
        self.saved = None
        self.steps, self.max_steps = 0, max_steps

    def take(self, nibbles=1):
        if self.pos + nibbles > len(self.data) * 2:
            raise OutlineError('Оборван контур шрифта RGO.')
        value = 0
        for _ in range(nibbles):
            value = value * 16 + ((self.data[self.pos // 2] >> (0 if self.pos & 1 else 4)) & 15)
            self.pos += 1
        return value

    def scalar(self, width, signed=True):
        value = self.take(width // 4)
        return value - (1 << width) if signed and value & (1 << (width - 1)) else value

    def move(self):
        if self.mode != 1:
            raise OutlineError('Не завершён предыдущий контур RGO.')
        x = self.take()
        if x == 8:
            x = self.scalar(8)
            if x == -128:
                x = self.scalar(16)
        elif x > 7:
            x -= 16
        y = self.take()
        if y == 15:
            y = self.scalar(8)
            if y == -128:
                y = self.scalar(16)
        self.sx, self.sy, self.mode = -1, 1, 0
        return x, y

    def wide(self, selector, signed=True):
        if not 0xf7 <= selector <= 0xff:
            raise OutlineError('Неизвестный код координат RGO: ' + hex(selector) + '.')
        index = selector - 0xf7
        return self.scalar((4, 8, 16)[index // 3], signed), self.scalar((4, 8, 16)[index % 3], signed)

    def step(self):
        self.steps += 1
        if self.steps > self.max_steps:
            raise OutlineError('Превышен предел сложности контуров RGO.')
        if self.mode == 1:
            raise OutlineError('Вместо нового контура RGO ожидалось смещение.')
        if self.mode in (2, 4):
            dx, dy = self.sx, self.sy
            if self.mode == 2:
                self.mode = 0
        else:
            # A definition marker emits no geometry. A reference has only one
            # return slot; nested references are invalid, rather than unbounded.
            for _ in range(len(self.data) * 2 + 1):
                token = self.take()
                if token < 13:
                    dx, dy = SMALL[token]
                elif token == 13:
                    self.mode = 2
                    dx, dy = 1, 1
                elif token == 14:
                    dx, dy = EXTENDED[self.take()]
                else:
                    selector = self.take(2)
                    if selector < 234:
                        dx, dy = LONG[selector]
                    elif selector == 0xeb:
                        continue
                    elif selector == 0xec:
                        target = self.take(4)
                        if self.saved is not None or target >= len(self.data):
                            raise OutlineError('Недопустимая ссылка на контур RGO.')
                        target_pos = target * 2 + (3 if self.data[target] == 0xfe else 4)
                        if target_pos >= self.pos or target_pos < 3:
                            raise OutlineError('Контур RGO ссылается вперёд или на себя.')
                        marker_pos = target_pos - 3
                        if ''.join(format((self.data[p // 2] >> (0 if p & 1 else 4)) & 15, 'x')
                                   for p in range(marker_pos, target_pos)) != 'feb':
                            raise OutlineError('Отсутствует определение контура RGO.')
                        self.saved = (self.pos, self.sx, self.sy, self.x, self.y, self.stop_x)
                        self.pos, self.sx, self.sy, self.stop_x = target_pos, -1, 1, 0
                        continue
                    elif selector == 0xea:
                        self.mode = 4
                        first = self.take()
                        dx, dy = self.wide(self.take(2), False) if first == 15 else (first, self.take())
                    else:
                        dx, dy = self.wide(selector)
                dx, dy = dx * self.sx, dy * self.sy
                if self.mode == 4:
                    self.stop_x = self.x + dx + self.sx * 11
                    dx, dy = self.sx, self.sy
                else:
                    self.sx = 1 if dx >= 0 else -1
                    self.sy = 1 if dy >= 0 else -1
                break
            else:
                raise OutlineError('Зацикленный контур RGO.')
        self.x += dx
        self.y += dy
        if max(abs(self.x), abs(self.y)) > 32767:
            raise OutlineError('Недопустимые координаты контура RGO.')
        if self.mode == 4 and self.x == self.stop_x:
            self.mode, self.stop_x = 0, 0
        if self.x == self.y == 0:
            if self.saved is not None:
                self.pos, self.sx, self.sy, self.x, self.y, self.stop_x = self.saved
                self.saved = None
            self.mode = 1
        return dx, dy

    def glyph(self, extra_contours):
        count = 0 if extra_contours == 65535 else extra_contours + 1
        if not 0 <= count <= 256:
            raise OutlineError('Слишком много контуров буквы RGO.')
        result, ox, oy = [], 0, 0
        for index in range(count):
            if index:
                dx, dy = self.move()
                ox, oy = ox + dx, oy + dy
            x, y = ox, oy
            contour = [(x, y)]
            while True:
                dx, dy = self.step()
                if dx:
                    x += dx
                    contour.append((x, y))
                if dy:
                    y += dy
                    contour.append((x, y))
                if self.mode == 1:
                    break
            result.append(contour)
        # Glyphs, unlike contours, start on a byte boundary with positive signs.
        self.pos = (self.pos + 1) & ~1
        self.sx = self.sy = 1
        self.mode = 0
        return result


def raster(contours, max_pixels=16000000):
    """One-bit even/odd fill of integer rectilinear edges, including holes."""
    points = [point for contour in contours for point in contour]
    if not points:
        return 0, 0, 0, 0, []
    left, top = map(min, zip(*points))
    right, bottom = map(max, zip(*points))
    width, height = right - left, bottom - top
    if width < 0 or height < 0 or width * height > max_pixels:
        raise OutlineError('Слишком большое изображение шрифта RGO.')
    rows = [[] for _ in range(height)]
    for contour in contours:
        if not contour or contour[0] != contour[-1]:
            raise OutlineError('Незамкнутый контур буквы RGO.')
        for (x1, y1), (x2, y2) in zip(contour, contour[1:]):
            if x1 != x2 and y1 != y2:
                raise OutlineError('Непрямоугольный контур буквы RGO.')
            if y1 != y2:
                for y in range(min(y1, y2), max(y1, y2)):
                    rows[y - top].append(x1 - left)
    spans = []
    for row in rows:
        row.sort()
        if len(row) & 1:
            raise OutlineError('Нарушена граница буквы RGO.')
        spans.append(list(zip(row[::2], row[1::2])))
    return width, height, left, top, spans


def line_png(words, glyphs, offsets_x, offsets_y, letter_gap, word_gap):
    """Keep the stored glyphs, side bearings, word gaps and baseline offsets.

    One-bit PNGs keep outlined text sharp and small; this is not OCR. Offsets
    are indexed by glyph position on the page, not by the glyph's font index.
    """
    import struct
    import zlib
    placed, cursor = [], 0
    for word in words:
        for number, (position, index) in enumerate(word):
            width, height, _, _, rows = glyphs[index]
            cursor += (letter_gap if number else word_gap) + offsets_x[position]
            if width and height:
                placed.append((cursor, offsets_y[position] - height, width, height, rows))
            cursor += width
    if not placed:
        raise OutlineError('В строке RGO не найдено изображений букв.')
    left = min(item[0] for item in placed)
    top = min(item[1] for item in placed)
    right = max(item[0] + item[2] for item in placed)
    bottom = max(item[1] + item[3] for item in placed)
    width, height = right - left, bottom - top
    if not 0 < width <= 32768 or not 0 < height <= 8192 or width * height > 16000000:
        raise OutlineError('Слишком большая строка RGO.')
    stride = (width + 7) // 8
    pixels = bytearray(b'\xff' * (stride * height))
    for x, y, _, _, rows in placed:
        for row, spans in enumerate(rows):
            at = (y - top + row) * stride
            for a, b in spans:
                a, b = a + x - left, b + x - left
                # Most glyph edges span only a few pixels. Whole bytes avoid
                # the per-pixel loop for long horizontal stems and large fonts.
                while a < b and a & 7:
                    pixels[at + a // 8] &= ~(128 >> (a & 7))
                    a += 1
                last = b & ~7
                if a < last:
                    pixels[at + a // 8:at + last // 8] = b'\0' * ((last - a) // 8)
                    a = last
                while a < b:
                    pixels[at + a // 8] &= ~(128 >> (a & 7))
                    a += 1
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\0' + pixels[i:i + stride] for i in range(0, len(pixels), stride))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 1, 0, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))

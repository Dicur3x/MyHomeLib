"""Bounded iSilo grayscale DCT image decoding (MIT).

The container uses independently byte-framed32x32 spatial tiles. Each tile
contains row-ordered8x8 DCT blocks. Quantization uses the JPEG luminance
table/quality scale; output is lossless RGB for the common Palm raster path.
No author encoder, viewer or native image codec is needed.
"""
import math
import struct

class ISiloImageError(ValueError):
    pass


class ImageBits:
    def __init__(self, data):
        self.data = data
        self.position = 0

    def read(self, count):
        if count < 0 or count > 24 or self.position + count > len(self.data) * 8:
            raise ISiloImageError('Оборван сжатый блок изображения iSilo.')
        at = self.position
        self.position += count
        if count == 1:
            return (self.data[at // 8] >> (at % 8)) & 1
        first, shift = at // 8, at % 8
        value = int.from_bytes(self.data[first:first + (shift + count + 7) // 8], 'little')
        return (value >> shift) & ((1 << count) - 1)

    def finish(self):
        unused = len(self.data) * 8 - self.position
        if unused > 7 or self.read(unused):
            raise ISiloImageError('Лишние данные в сжатом блоке изображения iSilo.')


LUMINANCE = (
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
)
ZIGZAG = []
for _diagonal in range(15):
    _pairs = [(y, _diagonal - y) for y in range(8) if 0 <= _diagonal - y < 8]
    ZIGZAG.extend(y * 8 + x for y, x in (_pairs[::-1] if _diagonal % 2 == 0 else _pairs))
ZIGZAG = tuple(ZIGZAG)
BASIS = tuple(tuple(math.cos((2 * x + 1) * k * math.pi / 16) *
                    (1 / math.sqrt(2) if k == 0 else 1) / 2
                    for k in range(8)) for x in range(8))


def coefficient_blocks(tree, data, width, height):
    bits = ImageBits(data)
    for _ in range(((width + 7) // 8) * ((height + 7) // 8)):
        block = []
        while len(block) < 64:
            symbol = tree.read(bits)
            if symbol < 256:
                block.append(symbol - 128)
            elif symbol == 260:
                block.extend([0] * (3 + bits.read(2)))
            elif 261 <= symbol <= 267:
                # Long zero runs are groups of eight with three low bits,
                # rather than progressively wider binary categories.
                block.extend([0] * (7 + (symbol - 261) * 8 + bits.read(3)))
            elif symbol == 268:
                block.extend([0] * (64 - len(block)))
            else:
                raise ISiloImageError('Неподдерживаемый расширенный коэффициент изображения iSilo.')
            if len(block) > 64:
                raise ISiloImageError('Серия нулей выходит за границу блока изображения iSilo.')
        yield block
    bits.finish()


def image_tiles(data, width, height):
    at = 0
    for y in range(0, height, 32):
        for x in range(0, width, 32):
            if at >= len(data):
                raise ISiloImageError('Отсутствует часть изображения iSilo.')
            size = data[at]
            at += 1
            if size >= 240:
                if at >= len(data):
                    raise ISiloImageError('Оборвана длина части изображения iSilo.')
                size = ((size - 240) << 8) | data[at]
                at += 1
            if not size or at + size > len(data):
                raise ISiloImageError('Неверная длина части изображения iSilo.')
            yield x, y, min(32, width - x), min(32, height - y), data[at:at + size]
            at += size
    if at != len(data):
        raise ISiloImageError('Лишние части изображения iSilo.')


def inverse_block(coefficients, quantization):
    natural = [0] * 64
    for at, value in zip(ZIGZAG, coefficients):
        natural[at] = value * quantization[at]
    if not any(natural[1:]):
        shade = max(0, min(255, math.floor(128 + natural[0] / 8 + .5)))
        return bytes([shade] * 64)
    intermediate = []
    for row in range(8):
        active = [(k, natural[row * 8 + k]) for k in range(8) if natural[row * 8 + k]]
        intermediate.append([sum(value * BASIS[x][k] for k, value in active) for x in range(8)])
    return bytes(max(0, min(255, math.floor(128 +
                 sum(BASIS[y][k] * intermediate[k][x] for k in range(8)) + .5)))
                 for y in range(8) for x in range(8))


def grayscale(record, huffman_type, length_order, read_code_lengths):
    if len(record) < 18 or record[:2] != b'\x04\x04' or record[4:6] != b'\x0c\x03':
        raise ISiloImageError('Оборвано полутоновое изображение iSilo.')
    quality, flags, width, height, table_end = struct.unpack_from('>BBHHH', record, 6)
    table_end += 4
    table_size = int.from_bytes(record[14:17], 'big')
    if (not 1 <= quality <= 100 or flags or not width or not height or
            width * height > 16000000 or table_end != 17 + table_size or
            not 0 < table_size <= 4096 or table_end > len(record)):
        raise ISiloImageError('Неверный заголовок полутонового изображения iSilo.')
    bits = ImageBits(record[17:table_end])
    count = bits.read(5) + 4
    if count > len(length_order):
        raise ISiloImageError('Слишком большая таблица кодов изображения iSilo.')
    lengths = [0] * 19
    for symbol in length_order[:count]:
        lengths[symbol] = bits.read(3)
    tree = huffman_type(read_code_lengths(bits, huffman_type(lengths), 269))
    bits.finish()
    scale = 5000 // quality if quality < 50 else 200 - quality * 2
    quantization = [max(1, min(255, (value * scale + 50) // 100)) for value in LUMINANCE]
    pixels = bytearray(width * height * 3)
    for x, y, tw, th, data in image_tiles(record[table_end:], width, height):
        columns = (tw + 7) // 8
        for number, coefficients in enumerate(coefficient_blocks(tree, data, tw, th)):
            raster = inverse_block(coefficients, quantization)
            xx, yy = x + number % columns * 8, y + number // columns * 8
            for dy in range(min(8, height - yy)):
                for dx in range(min(8, width - xx)):
                    shade = raster[dy * 8 + dx]
                    at = ((yy + dy) * width + xx + dx) * 3
                    pixels[at:at + 3] = bytes((shade, shade, shade))
    return width, height, bytes(pixels), False

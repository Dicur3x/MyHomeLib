"""Bounded ICEContainer interoperability primitives (MIT).

The public format tables are generated independently. Original ICE program
files are never run or patched. The optional original data file supplies a
matching book read profile in memory; no registration identity is exported.
"""
import array
import functools
import hashlib
import json
from pathlib import Path
import struct
import sys


class IBKError(ValueError):
    pass


class RuntimeRequired(IBKError):
    pass


@functools.lru_cache(maxsize=1)
def format_data():
    root = Path(__file__).resolve().parent
    try:
        parameters = json.loads((root / 'ibk_parameters.json').read_text(encoding='utf-8'))
        raw = (root / 'ibk_tables.bin').read_bytes()
        if len(raw) != 8 + 4 * 131072 or raw[:8] != b'MHLIBK1\0':
            raise ValueError('table layout')
        if hashlib.sha256(raw).hexdigest() != parameters['tables_sha256']:
            raise ValueError('table checksum')
        tables = []
        for index in range(4):
            values = array.array('H')
            values.frombytes(raw[8 + index * 131072:8 + (index + 1) * 131072])
            if sys.byteorder != 'little':
                values.byteswap()
            tables.append(values)
        core_inverse = array.array('H', [0]) * 65536
        for index, value in enumerate(tables[0]):
            core_inverse[value] = index
        tables.append(core_inverse)
        return parameters, tuple(tables)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise IBKError('Данные модуля IBK отсутствуют или повреждены. Восстановите модуль конвертации книг.') from error


def transform(data, table, reverse=False):
    output = bytearray(data)
    size = len(output)
    strides = []
    stride = 1
    while stride < size:
        strides.append(stride)
        stride *= 2
    if reverse:
        strides.reverse()
    for stride in strides:
        starts = range(0, size, stride * 2)
        if reverse:
            starts = reversed(starts)
        for start in starts:
            indices = range(start, min(start + stride, size))
            if reverse:
                indices = reversed(indices)
            for index in indices:
                partner = (index + stride) % size
                pair = table[output[index] | output[partner] << 8]
                output[index], output[partner] = pair & 255, pair >> 8
    return output


def checksum(data, table, width=8):
    result = bytearray(width)
    for offset in range(0, len(data), width):
        block = transform(data[offset:offset + width].ljust(width, b'\0'), table)
        for index, value in enumerate(block):
            result[index] = (result[index] + value) & 255
    return bytes(result)


def permutation(seed):
    if not seed or len(seed) > 4096:
        raise IBKError('Некорректные параметры текста IBK.')
    words = (seed * (262144 // len(seed) + 1))[:262144]
    forward = array.array('H', ((index + 1) & 65535 for index in range(65536)))
    inverse = array.array('H', ((index - 1) & 65535 for index in range(65536)))
    for index, (word,) in enumerate(struct.iter_unpack('<I', words[:-4])):
        other = index + ((word * (65536 - index)) >> 32)
        next_a, prev_a = forward[index], inverse[index]
        next_b, prev_b = forward[other], inverse[other]
        if other == next_a:
            inverse[index], forward[index] = other, next_b
            inverse[next_b] = index
            inverse[other], forward[other] = prev_a, index
            forward[prev_a] = other
        elif other == prev_a:
            inverse[index], forward[index] = prev_b, other
            forward[prev_b] = index
            inverse[other], forward[other] = index, next_a
            inverse[next_a] = other
        else:
            forward[index], inverse[index] = next_b, prev_b
            inverse[next_b], forward[prev_b] = index, index
            forward[other], inverse[other] = next_a, prev_a
            inverse[next_a], forward[prev_a] = other, other
    return inverse


def read_block(raw, inverse=None):
    if len(raw) < 8:
        raise IBKError('Обрезан блок IBK.')
    tables = format_data()[1]
    payload = raw[:-8]
    if checksum(payload, tables[2]) != raw[-8:]:
        raise IBKError('Не совпала контрольная сумма блока IBK. Исходный файл сохранён.')
    if inverse is None:
        return payload
    if len(payload) < 8:
        raise IBKError('Обрезан защищённый блок IBK.')
    if len(payload) < 512:
        return bytes(transform(payload, inverse, True))[:-8]
    boundary = ((len(payload) - 256) // 256) * 256
    tail = transform(payload[boundary:], inverse, True)
    mask = tail[-8:]
    output = bytearray()
    for offset in range(0, boundary, 256):
        block = transform(payload[offset:offset + 256], inverse, True)
        for index in range(8):
            block[index] ^= mask[index]
        output.extend(block)
    output.extend(tail)
    return bytes(output[:-8])


def record_tree(raw):
    nodes = 0

    def take(position, size):
        if size < 0 or position < 0 or position + size > len(raw):
            raise IBKError('Обрезаны сведения IBK.')
        return raw[position:position + size], position + size

    def parse(position, depth):
        nonlocal nodes
        nodes += 1
        if depth > 16 or nodes > 65536:
            raise IBKError('Слишком сложная структура сведений IBK.')
        value, position = take(position, 1)
        descriptor = value[0]
        if descriptor == 255:
            raise IBKError('Некорректная запись сведений IBK.')
        value, position = take(position, (descriptor >> 6) + 1)
        identity = int.from_bytes(value, 'little')
        size = descriptor & 63
        if size >= 59:
            value, position = take(position, size - 58)
            size = int.from_bytes(value, 'little')
        data, position = take(position, size)
        children = {}
        while True:
            value, _ = take(position, 1)
            if value[0] == 255:
                return (data, children), identity, position + 1
            child, child_id, position = parse(position, depth + 1)
            if child_id in children:
                raise IBKError('Повторяется запись сведений IBK.')
            children[child_id] = child

    if len(raw) > 8 * 1024 * 1024:
        raise IBKError('Сведения IBK превышают предел чтения.')
    result, identity, end = parse(0, 0)
    if identity != 0 or end != len(raw):
        raise IBKError('Некорректная структура сведений IBK.')
    return result


def _signed_payload(encoded, parameters, inverse):
    if len(encoded) < 12:
        raise IBKError('Обрезаны данные модуля IBK.')
    size, first_size, first_out = struct.unpack_from('<IHH', encoded)
    if not 8 <= size <= 4096 or first_size != 128 or 8 + first_size + 4 > len(encoded):
        raise IBKError('Некорректные данные модуля IBK.')
    second_size, second_out = struct.unpack_from('<HH', encoded, 8 + first_size)
    if second_size != 128 or not 0 < first_out <= 127 or not 0 < second_out <= 127:
        raise IBKError('Некорректная подпись данных IBK.')
    middle_offset = 12 + first_size + second_size
    middle = encoded[middle_offset:]
    if len(encoded) < middle_offset or len(middle) != size - first_out - second_out:
        raise IBKError('Не совпал размер данных модуля IBK.')
    modulus = int.from_bytes(bytes.fromhex(parameters['public_signature_modulus_le']), 'little')
    exponent = parameters['public_signature_exponent']
    mask = (1 << (((modulus.bit_length() - 2) // 8) * 8)) - 1
    first = pow(int.from_bytes(encoded[8:8 + first_size], 'little'), exponent, modulus) & mask
    second = pow(int.from_bytes(encoded[12 + first_size:middle_offset], 'little'), exponent, modulus) & mask
    try:
        payload = first.to_bytes(first_out, 'little') + middle + second.to_bytes(second_out, 'little')
    except OverflowError as error:
        raise IBKError('Не удалось проверить подпись данных IBK.') from error
    return bytes(transform(payload, inverse, True))[8:]


def runtime_profile(tools_root):
    parameters, tables = format_data()
    folder = Path(tools_root) / 'ibk'
    path = folder / 'Rus.key'
    try:
        if path.stat().st_size != parameters['runtime_key_bytes']:
            raise RuntimeRequired('Данные чтения IBK имеют другую версию.')
        data = path.read_bytes()
    except OSError as error:
        raise RuntimeRequired('Для этой книги нужны дополнительные данные чтения IBK.') from error
    if hashlib.sha256(data).hexdigest() != parameters['runtime_key_sha256']:
        raise RuntimeRequired('Данные чтения IBK не прошли проверку. Восстановите компонент IBK.')
    # Match the original published package exactly. Personal registration files
    # and activation state are neither searched for nor used.
    outer = bytes(transform(data, tables[3], True))
    if checksum(outer[:-16], tables[0], 16) != outer[-16:]:
        raise IBKError('Не удалось проверить исходные данные чтения IBK.')
    payload = _signed_payload(outer[:-16], parameters, tables[4])
    return _profile_payload(payload, parameters, tables)


def _profile_payload(payload, parameters, tables):
    if len(payload) < 16 or checksum(payload[:-16], tables[0], 16) != payload[-16:]:
        raise IBKError('Не совпала подпись исходных данных IBK.')
    _, root = record_tree(payload[:-16])
    try:
        _, records = root[5]
        _, fields = records[parameters['book_profile_id']]
        if fields[2][0].hex() != parameters['book_profile_uuid_le']:
            raise KeyError('profile identity')
        return int.from_bytes(fields[4][0], 'little')
    except (KeyError, TypeError) as error:
        raise IBKError('Исходный пакет не содержит подходящего профиля чтения IBK.') from error


def text_context(info, tools_root):
    parameters, tables = format_data()
    _, fields = record_tree(info)
    try:
        version = int.from_bytes(fields[1][0], 'little')
        identity = int.from_bytes(fields[2][0], 'little')
        mode = int.from_bytes(fields[8][0], 'little')
        wrapped = fields[5][0]
        valid_identity = fields[3][0].hex() == parameters['book_profile_uuid_le']
    except KeyError as error:
        raise IBKError('Недостаточно сведений для чтения текста IBK.') from error
    if version != 2 or identity != parameters['book_profile_id'] or not valid_identity or mode not in (0, 1):
        raise IBKError('Эта книга использует другой или защищённый профиль IBK. Откройте её в исходной программе.')
    if len(wrapped) < 8 or len(wrapped) > 8192 or int.from_bytes(wrapped[:4], 'little') + 4 != len(wrapped):
        raise IBKError('Повреждены параметры текста IBK.')
    exponent = runtime_profile(tools_root)
    modulus = int.from_bytes(bytes.fromhex(parameters['book_profile_modulus_le']), 'little')
    mask = (1 << ((((modulus.bit_length() - 2) // 8) - 8) * 8)) - 1
    output = bytearray()
    position = 4
    while position < len(wrapped):
        if position + 4 > len(wrapped):
            raise IBKError('Обрезаны параметры текста IBK.')
        stored, size = struct.unpack_from('<HH', wrapped, position)
        position += 4
        if not 0 < stored <= 128 or not 0 < size <= 119 or position + stored > len(wrapped):
            raise IBKError('Некорректный блок параметров текста IBK.')
        value = pow(int.from_bytes(wrapped[position:position + stored], 'little'), exponent, modulus) & mask
        position += stored
        try:
            output.extend(value.to_bytes(size, 'little'))
        except OverflowError as error:
            raise IBKError('Не удалось прочитать параметры этой книги IBK.') from error
    if len(output) < 5 or int.from_bytes(output[:4], 'little') + 4 != len(output):
        raise IBKError('Не совпал размер параметров текста IBK.')
    seed = bytes(output[4:])
    if mode == 1:
        seed = bytes(transform(seed, tables[0]))
    return permutation(seed)

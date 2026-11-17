"""Prepare one static GIF frame in an export's private work directory."""

import base64
from hashlib import sha256
import json
from pathlib import Path
import os
import struct
import tempfile

from advanced_output import run_writer


PNG = b'\x89PNG\r\n\x1a\n'
WARNING = 'GIF сохранены статичными изображениями PNG: используется первый кадр. Исходные файлы не изменены.'


def first_frame(api, data, tools, work, check=None):
    if not 14 <= len(data) <= 16 * 1024 * 1024 or not data.startswith((b'GIF87a', b'GIF89a')):
        raise api.ConversionError('Некорректное или слишком большое изображение GIF.')
    width, height = struct.unpack_from('<HH', data, 6)
    if not (0 < width <= 16384 and 0 < height <= 16384) or width * height > 16777216:
        raise api.ConversionError('Изображение GIF превышает допустимые размеры.')
    if check is not None:
        check()
    tool = api.image_processor_path(tools)
    if not tool.is_file():
        raise api.ComponentRequired('ImageProcessing', 'Для статичного кадра GIF нужен модуль HomeLibre Images.')
    runtime = tool.with_name('RUNTIME.json')
    try:
        if runtime.stat().st_size > 65536 or json.loads(runtime.read_text(encoding='utf-8-sig')).get('gif_static_api') != 1:
            raise ValueError('No static GIF capability')
    except (OSError, ValueError, AttributeError):
        raise api.ComponentRequired('ImageProcessing', 'Обновите модуль HomeLibre Images для подготовки статичного кадра GIF.') from None
    with tempfile.TemporaryDirectory(prefix='homelibre-gif-static-', dir=work) as folder:
        source = Path(folder) / 'source.gif'
        output = Path(folder) / 'first.png'
        source.write_bytes(data)
        run_writer(api, [str(tool), '--gif-first-frame', str(source), str(output)], Path(folder), check, timeout=30)
        if not output.is_file() or not 33 <= output.stat().st_size <= 16 * 1024 * 1024:
            raise api.ConversionError('Модуль не подготовил статичный кадр GIF допустимого размера. Обновите HomeLibre Images.')
        result = output.read_bytes()
        if (not result.startswith(PNG) or result[12:16] != b'IHDR'
                or struct.unpack_from('>II', result, 16) != (width, height)):
            raise api.ConversionError('Подготовка GIF изменила размер изображения или не вернула PNG.')
        if check is not None:
            check()
        return result


def normalize_export(api, private_book, extension, tools, warnings, check=None):
    """Normalize GIFs in an already generated private FB2/EPUB, never a source."""
    cache = {}
    def decode(data):
        key = sha256(data).digest()
        if key not in cache:
            cache[key] = first_frame(api, data, tools, private_book.parent, check)
        return cache[key]

    with tempfile.TemporaryDirectory(prefix='homelibre-gif-export-', dir=private_book.parent) as folder:
        output = Path(folder) / ('static' + extension)
        count = 0
        if extension == '.epub':
            from kfx_image_input import prepare
            count = prepare(api, private_book, output, None, check, decode_gif=decode, only_gif=True)
        elif extension == '.fb2':
            root = api.xml(private_book.read_bytes(), api.MAX_TOTAL)
            for node in root:
                if check is not None:
                    check()
                if node.tag != '{' + api.FB + '}binary':
                    continue
                payload = ''.join((node.text or '').split())
                try:
                    header = base64.b64decode(payload[:12], validate=True)
                except ValueError:
                    continue
                if not header.startswith((b'GIF87a', b'GIF89a')):
                    continue
                if len(payload) > 4 * ((16 * 1024 * 1024 + 2) // 3):
                    raise api.ConversionError('Изображение GIF превышает 16 МБ.')
                try:
                    data = base64.b64decode(payload, validate=True)
                except ValueError as error:
                    raise api.ConversionError('Некорректные данные GIF в FB2.') from error
                node.text = base64.b64encode(decode(data)).decode('ascii')
                node.set('content-type', 'image/png')
                count += 1
            if count:
                data = api.serialized(root)
                if len(data) > api.MAX_TOTAL:
                    raise api.ConversionError('Книга со статичными GIF превышает предел размера.')
                output.write_bytes(data)
        else:
            raise api.ConversionError('Статичные GIF подготавливаются в FB2 или EPUB.')
        if count:
            if check is not None:
                check()
            os.replace(output, private_book)
            warnings.add(WARNING)
        return count

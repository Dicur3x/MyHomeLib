"""Prepare one static GIF frame in an export's private work directory."""

import base64
from contextlib import ExitStack
from hashlib import sha256
import json
from pathlib import Path
from queue import Empty
import os
import struct
import tempfile

from advanced_output import ImageFileWorker, run_writer


PNG = b'\x89PNG\r\n\x1a\n'
WARNING = 'GIF сохранены статичными изображениями PNG: используется первый кадр. Исходные файлы не изменены.'


def gif_canvas(api, data):
    if not 14 <= len(data) <= 16 * 1024 * 1024 or not data.startswith((b'GIF87a', b'GIF89a')):
        raise api.ConversionError('Некорректное или слишком большое изображение GIF.')
    width, height = struct.unpack_from('<HH', data, 6)
    if not (0 < width <= 16384 and 0 < height <= 16384) or width * height > 16777216:
        raise api.ConversionError('Изображение GIF превышает допустимые размеры.')
    return width, height


def gif_runtime(api, tools):
    tool = api.image_processor_path(Path(tools or Path(__file__).resolve().parent.parent)).absolute()
    if not tool.is_file():
        raise api.ComponentRequired('ImageProcessing', 'Для статичного кадра GIF нужен модуль HomeLibre Images.')
    runtime = tool.with_name('RUNTIME.json')
    try:
        if runtime.stat().st_size > 65536:
            raise ValueError('Oversized runtime descriptor')
        manifest = json.loads(runtime.read_text(encoding='utf-8-sig'))
        if manifest.get('gif_static_api') != 1:
            raise ValueError('No static GIF capability')
    except (OSError, ValueError, AttributeError):
        raise api.ComponentRequired('ImageProcessing', 'Обновите модуль HomeLibre Images для подготовки статичного кадра GIF.') from None
    return tool, manifest.get('gif_stream_api') == 1


def read_frame(api, output, canvas):
    if not output.is_file() or not 33 <= output.stat().st_size <= 16 * 1024 * 1024:
        raise api.ConversionError('Модуль не подготовил статичный кадр GIF допустимого размера. Обновите HomeLibre Images.')
    result = output.read_bytes()
    if (not result.startswith(PNG) or result[12:16] != b'IHDR'
            or struct.unpack_from('>II', result, 16) != canvas):
        raise api.ConversionError('Подготовка GIF изменила размер изображения или не вернула PNG.')
    return result


def single_frame(api, tool, data, canvas, work, check):
    with tempfile.TemporaryDirectory(prefix='homelibre-gif-static-', dir=work) as folder:
        workspace = Path(folder).absolute()
        source = workspace / 'source.gif'
        output = workspace / 'first.png'
        source.write_bytes(data)
        # Windows cannot always use a long directory as the current directory.
        run_writer(api, [str(tool), '--gif-first-frame', str(source), str(output)], workspace, check,
                   timeout=30, use_working_directory=False)
        return read_frame(api, output, canvas)


class GifFrameDecoder(ExitStack):
    """Reuse one image process for the GIF resources of a single book."""

    def __init__(self, api, tools, work, check=None):
        super().__init__()
        self.api, self.tools, self.work, self.check = api, tools, work, check
        self.tool = None
        self.worker = None

    def start_worker(self):
        folder = self.enter_context(tempfile.TemporaryDirectory(prefix='homelibre-gif-stream-', dir=self.work))
        try:
            worker = ImageFileWorker(self.tool, Path(folder).absolute(), '--gif-first-frame-stream')
        except OSError:
            return
        self.callback(worker.close)
        try:
            if worker.response(5, self.check) == b'READY 1':
                self.worker = worker
                return
        except Empty:
            pass
        worker.close()

    def decode(self, data):
        canvas = gif_canvas(self.api, data)
        if self.check is not None:
            self.check()
        if self.tool is None:
            self.tool, can_stream = gif_runtime(self.api, self.tools)
            if can_stream:
                self.start_worker()
        result = None
        if self.worker is not None:
            try:
                reply = self.worker.request(data, 30, self.check)
            except BrokenPipeError:
                reply = None
            except Empty:
                raise self.api.ConversionError('Модуль GIF не завершил подготовку кадра за 30 с.') from None
            if reply == b'OK':
                result = read_frame(self.api, self.worker.target, canvas)
            elif reply != b'ERROR':
                self.worker.close()
                self.worker = None
            # A failed frame uses the single-image command for its detailed error.
        if result is None:
            result = single_frame(self.api, self.tool, data, canvas, self.work, self.check)
        if self.check is not None:
            self.check()
        return result


def first_frame(api, data, tools, work, check=None):
    with GifFrameDecoder(api, tools, work, check) as decoder:
        return decoder.decode(data)


def normalize_export(api, private_book, extension, tools, warnings, check=None, maximum_total=None, progress=None):
    """Normalize GIFs in an already generated private FB2/EPUB, never a source."""
    cache = {}
    with GifFrameDecoder(api, tools, private_book.parent, check) as decoder, \
            tempfile.TemporaryDirectory(prefix='homelibre-gif-export-', dir=private_book.parent) as folder:
        def decode(data):
            key = sha256(data).digest()
            if key not in cache:
                cache[key] = decoder.decode(data)
                if progress is not None:
                    progress('gif-preparation', len(cache), 0)
            return cache[key]

        output = Path(folder) / ('static' + extension)
        count = 0
        if extension == '.epub':
            from kfx_image_input import prepare
            count = prepare(api, private_book, output, None, check, decode_gif=decode, only_gif=True,
                            maximum_total=maximum_total)
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

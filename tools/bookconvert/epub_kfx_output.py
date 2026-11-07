"""Direct KFX/AZW8 export from a prepared EPUB using optional native tools."""

from math import ceil
import re

from image_input import decode_webp
from kfx_image_input import prepare
from text_inputs import Book


PIXELS = re.compile(r'(\d{1,7}(?:\.\d{1,6})?)(?:px)?')


def convert(api, source, output, writer, tools, warnings, check, run_writer):
    work = output.parent
    renderer = writer.with_name('resvg.exe')
    book = Book(api, source, warnings, tools_root=tools)

    def render(svg):
        if not renderer.is_file():
            raise api.ComponentRequired('KfxExport', 'Переустановите модуль KFX и AZW8 для обработки SVG.')
        drawing = work / 'drawing.svg'
        bitmap = work / 'drawing.png'
        root = api.xml(svg)
        width = PIXELS.fullmatch(root.get('width', '').strip())
        height = PIXELS.fullmatch(root.get('height', '').strip())
        # Both limits are passed together. resvg fits into the box while
        # preserving the aspect ratio. Use 2x author sizes where practical.
        bounds = (2048, 2048)
        if width and height and max(float(width[1]), float(height[1])) <= 1024:
            bounds = tuple(max(1, ceil(2 * float(match[1]))) for match in (width, height))
        drawing.write_bytes(svg)
        bitmap.unlink(missing_ok=True)
        run_writer(api, [str(renderer), '--skip-system-fonts', '--width', str(bounds[0]),
                         '--height', str(bounds[1]), str(drawing), str(bitmap)], work, check, timeout=30)
        if not bitmap.is_file() or bitmap.stat().st_size > api.MAX_FILE:
            raise api.ConversionError('KFX: модуль SVG не создал изображение допустимого размера.')
        return bitmap.read_bytes()

    compatible = work / 'kindle-source.epub'
    if prepare(api, source, compatible, render, check, lambda data: decode_webp(book, data)):
        source = compatible
        warnings.add('Для совместимости с Kindle часть рисунков сохранена в PNG. Иллюстрации SVG в копии становятся растровыми.')
    warnings.add('При сохранении в формате Kindle оформление и разбиение текста на страницы могут измениться.')
    run_writer(api, [str(writer), 'convert', '-t', 'kfx', str(source), str(output)], work, check)

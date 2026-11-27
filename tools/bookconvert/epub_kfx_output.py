"""Direct KFX/AZW8 export from a prepared EPUB using optional native tools."""

from contextlib import closing
from math import ceil
from hashlib import sha256
import re

from image_input import decode_webp
from gif_static import GifFrameDecoder, WARNING as STATIC_GIF_WARNING
from kfx_image_input import prepare
from text_inputs import Book


PIXELS = re.compile(r'(\d{1,7}(?:\.\d{1,6})?)(?:px)?')


def omitted_publication_fields(api, source):
    with closing(api.EpubArchive(source)) as archive:
        container = api.xml(archive.read('META-INF/container.xml'))
        package_path = next(node.get('full-path') for node in container.iter() if api.tag(node) == 'rootfile')
        package = api.xml(archive.read(package_path))
    metadata = api.first(package, 'metadata')
    if metadata is None:
        return []
    fields = ['ISBN'] if any(api.epub_isbn_identifiers(metadata)) else []
    fields.extend(label for name, label in (('subject', 'жанры и темы'), ('rights', 'сведения о правах'))
                  if any(api.plain(node) for node in api.children(metadata, name)))
    return fields


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
    gif_images = {}
    with GifFrameDecoder(api, tools, work, check) as decoder:
        def gif(data):
            key = sha256(data).digest()
            if key not in gif_images:
                gif_images[key] = decoder.decode(data)
            warnings.add(STATIC_GIF_WARNING)
            return gif_images[key]

        if prepare(api, source, compatible, render, check, lambda data: decode_webp(book, data), gif,
                   warnings=warnings):
            warnings.add('Для совместимости с Kindle часть изображений в копии сохранена в PNG.')
        if compatible.exists():
            source = compatible
    warnings.add('При сохранении в формате Kindle оформление и разбиение текста на страницы могут измениться.')
    run_writer(api, [str(writer), 'convert', '-t', 'kfx', str(source), str(output)], work, check)
    if fields := omitted_publication_fields(api, source):
        format_name = output.suffix[1:].upper()
        warnings.add(f'{api.KFX_METADATA_LOSS} {format_name} — {", ".join(fields)}. '
                     'Чтобы сохранить эти сведения, выберите EPUB или AZW3.')

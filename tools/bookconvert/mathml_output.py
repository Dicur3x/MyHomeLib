"""Prepare private MathML images for FB2 using the optional EPUB layout module."""

from html import escape
import importlib.util
from pathlib import Path
import re


MATH = 'http://www.w3.org/1998/Math/MathML'
XHTML = 'http://www.w3.org/1999/xhtml'
ELEMENTS = {'math', 'mrow', 'mi', 'mn', 'mo', 'mtext', 'ms', 'mspace', 'mfrac', 'msqrt', 'mroot',
            'msub', 'msup', 'msubsup', 'munder', 'mover', 'munderover', 'mmultiscripts', 'mprescripts',
            'none', 'mtable', 'mtr', 'mtd', 'mstyle', 'mphantom', 'mpadded', 'semantics', 'annotation'}
ATTRIBUTES = {'display', 'displaystyle', 'dir', 'mathvariant', 'mathcolor', 'mathbackground', 'mathsize',
              'scriptlevel', 'width', 'height', 'depth', 'voffset', 'lspace', 'rspace', 'minsize', 'maxsize',
              'form', 'fence', 'separator', 'stretchy', 'symmetric', 'accent', 'accentunder', 'linethickness',
              'rowspan', 'columnspan', 'rowalign', 'columnalign', 'rowspacing', 'columnspacing'}
MAX_FORMULAS = 256
MAX_MARKUP = 480 * 1024
MAX_IMAGE = 16 * 1024 * 1024
HOST = ('<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" '
        'content="default-src \'none\'; style-src \'unsafe-inline\'">'
        '<style>body{margin:8px;background:white;color:black} .formula{display:table;padding:2px;margin:4px 0} '
        'math{font:22px "Cambria Math",math,serif}</style>')


def markup(node):
    def element(item, root=False):
        namespace, _, name = item.tag.rpartition('}')
        if not namespace:
            name = item.tag
        if (name not in ELEMENTS or (name == 'math') != root or
                namespace not in ('', '{' + XHTML, '{' + MATH)):
            raise ValueError('Неподдерживаемый элемент формулы.')
        attributes = [('xmlns', MATH)] if root else []
        attributes.extend((key, value) for key, value in item.attrib.items()
                          if key in ATTRIBUTES and len(value) <= 120)
        properties = ''.join(f' {key}="{escape(value, quote=True)}"' for key, value in attributes)
        contents = escape(item.text or '') + ''.join(element(child) + escape(child.tail or '') for child in item)
        return f'<{name}{properties}>{contents}</{name}>'

    try:
        return element(node, root=True)
    except ValueError:
        return None


def label(node):
    names = {'msub': '_', 'msup': '^', 'mfrac': '/'}

    def text(item):
        name = item.tag.rsplit('}', 1)[-1]
        if name == 'annotation':
            return ''
        parts = [value for child in item if (value := text(child))]
        if name == 'mtable':
            return '[' + '; '.join(parts) + ']'
        if name == 'mtr':
            return '[' + ', '.join(parts) + ']'
        if name in names and len(parts) == 2:
            return '(' + parts[0] + ')' + names[name] + '(' + parts[1] + ')'
        return ' '.join(value for value in ((item.text or '').strip(), *parts) if value)

    return re.sub(r'\s+', ' ', node.get('alttext', '').strip() or text(node))[:512] or 'Формула'


def render(api, nodes, tools, work, check=None):
    directory = tools / 'epub-pdf'
    renderer = directory / 'runtime' / 'HomeLibEpubPdf.exe'
    runner = directory / 'epub_pdf_output.py'
    missing = 'Для отрисовки формул установите или обновите модуль «Вёрстка EPUB в PDF».'
    if not renderer.is_file() or not runner.is_file():
        return {}, missing
    spec = importlib.util.spec_from_file_location('homelibre_epub_math_renderer', runner)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, 'render_math', None)):
        return {}, missing

    unique = {}
    occurrences = {}
    size = 0
    for node in nodes:
        if check is not None:
            check()
        body = markup(node)
        if not body:
            continue
        if body not in unique:
            length = len(body.encode('utf-8')) + 32
            if size + length > MAX_MARKUP or len(unique) >= MAX_FORMULAS:
                continue
            unique[body] = len(unique)
            size += length
        occurrences[node] = unique[body]
    if not unique:
        return {}, ''

    work.mkdir()
    (work / 'formulas.html').write_text(HOST + ''.join(f'<div class="formula">{body}</div>' for body in unique),encoding='utf-8')
    from time import monotonic
    deadline = monotonic() + 90

    def checkpoint():
        if check is not None:
            check()
        if monotonic() > deadline:
            raise TimeoutError('Модуль не завершил отрисовку формул за 90 секунд.')

    try:
        module.render_math(renderer, work, len(unique), 2 * MAX_IMAGE, checkpoint)
    except api.ConversionError:
        raise
    except (ValueError, OSError) as error:
        return {}, str(error)[:280]

    images = {}
    for index in range(len(unique)):
        image = work / f'formula-{index:04d}.png'
        if not image.is_file() or not 0 < image.stat().st_size <= MAX_IMAGE:
            continue
        data = image.read_bytes()
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):
            continue
        width, height = api.raster_header_size(data)
        if width and height and width % 2 == height % 2 == 0:
            try:
                api.check_embedded_raster(data)
            except api.UnreadableImage:
                continue
            images[index] = (image, width // 2, height // 2)
    return {node: images[index] for node, index in occurrences.items() if index in images}, ''

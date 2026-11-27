"""Local FB2/EPUB conversion. MIT license; see LICENSE.txt.

Standard library only; source files are read-only.

EPUB can describe layouts that FB2 cannot. Such features are reported explicitly.
This module never downloads resources, rewrites the source or replaces a target.
"""
from __future__ import annotations

import argparse
import base64
import copy
from collections import Counter
from contextlib import ExitStack
from functools import lru_cache
import hashlib
import importlib.util
from html import unescape as unescape_html
from html.entities import name2codepoint
from itertools import groupby
import json
import math
import mimetypes
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from typing import NamedTuple
from urllib.parse import quote, unquote, unquote_to_bytes, urlsplit
import uuid
import xml.etree.ElementTree as ET
from xml.parsers import expat
import zipfile

FB = 'http://www.gribuser.ru/xml/fictionbook/2.0'
XL = 'http://www.w3.org/1999/xlink'
XH = 'http://www.w3.org/1999/xhtml'
SVG = 'http://www.w3.org/2000/svg'
EP = 'http://www.idpf.org/2007/ops'
OP = 'http://www.idpf.org/2007/opf'
DC = 'http://purl.org/dc/elements/1.1/'
CN = 'urn:oasis:names:tc:opendocument:xmlns:container'
MHL = 'https://github.com/Dicur3x/MyHomeLib/conversion/'
MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
# Scan images are staged on disk and streamed into the EPUB. Match the
# reader's lazy image budget while allowing room for the book markup.
MAX_SCAN_EPUB_RESOURCES = 3 * 1024**3
MAX_LARGE_FB2_OUTPUT = 512 * 1024 * 1024
LARGE_JPEG_EPUB_RESOURCE = 'images/original.jpg'
MAX_PDF_SOURCE = 512 * 1024 * 1024
MAX_ENTRIES = 20000
FB2_TABLE_HEADING = 'homelibre-table-heading-'
FB2_TABLE_LINE_STYLE = 'white-space:pre-wrap'
FB2_IMAGE_SIZE_PREFIX = 'homelibre-image-size-'
FB2_IMAGE_WIDTH_PREFIX = 'homelibre-image-width-'
FB2_EPUB_OUTLINE = 'HomeLibre: EPUB outline v1'
FB2_EPUB_COVER_IN_BODY = 'HomeLibre: EPUB cover in body v1'
EPUB_START_ONLY = 'data-homelib-start-only'
MAX_OUTLINE_METADATA = 2 * 1024 * 1024
MARGIN_RULE_PREFIX = 'homelibre-margin-rule:'
WORD_RULE_CLASS = 'homelibre-word-rule-'
WORD_LINE_CLASS = 'homelibre-word-line-'
WORD_SPACER_CLASS = 'homelibre-word-space-'
WORD_SPACER_PARAGRAPH = 'homelibre-word-space-paragraph-'
WORD_LIST_PARAGRAPH = 'homelibre-word-list-'
WORD_CANVAS_STYLE = 'homelibre-word-canvas'
WORD_LEGEND_STYLE = 'homelibre-word-legend'
EPUB_XHTML_TYPES = {'application/xhtml+xml', 'application/x-ibooks-html'}
EPUB_MISLABELED_XHTML_TYPES = {'image/xhtml', 'image/xhtml+xml'}
EPUB_NAMESPACE_REPAIR = 'Исправлены объявления пространств имён в EPUB.'
EPUB_TRAILING_MARKUP_REPAIR = 'Фрагмент после закрывающего тега XHTML возвращён в конец главы EPUB.'
EPUB_CLOSING_TAG_REPAIR = 'Исправлены закрывающие теги XHTML в главах EPUB; оформление отдельных фрагментов может отличаться.'
EPUB_TRUNCATED_CHAPTER = 'В главе EPUB не сохранились закрывающие теги'
EPUB_DANGLING_START = 'В главе EPUB оборван открывающий тег'
EPUB_MISSING_BODY = 'В разделе EPUB отсутствует содержимое'
MOBI_NAVIGATION_LOSS = 'Не перенесены переходы оглавления MOBI'
MOBI_METADATA_LOSS = 'Не удалось прочитать сведения об издании MOBI.'
DOC_NOTE_LAYOUT_LOSS = 'Не удалось восстановить все связи сносок DOC'
DOCX_PAGE_OVERLAYS = 'Белые накладки печатных страниц не перенесены'
KFX_METADATA_LOSS = 'Не перенесены сведения о книге при сохранении в'
KINDLE_JPEG_TRAILER_LOSS = 'В Kindle не перенесены дополнительные данные изображения JPEG'
MOBI_IMAGE_REDUCTION = 'Изображение перекодировано для MOBI'
XML_QUOTED_BYTES = br""""[^"]*"|'[^']*'"""
XML_NAMESPACE_TAG = re.compile(
    br'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<!DOCTYPE(?:' + XML_QUOTED_BYTES +
    br'''|[^>"'])*>|(<[^\s<>"'!?/]+(?:''' + XML_QUOTED_BYTES + br'''|[^<>"'])*>)''',
    re.S)
EPUB_EMPTY_PREFIX = re.compile(
    XML_QUOTED_BYTES + br'''|(?<=[ \t\r\n])(xmlns):(?=[ \t\r\n]*=[ \t\r\n]*(["'])(?:''' +
    b'|'.join(re.escape(uri.encode('ascii')) for uri in (
        XH, OP, SVG, CN, 'http://www.daisy.org/z3986/2005/ncx/', 'http://www.w3.org/1998/Math/MathML')) +
    br''')\2)''')
CSS_QUOTED = r""""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"""
CSS_URL_TOKEN = re.compile(
    rf'''/\*.*?\*/|@font-face\s*\{{[^{{}}]*\}}|@import\b(?:{CSS_QUOTED}|[^;"'])*;|'''
    rf'''{CSS_QUOTED}|(?<![\w-])url\s*\(\s*(?P<url>{CSS_QUOTED}|'''
    r'''(?:\\(?:[0-9a-f]{1,6}(?:\r\n|[ \t\r\n\f])?|.)|[^\\\s"'()])*)\s*\)''',
    re.I | re.S)

BOOK_TEXT_INPUTS = {'.txt', '.text', '.faq', '.html', '.htm', '.xhtml', '.shtml', '.rtf', '.docx', '.odt', '.fb3', '.md', '.markdown', '.abw', '.sxw',
                    '.doc', '.dot', '.docm', '.dotx', '.dotm', '.ppt', '.pps', '.pot', '.pptx', '.pptm', '.ppsx', '.ppsm', '.potx', '.potm', '.xls', '.xlt', '.xlsx', '.xlsm', '.xltx', '.xltm', '.ods', '.ots', '.odp', '.otp', '.ott', '.wps', '.wpd', '.mht', '.mhtml', '.wri', '.pdb', '.ibk', '.rgo', '.jutoh', '.pages', '.tcr', '.chm', '.lit', '.lrf', '.rb', '.xps', '.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.cbz','.cbr','.cb7', '.pdf', '.djvu', '.djv', '.dju', '.djm', '.djvm'}
BOOK_KINDLE_INPUTS = {'.mobi', '.azw', '.azw3', '.prc'}
BOOK_SCAN_INPUTS = {'.pdf', '.djvu', '.djv', '.dju', '.djm', '.djvm'}
BOOK_EPUB_INPUTS = BOOK_TEXT_INPUTS | BOOK_KINDLE_INPUTS | {'.fb2', '.epub', '.ha', '.cr3', '.b1'}


class ConversionError(ValueError):
    pass


class UnreadableImage(ConversionError):
    pass


@lru_cache(maxsize=1)
def _jpeg_recovery():
    spec = importlib.util.spec_from_file_location('homelib_jpeg_recovery', Path(__file__).with_name('tiff_jpeg.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_JPEG_RESERVED_MARKER = re.compile(rb'\xff[\x02-\xbf]')


def check_embedded_raster(data):
    """Check known raster containers before copying the original bytes."""
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        import struct
        import zlib
        raw = memoryview(data)
        offset = 8
        has_pixels = False
        while offset + 12 <= len(raw):
            length, kind = struct.unpack_from('>I4s', raw, offset)
            end = offset + 8 + length
            if end + 4 > len(raw):
                break
            if zlib.crc32(raw[offset + 4:end]) != struct.unpack_from('>I', raw, end)[0]:
                raise UnreadableImage('Не совпадает контрольная сумма блока PNG.')
            if kind == b'IDAT':
                has_pixels = True
            if kind == b'IEND' and not length and has_pixels:
                return
            offset = end + 4
        raise UnreadableImage('Изображение PNG не содержит всех необходимых данных.')
    if data.startswith(b'\xff\xd8\xff'):
        scan = data.find(b'\xff\xda')
        end = data.rfind(b'\xff\xd9')
        if scan < 0 or end <= scan:
            raise UnreadableImage('Изображение JPEG обрывается.')
        if _JPEG_RESERVED_MARKER.search(data, scan+2, end) and _jpeg_recovery().has_reserved_baseline_scan_marker(data):
            raise UnreadableImage('Повреждён маркер внутри изображения JPEG.')
    if data.startswith((b'GIF87a', b'GIF89a')):
        def palette_size(flags):
            return 3 * (2 << (flags & 7)) if flags & 0x80 else 0

        try:
            offset = 13 + palette_size(data[10])
            while offset < len(data):
                marker = data[offset]
                if marker == 0x21:
                    offset += 2  # Extension label and its data subblocks.
                elif marker == 0x2c:
                    offset += 11 + palette_size(data[offset + 9])
                else:
                    break
                while size := data[offset]:
                    offset += size + 1
                offset += 1
                if marker == 0x2c:
                    return
        except IndexError:
            pass
        raise UnreadableImage('Изображение GIF не содержит полного первого кадра.')


def recover_book_jpeg(data, warnings, label='', check=None):
    if not data.startswith(b'\xff\xd8\xff'):
        return data, ''
    try:
        check_embedded_raster(data)
        return data, ''
    except UnreadableImage:
        result = _jpeg_recovery().recover_jpeg(data, check)
        if result is None:
            raise
    if result.rows == result.original_rows and not result.preview_scans:
        warnings.add('Восстановлены конечные маркеры JPEG с полными данными изображения.')
        return result.data, ''
    detail = f' «{label[:100]}»' if label else ''
    notice = f'Частично восстановлено изображение JPEG{detail}. '
    if result.preview_scans:
        notice += f'Полных проходов: {result.preview_scans}. Часть мелких деталей утрачена.'
    else:
        notice += f'Сохранены верхние {result.rows} из {result.original_rows} строк.'
    warnings.add(notice)
    return result.data, notice


class ComponentRequired(ConversionError):
    def __init__(self, component, message):
        super().__init__(message)
        self.component = component


class FB2ImageRecoveryRequired(ConversionError):
    def __init__(self, book, cover, identity):
        super().__init__('Текст FB2 цел. В конце файла обрывается ' + ('обложка.' if cover else 'иллюстрация.'))
        self.book = book
        label = 'Повреждённая обложка' if cover else 'Повреждённая иллюстрация'
        self.warning = f'{label} «{identity[:100]}» пропущена.'


TEXT_FRAME_STYLE = 'homelibre-text-frame'
TEXT_FRAME_CSS = 'white-space:pre;overflow-x:auto;font-family:monospace;text-indent:0;margin:0;tab-size:8'
EPUB_LIST_MARKER_STYLE = 'homelibre-list-marker'


def rewrite_css_urls(css, transform):
    """Rewrite image URL tokens while preserving comments, strings and font/import rules."""
    def replace(match):
        value = match['url']
        if value is None:
            return match[0]
        if value.startswith(('"', "'")):
            value = value[1:-1]
        def unescape(escape):
            if escape[1]:
                code = int(escape[1], 16)
                return '\ufffd' if code == 0 or 0xd800 <= code <= 0xdfff or code > 0x10ffff else chr(code)
            return escape[2] or ''
        value = re.sub(r'\\(?:([0-9a-fA-F]{1,6})(?:\r\n|[ \t\r\n\f])?|\r\n|[\r\n\f]|(.))', unescape, value)
        return transform(value, match[0])
    return CSS_URL_TOKEN.sub(replace, css)


def rewrite_fb2_css_types(css):
    """Translate FB2 type selectors whose XHTML aliases are unambiguous."""
    aliases = {'image': 'img', 'title': 'header', 'emphasis': 'em', 'strikethrough': 's'}
    grouping = {'media', 'supports', 'layer', 'container'}
    opaque = rf'/\*.*?\*/|{CSS_QUOTED}|\\(?:[0-9a-fA-F]{{1,6}}\s?|.)'

    def rewrite_selector(selector):
        depth = 0
        at_type = True
        result = []
        for match in re.finditer(opaque + r'|[-\w]+|\s+|.', selector, re.S):
            token = match[0]
            if token.startswith('/*'):
                result.append(token)
                continue
            if token in ('[', '('):
                depth += 1
            elif token in (']', ')'):
                depth -= 1
            if depth == 0 and at_type and token in aliases and selector[match.end():match.end()+1] != '|':
                token = aliases[token]
            result.append(token)
            at_type = depth == 0 and (token in (',', '+', '>', '~') or token.isspace())
        return ''.join(result)

    replacements = []
    rule_lists = [True]
    depth = start = 0
    for match in re.finditer(opaque + r'|[{};()\[\]]', css, re.S):
        token = match[0]
        if token in ('[', '('):
            depth += 1
        elif token in (']', ')'):
            depth -= 1
        elif depth == 0 and token == '{':
            prelude = css[start:match.start()]
            rule = re.sub(r'/\*.*?\*/', '', prelude, flags=re.S).lstrip()
            at_rule = re.match(r'@([-\w]+)', rule)
            if rule_lists[-1] and rule and not rule.startswith('@'):
                updated = rewrite_selector(prelude)
                if updated != prelude:
                    replacements.append((start, match.start(), updated))
            rule_lists.append(bool(rule_lists[-1] and at_rule and at_rule[1].lower() in grouping))
            start = match.end()
        elif depth == 0 and token == '}':
            if len(rule_lists) == 1:
                return css
            rule_lists.pop()
            start = match.end()
        elif depth == 0 and token == ';':
            start = match.end()
    if depth != 0 or len(rule_lists) != 1 or not replacements:
        return css
    output = []
    start = 0
    for left, right, updated in replacements:
        output.extend((css[start:left], updated))
        start = right
    output.append(css[start:])
    return ''.join(output)


def css_list_declarations(css):
    """Yield the two marker properties, including resets from list-style."""
    urls = {}

    def reserve_url(reference, original):
        key = f'\x00{len(urls)}\x00'
        urls[key] = reference
        return key

    for part in rewrite_css_urls(css, reserve_url).split(';'):
        name, _, value = part.partition(':')
        name = name.strip().lower()
        if name not in {'list-style', 'list-style-type', 'list-style-image'}:
            continue
        value, important = re.subn(r'\s*!\s*important\s*$', '', value, flags=re.I)
        tokens = value.strip().lower().split()
        if not tokens:
            continue
        if name == 'list-style-type':
            if len(tokens) == 1:
                yield name, tokens[0], bool(important)
        elif name == 'list-style-image':
            if len(tokens) == 1 and (tokens[0] in urls or tokens[0] in {'none','inherit','initial','unset'}):
                yield name, urls.get(tokens[0], tokens[0]), bool(important)
        else:
            if len(tokens) == 1 and tokens[0] in {'inherit','initial','unset'}:
                marker_type = marker_image = tokens[0]
            else:
                marker_image = next((urls[token] for token in tokens if token in urls), 'none')
                marker_type = next((token for token in tokens if token not in urls and
                                    token not in {'inside','outside','none'}), 'none' if 'none' in tokens else 'disc')
            yield 'list-style-type', marker_type, bool(important)
            yield 'list-style-image', marker_image, bool(important)


CSS_TABLE_EDGES = ('top', 'right', 'bottom', 'left')
CSS_TABLE_PADDING = {'padding', *(f'padding-{edge}' for edge in CSS_TABLE_EDGES)}
CSS_TABLE_BORDER_STYLES = {'none', 'hidden', 'solid', 'dotted', 'dashed', 'double',
                           'groove', 'ridge', 'inset', 'outset'}
CSS_TABLE_LENGTH = re.compile(r'(?:0|(?:\d+(?:\.\d+)?|\.\d+)(?:px|pt|in|cm|mm|pc|em|rem|ex|ch|%))')
CSS_TABLE_COLOR = re.compile(r'#[0-9a-f]{3}(?:[0-9a-f]{3})?|[a-z]+')

def css_border_part(token):
    if token in CSS_TABLE_BORDER_STYLES:
        return 'style'
    if token in {'thin', 'medium', 'thick'} or (not token.endswith('%') and CSS_TABLE_LENGTH.fullmatch(token)):
        return 'width'
    return 'color' if CSS_TABLE_COLOR.fullmatch(token) else ''


def css_table_declarations(css):
    """Yield safe table layout declarations in source order."""
    start = depth = 0
    for token in re.finditer(CSS_QUOTED + r'|/\*.*?\*/|[();]', css + ';', re.S):
        if token[0] == '(':
            depth += 1
        elif token[0] == ')':
            depth = max(0, depth - 1)
        if token[0] != ';' or depth:
            continue
        declaration = css[start:token.start()]
        start = token.end()
        if '/*' in declaration:
            declaration = re.sub(r'/\*.*?\*/', ' ', declaration, flags=re.S)
        name, _, value = declaration.partition(':')
        name = name.strip().lower()
        value, important = re.subn(r'\s*!\s*important\s*$', '', value.strip().lower())
        value = value.strip()
        if name in {'background', 'background-color'} and value:
            name = 'background-color'
            if re.fullmatch(r'#[0-9a-f]{3}(?:[0-9a-f]{3})?', value):
                if len(value) == 4:
                    value = '#' + ''.join(digit * 2 for digit in value[1:])
            else:
                # Clear an older solid fill when the active rule replaces it.
                value = 'transparent'
        elif name == 'border-collapse':
            if value not in {'collapse', 'separate'}:
                continue
        elif name in CSS_TABLE_PADDING:
            tokens = value.split()
            if not 1 <= len(tokens) <= (4 if name == 'padding' else 1) or not all(
                CSS_TABLE_LENGTH.fullmatch(token) for token in tokens
            ):
                continue
        elif name == 'border' or name.startswith('border-'):
            tokens = name.split('-')[1:]
            if tokens and tokens[0] in CSS_TABLE_EDGES:
                tokens.pop(0)
            kind = tokens[0] if len(tokens) == 1 else ''
            if tokens and (len(tokens) != 1 or kind not in {'style', 'width', 'color'}):
                continue
            parts = value.split()
            if not 1 <= len(parts) <= (3 if not kind else 1 if len(name.split('-')) == 3 else 4):
                continue
            kinds = [css_border_part(token) for token in parts]
            if (kind and any(part != kind for part in kinds) or
                not kind and ('' in kinds or len(set(kinds)) != len(kinds))):
                continue
        else:
            continue
        yield name, value, bool(important)


def resolved_table_style(layers, *, table=False):
    """Serialize supported declarations in cascade order, including shorthands."""
    selected = {}
    for order, (specificity, name, value, important) in enumerate(layers):
        if (name == 'border-collapse') != table:
            continue
        rank = (important, specificity, order)
        if name not in selected or rank >= selected[name][0]:
            selected[name] = rank, value
    return [name + ':' + value for name, (_, value) in sorted(selected.items(), key=lambda item: item[1][0])]


def epub_list_label(style, index):
    bullets = {'none':'', 'disc':'• ', 'circle':'◦ ', 'square':'▪ '}
    if style in bullets:
        return bullets[style]
    label = str(index)
    if style == 'decimal-leading-zero':
        label = ('-' if index < 0 else '') + str(abs(index)).zfill(2)
    elif style in {'lower-latin','upper-latin','lower-alpha','upper-alpha'} and index > 0:
        letters = []
        while index:
            index, digit = divmod(index - 1, 26)
            letters.append(chr(ord('a') + digit))
        label = ''.join(reversed(letters))
    elif style in {'lower-roman','upper-roman'} and 0 < index < 4000:
        parts = []
        for value, signs in ((1000,'M'),(900,'CM'),(500,'D'),(400,'CD'),(100,'C'),(90,'XC'),
                             (50,'L'),(40,'XL'),(10,'X'),(9,'IX'),(5,'V'),(4,'IV'),(1,'I')):
            count, index = divmod(index, value)
            parts.append(signs * count)
        label = ''.join(parts).lower()
    if style.startswith('upper-'):
        label = label.upper()
    return label + '. '


def damaged_content_warnings(warnings):
    selected = [message for message in warnings if message.startswith((
        'В исходнике не удалось прочитать страницы', 'Часть изображений ', 'Повреждённая обложка',
        'Повреждённая иллюстрация', 'Частично восстановлено изображение JPEG',
        KINDLE_JPEG_TRAILER_LOSS, MOBI_IMAGE_REDUCTION,
        'Описание FB3 недоступно',
        'Оглавление EPUB повреждено', 'Не перенесены переходы оглавления EPUB', MOBI_NAVIGATION_LOSS, MOBI_METADATA_LOSS,
        EPUB_TRUNCATED_CHAPTER, EPUB_DANGLING_START, EPUB_MISSING_BODY,
        'Не перенесены повторные разделы EPUB', 'Страницы DjVu с повреждённым текстовым слоем',
        'Восстановлена часть страниц DjVu:',
        'В архиве EPUB отсутствуют файлы из порядка чтения',
        'В копии закрыты недостающие теги FB2', 'В исходном FB2 отсутствуют', 'В исходной FB2 отсутствуют цели ссылок',
        'В исходном EPUB отсутствуют данные обложки',
        'Страница обложки EPUB перенесена в книгу без отдельной обложки FB2',
        'У некоторых ссылок Kindle отсутствует адрес', KFX_METADATA_LOSS, 'В EPUB отсутствуют некоторые встроенные шрифты',
        'Не перенесены встроенные шрифты Kindle',
        'Некоторые иллюстрации отсутствуют в исходных файлах', 'Нечитаемые символы HTML', 'Нечитаемые символы исходника',
        'У некоторых ссылок CHM недоступна цель', 'Нечитаемые символы RTF',
        'Не найдена цель ссылки CHM', 'Не найдены остальные цели ссылок CHM',
        'Вложение CHM', 'В исходнике остались другие вложения CHM', 'Подписи ссылок на вложения сохранены.',
        'После окончания RTF обнаружены данные', 'Не найдена цель ссылки EPUB', 'Не найдена цель внутренней ссылки',
        'Не перенесена вложенная ссылка EPUB', 'Некорректный адрес ссылки EPUB',
        'Скрытая навигация EPUB перенесена в конец FB2',
        'Метка обложки EPUB отсутствует', 'Не удалось прочитать обложку EPUB',
        'Сноска DOCX отсутствует', DOC_NOTE_LAYOUT_LOSS, 'Не перенесён объект DOCX', DOCX_PAGE_OVERLAYS,
        'Встроенные объекты DOCX перенесены как изображения',
        'Нумерация сносок DOCX заменена обычной',
        'Не восстановлена метка списка DOCX',
        'Графики старого DOC перенесены как изображения', 'Обрезка изображения DOCX не перенесена',
        'Не перенесены вертикальные линии на полях DOCX',
        'Вертикальные линии на полях (', 'Не перенесены вертикальные линии на полях в FB2',
        'Размеры размещения иллюстраций сохранены в FB2', 'Размеры размещения внутри составных ссылок',
        'Горизонтальные линии на полях DOC сохранены перед абзацами',
        'Разделители страниц DOC сохранены перед текстом',
        'Разделитель DOC сохранён перед соответствующим абзацем',
        'Подчёркивание заголовка DOC сохранено отдельной линией',
        'Линия DOC сохранена после связанного абзаца',
        'Линии старого DOC сохранены возле связанных абзацев',
        'Страница схемы старого DOC сохранена как изображение',
        'Плавающие текстовые рамки DOCX сохранены как изображения',
        'Страницы DOCX с рамками сохранены как изображения',
        'Положение составного рисунка DOCX на печатной странице может измениться',
        'Размеры пустых рамок FB2', 'Размеры пустых рамок внутри ссылок FB2',
        'Схемы старого DOC сохранены',
        'Не перенесён встроенный объект RTF', 'Встроенные объекты RTF перенесены как статическое содержимое',
        'Не перенесена фигура RTF', 'Положение плавающих объектов RTF изменено', 'Обрезка иллюстраций RTF не перенесена',
        'Рамки RTF с привязкой к странице',
        'Строка таблицы RTF', 'В строке таблицы RTF', 'У горизонтального объединения ячеек RTF',
        'Вертикальное объединение ячеек RTF не восстановлено', 'Вложенные таблицы RTF',
        'Вертикальное объединение ячеек DOCX не восстановлено',
        'Строки таблицы, полностью занятые объединёнными ячейками',
        'Вложенные таблицы представлены последовательными блоками FB2',
        'Нестандартные таблицы представлены последовательными блоками FB2',
        'Размеры или оформление столбцов EPUB могут отличаться в FB2',
        'Внешняя таблица из одной ячейки заменена разделом FB2',
        'Вложенные таблицы развёрнуты внутри ячеек FB2',
        'Переходы внутри строк и ячеек таблиц FB2 ведут к началу ячеек',
        'Таблицы без строк заменены пустыми абзацами при сохранении в FB2',
        'Сложная цитата EPUB представлена разделом FB2',
        'Повреждено оглавление CHM', 'Раздел CHM «', 'Архив CHM повреждён', 'Архив EPUB повреждён',
        'Не удалось прочитать приложение к комиксу', 'Архив комикса повреждён',
        'Изображение CHM размером 1 × 1 недоступно',
        'Видео EPUB не перенесено', 'Аудио EPUB не перенесено', 'Виджет Apple Books не перенесён',
        'Видео EPUB показано статично', 'Аудио EPUB показано статично', 'Субтитры EPUB не перенесены',
        'Субтитры EPUB восстановлены частично',
        'Формулы EPUB сохранены как изображения',
        'Исправлена повреждённая разметка главы EPUB', 'Оформление иллюстрации SVG упрощено', 'SVG в «',
        'Элемент EPUB не перенесён', 'Таблица стилей EPUB недоступна', 'Ресурс оформления EPUB не перенесён',
        'Не удалось прочитать текстовый слой страниц DjVu', 'Не удалось прочитать текстовый слой страниц PDF',
        'Нечитаемые символы PDF на страницах', 'Нечитаемые символы DjVu на страницах',
        'Не удалось перенести все переходы оглавления',
        'Заголовки в ячейках таблиц сохранены', 'Выравнивание таблиц и схем в FB2')) or
        message.startswith('Изображения страниц исходника не читаются') or
        re.match(r'Страница \d+: нечитаемые символы исходного текстового слоя', message)]
    pictures = [(int(match[1]), message) for message in warnings
                if (match := re.match(r'Изображение (\d+) недоступно\.', message))]
    return selected + [message for _, message in sorted(pictures)]


def optional_component_id(component, tools_root=None):
    """Keep old full-converter clients compatible; new packages name dependencies."""
    root = Path(tools_root or Path(__file__).resolve().parent.parent)
    try:
        modern = (root/'bookconvert/MODULAR_API.txt').read_text('ascii').strip() == '1'
    except (OSError, UnicodeError):
        modern = False
    if not modern and component in {'ImageProcessing', 'XPS', 'LegacyOffice', 'Kindle', 'LegacyBooks'}:
        return 'BookConverter'
    return component


def image_processor_path(tools_root):
    root = Path(tools_root)
    current = root/'images/HomeLibImages.exe'
    # Existing installations may retain the former shared helper. Reuse it;
    # new downloads put image processing in its own component and directory.
    return current if current.is_file() else root/'xps/HomeLibXps.exe'


def observe_component_tools(tools_root):
    """Bounded actual helper/codec use for one short-lived CLI process."""
    used_tools = set()
    root = Path(tools_root).resolve()
    def observe_tool(event, arguments):
        if event not in {'subprocess.Popen', 'ctypes.dlopen'} or not arguments or len(used_tools) >= 32:
            return
        try:
            executable = arguments[0]
            if not executable and event == 'subprocess.Popen':
                # On Windows Popen normally leaves lpApplicationName empty;
                # the executable is argv[0] of its generated command line.
                command = arguments[1]
                if isinstance(command, (list, tuple)):
                    executable = command[0]
                else:
                    command = command.lstrip()
                    executable = command[1:command.index('"', 1)] if command.startswith('"') else command.split(None, 1)[0]
            path = Path(executable).resolve()
            path.relative_to(root)
            if path.suffix.lower() in {'.exe', '.dll'}:
                used_tools.add(str(path))
        except (OSError, TypeError, ValueError, RuntimeError, IndexError):
            pass  # Optional bookkeeping must never prevent decoding a book.
    sys.addaudithook(observe_tool)
    return used_tools


def tag(node):
    return node.tag.rsplit('}', 1)[-1] if isinstance(node.tag, str) else ''


FB2_WINDOWS1251_DECLARATION = re.compile(
    br"""^(?:\xef\xbb\xbf)?<\?xml\s+[^?]*\bencoding\s*=\s*(["'])(windows-1251|cp1251)\1""", re.I)


def repair_fb2_encoding(data):
    """Match the native FB2 reader's conservative repair for mislabeled UTF-8."""
    prefix = data[:8192]
    declaration = FB2_WINDOWS1251_DECLARATION.match(prefix[:512])
    if not declaration or not re.search(br'<(?:[A-Za-z_][\w.-]*:)?FictionBook(?=[\s>/])', prefix):
        return data
    if not (prefix.startswith(b'\xef\xbb\xbf') or
            re.search(br'(?:\xd0[\x81\x90-\xbf]|\xd1[\x80-\x8f\x91]){4}', prefix)):
        return data
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return data
    start, end = declaration.span(2)
    return data[:start] + b'UTF-8' + data[end:]


def repair_epub_namespace(data):
    """Repair the empty prefix on a standard namespace declaration in a start tag."""
    if data.startswith((b'\xff\xfe', b'<\x00')):
        encoding = 'utf-16-le'
    elif data.startswith((b'\xfe\xff', b'\x00<')):
        encoding = 'utf-16-be'
    else:
        encoding = None
    probe = data
    if encoding:
        if 'xmlns:'.encode(encoding) not in data:
            return data
        try:
            probe = data.decode(encoding).encode('utf-8')
        except UnicodeError:
            return data
    if b'xmlns:' not in probe:
        return data

    def repair_tag(match):
        start_tag = match[1]
        if not start_tag or b'xmlns:' not in start_tag:
            return match[0]
        return EPUB_EMPTY_PREFIX.sub(lambda token: token[1] or token[0], start_tag)

    repaired = XML_NAMESPACE_TAG.sub(repair_tag, probe)
    if repaired == probe:
        return data
    return repaired.decode('utf-8').encode(encoding) if encoding else repaired


def xml(data, maximum=MAX_FILE, *, namespace_warnings=None):
    if len(data) > maximum:
        raise ConversionError('Файл превышает предел конвертации ('+str(maximum//1024//1024)+' МБ).')
    data = repair_fb2_encoding(data)
    # ElementTree never fetches external entities. Reject internal entities too.
    probe = data.replace(b'\x00', b'')  # UTF-16/32 declarations must not bypass the gate.
    if re.search(br'<!\s*ENTITY\b|<!\s*DOCTYPE\b[^>]*\[', probe, re.I):
        raise ConversionError('Документ с внутренними сущностями DTD нельзя безопасно преобразовать.')
    try:
        try:
            root = ET.fromstring(data)
        except ET.ParseError as error:
            if namespace_warnings is None or error.code != expat.errors.codes[expat.errors.XML_ERROR_INVALID_TOKEN]:
                raise
            repaired = repair_epub_namespace(data)
            if repaired is data:
                raise
            root = ET.fromstring(repaired)
            namespace_warnings.add(EPUB_NAMESPACE_REPAIR)
        pending = [(root, 0)]; nodes = 0
        while pending:
            node, depth = pending.pop(); nodes += 1
            if depth > 128 or nodes > 500000:
                raise ConversionError('XML книги слишком сложен для конвертации.')
            pending.extend((child, depth + 1) for child in node)
        return root
    except (ET.ParseError, LookupError) as error:
        raise ConversionError('Некорректная структура XML: ' + str(error)) from error


def parse_fb2_file(path, maximum, *, keep_binary_data, binary_files=None, binary_directory=None,
                   maximum_nodes=500000, part_completed=None):
    """Parse large FB2 in chunks, retaining image data only when it will be used."""
    class Structure(ET.TreeBuilder):
        depth = nodes = 0
        skip_data = False
        binary_stream = None
        body = None
        pending_part = None

        def complete_part(self):
            if self.pending_part is not None:
                part_completed(self.body, self.pending_part)
                self.body.remove(self.pending_part)
                self.pending_part = None

        def start(self, name, attrs):
            self.depth += 1
            self.nodes += 1
            if self.depth > 129 or self.nodes > maximum_nodes:
                raise ConversionError('XML книги слишком сложен для конвертации.')
            if self.depth == 2:
                self.skip_data = not keep_binary_data and name == '{' + FB + '}binary'
            node = super().start(name, attrs)
            if part_completed is not None and self.depth == 2 and name == '{' + FB + '}body':
                self.body = node
            elif self.depth == 3 and self.body is not None:
                # TreeBuilder attaches trailing text when the following tag starts.
                self.complete_part()
            if self.depth == 2 and self.skip_data and binary_directory is not None:
                file = binary_directory / ('base64-' + str(len(binary_files)))
                self.binary_stream = file.open('xb')
                binary_files[node] = file
            return node

        def end(self, name):
            node = super().end(name)
            if self.depth == 3 and self.body is not None:
                self.pending_part = node
            elif self.depth == 2 and self.body is not None:
                self.complete_part()
                part_completed(self.body, None)
                self.body = None
            if self.depth == 2:
                self.skip_data = False
                if self.binary_stream is not None:
                    self.binary_stream.close()
                    self.binary_stream = None
            self.depth -= 1
            return node

        def data(self, value):
            if not self.skip_data:
                super().data(value)
            elif self.binary_stream is not None:
                self.binary_stream.write(value.encode('utf-8'))

    def reject_internal_dtd(_name, _system_id, _public_id, has_internal_subset):
        if has_internal_subset:
            raise ConversionError('Документ с внутренними сущностями DTD нельзя безопасно преобразовать.')

    def expanded(name):
        return '{' + name if '}' in name else name

    tree = Structure()
    parser = expat.ParserCreate(namespace_separator='}')
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.StartDoctypeDeclHandler = reject_internal_dtd
    parser.StartElementHandler = lambda name, attrs: tree.start(expanded(name), {expanded(k): v for k, v in attrs.items()})
    parser.EndElementHandler = lambda name: tree.end(expanded(name))
    parser.CharacterDataHandler = tree.data
    with Path(path).open('rb') as stream:
        try:
            remaining = maximum
            while chunk := stream.read(min(256 * 1024, remaining + 1)):
                remaining -= len(chunk)
                if remaining < 0:
                    raise ConversionError('Файл превышает предел конвертации (' + str(maximum // 1024 // 1024) + ' МБ).')
                parser.Parse(chunk, False)
            parser.Parse(b'', True)
            return tree.close()
        except (expat.ExpatError, LookupError) as error:
            raise ConversionError('Некорректная структура XML: ' + str(error)) from error
        finally:
            if tree.binary_stream is not None:
                tree.binary_stream.close()


def truncated_fb2_recovery(data, maximum):
    """Recognize EOF after a closed element, in plain paragraph text or in an image."""
    parser = expat.ParserCreate(namespace_separator='}')
    stack = []
    nested_binary = False
    last_end = -1

    def start(name, attributes):
        nonlocal nested_binary
        if len(stack) > 128:
            raise ConversionError('XML книги слишком сложен для конвертации.')
        if len(stack) == 2 and stack[-1][0] == FB + '}binary':
            nested_binary = True
        elif len(stack) == 1:
            nested_binary = False
        stack.append((name, attributes, parser.CurrentByteIndex))

    def end(_name):
        nonlocal last_end
        last_end = parser.CurrentByteIndex
        stack.pop()

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    try:
        parser.Parse(data, True)
    except expat.ExpatError as error:
        if error.code != expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS]:
            return None
    names = [frame[0] for frame in stack]
    root = FB + '}FictionBook'
    section = FB + '}section'
    if names[:1] == [root]:
        open_final_paragraph = len(names) >= 4 and names[-1] == FB + '}p'
        remaining = names[1:-1] if open_final_paragraph else names[1:]
        if not remaining or remaining[0] == FB + '}body' and all(name == section for name in remaining[1:]):
            if open_final_paragraph:
                paragraph_start = stack[-1][2]
                paragraph_tag = re.compile(br'''<[^<>\x00- /]+(?:[^"'<>]++|"[^"]*"|'[^']*')*>''')
                opening = paragraph_tag.match(data, paragraph_start)
                plain_tail = data[opening.end():] if opening else b''
                can_close = bool(plain_tail.strip()) and b'<' not in plain_tail
            else:
                can_close = last_end >= 0 and re.fullmatch(br'</[^<>\x00- ]+\s*>\s*', data[last_end:])
            if can_close:
                tags = [re.match(br'<([^<>\x00- />]+)(?=[\s/>])', data[offset:offset+512])
                        for _, _, offset in stack]
                if all(tags):
                    return data + b''.join(b'</' + match[1] + b'>' for match in reversed(tags))
    if nested_binary or names != [root, FB + '}binary']:
        return None
    _, attrs, image_at = stack[1]
    identity = attrs.get('id')
    if not identity or not attrs.get('content-type', '').lower().startswith('image/'):
        return None
    root_at = stack[0][2]
    root_name = re.match(br'<([^\x00-\x20/>]{1,256})(?=[\s/>])', data[root_at:root_at + 258])
    if root_name is None:
        return None
    book = xml(data[:image_at] + b'</' + root_name[1] + b'>', maximum)
    if any(node.get('id') == identity for node in book.iter()):
        return None
    image = '{' + FB + '}image'
    href = '{' + XL + '}href'
    cover = any(node.get(href) == '#' + identity for page in book.iter('{' + FB + '}coverpage')
                for node in page.iter(image))
    # This helper uses only the shared FB2 markup routines, with no image codecs.
    spec = importlib.util.spec_from_file_location('homelib_image_quality', Path(__file__).with_name('image_quality.py'))
    image_quality = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(image_quality)
    api = SimpleNamespace(FB=FB, XL=XL, tag=tag, element=element, rewrite_css_urls=rewrite_css_urls)
    if not image_quality.readable_text(api, book, True):
        return None
    image_quality.strip_fb2(api, book, only=identity, note='[Повреждённое изображение пропущено]')
    complete_ids = {node.get('id') for node in children(book, 'binary')}
    if any((node.get(href) or '').removeprefix('#') not in complete_ids for node in book.iter(image)):
        return None
    if cover:
        body = first(book, 'body')
        at = next((i for i, node in enumerate(body) if tag(node) == 'section'), len(body))
        body.insert(at, image_quality.image_note(api, body, True, '[Повреждённая обложка пропущена]'))
    return FB2ImageRecoveryRequired(serialized(book), cover, identity)


def read_fb2(data, maximum, warnings):
    """Repair local FB2 syntax errors in a working copy after strict parsing fails."""
    try:
        return xml(data, maximum), None
    except ConversionError as original:
        if not isinstance(original.__cause__, ET.ParseError) or len(data)>16*1024*1024:
            raise
        # These repairs address ASCII syntax in UTF-8 and single-byte encodings.
        if b'\x00' in data[:4] or data.startswith((b'\xff\xfe', b'\xfe\xff')):
            raise
        if b'\x00' in data:
            raise ConversionError('FB2 повреждён: внутри файла найдены нулевые байты.') from original
        candidate = repair_fb2_encoding(data)
        for _ in range(4):
            closed_tail = False
            parser = expat.ParserCreate(namespace_separator='}')
            try:
                parser.Parse(candidate, True)
            except expat.ExpatError as error:
                offset = parser.ErrorByteIndex
                if error.code == expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS]:
                    recovery = truncated_fb2_recovery(candidate, maximum)
                    if isinstance(recovery, FB2ImageRecoveryRequired):
                        raise recovery from original
                    if recovery is None:
                        raise ConversionError('FB2 обрывается до конца документа.') from original
                    candidate = recovery
                    closed_tail = True
                elif (error.code == expat.errors.codes[expat.errors.XML_ERROR_INVALID_TOKEN] and
                        offset > 0 and candidate[offset-1:offset] == b'&' and
                        candidate[offset:offset+1] in (b' ',b'\r',b'\n',b'\t')):
                    candidate = candidate[:offset] + b'amp;' + candidate[offset:]
                elif error.code == expat.errors.codes[expat.errors.XML_ERROR_TAG_MISMATCH] and offset >= 2 and candidate[offset-2:offset+6] == b'</title>':
                    candidate = candidate[:offset-2] + candidate[offset+6:]
                elif (error.code == expat.errors.codes[expat.errors.XML_ERROR_UNBOUND_PREFIX] and
                        re.match(br'<[^<>]*\s+xlink:(?:href|type)\s*=', candidate[offset:offset+2048])):
                    root = re.match(br'^(?:\xef\xbb\xbf)?\s*(?:<\?xml[^?]*\?>\s*)?<FictionBook(?=[\s>])', candidate[:8192])
                    if root is None:
                        raise original
                    at = root.end()
                    candidate = candidate[:at] + b' xmlns:xlink="http://www.w3.org/1999/xlink"' + candidate[at:]
                else:
                    raise original
            try:
                book = xml(candidate, maximum)
            except ConversionError:
                continue
            if book.tag != '{'+FB+'}FictionBook':
                raise original
            if closed_tail:
                if not any(plain(body) for body in book.findall('{' + FB + '}body')):
                    raise ConversionError('FB2 обрывается до конца документа.') from original
                warnings.add('В копии закрыты недостающие теги FB2. Полноту текста подтвердить нельзя. Исходный файл сохранён.')
                images = {node.get('id') for node in children(book, 'binary')}
                if any(node.get('{' + XL + '}href', '').startswith('#') and
                       node.get('{' + XL + '}href')[1:] not in images
                       for cover in book.iter('{' + FB + '}coverpage') for node in cover.iter('{' + FB + '}image')):
                    warnings.add('В исходном FB2 отсутствуют данные обложки.')
            else:
                warnings.add('Исправлена разметка FB2 в сохранённой копии. Исходный файл сохранён.')
            return book, candidate
        raise original


def empty_epub_chapter(data):
    """Recognize the empty spine items emitted by some old EPUB generators."""
    if len(data) > 128:
        return False
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    try:
        text = data.decode(encoding)
    except UnicodeDecodeError:
        return False
    return re.fullmatch(r'[ \t\r\n]*</body[ \t\r\n]*>[ \t\r\n]*</html[ \t\r\n]*>[ \t\r\n]*',
                        text, re.IGNORECASE) is not None


def epub_xhtml_encoding(data):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return 'utf-16'
    if data.startswith(b'\xef\xbb\xbf'):
        return 'utf-8-sig'
    declaration = re.match(br'''<\?xml\s+[^>]*?\bencoding\s*=\s*["']([^"']+)["']''', data)
    return declaration[1].decode('ascii') if declaration else 'utf-8'


def xhtml(data, *, namespace_warnings=None):
    """Some XHTML chapters use named HTML entities without declaring them.

    Expand that fixed, local table only; never load a DTD or fetch any resource.
    Decoding by the XML declaration preserves non-UTF-8 EPUB 2 chapters.
    """
    try:
        return xml(data, namespace_warnings=namespace_warnings)
    except ConversionError as error:
        parse_error = error.__cause__
        if (not isinstance(parse_error, ET.ParseError) or
                parse_error.code != expat.errors.codes[expat.errors.XML_ERROR_UNDEFINED_ENTITY]):
            raise
        try:
            text = data.decode(epub_xhtml_encoding(data))
        except (LookupError, UnicodeError) as error:
            raise ConversionError('Неизвестная кодировка главы EPUB.') from error
        def named_entity(match):
            name = match[1]
            if name in name2codepoint and name not in {'amp', 'lt', 'gt', 'quot', 'apos'}:
                return f'&#{name2codepoint[name]};'
            return match[0]

        tokens = (r'<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|'
                  r'''<!DOCTYPE(?:"[^"]*"|'[^']*'|[^>"'])*>|&([A-Za-z][A-Za-z0-9]+);''')
        repaired = re.sub(tokens, named_entity, text, flags=re.S)
        if repaired == text:
            raise
        repaired = re.sub(r'''\A(<\?xml\s+[^>]*?\bencoding\s*=\s*["'])[^"']+''', r'\1utf-8', repaired)
        return xml(repaired.encode('utf-8'), namespace_warnings=namespace_warnings)


EPUB_TAIL_BOUNDARY = re.compile(r'</(?:[\w.-]+:)?body\s*>\s*</(?:[\w.-]+:)?html\s*>', re.I)
EPUB_TAIL_TOKEN = re.compile(r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<(/?)([a-z][a-z0-9]*)(?=[\s/>])'
                             r'''((?:"[^"]*"|'[^']*'|[^<>"'])*)>''', re.I | re.S)
EPUB_TAIL_BLOCKS = {'p', 'center', 'div', 'blockquote', 'pre', 'ul', 'ol', 'li'}
EPUB_TAIL_INLINE = {'a', 'b', 'big', 'code', 'em', 'i', 's', 'small', 'span', 'strong', 'sub', 'sup', 'u'}
EPUB_TAIL_VOID = {'br', 'hr', 'img'}


def rejoin_epub_trailing_markup(data, error):
    """Move a small, recognizable HTML fragment into a complete XHTML chapter."""
    cause = error.__cause__
    if not isinstance(cause, ET.ParseError) or cause.code != expat.errors.codes[expat.errors.XML_ERROR_JUNK_AFTER_DOC_ELEMENT]:
        raise error
    try:
        encoding = epub_xhtml_encoding(data)
        text = data.decode(encoding)
        # Bound the search to the end of the member. The prefix is parsed
        # separately so a fake closing tag in a comment cannot identify it.
        boundary = EPUB_TAIL_BOUNDARY.search(text, max(0, len(text) - 65536))
        if boundary is None or not (tail := text[boundary.end():]).strip():
            raise error
        main = xhtml(text[:boundary.end()].encode(encoding))
        if tag(main) != 'html' or first(main, 'body') is None:
            raise error
        pieces, stack = [], []
        position = 0
        for token in EPUB_TAIL_TOKEN.finditer(tail):
            gap = tail[position:token.start()]
            if '<' in gap:
                raise error
            pieces.append(gap)
            position = token.end()
            closing, name, attributes = token.groups()
            if name is None:
                pieces.append(token[0])
                continue
            name = name.lower()
            if name not in EPUB_TAIL_BLOCKS | EPUB_TAIL_INLINE | EPUB_TAIL_VOID:
                raise error
            mapped = 'p' if name == 'center' else name
            if closing:
                if attributes.strip() or not stack or stack.pop() != name:
                    raise error
                pieces.append(f'</{mapped}>')
                continue
            if name in EPUB_TAIL_BLOCKS and stack and stack[-1] == 'p':
                stack.pop()
                pieces.append('</p>')
            attributes = attributes.rstrip()
            empty = attributes.endswith('/') or name in EPUB_TAIL_VOID
            attributes = attributes.removesuffix('/')
            if name == 'center' and not re.search(r'\bstyle\s*=', attributes, re.I):
                attributes += ' style="text-align:center"'
            pieces.append(f'<{mapped}{attributes}{"/" if empty else ""}>')
            if not empty:
                if len(stack) == 128:
                    raise error
                stack.append(name)
        if '<' in tail[position:]:
            raise error
        pieces.append(tail[position:])
        pieces.extend(f'</{"p" if name == "center" else name}>' for name in reversed(stack))
        repaired = (text[:boundary.start()] + ''.join(pieces) + boundary[0]).encode(encoding)
        return xhtml(repaired), repaired
    except (ConversionError, LookupError, UnicodeError):
        raise error from cause


EPUB_CLOSING_TOKEN = re.compile(
    r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|'
    r'''<!DOCTYPE(?:"[^"]*"|'[^']*'|[^<>"'\[])*>|'''
    r'''<(/?)([A-Za-z_][\w:.-]*)(?=[\s/>])((?:"[^"]*"|'[^']*'|[^<>"']++)*)>''', re.S)
EPUB_CLOSABLE_TAGS = {'span', 'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}
EPUB_STRAY_CLOSING_TAGS = {'span', 'p', 'div', 'blockquote'}


def balance_epub_closing_tags(data, error):
    """Repair ordinary XHTML containers without touching any text or start tag."""
    cause = error.__cause__
    if not isinstance(cause, ET.ParseError) or cause.code not in {
            expat.errors.codes[expat.errors.XML_ERROR_TAG_MISMATCH],
            expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS]}:
        raise error
    try:
        encoding = epub_xhtml_encoding(data)
        text = data.decode(encoding)
    except (LookupError, UnicodeError):
        raise error from cause
    stack, pieces = [], []
    saw_body = False
    position = copied = 0
    for match in EPUB_CLOSING_TOKEN.finditer(text):
        if '<' in text[position:match.start()]:
            raise error
        position = match.end()
        closing, name, attributes = match.groups()
        if name is None:
            continue
        if not closing:
            if name == 'body' and stack == ['html'] and not attributes.rstrip().endswith('/'):
                saw_body = True
            if not attributes.rstrip().endswith('/'):
                if len(stack) >= 128:
                    raise error
                stack.append(name)
            continue
        if attributes.strip():
            raise error
        if stack and name == stack[-1]:
            stack.pop()
            continue
        if stack[:2] != ['html', 'body']:
            raise error
        pieces.append(text[copied:match.start()])
        if name not in stack:
            if name not in EPUB_STRAY_CLOSING_TAGS or stack[-1] not in EPUB_CLOSABLE_TAGS | {'body'}:
                raise error
            copied = match.end()
        else:
            while stack[-1] != name:
                unclosed = stack.pop()
                if unclosed not in EPUB_CLOSABLE_TAGS and not (unclosed == 'body' and name == 'html'):
                    raise error
                pieces.append(f'</{unclosed}>')
            stack.pop()
            copied = match.start()
    truncated = bool(stack)
    head_only = (not saw_body and cause.code == expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS] and
                 stack in (['html'], ['html', 'head'], ['html', 'head', 'title']))
    if (not (saw_body or head_only) or '<' in text[position:] or
            (truncated and not head_only and (stack[:1] != ['html'] or
                            (len(stack) > 1 and stack[1] != 'body') or
                            any(name not in EPUB_CLOSABLE_TAGS for name in stack[2:])))):
        raise error
    if not (pieces or truncated):
        raise error
    pieces.append(text[copied:])
    pieces.extend(f'</{name}>' for name in reversed(stack))
    repaired = ''.join(pieces).encode(encoding)
    document = xhtml(repaired)
    if tag(document) != 'html' or (not head_only and first(document, 'body') is None):
        raise error
    return document, repaired, truncated


EPUB_HTML5_REPAIR = 'Исправлена повреждённая разметка главы EPUB'


def remove_epub_dangling_start(data, error, part):
    """Recover the intact markup after an isolated, cut-off container tag."""
    cause = error.__cause__
    if (not isinstance(cause, ET.ParseError) or
            cause.code != expat.errors.codes[expat.errors.XML_ERROR_INVALID_TOKEN] or len(data) > MAX_FILE):
        raise error
    try:
        encoding = epub_xhtml_encoding(data)
        text = data.decode(encoding)
    except (LookupError, UnicodeError):
        raise error from cause
    line, column = cause.position
    rows = text.split('\n', line)
    if line < 2 or len(rows) < line:
        raise error
    fragment, next_row = rows[line-2:line]
    unfinished = re.search(r'<(?:p|div|span|h[1-6])(?:[ \t]+[A-Za-z_:][\w:.-]*)?[ \t]*\r?\Z', fragment)
    if (unfinished is None or not re.fullmatch(r'[ \t]*', next_row[:column]) or
            not next_row[column:].startswith('<')):
        raise error
    rows[line-2] = fragment[:unfinished.start()]
    if not rows[line-2].strip():
        del rows[line-2]
    repaired = '\n'.join(rows).encode(encoding)
    try:
        document = xhtml(repaired)
    except ConversionError as incomplete:
        document, repaired, _ = balance_epub_closing_tags(repaired, incomplete)
    if tag(document) != 'html' or first(document, 'body') is None:
        raise error
    label = f' «{posixpath.basename(part)[:100]}»' if part else ''
    warning = f'{EPUB_DANGLING_START}{label}. Доступный текст сохранён, полноту главы подтвердить нельзя.'
    return document, repaired, warning


def html5_epub_document(data):
    vendor = str(Path(__file__).with_name('vendor'))
    sys.path.insert(0, vendor)
    try:
        import html5lib
        document = html5lib.parse(data.decode(epub_xhtml_encoding(data)), namespaceHTMLElements=True)
    finally:
        sys.path.pop(0)
    # HTML parsing resolves foreign names. Leave their declarations to the XML writer.
    for node in document.iter():
        for name in tuple(node.attrib):
            if name.startswith('{http://www.w3.org/2000/xmlns/}'):
                del node.attrib[name]
    return xml(serialized(document))


def repair_epub_content(data, error, part, *, allow_html5=False):
    cause = error.__cause__
    if isinstance(cause, ET.ParseError) and cause.code == expat.errors.codes[expat.errors.XML_ERROR_JUNK_AFTER_DOC_ELEMENT]:
        document, repaired = rejoin_epub_trailing_markup(data, error)
        return document, repaired, EPUB_TRAILING_MARKUP_REPAIR
    if isinstance(cause, ET.ParseError) and cause.code == expat.errors.codes[expat.errors.XML_ERROR_INVALID_TOKEN]:
        return remove_epub_dangling_start(data, error, part)
    if (isinstance(cause, ET.ParseError) and cause.code == expat.errors.codes[expat.errors.XML_ERROR_NO_ELEMENTS] and
            not data.removeprefix(b'\xef\xbb\xbf').strip()):
        document, repaired, truncated = element(XH, 'html'), data, True
    else:
        try:
            document, repaired, truncated = balance_epub_closing_tags(data, error)
        except ConversionError:
            mismatch = isinstance(cause, ET.ParseError) and cause.code == expat.errors.codes[expat.errors.XML_ERROR_TAG_MISMATCH]
            if not allow_html5 or not mismatch or len(data) > 8 * 1024 * 1024:
                raise
            document = html5_epub_document(data)
            label = posixpath.basename(part)[:100]
            return document, serialized(document), f'{EPUB_HTML5_REPAIR} «{label}».'
    if first(document, 'body') is None:
        label = f' «{posixpath.basename(part)[:100]}»' if part else ''
        warning = f'{EPUB_MISSING_BODY}{label}.'
        marker = warning
        head = first(document, 'head')
        title = first(head, 'title') if head is not None else None
        if title is not None and plain(title):
            marker += f' Сохранился фрагмент заголовка «{plain(title)[:200]}».'
        body = element(XH, 'body')
        body.append(element(XH, 'p', f'[{marker}]'))
        document.append(body)
        return document, serialized(document), warning
    warning = EPUB_CLOSING_TAG_REPAIR
    if truncated:
        label = f' «{posixpath.basename(part)[:100]}»' if part else ''
        warning = f'{EPUB_TRUNCATED_CHAPTER}{label}. Доступный текст сохранён, полноту главы подтвердить нельзя.'
    return document, repaired, warning


def read_epub_content(data, warnings, *, part='', allow_partial_epub=False):
    try:
        return xhtml(data, namespace_warnings=warnings)
    except ConversionError as error:
        document, _, warning = repair_epub_content(data, error, part, allow_html5=allow_partial_epub)
        if warning.startswith((EPUB_TRUNCATED_CHAPTER, EPUB_DANGLING_START, EPUB_MISSING_BODY)) and not allow_partial_epub:
            raise ConversionError(warning + ' Для частичного экспорта требуется подтверждение.') from error
        warnings.add(warning)
        return document


def serialized(node):
    return ET.tostring(node, encoding='utf-8', xml_declaration=True)


def local_foreign_namespaces(root, xhtml_uri):
    """Keep actual QName bindings when the writer replaces the HTML root."""
    xml_uri = 'http://www.w3.org/XML/1998/namespace'

    def namespaces(node):
        return {name[1:].split('}', 1)[0] for name in [node.tag, *node.attrib]
                if isinstance(name, str) and name.startswith('{')
                and name[1:].split('}', 1)[0] not in {xhtml_uri, xml_uri}}

    uris = set()
    for node in root.iter():
        uris.update(namespaces(node))
    if not uris:
        return
    preferred = {'http://www.w3.org/2000/svg': 'svg',
                 'http://www.w3.org/1999/xlink': 'xlink',
                 'http://www.w3.org/1998/Math/MathML': 'math',
                 'http://www.idpf.org/2007/ops': 'epub'}
    prefixes, used = {}, {'', 'xml', 'xmlns'}
    for uri in sorted(uris):
        prefix = preferred.get(uri, 'hlns' + str(len(prefixes)))
        while prefix in used:
            prefix += '_'
        used.add(prefix)
        ET.register_namespace(prefix, uri)
        prefixes[uri] = prefix

    def visit(node, inherited):
        scope = inherited | namespaces(node)
        for uri in scope - inherited:
            node.set('xmlns:' + prefixes[uri], uri)
        for child in node:
            visit(child, scope)

    # Root declarations alone are lost by the writer. Start the scope again
    # on each retained subtree; QName URIs come from parsed XML, not guesses.
    for child in root:
        visit(child, set())



def prepare_html_writer_epub(source, destination, check=None):
    """Normalize XHTML syntax for HTML-oriented writers in a private EPUB.

    Prefixes and XML empty non-void tags are valid XHTML but are misread by
    kepubify's HTML parser. Preserve resources and actual foreign QName scopes.
    """
    archive = EpubArchive(source)
    namespaces = ET._namespace_map.copy()
    try:
        documents = set()
        container = xml(archive.read('META-INF/container.xml'))
        for rootfile in (n for n in container.iter() if tag(n) == 'rootfile'):
            package_path = archive.resolve('container.xml', rootfile.get('full-path',''))[0]
            package = xml(archive.read(package_path))
            for item in (n for n in package.iter() if tag(n) == 'item'):
                if item.get('media-type') == 'application/xhtml+xml':
                    documents.add(archive.resolve(package_path,item.get('href',''))[0])
        if not documents:
            raise ConversionError('В EPUB отсутствует текст книги.')
        with zipfile.ZipFile(destination,'x') as target:
            for entry in archive.archive.infolist():
                if check is not None: check()
                data = archive.read(entry.filename)
                if entry.filename in documents:
                    document = xhtml(data)
                    if document.tag != '{'+XH+'}html':
                        raise ConversionError('Некорректная глава EPUB.')
                    ET.register_namespace('', XH)
                    local_foreign_namespaces(document, XH)
                    data = ET.tostring(document,encoding='utf-8',xml_declaration=True,short_empty_elements=False)
                    # HTML parsers interpret </br> as a second line break.
                    # Pair empty containers, but leave void elements self-closing.
                    data = re.sub(rb'(<(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)\b[^<>]*?)></\2>',
                                  rb'\1 />', data)
                target.writestr(entry,data)
    finally:
        ET._namespace_map.clear()
        ET._namespace_map.update(namespaces)
        archive.close()


def element(namespace, local_name, text=None, **attributes):
    node = ET.Element('{' + namespace + '}' + local_name, attributes)
    node.text = text
    return node


FB2_COVER_PAGE_ATTRIBUTES = {'{' + EP + '}type': 'cover', 'data-homelib-fb2-cover': '1'}


def margin_rule_geometry(marker):
    match = re.fullmatch(MARGIN_RULE_PREFIX + r'(left|right):([0-9]{1,5}):([0-9]{1,5}):'
                         r'(-?[0-9]{1,8}):(-?[0-9]{1,8}):([0-9]{1,8}):([0-9]{1,5})', marker)
    if match is None:
        return None
    side = match[1]
    offset, band, left, top, height, width = map(int, match.groups()[1:])
    if (1 <= band <= 57600 and 0 <= offset <= band and abs(left) <= 57600 * 635
            and -80 * 12700 <= top <= 720 * 12700
            and 635 <= height <= 800 * 12700 and 635 <= width <= 63500):
        return side, offset, band, top, height, width


def word_spacer_dimensions(marker):
    match = re.fullmatch(WORD_SPACER_CLASS + r'([0-9]{1,5})-([0-9]{1,5})', marker)
    if match:
        width, height = map(int, match.groups())
        if 10 <= width <= 14400 and 10 <= height <= 14400:
            return width, height


def word_spacer_css(marker):
    dimensions = word_spacer_dimensions(marker)
    if dimensions:
        width, height = dimensions
        return f'display:inline-block;width:{width/20:g}pt;height:{height/20:g}pt;vertical-align:baseline'
    paragraph = re.fullmatch(WORD_SPACER_PARAGRAPH + r'(left|right|center|justify)-(none|[0-9a-f]{6})', marker)
    if paragraph:
        alignment, color = paragraph.groups()
        return f'text-align:{alignment}' + ('' if color == 'none' else f';background-color:#{color}')


def html_image_pixels(value):
    value = (value or '').strip()
    number = int(value) if re.fullmatch(r'[0-9]{1,5}', value) else 0
    return number if 0 < number <= 32768 else 0


def set_html_image_extent(image, width, height):
    if width:
        image.set('width', str(width))
    if height:
        image.set('height', str(height))
    if width and height:
        # Generated EPUBs use height:auto so pictures can shrink to fit.
        style = image.get('style', '').rstrip(';')
        image.set('style', ';'.join(filter(None, (style, f'aspect-ratio:{width}/{height}'))))


def word_rule_height(marker):
    if not marker.startswith(WORD_RULE_CLASS):
        return 0
    value = marker[len(WORD_RULE_CLASS):]
    height = int(value) if re.fullmatch(r'[1-9][0-9]{0,2}', value) else 0
    return height if height <= 720 else 0


def style_word_rule(image, height):
    classes = image.get('class', '').split()
    image.set('class', ' '.join([*classes, WORD_RULE_CLASS + str(height)]))
    image.set('style', f'display:block;width:100%;height:{height / 20:g}pt')


def word_line_geometry(marker):
    match = re.fullmatch(WORD_LINE_CLASS + r'([1-9][0-9]{0,4}):([1-9][0-9]{0,3}):(-?[0-9]{1,4})', marker)
    if match:
        width, height, left = map(int, match.groups())
        if width <= 28800 and height <= 1440 and abs(left) <= 1440:
            return width, height, left
    return None


def style_word_line(image, marker, geometry):
    width, height, left = geometry
    image.set('class', ' '.join((*image.get('class', '').split(), marker)))
    image.set('style', f'display:block;width:{width / 20:g}pt;height:{height / 20:g}pt;'
                       f'max-width:100%;margin-left:{left / 20:g}pt;margin-right:auto')


def word_list_css(marker):
    match = re.fullmatch(WORD_LIST_PARAGRAPH + r'(-?[0-9]{1,7}):(-?[0-9]{1,7})', marker)
    if match:
        margin, indent = map(int, match.groups())
        if abs(margin) <= 1_000_000 and abs(indent) <= 1_000_000:
            return f'margin-left:{margin / 20:g}pt;text-indent:{indent / 20:g}pt'
    return ''


def exif_keeps_image_axes(header):
    order = {b'II*\0': 'little', b'MM\0*': 'big'}.get(header[:4])
    if order is None or len(header) < 8:
        return False

    def read(offset, size):
        return int.from_bytes(header[offset:offset + size], order)

    directory = read(4, 4)
    if not 8 <= directory <= len(header) - 2:
        return False
    first = directory + 2
    end = first + 12 * read(directory, 2)
    if end + 4 > len(header):
        return False
    orientation = None
    for offset in range(first, end, 12):
        if read(offset, 2) == 0x0112:
            if orientation is not None or read(offset + 2, 2) != 3 or read(offset + 4, 4) != 1:
                return False
            orientation = read(offset + 8, 2)
    return orientation is None or 1 <= orientation <= 4


def jpeg_frame_size(data):
    # JPEG segments before the first scan contain the original pixel dimensions.
    offset, limit = 2, min(len(data), 1024 * 1024)
    while offset + 4 <= limit and data[offset] == 0xff:
        while offset < limit and data[offset] == 0xff:
            offset += 1
        if offset + 3 > limit:
            break
        marker = data[offset]
        if marker == 0 or 0xd0 <= marker <= 0xda:
            break
        offset += 1
        length = int.from_bytes(data[offset:offset + 2], 'big')
        end = offset + length
        if length < 2 or end > limit:
            break
        # Different readers can apply Exif orientation to the intrinsic size.
        if (marker == 0xe1 and data.startswith(b'Exif\0\0', offset + 2, end)
                and not exif_keeps_image_axes(data[offset + 8:end])):
            break
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc9, 0xca, 0xcb):
            if length < 11 or length != 8 + 3 * data[offset + 7]:
                break
            height = int.from_bytes(data[offset + 3:offset + 5], 'big')
            width = int.from_bytes(data[offset + 5:offset + 7], 'big')
            if width and height:
                return width, height
            break
        offset = end
    return 0, 0


def raster_header_size(data):
    if len(data) >= 24 and data.startswith(b'\x89PNG\r\n\x1a\n') and data[12:16] == b'IHDR':
        return int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')
    if len(data) >= 10 and data.startswith((b'GIF87a', b'GIF89a')):
        return int.from_bytes(data[6:8], 'little'), int.from_bytes(data[8:10], 'little')
    if data.startswith(b'\xff\xd8\xff'):
        return jpeg_frame_size(data)
    return 0, 0


def svg_changes_appearance(node):
    if any(node.get(attribute) for attribute in ('clip-path', 'mask', 'filter')):
        return True
    aspect_ratio = node.get('preserveAspectRatio', '').split()
    if (node.get('opacity', '1').strip() not in {'1', '1.0', '100%'} or
            node.get('visibility', 'visible').strip() != 'visible' or
            node.get('display', '').strip() == 'none' or
            'none' in aspect_ratio or 'slice' in aspect_ratio):
        return True
    transform = node.get('transform', '').strip()
    zero = r'[+-]?(?:0+(?:\.0*)?|\.0+)'
    return bool(transform and transform != 'none' and not re.fullmatch(
        rf'translate\(\s*{zero}(?:(?:\s*,\s*|\s+){zero})?\s*\)', transform))


def svg_picture_sizing(svg, picture):
    """Read inline sizing that can be written as static SVG geometry."""
    sizing = {}
    limits = set()
    for rule in picture.get('style', '').strip().split(';'):
        if not rule.strip():
            continue
        key, _, value = rule.lower().partition(':')
        key, value = key.strip(), value.strip()
        if key == 'text-align' and value in {'start', 'end', 'left', 'right', 'center', 'justify'}:
            # An SVG image has no text content to align.
            continue
        axis = key.removeprefix('max-')
        if axis not in {'width', 'height'} or not (svg.get('viewBox') and picture.get(axis)):
            return None
        if key != axis:
            if value != '100%':
                return None
            limits.add(axis)
        elif re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,5})?%', value) and 0 < float(value[:-1]) <= 100:
            sizing[axis] = value
        else:
            return None
    if limits:
        try:
            _, _, width, height = map(float, re.split(r'[\s,]+', svg.get('viewBox').strip()))
            dimensions = {'width': width, 'height': height}
            if any(axis not in sizing and not 0 < float(picture.get(axis)) <= dimensions[axis] for axis in limits):
                return None
        except ValueError:
            return None
    return sizing


def svg_cover_styles_preserve_ratio(stylesheets, containers, svg):
    """Check the rules that can affect the isolated raster and its containers."""
    selector_pattern = re.compile(r'(\*|[a-zA-Z][a-zA-Z0-9-]*)?((?:[.#][a-zA-Z_][a-zA-Z0-9_-]*)*)')
    length = r'(?:0|[0-9]+(?:\.[0-9]+)?(?:px|pt))'
    margins = re.compile(rf'(?:{length}|auto)(?:\s+(?:{length}|auto)){{0,3}}')
    zero = r'0(?:\.0+)?(?:px|pt)?'
    padding = re.compile(rf'{zero}(?:\s+{zero}){{0,3}}')
    elements = [(node, tag(node).lower(), set(node.get('class', '').split()), node.get('id', ''))
                for node in [*containers, *svg.iter()]]

    def allows(node, key, value):
        if node is svg:
            return ((key in {'width', 'height'} and value in {'auto', '100%'}) or
                    (key == 'display' and value in {'block', 'inline', 'inline-block'}))
        if node is not None and node not in containers:
            return False
        if re.fullmatch(r'margin(?:-top|-right|-bottom|-left)?', key):
            return margins.fullmatch(value) is not None
        if re.fullmatch(r'padding(?:-top|-right|-bottom|-left)?', key):
            return padding.fullmatch(value) is not None
        return node is not None and (key, value) in {('display', 'block'), ('text-align', 'center'), ('font-size', '1em')}

    # Quoted values in unrelated rules, such as a named typeface, cannot
    # resize the cover. Keep an opaque token so matching rules still need to
    # pass the property and value checks below.
    opaque = r"""/\*.*?\*/|"(?:\\(?:\r\n|.)|[^"\\\r\n\f])*"|'(?:\\(?:\r\n|.)|[^'\\\r\n\f])*'"""
    for sheet in stylesheets:
        css = re.sub(opaque, lambda match: ' ' if match[0].startswith('/*') else '\x01', sheet, flags=re.S)
        if any(character in css for character in "\\\"'\ufffd"):
            return False
        end = 0
        for rule in re.finditer(r'([^{}]+)\{([^{}]*)\}', css):
            if css[end:rule.start()].strip():
                return False
            end = rule.end()
            targets = set()
            for raw_selector in rule[1].split(','):
                selector = raw_selector.strip()
                if selector.lower() == '@page':
                    targets.add(None)
                    continue
                match = selector_pattern.fullmatch(selector)
                if not selector or not match:
                    return False
                name, qualifiers = match.groups()
                classes = set(re.findall(r'\.([a-zA-Z_][a-zA-Z0-9_-]*)', qualifiers))
                ids = set(re.findall(r'#([a-zA-Z_][a-zA-Z0-9_-]*)', qualifiers))
                targets.update(node for node, name_in_page, classes_in_page, identity in elements
                               if (name in {None, '*'} or name.lower() == name_in_page)
                               and classes <= classes_in_page and (not ids or ids == {identity}))
            if targets:
                for declaration in filter(None, map(str.strip, rule[2].split(';'))):
                    key, separator, value = declaration.lower().partition(':')
                    if not separator or any(not allows(node, key.strip(), value.strip()) for node in targets):
                        return False
        if css[end:].strip():
            return False
    return True


def svg_width_percent_x100(value):
    match = re.fullmatch(r'([0-9]{1,3})(?:\.([0-9]{1,2}))?%', value)
    if not match:
        return 0
    width = int(match[1]) * 100 + int((match[2] or '').ljust(2, '0'))
    return width if 0 < width <= 10000 else 0


def svg_reflowable_viewport_size(document, svg, picture, linked_stylesheets=None):
    """Recognize an isolated SVG whose parent has no independently set height."""
    width = svg_width_percent_x100(svg.get('width', '100%'))
    if (tag(document) != 'html' or document.attrib.keys() - {'lang', '{http://www.w3.org/XML/1998/namespace}lang'} or
            svg.tag != f'{{{SVG}}}svg' or picture.tag != f'{{{SVG}}}image' or len(picture) or
            svg.attrib.keys() - {'viewBox', 'width', 'height', 'version', 'preserveAspectRatio', 'id', 'class'} or
            picture.attrib.keys() - {'width', 'height', 'x', 'y', 'href', f'{{{XL}}}href', 'alt', 'id', 'class'} or
            svg.get('preserveAspectRatio', '').strip() != 'none' or
            not width or (width != 10000 and linked_stylesheets is not None) or svg.get('height') != '100%' or
            any(picture.get(axis, '0') not in {'0', '0.0'} for axis in ('x', 'y'))):
        return None
    box = re.fullmatch(r'\s*0\s+0\s+([1-9][0-9]{0,3})\s+([1-9][0-9]{0,3})\s*', svg.get('viewBox', ''))
    if not box or box.groups() != (picture.get('width'), picture.get('height')):
        return None

    def trailing_prose(block):
        # A caption in normal flow cannot size or clip the preceding SVG.
        # Its own content still goes through the ordinary text conversion.
        if tag(block) not in {'p', 'div'} or block.attrib.keys() - {'style', 'id'}:
            return False
        length = r'(?:0|[0-9]+(?:\.[0-9]+)?(?:px|pt))'
        flow = re.compile(rf'(?i)(?:float\s*:\s*none|text-align\s*:\s*(?:left|right|center|justify)|'
                          rf'margin\s*:\s*{length}(?:\s+{length}){{0,3}})')
        if any(not flow.fullmatch(rule) for rule in filter(None, map(str.strip, block.get('style', '').split(';')))):
            return False
        return all(tag(node) in {'p', 'span', 'a', 'em', 'i', 'strong', 'b', 'br'} and
                   node.attrib.keys() <= ({'href', f'{{{XL}}}href', 'id'} if tag(node) == 'a' else {'id'})
                   for node in list(block.iter())[1:])

    containers = [document]
    parent = first(document, 'body')
    while parent is not None and tag(parent) in {'body', 'div'}:
        if (not len(parent) or (parent.text or '').strip() or
                any((child.tail or '').strip() for child in parent) or parent.attrib.keys() - {'id', 'class'}):
            return None
        if len(parent) != 1 and (tag(parent) != 'body' or linked_stylesheets is not None or
                                 not all(trailing_prose(block) for block in parent[1:])):
            return None
        containers.append(parent)
        parent = parent[0]
    if parent is None or parent.tag != svg.tag or parent.attrib != svg.attrib:
        return None
    if linked_stylesheets is not None:
        return tuple(map(int, box.groups())) if svg_cover_styles_preserve_ratio(linked_stylesheets, containers, parent) else None
    head = first(document, 'head')
    if head is not None:
        for node in head:
            if tag(node) in {'title', 'meta'}:
                continue
            if tag(node) != 'style':
                return None
            css = re.sub(r'/\*.*?\*/', '', ''.join(node.itertext()), flags=re.S).strip()
            while css:
                rule = re.match(r'(?i)(?:@page|html|body|div)\s*\{([^{}]*)\}\s*', css)
                if not rule:
                    return None
                for declaration in filter(None, map(str.strip, rule[1].split(';'))):
                    if not re.fullmatch(r'(?i)(?:text-align\s*:\s*center|(?:margin|padding)\s*:\s*0(?:pt|px)?)', declaration):
                        return None
                css = css[rule.end():]
    return tuple(map(int, box.groups()))


def svg_background_picture(node):
    """Recognize a viewport-sized raster on a solid rectangular background."""
    if node.tag != f'{{{SVG}}}svg':
        return None
    children = [child for child in node if tag(child) not in {'title', 'desc'}]
    if [child.tag for child in children] != [f'{{{SVG}}}rect', f'{{{SVG}}}image']:
        return None
    if node.attrib.keys() - {'viewBox', 'width', 'height', 'version', 'class', 'id', 'style', 'transform'}:
        return None
    box = re.fullmatch(r'\s*0\s+0\s+([1-9][0-9]{0,3})\s+([1-9][0-9]{0,3})\s*', node.get('viewBox', ''))
    if not box or max(map(int, box.groups())) > 4096:
        return None
    width, height = box.groups()
    rect, picture = children
    if len(rect) or len(picture) or any(svg_changes_appearance(part) for part in (node, picture)):
        return None
    if rect.attrib.keys() - {'x', 'y', 'width', 'height', 'fill'}:
        return None
    if picture.attrib.keys() - {'x', 'y', 'width', 'height', 'href', f'{{{XL}}}href', 'transform'}:
        return None
    if not re.fullmatch(r'#[0-9a-fA-F]{6}', rect.get('fill', '')):
        return None
    for child in children:
        if any(child.get(axis, '0') not in {'0', '0.0'} for axis in ('x', 'y')):
            return None
    for axis, size in (('width', width), ('height', height)):
        if node.get(axis, '100%') not in {'100%', size} or rect.get(axis) not in {'100%', size} or picture.get(axis) != size:
            return None
    return width, height, rect.get('fill'), picture.get(f'{{{XL}}}href') or picture.get('href', '')


def svg_cropped_raster(node, picture, sizing):
    """Build a static viewport for a single local raster, preserving its clip."""
    if (node.tag != f'{{{SVG}}}svg' or picture.tag != f'{{{SVG}}}image' or len(picture) or
            any(svg_changes_appearance(part) for part in (node, picture))):
        return None
    if node.attrib.keys() - {'viewBox', 'width', 'height', 'version', 'class', 'id', 'style', 'transform', 'preserveAspectRatio'}:
        return None
    if picture.attrib.keys() - {'x', 'y', 'width', 'height', 'href', f'{{{XL}}}href', 'transform', 'class', 'id', 'alt', 'preserveAspectRatio', 'style'}:
        return None
    box = re.split(r'[\s,]+', node.get('viewBox', '').strip())
    position = r'[+-]?[0-9]{1,5}(?:\.[0-9]{1,5})?'
    extent = r'[1-9][0-9]{0,3}'
    if (len(box) != 4 or not all(re.fullmatch(position, part) for part in box[:2]) or
            not all(re.fullmatch(extent, part) and int(part) <= 4096 for part in box[2:])):
        return None
    width, height = box[2:]
    if (node.get('width', width) not in {width, '99%', '100%'} or
            node.get('height', height) not in {height, '99%', '100%'}):
        return None
    geometry = {axis: picture.get(axis, '0') for axis in ('x', 'y', 'width', 'height')}
    if (not all(re.fullmatch(position, part) for part in geometry.values()) or
            not all(0 < float(geometry[axis]) <= 8192 for axis in ('width', 'height'))):
        return None
    alignment = picture.get('preserveAspectRatio')
    if alignment:
        if not re.fullmatch(r'x(?:Min|Mid|Max)Y(?:Min|Mid|Max)(?:\s+meet)?', alignment):
            return None
        geometry['preserveAspectRatio'] = alignment
    geometry.update(sizing)
    drawing = element(SVG, 'svg', width=width, height=height, viewBox=' '.join(box))
    drawing.append(element(SVG, 'image', **geometry))
    return drawing


def fb2_image_size(marker):
    if not marker.startswith(FB2_IMAGE_SIZE_PREFIX):
        return 0, 0
    width, separator, height = marker[len(FB2_IMAGE_SIZE_PREFIX):].partition('-')
    if not separator or not re.fullmatch(r'[0-9]{1,5}-[0-9]{1,5}', width + '-' + height):
        return 0, 0
    width, height = int(width), int(height)
    return (width, height) if max(width, height) <= 32768 else (0, 0)


def fb2_relative_image_width(marker):
    value = marker.removeprefix(FB2_IMAGE_WIDTH_PREFIX)
    if value == marker or not re.fullmatch(r'[0-9]{1,4}', value) or not int(value):
        return ''
    return format(int(value) / 100, 'g') + '%'


def relative_image_css(width):
    return f'width:{width};height:auto;display:block;margin-left:auto;margin-right:auto'


def fb2_image_has_layout(marker):
    return (word_rule_height(marker) > 0 or word_line_geometry(marker) is not None or
            any(fb2_image_size(marker)) or bool(fb2_relative_image_width(marker)))


def margin_rule_class(node):
    if tag(node) != 'span' or len(node) or node.text:
        return None
    return next((name for name in node.get('class', '').split() if margin_rule_geometry(name)), None)


def layout_margin_rules(body):
    markers = [(node, marker) for node in body.iter() if (marker := margin_rule_class(node))]
    if not markers:
        return
    parents = {child: parent for parent in body.iter() for child in parent}
    hosts = set()
    for node, marker in markers:
        side, offset, band, top, height, width = margin_rule_geometry(marker)
        host = parents[node]
        while tag(host) in {'span', 'em', 'strong', 's', 'sup', 'sub', 'u', 'a', 'code'}:
            host = parents[host]
        hosts.add(host)
        # Keep the full coordinates in the class. The redistributed margins
        # keep the visible stroke clear of the reflowed text.
        lane = 9 + 14 * (1 - offset / band if side == 'left' else offset / band)
        node.set('style', f'position:absolute;{side}:-{lane:.3f}px;top:{top / 12700:.5f}pt;'
                 f'height:{height / 12700:.5f}pt;width:0;border-left:{width / 12700:.5f}pt solid currentColor')
    for host in hosts:
        style = host.get('style', '').rstrip('; ')
        host.set('style', (style + ';' if style else '') + 'position:relative')
    body.set('style', 'padding-left:32px;padding-right:32px')


def plain(node):
    return ''.join(node.itertext()).strip() if node is not None else ''


def html_heading_level(node):
    name = tag(node)
    if re.fullmatch(r'h[1-6]', name):
        return int(name[1])
    if name != 'p':
        return 0
    level = node.get('aria-level')
    if node.get('role') == 'heading' and level in {'1', '2', '3', '4', '5', '6', '7', '8', '9'}:
        return int(level)
    # Word's filtered HTML uses heading paragraphs for levels beyond h6.
    word = re.search(r'(?:^|\s)MsoHeading([1-9])(?=\s|$)', node.get('class', ''), re.I)
    if word:
        return int(word[1])
    return 0


def children(node, name):
    return [child for child in node if tag(child) == name]


def first(node, name):
    return next((n for n in node if tag(n) == name), None)


FB3_DESCRIPTION_METADATA = 'mhl:fb3-description'
FB2_DESCRIPTION_METADATA = 'mhl:fb2-description'
FB2_IMAGES_METADATA = 'mhl:fb2-images'
FB2_STYLESHEETS_METADATA = 'mhl:fb2-stylesheets'
FB2_QUOTE_SECTIONS = 'HomeLibre: EPUB quotation sections v1'
ROUNDTRIP_METADATA = {FB2_DESCRIPTION_METADATA, FB2_IMAGES_METADATA, FB2_STYLESHEETS_METADATA,
                      FB3_DESCRIPTION_METADATA}
FB3_PART_TYPES = {'application/fb3-body+xml': 'body',
                  'application/fb3-description+xml': 'description'}


def fb3_declared_parts(archive):
    try:
        item = archive.getinfo('[Content_Types].xml')
    except KeyError:
        return {}
    if item.file_size > 1024 * 1024 or item.flag_bits & 1:
        return {}
    data = archive.read(item)
    if b'application/fb3-' not in data.replace(b'\0', b'').lower():
        return {}
    content_types = xml(data)
    parts = {}
    for item in children(content_types, 'Override'):
        kind = FB3_PART_TYPES.get(item.get('ContentType', '').casefold())
        name = item.get('PartName')
        if kind and name:
            if kind in parts:
                raise ConversionError('В FB3 несколько частей с одинаковым назначением.')
            parts[kind] = name
    return parts


def fb3_title(node):
    return (plain(first(node, 'main')) or plain(node)) if node is not None else ''


def fb3_document_id(description):
    if description is not None and (value := description.get('id')):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            pass
    return ''


def fb3_people(description, role):
    relations = first(description, 'fb3-relations')
    if relations is None:
        return
    for person in children(relations, 'subject'):
        if person.get('link') == role:
            fields = {key: plain(first(person, key)) for key in ('first-name', 'middle-name', 'last-name')}
            name = fb3_title(first(person, 'title')) or ' '.join(value for value in fields.values() if value)
            if name:
                yield name, fields


def fb3_edition(description):
    # Select the same paper edition as the catalogue. Never fill a gap with
    # a value from a different paper publication listed later in the file.
    paper = first(description, 'paper-publish-info')
    document = first(description, 'document-info')
    edition = {name: paper.get(attr, '').strip() for name, attr in (
        ('book-name', 'title'), ('publisher', 'publisher'), ('city', 'city'), ('year', 'year'))} if paper is not None else {}
    isbn = next((plain(first(node, 'isbn')) for node in (paper, document)
                 if node is not None and plain(first(node, 'isbn'))), '')
    if isbn:
        edition['isbn'] = isbn
    return {name: value for name, value in edition.items() if value}


def write_epub_fb3_metadata(metadata, description):
    metadata.append(element(OP, 'meta', base64.b64encode(serialized(description)).decode('ascii'),
                            property=FB3_DESCRIPTION_METADATA))
    annotation = first(description, 'annotation')
    if annotation is not None:
        text = '\n'.join(plain(node) for node in annotation) if len(annotation) else plain(annotation)
        if text.strip():
            metadata.append(element(DC, 'description', text))
    for name, _ in fb3_people(description, 'author'):
        metadata.append(element(DC, 'creator', name))
    write_epub_translators(metadata, (name for name, _ in fb3_people(description, 'translator')))
    edition = fb3_edition(description)
    for field, target in (('publisher', 'publisher'), ('year', 'date'), ('isbn', 'identifier')):
        if not (value := edition.get(field)):
            continue
        if field == 'year' and not re.fullmatch(r'[0-9]{4}', value):
            continue
        if field == 'isbn':
            if not re.fullmatch(r'(?:[0-9]{9}[0-9Xx]|[0-9]{13})', re.sub(r'[\s-]+', '', value)):
                continue  # The original description still retains this value.
            value = 'urn:isbn:' + value
        metadata.append(element(DC, target, value))


def restore_fb3_annotation(source, resolve_link, warnings):
    values = {'p': 'p', 'br': 'empty-line', 'strong': 'strong', 'em': 'emphasis', 'a': 'a'}

    def convert(node, in_link=False):
        name = tag(node)
        if name not in values:
            warnings.add('Часть разметки аннотации FB3 передана текстом.')
            return None
        result = element(FB, values[name], node.text)
        if name == 'a':
            href = node.get('href', '').strip()
            target = resolve_link(href) if href else ''
            if not target or in_link:
                warnings.add('Не перенесён переход в аннотации FB3. Текст ссылки сохранён.')
                return None
            result.set('{' + XL + '}href', target)
        for child in node:
            output = convert(child, in_link or name == 'a')
            if output is None:
                append_text(result, ''.join(child.itertext()))
            else:
                result.append(output)
            append_text(result, child.tail)
        return result

    annotation = element(FB, 'annotation')
    if source.text and source.text.strip():
        annotation.append(element(FB, 'p', source.text))
    for node in source:
        if tag(node) in {'p', 'br'}:
            annotation.append(convert(node))
        elif plain(node):
            annotation.append(element(FB, 'p', plain(node)))
            warnings.add('Часть разметки аннотации FB3 передана текстом.')
    return annotation


def epub_custom_metadata_value(node, key):
    if node.get('property') == key:
        return plain(node)
    if node.get('name') == key:
        return node.get('content', '')
    return ''


def epub_custom_metadata(metadata, key, default=''):
    return next((value for node in children(metadata, 'meta')
                 if (value := epub_custom_metadata_value(node, key))), default)


def set_epub_custom_metadata_value(node, key, value):
    if node.get('property') == key:
        node.text = value
    else:
        node.set('content', value)


def fb3_source_description(metadata):
    value = epub_custom_metadata(metadata, FB3_DESCRIPTION_METADATA)
    if not value:
        return None
    try:
        source = xml(base64.b64decode(value, validate=True))
    except (ValueError, ConversionError) as error:
        raise ConversionError('Повреждено исходное описание FB3.') from error
    if tag(source) != 'fb3-description':
        raise ConversionError('Неверное исходное описание FB3.')
    return source


def append_fb2_person(title_info, role, name, fields):
    person = element(FB, role)
    if fields.get('first-name') and fields.get('last-name'):
        for part in ('first-name', 'middle-name', 'last-name'):
            if value := fields.get(part):
                person.append(element(FB, part, value))
    else:
        person.append(element(FB, 'nickname', name))
    title_info.append(person)


def read_epub_people(metadata):
    roles = {}
    for entry in children(metadata, 'meta'):
        target = entry.get('refines', '')
        if entry.get('property') == 'role' and target.startswith('#'):
            roles.setdefault(target[1:], set()).add(plain(entry).casefold())
    authors, translators = [], []
    for person in metadata:
        kind = tag(person)
        if kind not in ('creator', 'contributor') or not (name := plain(person)):
            continue
        person_roles = roles.get(person.get('id'), set())
        if role := person.get('{' + OP + '}role', person.get('role', '')).strip().casefold():
            person_roles = person_roles | {role}
        if 'aut' in person_roles or kind == 'creator' and not person_roles:
            authors.append(name)
        if 'trl' in person_roles:
            translators.append(name)
    return authors, translators


def write_epub_translators(metadata, names):
    for index, name in enumerate(filter(None, names), 1):
        identity = f'translator-{index}'
        metadata.append(element(DC, 'contributor', name, id=identity))
        metadata.append(element(OP, 'meta', 'trl', property='role', refines='#' + identity, scheme='marc:relators'))


def standard_epub_series(metadata):
    refinements = {}
    for entry in children(metadata, 'meta'):
        reference = entry.get('refines', '')
        if reference.startswith('#') and entry.get('property') in {'collection-type', 'group-position'}:
            refinements.setdefault(reference, {})[entry.get('property')] = plain(entry)
    for entry in children(metadata, 'meta'):
        if entry.get('property') != 'belongs-to-collection' or not plain(entry):
            continue
        fields = refinements.get('#' + entry.get('id', ''), {})
        if fields.get('collection-type') == 'series':
            yield entry, fields.get('group-position', '')


# EPUB collections can have composite positions such as 2.4. FB2 sequence numbers are integers.
def append_epub_series_to_fb2(metadata, title_info, warnings):
    series = [(plain(entry), number, bool(entry.get('refines')))
              for entry, number in standard_epub_series(metadata)]
    if not series and (name := epub_custom_metadata(metadata, 'calibre:series').strip()):
        number = epub_custom_metadata(metadata, 'calibre:series_index').strip()
        series.append((name, re.sub(r'(?<=\d)\.0+$', '', number), False))
    for name, number, nested in series:
        sequence = element(FB, 'sequence', name=name)
        if re.fullmatch(r'[+-]?[0-9]+', number):
            sequence.set('number', number)
        if nested or number and 'number' not in sequence.attrib:
            warnings.add('В FB2 перенесено название серии. Составной номер или вложенность сохранены в исходных сведениях EPUB.')
        title_info.append(sequence)


def write_epub_publication_metadata(metadata, description, title_info):
    write_epub_translators(metadata, (' '.join(plain(n) for n in person
                                             if tag(n) in {'first-name', 'middle-name', 'last-name', 'nickname'}).strip()
                                      for person in children(title_info, 'translator')))
    annotation = first(title_info, 'annotation')
    if annotation is not None:
        text = '\n'.join(value for paragraph in annotation if (value := plain(paragraph))) or plain(annotation)
        if text:
            metadata.append(element(DC, 'description', text))
    for genre in children(title_info, 'genre'):
        if value := plain(genre):
            metadata.append(element(DC, 'subject', value))
    for index, sequence in enumerate(children(title_info, 'sequence'), 1):
        if not (name := sequence.get('name', '').strip()):
            continue
        reference = f'series-{index}'
        metadata.append(element(OP, 'meta', name, property='belongs-to-collection', id=reference))
        metadata.append(element(OP, 'meta', 'series', refines='#' + reference, property='collection-type'))
        number = sequence.get('number', '').strip().lstrip('+')
        if re.fullmatch(r'[0-9]{1,10}', number) and int(number) <= 4294967295:
            metadata.append(element(OP, 'meta', number, refines='#' + reference, property='group-position'))
    publication = first(description, 'publish-info')
    if publication is None:
        return
    for source_name, target_name in (('publisher', 'publisher'), ('year', 'date')):
        if value := plain(first(publication, source_name)):
            if target_name != 'date' or re.fullmatch(r'[0-9]{4}', value):
                metadata.append(element(DC, target_name, value))
    isbn = plain(first(publication, 'isbn'))
    if re.fullmatch(r'(?:[0-9]{9}[0-9Xx]|[0-9]{13})', re.sub(r'[\s-]+', '', isbn)):
        metadata.append(element(DC, 'identifier', 'urn:isbn:' + isbn))


def epub_isbn_identifiers(metadata):
    isbn_ids = {meta.get('refines', '').removeprefix('#') for meta in children(metadata, 'meta')
                if meta.get('property') == 'identifier-type' and meta.get('scheme') == 'onix:codelist5' and
                plain(meta) in {'02', '15'}}
    for identity in children(metadata, 'identifier'):
        value = plain(identity)
        scheme = identity.get('{' + OP + '}scheme', identity.get('scheme', '')).casefold()
        if value.casefold().startswith('urn:isbn:'):
            value = value[9:]
        elif scheme != 'isbn' and identity.get('id') not in isbn_ids:
            continue
        if value:
            yield value


def read_epub_publication_metadata(metadata, description, edition=None):
    """Populate fields that FB2 readers can use; retain the full EPUB metadata too."""
    publisher = next((plain(n) for n in children(metadata, 'publisher') if plain(n)), '')
    year = ''
    for date in children(metadata, 'date'):
        event = date.get('{' + OP + '}event', date.get('event', '')).casefold()
        if event and event != 'publication':
            continue
        if match := re.fullmatch(r'([0-9]{4})(?:-[0-9]{2}(?:-[0-9]{2}(?:T.+)?)?)?', plain(date)):
            year = match[1]
            break
    isbn = next(epub_isbn_identifiers(metadata), '')
    edition = dict(edition or ())
    for name, value in (('publisher', publisher), ('year', year), ('isbn', isbn)):
        if value:
            edition[name] = value
    if 'year' in edition and not re.fullmatch(r'[0-9]{4}', edition['year']):
        del edition['year']
    if edition:
        publication = element(FB, 'publish-info')
        for name in ('book-name', 'publisher', 'city', 'year', 'isbn'):
            if value := edition.get(name):
                publication.append(element(FB, name, value))
        description.append(publication)


def append_navigation_list(toc, entries, *, start_only=False):
    root = element(XH, 'ol')
    toc.append(root)
    ancestors = []
    for href, label, depth in entries:
        while ancestors and ancestors[-1][0] >= depth:
            ancestors.pop()
        listing = root
        if ancestors:
            parent = ancestors[-1][1]
            listing = first(parent, 'ol')
            if listing is None:
                listing = element(XH, 'ol')
                parent.append(listing)
        item = element(XH, 'li')
        link = element(XH, 'a', label, href=href)
        if start_only:
            link.set(EPUB_START_ONLY, '1')
        item.append(link)
        listing.append(item)
        ancestors.append((depth, item))


def restore_epub_outline(description, anchors):
    marker = next((item for item in children(description, 'custom-info')
                   if item.get('info-type') == FB2_EPUB_OUTLINE), None)
    if marker is None or not marker.text or len(marker.text) > MAX_OUTLINE_METADATA:
        return []
    rows = marker.text.splitlines()
    if not 0 < len(rows) <= MAX_ENTRIES:
        return []
    result = []
    for row in rows:
        cells = row.split('\t', 2)
        if len(cells) != 3:
            return []
        identity, level, label = cells
        if identity not in anchors or not re.fullmatch(r'[1-9]|1[0-6]', level) or not 0 < len(label.strip()) <= 4096:
            return []
        result.append((anchors[identity] + '#' + quote(identity, safe=''), label, int(level)))
    return result


def fb2_section_has_cover(section, cover):
    reference = '{' + XL + '}href'
    cover_images = {picture.get(reference) for picture in cover if tag(picture) == 'image'}
    body_images = {picture.get(reference) for picture in section.iter('{' + FB + '}image')}
    return bool(cover_images) and None not in cover_images and cover_images <= body_images


def fb2_cover_already_in_body(description, bodies, cover):
    if cover is None:
        return False
    key = next((plain(item) for item in children(description, 'custom-info')
                if item.get('info-type') == FB2_EPUB_COVER_IN_BODY), '')
    if not re.fullmatch(r'id_[0-9a-f]{24}', key):
        return False
    return any(section.get('id') == key and fb2_section_has_cover(section, cover)
               for body in bodies for section in children(body, 'section'))


def append_text(node, text):
    if not text:
        return
    if len(node):
        node[-1].tail = (node[-1].tail or '') + text
    else:
        node.text = (node.text or '') + text


def split_nested_fb2_links(link, reference, warnings):
    """Keep link labels and inline formatting without nesting FB2 hyperlinks."""
    link_tag = '{' + FB + '}a'
    nested = [child for child in link.iter(link_tag) if child is not link]
    if not nested:
        return [link]

    def copy_content(node):
        clone = copy.copy(node)
        clone.tail = None
        return clone

    def fill(node, fragments):
        for fragment in fragments:
            if isinstance(fragment, str):
                append_text(node, fragment)
            else:
                node.append(fragment)

    def parts(node):
        if node.text:
            yield False, node.text
        for child in node:
            if child.tag == link_tag:
                yield True, copy_content(child)
            elif next(child.iter(link_tag), None) is not None:
                for index, (escaped, group) in enumerate(groupby(parts(child), key=lambda part: part[0])):
                    attributes = dict(child.attrib)
                    if index:
                        attributes.pop('id', None)
                    wrapper = ET.Element(child.tag, attributes)
                    fill(wrapper, (fragment for _, fragment in group))
                    yield escaped, wrapper
            else:
                yield False, copy_content(child)
            if child.tail:
                yield False, child.tail

    attributes = dict(link.attrib)
    anchor = attributes.pop('id', None)
    result = []
    has_own_label = False
    for escaped, group in groupby(parts(link), key=lambda part: part[0]):
        if escaped:
            result.extend(fragment for _, fragment in group)
            continue
        segment = ET.Element(link_tag, attributes)
        fill(segment, (fragment for _, fragment in group))
        if ''.join(segment.itertext()).strip() or next(segment.iter('{' + FB + '}image'), None) is not None:
            has_own_label = True
        else:
            segment.tag = '{' + FB + '}style'
            segment.attrib.clear()
            segment.set('name', 'epub-inline')
        result.append(segment)
    if anchor:
        wrapper = element(FB, 'style', name='epub-inline', id=anchor)
        wrapper.append(result[0])
        result[0] = wrapper
    href = '{' + XL + '}href'
    if not has_own_label and any(child.get(href) != link.get(href) for child in nested):
        warnings.add(f'Не перенесена вложенная ссылка EPUB «{reference[:160]}». '
                     'У неё нет отдельной подписи. Переход по ссылке внутри неё сохранён.')
    return result


def normalize_fb2(book, preserved_bodies=(), warnings=None, record_quotation=None):
    """Split flow at line breaks; FB2 sections cannot mix children and prose."""
    inline = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
    paragraphs = {'p', 'subtitle', 'v', 'text-author'}
    def split_paragraph(node):
        result, current, chain = [], element(FB, tag(node), **node.attrib), []
        def append(value):
            parent = current
            for wrapper in chain:
                if len(parent) and parent[-1].tag == wrapper.tag and parent[-1].attrib == wrapper.attrib and not parent[-1].tail:
                    parent = parent[-1]
                else:
                    clone = element(FB, tag(wrapper), **wrapper.attrib); parent.append(clone); parent = clone
            if isinstance(value, str): append_text(parent, value)
            else:
                clone = copy.deepcopy(value); clone.tail = None; parent.append(clone)
        def flush():
            nonlocal current
            had_content = bool(plain(current) or len(current) or current.get('id'))
            if had_content: result.append(current)
            current = element(FB, tag(node), **{k:v for k,v in node.attrib.items() if k != 'id'})
            return had_content
        def walk(parent):
            append(parent.text or '')
            for child in parent:
                if tag(child) == 'empty-line':
                    if not flush(): result.append(element(FB, 'empty-line'))
                    # FB2 empty-line has no anchor attribute. Put the source
                    # break's target on the following paragraph instead.
                    if child.get('id'): current.set('id', child.get('id'))
                elif tag(child) not in inline:
                    flush(); clone = copy.deepcopy(child); clone.tail = None; result.append(clone)
                elif tag(child) == 'image' or (tag(child) == 'style' and not len(child) and not child.text
                        and (margin_rule_geometry(child.get('name', '')) or word_spacer_dimensions(child.get('name', '')))):
                    append(child)
                else:
                    chain.append(child); walk(child); chain.pop()
                append(child.tail or '')
        walk(node); flush()
        return result or [element(FB, tag(node), **node.attrib)]

    def grouped_section(blocks):
        section = element(FB, 'section')
        section.extend(blocks)
        if len(blocks) == 1 and tag(blocks[0]) == 'title':
            section.append(element(FB, 'empty-line'))
        return section

    def fix(node):
        updated = []
        for child in list(node):
            fix(child)
            if tag(child) in paragraphs:
                parts = split_paragraph(child)
                # The text after a nested paragraph belongs to the enclosing
                # flow, including a heading split by publisher line breaks.
                parts[-1].tail = child.tail
                updated.extend(parts)
            elif tag(child) == 'title' and tag(node) in {'body', 'section'}:
                first_block = next((i for i, part in enumerate(child)
                                    if tag(part) not in {'p', 'empty-line'}), len(child))
                overflow = list(child[first_block:])
                del child[first_block:]
                if len(child) or not overflow: updated.append(child)
                updated.extend(overflow)
                if overflow and warnings is not None:
                    warnings.add('Блоки внутри заголовка вынесены в текст раздела FB2 с сохранением порядка.')
            else:
                updated.append(child)
        node[:] = updated
        # Splitting paragraphs may expose blocks that a citation cannot contain.
        # Use a section so the nested citations, anchors and block order survive.
        if tag(node) == 'cite' and any(tag(child) not in {'p', 'poem', 'empty-line', 'subtitle', 'table', 'text-author'}
                                       for child in node):
            node.tag = '{' + FB + '}section'
            if record_quotation is not None:
                record_quotation(node)
            if warnings is not None:
                presentation = ('Другие читалки могут показывать внешнюю цитату как раздел.'
                                if record_quotation is not None else 'Отступы могут отличаться.')
                warnings.add('Сложная цитата EPUB представлена разделом FB2. '
                             'Текст, внутренние цитаты и ссылки сохранены. ' + presentation)
        if tag(node) in {'body', 'section'}:
            content = []
            if node.text and node.text.strip(): content.append(element(FB, 'p', node.text))
            # Mixed text can occur in HTML block containers. FB2 sections must
            # carry it in paragraphs, including text between two blocks.
            run = None
            for child in node:
                tail = child.tail; child.tail = tail if tail and not tail.strip() else None
                if tag(child) in inline - {'image'}:
                    if run is None: run = element(FB, 'p'); content.append(run)
                    run.append(child); append_text(run, tail)
                else:
                    run = None; content.append(child)
                    if tail and tail.strip(): content.append(element(FB, 'p', tail))
            node.text = None
            prefix = []
            is_body = tag(node) == 'body'
            allowed = {'image', 'title', 'epigraph'} if is_body else {'title', 'epigraph', 'image', 'annotation'}
            while content and tag(content[0]) in allowed:
                if tag(content[0]) == 'title' and prefix and not (
                        is_body and len(prefix) == 1 and tag(prefix[0]) == 'image'):
                    break
                prefix.append(content.pop(0))
            if is_body or any(tag(n) in {'section', 'title'} for n in content):
                groups, run = [], []
                for child in content:
                    if run and tag(child) in {'section', 'title'}:
                        groups.append(grouped_section(run)); run = []
                    if tag(child) == 'section':
                        groups.append(child)
                    else: run.append(child)
                if run: groups.append(grouped_section(run))
                node[:] = prefix + groups
            else: node[:] = prefix + content
            if not any(tag(n) in {'section', 'p', 'subtitle', 'poem', 'cite', 'table', 'empty-line'} for n in node):
                node.append(element(FB, 'section') if tag(node) == 'body' else element(FB, 'empty-line'))
        if tag(node) == 'epigraph':
            def flatten(section):
                for item in section:
                    if tag(item) == 'section': yield from flatten(item)
                    elif tag(item) == 'title':
                        for p in item:
                            p.tag = '{' + FB + '}p'; yield p
                    else: yield item
            node[:] = [part for child in node for part in (list(flatten(child)) if tag(child) == 'section' else [child])]
    for body in children(book, 'body'):
        if body not in preserved_bodies: fix(body)
    # FB2 has block anchors, but no id attribute on links, named styles or
    # inline images. Keep such source/EPUB anchors at the enclosing paragraph
    # (or section) and redirect links there without splitting styled prose.
    aliases = {}
    inline_names = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code'}
    def anchors(node, block=None, inline=False):
        name = tag(node)
        if name == 'section' or name in paragraphs: block = node
        if node.get('id') and (name in inline_names or name == 'image' and inline):
            old = node.attrib.pop('id')
            if block is None: raise ConversionError('Не удалось сохранить метку внутри абзаца FB2: ' + old)
            if not block.get('id'): block.set('id', old)
            aliases[old] = block.get('id')
        for child in node:
            anchors(child, block, inline or name in paragraphs or name in inline_names or name in {'td', 'th'})
    for body in children(book, 'body'): anchors(body)
    if aliases:
        for link in book.iter('{' + FB + '}a'):
            href = link.get('{' + XL + '}href', '')
            if href.startswith('#') and href[1:] in aliases:
                link.set('{' + XL + '}href', '#' + aliases[href[1:]])
        if warnings is not None:
            warnings.add('FB2 не поддерживает метки перехода внутри текста абзаца. Такие переходы ведут к содержащему их абзацу; текст и его оформление сохранены.')
    return aliases


def fb2_output_issues(book, *, check_targets=True):
    """Describe structural defects without modifying the document."""
    inline = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
    prose = {'p', 'poem', 'subtitle', 'cite', 'empty-line', 'table', 'image'}
    rules = {'body': {'title', 'epigraph', 'image', 'section'},
             'section': prose | {'title', 'epigraph', 'annotation', 'section'},
             'title': {'p', 'empty-line'}, 'table': {'tr'}, 'tr': {'td', 'th'},
             'cite': {'p', 'poem', 'empty-line', 'subtitle', 'table', 'text-author'},
             'epigraph': {'p', 'poem', 'cite', 'empty-line', 'text-author'},
             'annotation': {'p', 'poem', 'cite', 'subtitle', 'table', 'empty-line'},
             'poem': {'title', 'epigraph', 'subtitle', 'stanza', 'text-author', 'date'},
             'stanza': {'title', 'subtitle', 'v'}}
    for name in {'p', 'subtitle', 'v', 'text-author', 'td', 'th'} | (inline - {'image'}): rules[name] = inline
    identities = set()
    for node in book.iter():
        value = node.get('id')
        if value:
            if value in identities:
                yield ('duplicate-id', value), 'В результате повторяется идентификатор FB2: ' + value
            identities.add(value)
    link_tag = '{' + FB + '}a'
    link_styles, nested_links = set(), set()
    for link in book.iter(link_tag):
        link_styles.update(link.iter('{' + FB + '}style'))
        nested_links.update(child for child in link.iter(link_tag) if child is not link)
    for body in children(book, 'body'):
        parents = {child: parent for parent in body.iter() for child in parent}
        for node in body.iter():
            name = tag(node)
            if node.get('id') and (name in inline - {'image'} or name == 'image' and
                    tag(parents[node]) in inline | {'p', 'subtitle', 'v', 'text-author', 'td', 'th'}):
                yield ('inline-id', name, node.get('id')), 'В результате FB2 недопустимая метка внутри абзаца: ' + node.get('id')
            if node.tag != '{' + FB + '}' + name or name not in rules and name not in {'image', 'empty-line', 'date'}:
                yield ('element', node.tag), 'Нельзя сохранить элемент в FB2: ' + name
            allowed = rules.get(name, set())
            for index, child in enumerate(node):
                if tag(child) not in allowed:
                    yield ('child', name, child.tag), 'Недопустимый вложенный элемент FB2: ' + tag(child) + ' внутри ' + name
                if tag(child) == 'title' and name in {'body', 'section'} and index and not (
                        name == 'body' and index == 1 and tag(node[0]) == 'image'):
                    yield ('misplaced-title', name), 'В результате FB2 заголовок расположен после основного текста раздела.'
            if name in {'table', 'tr'} and not len(node):
                yield ('empty-table-structure', name), 'В результате FB2 обнаружена пустая таблица или строка.'
            if name not in inline | {'p', 'subtitle', 'v', 'text-author', 'td', 'th', 'date'}:
                if node.text and node.text.strip() or any(child.tail and child.tail.strip() for child in node):
                    yield ('flow-text', name), 'В результате FB2 остался текст вне абзаца: ' + name
            if name == 'section':
                parts = list(node)
                while parts and tag(parts[0]) in {'title', 'epigraph', 'image', 'annotation'}: parts.pop(0)
                if any(tag(n) == 'section' for n in parts) and any(tag(n) != 'section' for n in parts):
                    yield ('mixed-section',), 'В результате FB2 смешаны главы и абзацы.'
            if name == 'style' and node not in link_styles and not node.get('name'):
                yield ('unnamed-style',), 'В результате FB2 у стиля отсутствует имя.'
            if node in nested_links:
                yield ('nested-link',), 'В результате FB2 одна ссылка вложена в другую.'
            if check_targets and name in {'a', 'image'}:
                href = node.get('{' + XL + '}href', '')
                if href.startswith('#') and href[1:] not in identities:
                    yield ('missing-target', name, href), 'В результате FB2 отсутствует цель ссылки: ' + href


def validate_fb2_output(book, inherited_issues=None, *, check_targets=True):
    """Generated books must be valid. An FB2 image-only edit may retain source
    defects, but cannot introduce extra occurrences or other kinds of defect.
    The complete XSD is additionally exercised by the regression suite.
    """
    remaining = Counter(inherited_issues or {})
    for key, message in fb2_output_issues(book, check_targets=check_targets):
        if remaining[key]: remaining[key] -= 1
        else: raise ConversionError(message)


def validate_streamed_fb2(path, check=None, progress=None):
    identities, references = set(), set()
    section_count = 0
    body_position, previous_part = 0, ''
    href_name = '{' + XL + '}href'

    def collect(root):
        for node in root.iter():
            if identity := node.get('id'):
                if identity in identities:
                    raise ConversionError('В результате повторяется идентификатор FB2: ' + identity)
                identities.add(identity)
            if node.tag in {'{' + FB + '}a', '{' + FB + '}image'}:
                href = node.get(href_name, '')
                if href.startswith('#'):
                    references.add(href[1:])

    def check_part(body, node):
        nonlocal section_count, body_position, previous_part
        if check is not None:
            check()
        if node is None:
            if (body.text or '').strip():
                raise ConversionError('В результате FB2 остался текст вне раздела книги.')
            body_position, previous_part = 0, ''
            return
        if (node.tail or '').strip():
            raise ConversionError('В результате FB2 остался текст вне раздела книги.')
        if node.tag == '{' + FB + '}title' and body_position and not (
                body_position == 1 and previous_part == '{' + FB + '}image'):
            raise ConversionError('В результате FB2 заголовок расположен после основного текста раздела.')
        wrapper = element(FB, 'FictionBook')
        part_body = element(FB, 'body')
        part_body.append(node)
        wrapper.append(part_body)
        validate_fb2_output(wrapper, check_targets=False)
        collect(node)
        body_position += 1
        previous_part = node.tag
        if node.tag == '{' + FB + '}section':
            section_count += 1
            if progress is not None:
                progress('checking-fb2-sections', section_count, 0)

    book = parse_fb2_file(path, MAX_LARGE_FB2_OUTPUT, keep_binary_data=False,
                         maximum_nodes=10_000_000, part_completed=check_part)
    if book.tag != '{' + FB + '}FictionBook' or not section_count:
        raise ConversionError('В результате FB2 нет разделов книги.')
    collect(book)
    if missing := references - identities:
        raise ConversionError('В результате FB2 отсутствует цель ссылки: #' + min(missing))


class EpubOutsideResource(ConversionError):
    pass


class EpubArchive:
    def __init__(self, path, maximum_total=None, *, allow_large_jpeg=False):
        maximum_total = MAX_TOTAL if maximum_total is None else maximum_total
        self.archive = zipfile.ZipFile(path)
        entries = self.archive.infolist()
        if len(entries) > MAX_ENTRIES or sum(e.file_size for e in entries) > maximum_total:
            self.archive.close()
            raise ConversionError('EPUB слишком велик для конвертации.')
        self.names = {e.filename for e in entries}
        self.fragment_aliases = {}
        if len(self.names) != len(entries):
            self.archive.close()
            raise ConversionError('В EPUB повторяются имена файлов.')
        for entry in entries:
            member_limit = (MAX_TOTAL - 1024 * 1024
                            if allow_large_jpeg and entry.filename == 'OEBPS/' + LARGE_JPEG_EPUB_RESOURCE else MAX_FILE)
            if entry.file_size > member_limit or '\\' in entry.filename or entry.filename.startswith('/') or '..' in entry.filename.split('/'):
                self.archive.close()
                raise ConversionError('Некорректный путь или слишком большой файл EPUB.')

    def read(self, name):
        if name not in self.names:
            raise ConversionError('В EPUB отсутствует файл: ' + name)
        try:
            return self.archive.read(name)
        except RuntimeError as error:
            raise ConversionError('Зашифрованный файл EPUB не поддерживается: ' + name) from error

    def resolve(self, current, reference):
        parts = urlsplit(reference)
        if parts.scheme or parts.netloc:
            return None, parts.fragment
        path = posixpath.normpath(posixpath.join(posixpath.dirname(current), unquote(parts.path))) if parts.path else current
        if path == '..' or path.startswith('../') or path.startswith('/') or '\\' in path:
            raise EpubOutsideResource('Ссылка EPUB выходит за пределы книги.')
        fragment = unquote(parts.fragment)
        if fragment and not parts.query:
            path, fragment = self.fragment_aliases.get((path, fragment), (path, fragment))
        return path, fragment

    def close(self):
        self.archive.close()


def epub_outline_headings(archive, items, paths, spine, documents, duplicate_anchors, warnings):
    """Recognize existing title paragraphs from declared EPUB navigation only.

    Do not guess headings from prose or change the source tag: paragraph CSS
    and all original anchors still apply. A whole-document TOC label can also
    name a section whose source starts directly with prose.
    """
    def read_navigation(identity, is_nav):
        path = paths.get(identity)
        if not path: return []
        parse = xhtml if is_nav else xml
        root = parse(archive.read(path), namespace_warnings=warnings)
        entries = []
        def add(reference, label, depth):
            if not reference or not label or len(label) > 4096: return
            if len(entries) >= MAX_ENTRIES:
                raise ConversionError('Слишком много пунктов оглавления EPUB.')
            target, fragment = archive.resolve(path, reference)
            if target in documents: entries.append((target, fragment, label, min(depth, 16)))
        def nav_list(node, depth):
            for item in children(node, 'li'):
                link = first(item, 'a')
                if link is not None: add(link.get('href'), plain(link), depth)
                nested = first(item, 'ol')
                if nested is not None: nav_list(nested, depth + 1)
        def ncx_list(node, depth):
            for point in children(node, 'navPoint'):
                label, content = first(point, 'navLabel'), first(point, 'content')
                if content is not None: add(content.get('src'), plain(label), depth)
                ncx_list(point, depth + 1)
        if is_nav:
            toc = next((n for n in root.iter() if tag(n) == 'nav' and
                        ('toc' in n.get('{' + EP + '}type', '').split() or n.get('role') == 'doc-toc')), None)
            listing = first(toc, 'ol') if toc is not None else None
            if listing is not None:
                if len(listing) == 1 and tag(listing[0]) == 'li' and len(listing[0]) == 1:
                    link = first(listing[0], 'a')
                    if link is not None and link.get(EPUB_START_ONLY) == '1' and not urlsplit(link.get('href', '')).fragment:
                        return []
                nav_list(listing, 1)
        else:
            listing = first(root, 'navMap')
            if listing is not None: ncx_list(listing, 1)
        return entries

    candidates = [(key, True) for key, item in items.items() if 'nav' in item.get('properties', '').split()]
    ncx = spine.get('toc')
    if ncx in items and items[ncx].get('media-type') == 'application/x-dtbncx+xml':
        candidates.append((ncx, False))
    entries = []
    for identity, is_nav in candidates:
        try:
            entries = read_navigation(identity, is_nav)
        except (ConversionError, ValueError):
            warnings.add('Оглавление EPUB повреждено или недоступно. Текст книги и заголовки из текста сохранены.')
        if entries: break
    if not entries: return {}, {}, []

    containers = {'body', 'div', 'section', 'article', 'header'}
    inlines = {'a', 'span', 'b', 'strong', 'i', 'em', 'small', 'sup', 'sub'}
    headings, section_titles, indexes = {}, {}, {}
    def title_paragraph(node):
        if tag(node) == 'p' or re.fullmatch('h[1-6]', tag(node)): return node
        if tag(node) not in containers or (node.text or '').strip(): return None
        for child in node:
            found = title_paragraph(child)
            if found is not None and plain(found): return found
            # Only empty spacing/anchor blocks may precede the actual title.
            if plain(child) or any(tag(n) in {'img', 'svg', 'table', 'audio', 'video'} for n in child.iter()): return None
            if (child.tail or '').strip(): return None
        return None
    def block_target(node, body, parents):
        while node is not body and tag(node) in inlines:
            node = parents[node]
        return node

    for index, (path, fragment, label, depth) in enumerate(entries):
        duplicates = duplicate_anchors.get((path, fragment))
        if duplicates:
            entries[index] = (path, None, label, depth)
        body = documents[path]
        if any(n.get('data-fb2') == 'body' for n in body): continue
        if path not in indexes:
            indexes[path] = ({n.get('id'): n for n in body.iter() if n.get('id')},
                             {child: parent for parent in body.iter() for child in parent})
        anchors, parents = indexes[path]
        if fragment and fragment not in anchors and '\xa0' in fragment:
            alternative = fragment.replace('\xa0', ' ')
            if alternative in anchors and (path, alternative) not in duplicate_anchors:
                fragment = alternative
                entries[index] = (path, fragment, label, depth)
        normalized_label = ' '.join(label.split())
        if duplicates:
            # Broken IDs often mark a heading and an empty page break. The
            # publisher's label can confirm which anchor to keep in the TOC.
            matches = [key for key in (fragment, *duplicates)
                       if ' '.join(plain(title_paragraph(block_target(anchors[key], body, parents))).split())
                       == normalized_label]
            if len(matches) != 1:
                continue
            fragment, = matches
            entries[index] = (path, fragment, label, depth)
        target = anchors.get(fragment) if fragment else body
        if target is None: continue
        target = block_target(target, body, parents)
        candidate = title_paragraph(target)
        # A publisher may name an introduction or afterword only in the TOC.
        # At a whole-document boundary this label is a real section title,
        # not a reason to mislabel the first prose paragraph as a heading.
        if target is body and (candidate is None or
                tag(candidate) == 'p' and ' '.join(plain(candidate).split()) != normalized_label):
            # An opening illustration can precede the chapter's actual heading.
            # Keep the author's heading in place instead of adding a second copy.
            first_heading = next((n for n in body.iter() if html_heading_level(n) and plain(n)), None)
            if first_heading is None or ' '.join(plain(first_heading).split()) != normalized_label:
                section_titles.setdefault(path, label)
            continue
        if candidate is None or tag(candidate) != 'p': continue
        if ' '.join(plain(candidate).split()) != normalized_label: continue
        if any(tag(n) in {'img', 'svg', 'table'} for n in candidate.iter()): continue
        headings.setdefault(candidate, min(depth, 6))
    return headings, section_titles, entries


def fb2_image_type(data, declared):
    # Real-world FB2 files use aliases and sometimes a wrong MIME declaration.
    # Keep the original image bytes; EPUB requires canonical media types.
    mime = declared.split(';', 1)[0].strip().lower()
    mime = {'image/jpg': 'image/jpeg', 'image/pjpeg': 'image/jpeg',
            'image/x-png': 'image/png'}.get(mime, mime)
    if data.startswith(b'\xff\xd8\xff'):
        mime = 'image/jpeg'
    elif data.startswith(b'\x89PNG\r\n\x1a\n'):
        mime = 'image/png'
    elif data.startswith((b'GIF87a', b'GIF89a')):
        mime = 'image/gif'
    elif data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        mime = 'image/webp'
    extension = {'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif',
                 'image/svg+xml': '.svg', 'image/webp': '.webp'}.get(mime)
    if extension is None:
        raise ConversionError('Изображение FB2 имеет неподдерживаемый тип: ' + declared)
    return mime, extension


def validate_epub_inline_svg(data):
    """Check that the original drawing stays self-contained when moved to FB2."""
    declarations = data.replace(b'\x00', b'')
    if re.search(br'<!\s*DOCTYPE\b|<\?(?!xml\s)', declarations, re.I):
        raise UnreadableImage('Встроенный SVG использует DTD или внешнее оформление.')
    try:
        root = xml(data)
    except ConversionError as error:
        raise UnreadableImage('Не удалось прочитать встроенный SVG.') from error
    if root.tag not in ('{' + SVG + '}svg', 'svg'):
        raise UnreadableImage('Встроенный ресурс не содержит рисунок SVG.')
    fragment = re.compile(r'''#[^\s"'()\\]+\Z''')
    nested_image = re.compile(r'data:image/(?:png|jpeg|gif|webp);base64,', re.I)
    blocked = {'script', 'foreignobject', 'iframe', 'object', 'embed', 'animate',
               'animatecolor', 'animatemotion', 'animatetransform', 'set', 'discard'}
    links = re.compile(r'''url\s*\(\s*(?:"([^"]*)"|'([^']*)'|([^'"()\s]+))\s*\)''', re.I)
    error_message = 'Встроенный SVG использует активное содержимое или внешний ресурс.'

    def check_css(value):
        value = re.sub(r'/\*.*?\*/', '', value, flags=re.S)
        if ('\\' in value or re.search(r'@\s*import\b', value, re.I) or
                re.search(r'url\s*\(', links.sub('', value), re.I)):
            raise UnreadableImage(error_message)
        for match in links.finditer(value):
            if not fragment.fullmatch(next(part for part in match.groups() if part is not None)):
                raise UnreadableImage(error_message)

    for index, node in enumerate(root.iter(), 1):
        if index > 50000:
            raise UnreadableImage('Встроенный SVG слишком сложен.')
        kind = tag(node).lower()
        if kind in blocked:
            raise UnreadableImage(error_message)
        if kind == 'style':
            check_css(node.text or '')
        for name, value in node.attrib.items():
            attribute = name.rsplit('}', 1)[-1].lower()
            if attribute.startswith('on') or attribute == 'base':
                raise UnreadableImage(error_message)
            if attribute in {'href', 'src'} and not fragment.fullmatch(value):
                if kind not in {'image', 'feimage'} or not nested_image.match(value):
                    raise UnreadableImage(error_message)
            elif attribute not in {'href', 'src'} and (attribute == 'style' or re.search(r'url|\\|@', value, re.I)):
                check_css(value)


def decode_epub_inline_image(reference):
    """Read an embedded illustration from a data URL within the reader's limit."""
    limit = 16 * 1024 * 1024
    if len(reference) > MAX_FILE:
        raise UnreadableImage('Встроенное изображение EPUB превышает 16 МБ.')
    header, separator, payload = reference.partition(',')
    mime, *parameters = header[5:].lower().split(';')
    if not separator or not re.fullmatch(r'image/[a-z0-9][a-z0-9.+_-]{0,63}', mime):
        raise UnreadableImage('Неверный адрес встроенного изображения EPUB.')
    data = unquote_to_bytes(payload)
    if parameters and parameters[-1] == 'base64':
        try:
            data = base64.b64decode(data.translate(None, b' \t\r\n\f'), validate=True)
        except ValueError as error:
            raise UnreadableImage('Повреждены данные встроенного изображения EPUB.') from error
    if len(data) > limit:
        raise UnreadableImage('Встроенное изображение EPUB превышает 16 МБ.')
    try:
        media, _ = fb2_image_type(data, '')
    except ConversionError as error:
        if mime == 'image/svg+xml':
            validate_epub_inline_svg(data)
            media = mime
        elif data.startswith((b'II*\0', b'MM\0*')) and len(data) >= 8:
            media = 'image/tiff'
        elif data.startswith(b'BM') and len(data) >= 26:
            media = 'image/bmp'
        else:
            raise UnreadableImage('Не удалось определить формат встроенного изображения EPUB.') from error
    return media, data


def fb2_to_epub(source, output, warnings, maximum=MAX_FILE, progress=None, check=None):
    source = Path(source)
    large = source.stat().st_size > MAX_FILE
    legacy_declaration = False
    if large:
        with source.open('rb') as stream:
            legacy_declaration = FB2_WINDOWS1251_DECLARATION.match(stream.read(512)) is not None
    # Keep the existing repair for books that incorrectly declare Windows-1251.
    if large and not legacy_declaration:
        with tempfile.TemporaryDirectory(prefix='homelibre-fb2-resources-', dir=Path(output).parent) as folder:
            root = Path(folder)
            if shutil.disk_usage(root).free < 2 * source.stat().st_size + MAX_FILE:
                raise ConversionError('Для подготовки большой FB2 недостаточно места в рабочей папке.')
            files, documents = {}, []
            body_number, part_number = 1, 1
            piece = None
            nodes = text_length = 0

            def store_piece():
                nonlocal part_number
                stem = f'body-{body_number}' + (f'-{part_number}' if part_number > 1 else '')
                path = root / (stem + '.xml')
                ET.ElementTree(piece).write(path, encoding='utf-8')
                documents.append((stem + '.xhtml', path, part_number > 1))
                if progress is not None:
                    progress('preparing-fb2', len(documents), 0)
                part_number += 1

            def spool_part(body, section):
                nonlocal piece, nodes, text_length, body_number, part_number
                if check is not None:
                    check()
                if piece is None:
                    piece = ET.Element(body.tag, body.attrib)
                    piece.text = body.text
                if section is None:
                    store_piece()
                    piece = None
                    nodes = text_length = 0
                    body_number += 1
                    part_number = 1
                    return
                section_nodes = section_text = 0
                for node in section.iter():
                    section_nodes += 1
                    section_text += len(node.text or '') + len(node.tail or '')
                if len(piece) and (nodes + section_nodes > 50_000 or text_length + section_text > 8 * 1024 * 1024):
                    store_piece()
                    piece = ET.Element(body.tag, body.attrib)
                    piece.attrib.pop('id', None)
                    nodes = text_length = 0
                piece.append(section)
                nodes += section_nodes
                text_length += section_text

            book = parse_fb2_file(source, maximum, keep_binary_data=False, binary_files=files,
                                  binary_directory=root, maximum_nodes=10_000_000, part_completed=spool_part)
            write_fb2_epub(book, source, output, warnings, files, progress, working_directory=root, check=check,
                           stored_bodies=documents)
        return
    book, _ = read_fb2(source.read_bytes(), maximum, warnings)
    write_fb2_epub(book, source, output, warnings, check=check)


def fb2_body_documents(bodies, split=False):
    """Keep large FB2 bodies in consecutive EPUB documents at section boundaries."""
    for index, body in enumerate(bodies, 1):
        if not split or len(body) <= 1:
            yield f'body-{index}.xhtml', body, False
            continue
        groups = [[]]
        nodes = text_length = 0
        for section in body:
            section_nodes = section_text = 0
            for node in section.iter():
                section_nodes += 1
                section_text += len(node.text or '') + len(node.tail or '')
            if groups[-1] and (nodes + section_nodes > 50_000 or text_length + section_text > 8 * 1024 * 1024):
                groups.append([])
                nodes = text_length = 0
            groups[-1].append(section)
            nodes += section_nodes
            text_length += section_text
        if len(groups) == 1:
            yield f'body-{index}.xhtml', body, False
            continue
        for position, group in enumerate(groups, 1):
            fragment = ET.Element(body.tag, body.attrib)
            if position == 1:
                fragment.text = body.text
                filename = f'body-{index}.xhtml'
            else:
                fragment.attrib.pop('id', None)
                filename = f'body-{index}-{position}.xhtml'
            fragment.extend(group)
            yield filename, fragment, position != 1


def write_fb2_epub(book, source, output, warnings, binary_files=None, progress=None, *, working_directory=None,
                  check=None, stored_bodies=None):
    if book.tag != '{' + FB + '}FictionBook':
        raise ConversionError('Файл не является книгой FB2.')
    description = first(book, 'description')
    title_info = first(description, 'title-info') if description is not None else None
    if title_info is None:
        raise ConversionError('В FB2 отсутствует описание книги.')
    quote_sections = {identity for entry in children(description, 'custom-info')
                      if entry.get('info-type') == FB2_QUOTE_SECTIONS
                      for identity in plain(entry).split()}
    title = plain(first(title_info, 'book-title')) or Path(source).stem
    language = plain(first(title_info, 'lang')) or 'und'
    bodies = children(book, 'body')
    if not bodies:
        raise ConversionError('В FB2 отсутствует текст книги.')
    documents = stored_bodies

    def read_bodies():
        for filename, body, continuation in documents:
            if check is not None:
                check()
            yield filename, ET.parse(body).getroot() if isinstance(body, Path) else body, continuation

    ids, resources = {}, {}
    image_files, saved_image_ids, image_aliases = {}, {}, {}
    used_ids = {n.get('id') for n in book.iter() if n.get('id')}
    text_ids = {n.get('id') for n in book.iter() if tag(n) != 'binary' and n.get('id')}
    if stored_bodies is not None:
        for _, body, _ in read_bodies():
            text_ids.update(node.get('id') for node in body.iter() if node.get('id'))
        used_ids.update(text_ids)
    partial_jpegs, unreadable_jpegs = {}, set()
    for index, binary in enumerate(children(book, 'binary')):
        if check is not None:
            check()
        identity = binary.get('id', '')
        stored = binary_files[binary] if binary_files is not None else None
        if stored is not None:
            encoded = bytearray()
            with stored.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    encoded.extend(b''.join(chunk.split()))
                    if len(encoded) > MAX_FILE:
                        raise ConversionError('Изображение FB2 превышает предел размера: ' + identity)
        try:
            if stored is not None:
                data = base64.b64decode(encoded, validate=True)
                encoded.clear()
            else:
                data = base64.b64decode(re.sub(r'\s+', '', plain(binary)), validate=True)
        except ValueError as error:
            raise ConversionError('Повреждено изображение FB2: ' + identity) from error
        try:
            data, jpeg_note = recover_book_jpeg(data, warnings, identity, check)
        except UnreadableImage:
            label = f' «{identity[:100]}»' if identity else ''
            warnings.add(f'Повреждённая иллюстрация JPEG{label} пропущена. Доступный фрагмент восстановить не удалось.')
            unreadable_jpegs.add(identity)
            continue
        binary.text = None
        mime, extension = fb2_image_type(data, binary.get('content-type', 'application/octet-stream'))
        original_identity = identity
        previous = image_files.get(image_aliases.get(identity, identity)) if identity else None
        if previous:
            payload, previous_mime = resources[previous]
            if mime == previous_mime and (payload.read_bytes() if isinstance(payload, Path) else payload) == data:
                warnings.add('Одинаковые изображения с повторяющимся идентификатором FB2 сохранены одним ресурсом EPUB. Все ссылки на него сохранены.')
                continue
            warnings.add('В исходной FB2 разные изображения имеют одинаковый идентификатор. Все варианты сохранены с разными именами. Неоднозначные ссылки показывают первый вариант из исходного файла.')
        if previous or identity in text_ids:
            identity = 'image-resource-' + str(index + 1)
            while identity in used_ids: identity += '-copy'
            used_ids.add(identity)
            binary.set('id', identity)
            if not previous:
                warnings.add('Идентификатор изображения FB2 совпадает с меткой в тексте. Изображение получило отдельное имя; ссылки на изображение и метка текста сохранены.')
        if not identity:
            identity = 'unnamed-image-' + str(index + 1)
            while identity in used_ids: identity += '-copy'
            used_ids.add(identity)
            warnings.add('В исходной FB2 есть изображение без идентификатора. Его данные сохранены в EPUB с новым именем; отсутствующие ссылки на него не создавались.')
        filename = f'images/image-{index + 1}{extension}'
        if stored is not None:
            stored.write_bytes(data)
            resources[filename] = (stored, mime)
        else:
            resources[filename] = (data, mime)
        image_files[identity] = filename
        saved_image_ids[filename] = identity
        if original_identity: image_aliases.setdefault(original_identity, identity)
        if jpeg_note: partial_jpegs[identity] = jpeg_note
    lost_images = unreadable_jpegs - image_aliases.keys()
    if lost_images:
        spec = importlib.util.spec_from_file_location('homelib_image_quality', Path(__file__).with_name('image_quality.py'))
        image_quality = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(image_quality)
        api = SimpleNamespace(FB=FB, XL=XL, tag=tag, element=element, rewrite_css_urls=rewrite_css_urls)
        scopes = (body for _, body, _ in read_bodies()) if stored_bodies is not None else (book,)
        if not image_files and not any(image_quality.readable_text(api, scope, True) for scope in scopes):
            raise ConversionError('В FB2 нет текста и доступных изображений.')
        for identity in sorted(lost_images):
            image_quality.strip_fb2(api, book, only=identity, note='[Повреждённое изображение JPEG пропущено]')
    if stored_bodies is None:
        documents = list(fb2_body_documents(bodies, working_directory is not None))
    def note_damaged_pictures(body):
        if not partial_jpegs:
            return
        for node in body.iter():
            if tag(node) == 'image':
                reference = node.get('{' + XL + '}href', '').removeprefix('#')
                note = partial_jpegs.get(image_aliases.get(reference, reference))
                if note:
                    node.tail = f' [{note}]' + (node.tail or '')
    # A picture reference and a textual anchor are different namespaces in a
    # malformed source. Rename only picture resources/references; text links
    # must still reach their original text or image-element anchors.
    def rename_pictures(scope):
        for picture in scope.iter('{' + FB + '}image'):
            href = picture.get('{' + XL + '}href', '')
            if href.startswith('#') and href[1:] in image_aliases:
                picture.set('{' + XL + '}href', '#' + image_aliases[href[1:]])

    # Work on one stored part at a time and index every surviving fragment before
    # emitting links in any part, including links across separate FB2 bodies.
    for filename, body, _ in read_bodies():
        if stored_bodies is not None and lost_images:
            for identity in sorted(lost_images):
                image_quality.strip_fb2(api, body, only=identity, note='[Повреждённое изображение JPEG пропущено]')
        for node in body.iter():
            if identity := node.get('id'):
                if identity in ids:
                    raise ConversionError('В FB2 повторяется идентификатор: ' + identity)
                ids[identity] = filename
        note_damaged_pictures(body)
        if stored_bodies is not None:
            rename_pictures(body)
            ET.ElementTree(body).write(working_directory / Path(filename).with_suffix('.xml'), encoding='utf-8')
    rename_pictures(book)
    for stylesheet in children(book, 'stylesheet'):
        if stylesheet.text:
            def renamed_css(reference, original):
                if reference.startswith('#'):
                    identity, marker, fragment = reference[1:].partition('#')
                    name = image_aliases.get(identity, identity)
                    if name != identity:
                        return f'url("#{name}{marker}{fragment}")'
                return original
            stylesheet.text = rewrite_css_urls(stylesheet.text, renamed_css)
    def repair_titles(scope):
        for source_title in scope.iter('{' + FB + '}title'):
            if not ((source_title.text and source_title.text.strip()) or
                    any((n.tail and n.tail.strip()) or tag(n) not in {'p', 'empty-line'} for n in source_title)):
                continue
            parts, paragraph = [], None
            if source_title.text:
                paragraph = element(FB, 'p', source_title.text); parts.append(paragraph)
            for child in source_title:
                tail = child.tail; child.tail = None
                if tag(child) in {'p', 'empty-line'}:
                    parts.append(child); paragraph = None
                elif tag(child) in {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}:
                    if paragraph is None: paragraph = element(FB, 'p'); parts.append(paragraph)
                    paragraph.append(child)
                else:
                    raise ConversionError('В заголовке FB2 нельзя перенести элемент: ' + tag(child))
                if tail:
                    if paragraph is None:
                        if tail.strip(): paragraph = element(FB, 'p', tail); parts.append(paragraph)
                        else: child.tail = tail
                    else: append_text(paragraph, tail)
            source_title.text = None; source_title[:] = parts
            warnings.add('Текст заголовка исходной FB2 вне абзаца перенесён в абзац заголовка без потери текста.')

    repair_titles(book)
    headings = []
    missing_links = []
    generated_ids = set(ids)
    mapping = {'section': 'section', 'p': 'p', 'subtitle': 'h3', 'poem': 'div',
               'stanza': 'div', 'v': 'p', 'cite': 'blockquote', 'epigraph': 'blockquote',
               'text-author': 'p', 'date': 'p', 'strong': 'strong', 'emphasis': 'em',
               'strikethrough': 's', 'sub': 'sub', 'sup': 'sup', 'code': 'code',
               'style': 'span', 'annotation': 'div', 'a': 'a', 'table': 'table', 'tr': 'tr', 'td': 'td', 'th': 'th'}

    def add_heading(result, filename, label, level):
        identity = result.get('id')
        if not identity:
            index = len(headings) + 1
            while 'chapter-' + str(index) in generated_ids:
                index += 1
            identity = 'chapter-' + str(index)
            generated_ids.add(identity)
            result.set('id', identity)
        headings.append((filename + '#' + identity, label, level))

    def convert(node, filename, depth=0, navigation_depth=0, in_cell=False, section_heading=None):
        name = tag(node)
        section_title = first(node, 'title') if name == 'section' else None
        has_section_title = section_title is not None and bool(plain(section_title))
        if name == 'image':
            identity = node.get('{' + XL + '}href', '').lstrip('#')
            if identity not in image_files:
                raise ConversionError('Не найдено изображение FB2: ' + identity)
            result = element(XH, 'img', src=image_files[identity], alt=node.get('alt', ''))
            result.set('data-fb2-image-id', identity)
        elif name == 'br':
            if len(node) or (node.text and node.text.strip()):
                raise ConversionError('Элемент br в FB2 содержит вложенный текст или элементы.')
            warnings.add('Элемент br в исходной FB2 перенесён как перевод строки.')
            result = element(XH, 'br')
            result.set('data-fb2', 'empty-line')
            if node.get('id'):
                result.set('id', node.get('id'))
                result.set('data-fb2-attributes', json.dumps({'id': node.get('id')}))
            return result
        elif name == 'empty-line':
            result = element(XH, 'p'); result.append(element(XH, 'br'))
        elif name == 'title':
            result = element(XH, 'header')
            result.text = node.text
            for paragraph in node:
                heading = convert(paragraph, filename, depth, navigation_depth, in_cell)
                heading.tag = '{' + XH + '}h' + str(min(6, max(1, depth)))
                heading.tail = paragraph.tail
                result.append(heading)
        elif name == 'body':
            result = element(XH, 'div')
        elif name in mapping:
            quoted_section = name == 'section' and node.get('id') in quote_sections
            result = element(XH, 'blockquote' if quoted_section else mapping[name])
        else:
            raise ConversionError('Неизвестный элемент FB2: ' + name)
        result.set('data-fb2', name)
        if node.attrib:
            result.set('data-fb2-attributes', json.dumps(node.attrib, ensure_ascii=False, separators=(',', ':')))
        result.set('class', 'fb2-' + name + ((' ' + node.get('name', '')) if name == 'style' else ''))
        if name == 'p' and node.get('style') == TEXT_FRAME_STYLE:
            result.set('class', 'fb2-p ' + TEXT_FRAME_STYLE)
        word_layout = node.get('style', '') if name == 'p' else node.get('name', '') if name == 'style' else ''
        for marker in word_layout.split():
            if declarations := word_spacer_css(marker) or word_list_css(marker):
                result.set('class', result.get('class', '') + ' ' + marker)
                result.set('style', ';'.join(filter(None, (result.get('style'), declarations))))
                if name == 'style': result.set('aria-hidden', 'true')
        if name == 'image' and re.fullmatch(r'word_textbox_(?:left_)?[0-9]+', identity):
            if identity.startswith('word_textbox_left_'):
                result.set('class', 'fb2-image word-textbox-left')
            else:
                result.set('class', 'fb2-image word-textbox')
                result.set('style', 'display:block;margin-left:auto;margin-right:auto')
        if name == 'image' and re.fullmatch(r'word_diagram_(?:legend_)?[0-9]+', identity):
            legend = identity.startswith('word_diagram_legend_')
            result.set('class', 'fb2-image word-diagram-legend' if legend else 'fb2-image word-diagram')
            result.set('style', 'display:block;margin-right:auto;margin-left:' + ('0' if legend else 'auto'))
        if node.get('id'):
            result.set('id', node.get('id'))
        if name == 'a':
            href = node.get('{' + XL + '}href', '')
            if href.startswith('#'):
                if href[1:] not in ids:
                    missing_links.append(href)
                    # Keep the complete visible label, but do not emit a false
                    # EPUB hyperlink/noteref or guess an external URL.
                    result.tag = '{' + XH + '}span'
                    result.set('data-fb2', 'style')
                    label_attributes = {'name': 'source-link-without-target'}
                    if node.get('id'): label_attributes['id'] = node.get('id')
                    result.set('data-fb2-attributes', json.dumps(label_attributes))
                    result.set('data-homelib-source-href', href)
                    if node.get('type') == 'note': result.set('style', 'vertical-align:super;font-size:smaller')
                else: href = ids[href[1:]] + href
            if tag(result) == 'a': result.set('href', href)
            if tag(result) == 'a' and node.get('type') == 'note':
                result.set('{' + EP + '}type', 'noteref')
        for key in ('colspan', 'rowspan'):
            if node.get(key):
                result.set(key, node.get(key))
        if node.get('align'): result.set('style', 'text-align:' + node.get('align'))
        if name in {'table', 'td', 'th'}:
            cell_style = node.get('style', '')
            style = [result.get('style', '')]
            if name != 'table' and FB2_TABLE_LINE_STYLE in cell_style.split(';'):
                style.append(FB2_TABLE_LINE_STYLE)
            style.extend(resolved_table_style(
                (((1, 0, 0, 0), key, value, important)
                 for key, value, important in css_table_declarations(cell_style)), table=name == 'table'))
            if any(style):
                result.set('style', ';'.join(filter(None, style)))
        if has_section_title:
            # Untitled grouping sections do not create a navigation level.
            add_heading(result, filename, plain(section_title), navigation_depth + 1)
        elif name == 'title' and node is not section_heading and (label := plain(node)):
            add_heading(result, filename, label, navigation_depth + 1)
        if name == 'style' and in_cell:
            heading = re.fullmatch(FB2_TABLE_HEADING + '([1-9])', node.get('name', ''))
            label = ' '.join(plain(node).split()) if heading else ''
            if label:
                index = len(headings) + 1
                while 'chapter-' + str(index) in generated_ids: index += 1
                identity = 'chapter-' + str(index); generated_ids.add(identity)
                level = heading[1]
                result.attrib.update(id=identity, role='heading', **{'aria-level': level})
                result.set('style', 'display:block')
                headings.append((filename + '#' + identity, label, int(level)))
        if name not in {'image', 'empty-line', 'title'}:
            result.text = node.text
            for child in node:
                mapped = convert(child, filename, depth + (name == 'body' or name == 'section'),
                                 navigation_depth + has_section_title, in_cell or name in {'td', 'th'},
                                 section_heading=section_title)
                mapped.tail = child.tail
                result.append(mapped)
        if name == 'style':
            marker = node.get('name', '')
            if fb2_image_has_layout(marker):
                pictures = list(result.iter('{' + XH + '}img'))
                if len(pictures) == 1:
                    if height := word_rule_height(marker):
                        style_word_rule(pictures[0], height)
                    elif geometry := word_line_geometry(marker):
                        style_word_line(pictures[0], marker, geometry)
                    elif relative_width := fb2_relative_image_width(marker):
                        picture = pictures[0]
                        picture.set('class', ' '.join(filter(None, (picture.get('class'), marker))))
                        picture.set('style', relative_image_css(relative_width))
                    else:
                        set_html_image_extent(pictures[0], *fb2_image_size(marker))
        if result.get('data-homelib-source-href') is not None:
            # A style inside an FB2 link legitimately has no name. Once its
            # broken outer link becomes a plain label, give that style a name
            # so later export back to FB2 remains valid and keeps its content.
            for child in result.iter():
                if child.get('data-fb2') == 'style':
                    attributes = json.loads(child.get('data-fb2-attributes', '{}'))
                    if not attributes.get('name'):
                        attributes['name'] = 'source-link-style'
                        child.set('data-fb2-attributes', json.dumps(attributes))
        return result

    for index, (filename, body, continuation) in enumerate(read_bodies(), 1):
        if stored_bodies is not None:
            repair_titles(body)
        html = element(XH, 'html', **{'lang': language})
        head = element(XH, 'head'); head.append(element(XH, 'title', title))
        head.append(element(XH, 'link', rel='stylesheet', href='book.css', type='text/css'))
        html.append(head)
        html_body = element(XH, 'body'); html_body.append(convert(body, filename))
        layout_margin_rules(html_body)
        if any(tag(n) == 'br' for n in body.iter()):
            html_body[0].set('data-homelib-fb2-normalize', '1')
        if continuation:
            html_body[0].set('data-homelib-fb2-continuation', '1')
        html.append(html_body)
        if working_directory is None:
            payload = serialized(html)
        else:
            payload = working_directory / filename
            ET.ElementTree(html).write(payload, encoding='utf-8', xml_declaration=True)
        resources[filename] = (payload, 'application/xhtml+xml')
        if stored_bodies is not None and progress is not None:
            progress('preparing-fb2', len(stored_bodies) + index, 0)
    if missing_links:
        examples = ', '.join(dict.fromkeys(link[:120] for link in missing_links[:3]))
        warnings.add(f'В исходной FB2 отсутствуют цели ссылок: {len(missing_links)} ({examples}). Надписи ссылок сохранены без перехода; отсутствующий текст сносок не восстановлен.')
    css = ('body{line-height:1.35}p{margin:.45em 0;text-indent:1.3em}'
           'h1,h2,h3,h4,h5,h6{text-align:center;text-indent:0}'
           'img{max-width:100%;height:auto}.fb2-v{text-indent:0;margin:.1em 0;white-space:pre-wrap}'
           '.fb2-poem,.fb2-stanza{margin:1em 2em}.fb2-text-author{text-align:right}'
           '.fb2-epigraph,.fb2-cite{margin:1em 2em}.fb2-subtitle{text-align:center}'
           'code{white-space:pre-wrap}table{border-collapse:collapse}td,th{padding:.2em .4em}'
           f'.{TEXT_FRAME_STYLE}{{{TEXT_FRAME_CSS}}}.{TEXT_FRAME_STYLE} code{{white-space:pre;font-family:inherit}}'
           f'.{EPUB_LIST_MARKER_STYLE} img{{max-width:1em;max-height:1em;vertical-align:baseline}}')
    for stylesheet in children(book, 'stylesheet'):
        if stylesheet.get('type', 'text/css') == 'text/css':
            extra_css = plain(stylesheet)
            # FB2 has no packaged font resources. Do not emit an EPUB stylesheet
            # containing dangling publisher URLs carried in a source FB2.
            extra_css, font_faces = re.subn(r'@font-face\s*\{[^{}]*\}', '', extra_css, flags=re.I)
            if font_faces: warnings.add('Объявления внешних шрифтов FB2 не перенесены в EPUB; используются шрифты читалки.')
            if re.search(r'@import\b', extra_css, re.I):
                raise ConversionError('Внешнюю таблицу стилей FB2 нельзя перенести в EPUB без её файла.')
            def css_resource(reference, original):
                if reference.startswith('#'):
                    identity, marker, fragment = reference[1:].partition('#')
                    if identity in image_files:
                        return f'url("{image_files[identity]}{marker}{fragment}")'
                if not reference or reference.lower().startswith('data:image/'):
                    return original
                raise ConversionError('Не найден ресурс оформления FB2: ' + reference)
            extra_css = rewrite_css_urls(extra_css, css_resource)
            css += '\n' + rewrite_fb2_css_types(extra_css)
    resources['book.css'] = (css.encode('utf-8'), 'text/css')
    nav = element(XH, 'html', lang=language)
    head = element(XH, 'head'); head.append(element(XH, 'title', 'Содержание')); nav.append(head)
    body = element(XH, 'body'); nav.append(body)
    toc = element(XH, 'nav', **{'{' + EP + '}type': 'toc', 'id': 'toc'})
    body.append(toc); toc.append(element(XH, 'h1', 'Содержание'))
    navigation = restore_epub_outline(description, ids) or headings
    append_navigation_list(toc, navigation or [('body-1.xhtml', title, 1)], start_only=not navigation)
    resources['nav.xhtml'] = (serialized(nav), 'application/xhtml+xml')
    package = element(OP, 'package', version='3.0', **{'unique-identifier': 'book-id', 'prefix': 'mhl: ' + MHL})
    metadata = element(OP, 'metadata'); package.append(metadata)
    metadata.append(element(DC, 'identifier', 'urn:uuid:' + str(uuid.uuid4()), id='book-id'))
    metadata.append(element(DC, 'title', title)); metadata.append(element(DC, 'language', language))
    from datetime import datetime, timezone
    metadata.append(element(OP, 'meta', datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), property='dcterms:modified'))
    metadata.append(element(OP, 'meta', base64.b64encode(serialized(description)).decode(), property=FB2_DESCRIPTION_METADATA))
    metadata.append(element(OP, 'meta', json.dumps(saved_image_ids, ensure_ascii=False), property=FB2_IMAGES_METADATA))
    metadata.append(element(OP, 'meta', json.dumps([base64.b64encode(serialized(n)).decode() for n in children(book, 'stylesheet')]), property=FB2_STYLESHEETS_METADATA))
    for author in children(title_info, 'author'):
        name = ' '.join(plain(n) for n in author if tag(n) in {'first-name', 'middle-name', 'last-name', 'nickname'})
        if name:
            metadata.append(element(DC, 'creator', name))
    write_epub_publication_metadata(metadata, description, title_info)
    manifest = element(OP, 'manifest'); package.append(manifest)
    cover = first(title_info, 'coverpage')
    cover_pictures = children(cover, 'image') if cover is not None else []
    cover_images = [image_files.get(picture.get('{' + XL + '}href', '').lstrip('#'))
                    for picture in cover_pictures]
    cover_filename = None
    cover_bodies = (body for _, body, _ in read_bodies()) if stored_bodies is not None else bodies
    if cover_images and all(cover_images) and not fb2_cover_already_in_body(description, cover_bodies, cover):
        cover_filename = 'cover.xhtml'
        html = element(XH, 'html', lang=language)
        head = element(XH, 'head'); head.append(element(XH, 'title', title))
        head.append(element(XH, 'link', rel='stylesheet', href='book.css', type='text/css'))
        html.append(head)
        cover_body = element(XH, 'body', **FB2_COVER_PAGE_ATTRIBUTES)
        for picture, filename in zip(cover_pictures, cover_images):
            cover_body.append(element(XH, 'img', src=filename, alt=picture.get('alt', title)))
            identity = picture.get('{' + XL + '}href', '').removeprefix('#')
            if note := partial_jpegs.get(identity):
                cover_body.append(element(XH, 'p', f'[{note}]'))
        html.append(cover_body)
        resources[cover_filename] = (serialized(html), 'application/xhtml+xml')
    for index, (filename, (data, mime)) in enumerate(resources.items()):
        attributes = {'id': 'resource-' + str(index), 'href': filename, 'media-type': mime}
        if filename == 'nav.xhtml': attributes['properties'] = 'nav'
        if cover_images and filename == cover_images[0]: attributes['properties'] = 'cover-image'
        manifest.append(element(OP, 'item', **attributes))
    spine = element(OP, 'spine'); package.append(spine)
    by_name = {item.get('href'): item.get('id') for item in manifest}
    if cover_filename:
        spine.append(element(OP, 'itemref', idref=by_name[cover_filename]))
    for filename, _, _ in documents:
        spine.append(element(OP, 'itemref', idref=by_name[filename]))
    container = element(CN, 'container', version='1.0'); rootfiles = element(CN, 'rootfiles'); container.append(rootfiles)
    rootfiles.append(element(CN, 'rootfile', **{'full-path': 'OEBPS/package.opf', 'media-type': 'application/oebps-package+xml'}))
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', serialized(container))
        archive.writestr('OEBPS/package.opf', serialized(package))
        if progress:
            progress('writing-epub', 0, len(resources))
        for index, (filename, (data, mime)) in enumerate(resources.items(), 1):
            if isinstance(data, Path):
                compression = zipfile.ZIP_DEFLATED if mime == 'application/xhtml+xml' else zipfile.ZIP_STORED
                archive.write(data, 'OEBPS/' + filename, compress_type=compression)
            else:
                archive.writestr('OEBPS/' + filename, data)
            if progress and (index % 8 == 0 or index == len(resources)):
                progress('writing-epub', index, len(resources))


def epub_fragment_manifest_aliases(archive, package_path, package, groups, check):
    """Recognize saved web copies of gallery links that were entered as resources."""
    candidates = {identity: entries for identity, entries in groups.items() if identity and
                  len(entries) > 1 and all(item.get('media-type', '').startswith('image/xhtml#') for item in entries)}
    if not candidates:
        return set()

    referenced_ids = set()
    for node in package.iter():
        for attribute in ('idref', 'toc', 'fallback', 'fallback-style', 'media-overlay'):
            referenced_ids.add(node.get(attribute))
        if node.get('refines', '').startswith('#'):
            referenced_ids.add(node.get('refines')[1:])
        if tag(node) == 'meta' and node.get('name', '').lower() == 'cover':
            referenced_ids.add(node.get('content'))

    def file_address(reference):
        try:
            return archive.resolve(package_path, reference)
        except (ConversionError, ValueError):
            return None, ''

    pages = set()
    for entries in groups.values():
        if len(entries) == 1 and entries[0].get('media-type') in EPUB_XHTML_TYPES:
            path, fragment = file_address(entries[0].get('href', ''))
            if path in archive.names and not fragment:
                pages.add(path)

    unique_anchors, aliases, skipped = {}, {}, set()
    for identity, entries in candidates.items():
        if identity in referenced_ids:
            continue
        group_aliases = {}
        for item in entries:
            if check is not None:
                check()
            if set(item.attrib) != {'id', 'href', 'media-type'} or '?' in item.get('href', ''):
                break
            path, fragment = file_address(item.get('href', ''))
            if (not path or not fragment or item.get('media-type') != 'image/xhtml#' + fragment or
                    path in archive.names or path + '#' + fragment not in archive.names):
                break
            directory, name = posixpath.split(path)
            page = posixpath.join(posixpath.dirname(directory), name)
            if page == path or page not in pages:
                break
            if page not in unique_anchors:
                unique_anchors[page] = set()
                try:
                    body = first(xhtml(archive.read(page)), 'body')
                except (ConversionError, zipfile.BadZipFile):
                    body = None
                if body is not None:
                    counts = Counter()
                    for node in body.iter():
                        counts.update({node.get('id'), node.get('name') if tag(node) == 'a' else None} - {None, ''})
                    unique_anchors[page] = {anchor for anchor, count in counts.items() if count == 1}
            if fragment not in unique_anchors[page]:
                break
            group_aliases[path, fragment] = (page, fragment)
        else:
            skipped.add(identity)
            aliases.update(group_aliases)
    archive.fragment_aliases.update(aliases)
    return skipped


def epub_reading_order(archive, warnings, check=None, *, allow_partial_epub=False,
                       include_cover_pages=False, attached_styles=None, spool_directory=None):
    """Read the spine and the local XHTML documents linked from it."""
    container = xml(archive.read('META-INF/container.xml'), namespace_warnings=warnings)
    package_path = next((n.get('full-path') for n in container.iter() if tag(n) == 'rootfile'), '')
    if not package_path: raise ConversionError('В EPUB отсутствует пакет книги.')
    package = xml(archive.read(package_path), namespace_warnings=warnings); metadata = first(package, 'metadata')
    manifest = first(package, 'manifest'); spine = first(package, 'spine')
    if metadata is None or manifest is None or spine is None: raise ConversionError('Неполный пакет EPUB.')
    groups = {}
    for item in manifest:
        key = item.get('id')
        if not key: raise ConversionError('В EPUB отсутствует идентификатор ресурса.')
        groups.setdefault(key, []).append(item)
    skipped = epub_fragment_manifest_aliases(archive, package_path, package, groups, check)
    if skipped:
        warnings.add('Восстановлены переходы EPUB к иллюстрациям и разделам книги.')
    items = {}
    for item in manifest:
        key = item.get('id')
        if key in skipped:
            continue
        if key in items:
            if serialized(item).strip() != serialized(items[key]).strip():
                raise ConversionError('Один идентификатор EPUB обозначает разные ресурсы: ' + key)
            warnings.add('Повторяющиеся одинаковые записи каталога EPUB учтены один раз.')
        else: items[key] = item
    paths = {identity: archive.resolve(package_path, item.get('href', ''))[0] for identity, item in items.items()}
    navigation_paths = {paths[identity] for identity, item in items.items()
                        if 'nav' in item.get('properties', '').split()}
    cover_ids = {n.get('content') for n in metadata if tag(n) == 'meta' and n.get('name') == 'cover'}
    cover_resources = {paths[key]: item.get('media-type', '') for key, item in items.items()
                       if key in cover_ids or 'cover-image' in item.get('properties', '').split()}
    media_by_path = {}
    for key, item in items.items():
        media_by_path.setdefault(paths[key], item.get('media-type', ''))
    for reference in cover_ids.difference(items):
        if not reference:
            continue
        try:
            path, fragment = archive.resolve(package_path, reference)
        except (ConversionError, ValueError):
            continue
        media = media_by_path.get(path, '')
        if not fragment and path in archive.names and media.startswith('image/') and media not in EPUB_MISLABELED_XHTML_TYPES:
            cover_resources.setdefault(path, media)
    guide = first(package, 'guide')
    if guide is not None:
        for entry in children(guide, 'reference'):
            if entry.get('type') != 'cover':
                continue
            try:
                path, fragment = archive.resolve(package_path, entry.get('href', ''))
            except (ConversionError, ValueError):
                continue
            if path is not None and not fragment:
                cover_resources.setdefault(path, media_by_path.get(path) or mimetypes.guess_type(path)[0] or '')
    cover_anchors = {}
    vendor_html = {paths[identity] for identity, item in items.items()
                   if item.get('media-type') == 'application/x-ibooks-html'}
    documents = []
    documents_by_path = {}
    duplicate_anchors = {}
    empty_chapters = set()

    def keep_document(path, body):
        if spool_directory is not None:
            file = spool_directory / f'epub-body-{len(documents)}.xml'
            ET.ElementTree(body).write(file, encoding='utf-8')
            body = file
        documents.append((path, body))
        documents_by_path[path] = body

    def load_document(path):
        if path in documents_by_path: return
        if check is not None: check()
        if path is None: raise ConversionError('Внешняя глава EPUB не скачивается.')
        if path in vendor_html and any(part.lower().endswith('.wdgt') for part in path.split('/')[:-1]):
            if not allow_partial_epub:
                raise ConversionError('В книге есть интерактивный виджет Apple Books, который не поддерживается в FB2. Выберите «Оставить EPUB».')
            label = next(part[:-5] for part in path.split('/') if part.lower().endswith('.wdgt'))[:120]
            body = element(XH, 'body')
            body.append(element(XH, 'p', f'[Виджет Apple Books «{label}» доступен в исходной книге.]'))
            warnings.add(f'Виджет Apple Books не перенесён: «{label}».')
            keep_document(path, body)
            return
        data = archive.read(path)
        try:
            if empty_epub_chapter(data):
                document = element(XH, 'html')
                document.append(element(XH, 'body'))
                empty_chapters.add(path)
                warnings.add(f'Исправлена разметка пустого раздела EPUB «{posixpath.basename(path)[:100]}».')
            else:
                chapter_warnings = set()
                document = read_epub_content(data, chapter_warnings, part=path, allow_partial_epub=allow_partial_epub)
                warnings.update(chapter_warnings)
                if any(warning.startswith(EPUB_MISSING_BODY) for warning in chapter_warnings):
                    empty_chapters.add(path)
        except ConversionError as error:
            if path not in vendor_html or len(data) > 8 * 1024 * 1024:
                raise
            document = html5_epub_document(data)
            warnings.add('Исправлена разметка главы Apple Books «' + posixpath.basename(path)[:100] + '».')
        if document.tag not in {'{' + XH + '}html', 'html'}:
            raise ConversionError('Глава EPUB не является XHTML.')
        body = first(document, 'body')
        if body is None: raise ConversionError('В главе EPUB отсутствует текст.')
        for node in body.iter():
            if tag(node) == 'a' and not node.get('id') and node.get('name'):
                node.set('id', node.get('name'))
        ids = {n.get('id') for n in body.iter() if n.get('id')}
        if path in cover_resources:
            cover_anchors[path] = ids
        seen = set()
        suffixes = {}
        for node in body.iter():
            identity = node.get('id')
            if not identity:
                continue
            if identity in seen:
                suffix = suffixes.get(identity, 2)
                while f'{identity}-homelibre-{suffix}' in ids:
                    suffix += 1
                replacement = f'{identity}-homelibre-{suffix}'
                node.set('id', replacement)
                duplicate_anchors.setdefault((path, identity), []).append(replacement)
                ids.add(replacement)
                suffixes[identity] = suffix + 1
                warnings.add('Повторяющиеся метки EPUB переименованы. Ссылки ведут к первой метке.')
            seen.add(identity)
        keep_document(path, body)
        # Publisher styles may be embedded in each chapter's head too.
        head = first(document, 'head')
        if head is not None:
            embedded_css.extend((path, ''.join(n.itertext())) for n in head.iter() if tag(n) == 'style')
            if attached_styles is not None:
                attached_styles[path] = [n for n in head.iter() if tag(n) == 'style' or
                                         (tag(n) == 'link' and 'stylesheet' in n.get('rel','').lower().split())]
    embedded_css = []
    unavailable_navigation = set()

    def load_reading_document(path):
        if path in unavailable_navigation:
            return
        try:
            load_document(path)
        except (ConversionError, zipfile.BadZipFile):
            if not allow_partial_epub or path not in navigation_paths:
                raise
            unavailable_navigation.add(path)
            warnings.add(f'Оглавление EPUB повреждено или недоступно в разделе «{posixpath.basename(path or "")[:120]}».')

    for itemref in spine:
        identity = itemref.get('idref'); item = items.get(identity)
        if item is None: raise ConversionError('EPUB ссылается на отсутствующую главу.')
        if item.get('media-type') not in EPUB_XHTML_TYPES:
            raise ConversionError('Нетекстовая глава EPUB не поддерживается: ' + item.get('media-type', ''))
        path = paths[identity]
        if path in navigation_paths and itemref.get('linear', '') == 'no': continue
        load_reading_document(path)
    if not documents or all(path in empty_chapters for path, _ in documents):
        raise ConversionError('В EPUB отсутствуют главы для чтения.')
    if include_cover_pages:
        in_spine = len(documents)
        for path, media_type in cover_resources.items():
            if path is None or media_type not in EPUB_XHTML_TYPES or path in documents_by_path:
                continue
            try:
                load_document(path)
            except (ConversionError, zipfile.BadZipFile):
                # An unreadable cover outside the reading order cannot block the chapters.
                continue
        documents[:] = documents[in_spine:] + documents[:in_spine]
    # A valid EPUB may keep referenced notes or appendices outside the spine.
    # Include only linked local XHTML resources, never download external ones.
    text_resources = {paths[k] for k, item in items.items() if item.get('media-type') in EPUB_XHTML_TYPES}
    for path, stored in documents:
        body = ET.parse(stored).getroot() if isinstance(stored, Path) else stored
        changed = False
        for link in body.iter():
            if tag(link) == 'a' and link.get('href'):
                reference = link.get('href')
                try:
                    target, fragment = archive.resolve(path, reference)
                except EpubOutsideResource:
                    if not allow_partial_epub:
                        raise
                    warnings.add(f'Не найдена цель ссылки EPUB «{reference[:160]}». Ссылка выходит за пределы книги. Текст ссылки сохранён.')
                    del link.attrib['href']
                    changed = True
                    continue
                except ValueError as error:
                    warning = f'Некорректный адрес ссылки EPUB «{reference[:160]}». Текст ссылки сохранён.'
                    if not allow_partial_epub:
                        raise ConversionError(warning + ' Для частичного экспорта требуется подтверждение.') from error
                    warnings.add(warning)
                    del link.attrib['href']
                    changed = True
                    continue
                if target in text_resources: load_reading_document(target)
                if (path in navigation_paths and target in cover_anchors and fragment.casefold() == 'cover'
                        and fragment not in cover_anchors[target]):
                    # The publisher separately identifies this entire file as the cover.
                    link.set('href', reference.split('#', 1)[0])
                    changed = True
                    warnings.add(f'Метка обложки EPUB отсутствует в «{reference[:120]}». Переход ведёт к началу обложки.')
        if changed and isinstance(stored, Path):
            ET.ElementTree(body).write(stored, encoding='utf-8')
    return package_path, metadata, manifest, spine, items, paths, documents, embedded_css, duplicate_anchors, cover_resources


class FB2BinaryRange(NamedTuple):
    name: str
    start: int
    payload_start: int
    payload_end: int
    end: int


def write_fb2_binary(stream, name, mime, data, maximum=MAX_LARGE_FB2_OUTPUT):
    from xml.sax.saxutils import quoteattr

    start = stream.tell()
    header = f'<binary xmlns="{FB}" id={quoteattr(name)} content-type={quoteattr(mime)}>'.encode('utf-8')
    footer = b'</binary>'
    if start + len(header) + 4 * ((len(data) + 2) // 3) + len(footer) > maximum:
        raise ConversionError('Изображения не помещаются в FB2 (512 МБ). Сохраните книгу в EPUB.')
    stream.write(header)
    payload_start = stream.tell()
    # The block size is divisible by three, so padding only occurs at EOF.
    view = memoryview(data)
    for offset in range(0, len(view), 192 * 1024):
        stream.write(base64.b64encode(view[offset:offset + 192 * 1024]))
    payload_end = stream.tell()
    stream.write(footer)
    return FB2BinaryRange(name, start, payload_start, payload_end, stream.tell())


def write_fb2_resources(book, output, archive, resources, warnings, *, tools=None, static_gifs=False, check=None,
                       progress=None, sections=None, anchor_redirects=None, binary_ranges=None):
    """Write one binary at a time so base64 copies never accumulate in memory."""
    with ExitStack() as cleanup, output.open('w+b') as stream:
        gif_decoder = None
        # Write the XML tree directly. Serializing and splitting it in memory
        # creates two copies of the text of large dictionaries and manuals.
        if sections is None:
            ET.ElementTree(book).write(stream, encoding='utf-8', xml_declaration=True)
        else:
            header, marker, closing = serialized(book).rpartition(b'</')
            stream.write(header)
            stream.write(f'<body xmlns="{FB}">'.encode('utf-8'))
            for section in sections:
                if check is not None:
                    check()
                node = ET.parse(section).getroot()
                if anchor_redirects:
                    href_name = '{' + XL + '}href'
                    for link in node.iter('{' + FB + '}a'):
                        href = link.get(href_name, '')
                        if href.startswith('#') and href[1:] in anchor_redirects:
                            link.set(href_name, '#' + anchor_redirects[href[1:]])
                ET.ElementTree(node).write(stream, encoding='utf-8', xml_declaration=False)
                if stream.tell() > MAX_LARGE_FB2_OUTPUT:
                    raise ConversionError('Текст и оформление не помещаются в FB2 (512 МБ). Сохраните книгу в EPUB.')
            stream.write(b'</body>' + marker + closing)
        last_size = stream.tell()
        stream.seek(max(0, last_size - 128))
        _, marker, closing = stream.read().rpartition(b'</')
        if not marker or not re.fullmatch(br'(?:[A-Za-z_][\w.-]*:)?FictionBook>', closing):
            raise ConversionError('Не удалось дописать изображения в FB2.')
        closing = marker + closing
        stream.seek(last_size - len(closing))
        if progress:
            progress('writing-fb2', 0, len(resources))
        for index, (path, name, mime) in enumerate(resources, 1):
            if check:
                check()
            data = path.read_bytes() if isinstance(path, Path) else archive.read(path)
            if static_gifs and data.startswith((b'GIF87a', b'GIF89a')):
                sys.path.insert(0, str(Path(__file__).resolve().parent))
                try:
                    from gif_static import GifFrameDecoder, WARNING
                    if gif_decoder is None:
                        api = type('ConversionAPI', (), {key: value for key, value in globals().items() if not key.startswith('__')})
                        gif_decoder = cleanup.enter_context(GifFrameDecoder(api, tools, output.parent, check))
                    data = gif_decoder.decode(data)
                    warnings.add(WARNING)
                finally:
                    sys.path.pop(0)
                mime = 'image/png'
            entry = write_fb2_binary(stream, name, mime, data, MAX_LARGE_FB2_OUTPUT - len(closing))
            if binary_ranges is not None:
                binary_ranges.append(entry)
            if progress and (index % 8 == 0 or index == len(resources)):
                progress('writing-fb2', index, len(resources))
            del data
        stream.write(closing)


def repeat_epub_spine_sections(book, body, reading_order, archive, warnings, check):
    if len(reading_order) == len({section for _, section in reading_order}):
        return
    following, section_sizes = {}, {}
    seen = set()
    size_left = MAX_FILE
    nodes_left = 500000 - sum(1 for _ in book.iter())
    omitted = 0
    for path, section in reading_order:
        if section not in seen:
            seen.add(section)
            insert_after = section
            continue
        if check is not None:
            check()
        if section not in section_sizes:
            section_sizes[section] = (archive.archive.getinfo(path).file_size, sum(1 for _ in section.iter()))
        byte_size, node_count = section_sizes[section]
        if byte_size > size_left or node_count > nodes_left:
            omitted += 1
            continue
        duplicate = copy.deepcopy(section)
        # Links in the source resolve to the first passage. Keep the repeated
        # content and retain a single target for each of its anchors.
        for node in duplicate.iter():
            node.attrib.pop('id', None)
        following.setdefault(insert_after, []).append(duplicate)
        size_left -= byte_size
        nodes_left -= node_count
    body[:] = [part for section in body for part in (section, *following.get(section, ()))]
    if omitted:
        warnings.add(f'Не перенесены повторные разделы EPUB ({omitted}). Повтор превышает допустимый размер FB2.')


def epub_media_label(node):
    is_video = tag(node) == 'video'
    reference = node.get('src') or next((child.get('src', '') for child in children(node, 'source')), '')
    try:
        filename = posixpath.basename(unquote(urlsplit(reference).path))
    except ValueError:
        filename = ''
    label = node.get('title') or filename or ('видеозапись' if is_video else 'аудиозапись')
    return ('Видео' if is_video else 'Аудио'), label[:150]


WEBVTT_STAMP = r'(?:[0-9]{2,}:)?[0-5][0-9]:[0-5][0-9]\.[0-9]{3}'
WEBVTT_TIMING = re.compile(rf'({WEBVTT_STAMP})[ \t]+-->[ \t]+({WEBVTT_STAMP})(?:[ \t]+[^\n]*)?')
WEBVTT_TAG = re.compile(r'</?([a-z]+)(?:\.[^ \t<>.]+)*(?:[ \t]+([^<>]*))?>')
WEBVTT_ENTITIES = re.compile(r'&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);')


def decode_epub_cue_text(text):
    text = WEBVTT_ENTITIES.sub(lambda match: unescape_html(match[0]), text)
    return re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]', '\ufffd', text)


def epub_cue_paragraphs(lines, times):
    # Active spans continue over a line break within a cue, never into another cue.
    spans = []
    paragraphs = []
    for line in lines:
        paragraph = element(XH, 'p')
        chain = [paragraph]
        if not paragraphs and times:
            paragraph.append(element(XH, 'strong', times))
            append_text(paragraph, '  ')
        for _, markup, annotation in spans:
            nested = element(XH, markup, **annotation)
            chain[-1].append(nested)
            chain.append(nested)
        for token in re.split(r'(<[^<>\n]*>)', line):
            if token.startswith('<') and re.fullmatch(WEBVTT_STAMP, token[1:-1]):
                continue
            match = WEBVTT_TAG.fullmatch(token)
            if not match or match[1] not in {'b', 'i', 'u', 'c', 'v', 'lang', 'ruby', 'rt'}:
                append_text(chain[-1], decode_epub_cue_text(token))
                continue
            kind, argument = match[1], (match[2] or '').strip()
            if token.startswith('</'):
                for index in range(len(spans) - 1, -1, -1):
                    if spans[index][0] == kind:
                        if kind == 'rt':
                            append_text(chain[-1], ')')
                        del spans[index:]
                        del chain[index + 1:]
                        break
                continue
            markup = {'b': 'strong', 'i': 'em', 'u': 'u'}.get(kind, 'span')
            annotation = {'lang': argument} if kind == 'lang' and re.fullmatch('[a-zA-Z0-9-]+', argument) else {}
            nested = element(XH, markup, **annotation)
            chain[-1].append(nested)
            chain.append(nested)
            spans.append((kind, markup, annotation))
            if kind == 'v' and argument:
                append_text(nested, decode_epub_cue_text(argument) + ' — ')
            elif kind == 'rt':
                append_text(nested, ' (')
        paragraphs.append(paragraph)
    return paragraphs


def epub_subtitle_paragraphs(archive, path, track, resources, warnings):
    address = track.get('src', '')
    if not address:
        warnings.add('Субтитры EPUB не перенесены: для дорожки не указан файл.')
        return []
    try:
        member, fragment = archive.resolve(path, address)
        if fragment or member is None or resources.get(member) != 'text/vtt':
            raise ConversionError('Нужен локальный файл WebVTT, указанный в манифесте книги.')
        kind = track.get('kind', 'subtitles').casefold()
        if kind == 'metadata':
            raise ConversionError('Служебная дорожка предназначена для проигрывателя.')
        data = archive.read(member)
        try:
            text = data.decode('utf-8-sig')
            invalid_encoding = False
        except UnicodeDecodeError:
            text = data.decode('utf-8-sig', errors='replace')
            invalid_encoding = True
        text = text.replace('\r\n', '\n').replace('\r', '\n')
        header, _, text = text.partition('\n\n')
        signature, _, header_lines = header.partition('\n')
        if not re.fullmatch(r'WEBVTT(?:[ \t][^\n]*)?', signature):
            raise ConversionError('Файл не имеет заголовка WebVTT.')
    except (ConversionError, ValueError, zipfile.BadZipFile) as error:
        warnings.add(f'Субтитры EPUB не перенесены: «{address[:150]}». {error}')
        return []

    label = track.get('label', '').strip() or track.get('srclang', '').strip() or posixpath.basename(member)
    description = {'descriptions': 'Описание видео', 'chapters': 'Главы видео'}.get(kind, 'Субтитры')
    title = element(XH, 'p')
    title.append(element(XH, 'strong', f'{description} — {label}'))
    paragraphs = [title]
    if '-->' in header_lines:
        text = header_lines + '\n\n' + text
        warnings.add(f'Субтитры EPUB восстановлены частично: «{label}». Нет пустой строки после заголовка.')
    invalid_blocks = 0
    for block in re.split(r'\n{2,}', text.strip('\n')):
        if not block or re.match(r'NOTE(?:[ \t]|\n|$)', block) or block.split('\n', 1)[0] in {'STYLE', 'REGION'}:
            continue
        lines = block.split('\n')
        for index, line in enumerate(lines[:2]):
            if match := WEBVTT_TIMING.fullmatch(line):
                paragraphs.extend(epub_cue_paragraphs(lines[index + 1:], ' — '.join(match.groups())))
                break
        else:
            invalid_blocks += 1
            # Keep the recoverable lines even if their timestamps are malformed.
            paragraphs.extend(epub_cue_paragraphs(lines, ''))
    if invalid_encoding:
        warnings.add(f'Субтитры EPUB восстановлены частично: «{label}». В файле есть нечитаемые символы.')
    if invalid_blocks:
        warnings.add(f'Субтитры EPUB восстановлены частично: «{label}». Блоков без точного времени — {invalid_blocks}.')
    if len(paragraphs) == 1:
        return []
    warnings.add(f'Субтитры EPUB сохранены отдельным текстом: «{label}».')
    return paragraphs


def epub_to_fb2(source, output, warnings, *, use_navigation=True, stream_images=None, allow_partial_epub=False,
                maximum_total=None, preserve_image_placement=True, tools_root=None, cancel_check=None,
                render_math_images=True, generated_sections=None, document_progress=None):
    archive = EpubArchive(source, maximum_total)
    composition_cache = None
    staged_images = None
    try:
        if 'META-INF/encryption.xml' in archive.names:
            encrypted = xml(archive.read('META-INF/encryption.xml'))
            algorithms = [n.get('Algorithm', '') for n in encrypted.iter() if tag(n) == 'EncryptionMethod']
            if any(a not in {'http://www.idpf.org/2008/embedding', 'http://ns.adobe.com/pdf/enc#RC'} for a in algorithms):
                raise ConversionError('Зашифрованная книга EPUB не поддерживается.')
            warnings.add('Встроенные шрифты EPUB не переносятся в FB2.')
        check = cancel_check if stream_images is None else stream_images.get('check')
        attached_styles = {}
        (package_path, metadata, manifest, spine, items, paths, documents, embedded_css,
         duplicate_anchors, cover_resources) = epub_reading_order(
            archive, warnings, check, allow_partial_epub=allow_partial_epub, include_cover_pages=True,
            attached_styles=attached_styles, spool_directory=generated_sections)
        documents_by_path = dict(documents)
        media_resources = {paths[identity]: item.get('media-type') for identity, item in items.items()}

        def read_documents():
            for path, body in documents:
                if check is not None:
                    check()
                yield path, ET.parse(body).getroot() if isinstance(body, Path) else body
        reading_spine = [paths[item.get('idref')] for item in spine if item.get('linear', '').lower() != 'no']
        outline_headings, outline_titles, outline = ({}, {}, [])
        recovered_scan = any(child.get('id') == 'recovered-id' and plain(child).startswith('urn:homelibre:recovered:')
                             for child in children(metadata, 'identifier'))
        if use_navigation and not recovered_scan:
            outline_headings, outline_titles, outline = epub_outline_headings(archive, items, paths, spine,
                                                                            documents_by_path, duplicate_anchors,
                                                                            warnings)
        table_content = {'table': {'caption', 'colgroup', 'col', 'thead', 'tbody', 'tfoot', 'tr'},
                         'colgroup': {'col'}, 'col': set(),
                         'thead': {'tr'}, 'tbody': {'tr'}, 'tfoot': {'tr'}, 'tr': {'td', 'th'}}
        table_parts = table_content.keys() | {'td', 'th'}

        def normalize_row_spans(rows):
            for index, row in enumerate(rows):
                for cell in row:
                    if tag(cell) not in {'td', 'th'}:
                        continue
                    for key, maximum in (('colspan', 1000), ('rowspan', 65534)):
                        raw = cell.get(key)
                        if raw is None:
                            continue
                        # Match HTML's integer parsing and limit the magnitude
                        # before converting arbitrary strings to Python ints.
                        match = re.match(r'[\t\n\f\r ]*([+-]?)([0-9]+)', raw)
                        digits = match[2].lstrip('0') if match else ''
                        valid = match and (match[1] != '-' or not digits)
                        if not valid or (key == 'colspan' and not digits):
                            del cell.attrib[key]
                            warnings.add('Недопустимые размеры объединения ячеек EPUB заменены значениями по умолчанию по правилам HTML.')
                            continue
                        # An EPUB rowspan of zero spans the rest of this row
                        # group. FB2 stores the corresponding explicit count.
                        if not digits:
                            span = len(rows) - index
                        else:
                            span = min(maximum, int(digits)) if len(digits) <= len(str(maximum)) else maximum
                        cell.set(key, str(span))

        def normalize_table_spans(body):
            for table in body.iter('{' + XH + '}table'):
                rows = []
                for child in table:
                    name = tag(child)
                    if name == 'tr':
                        rows.append(child)
                    elif name in {'thead', 'tbody', 'tfoot'}:
                        normalize_row_spans(rows)
                        rows.clear()
                        normalize_row_spans(children(child, 'tr'))
                normalize_row_spans(rows)

        def malformed_table(table):
            return any((part.text or '').strip() or any(
                tag(child) not in table_content[tag(part)] or (child.tail or '').strip() for child in part)
                for part in table.iter() if tag(part) in table_content)

        def single_cell_wrapper(table):
            containers = [table]
            rows = list(table)
            if len(rows) == 1 and tag(rows[0]) == 'tbody':
                containers.append(rows[0])
                rows = list(rows[0])
            if len(rows) != 1 or tag(rows[0]) != 'tr' or len(rows[0]) != 1:
                return []
            cell = rows[0][0]
            if tag(cell) != 'td' or any(cell.get(span, '1') != '1' for span in ('rowspan', 'colspan')):
                return []
            return containers + [rows[0], cell]

        def preserve_nested_grids(body):
            ignored = set()
            local_references = None
            for table in list(body.iter('{' + XH + '}table')):
                if table in ignored or tag(table) != 'table': continue
                inner = list(table.iter('{' + XH + '}table'))[1:]
                layout_only = table.get('data-homelib-layout-wrapper') == '1'
                if not inner and not layout_only: continue
                if malformed_table(table):
                    ignored.update(inner)
                    continue
                rtf = table.get('data-homelib-rtf-table') == '1'
                wrapper = [] if rtf else single_cell_wrapper(table)
                if not inner:
                    if not wrapper: continue
                    if local_references is None:
                        local_references = {unquote(href[1:]) for link in body.iter('{' + XH + '}a')
                                            if (href := link.get('href', '')).startswith('#')}
                    linked_blocks = (block for block in wrapper[-1].iter()
                                     if tag(block) in {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'} and
                                     any(node.get('id') in local_references for node in block.iter()))
                    # A borderless full-width layout cell can contain several
                    # real destinations. Keep them as separate blocks in FB2.
                    if next(linked_blocks, None) is None or next(linked_blocks, None) is None:
                        continue
                if wrapper:
                    # Keep both the destinations and any inner tables in place.
                    for part in wrapper: part.tag = '{' + XH + '}div'
                    if inner:
                        warnings.add('Внешняя таблица из одной ячейки заменена разделом FB2. Внутренние таблицы сохранены, где позволяет формат.')
                    else:
                        warnings.add('Одноячеечная таблица разметки представлена абзацами FB2. Переходы сохранены на своих местах.')
                else:
                    # FB2 cells accept only inline content. Leave the outer grid.
                    for nested in inner:
                        for part in nested.iter():
                            if tag(part) in table_parts: part.tag = '{' + XH + '}div'
                    alternative = ' Внешняя таблица сохранена. Чтобы сохранить сетку вложенных таблиц, выберите EPUB.'
                    if rtf:
                        warnings.add('Вложенные таблицы RTF представлены строками внутри ячеек FB2.' + alternative)
                    else:
                        warnings.add('Вложенные таблицы развёрнуты внутри ячеек FB2.' + alternative)

        navigation_paths = {paths[key] for key, item in items.items() if 'nav' in item.get('properties', '').split()}
        navigation_lists, hidden_navigation = set(), {}
        for path, body in read_documents():
            if path not in navigation_paths:
                continue
            navigation_elements, hidden_elements = set(), set()
            parent = {child: node for node in body.iter() for child in node}
            for node in body.iter():
                owner = parent.get(node)
                if tag(node) == 'nav' or owner in navigation_elements:
                    navigation_elements.add(node)
                    if tag(node) in {'ol', 'ul'}:
                        navigation_lists.add(node)
                if owner in hidden_elements:
                    hidden_elements.add(node)
                elif owner is not None and 'hidden' in node.attrib:
                    hidden_elements.add(node)
                    hidden_navigation[node] = path
        aliases = {}
        table_alias_targets = set()
        def base_identity(path, fragment=''):
            return 'id_' + hashlib.sha256((path + '#' + fragment).encode('utf-8')).hexdigest()[:24]
        def identity(path, fragment=''):
            return aliases.get((path, fragment), base_identity(path, fragment))
        # Several inline anchors may denote the same paragraph. FB2 IDs belong
        # to blocks, so point all such references at their containing block.
        block_tags = {'p', 'div', 'section', 'article', 'aside', 'nav', 'li', 'td', 'th', 'tr', 'table', 'figure', 'pre', 'blockquote', 'ul', 'ol', 'dl', 'dd', 'dt', 'figcaption', 'caption', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}
        for path, body in read_documents():
            if any(n.get('data-fb2') == 'body' for n in body): continue
            normalize_table_spans(body)
            preserve_nested_grids(body)
            parents = {child: parent for parent in body.iter() for child in parent}
            for index, node in enumerate(body.iter()):
                if not node.get('id'): continue
                host = node
                while host is not body and tag(host) not in block_tags: host = parents[host]
                if tag(host) == 'tr':
                    row = host
                    host = next((cell for cell in row if tag(cell) in {'td', 'th'}), None)
                    if host is None:
                        host = parents[row]
                        while host is not body and tag(host) != 'table': host = parents[host]
                ancestor = host
                while ancestor is not body and tag(ancestor) not in {'td', 'th'}:
                    ancestor = parents[ancestor]
                if tag(ancestor) in {'td', 'th'}:
                    # FB2 flattens the paragraphs inside a cell. Keep their
                    # destinations on the retained cell so return links work.
                    host = ancestor
                    if node is not host:
                        table_alias_targets.add((path, node.get('id')))
                anchor = host.get('data-homelib-anchor')
                if not anchor:
                    # NUL cannot occur in an XML ID; keep synthetic block keys
                    # disjoint from all publisher-provided identifiers.
                    anchor = base_identity(path, host.get('id') or ('\x00block-' + str(index))) if host is not body else base_identity(path)
                    host.set('data-homelib-anchor', anchor)
                aliases[path, node.get('id')] = anchor
            if generated_sections is not None:
                ET.ElementTree(body).write(documents_by_path[path], encoding='utf-8')
        available = {(path, '') for path, body in documents}
        note_links = []
        numeric_candidates = set()
        numeric_link = re.compile(r'(?:\./)?([0-9]{1,9})').fullmatch
        for path, body in read_documents():
            folder = posixpath.dirname(path)
            for node in body.iter():
                if node.get('id'): available.add((path, node.get('id')))
                if tag(node) != 'a' or not (reference := node.get('href')): continue
                if match := numeric_link(reference):
                    resource = posixpath.join(folder, match[1])
                    if resource not in archive.names:
                        numeric_candidates.add(resource)
                if 'noteref' in node.get('{' + EP + '}type', '').split() or node.get('role') == 'doc-noteref':
                    note_links.append((path, reference))
        numeric_targets = {}
        if numeric_candidates:
            for path, fragment in available:
                if not re.fullmatch(r'[0-9]{1,9}', fragment): continue
                missing = posixpath.join(posixpath.dirname(path), fragment)
                if missing not in numeric_candidates: continue
                numeric_targets[missing] = (None if missing in numeric_targets or (path, fragment) in duplicate_anchors
                                            else (path, fragment))
            evidence = Counter(posixpath.dirname(key) for key, target in numeric_targets.items() if target)
            # More than one distinct match in the folder confirms the same
            # broken link pattern. Never redirect an existing file or guess
            # between duplicate anchors.
            numeric_targets = {key: target for key, target in numeric_targets.items()
                               if target and evidence[posixpath.dirname(key)] >= 2}

        def link_target(path, reference):
            target, fragment = archive.resolve(path, reference)
            if numeric_link(reference) and target in numeric_targets:
                return numeric_targets[target]
            if target and '\xa0' in fragment and (target, fragment) not in available:
                alternative = (target, fragment.replace('\xa0', ' '))
                if alternative in available and alternative not in duplicate_anchors:
                    return alternative
            return target, fragment

        notes = {target for path, reference in note_links if (target := link_target(path, reference))[0]}
        note_anchors = {identity(path, fragment) for path, fragment in notes if fragment}
        book = element(FB, 'FictionBook'); preserved_description = None
        original = epub_custom_metadata(metadata, FB2_DESCRIPTION_METADATA)
        if original:
            try: preserved_description = xml(base64.b64decode(original, validate=True))
            except (ValueError, ConversionError) as error: raise ConversionError('Повреждено исходное описание FB2.') from error
            if preserved_description.tag != '{' + FB + '}description': raise ConversionError('Неверное исходное описание FB2.')
        description = preserved_description if preserved_description is not None else element(FB, 'description')
        book.append(description)
        if preserved_description is None:
            fb3_description = fb3_source_description(metadata)
            ti = element(FB, 'title-info'); description.append(ti)
            ti.append(element(FB, 'genre', 'unrecognised'))
            creators, epub_translators = read_epub_people(metadata)
            authors = list(fb3_people(fb3_description, 'author')) if fb3_description is not None else []
            if [name for name, _ in authors] != creators:
                authors = [(name, {}) for name in creators]
            for name, fields in authors or [('Не указан', {})]:
                append_fb2_person(ti, 'author', name, fields)
            ti.append(element(FB, 'book-title', next((plain(n) for n in metadata if tag(n) == 'title'), Path(source).stem)))
            annotation_text = next((plain(n) for n in metadata if tag(n) == 'description' and plain(n)), '')
            source_annotation = first(fb3_description, 'annotation') if fb3_description is not None else None
            if source_annotation is not None and plain(source_annotation):
                def resolve_annotation_link(href):
                    if href.startswith('#'):
                        fragment = unquote(href[1:])
                        paths = [path for path, anchor in available if anchor == fragment and (path, anchor) not in duplicate_anchors]
                        return '#' + identity(paths[0], fragment) if len(paths) == 1 else ''
                    try:
                        return href if urlsplit(href).scheme.lower() in {'http', 'https', 'mailto'} else ''
                    except ValueError:
                        return ''
                annotation = restore_fb3_annotation(source_annotation, resolve_annotation_link, warnings)
                if len(annotation):
                    ti.append(annotation)
            elif annotation_text:
                annotation = element(FB, 'annotation')
                for paragraph in annotation_text.splitlines():
                    if paragraph.strip():
                        annotation.append(element(FB, 'p', paragraph))
                ti.append(annotation)
            subjects = [plain(n) for n in metadata if tag(n) == 'subject' and plain(n)]
            if subjects: ti.append(element(FB, 'keywords', ', '.join(subjects)))
            ti.append(element(FB, 'lang', next((plain(n) for n in metadata if tag(n) == 'language'), 'und')))
            translators = list(fb3_people(fb3_description, 'translator')) if fb3_description is not None else []
            if [name for name, _ in translators] != epub_translators:
                translators = [(name, {}) for name in epub_translators]
            for name, fields in translators:
                append_fb2_person(ti, 'translator', name, fields)
            append_epub_series_to_fb2(metadata, ti, warnings)
            info = element(FB, 'document-info'); description.append(info)
            author = element(FB, 'author'); author.append(element(FB, 'nickname', 'HomeLib Ru')); info.append(author)
            info.append(element(FB, 'program-used', 'HomeLib Ru — FB2/EPUB'))
            from datetime import date
            info.append(element(FB, 'date', date.today().isoformat(), value=date.today().isoformat()))
            info.append(element(FB, 'id', fb3_document_id(fb3_description) or str(uuid.uuid4())))
            version = fb3_description.get('version', '') if fb3_description is not None else ''
            info.append(element(FB, 'version', version if re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', version) else '1.0'))
            read_epub_publication_metadata(metadata, description, fb3_edition(fb3_description) if fb3_description is not None else None)
            # Keep all source metadata, including values without a direct FB2
            # counterpart (identifier, publisher, rights and EPUB refinements).
            description.append(element(FB, 'custom-info', base64.b64encode(serialized(metadata)).decode('ascii'), **{'info-type': 'HomeLib Ru: EPUB metadata (XML/base64)'}))
        image_ids, image_sizes, binaries = {}, {}, []
        picture_link_targets = {}
        jpeg_notices, jpeg_original_heights = {}, {}
        missing_image_resources = set()
        omitted_images = 0
        image_types = {}
        for resource_id, item in items.items():
            # Preserve the first declaration when several IDs name one file.
            image_types.setdefault(paths[resource_id], item.get('media-type'))

        def add_image(resource, mime, data, preferred='', stored=None):
            name = preferred or 'image_' + str(len(image_ids) + 1)
            if name in image_ids.values(): raise ConversionError('Повторяется идентификатор изображения.')
            if stream_images is None:
                binaries.append(element(FB, 'binary', base64.b64encode(data).decode('ascii'),
                                        id=name, **{'content-type': mime}))
            else:
                binaries.append((resource if stored is None else stored, name, mime))
            image_ids[resource] = name
            if preserve_image_placement:
                image_sizes[name] = raster_header_size(data)
            return name

        def embed_image(resolved, preferred='', recover=False, inline=None):
            nonlocal staged_images
            if resolved not in image_ids:
                if recover and resolved in missing_image_resources:
                    return None
                if inline is None:
                    mime = image_types.get(resolved)
                    if mime in EPUB_MISLABELED_XHTML_TYPES:
                        if recover:
                            missing_image_resources.add(resolved)
                            return None
                        raise ConversionError('Вместо изображения EPUB указана HTML-страница: ' + resolved)
                    if recover and resolved not in archive.names:
                        missing_image_resources.add(resolved)
                        return None
                    try:
                        data = archive.read(resolved)
                    except zipfile.BadZipFile:
                        if not recover:
                            raise
                        missing_image_resources.add(resolved)
                        return None
                    mime = mime or mimetypes.guess_type(resolved)[0] or ''
                    label = resolved
                else:
                    mime, data, label = inline
                if recover and (not data or data.isspace()):
                    missing_image_resources.add(resolved)
                    return None
                original = data
                notice = ''
                if recover:
                    try:
                        if data.startswith(b'\xff\xd8\xff'):
                            data, notice = recover_book_jpeg(data, warnings, label, check)
                        else:
                            check_embedded_raster(data)
                    except UnreadableImage:
                        missing_image_resources.add(resolved)
                        return None
                try:
                    detected, _ = fb2_image_type(data, mime if mime.startswith('image/') else '')
                except ConversionError as error:
                    if not mime.startswith('image/'):
                        if not recover:
                            raise ConversionError('Неизвестный тип изображения EPUB: ' + resolved) from error
                        missing_image_resources.add(resolved)
                        return None
                else:
                    if detected != mime:
                        warnings.add(f'Тип изображения EPUB уточнён по содержимому файла «{label[:120]}».')
                    mime = detected
                stored = None
                if data is not original:
                    mime = 'image/jpeg'
                if stream_images is not None and (inline is not None or data is not original):
                    if staged_images is None:
                        staged_images = tempfile.TemporaryDirectory(prefix='homelibre-fb2-images-', dir=output.parent)
                    stored = Path(staged_images.name) / hashlib.sha256(data).hexdigest()
                    if not stored.exists():
                        stored.write_bytes(data)
                identity = add_image(resolved, mime, data, preferred, stored)
                if notice:
                    jpeg_notices[identity] = notice
                    jpeg_original_heights[identity] = raster_header_size(original)[1]
            return image_ids[resolved]

        def picture_with_recovery_note(picture, identifier):
            notice = jpeg_notices.get(identifier)
            return [picture, element(FB, 'emphasis', ' [' + notice + ']')] if notice else [picture]

        def render_svg_raster(path, drawing, reference, preserve_resolution=False):
            nonlocal composition_cache
            try:
                resolved, fragment = archive.resolve(path, reference)
                if resolved not in archive.names or fragment:
                    return None
                data = archive.read(resolved)
                check_embedded_raster(data)
            except (EpubOutsideResource, UnreadableImage, zipfile.BadZipFile):
                return None
            if data.startswith(b'\x89PNG\r\n\x1a\n'):
                mime = 'image/png'
            elif data.startswith(b'\xff\xd8\xff'):
                mime = 'image/jpeg'
            else:
                return None
            raster_width, raster_height = raster_header_size(data)
            if not (0 < raster_width * raster_height <= 16 * 1024**2) or len(data) > MAX_FILE * 3 // 4:
                return None
            if preserve_resolution:
                width, height = int(drawing.get('width')), int(drawing.get('height'))
                # Scale the whole viewport without changing its aspect ratio.
                scale = min(4096 // max(width, height), math.isqrt(4_000_000 // (width * height)),
                            math.ceil(max(raster_width / width, raster_height / height)))
                if not scale:
                    return None
                drawing.set('width', str(width * scale))
                drawing.set('height', str(height * scale))
            tools = Path(tools_root or Path(__file__).resolve().parent.parent).resolve()
            renderer = tools / 'kfx-export' / 'resvg.exe'
            if not renderer.is_file():
                raise ComponentRequired('KfxExport', 'Для переноса композиции SVG в FB2 нужен отрисовщик из модуля KFX и AZW8.')
            if composition_cache is None:
                composition_cache = tempfile.TemporaryDirectory(prefix='homelibre-art-', dir=output.parent)
            work = Path(composition_cache.name).resolve()
            digest = hashlib.sha256(data)
            digest.update(serialized(drawing))
            key = digest.hexdigest()
            bitmap = work / (key + '.png')
            if bitmap in image_ids:
                return image_ids[bitmap], resolved
            svg_file = work / 'artwork.svg'
            inline_picture = f'data:{mime};base64,' + base64.b64encode(data).decode('ascii')
            drawing[-1].set(f'{{{XL}}}href', inline_picture)
            svg_file.write_bytes(serialized(drawing))
            module_dir = str(Path(__file__).resolve().parent)
            sys.path.insert(0, module_dir)
            try:
                from advanced_output import run_writer
                run_writer(SimpleNamespace(ConversionError=ConversionError),
                           [str(renderer), '--skip-system-fonts', str(svg_file), str(bitmap)], work, check, timeout=30)
            finally:
                sys.path.pop(0)
            if not bitmap.is_file() or not 0 < bitmap.stat().st_size <= MAX_FILE:
                raise ConversionError('Не удалось получить обложку SVG допустимого размера.')
            data = bitmap.read_bytes()
            check_embedded_raster(data)
            size = (int(drawing.get('width')), int(drawing.get('height')))
            if not data.startswith(b'\x89PNG\r\n\x1a\n') or raster_header_size(data) != size:
                raise ConversionError('Размер отрисованной обложки SVG отличается от исходного.')
            return add_image(bitmap, 'image/png', data), resolved

        def image(path, reference, preferred='', recover=False):
            if not reference.strip():
                if recover:
                    return None
                raise ConversionError('В EPUB не указан файл изображения.')
            if reference[:5].lower() == 'data:':
                if check:
                    check()
                try:
                    mime, data = decode_epub_inline_image(reference)
                except UnreadableImage as error:
                    if recover:
                        if reference[:19].lower() in ('data:image/svg+xml,', 'data:image/svg+xml;'):
                            warnings.add(f'SVG в «{posixpath.basename(path)[:80]}»: {error}')
                        return None
                    raise
                key = ('inline', mime, hashlib.sha256(data).hexdigest())
                label = f'Встроенная иллюстрация в «{posixpath.basename(path)[:80]}»'
                return embed_image(key, preferred, recover, (mime, data, label))
            try:
                resolved, _ = archive.resolve(path, reference)
            except EpubOutsideResource:
                if allow_partial_epub and recover:
                    return None
                raise
            except ValueError as error:
                if recover:
                    return None
                raise ConversionError('Некорректный адрес изображения EPUB: ' + reference[:120]) from error
            if resolved is None:
                if recover: return None
                raise ConversionError('Внешнее изображение EPUB не скачивается: ' + reference)
            return embed_image(resolved, preferred, recover)

        def image_label(path, reference, description=''):
            chapter = posixpath.basename(path)[:80]
            prefix = description + ' ' if description else ''
            if not reference.strip():
                return f'{prefix}В разделе «{chapter}» не указан файл изображения.'
            if reference[:5].lower() == 'data:':
                return description or f'Встроенная иллюстрация в «{chapter}».'
            try:
                filename = posixpath.basename(unquote(urlsplit(reference).path))
            except ValueError:
                return f'{prefix}В разделе «{chapter}» некорректный адрес изображения «{reference[:60]}».'
            return description or filename or f'Изображение из раздела «{chapter}».'

        def missing_picture(label=''):
            nonlocal omitted_images
            omitted_images += 1
            warnings.add('Часть изображений EPUB недоступна. На их местах стоят отметки.')
            warnings.add(f'Изображение {omitted_images} недоступно.' + (' ' + label[:160] if label else ''))
            return element(FB, 'emphasis', f'[Изображение {omitted_images} недоступно.]' +
                           (' ' + label if label else ''))

        title_info = first(description, 'title-info')
        cover_page = first(title_info, 'coverpage') if title_info is not None else None
        def add_cover(picture):
            nonlocal cover_page
            cover_page = element(FB, 'coverpage')
            cover_page.append(element(FB, 'image', **picture))
            # FB2 title-info puts coverpage before lang.
            at = next((i for i, n in enumerate(title_info) if tag(n) == 'lang'), len(title_info))
            title_info.insert(at, cover_page)

        cover_sections = {}
        converted_sections = {}
        cropped_covers = {}
        unreadable_covers = set()
        for path, media in cover_resources.items():
            if path is None or not media.startswith('image/'):
                continue
            preferred = (next((n.get('{' + XL + '}href', '').lstrip('#') for n in children(cover_page, 'image')), '')
                         if cover_page is not None else '')
            name = embed_image(path, preferred, recover=preserved_description is None)
            if name is not None:
                if cover_page is None:
                    add_cover({'{' + XL + '}href': '#' + name})
                break
            unreadable_covers.add(path)
            warnings.add(f'Не удалось прочитать обложку EPUB «{path[:120]}».')
        if preserved_description is not None:
            try:
                saved_images = json.loads(epub_custom_metadata(metadata, FB2_IMAGES_METADATA, '{}'))
                for reference, preferred in saved_images.items(): image(package_path, reference, preferred)
                saved_styles = json.loads(epub_custom_metadata(metadata, FB2_STYLESHEETS_METADATA, '[]'))
                for value in reversed(saved_styles):
                    stylesheet = xml(base64.b64decode(value, validate=True))
                    if stylesheet.tag != '{' + FB + '}stylesheet': raise ConversionError('Неверная исходная таблица стилей.')
                    book.insert(0, stylesheet)
            except (ValueError, AttributeError, TypeError) as error: raise ConversionError('Повреждены исходные ресурсы FB2.') from error
        inline_mapping = {'strong': 'strong', 'b': 'strong', 'em': 'emphasis', 'i': 'emphasis',
                          's': 'strikethrough', 'del': 'strikethrough', 'strike': 'strikethrough',
                          'sub': 'sub', 'sup': 'sup', 'code': 'code', 'a': 'a'}
        margin_rule_count = 0
        converted_text_frames = False
        block_mapping = {'p': 'p', 'blockquote': 'cite', 'table': 'table', 'tr': 'tr', 'td': 'td', 'th': 'th', 'caption': 'subtitle', 'dt': 'subtitle'}
        # Preserve simple CSS emphasis, including publisher classes on paragraphs.
        css_rules = []
        css_sources = list(embedded_css)
        external_css = {}
        for item in manifest:
            if item.get('media-type') == 'text/css':
                reference = item.get('href', '')
                css_path = paths[item.get('id')]
                css = None
                if css_path in archive.names:
                    try:
                        data = archive.read(css_path)
                        encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
                        css = data.decode(encoding, errors='replace').replace('\f', '\n')
                    except (ConversionError, zipfile.BadZipFile):
                        pass
                if css is None or re.search(r'[\x00-\x08\x0b\x0e-\x1f\ufffe\uffff]', css):
                    warning = f'Таблица стилей EPUB недоступна: «{reference[:120]}». Текст сохраняется с доступным оформлением.'
                    if not allow_partial_epub:
                        raise ConversionError(warning + ' Для частичного экспорта требуется подтверждение.')
                    warnings.add(warning)
                    continue
                external_css[css_path] = css
                css_sources.append((css_path, css))
        for _, css in css_sources:
            for selector, properties in re.findall(r'([^{}]+)\{([^{}]*)\}', re.sub(r'/\*.*?\*/', '', css, flags=re.S)):
                for simple in selector.split(','):
                    if re.fullmatch(r'(?:[a-zA-Z][\w-]*)?(?:\.[\w-]+)*', simple.strip()):
                        css_rules.append((simple.strip(), properties))
            if re.search(r'\b(?:display\s*:\s*(?:grid|flex)|float\s*:|position\s*:\s*(?:absolute|fixed))', css, re.I):
                warnings.add('Сложное расположение блоков EPUB упрощено до последовательного текста FB2.')

        def svg_viewport_css(node, sized_picture=None):
            # Sizing the outer SVG does not change the composition inside its viewBox.
            # Keep the ordinary fallback when publisher CSS paints or clips the contents.
            for part in node.iter():
                classes = set(part.get('class', '').split())
                declarations = [] if part is sized_picture else [part.get('style', '')]
                for selector, properties in css_rules:
                    name, *required_classes = selector.split('.')
                    if (not name or name == tag(part)) and set(required_classes).issubset(classes):
                        declarations.append(properties)
                allowed = {'width', 'height', 'max-width', 'max-height', 'display'} if part is node else set()
                for rule in declarations:
                    for entry in rule.split(';'):
                        if not entry.strip():
                            continue
                        property_name, _, value = entry.lower().partition(':')
                        property_name = property_name.strip()
                        if (property_name not in allowed or
                                property_name == 'display' and value.strip() not in {'block', 'inline', 'inline-block'}):
                            return False
            return True

        def viewport_stylesheets(path, head_nodes):
            styles = []
            for node in head_nodes:
                name = tag(node)
                if name in {'title', 'meta'}:
                    continue
                if (node.get('media', '').strip().lower() not in {'', 'all', 'screen'} or
                        node.get('type', '').strip().lower() not in {'', 'text/css'}):
                    return None
                if name == 'style' and node.attrib.keys() <= {'media', 'type'}:
                    css = ''.join(node.itertext())
                elif (name == 'link' and node.get('rel', '').strip().lower() == 'stylesheet' and
                      node.attrib.keys() <= {'href', 'rel', 'media', 'type'}):
                    href = node.get('href', '')
                    if not href or '?' in href:
                        return None
                    try:
                        stylesheet, fragment = archive.resolve(path, href)
                    except (EpubOutsideResource, ValueError):
                        return None
                    if fragment or stylesheet not in external_css:
                        return None
                    css = external_css[stylesheet]
                else:
                    return None
                styles.append(css)
            return styles if sum(map(len, styles)) <= 65536 else None

        def reflowable_svg_viewport(path, svg, picture, reference):
            if archive.archive.getinfo(path).file_size > 65536 or any(
                n.get('property') == 'rendition:layout' and plain(n).strip() == 'pre-paginated' for n in metadata
            ):
                return None
            if any(paths.get(n.get('idref')) == path and 'rendition:layout-pre-paginated' in n.get('properties', '').split()
                   for n in spine):
                return None
            try:
                data = archive.read(path)
                if re.search(br'<\?xml-stylesheet\b', data.replace(b'\0', b''), re.I):
                    return None
                document = xhtml(data)
                head = first(document, 'head')
                styles = None
                if head is not None and any(tag(node) == 'link' for node in head):
                    styles = viewport_stylesheets(path, head)
                    if styles is None:
                        return None
                size = svg_reflowable_viewport_size(document, svg, picture, styles)
                if size is None or ('href' in picture.attrib and f'{{{XL}}}href' in picture.attrib):
                    return None
                target, fragment = archive.resolve(path, reference)
                if target not in archive.names or fragment:
                    return None
                with archive.archive.open(target) as raster:
                    header = raster.read(1024 * 1024)
                if not header.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff')):
                    return None
                width, height = raster_header_size(header)
                if width and height:
                    same_ratio = width * size[1] == height * size[0]
                    return size, same_ratio
            except (ConversionError, ValueError, zipfile.BadZipFile):
                return None

        def css_declarations(node):
            classes = set(node.get('class', '').split())
            matched = []
            for index, (selector, properties) in enumerate(css_rules):
                bits = selector.split('.'); name = bits[0]
                if (not name or name == tag(node)) and set(bits[1:]).issubset(classes):
                    matched.append((len(bits[1:]) * 100 + bool(name), index, properties))
            style_text = ';'.join(properties for _, _, properties in sorted(matched)) + ';' + node.get('style', '')
            declarations = {}
            for entry in style_text.split(';'):
                if ':' in entry:
                    key, value = entry.split(':', 1); declarations[key.strip().lower()] = value.strip().lower()
            return declarations

        def styled(node, result):
            if tag(result) not in {'p', 'subtitle', 'v', 'text-author', 'style', 'a', 'strong', 'emphasis', 'td', 'th'}: return result
            declarations = css_declarations(node)
            wrappers = []
            if re.fullmatch(r'(?:bold|[6-9]00)(?:\s*!important)?', declarations.get('font-weight', '')): wrappers.append('strong')
            if re.match(r'(?:italic|oblique)\b', declarations.get('font-style', '')): wrappers.append('emphasis')
            if 'line-through' in declarations.get('text-decoration', '') + declarations.get('text-decoration-line', ''): wrappers.append('strikethrough')
            for name in wrappers:
                wrapped = element(FB, name); wrapped.text = result.text; result.text = None
                for child in list(result): result.remove(child); wrapped.append(child)
                result.append(wrapped)
            return result
        # The HTML reader sanitizes CHM before writing these generated parts.
        # It emits text and images, with no MathML or publisher scripts.
        formulas = [] if generated_sections is not None else [
            node for _, body in documents for node in body.iter() if tag(node) == 'math']
        math_module = None
        rendered_math = {}
        math_error = ''
        if formulas:
            spec = importlib.util.spec_from_file_location('homelibre_mathml', Path(__file__).with_name('mathml_output.py'))
            math_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(math_module)
            if render_math_images:
                tools = Path(tools_root or Path(__file__).resolve().parent.parent).resolve()
                composition_cache = tempfile.TemporaryDirectory(prefix='homelibre-art-', dir=output.parent)
                math_api = SimpleNamespace(ConversionError=ConversionError, UnreadableImage=UnreadableImage,
                                           raster_header_size=raster_header_size, check_embedded_raster=check_embedded_raster)
                rendered_math, math_error = math_module.render(math_api, formulas, tools,
                                                            Path(composition_cache.name) / 'math', check)

        inline_fb = {'strong', 'emphasis', 'style', 'a', 'strikethrough', 'sub', 'sup', 'code', 'image'}
        heading_levels = {}
        list_prefixes = {}
        rules_by_source, rules_by_document, list_parents, list_styles = {}, {}, {}, {}
        list_initial = {'list-style-type': ('disc', ''), 'list-style-image': ('none', '')}
        list_type_attribute = {'1':'decimal', 'a':'lower-latin', 'A':'upper-latin',
                               'i':'lower-roman', 'I':'upper-roman', 'disc':'disc',
                               'circle':'circle', 'square':'square'}

        def local_rules(path):
            if path in rules_by_document:
                return rules_by_document[path]
            result = []
            for part in attached_styles.get(path, ()):
                if part.get('media', '').strip().lower() not in {'', 'all', 'screen'}:
                    continue
                origin = path
                if tag(part) == 'link':
                    try:
                        origin, _ = archive.resolve(path, part.get('href', ''))
                    except EpubOutsideResource:
                        continue
                    css = external_css.get(origin, '')
                else:
                    css = ''.join(part.itertext())
                key = (origin, css)
                if key not in rules_by_source:
                    rules = []
                    if re.search(r'list-style|background|border|padding', css, re.I):
                        text = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
                        depth = 0
                        start = opening = 0
                        for token in re.finditer(CSS_QUOTED + r'|[{}]', text):
                            if token[0] == '{':
                                if depth == 0:
                                    opening = token.start()
                                depth += 1
                            elif token[0] == '}':
                                depth -= 1
                                if depth != 0:
                                    continue
                                selectors = text[start:opening].rsplit(';', 1)[-1].strip()
                                declarations = text[opening+1:token.start()]
                                start = token.end()
                                if selectors.startswith('@') or '{' in declarations:
                                    continue
                                picked = tuple(css_list_declarations(declarations)) + tuple(css_table_declarations(declarations))
                                if not picked:
                                    continue
                                for selector in selectors.split(','):
                                    selector = selector.strip()
                                    simple = re.fullmatch(r'([\w-]+|\*)?((?:[.#][\w-]+)*)', selector)
                                    if not selector or not simple or len(selector) > 256:
                                        continue
                                    tag_name, suffix = simple.groups()
                                    tests = tuple(re.findall(r'([.#])([\w-]+)', suffix))
                                    specificity = (0,suffix.count('#'),suffix.count('.'),int(tag_name not in (None,'*')))
                                    rules.append((tag_name,tests,specificity,origin,picked))
                    rules_by_source[key] = rules
                result.extend(rules_by_source[key])
            rules_by_document[path] = result
            return result

        def matched_local_rules(node, path):
            name = tag(node)
            classes = set(node.get('class', '').split())
            ident = node.get('id', '')
            for tag_name, tests, specificity, origin, declarations in local_rules(path):
                if tag_name in (None, '*', name) and all(
                    value == ident if marker == '#' else value in classes for marker, value in tests
                ):
                    yield specificity, origin, declarations

        def table_style_layers(node, path):
            for specificity, _, declarations in matched_local_rules(node, path):
                for name, value, important in declarations:
                    if name not in list_initial:
                        yield specificity, name, value, important
            for name, value, important in css_table_declarations(node.get('style', '')):
                yield (1, 0, 0, 0), name, value, important

        def list_style(node, path):
            if node in list_styles:
                return list_styles[node]
            if path not in list_parents:
                list_parents[path] = {child:parent for parent in documents_by_path[path].iter() for child in parent}
            parent = list_parents[path].get(node)
            inherited = list_style(parent, path) if parent is not None else list_initial
            values, priorities = dict(inherited), {}
            name = tag(node)
            default = {'ul':'disc', 'ol':'decimal'}.get(name)
            if name in {'ul','ol','li'}:
                default = list_type_attribute.get(node.get('type',''), default)
            if default is not None:
                values['list-style-type'] = (default, path)
            def apply(declarations, specificity, origin):
                for property_name,value,important in declarations:
                    if property_name not in list_initial:
                        continue
                    rank = (important, *specificity)
                    if property_name not in priorities or rank >= priorities[property_name]:
                        priorities[property_name] = rank
                        if value in {'inherit','unset'}:
                            values[property_name] = inherited[property_name]
                        elif value == 'initial':
                            values[property_name] = list_initial[property_name]
                        else:
                            values[property_name] = (value, origin)

            for specificity, origin, declarations in matched_local_rules(node, path):
                apply(declarations,specificity,origin)
            apply(css_list_declarations(node.get('style','')),(1,0,0,0),path)
            list_styles[node] = values
            return values

        def list_entries(container):
            for item in container:
                name = tag(item)
                if name == 'li': yield item
                elif name not in {'ol', 'ul'}: yield from list_entries(item)

        def flow(node, result, path):
            """Build heading sections at every HTML container depth, not only body."""
            current, stack, paragraph = result, [(0, result)], None
            unwrap_quote_divs = tag(result) == 'cite'

            def contents(container):
                if container.text:
                    yield container.text
                for child in container:
                    if unwrap_quote_divs and tag(child) == 'div' and not child.attrib and child not in hidden_navigation:
                        yield from contents(child)
                    else:
                        yield child
                    if child.tail:
                        yield child.tail

            for child in contents(node):
                if isinstance(child, str):
                    if child.strip() or paragraph is not None:
                        if paragraph is None: paragraph = element(FB, 'p'); current.append(paragraph)
                        append_text(paragraph, child)
                    continue
                level = 0 if child in hidden_navigation else html_heading_level(child) or outline_headings.get(child, 0)
                if level:
                    while len(stack) > 1 and stack[-1][0] >= level: stack.pop()
                    section = element(FB, 'section'); section.extend(convert(child, path)); stack[-1][1].append(section)
                    stack.append((level, section)); current = section; paragraph = None
                else:
                    for mapped in convert(child, path):
                        if tag(mapped) in inline_fb:
                            if paragraph is None: paragraph = element(FB, 'p'); current.append(paragraph)
                            paragraph.append(mapped)
                        else:
                            current.append(mapped); paragraph = None
            return result
        def table_cell(result):
            """FB2 cells permit inline markup, but no nested HTML paragraphs."""
            has_line_breaks = False
            def ending(node):
                if len(node): return node[-1].tail[-1:] if node[-1].tail else ending(node[-1])
                return (node.text or '')[-1:]
            def line_break(target, explicit=False):
                nonlocal has_line_breaks
                if explicit or ((target.text or len(target)) and ending(target) != '\n'):
                    append_text(target, '\n')
                    has_line_breaks = True
            def append_cell_text(target, value, preformatted):
                if value:
                    append_text(target, value if preformatted else re.sub(r'[\t\r\n\f ]+', ' ', value))
            def flatten(source, target, preformatted=False):
                append_cell_text(target, source.text, preformatted)
                for child in source:
                    if tag(child) == 'table': raise ConversionError('Вложенную таблицу EPUB нельзя сохранить в FB2. Выберите «Оставить EPUB», чтобы сохранить таблицу.')
                    if tag(child) in inline_fb:
                        clone = element(FB, tag(child), **child.attrib)
                        flatten(child, clone, preformatted or tag(child) == 'code'); target.append(clone)
                    elif tag(child) == 'empty-line':
                        line_break(target, explicit=True)
                    else:
                        warnings.add('Абзацы внутри ячеек таблицы EPUB разделены переносами строк.')
                        line_break(target)
                        level = heading_levels.pop(child, None)
                        if level is None or not plain(child):
                            flatten(child, target, preformatted)
                        else:
                            # FB2 cells accept inline named styles, not title blocks.
                            heading = element(FB, 'style', name=FB2_TABLE_HEADING + str(level))
                            emphasis = element(FB, 'strong')
                            flatten(child[0], emphasis, preformatted)
                            heading.append(emphasis); target.append(heading)
                            warnings.add('Заголовки в ячейках таблиц сохранены. Перейти к ним из оглавления FB2 можно в HomeLibre Reader. Чтобы сохранить переходы и в других читалках, выберите EPUB.')
                        line_break(target)
                    append_cell_text(target, child.tail, preformatted)
            flattened = element(FB, tag(result), **result.attrib)
            flatten(result, flattened)
            if has_line_breaks:
                flattened.set('style', FB2_TABLE_LINE_STYLE)
            return flattened
        def convert(node, path, *, include_hidden=False):
            nonlocal margin_rule_count, converted_text_frames
            if not include_hidden and node in hidden_navigation:
                return []
            name, original_name = tag(node), node.get('data-fb2', '')
            captions = []
            if original_name:
                allowed = {'body', 'section', 'title', 'p', 'subtitle', 'poem', 'stanza', 'v', 'cite', 'epigraph', 'annotation', 'text-author', 'date', 'strong', 'emphasis', 'strikethrough', 'sub', 'sup', 'code', 'style', 'a', 'table', 'tr', 'td', 'th', 'image', 'empty-line'}
                if original_name not in allowed: raise ConversionError('Неизвестный исходный элемент FB2.')
                try: attributes = json.loads(node.get('data-fb2-attributes', '{}'))
                except ValueError as error: raise ConversionError('Повреждены исходные атрибуты FB2.') from error
                if not isinstance(attributes, dict) or not all(isinstance(k, str) and isinstance(v, str) for k,v in attributes.items()): raise ConversionError('Неверные атрибуты FB2.')
                result = element(FB, original_name, **attributes)
                if original_name == 'image':
                    image(path, node.get('src', ''), node.get('data-fb2-image-id', ''))
                    return [result]
                if original_name == 'empty-line': return [result]
                result.text = node.text
                for child in node:
                    for mapped in convert(child, path): result.append(mapped)
                    append_text(result, child.tail)
                return [result]
            if name in {'script', 'style'}: return []
            marker = margin_rule_class(node)
            if marker:
                margin_rule_count += 1
                return [element(FB, 'style', name=marker)]
            if name == 'span' and not len(node) and not (node.text or '').strip():
                spacer = next((value for value in node.get('class', '').split() if word_spacer_dimensions(value)), '')
                if spacer:
                    return [element(FB, 'style', name=spacer)]
            if name == 'table':
                rows = [child for child in node if tag(child) == 'tr']
                removed = [0]
                for row in rows:
                    covered = row.get('data-homelib-merged-row') == '1' and not (
                        len(row) or plain(row) or row.get('id') or row.get('data-homelib-anchor'))
                    removed.append(removed[-1] + int(covered))
                if 0 < removed[-1] < len(rows):
                    # FB2 requires a cell in each row. Removing covered rows
                    # must shorten every span that crosses them.
                    for index, row in enumerate(rows):
                        if removed[index + 1] != removed[index]:
                            node.remove(row)
                            continue
                        for cell in row:
                            value = cell.get('rowspan', '')
                            if not re.fullmatch(r'[0-9]{1,10}', value):
                                continue
                            span = int(value)
                            if span < 2:
                                continue
                            end = min(index + span, len(rows))
                            new_span = span - (removed[end] - removed[index])
                            if new_span > 1:
                                cell.set('rowspan', str(new_span))
                            else:
                                cell.attrib.pop('rowspan')
                    warnings.add('Строки таблицы, полностью занятые объединёнными ячейками, '
                                 'сокращены при сохранении в FB2. Содержимое ячеек сохранено.')
                nested = any(tag(child) == 'table' for child in node.iter() if child is not node)
                if nested or malformed_table(node):
                    # Preserve the reading order and anchors when FB2 cannot represent the table structure.
                    linear = copy.deepcopy(node)
                    for part in linear.iter():
                        if tag(part) in table_parts:
                            part.tag = '{' + XH + '}div'
                    label = 'Вложенные таблицы' if nested else 'Нестандартные таблицы'
                    warnings.add(label + ' представлены последовательными блоками FB2. Текст, изображения и ссылки сохранены; расположение строк и столбцов изменилось.')
                    return convert(linear, path)
            if name in {'colgroup', 'col'}:
                for column in node.iter():
                    if (column.attrib.keys() & {'width', 'align', 'valign', 'bgcolor', 'char', 'charoff'}
                            or css_declarations(column).keys() - {'display'}):
                        warnings.add('Размеры или оформление столбцов EPUB могут отличаться в FB2. '
                                     'Строки, ячейки и содержимое таблицы сохранены.')
                        break
                return []
            if name in {'tbody', 'thead', 'tfoot'}:
                return [mapped for child in node for mapped in convert(child, path)]
            if name == 'svg':
                label = ' '.join(plain(n) for n in node if tag(n) in {'title', 'desc'} and plain(n))
                composition = svg_background_picture(node)
                if composition and svg_viewport_css(node):
                    width, height, fill, reference = composition
                    drawing = element(SVG, 'svg', width=width, height=height, viewBox=f'0 0 {width} {height}')
                    drawing.append(element(SVG, 'rect', width=width, height=height, fill=fill))
                    drawing.append(element(SVG, 'image', width=width, height=height))
                    rendered = render_svg_raster(path, drawing, reference)
                    if rendered is not None:
                        identifier, _ = rendered
                        warnings.add('Композиция SVG сохранена в PNG вместе с её фоном.')
                        attributes = {f'{{{XL}}}href': '#' + identifier}
                        if label:
                            attributes['alt'] = label
                        return [element(FB, 'image', **attributes)]
                images = [n for n in node if tag(n) == 'image']
                if len(images) == 1 and all(tag(n) in {'image', 'title', 'desc'} for n in node):
                    picture = images[0]
                    label = label or picture.get('alt', '')
                    placed = any(picture.get(axis, '0') not in {'0', '0.0'} for axis in ('x', 'y'))
                    sizing = svg_picture_sizing(node, picture)
                    resized = bool(sizing) and any(float(value[:-1]) != 100 for value in sizing.values())
                    transformed = (sizing is None or
                                   svg_changes_appearance(node) or svg_changes_appearance(picture))
                    cropped = False
                    if node.get('viewBox'):
                        try:
                            left, top, width, height = map(float, re.split(r'[\s,]+', node.get('viewBox').strip()))
                            cropped = (left != 0 or top != 0 or width != float(picture.get('width', str(width)))
                                       or height != float(picture.get('height', str(height))))
                        except ValueError:
                            cropped = True
                    reference = picture.get('{' + XL + '}href') or picture.get('href', '')
                    drawing = None
                    intrinsic = None
                    relative_width = 0
                    if transformed and not (cropped or placed):
                        intrinsic = reflowable_svg_viewport(path, node, picture, reference)
                        if intrinsic is not None:
                            size, same_ratio = intrinsic
                            width_percent = svg_width_percent_x100(node.get('width', '100%'))
                            if 0 < width_percent < 10000:
                                relative_width = width_percent
                            transformed = not same_ratio
                            if transformed and max(size) <= 4096:
                                width, height = map(str, size)
                                drawing = element(SVG, 'svg', width=width, height=height, viewBox=f'0 0 {width} {height}')
                                drawing.append(element(SVG, 'image', width=width, height=height))
                    if not transformed and (cropped or placed or resized) and svg_viewport_css(node, picture if resized else None):
                        styles = viewport_stylesheets(path, attached_styles.get(path, ())) if resized else []
                        if styles is not None and svg_cover_styles_preserve_ratio(styles, [], node):
                            drawing = svg_cropped_raster(node, picture, sizing)
                    def svg_picture(attributes):
                        picture = element(FB, 'image', **attributes)
                        if not relative_width:
                            return picture
                        layout = element(FB, 'style', name=f'{FB2_IMAGE_WIDTH_PREFIX}{relative_width}')
                        layout.append(picture)
                        return layout

                    if drawing is not None:
                        rendered = render_svg_raster(path, drawing, reference, preserve_resolution=intrinsic is not None)
                        if rendered is not None:
                            identifier, source_image = rendered
                            attributes = {f'{{{XL}}}href': '#' + identifier}
                            if label:
                                attributes['alt'] = label
                            # An EPUB 3 manifest may identify the cover bitmap alone.
                            # Match its authored rendering on the first reading page.
                            if path in cover_resources or (relative_width and reading_spine[:1] == [path]):
                                cropped_covers.setdefault(path, {})[identifier] = source_image
                            if resized or relative_width or intrinsic is not None:
                                embed_image(source_image)
                            warnings.add('Область просмотра SVG сохранена в PNG с исходными размерами размещения.' if resized else
                                         'Область просмотра SVG сохранена в PNG с исходными пропорциями.' if intrinsic else
                                         'Область просмотра SVG сохранена в PNG с авторской обрезкой.')
                            return [svg_picture(attributes)]
                    if transformed or cropped or placed or resized:
                        if not allow_partial_epub:
                            kind = 'Преобразованное' if transformed or placed or resized else 'Обрезанное'
                            raise ConversionError(f'{kind} изображение SVG нельзя сохранить в FB2 без потери оформления. Выберите «Оставить EPUB».')
                        relative_width = 0
                        picture_name = image_label(path, reference, label)
                        warnings.add(f'Оформление иллюстрации SVG упрощено: «{picture_name[:120]}». Переносится исходное изображение без обрезки и преобразования.')
                    identifier = image(path, reference, recover=True)
                    if identifier is None: return [missing_picture(image_label(path, reference, label))]
                    attributes = {'{' + XL + '}href': '#' + identifier}
                    if label: attributes['alt'] = label
                    warnings.add('SVG-обёртка изображения EPUB заменена исходным изображением без изменения его данных.')
                    return picture_with_recovery_note(svg_picture(attributes), identifier)
                if allow_partial_epub:
                    return [missing_picture(label or f'Векторная иллюстрация из раздела «{posixpath.basename(path)}».')]
                raise ConversionError('Векторную композицию SVG нельзя сохранить в FB2 без потери содержимого. Выберите «Оставить EPUB».')
            if allow_partial_epub and name in {'audio', 'video'}:
                media, label = epub_media_label(node)
                warnings.add(f'{media} EPUB не перенесено: «{label}».')
                result = []
                poster = node.get('poster')
                if poster:
                    identifier = image(path, poster, recover=True)
                    result.append(element(FB, 'image', **{'{' + XL + '}href': '#' + identifier, 'alt': label})
                                  if identifier else missing_picture(label))
                result.append(element(FB, 'p', f'[{media} «{label}» доступно в исходной книге.]'))
                fallback = element(FB, 'p', node.text)
                for child in node:
                    if tag(child) not in {'source', 'track'}:
                        fallback.extend(convert(child, path))
                    append_text(fallback, child.tail)
                if len(fallback) or plain(fallback).strip():
                    result.append(fallback)
                for track in children(node, 'track'):
                    for paragraph in epub_subtitle_paragraphs(archive, path, track, media_resources, warnings):
                        result.extend(convert(paragraph, path))
                return result
            if name == 'math' and node in rendered_math:
                bitmap, width, height = rendered_math[node]
                if bitmap not in image_ids:
                    add_image(bitmap, 'image/png', bitmap.read_bytes(), 'formula_' + str(len(image_ids) + 1))
                picture = element(FB, 'image', alt=math_module.label(node), **{'{' + XL + '}href': '#' + image_ids[bitmap]})
                warnings.add(f'Формулы EPUB сохранены как изображения с текстовым описанием ({len(rendered_math)}). '
                             'Для редактирования формул используйте исходный EPUB.')
                if not preserve_image_placement:
                    return [picture]
                extent = element(FB, 'style', name=f'{FB2_IMAGE_SIZE_PREFIX}{width}-{height}')
                extent.append(picture)
                return [extent]
            if allow_partial_epub and name in {'object', 'iframe', 'math'}:
                reference = node.get('data') if name == 'object' else node.get('src')
                reference_path = unquote(urlsplit(reference or '').path)
                bundle = next((part[:-5] for part in reference_path.split('/') if part.lower().endswith('.wdgt')), '')
                is_widget = bundle or node.get('type', '').lower() == 'application/x-ibooks+widget'
                kind = 'формула' if name == 'math' else 'встроенный объект'
                label = (node.get('title') or bundle or node.get('id') or posixpath.basename(reference_path)
                         or (math_module.label(node) if name == 'math' else kind))[:120]
                if is_widget:
                    warnings.add(f'Виджет Apple Books не перенесён: «{label}».')
                else:
                    warnings.add(f'Элемент EPUB не перенесён: {kind} «{label}» в разделе «{posixpath.basename(path)}».')
                preview = [piece for picture in node.iter() if tag(picture) == 'img' for piece in convert(picture, path)]
                preview.append(element(FB, 'p', f'[«{label}» доступно в исходной книге.]'))
                if name == 'math':
                    if math_error:
                        warnings.add('Элемент EPUB не перенесён как иллюстрация. ' + math_error)
                    preview.append(element(FB, 'p', math_module.label(node)))
                elif plain(node):
                    preview.append(element(FB, 'p', plain(node)))
                return preview
            if name in {'audio', 'video', 'math', 'object', 'iframe'}:
                if name == 'math' and math_error:
                    raise ConversionError(math_error + ' Можно сохранить исходный EPUB.')
                raise ConversionError(f'Элемент EPUB нельзя сохранить в FB2 без потери содержимого: {name}. Выберите «Оставить EPUB».')
            is_note = node.get('data-homelib-anchor') in note_anchors or bool(set(node.get('{' + EP + '}type', '').split()) & {'footnote', 'endnote'}) or node.get('role') in {'doc-footnote', 'doc-endnote'}
            if is_note or name in {'section', 'article', 'nav'} or include_hidden and name == 'li':
                mapped_name = 'section'
            else:
                mapped_name = block_mapping.get(name) or inline_mapping.get(name)
            if name == 'img':
                picture_classes = node.get('class', '').split()
                preferred = ''
                for marker, prefix in (('paragraph-rule', 'paragraph_rule_'), ('word-diagram-legend', 'word_diagram_legend_'),
                                       ('word-diagram', 'word_diagram_'), ('word-textbox-left', 'word_textbox_left_'),
                                       ('word-textbox', 'word_textbox_')):
                    if marker in picture_classes:
                        preferred = prefix + str(len(image_ids) + 1)
                        break
                reference = node.get('src', '')
                identifier = image(path, reference, preferred=preferred, recover=True)
                if identifier is None:
                    return [missing_picture(image_label(path, reference, node.get('alt', '').strip()))]
                attributes = {'{' + XL + '}href': '#' + identifier}
                if node.get('alt'): attributes['alt'] = node.get('alt')
                picture = element(FB, 'image', **attributes)
                if EPUB_LIST_MARKER_STYLE in picture_classes:
                    marker = element(FB, 'style', name=EPUB_LIST_MARKER_STYLE)
                    marker.append(picture)
                    return picture_with_recovery_note(marker, identifier)
                if WORD_CANVAS_STYLE in picture_classes:
                    canvas = element(FB, 'style', name=WORD_CANVAS_STYLE)
                    width, height = (html_image_pixels(node.get(axis)) for axis in ('width', 'height'))
                    if width or height:
                        dimensions = element(FB, 'style', name=f'{FB2_IMAGE_SIZE_PREFIX}{width}-{height}')
                        dimensions.append(picture)
                        canvas.append(dimensions)
                    else:
                        canvas.append(picture)
                    if WORD_LEGEND_STYLE in picture_classes:
                        legend = element(FB, 'style', name=WORD_LEGEND_STYLE)
                        legend.append(canvas)
                        canvas = legend
                    return picture_with_recovery_note(canvas, identifier)
                rule = next((marker for marker in picture_classes if word_rule_height(marker) or word_line_geometry(marker)), '')
                if rule:
                    extent = element(FB, 'style', name=rule)
                    extent.append(picture)
                    return picture_with_recovery_note(extent, identifier)
                if not preserve_image_placement:
                    return picture_with_recovery_note(picture, identifier)
                width, height = (html_image_pixels(node.get(key)) for key in ('width', 'height'))
                natural_width, natural_height = image_sizes[identifier]
                original_height = jpeg_original_heights.get(identifier, 0)
                if height and 0 < natural_height < original_height:
                    height = max(1, round(height * natural_height / original_height))
                if width in (0, natural_width) and height in (0, natural_height):
                    return picture_with_recovery_note(picture, identifier)
                extent = element(FB, 'style', name=f'{FB2_IMAGE_SIZE_PREFIX}{width}-{height}')
                extent.append(picture)
                return picture_with_recovery_note(extent, identifier)
            if name == 'br':
                return [element(FB, 'empty-line')]
            level = html_heading_level(node) or outline_headings.get(node, 0)
            if level:
                result = element(FB, 'title'); paragraph = element(FB, 'p'); result.append(paragraph)
                heading_levels[result] = level
                paragraph.text = node.text
                for child in node:
                    for mapped in convert(child, path): paragraph.append(mapped)
                    append_text(paragraph, child.tail)
                if node in outline_headings: styled(node, paragraph)
            elif name == 'li' and node in list_prefixes:
                result = flow(node, element(FB, 'section'), path)
                paragraph = result[0] if len(result) and tag(result[0]) == 'p' else None
                if paragraph is None: paragraph = element(FB, 'p'); result.insert(0, paragraph)
                label, marker_id = list_prefixes[node]
                if marker_id:
                    prefix = element(FB, 'style', name=EPUB_LIST_MARKER_STYLE)
                    prefix.append(element(FB, 'image', **{'{' + XL + '}href': '#' + marker_id}))
                    note = jpeg_notices.get(marker_id)
                    prefix.tail = ' ' + (f'[{note}] ' if note else '') + (paragraph.text or '')
                    paragraph.text = None
                    paragraph.insert(0, prefix)
                else:
                    paragraph.text = label + (paragraph.text or '')
            elif mapped_name:
                result = element(FB, mapped_name)
                if mapped_name in {'section', 'cite'}: flow(node, result, path)
                else:
                    result.text = node.text
                    for child in node:
                        if name == 'table' and tag(child) == 'caption': captions.extend(convert(child, path))
                        else:
                            for mapped in convert(child, path): result.append(mapped)
                            append_text(result, child.tail)
                if mapped_name == 'table' and not len(result):
                    result.tag = '{' + FB + '}p'
                    warnings.add('Таблицы без строк заменены пустыми абзацами при сохранении в FB2.')
                if mapped_name == 'tr' and not len(result):
                    result.append(element(FB, 'td'))
            elif name in {'ul', 'ol'}:
                numbered = node not in navigation_lists or any(key in node.attrib for key in {'start', 'reversed', 'type'})
                if numbered:
                    warnings.add('Списки EPUB записаны отдельными абзацами с сохранением нумерации.')
                # Older HTML can wrap list items in a div or put text between
                # them. Copy that content in place and number the actual items.
                entries = list(list_entries(node)); reverse = 'reversed' in node.attrib
                try: index = int(node.get('start', str(len(entries) if reverse else 1)))
                except ValueError: raise ConversionError('Некорректная нумерация списка EPUB.')
                for child in entries:
                    if child in hidden_navigation:
                        continue
                    try: index = int(child.get('value', str(index)))
                    except ValueError: raise ConversionError('Некорректный номер пункта EPUB.')
                    visual = list_style(child,path)
                    style = visual['list-style-type'][0]
                    reference, origin = visual['list-style-image']
                    label = epub_list_label(style,index) if numbered else ''
                    marker_id = None
                    if numbered and reference != 'none':
                        marker_id = image(origin,reference,recover=True)
                        if marker_id is None:
                            message = (f'Ресурс оформления EPUB не перенесён: «{reference[:120]}». '
                                       'В списке оставлен текстовый маркер, если он указан.')
                            if not allow_partial_epub:
                                raise ConversionError(message)
                            warnings.add(message)
                    list_prefixes[child] = label, marker_id
                    index += -1 if reverse else 1
                result = flow(node, element(FB, 'section'), path)
            elif name == 'pre':
                if TEXT_FRAME_STYLE in node.get('class', '').split() and not len(node) and node.text:
                    converted_text_frames = True
                    paragraphs = []
                    for line in node.text.split('\n'):
                        paragraph = element(FB, 'p', style=TEXT_FRAME_STYLE)
                        paragraph.append(element(FB, 'code', line))
                        paragraphs.append(paragraph)
                    if anchor := node.get('data-homelib-anchor'):
                        paragraphs[0].set('id', anchor)
                    if is_note:
                        paragraphs[0].set('data-homelib-note', '1')
                    return paragraphs
                result = element(FB, 'p')
                code = element(FB, 'code', node.text)
                for child in node:
                    code.extend(convert(child, path))
                    append_text(code, child.tail)
                result.append(code)
            else:
                # Formatting containers are transparent; keep all their text/tails.
                result = element(FB, 'section' if name in {'div', 'aside', 'header', 'footer', 'figure', 'dl', 'dd'} else 'p' if name in {'figcaption', 'li', 'hr'} else 'style')
                if tag(result) == 'style': result.set('name', 'epub-inline')
                if tag(result) == 'section': flow(node, result, path)
                else:
                    result.text = node.text
                    for child in node:
                        for mapped in convert(child, path): result.append(mapped)
                        append_text(result, child.tail)
            anchor = node.get('data-homelib-anchor')
            if anchor:
                if tag(result) == 'title': result[0].set('id', anchor)
                else: result.set('id', anchor)
            if is_note: result.set('data-homelib-note', '1')
            if name == 'a':
                href = node.get('href')
                target, fragment = link_target(path, href) if href is not None else (None, '')
                if target:
                    if (target, fragment) not in available:
                        media = image_types.get(target) or mimetypes.guess_type(target)[0] or ''
                        picture = None
                        if not fragment and media.startswith('image/') and media not in EPUB_MISLABELED_XHTML_TYPES:
                            picture = embed_image(target, recover=True)
                        if picture:
                            anchor = picture_link_targets.setdefault('#' + picture, base_identity(target))
                            href = '#' + anchor
                        else:
                            warnings.add(f'Не найдена цель ссылки EPUB «{href[:160]}». Текст ссылки сохранён.')
                            href = None
                    else:
                        if (target, fragment) in table_alias_targets:
                            warnings.add('Переходы внутри строк и ячеек таблиц FB2 ведут к началу ячеек. Подписи и ссылки сохранены.')
                        href = '#' + identity(target, fragment)
                if href:
                    result.set('{' + XL + '}href', href)
                    if (target, fragment) in notes: result.set('type', 'note')
                else:
                    result.tag = '{' + FB + '}style'
                    result.set('name', 'epub-inline')
            if tag(result) in {'td', 'th', 'tr'} and node.get('align'):
                result.set('align', node.get('align'))
            if tag(result) in {'td', 'th'}:
                for key in ('colspan', 'rowspan'):
                    if node.get(key):
                        result.set(key, node.get(key))
                result = table_cell(result)
            if tag(result) in {'table', 'td', 'th'}:
                style = resolved_table_style(table_style_layers(node, path), table=tag(result) == 'table')
                # An empty or transparent fill needs no override when the source's
                # remaining background rule was flattened into this cell.
                if style == ['background-color:transparent']:
                    style.clear()
                if style:
                    result.set('style', ';'.join(filter(None, (result.get('style'), *style))))
            result = styled(node, result)
            if tag(result) in {'p', 'title'}:
                names = [value for value in node.get('class', '').split()
                         if word_list_css(value) or value.startswith(WORD_SPACER_PARAGRAPH) and word_spacer_css(value)]
                if names:
                    paragraph = result[0] if tag(result) == 'title' else result
                    paragraph.set('style', ' '.join(names))
            if name == 'a' and tag(result) == 'a':
                if len(result) == 1 and not (result.text or '').strip():
                    extent = result[0]
                    if (tag(extent) == 'style' and fb2_image_has_layout(extent.get('name', ''))
                            and len(extent) == 1 and tag(extent[0]) == 'image'):
                        # A link's style has no name in FB2. When the link is
                        # just a picture, put the named style around the link.
                        picture = extent[0]
                        picture.tail, extent.tail = extent.tail, None
                        extent.remove(picture); result.remove(extent)
                        result.append(picture); extent.append(result)
                        return captions + [extent]
                return captions + split_nested_fb2_links(result, node.get('href'), warnings)
            return captions + [result]
        preserved_bodies = set()
        previous_original_body = None
        unchanged_cover_path = None
        staged_sections = []
        anchor_redirects = {}
        streamed_sizes = Counter()
        streamed_spacer_styles = {}
        quote_sections = set()
        used_quote_ids = set()
        next_quote_id = 0

        def record_quotation(section):
            nonlocal next_quote_id
            identity = section.get('id')
            if not identity:
                while not identity or identity in used_quote_ids:
                    next_quote_id += 1
                    identity = f'homelibre-quote-{next_quote_id}'
                section.set('id', identity)
            used_quote_ids.add(identity)
            quote_sections.add(identity)

        def picture_styles(tree):
            stats = Counter()
            styles = {}
            for link in tree.iter('{' + FB + '}a'):
                for node in link.iter('{' + FB + '}style'):
                    marker = node.attrib.pop('name', '')
                    if fb2_image_has_layout(marker):
                        stats['unsized_images'] += 1
                    if word_spacer_dimensions(marker):
                        node.text = '\u00a0'
                        stats['unsized_spacers'] += 1
            for node in tree.iter('{' + FB + '}style'):
                marker = node.get('name', '')
                if word_spacer_dimensions(marker):
                    styles[f'style[name="{marker}"]'] = word_spacer_css(marker)
                elif width := fb2_relative_image_width(marker):
                    styles[f'style[name="{marker}"] image'] = relative_image_css(width)
                stats['sized_images'] += bool(fb2_image_has_layout(marker))
                stats['margin_rules'] += bool(margin_rule_geometry(marker))
            for paragraph in tree.iter('{' + FB + '}p'):
                name = paragraph.get('style', '')
                rules = []
                for marker in name.split():
                    if css := word_list_css(marker):
                        rules.append(css)
                    elif marker.startswith(WORD_SPACER_PARAGRAPH) and (css := word_spacer_css(marker)):
                        rules.append(css)
                if rules:
                    styles[f'p[style="{name}"]'] = ';'.join(rules)
            return stats, styles

        def matches_fb2_cover(path, body):
            if preserved_description is None or body.attrib != FB2_COVER_PAGE_ATTRIBUTES or plain(body):
                return False
            title_info = first(preserved_description, 'title-info')
            cover = first(title_info, 'coverpage') if title_info is not None else None
            if cover is None:
                return False
            pictures = children(cover, 'image')
            if not pictures or len(body) != len(pictures):
                return False
            title = plain(first(title_info, 'book-title')) or plain(first(metadata, 'title'))
            for node, picture in zip(body, pictures):
                if tag(node) != 'img' or len(node) or set(node.attrib) != {'src', 'alt'}:
                    return False
                reference = picture.get('{' + XL + '}href', '').lstrip('#')
                try:
                    address, fragment = archive.resolve(path, node.get('src'))
                except (ConversionError, ValueError):
                    return False
                if (not reference or fragment or image_ids.get(address) != reference or
                        node.get('alt') != picture.get('alt', title)):
                    return False
            return True

        # The original FB2 description already includes this cover. Keep the
        # reading page if it has edits or serves as a navigation destination.
        if documents and preserved_description is not None:
            path, first_body = documents[0]
            if path not in outline_titles and matches_fb2_cover(path, first_body):
                unchanged_cover_path = path
                for other_path, other_body in documents[1:]:
                    if unchanged_cover_path is None:
                        break
                    for link in other_body.iter('{' + XH + '}a'):
                        if not (reference := link.get('href')):
                            continue
                        try:
                            target, _ = link_target(other_path, reference)
                        except (ConversionError, ValueError):
                            continue
                        if target == path:
                            unchanged_cover_path = None
                            break
        for index, (path, source_body) in enumerate(read_documents()):
            if document_progress is not None and index % 8 == 0:
                document_progress('preparing-epub', index, len(documents))
            if path == unchanged_cover_path:
                continue
            original_body = next((n for n in source_body if n.get('data-fb2') == 'body'), None)
            if original_body is not None:
                converted_bodies = convert(original_body, path)
                if (original_body.get('data-homelib-fb2-continuation') == '1' and previous_original_body is not None
                        and len(converted_bodies) == 1 and not converted_bodies[0].text):
                    previous_original_body.extend(converted_bodies[0])
                    if original_body.get('data-homelib-fb2-normalize') == '1':
                        preserved_bodies.discard(previous_original_body)
                    continue
                book.extend(converted_bodies)
                previous_original_body = converted_bodies[-1] if converted_bodies else None
                if original_body.get('data-homelib-fb2-normalize') != '1': preserved_bodies.update(converted_bodies)
                continue
            previous_original_body = None
            body = first(book, 'body')
            if body is None:
                body = element(FB, 'body')
                if generated_sections is None:
                    book.append(body)
            root = element(FB, 'section', id=identity(path)); body.append(root)
            if generated_sections is not None:
                documents_by_path[path] = source_body
            flow(source_body, root, path)
            if generated_sections is not None:
                # This EPUB was generated from a CHM. All parts are in the spine,
                # with no publisher cover, hidden navigation or separate note body.
                wrapper = element(FB, 'FictionBook'); wrapper.append(body)
                anchor_redirects.update(normalize_fb2(wrapper, warnings=warnings, record_quotation=record_quotation))
                sizes, styles = picture_styles(wrapper)
                streamed_sizes.update(sizes)
                streamed_spacer_styles.update(styles)
                chapter = generated_sections / f'fb2-section-{len(staged_sections)}.xml'
                ET.ElementTree(root).write(chapter, encoding='utf-8')
                staged_sections.append(chapter)
                documents_by_path.pop(path)
                list_parents.pop(path, None)
                list_styles.clear()
                list_prefixes.clear()
                heading_levels.clear()
                if stream_images and (report := stream_images.get('progress')):
                    report('writing-fb2-sections', len(staged_sections), len(documents))
                continue
            converted_sections[path] = root
            if cover_page is None and path in cover_resources:
                cover_sections[path] = root
            elif preserved_description is None and path in cropped_covers:
                # A cover document may show a cropped view of its declared
                # metadata image. Use the same view in both FB2 locations.
                image_link = f'{{{XL}}}href'
                pictures = {node.get(image_link, '').removeprefix('#') for node in root.iter(f'{{{FB}}}image')}
                declared = children(cover_page, 'image')
                if len(pictures) == 1 and len(declared) == 1:
                    identifier = next(iter(pictures))
                    resource = cropped_covers[path].get(identifier)
                    original = image_ids.get(resource)
                    if original and declared[0].get(image_link) == '#' + original:
                        declared[0].set(image_link, '#' + identifier)
            if (path, '') in notes: root.set('data-homelib-note', '1')
        if cover_page is None and cover_resources:
            image_link = '{' + XL + '}href'
            for path in cover_resources:
                section = cover_sections.get(path)
                if section is None:
                    continue
                pictures = {n.get(image_link): n for n in section.iter('{' + FB + '}image') if n.get(image_link)}
                if len(pictures) == 1:
                    picture = next(iter(pictures.values()))
                    add_cover({key: picture.get(key) for key in (image_link, 'alt') if picture.get(key)})
                    break
            if cover_page is None:
                if any(plain(section).strip() or next(section.iter('{' + FB + '}image'), None) is not None
                       for section in cover_sections.values()):
                    warnings.add('Страница обложки EPUB перенесена в книгу без отдельной обложки FB2.')
                elif not unreadable_covers:
                    warnings.add('В исходном EPUB отсутствуют данные обложки.')
        if hidden_navigation:
            body = first(book, 'body')
            supplement = element(FB, 'section')
            for node, path in hidden_navigation.items():
                supplement.extend(convert(node, path, include_hidden=True))
            if len(supplement):
                body.append(supplement)
                warnings.add('Скрытая навигация EPUB перенесена в конец FB2. Подписи и переходы доступны после основного текста.')
        detached_notes = []
        def detach(parent):
            for child in list(parent):
                if child.attrib.pop('data-homelib-note', ''):
                    parent.remove(child)
                    for nested in child.iter(): nested.attrib.pop('data-homelib-note', None)
                    detached_notes.append(child)
                else: detach(child)
        for body in children(book, 'body'): detach(body)
        if detached_notes:
            note_body = element(FB, 'body', name='notes'); note_body.extend(detached_notes); book.append(note_body)
        # FB2 permits unreferenced binaries. Keep local publisher image
        # resources too, even when an alternate cover or decoration is unused.
        if preserved_description is None:
            for resource_id, item in items.items():
                resolved = paths[resource_id]
                mime = item.get('media-type', '')
                if (resolved is not None and resolved not in unreadable_covers and mime.startswith('image/')
                        and mime not in EPUB_MISLABELED_XHTML_TYPES):
                    if embed_image(resolved, recover=True) is None and not omitted_images:
                        warnings.add('Часть изображений EPUB недоступна. В исходнике отсутствуют объявленные ресурсы.')
            if css_sources:
                missing_css_resources = {}

                def packaged_css(path, css):
                    def css_picture(reference, original):
                        if not reference or reference.lower().startswith('data:image/'):
                            return original
                        warning = f'Ресурс оформления EPUB не перенесён: «{reference[:120]}». '
                        warning += f'Таблица стилей «{posixpath.basename(path)[:100]}».'
                        resolved = None
                        try:
                            resolved, fragment = archive.resolve(path, reference)
                            if resolved is not None:
                                identity = embed_image(resolved, recover=True)
                                if identity is not None:
                                    target = '#' + identity
                                    if fragment:
                                        target += '#' + quote(fragment, safe='')
                                    return f'url("{target}")'
                        except (ValueError, EpubOutsideResource) as error:
                            if not allow_partial_epub:
                                raise ConversionError(warning) from error
                        if not allow_partial_epub:
                            raise ConversionError(warning)
                        key = (resolved, '') if resolved is not None else (None, reference)
                        _, locations = missing_css_resources.setdefault(key, (warning, set()))
                        locations.add(path)
                        return 'none'
                    return rewrite_css_urls(css, css_picture)
                css = '\n'.join(packaged_css(path, css) for path, css in css_sources)
                for warning, locations in missing_css_resources.values():
                    if len(locations) > 1:
                        warning += f' Ресурс указан в нескольких файлах книги. Число файлов — {len(locations)}.'
                    warnings.add(warning)
                book.insert(0, element(FB, 'stylesheet', css, type='text/css'))
                warnings.add('FB2 передаёт основные стили текста; точное оформление CSS и встроенные шрифты EPUB зависят от читалки.')
        if converted_text_frames:
            selector = f'p[style="{TEXT_FRAME_STYLE}"]'
            book.insert(0, element(FB, 'stylesheet',
                                  f'{selector}{{{TEXT_FRAME_CSS}}}{selector} code{{white-space:pre;font-family:inherit}}',
                                  type='text/css'))
            warnings.add('Выравнивание таблиц и схем в FB2 зависит от поддержки стилей в читалке. '
                         'Чтобы сохранить расположение колонок и символов в других приложениях, выберите EPUB.')
        used_quote_ids.update(node.get('id') for node in book.iter() if node.get('id'))
        normalize_fb2(book, preserved_bodies, warnings, record_quotation)
        if quote_sections:
            entry = next((item for item in children(description, 'custom-info')
                          if item.get('info-type') == FB2_QUOTE_SECTIONS), None)
            if entry is None:
                entry = element(FB, 'custom-info', **{'info-type': FB2_QUOTE_SECTIONS})
                description.append(entry)
            entry.text = '\n'.join(sorted(quote_sections.union(plain(entry).split())))
        if picture_link_targets:
            href_attr = f'{{{XL}}}href'

            def place_picture_targets(tree):
                parents = {child: parent for parent in tree.iter() for child in parent}
                changed = False
                for picture in tree.iter(f'{{{FB}}}image'):
                    anchor = picture_link_targets.pop(picture.get(href_attr), None)
                    if anchor is None:
                        continue
                    host = picture
                    if tag(parents[picture]) not in {'body', 'section'}:
                        host = parents[picture]
                        while tag(host) not in {'p', 'subtitle', 'v', 'text-author', 'td', 'th', 'section'}:
                            host = parents[host]
                    current = host.get('id')
                    if current:
                        anchor_redirects[anchor] = current
                    else:
                        host.set('id', anchor)
                        changed = True
                    if not picture_link_targets:
                        break
                return changed

            for part in children(book, 'body'):
                if picture_link_targets:
                    place_picture_targets(part)
            for file in staged_sections:
                if not picture_link_targets:
                    break
                section = ET.parse(file)
                if place_picture_targets(section.getroot()):
                    section.write(file, encoding='utf-8')
            # A picture referenced only by a link still needs a readable destination.
            for reference, anchor in picture_link_targets.items():
                section = element(FB, 'section', id=anchor)
                paragraph = element(FB, 'p'); section.append(paragraph)
                paragraph.append(element(FB, 'image', **{href_attr: reference}))
                if generated_sections is None:
                    first(book, 'body').append(section)
                else:
                    file = generated_sections / f'fb2-section-{len(staged_sections)}.xml'
                    ET.ElementTree(section).write(file, encoding='utf-8')
                    staged_sections.append(file)
            if anchor_redirects and generated_sections is None:
                for link in book.iter(f'{{{FB}}}a'):
                    href = link.get(href_attr, '')
                    if href.startswith('#') and href[1:] in anchor_redirects:
                        link.set(href_attr, '#' + anchor_redirects[href[1:]])
        body = first(book, 'body')
        if body is not None and converted_sections:
            in_body = set(body)
            reading_order = [(path, converted_sections[path]) for path in reading_spine
                             if converted_sections.get(path) in in_body]
            repeat_epub_spine_sections(book, body, reading_order, archive, warnings, check)
            if cover_page is not None and preserved_description is None:
                # A cover retained from the guide or a non-linear spine entry
                # is also displayed in the FB2 body. Keep one visible copy.
                visible_sections = [section for _, section in reading_order]
                visible_sections.extend(section for path, section in converted_sections.items()
                                        if path in cover_resources and section in in_body)
                # A leading non-linear page can repeat the declared cover image
                # without a guide entry. Match its content rather than its name.
                cover_image_count = len(children(cover_page, 'image'))
                for itemref in spine:
                    if itemref.get('linear', '').lower() != 'no':
                        break
                    section = converted_sections.get(paths[itemref.get('idref')])
                    if (section in in_body and not plain(section) and
                            sum(1 for _ in section.iter(f'{{{FB}}}image')) == cover_image_count):
                        visible_sections.append(section)
                visible_cover = next((section for section in visible_sections
                                      if fb2_section_has_cover(section, cover_page)), None)
                if visible_cover is not None:
                    description.append(element(FB, 'custom-info', visible_cover.get('id'),
                                               **{'info-type': FB2_EPUB_COVER_IN_BODY}))
        # FB2 styleLinkType deliberately has no attributes, unlike named styles.
        sizes, spacer_styles = picture_styles(book)
        sizes.update(streamed_sizes)
        spacer_styles.update(streamed_spacer_styles)
        unsized_link_pictures = sizes['unsized_images']
        unsized_link_spacers = sizes['unsized_spacers']
        if unsized_link_spacers:
            warnings.add('Размеры пустых рамок внутри ссылок FB2 упрощены до пробела. Для сохранения размеров выберите EPUB.')
        if spacer_styles and preserved_description is None:
            rules = '\n'.join(f'{selector}{{{spacer_styles[selector]}}}' for selector in sorted(spacer_styles))
            book.insert(0, element(FB, 'stylesheet', rules, type='text/css'))
            if any(f'style[name="{WORD_SPACER_CLASS}' in selector for selector in spacer_styles):
                warnings.add('Размеры пустых рамок FB2 сохранены для HomeLibre Reader. В других читалках интервалы '
                             'зависят от поддержки стилей. Для сохранения интервалов выберите EPUB.')
        if unsized_link_pictures:
            warnings.add(f'Размеры размещения внутри составных ссылок не перенесены. '
                         f'Иллюстрации сохранены ({unsized_link_pictures}). Для сохранения размеров выберите EPUB.')
        sized_pictures = sizes['sized_images']
        if sized_pictures:
            warnings.add(f'Размеры размещения иллюстраций сохранены в FB2 для HomeLibre Reader ({sized_pictures}). '
                         'Другие читалки могут показывать рисунки в исходном размере. '
                         'Для чтения с заданными размерами в других приложениях выберите EPUB.')
        if margin_rule_count:
            preserved_rules = sizes['margin_rules']
            if preserved_rules < margin_rule_count:
                warnings.add(f'Не перенесены вертикальные линии на полях в FB2. '
                             f'Пропущено линий: {margin_rule_count - preserved_rules}.')
            if preserved_rules:
                warnings.add(f'Вертикальные линии на полях ({preserved_rules}) отображаются в HomeLibre Reader. '
                             'Другие читалки FB2 могут их скрывать.')
        # FB2 section titles remain visible in the text. Keep the separate publisher
        # list in valid metadata for the reader and subsequent EPUB export.
        if outline and preserved_description is None:
            body_ids = {node.get('id') for body in children(book, 'body') for node in body.iter() if node.get('id')}
            entries, missing = [], []
            for path, fragment, label, depth in outline:
                anchor = identity(path, fragment) if fragment is not None else None
                if anchor in body_ids:
                    entries.append(f'{anchor}\t{depth}\t' + ' '.join(label.split()))
                else:
                    missing.append(label)
            if entries:
                payload = '\n'.join(entries)
                if len(payload) <= MAX_OUTLINE_METADATA:
                    description.append(element(FB, 'custom-info', payload, **{'info-type': FB2_EPUB_OUTLINE}))
                else:
                    missing = [label for _, _, label, _ in outline]
            if missing:
                examples = ', '.join('«' + label[:100] + '»' for label in missing[:3])
                warnings.add(f'Не перенесены переходы оглавления EPUB ({len(missing)}): {examples}.')
        if stream_images is None:
            book.extend(binaries)
            ET.ElementTree(book).write(output, encoding='utf-8', xml_declaration=True)
        else:
            write_fb2_resources(book, output, archive, binaries, warnings, **stream_images,
                                sections=staged_sections if generated_sections is not None else None,
                                anchor_redirects=anchor_redirects)
    finally:
        archive.close()
        if composition_cache is not None:
            composition_cache.cleanup()
        if staged_images is not None:
            staged_images.cleanup()


def text_to_book(source, output, warnings, target_extension, *, stream_fb2=False, cancel_check=None, **metadata):
    spec = importlib.util.spec_from_file_location('homelib_text_inputs', Path(__file__).with_name('text_inputs.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    # The CLI is launched with -I: load the adjacent, shipped module explicitly.
    # Tests can import this file under an arbitrary module name too.
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    if target_extension == '.epub': module.to_epub(source, output, warnings, api, cancel_check=cancel_check, **metadata)
    else:
        with tempfile.TemporaryDirectory(prefix='homelib-text-',dir=output.parent) as directory:
            intermediate = Path(directory) / 'reading.epub'
            spooled = module.to_epub(source, intermediate, warnings, api, cancel_check=cancel_check, **metadata)
            stream_images = dict(check=cancel_check, progress=metadata.get('progress')) if stream_fb2 else None
            # Office intermediates also use dimensions for generated previews.
            # Those keep their existing FB2 layout and loss reporting.
            source_extension = metadata.get('input_extension') or Path(source).suffix.lower()
            preserve_image_placement = source_extension in {
                '.html', '.htm', '.shtml', '.xhtml', '.mht', '.mhtml', '.chm', '.rtf',
            }
            # Scan navigation carries the source's order and bookmark depth.
            # The other intermediates already carry their headings in the body.
            epub_to_fb2(intermediate, output, warnings,
                        use_navigation=source_extension in BOOK_SCAN_INPUTS or bool(metadata.get('document_outline')),
                        stream_images=stream_images,
                        maximum_total=MAX_SCAN_EPUB_RESOURCES + MAX_FILE if stream_fb2 else None,
                        preserve_image_placement=preserve_image_placement,
                        generated_sections=Path(directory) if stream_fb2 and spooled else None)
            return stream_fb2 and spooled


def kindle_xhtml(data):
    """Repair known KindleUnpack markup omissions without changing book text."""
    try:
        return xhtml(data), False
    except ConversionError as error:
        if 'unbound prefix' not in str(error):
            raise
        repaired = re.sub(rb'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<mbp:pagebreak\s*/>',
                          lambda match: b'<br/>' if match.group().startswith(b'<mbp:pagebreak') else match.group(), data)
        if repaired != data:
            try:
                return xhtml(repaired), True
            except ConversionError as remaining:
                if 'unbound prefix' not in str(remaining):
                    raise
            data = repaired
        # KindleUnpack supplies UTF-8 XHTML. Keep unknown prefixes and other
        # malformed XML as errors rather than guessing their meaning.
        root = re.search(rb'''<(?:html:)?html\b(?:[^<>"']|"[^"]*"|'[^']*')*>''', data)
        if root is None:
            raise
        declarations = []
        for prefix, uri in ((b'html', b'http://www.w3.org/1999/xhtml'),
                            (b'epub', b'http://www.idpf.org/2007/ops')):
            if prefix + b':' in data and not re.search(rb'\bxmlns:' + prefix + rb'\s*=', root.group()):
                declarations.append(b' xmlns:' + prefix + b'="' + uri + b'"')
        if not declarations:
            raise
        repaired = data[:root.end()-1] + b''.join(declarations) + data[root.end()-1:]
        return xhtml(repaired), True


def escape_kindle_ampersands(data):
    return re.sub(rb'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|&(?!#\d+;|#x[0-9a-fA-F]+;|[A-Za-z_:][\w:.-]*;)',
                  lambda match: b'&amp;' if match.group() == b'&' else match.group(), data)


def kindle_generated_xhtml(data):
    """Escape bare ampersands in KindleUnpack's generated XHTML."""
    try:
        return kindle_xhtml(data)
    except ConversionError as error:
        if 'invalid token' not in str(error): raise
        # The unpacker inserts titles and INDX labels without XML escaping.
        repaired = escape_kindle_ampersands(data)
        if repaired == data: raise
        document, _ = kindle_xhtml(repaired)
        return document, True


def kindle_epub(source, output, warnings=None):
    """Keep KindleUnpack resources, repair its known EPUB 3 packaging omissions."""
    archive = EpubArchive(source)
    try:
        container = xml(archive.read('META-INF/container.xml'))
        roots = [n for n in container.iter() if tag(n) == 'rootfile']
        if len(roots) != 1: raise ConversionError('В результате KindleUnpack нет однозначного описания EPUB.')
        package_path = archive.resolve('container.xml', roots[0].get('full-path', ''))[0]
        package_data = archive.read(package_path)
        # KindleUnpack writes binary EXTH Container_Id values inside this
        # generated, explicitly informational XML comment. NUL/invalid UTF-8
        # there must not invalidate the real OPF metadata or the book. Remove
        # only that complete known comment; all actual XML stays strict.
        package_data = re.sub(rb'<!-- BEGIN INFORMATION ONLY .*?END INFORMATION ONLY -->',
                              b'', package_data, flags=re.DOTALL)
        try:
            package = xml(package_data)
        except ConversionError as error:
            if 'invalid token' not in str(error):
                raise
            repaired = escape_kindle_ampersands(package_data)
            if repaired == package_data:
                raise
            package = xml(repaired)
            if warnings is not None:
                warnings.add('В описании пакета Kindle восстановлено XML-экранирование.')
        manifest = first(package, 'manifest')
        spine = first(package, 'spine')
        if manifest is None or spine is None:
            raise ConversionError('В результате KindleUnpack нет манифеста или порядка чтения EPUB.')
        manifest_ids = {item.get('id') for item in manifest}
        for entry in spine:
            if entry.get('idref') != 'x_ref_cover' or 'x_ref_cover' in manifest_ids or entry.get('linear') != 'no':
                continue
            guide = first(package, 'guide')
            cover_paths = {archive.resolve(package_path, node.get('href', ''))[0]
                           for node in guide if node.get('type') == 'cover'} if guide is not None else set()
            cover_paths.intersection_update(archive.names)
            cover_ids = [item.get('id') for item in manifest if item.get('id') and
                         item.get('media-type') == 'application/xhtml+xml' and
                         archive.resolve(package_path, item.get('href', ''))[0] in cover_paths]
            if len(cover_ids) != 1:
                raise ConversionError('Не удалось однозначно восстановить ссылку на обложку Kindle.')
            entry.set('idref', cover_ids[0])
            if warnings is not None:
                warnings.add('Восстановлена ссылка на страницу обложки Kindle.')
        changed = {}
        omitted_images = 0
        for item in manifest:
            if item.get('media-type') != 'application/xhtml+xml': continue
            part = archive.resolve(package_path, item.get('href', ''))[0]
            navigation = 'nav' in item.get('properties', '').split()
            document, dirty = kindle_generated_xhtml(archive.read(part))
            if dirty and warnings is not None:
                warnings.add('В оглавлении Kindle восстановлено XML-экранирование или стандартные пространства имён.' if navigation else
                             'В разметке Kindle исправлены служебные теги или специальные символы.')
            for node in document.iter():
                if 'cid' in node.attrib: node.attrib.pop('cid'); dirty = True
                href = node.get('href', '')
                name = tag(node)
                if name == 'img' and any(
                    node.get(attr, '').lower().startswith('kindle:embed:') for attr in ('src', 'href', '{'+XL+'}href')
                ):
                    omitted_images += 1
                    alt = (node.get('alt') or '').strip()
                    node.tag = '{' + XH + '}span'
                    for attr in ('src', 'href', '{'+XL+'}href', 'alt', 'srcset'):
                        node.attrib.pop(attr, None)
                    node.text = f'[Изображение {omitted_images} недоступно.]' + (' ' + alt if alt else '')
                    dirty = True
                    if warnings is not None:
                        warnings.add('Часть изображений Kindle недоступна. На их местах стоят отметки.')
                        warnings.add(f'Изображение {omitted_images} недоступно.' + (' ' + alt[:160] if alt else ''))
                if name == 'a' and re.fullmatch(r'X{24,}', href) and archive.resolve(part, href)[0] not in archive.names:
                    # KindleUnpack leaves this marker when its link index has no usable destination.
                    node.tag = '{' + XH + '}span'
                    node.attrib.pop('href')
                    dirty = True
                    if warnings is not None:
                        warnings.add('У некоторых ссылок Kindle отсутствует адрес перехода. Текст ссылок сохранён.')
            if any(n.tag == '{http://www.w3.org/2000/svg}svg' for n in document.iter()):
                properties = set(item.get('properties', '').split()); properties.add('svg')
                item.set('properties', ' '.join(sorted(properties)))
            if dirty: changed[part] = serialized(document)
        changed[package_path] = serialized(package)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as result:
            result.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            for entry in archive.archive.infolist():
                if entry.filename == 'mimetype': continue
                result.writestr(entry.filename, changed.get(entry.filename, archive.read(entry.filename)))
    finally:
        archive.archive.close()


def mobi_navigation(html, warnings):
    ncx = html.with_name('toc.ncx')
    if not ncx.is_file():
        return []
    try:
        if ncx.stat().st_size > MAX_FILE:
            raise ConversionError('Оглавление MOBI превышает допустимый размер.')
        navigation = first(xml(ncx.read_bytes()), 'navMap')
    except (ConversionError, OSError):
        warnings.add(MOBI_NAVIGATION_LOSS + '. Не удалось прочитать исходное оглавление.')
        return []
    pending = [(point, 1) for point in reversed(children(navigation, 'navPoint'))] if navigation is not None else []
    entries = []
    while pending:
        point, depth = pending.pop()
        content = first(point, 'content')
        label = plain(first(point, 'navLabel'))
        if content is not None and label:
            try:
                reference = urlsplit(content.get('src', ''))
            except ValueError:
                reference = None
            if (reference is not None and not reference.scheme and not reference.netloc and not reference.query
                    and unquote(reference.path) in {'', html.name} and reference.fragment):
                entries.append((unquote(reference.fragment), label, min(depth, 16)))
            else:
                warnings.add(MOBI_NAVIGATION_LOSS + '. Некоторые адреса в исходном оглавлении недоступны.')
        if len(entries) > MAX_ENTRIES:
            warnings.add(MOBI_NAVIGATION_LOSS + '. Число пунктов превышает допустимый предел.')
            return entries[:MAX_ENTRIES]
        pending.extend((child, depth + 1) for child in reversed(children(point, 'navPoint')))
    return entries


def mobi_package(html, warnings):
    opf = html.with_name('content.opf')
    if not opf.is_file():
        return None
    try:
        if opf.stat().st_size <= MAX_FILE:
            package = xml(escape_kindle_ampersands(opf.read_bytes()))
            if tag(package) == 'package' and first(package, 'metadata') is not None:
                return package
    except (ConversionError, OSError):
        pass
    warnings.add(MOBI_METADATA_LOSS)
    return None


def mobi_publication_metadata(package, asins):
    result = element(OP, 'metadata')
    if package is not None:
        fields = {'title', 'language', 'identifier', 'creator', 'contributor', 'publisher', 'source', 'subject',
                  'description', 'date', 'rights', 'type', 'format', 'relation', 'coverage'}
        op = '{' + OP + '}'
        unique_id = package.get('unique-identifier')
        xml_language = '{http://www.w3.org/XML/1998/namespace}lang'
        for index, node in enumerate(first(package, 'metadata'), 1):
            name = tag(node)
            if not node.tag.startswith('{' + DC + '}') or name not in fields or not (value := plain(node)):
                continue
            identifier = ''
            if name == 'identifier':
                if node.get(op + 'scheme', node.get('scheme', '')).casefold() == 'isbn':
                    value = value if value.casefold().startswith('urn:isbn:') else 'urn:isbn:' + value
                if unique_id and node.get('id') == unique_id and value != '0' and not any(n.get('id') == 'book-id' for n in result):
                    identifier = 'book-id'
            entry = element(DC, name, value)
            for attribute in (xml_language, 'dir'):
                if node.get(attribute):
                    entry.set(attribute, node.get(attribute))
            result.append(entry)
            for prop in ('role', 'file-as'):
                refinement = node.get(op + prop, node.get(prop, '')).strip()
                if not refinement:
                    continue
                identifier = identifier or f'kindle-publication-{index}'
                if prop == 'role' and re.fullmatch(r'[a-z]{3}', refinement):
                    result.append(element(OP, 'meta', refinement, property=prop, refines='#' + identifier, scheme='marc:relators'))
                else:
                    result.append(element(OP, 'meta', refinement, property=prop, refines='#' + identifier))
            if identifier:
                entry.set('id', identifier)
    for asin in asins:
        if isinstance(asin, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,128}', asin):
            result.append(element(OP, 'meta', asin, property='mhl:kindle-asin'))
    return result


def mobi_cover_asset(package, html, warnings):
    if package is None:
        return None
    metadata, manifest = first(package, 'metadata'), first(package, 'manifest')
    cover_ids = {node.get('content') for node in (() if metadata is None else children(metadata, 'meta'))
                 if node.get('name') == 'cover'}
    covers = [item for item in (() if manifest is None else children(manifest, 'item'))
              if item.get('id', '') in cover_ids or 'cover-image' in item.get('properties', '').split()]
    if not (covers or cover_ids):
        return None
    if len(covers) == 1 and covers[0].get('media-type', '').startswith('image/'):
        try:
            href = urlsplit(covers[0].get('href', ''))
            relative = unquote(href.path)
            if (relative and not href.scheme and not href.netloc and not href.query and not href.fragment
                    and '\\' not in relative and '\x00' not in relative):
                asset = (html.parent / relative).resolve()
                if asset.is_relative_to(html.parent / 'Images') and asset.is_file():
                    return asset
        except (OSError, ValueError):
            pass
    warnings.add('Повреждённая обложка MOBI: ссылка в исходнике не указывает на единственное доступное изображение.')
    return None


def kindle_to_book(source, output, warnings, target_extension, **metadata):
    with tempfile.TemporaryDirectory(prefix='homelib-kindle-convert-',dir=output.parent) as directory:
        root = Path(directory); manifest = root / 'result.json'; work = root / 'unpack'
        args = [sys.executable, '-I', '-B', str(Path(__file__).with_name('kindle_input.py')), str(source), str(manifest), str(work)]
        tools_root=Path(metadata.get('tools_root') or Path(__file__).resolve().parent.parent)
        if not (tools_root/'kindle/convert_kf8.py').is_file() or not (tools_root/'kindle/lib/kindleunpack.py').is_file():
            raise ComponentRequired(optional_component_id('Kindle', tools_root),
                                    'Для чтения этой книги нужен модуль KindleUnpack (MOBI/AZW/KF8).')
        with source.open('rb') as stream:
            header=stream.read(86)
            if len(header)==86 and header[60:68]==b'BOOKMOBI':
                count = int.from_bytes(header[76:78], 'big')
                offset = int.from_bytes(header[78:82], 'big')
                if not 2 <= count <= 20000 or not 78 + count * 8 <= offset <= source.stat().st_size - 40:
                    raise ConversionError('Повреждена таблица записей MOBI. Попробуйте открыть другую копию книги.')
                stream.seek(offset)
                record = stream.read(40)
                if record[12:14] != b'\0\0' and not (tools_root / 'bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll').is_file():
                    raise ComponentRequired(optional_component_id('LegacyBooks',tools_root),
                        'Для этого старого варианта Mobipocket нужен дополнительный кодек calibre.')
        args.append(str(tools_root/'bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll'))
        args.append(str(tools_root/'kindle'))
        try:
            process = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
                                     creationflags=0x08000000 if os.name == 'nt' else 0)
        except subprocess.TimeoutExpired as error: raise ConversionError('Подготовка Kindle-книги превысила 90 секунд.') from error
        if process.returncode:
            detail = process.stdout.decode('utf-8', errors='replace')[-1500:]
            raise ConversionError('Не удалось подготовить книгу Kindle. ' + detail)
        result = json.loads(manifest.read_text(encoding='utf-8')); path = Path(result['path']).resolve()
        for warning in result.get('warnings',[]):warnings.add(str(warning))
        if not path.is_relative_to(work) or not path.is_file(): raise ConversionError('Некорректный результат KindleUnpack.')
        if result['format'] == 'epub':
            if target_extension == '.fb2':
                normalized = root / 'normalized.epub'
                kindle_epub(path, normalized, warnings)
                epub_to_fb2(normalized, output, warnings)
            else: kindle_epub(path, output, warnings)
        elif result['format'] == 'html':
            metadata['resource_root'] = str(path.parent)
            metadata['resource_scope'] = str(work)
            metadata['document_outline'] = mobi_navigation(path, warnings)
            package = mobi_package(path, warnings)
            metadata['publication_metadata'] = mobi_publication_metadata(package, result.get('asins', ()))
            if not metadata.get('omit_images') or metadata.get('reading'):
                metadata['cover_asset'] = mobi_cover_asset(package, path, warnings)
            text_to_book(path, output, warnings, target_extension, **metadata)
            warnings.add('Старый MOBI преобразован из HTML; Kindle-вёрстка и служебные сведения могут упрощаться.')
        else: raise ConversionError('Неподдерживаемый результат KindleUnpack.')


def detect_compound_office(source, header):
    """Inspect bounded CFB directories and the seven-byte Works stream header."""
    import struct
    if len(header) < 512 or header[28:30] != b'\xfe\xff' or header[30:32] not in (b'\x09\0', b'\x0c\0'):
        return '.ole'
    sector_size = 1 << header[30]; entries = sector_size // 4
    u32 = lambda data, at: struct.unpack_from('<I', data, at)[0]
    count, directory, difat, difat_count = (u32(header, at) for at in (44, 48, 68, 72))
    if not 0 < count <= 4096 or difat_count > 32: return '.ole'
    with source.open('rb') as stream:
        size = source.stat().st_size
        def sector(index):
            offset = (index + 1) * sector_size
            if index >= 0xfffffffa or offset + sector_size > size: return b''
            stream.seek(offset); return stream.read(sector_size)
        fat = [u32(header, at) for at in range(76, 512, 4) if u32(header, at) < 0xfffffffa][:count]
        visited = set()
        while len(fat) < count:
            if difat in visited or len(visited) >= 32: return '.ole'
            visited.add(difat); data = sector(difat)
            if not data: return '.ole'
            fat.extend(u32(data, at) for at in range(0, sector_size - 4, 4) if u32(data, at) < 0xfffffffa)
            fat = fat[:count]; difat = u32(data, sector_size - 4)
        def next_sector(index):
            page, offset = divmod(index, entries)
            if page >= len(fat): return 0xfffffffe
            data = sector(fat[page])
            return u32(data, offset * 4) if data else 0xfffffffe
        root_stream = None
        def works_contents(data, at):
            length = int.from_bytes(data[at+120:at+128], 'little')
            if length < 7: return False
            index, offset = u32(data, at+116), 0
            if length < 4096:
                if root_stream is None or header[32:34] != b'\x06\0' or u32(header, 56) != 4096: return False
                offset = index * 64; index, root_length = root_stream
                if offset + 7 > root_length: return False
                steps, offset = divmod(offset, sector_size)
                if steps >= 256: return False
                seen = set()
                for _ in range(steps):
                    if index in seen: return False
                    seen.add(index); index = next_sector(index)
                if index in seen: return False
            prefix = sector(index)[offset:offset+7]
            # libwps WPSHeader identifies Works 2000 and Works 7/8 this way.
            return prefix in (b'CHNKINK', b'CHNKWKS')
        visited.clear()
        while directory < 0xfffffffa and len(visited) < 256:
            if directory in visited: return '.ole'
            visited.add(directory); data = sector(directory)
            if not data: return '.ole'
            for at in range(0, sector_size, 128):
                if len(visited) == 1 and at == 0 and data[66] == 5:
                    root_stream = (u32(data, 116), int.from_bytes(data[120:128], 'little'))
                length = int.from_bytes(data[at+64:at+66], 'little')
                if data[at+66] == 2 and 2 <= length <= 64 and length % 2 == 0:
                    try: name = data[at:at+length-2].decode('utf-16-le').casefold()
                    except UnicodeError: return '.ole'
                    match = {'worddocument': '.doc', 'powerpoint document': '.ppt', 'workbook': '.xls', 'book': '.xls'}.get(name)
                    if match: return match
                    if name == 'contents' and works_contents(data, at): return '.wps'
            index, offset = divmod(directory, entries)
            if index >= len(fat): return '.ole'
            data = sector(fat[index])
            if not data: return '.ole'
            directory = u32(data, offset * 4)
    return '.ole'


def comic_sidecar(name, extension):
    return (posixpath.basename(name).lower() in {'comicinfo.xml', '.ds_store', 'thumbs.db'}
            or (extension == '.cbz' and Path(name).suffix.lower() == '.sfv'))


def comic_text_attachment(name, extension):
    return extension == '.cbz' and Path(name).suffix.lower() == '.txt'


def detect_input(source):
    """Bounded signature inspection, also for numeric/mistyped extensions."""
    with source.open('rb') as stream: prefix = stream.read(131072)
    if prefix.startswith(b'AT&TFORM'): return '.djvu'
    if prefix.startswith(b'SQLite format 3\0'):
        import importlib.util
        spec = importlib.util.spec_from_file_location('homelib_jutoh_input', Path(__file__).with_name('jutoh_input.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return '.jutoh' if module.matches(source) else '.sqlite'
    for signature, extension in [(b'ICEContainer 1.0', '.ibk'),
                                  (b'CoolReader 3 Cache File ', '.cr3'), (b'\rJAP-Frame-Set1', '.jap'),
                                  (b'ASMJS[::]', '.sm'), (b'b1:as', '.b1')]:
        if prefix.startswith(signature): return extension
    if prefix.startswith(b'\xef\xbb\xbfASMJS[::]'): return '.sm'
    if len(prefix)>=21 and prefix[:2]==b'HA' and 0<int.from_bytes(prefix[2:4],'little')<=20000 and prefix[4]>>4<=2 and prefix[4]&15 in {0,1,2,14,15}: return '.ha'
    if prefix.startswith(b'\x89PNG\r\n\x1a\n'): return '.png'
    if prefix.startswith(b'\xff\xd8'): return '.jpg'
    if prefix.startswith(b'GIF8'): return '.gif'
    if prefix.startswith(b'BM'): return '.bmp'
    if prefix.startswith((b'II*\0',b'MM\0*')): return '.tif'
    if prefix.startswith(b'RIFF') and prefix[8:12] == b'WEBP': return '.webp'
    if prefix.startswith(b'Rar!'): return '.cbr'
    if prefix.startswith(b'7z\xbc\xaf\x27\x1c') and source.suffix.lower() == '.cb7': return '.cb7'
    if prefix.startswith(b'ITSF'): return '.chm'
    if prefix.startswith(b'ITOLITLS'): return '.lit'
    if prefix.startswith(b'L\0R\0F\0\0\0'): return '.lrf'
    if prefix.startswith(b'\xb0\x0c\xb0\x0c\x02\x00NUVO'):return '.rb'
    if prefix.startswith(b'!!8-Bit!!'): return '.tcr'
    if prefix[:2] in (b'1\xbe', b'2\xbe'): return '.wri'
    if prefix.startswith(b'{\\rtf'): return '.rtf'
    if len(prefix) >= 78:
        if prefix[60:68] == b'.rgoCERI': return '.rgo'
        if prefix[60:68] == b'BOOKMOBI': return '.mobi'
        if prefix[60:68] in (b'TEXtREAd', b'zTXTGPlm', b'SDocSilX', b'PNRdPPrs'): return '.pdb'
    # Some EPUB writers leave DEFLATE option bits on the stored mimetype entry.
    if (len(prefix) >= 58 and prefix.startswith(b'PK\x03\x04') and
            not int.from_bytes(prefix[6:8], 'little') & ~0x806 and prefix[8:10] == b'\0\0' and
            prefix[14:26] == b'oa\xab,\x14\0\0\0\x14\0\0\0' and
            prefix[26:30] == b'\x08\0\0\0' and prefix[30:58] == b'mimetypeapplication/epub+zip'):
        return '.epub'
    if prefix.startswith(b'PK'):
        with zipfile.ZipFile(source) as archive:
            if len(archive.infolist()) > MAX_ENTRIES: raise ConversionError('В контейнере слишком много файлов.')
            names = set(archive.namelist())
            for marker, extension in [('META-INF/container.xml', '.epub'), ('word/document.xml', '.docx'), ('ppt/presentation.xml', '.pptx'), ('xl/workbook.xml', '.xlsx'), ('fb3/body.xml', '.fb3')]:
                if marker in names: return extension
            if 'body' in fb3_declared_parts(archive):
                return '.fb3'
            if 'Index/Document.iwa' in names or 'Index.zip' in names: return '.pages'
            if 'mimetype' in names and archive.getinfo('mimetype').file_size < 1024:
                mime = archive.read('mimetype')
                if mime==b'application/vnd.sun.xml.writer':return '.sxw'
                for name, extension in [('text', '.odt'), ('spreadsheet', '.ods'), ('presentation', '.odp'), ('text-template', '.ott'), ('spreadsheet-template', '.ots'), ('presentation-template', '.otp')]:
                    if mime == ('application/vnd.oasis.opendocument.' + name).encode('ascii'): return extension
            if 'content.xml' in names:
                with archive.open('content.xml') as stream:content_prefix=stream.read(8192)
                if b'urn:oasis:names:tc:opendocument:xmlns:office:1.0' in content_prefix:return '.odt'
                if b'http://openoffice.org/2000/office' in content_prefix:return '.sxw'
            if any(name.lower().endswith('.fdseq') for name in names): return '.xps'
            page_names = [name for name in names if not name.endswith('/')]
            if page_names and any(Path(name).suffix.lower() in {'.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp'} for name in page_names) and all(
                Path(name).suffix.lower() in {'.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp'} or
                comic_sidecar(name, source.suffix.lower()) or comic_text_attachment(name, source.suffix.lower())
                for name in page_names): return '.cbz'
        return '.zip'
    if prefix.startswith(b'MZ'):return '.exe'
    if prefix.startswith(b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'):return detect_compound_office(source, prefix)
    if prefix[:2] in (b'\xff\xfe', b'\xfe\xff'):
        try: probe = prefix[:len(prefix)&~1].decode('utf-16').encode('utf-8')
        except UnicodeError: probe = b''
    else: probe = prefix.removeprefix(b'\xef\xbb\xbf')
    extension = source.suffix.lower()
    if extension in {'.mht', '.mhtml'}:
        headers = re.split(br'\r?\n\r?\n', probe, maxsplit=1)[0]
        if (re.search(br'^MIME-Version:', headers, re.M | re.I) and
                re.search(br'^Content-Type:\s*(?:text/plain|text/html|application/xhtml\+xml|multipart/[^;\s]+)(?=[;\s]|$)',
                          headers, re.M | re.I)):
            return '.mht'
    if re.match(br'\s*<\?(?:php(?=\s|$)|=)', probe, re.I): return '.php'
    if b'%PDF-' in prefix[:1024]:return '.pdf'
    if re.search(br'<(?:\w+:)?FictionBook\b', probe, re.I): return '.fb2'
    if re.search(br'<(?:\w+:)?abiword\b',probe,re.I):return '.abw'
    if re.search(br'^MIME-Version:', probe, re.M | re.I) and re.search(br'multipart/|text/html', probe, re.I): return '.mht'
    # Markdown commonly contains static HTML blocks. A full HTML document
    # still wins over a misleading suffix; a paragraph alone must not turn a
    # genuine Markdown book (and its links/code) into an HTML fragment.
    if (re.search(br'<html\b|<!DOCTYPE\s+html', probe, re.I) or
            (source.suffix.lower() not in {'.md', '.markdown'} and
             re.search(br'<(?:body|p|div|section|h[1-6])(?:\s|>)', probe, re.I))): return '.html'
    # Plain text may start with <|title|> or a URL in angle brackets.
    if source.suffix.lower() not in {'.md', '.markdown'} and re.match(br'<(?:[A-Za-z_:\x80-\xff][\w.:\x80-\xff-]*(?=[\s>]|/>)|\?xml(?=[\s?])|!--|!DOCTYPE(?=[\s>]))',
                probe.lstrip(), re.I):
        if source.suffix.lower() in {'.html','.htm','.xhtml','.shtml'}: return '.html'
        return '.xml'
    if extension == '.md5' and re.match(br'[0-9a-fA-F]{32} [ *][^\r\n]+(?:\r|\n|\Z)', probe):
        return '.md5'
    if prefix[:2] in (b'\xff\xfe',b'\xfe\xff'):
        try:text=prefix[:len(prefix)&~1].decode('utf-16')
        except UnicodeError:text=''
    else:text=prefix.decode('utf-8-sig',errors='replace')
    if text.strip() and not any(ord(char)<32 and char not in '\t\r\n\f' or ord(char)==127 for char in text):
        return extension if extension in {'.txt','.text','.faq','.md','.markdown','.html','.htm','.xhtml','.shtml'} else '.txt'
    return extension


def validate_epub_output(path, maximum_total=None, progress=None, *, allow_large_jpeg=False,
                         repairable_parts=None, allow_partial_epub=False):
    archive = EpubArchive(path, maximum_total, allow_large_jpeg=allow_large_jpeg)
    try:
        def read_part(name, parser):
            data = archive.read(name)
            if repairable_parts is None:
                return parser(data)
            repaired = set()
            if parser is xhtml:
                document = read_epub_content(data, repaired, part=name, allow_partial_epub=allow_partial_epub)
            else:
                document = parser(data, namespace_warnings=repaired)
            if repaired:
                repairable_parts[name] = repaired.pop()
            return document

        if progress is None:
            if archive.archive.testzip() is not None: raise ConversionError('Ошибка записи EPUB.')
        else:
            entries = archive.archive.infolist()
            progress('checking-epub', 0, len(entries))
            for index, entry in enumerate(entries, 1):
                with archive.archive.open(entry) as member:
                    while member.read(1024 * 1024):
                        pass
                if index % 8 == 0 or index == len(entries):
                    progress('checking-epub', index, len(entries))
        # EPUB 2 chapters may be named .xml. Their manifest media type,
        # rather than the suffix alone, identifies legacy XHTML/DTD entities.
        container = read_part('META-INF/container.xml', xml)
        if tag(container) != 'container':
            raise ConversionError('Некорректный контейнер EPUB.')
        versions, xhtml_parts, spine_parts = set(), set(), set()
        for rootfile in (n for n in container.iter() if tag(n) == 'rootfile'):
            package_path = archive.resolve('container.xml', rootfile.get('full-path', ''))[0]
            package = read_part(package_path, xml)
            versions.add(package.get('version', '').split('.')[0])
            manifest = first(package, 'manifest')
            if manifest is None: raise ConversionError('В EPUB отсутствует каталог ресурсов.')
            spine = first(package, 'spine')
            linear_ids = {item.get('idref') for item in spine if item.get('linear', '').lower() != 'no'} \
                if repairable_parts is not None and spine is not None else set()
            for item in manifest:
                if item.get('media-type') in EPUB_XHTML_TYPES:
                    path = archive.resolve(package_path, item.get('href', ''))[0]
                    if path not in archive.names: raise ConversionError('В EPUB отсутствует глава книги.')
                    xhtml_parts.add(path)
                    if item.get('id') in linear_ids:
                        spine_parts.add(path)
        for name in archive.names:
            if name in xhtml_parts or name.lower().endswith(('.xhtml', '.opf', '.ncx', '.xml')):
                parser = xhtml if name in xhtml_parts or name.lower().endswith('.xhtml') else xml
                read_part(name, parser)
        if repairable_parts is not None and spine_parts and all(
                repairable_parts.get(name, '').startswith(EPUB_MISSING_BODY) for name in spine_parts):
            raise ConversionError('В EPUB не сохранилось ни одной главы с содержимым.')
        return versions
    finally:
        archive.close()


def missing_epub_chapters(source, warnings, check, *, allow_large_jpeg=False):
    archive = EpubArchive(source, allow_large_jpeg=allow_large_jpeg)
    try:
        if check is not None:
            check()
        container = xml(archive.read('META-INF/container.xml'), namespace_warnings=warnings)
        package_path = next((n.get('full-path') for n in container.iter() if tag(n) == 'rootfile'), '')
        if not package_path:
            return {}
        package = xml(archive.read(package_path), namespace_warnings=warnings)
        manifest, spine = first(package, 'manifest'), first(package, 'spine')
        if manifest is None or spine is None:
            return {}
        items = {}
        for item in children(manifest, 'item'):
            ident = item.get('id', '')
            if ident in items:
                # The normal EPUB importer handles duplicated and aliased IDs.
                return {}
            items[ident] = item
        paths = {}
        for entry in children(spine, 'itemref'):
            if check is not None:
                check()
            item = items.get(entry.get('idref', ''))
            if item is None or item.get('media-type') not in EPUB_XHTML_TYPES:
                continue
            try:
                path, fragment = archive.resolve(package_path, item.get('href', ''))
            except EpubOutsideResource:
                continue
            if not path or fragment or 'nav' in item.get('properties', '').split():
                continue
            paths[path] = paths.get(path, False) or entry.get('linear', '').lower() != 'no'
        missing = [path for path in paths if path not in archive.names]
        if not missing:
            return {}
        if not any(linear and path in archive.names for path, linear in paths.items()):
            raise ConversionError('В EPUB отсутствуют главы для чтения.')
        if len(archive.names) + len(missing) > MAX_ENTRIES:
            raise ConversionError('В EPUB слишком много разделов для восстановления.')
        result = {}
        for path in missing:
            if any(ord(character)<32 or character in '\ufffe\uffff' for character in path):
                raise ConversionError('Некорректный адрес отсутствующего раздела EPUB.')
            document = element(XH, 'html')
            head = element(XH, 'head')
            head.append(element(XH, 'title', 'Раздел EPUB отсутствует'))
            document.append(head)
            body = element(XH, 'body')
            body.append(element(XH, 'p', f'[В архиве EPUB отсутствует раздел «{path}».]'))
            document.append(body)
            result[path] = serialized(document)
        warnings.add(f'В архиве EPUB отсутствуют файлы из порядка чтения ({len(missing)}). '
                     'В книге отмечены следующие пропуски: ' + ', '.join(missing) + '.')
        return result
    finally:
        archive.close()


def copy_epub_with_repaired_markup(source, destination, parts, check, *, additions=None, replacements=None):
    with zipfile.ZipFile(source) as archive:
        names = set(archive.namelist())
        if 'META-INF/signatures.xml' in names:
            raise ConversionError('Исправление разметки нарушит цифровую подпись EPUB.')
        with zipfile.ZipFile(destination, 'x') as output:
            for item in archive.infolist():
                if check is not None:
                    check()
                if replacements and item.filename in replacements:
                    output.writestr(copy.copy(item), replacements[item.filename])
                elif item.filename in parts:
                    data = archive.read(item)
                    if parts[item.filename] != EPUB_NAMESPACE_REPAIR:
                        try:
                            xhtml(data)
                        except ConversionError as error:
                            _, repaired, warning = repair_epub_content(data, error, item.filename,
                                allow_html5=parts[item.filename].startswith(EPUB_HTML5_REPAIR))
                            if warning != parts[item.filename]:
                                raise ConversionError('Исходный EPUB изменился во время обработки.')
                        else:
                            repaired = data
                    else:
                        repaired = repair_epub_namespace(data)
                    if repaired is data:
                        raise ConversionError('Исходный EPUB изменился во время обработки.')
                    output.writestr(copy.copy(item), repaired)
                else:
                    with archive.open(item) as original, output.open(copy.copy(item), 'w') as copied:
                        shutil.copyfileobj(original, copied, length=1024 * 1024)
            if additions:
                for name, content in additions.items():
                    if check is not None:
                        check()
                    if name in names:
                        raise ConversionError('Исходный EPUB изменился во время обработки.')
                    output.writestr(name, content, compress_type=zipfile.ZIP_DEFLATED)


def rewrite_epub_version(source, output, version, transform, warnings, check):
    if check is not None:
        check()
    archive = EpubArchive(source)
    try:
        container = xml(archive.read('META-INF/container.xml'))
        rootfiles = [node for node in container.iter() if tag(node) == 'rootfile']
        packages = [archive.resolve('container.xml', node.get('full-path', ''))[0] for node in rootfiles]
        documents = [xml(archive.read(path)) for path in packages if path]
        versions = [document.get('version', '').split('.')[0] for document in documents]
        if versions and len(versions) == len(packages) and set(versions) == {version}:
            shutil.copyfile(source, output)
            return
        if len(packages) != 1 or versions not in (['2'], ['3']):
            raise ConversionError('Для смены версии EPUB нужна книга с одним вариантом оформления.')
        if 'META-INF/signatures.xml' in archive.names:
            raise ConversionError('Изменение версии нарушит цифровую подпись EPUB.')
        if 'META-INF/encryption.xml' in archive.names:
            encryption = xml(archive.read('META-INF/encryption.xml'))
            methods = list(encryption.iter('{http://www.w3.org/2001/04/xmlenc#}EncryptionMethod'))
            font_algorithms = {'http://www.idpf.org/2008/embedding', 'http://ns.adobe.com/pdf/enc#RC'}
            if not methods or any(method.get('Algorithm') not in font_algorithms for method in methods):
                raise ConversionError('Для изменения версии EPUB нужен экземпляр книги без защиты.')
        replacements = transform(archive, packages[0], documents[0], warnings, check)
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as result:
            result.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            for entry in archive.archive.infolist():
                if check is not None:
                    check()
                name = entry.filename
                if name == 'mimetype' or entry.is_dir():
                    continue
                if name in replacements:
                    result.writestr(name, replacements.pop(name))
                else:
                    with archive.archive.open(entry) as data, result.open(name, 'w') as target:
                        shutil.copyfileobj(data, target, length=1024 * 1024)
            for name, data in replacements.items():
                result.writestr(name, data)
    finally:
        archive.close()


PACKING_IMAGE_API = 4
PACKING_IMAGE_FORMATS = frozenset({'.fb2', '.epub', '.docx', '.odt', '.cbz'})


def _packing_container_module():
    spec = importlib.util.spec_from_file_location('homelibre_container_images', Path(__file__).with_name('container_image_quality.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def packing_image_members(book, extension, check=None):
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    return _packing_container_module().image_members(api, book, extension, check)


def packing_container_metadata(data, replacements):
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    return _packing_container_module().rewrite_metadata(api, data, replacements)


def compress_image_container(source, destination, **options):
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    return _packing_container_module().compress(api, source, destination, **options)


def compressed_image_hashes(book, extension, check):
    spec = importlib.util.spec_from_file_location('homelib_image_quality', Path(__file__).with_name('image_quality.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
    return module.compressed_image_hashes(api, book, extension, check)


def convert_book(source, destination, **metadata):
    skip_damaged_image = metadata.pop('skip_damaged_fb2_image', False)
    try:
        return _convert_book(source, destination, **metadata)
    except FB2ImageRecoveryRequired as error:
        if metadata.get('reading') or detect_input(Path(source)) != '.fb2':
            raise ConversionError(str(error)) from error
        if not skip_damaged_image:
            raise
        with tempfile.TemporaryDirectory(prefix='homelib-fb2-image-recovery-', dir=Path(destination).absolute().parent) as folder:
            recovered = Path(folder) / Path(source).name
            recovered.write_bytes(error.book)
            report = _convert_book(recovered, destination, **metadata)
        report['warnings'].insert(0, error.warning)
        return report


def _convert_book(source, destination, **metadata):
    static_gifs = metadata.pop('_static_gifs', None)
    allow_partial_epub = metadata.pop('allow_partial_epub', False)
    if static_gifs is not None and not isinstance(static_gifs, bool):
        raise ConversionError('Некорректный режим статичных GIF.')
    output_profile = metadata.pop('output_profile', None)
    text_layer_only = metadata.pop('text_layer_only', False)
    image_quality = metadata.pop('image_quality', 'original')
    image_container = metadata.pop('image_container', None)
    cancel_check = metadata.pop('cancel_check', None)
    image_options = metadata.pop('image_options', None)
    image_choice = metadata.pop('image_choice', None)
    measure_scans = metadata.pop('measure_scans', False) and image_quality == 'ask'
    packing_grayscale = metadata.pop('packing_grayscale', False)
    packing_image_history = metadata.pop('packing_image_history', None)
    packing_image_report = metadata.pop('packing_image_report', None)
    grayscale = metadata.pop('grayscale', False) and image_quality != 'none'
    scan_layout = metadata.pop('scan_layout', 'keep')
    scan_exclude = metadata.pop('scan_exclude', '')
    if scan_layout not in {'keep','split','auto'}: raise ConversionError('Неизвестный режим страниц сканов.')
    if metadata.get('reading'):
        image_quality = 'original'
        grayscale = False
        scan_layout = 'keep'
        scan_exclude = ''
    source, destination = Path(source).resolve(), Path(destination).absolute()
    if source == destination.resolve(): raise ConversionError('Исходная книга и результат должны быть разными файлами. Выберите другую папку или имя.')
    if destination.exists(): raise ConversionError('Файл результата уже существует. Выберите другое имя.')
    source_size = source.stat().st_size
    if source_size > MAX_PDF_SOURCE:
        raise ConversionError('Книга превышает предел конвертации (512 МБ).')
    extension, target_extension = detect_input(source), destination.suffix.lower()
    if extension == '.php':
        raise ConversionError('Файл содержит PHP-код. Для конвертации нужен файл книги.')
    stream_source_fb2 = (extension == '.fb2' and target_extension == '.epub' and not output_profile
                         and image_quality == 'original' and not grayscale and source_size > MAX_FILE)
    if extension != '.pdf' and not stream_source_fb2 and source_size > MAX_TOTAL:
        raise ConversionError('Книга превышает предел конвертации (256 МБ).')
    if packing_grayscale and (metadata.get('reading') or output_profile or extension != target_extension or
                              extension not in {'.fb2', '.epub'} or image_quality not in {'balanced', 'economy', 'maximum'}):
        raise ConversionError('Чёрно-белый режим предназначен для сжатых копий FB2 и EPUB.')
    if packing_image_history is not None or packing_image_report is not None:
        if ((packing_image_history is not None and not callable(packing_image_history)) or
                (packing_image_report is not None and not callable(packing_image_report)) or
                metadata.get('reading') or output_profile or extension != target_extension or
                extension not in {'.fb2', '.epub'} or image_quality not in {'original','balanced','economy','maximum'}):
            raise ConversionError('История изображений доступна только для сжатия книги в её исходном формате.')
    grayscale = grayscale or packing_grayscale
    if image_container not in (None,'raw','fb2-zip') or (image_container == 'fb2-zip' and target_extension != '.fb2'):
        raise ConversionError('Неверный контейнер обработки изображений.')
    scanned_document = extension in BOOK_SCAN_INPUTS
    if text_layer_only and (not scanned_document or target_extension != '.fb2' or image_quality != 'none' or
                            output_profile or scan_layout != 'keep'):
        raise ConversionError('Текстовый слой можно извлечь из PDF или DjVu при сохранении в TXT.')
    if output_profile:
        if metadata.get('reading') or image_container == 'fb2-zip':
            raise ConversionError('Дополнительный формат недоступен для этой операции.')
        script = Path(__file__).with_name('advanced_output.py')
        spec = importlib.util.spec_from_file_location('homelibre_advanced_output', script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
        options = dict(metadata, image_quality=image_quality, image_container=image_container,
                       cancel_check=cancel_check, image_options=image_options, image_choice=image_choice,
                       scan_layout=scan_layout, scan_exclude=scan_exclude, grayscale=grayscale)
        return module.convert(api, source, destination, extension, output_profile, options)
    if target_extension in {'.mobi', '.azw3'}:
        script = Path(__file__).with_name('kindle_output.py')
        if not script.is_file():
            raise ComponentRequired('KindleExport',
                'Для сохранения в MOBI и AZW3 нужен модуль записи Kindle — Kindling.')
        spec = importlib.util.spec_from_file_location('homelibre_kindle_output', script)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
        options = dict(metadata, image_quality=image_quality, image_options=image_options, image_choice=image_choice,
                       scan_layout=scan_layout, scan_exclude=scan_exclude, grayscale=grayscale,
                       cancel_check=cancel_check)
        return module.convert(api, source, destination, options)
    if image_quality == 'none' and not text_layer_only and (scanned_document or extension in {
            '.tif','.tiff','.cbz','.cbr','.cb7','.jpg','.jpeg','.png','.gif','.bmp','.webp','.xps'}):
        raise ConversionError('Изображения содержат сами страницы. Выберите режим с изображениями, например «Без уменьшения качества».')
    large_jpeg = extension in {'.jpg', '.jpeg'} and source_size > 16 * 1024 * 1024
    if large_jpeg:
        if target_extension != '.epub' or image_quality not in {'original', 'ask'} or grayscale or scan_layout != 'keep':
            raise ConversionError('Это большое изображение JPEG. Чтобы сохранить его целиком, выберите EPUB и «Без уменьшения качества».')
        image_quality = 'original'
    image_export = None
    large_comic = extension in {'.cbz','.cbr','.cb7'} and source_size > MAX_FILE
    original_pages = image_quality == 'original' and scan_layout == 'keep' and not grayscale
    # Choosing a profile after the preview uses the same staging as a preset.
    stream_scan_epub = (target_extension == '.epub' and not metadata.get('reading') and
                        ((scanned_document and not measure_scans and image_quality != 'none') or
                         (large_comic and original_pages)))
    stream_scan_fb2 = (target_extension == '.fb2' and scanned_document and not metadata.get('reading')
                       and not measure_scans and image_quality != 'none')
    # A small compressed EPUB can contain more markup than fits in a single
    # FB2 parse. Write images in order and validate each generated section.
    stream_epub_to_fb2 = extension == '.epub' and target_extension == '.fb2'
    fb2_binary_ranges = [] if stream_epub_to_fb2 and (image_quality != 'original' or grayscale) else None
    stream_chm = extension == '.chm' and image_quality == 'original' and not grayscale
    stream_chm_epub = stream_chm and target_extension == '.epub' and source_size > MAX_FILE
    stream_chm_fb2 = stream_chm and target_extension == '.fb2'
    stream_text_fb2 = stream_chm_fb2 or stream_scan_fb2
    stream_docx_epub = (extension == '.docx' and target_extension == '.epub' and not metadata.get('reading')
                        and image_quality == 'original' and not grayscale)
    if stream_chm_epub or stream_chm_fb2 or stream_docx_epub:
        metadata['static_gifs'] = static_gifs is not False and not metadata.get('reading')
    if stream_docx_epub:
        metadata['stream_docx_images'] = True
    # PDF/DjVu use the same scan rendering detail for estimation and final
    # export, including the original-quality choice. Reading has its own path.
    if text_layer_only and cancel_check is not None:
        progress = metadata.get('progress')
        def checked_progress(*values):
            cancel_check()
            if progress is not None:
                progress(*values)
        metadata['progress'] = checked_progress
    if not text_layer_only and not metadata.get('reading') and (image_quality!='original' or grayscale or scan_layout!='keep' or scanned_document or stream_scan_epub) and extension in {'.pdf','.djvu','.djv','.dju','.djm','.djvm','.tif','.tiff','.cbz','.cbr','.cb7','.jpg','.jpeg','.png','.gif','.bmp','.webp','.xps'}:
        image_export={'profile':image_quality,'layout':scan_layout,'exclude':scan_exclude,'target':target_extension,'container':image_container,
                      'options':image_options,'choice':image_choice,'handled':False,'grayscale':grayscale,'check':cancel_check,
                      'measure_scans':measure_scans}
        metadata['image_export']=image_export
        if stream_scan_epub or stream_scan_fb2:
            image_export['resource_limit'] = MAX_SCAN_EPUB_RESOURCES
    large_images = scanned_document or extension in {'.tif','.tiff','.cbz','.cbr','.cb7','.rtf','.chm'} or (extension=='.fb2' and metadata.get('reading'))
    large_images = large_images or extension == '.epub' or (extension == '.fb2' and (image_quality!='original' or grayscale))
    limit = MAX_PDF_SOURCE if extension == '.pdf' else (MAX_TOTAL if large_images else MAX_FILE)
    if stream_source_fb2:
        limit = MAX_LARGE_FB2_OUTPUT
    if large_jpeg:
        limit = MAX_TOTAL - 1024 * 1024
    if source_size > limit: raise ConversionError('Книга превышает предел конвертации ('+str(limit//1024//1024)+' МБ).')
    conversion = {('.fb2', '.epub'): fb2_to_epub, ('.epub', '.fb2'): epub_to_fb2}.get((extension, target_extension))
    text_input = extension in BOOK_TEXT_INPUTS and target_extension in {'.epub', '.fb2'}
    kindle_input = extension in BOOK_KINDLE_INPUTS and target_extension in {'.epub', '.fb2'}
    same_format=extension==target_extension and extension in {'.fb2','.epub'}
    ha_input = extension == '.ha' and target_extension in {'.fb2','.epub'}
    cr3_input = extension == '.cr3' and target_extension in {'.fb2','.epub'}
    b1_input = extension == '.b1' and target_extension in {'.fb2','.epub'}
    if conversion is None and not text_input and not kindle_input and not same_format and not ha_input and not cr3_input and not b1_input:
        explanation = {
            '.sqlite': 'Это база данных или проект редактора. Для книги нужен исходный текст либо экспорт из создавшей её программы.',
            '.md5': 'Это файл контрольных сумм MD5. Для конвертации нужен указанный в нём файл книги.',
            '.jap': 'Набор рамок JAP требует связанных изображений или исходной книги.',
            '.sm': 'Это интерактивная книга: текст зависит от выбранных ответов. Откройте её во встроенной читалке и нажмите «Сохранить пройденную ветку…», чтобы получить FB2 или EPUB с показанным текстом и ответами. Другие ветки остаются в исходной книге.',
            '.rgo': 'Для старого формата RepliGo пока требуется его просмотрщик или экспорт в PDF.',
            '.ole': 'В контейнере Office не найден поддерживаемый документ. Возможно, файл повреждён.'
        }.get(extension, 'Этот формат пока не поддерживается конвертером FB2/EPUB. Сохраните книгу в исходном формате.')
        raise ConversionError(explanation)
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix='.homelib-convert-', suffix='.tmp', dir=destination.parent)
    os.close(handle); temporary = Path(temporary_name); warnings = set(); text_only_source = None
    spooled_fb2 = False
    inherited_fb2_issues = Counter()
    repaired_fb2 = None
    recovered_epub = completed_spine = normalized_epub = None
    try:
        if extension == '.epub':
            permitted = allow_partial_epub or bool(metadata.get('reading'))
            spec = importlib.util.spec_from_file_location('homelib_epub_recovery', Path(__file__).with_name('epub_recovery.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
            try:
                with zipfile.ZipFile(source):
                    pass
            except zipfile.BadZipFile:
                if not permitted:
                    raise ConversionError('Архив EPUB повреждён. Для сохранения доступной части нужно подтверждение.')
                recovered_epub = tempfile.TemporaryDirectory(prefix='homelibre-recover-epub-', dir=destination.parent)
                repaired = Path(recovered_epub.name) / 'recovered.epub'
                with source.open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                module.recover(api, source, repaired, warnings,
                               dict(metadata, source_name=source.stem, source_digest=digest), cancel_check)
                source = repaired
            else:
                replacements, metadata_warnings = module.recover_metadata(api, source, cancel_check,
                    allow_large_jpeg=large_jpeg, permitted=permitted)
                if replacements:
                    recovered_epub = tempfile.TemporaryDirectory(prefix='homelibre-recover-epub-', dir=destination.parent)
                    repaired = Path(recovered_epub.name) / 'recovered.epub'
                    copy_epub_with_repaired_markup(source, repaired, {}, cancel_check, replacements=replacements)
                    source = repaired
                    warnings.update(metadata_warnings)
                if permitted:
                    additions = missing_epub_chapters(source, warnings, cancel_check, allow_large_jpeg=large_jpeg)
                    if additions:
                        completed_spine = tempfile.TemporaryDirectory(prefix='homelibre-missing-spine-', dir=destination.parent)
                        prepared = Path(completed_spine.name) / 'source.epub'
                        copy_epub_with_repaired_markup(source, prepared, {}, cancel_check, additions=additions)
                        source = prepared
            if same_format or image_quality == 'none':
                repairable_parts = {}
                validate_epub_output(source, allow_large_jpeg=large_jpeg, repairable_parts=repairable_parts,
                                     allow_partial_epub=permitted)
                if repairable_parts:
                    normalized_epub = tempfile.TemporaryDirectory(prefix='homelibre-markup-epub-', dir=destination.parent)
                    normalized = Path(normalized_epub.name) / 'source.epub'
                    copy_epub_with_repaired_markup(source, normalized, repairable_parts, cancel_check)
                    source = normalized
                    warnings.update(repairable_parts.values())
        if same_format and extension == '.fb2':
            source_book, repaired_fb2 = read_fb2(source.read_bytes(), limit, warnings)
            if source_book.tag != '{'+FB+'}FictionBook' or first(source_book, 'body') is None:
                raise ConversionError('В исходном FB2 отсутствует читаемая книга.')
            inherited_fb2_issues = Counter(key for key, _ in fb2_output_issues(source_book))
            if inherited_fb2_issues:
                warnings.add('В исходной FB2 есть ошибки разметки. Исходное оформление сохранено; выполнены только выбранные изменения изображений. Новые ошибки структуры не допускаются.')
            del source_book
        if image_quality == 'none' and extension in {'.fb2','.epub'}:
            spec = importlib.util.spec_from_file_location('homelib_image_quality', Path(__file__).with_name('image_quality.py'))
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
            text_only_source = tempfile.TemporaryDirectory(prefix='homelib-text-source-',dir=destination.parent)
            prepared = Path(text_only_source.name)/('source'+extension)
            try: removed = module.without_images(api,source,prepared,extension,warnings)
            except module.NoTextContent as error: raise ConversionError(str(error)) from error
            source = prepared
            repaired_fb2 = None
            if removed: warnings.add('Книга сохранена без изображений и обложки. Исходная книга сохранена.')
        if same_format:
            # A correctly detected target format needs no lossy round trip.
            if repaired_fb2 is None:
                shutil.copyfile(source, temporary)
            else:
                temporary.write_bytes(repaired_fb2)
        elif b1_input:
            spec=importlib.util.spec_from_file_location('homelib_b1',Path(__file__).with_name('b1_input.py'))
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            api=type('ConversionAPI',(),{name:value for name,value in globals().items() if not name.startswith('__')})
            options=dict(metadata,image_quality=image_quality,image_options=image_options,image_choice=image_choice,image_container=image_container,
                         scan_layout=scan_layout,scan_exclude=scan_exclude,grayscale=grayscale,cancel_check=cancel_check)
            module.convert(api,source,temporary,target_extension,warnings,options)
        elif cr3_input:
            spec=importlib.util.spec_from_file_location('homelib_cr3',Path(__file__).with_name('cr3_input.py'))
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            api=type('ConversionAPI',(),{name:value for name,value in globals().items() if not name.startswith('__')})
            module.convert(api,source,temporary,target_extension,warnings)
        elif ha_input:
            spec=importlib.util.spec_from_file_location('homelib_ha',Path(__file__).with_name('ha_input.py'))
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            module.convert(source,temporary,warnings,target_extension,convert_book,detect_input,**metadata)
        elif kindle_input: kindle_to_book(source, temporary, warnings, target_extension, **metadata)
        elif text_input:
            spooled_fb2 = text_to_book(source, temporary, warnings, target_extension, input_extension=extension,
                                       stream_fb2=stream_text_fb2, cancel_check=cancel_check,
                                       **dict(metadata, omit_images=image_quality == 'none'))
        elif conversion is fb2_to_epub:
            fb2_to_epub(source,temporary,warnings,maximum=limit,
                        progress=metadata.get('progress') if stream_source_fb2 else None,check=cancel_check)
        elif conversion is epub_to_fb2:
            stream_images = dict(
                tools=metadata.get('tools_root'),
                static_gifs=static_gifs is not False and image_quality != 'none' and not metadata.get('reading'),
                check=cancel_check, progress=metadata.get('progress'), binary_ranges=fb2_binary_ranges)
            epub_to_fb2(source, temporary, warnings, stream_images=stream_images, allow_partial_epub=allow_partial_epub,
                        tools_root=metadata.get('tools_root'), cancel_check=cancel_check,
                        render_math_images=image_quality != 'none',
                        document_progress=metadata.get('progress') if stream_epub_to_fb2 else None)
        else: conversion(source, temporary, warnings)
        if (not large_jpeg and not stream_epub_to_fb2 and not stream_chm_epub and not stream_text_fb2 and not stream_docx_epub
                and not metadata.get('reading') and image_quality != 'none' and not text_layer_only
                and (static_gifs is True or (static_gifs is None and not same_format))):
            script_directory = str(Path(__file__).resolve().parent)
            sys.path.insert(0, script_directory)
            try:
                from gif_static import normalize_export
                api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
                normalize_export(api, temporary, target_extension, metadata.get('tools_root'), warnings, cancel_check,
                                 maximum_total=MAX_SCAN_EPUB_RESOURCES + MAX_FILE if stream_scan_epub or stream_source_fb2 or stream_chm_epub else MAX_TOTAL,
                                 progress=metadata.get('progress'))
            finally:
                sys.path.pop(0)
        if ((image_quality != 'original' or grayscale) and not text_layer_only and text_only_source is None
                and not b1_input and not (image_export and image_export['handled'])):
            spec = importlib.util.spec_from_file_location('homelib_image_quality', Path(__file__).with_name('image_quality.py'))
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            api = type('ConversionAPI', (), {name: value for name, value in globals().items() if not name.startswith('__')})
            module.apply(api, temporary, target_extension, image_quality, metadata.get('tools_root'),
                         metadata.get('progress') or (lambda *_: None), image_options, image_choice,
                         warnings, image_container, check=cancel_check, grayscale=grayscale,
                         preserve_image=packing_image_history, image_history_report=packing_image_report,
                         fb2_binary_ranges=fb2_binary_ranges)
        # Ensure the generated artifact is readable before publishing its name.
        if destination.suffix.lower() == '.epub':
            if stream_scan_epub or stream_source_fb2 or stream_chm_epub or stream_docx_epub:
                validate_epub_output(temporary, MAX_SCAN_EPUB_RESOURCES + MAX_FILE, metadata.get('progress'))
            else:
                validate_epub_output(temporary, allow_large_jpeg=large_jpeg)
        else:
            if spooled_fb2 or stream_epub_to_fb2:
                validate_streamed_fb2(temporary, cancel_check, metadata.get('progress'))
            elif stream_chm_fb2:
                # Dense dictionaries can expand beyond the ordinary FB2 node budget.
                # This file comes from our own writer. Validate it without buffering binaries.
                validate_fb2_output(parse_fb2_file(temporary, MAX_LARGE_FB2_OUTPUT, keep_binary_data=False,
                                                   maximum_nodes=2_000_000))
            elif stream_scan_fb2:
                validate_fb2_output(parse_fb2_file(temporary, MAX_LARGE_FB2_OUTPUT, keep_binary_data=False))
            elif temporary.stat().st_size > MAX_TOTAL:
                raise ConversionError('FB2 превышает предел конвертации (256 МБ). Для книги со сканами выберите меньший размер изображений.')
            elif scanned_document:
                validate_fb2_output(parse_fb2_file(temporary, MAX_TOTAL, keep_binary_data=False))
            else:
                validate_fb2_output(xml(temporary.read_bytes(),MAX_TOTAL), inherited_fb2_issues)
        with temporary.open('r+b') as stream: stream.flush(); os.fsync(stream.fileno())
        if os.name == 'nt': os.rename(temporary, destination)  # Windows never replaces an existing name.
        else: os.link(temporary, destination); temporary.unlink()
        warnings = sorted(warnings, key=lambda message: (
            not message.startswith(('В исходнике не удалось прочитать страницы', 'Часть изображений ')), message))
        return {'output': str(destination), 'warnings': warnings, 'size': destination.stat().st_size}
    finally:
        if temporary.exists(): temporary.unlink()
        if text_only_source is not None: text_only_source.cleanup()
        if recovered_epub is not None: recovered_epub.cleanup()
        if completed_spine is not None: completed_spine.cleanup()
        if normalized_epub is not None: normalized_epub.cleanup()


def _write_progress(path, text):
    """Best-effort telemetry: a short Windows sharing lock cannot lose a book."""
    handle, temporary_name = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(text)
        for attempt in range(3):
            try:
                os.replace(temporary, path)
                return True
            except PermissionError as error:
                if getattr(error, 'winerror', None) not in {5, 32, 33}: raise
                if attempt < 2: time.sleep(.01)
        # Leave the last complete record; the next page can advance it. The
        # parent's inactivity deadline remains effective if no records arrive.
        return False
    finally:
        try: temporary.unlink(missing_ok=True)
        except PermissionError as error:
            if getattr(error, 'winerror', None) not in {5, 32, 33}: raise
            # Only this private temporary may remain for the parent's cleanup.


def main():
    parser = argparse.ArgumentParser(description='HomeLib Ru — локальная конвертация книг')
    parser.add_argument('source'); parser.add_argument('destination'); parser.add_argument('--report')
    parser.add_argument('--title', default=''); parser.add_argument('--author', default=''); parser.add_argument('--language', default='')
    parser.add_argument('--resource-root')
    parser.add_argument('--tools-root')
    parser.add_argument('--output-profile', choices=['epub2','epub3','kepub','kfx','azw8','pdf','md'])
    parser.add_argument('--text-layer-only', action='store_true', help='Prepare a text layer for TXT export')
    parser.add_argument('--image-quality', choices=['original','high','balanced','economy','maximum','none','ask'], default='original')
    parser.add_argument('--image-container', choices=['raw','fb2-zip'], help='Internal final image container; EPUB is inferred by default')
    parser.add_argument('--grayscale', action='store_true')
    parser.add_argument('--skip-damaged-fb2-image', action='store_true')
    parser.add_argument('--allow-partial-epub', action='store_true', help='Prepare partial FB2 and report EPUB elements that could not be preserved')
    parser.add_argument('--scan-layout', choices=['keep','split','auto'], default='keep')
    parser.add_argument('--scan-exclude', default='')
    parser.add_argument('--image-options', help='Internal image size estimate channel')
    parser.add_argument('--image-choice', help='Internal export quality choice channel')
    parser.add_argument('--measure-scans', action='store_true', help='Measure all scan pages for size estimates')
    parser.add_argument('--progress-file', help='Internal bounded page-progress channel')
    parser.add_argument('--reading', action='store_true', help='Internal reading view with visible placeholders for unsupported office objects')
    options = parser.parse_args()
    progress_path = Path(options.progress_file).absolute() if options.progress_file else None
    if progress_path is not None and (progress_path.exists() or progress_path.resolve() in {
            Path(options.source).resolve(), Path(options.destination).resolve(),
            Path(options.report).resolve() if options.report else None}):
        print(json.dumps({'error': 'Файл прогресса уже существует или совпадает с книгой или отчётом.'}, ensure_ascii=False))
        return 1
    progress_sequence = 0
    progress_pages = (0, 0)
    def progress(stage, completed, total):
        nonlocal progress_sequence, progress_pages
        if progress_path is None:
            return
        if stage == 'pages':
            progress_pages = (completed, total)
        elif stage == 'finalizing':
            completed, total = progress_pages
        progress_sequence += 1
        value = json.dumps({'sequence': progress_sequence, 'stage': stage,
                            'completed': completed, 'total': total})
        # The parent owns a private operation directory. Atomic replacement
        # avoids a partially read record while the native worker polls it.
        _write_progress(progress_path, value)
    report = Path(options.report).absolute() if options.report else None
    if report is not None and (report.exists() or report.resolve() in {Path(options.source).resolve(), Path(options.destination).resolve()}):
        print(json.dumps({'error': 'Файл отчёта уже существует или совпадает с книгой.'}, ensure_ascii=False))
        return 1
    def publish_report(text):
        if report is not None:
            # The report also belongs to this operation; never replace a file
            # created by the user or another operation during conversion.
            with report.open('x', encoding='utf-8') as stream:
                stream.write(text); stream.flush(); os.fsync(stream.fileno())
    # Observe only this CLI operation. Helpers and ctypes codecs run inside
    # Python too, so the parent cannot infer their use from the Python process.
    # No paths outside this installation, URLs or book names enter this report.
    used_tools = observe_component_tools(options.tools_root or Path(__file__).resolve().parent.parent)
    try:
        result = convert_book(options.source, options.destination, title=options.title, author=options.author,
                              language=options.language, resource_root=options.resource_root, tools_root=options.tools_root,
                              reading=options.reading, progress=progress, image_quality=options.image_quality, scan_layout=options.scan_layout, scan_exclude=options.scan_exclude,
                              image_options=options.image_options, image_choice=options.image_choice,image_container=options.image_container,
                              measure_scans=options.measure_scans,
                              output_profile=options.output_profile, text_layer_only=options.text_layer_only, grayscale=options.grayscale,
                              skip_damaged_fb2_image=options.skip_damaged_fb2_image, allow_partial_epub=options.allow_partial_epub)
        result['used_tools'] = sorted(used_tools)
        if not options.reading:
            result['damaged_content'] = damaged_content_warnings(result.get('warnings', []))
        text = json.dumps(result, ensure_ascii=False)
        publish_report(text)
        print(text)
        return 0
    except (ConversionError, OSError, UnicodeError, LookupError, zipfile.BadZipFile, RecursionError, ValueError, MemoryError) as error:
        message = 'Не хватило памяти для преобразования книги. Попробуйте уменьшить размер изображений.' if isinstance(error, MemoryError) else str(error)
        details = {'error': message, 'used_tools': sorted(used_tools)}
        if isinstance(error, ComponentRequired): details['required_component'] = error.component
        if isinstance(error, FB2ImageRecoveryRequired): details['recoverable_fb2_image'] = True
        text = json.dumps(details, ensure_ascii=False)
        try: publish_report(text)
        except OSError: pass
        print(text)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

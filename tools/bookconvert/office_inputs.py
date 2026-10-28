"""Portable office inputs shared by the reader and ebook export (MIT).

Only package XML and embedded resources are read. Macros, external links and
spreadsheet formulae are never executed. Slides are reflowed in document order;
worksheets retain cell addresses. The original office page layout is not rendered.
"""
from datetime import datetime, timedelta
from pathlib import Path
import posixpath
import re
import subprocess
import tempfile
import time
import os

P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
X = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
C = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
T = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
O = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
D = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0'
TB = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0'
XL = 'http://www.w3.org/1999/xlink'
OFFICE = {'.docm', '.dotx', '.dotm', '.ppt', '.pps', '.pot', '.pptx', '.pptm',
          '.ppsx', '.ppsm', '.potx', '.potm', '.xls', '.xlt', '.xlsx', '.xlsm',
          '.xltx', '.xltm', '.ods', '.ots', '.odp', '.otp', '.ott', '.wps', '.wpd'}


def rasterize_image(book, data):
    """Decode legacy Office pictures using bounded Windows GDI+, never Office."""
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        import importlib.util
        spec=importlib.util.spec_from_file_location('homelib_image_decoder',Path(__file__).with_name('image_input.py'))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module.decode_webp(book,data)
    if data.startswith((b'BM',b'II*\0',b'MM\0*')):
        import zipfile
        tool=book.c.image_processor_path(book.tools_root)
        if not tool.is_file(): book.require('ImageProcessing', 'Для подготовки этих изображений нужен модуль HomeLib Images.')
        with tempfile.TemporaryDirectory(prefix='homelib-picture-',dir=getattr(book,'work_root',None)) as directory:
            source=Path(directory)/'image.bin';target=Path(directory)/'pages.zip';source.write_bytes(data)
            try:
                process=subprocess.run([str(tool),'--image-pages',str(source),str(target)],capture_output=True,timeout=30,
                                       creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            except subprocess.TimeoutExpired: book.fail('Чтение встроенного изображения превысило 30 секунд.')
            if process.returncode or not target.is_file():book.fail('Не удалось прочитать встроенное изображение Windows.')
            with zipfile.ZipFile(target) as archive:
                entries=archive.infolist()
                if len(entries)!=1:book.fail('Встроенный TIFF содержит несколько страниц. Для их полного переноса откройте TIFF отдельной книгой.')
                if entries[0].file_size>16*1024*1024:book.fail('Встроенное изображение превышает 16 МБ.')
                return archive.read(entries[0])
    legacy = (data.startswith((b'BM', b'II*\0', b'MM\0*', b'\xd7\xcd\xc6\x9a')) or
              data[:4] in {b'\x01\0\x09\0', b'\x02\0\x09\0'} or
              (data[:4] == b'\x01\0\0\0' and data[40:44] == b' EMF'))
    if not legacy:
        book.fail('Неподдерживаемое изображение документа. Поддерживаются PNG, JPEG, GIF, BMP, TIFF, EMF и WMF.')
    tool = book.tools_root / 'doc' / 'HomeLibDoc.exe'
    if not tool.is_file(): book.require('DocSharp', 'Для этого офисного изображения нужен компонент DocSharp.')
    with tempfile.TemporaryDirectory(prefix='homelib-image-',dir=getattr(book,'work_root',None)) as work:
        source = Path(work) / 'picture.bin'; target = Path(work) / 'picture.png'
        source.write_bytes(data)
        try:
            with (Path(work) / 'output.log').open('wb') as log:
                result = subprocess.run([str(tool), '--image-to-png', str(source), str(target)],
                                        stdout=log, stderr=subprocess.STDOUT, timeout=15,
                                        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if result.returncode or not target.is_file(): book.fail('Не удалось декодировать встроенное офисное изображение.')
            if target.stat().st_size > 16 * 1024 * 1024: book.fail('Преобразованное изображение превышает 16 МБ.')
            png = target.read_bytes()
            if not png.startswith(b'\x89PNG\r\n\x1a\n'): book.fail('Компонент создал некорректное изображение.')
            return png
        except subprocess.TimeoutExpired: book.fail('Декодирование изображения превысило 15 секунд.')


def _odf_image(book, package, node, out):
    href = node.get('{' + XL + '}href', '')
    if not href or href.startswith('/') or '..' in href.split('/') or ':' in href:
        book.fail('Внешнее изображение OpenDocument не загружается.')
    p = book.el('p'); p.append(book.image(package.data(href.removeprefix('./')))); out.append(p)


def _odf_object(book, out):
    if not book.reading:
        book.fail('Встроенный объект OpenDocument пока нельзя перенести полностью. Сохраните документ как PDF.')
    out.append(book.el('p', '[Встроенный объект OpenDocument. Для полного вида откройте исходный документ во внешнем просмотрщике.]'))
    book.warnings.add('Содержимое встроенных объектов OpenDocument не выполняется и показано пометкой.')


def _relation(book, package, relationships, rid):
    target, external = relationships.get(rid, ('', False))
    if not target or external:
        book.fail('В документе отсутствует встроенный ресурс или используется внешняя ссылка.')
    return target


def _rich(book, node, out):
    """DrawingML and spreadsheet inline runs, preserving text and line breaks."""
    for child in node:
        local = book.c.tag(child)
        if local in {'r', 'fld'}:
            target = out
            props = child.find('{' + A + '}rPr')
            if props is None: props = child.find('{' + X + '}rPr')
            if props is not None:
                if props.get('b') in {'1', 'true'} or props.find('{' + X + '}b') is not None:
                    target = book.el('strong'); out.append(target)
                if props.get('i') in {'1', 'true'} or props.find('{' + X + '}i') is not None:
                    italic = book.el('em'); target.append(italic); target = italic
            _rich(book, child, target)
        elif local == 't': book.c.append_text(out, child.text or '')
        elif local == 'br': out.append(book.el('br'))


def _chart(book, package, part, out):
    root = package.xml(part)
    title = ' '.join(n.text or '' for n in root.findall('.//{' + C + '}title//{' + A + '}t'))
    out.append(book.el('p', title or 'Данные диаграммы'))
    series = root.findall('.//{' + C + '}ser')
    if not series:
        if book.reading:
            out.append(book.el('p', '[У диаграммы нет сохранённых данных для текстового просмотра.]')); return
        book.fail('Диаграмма без сохранённых данных не может быть перенесена.')
    table = book.el('table'); out.append(table)
    for s in series:
        name = ' '.join(n.text or '' for n in s.findall('./{' + C + '}tx//{' + C + '}v'))
        row = book.el('tr'); table.append(row); row.append(book.el('th', name))
        values = s.findall('.//{' + C + '}numCache/{' + C + '}pt')
        labels = s.findall('.//{' + C + '}strCache/{' + C + '}pt')
        if not values:
            if book.reading:
                row.append(book.el('td', '[Нет сохранённых числовых данных]')); continue
            book.fail('В диаграмме нет сохранённых числовых данных.')
        if len(values) > 100000: book.fail('В диаграмме слишком много точек.')
        for index, value in enumerate(values):
            v = value.find('{' + C + '}v'); text = v.text or '' if v is not None else ''
            label = labels[index].find('{' + C + '}v') if index < len(labels) else None
            if label is not None: text = (label.text or '') + ': ' + text
            row.append(book.el('td', text))
    book.warnings.add('Диаграммы перенесены таблицами сохранённых данных; их графическое оформление не воспроизводится.')


def _drawing(book, package, root, part, out):
    rel = package.relationships(part)
    for node in root.iter():
        if node.tag == '{' + A + '}blip':
            rid = node.get('{' + R + '}embed')
            image = _relation(book, package, rel, rid)
            paragraph = book.el('p'); paragraph.append(book.image(package.data(image))); out.append(paragraph)
        elif node.tag == '{' + C + '}chart':
            _chart(book, package, _relation(book, package, rel, node.get('{' + R + '}id')), out)
        elif book.c.tag(node) in {'oleObj', 'relIds', 'contentPart'}:
            if book.reading:
                out.append(book.el('p', '[Встроенный объект: показано только доступное изображение. Для полного вида откройте исходный документ во внешнем просмотрщике.]'))
                book.warnings.add('Встроенные OLE-объекты и SmartArt показаны доступными изображениями; содержимое объектов не выполняется.')
            else: book.fail('Встроенные OLE-объекты или SmartArt пока нельзя перенести без потери содержимого. Сохраните документ как PDF.')


def read_presentation(book, package):
    root = package.xml('ppt/presentation.xml'); rel = package.relationships('ppt/presentation.xml')
    slides = root.findall('./{' + P + '}sldIdLst/{' + P + '}sldId')
    if len(slides) > 10000: book.fail('В презентации слишком много слайдов.')
    for number, slide in enumerate(slides, 1):
        part = _relation(book, package, rel, slide.get('{' + R + '}id'))
        content = package.xml(part); section = book.el('section'); book.body.append(section)
        section.append(book.el('h1', 'Слайд ' + str(number)))
        def shape(node):
            if node.tag == '{' + P + '}grpSp':
                for child in node: shape(child)
                return
            table = node.find('.//{' + A + '}tbl')
            if table is not None:
                target = book.el('table'); section.append(target)
                for row in table.findall('{' + A + '}tr'):
                    tr = book.el('tr'); target.append(tr)
                    for cell in row.findall('{' + A + '}tc'):
                        td = book.el('td'); tr.append(td)
                        for paragraph in cell.findall('.//{' + A + '}p'):
                            p = book.el('p'); _rich(book, paragraph, p); td.append(p)
            else:
                for paragraph in node.findall('.//{' + A + '}p'):
                    p = book.el('p'); _rich(book, paragraph, p)
                    if book.c.plain(p): section.append(p)
            _drawing(book, package, node, part, section)
        shapes = content.find('.//{' + P + '}spTree')
        if shapes is not None:
            for node in shapes: shape(node)
        else:
            for node in content: shape(node)
        # Notes contain placeholders for slide number and thumbnails. Only
        # the body placeholder is the author's actual speaker note.
        for target, external in package.relationships(part).values():
            if external or not target.startswith('ppt/notesSlides/notesSlide') or not target.endswith('.xml'): continue
            notes = package.xml(target)
            for shape in notes.findall('.//{' + P + '}sp'):
                placeholder = shape.find('.//{' + P + '}ph')
                if placeholder is None or placeholder.get('type') != 'body': continue
                section.append(book.el('h2', 'Заметки докладчика'))
                for paragraph in shape.findall('.//{' + A + '}p'):
                    p = book.el('p'); _rich(book, paragraph, p)
                    if book.c.plain(p): section.append(p)
    book.warnings.add('Презентация адаптирована для чтения: порядок слайдов, текст, таблицы и встроенные изображения сохранены; расположение объектов и анимация упрощены.')


def _cell_value(book, cell, shared, styles, date1904):
    kind = cell.get('t', 'n'); value = cell.find('{' + X + '}v')
    text = value.text or '' if value is not None else ''
    if kind == 'inlineStr': return ''.join(n.text or '' for n in cell.findall('.//{' + X + '}t'))
    if kind == 's':
        try: return shared[int(text)]
        except (ValueError, IndexError): book.fail('Некорректный индекс строки XLSX.')
    if kind == 'b': return 'Да' if text == '1' else 'Нет'
    if kind == 'e': return 'Ошибка: ' + text
    formula = cell.find('{' + X + '}f')
    if formula is not None:
        book.warnings.add('Формулы таблиц не пересчитываются: показаны сохранённые результаты. Без результата показана сама формула.')
        if value is None: return '=' + (formula.text or '')
    try:
        style = int(cell.get('s', '0'))
        fmt = styles[style] if style < len(styles) else 0
        if kind == 'n' and fmt in {14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47} and text:
            days = float(text)
            origin = datetime(1904, 1, 1) if date1904 else datetime(1899, 12, 30)
            # Excel's fictitious leap day only affects serials before March 1900.
            if not date1904 and days < 60: days += 1
            moment = origin + timedelta(days=days)
            return moment.strftime('%H:%M:%S' if fmt in {18, 19, 20, 21, 45, 46, 47} else '%d.%m.%Y %H:%M' if fmt == 22 else '%d.%m.%Y')
        if kind == 'n' and fmt in {9, 10} and text: return format(float(text) * 100, '.0f' if fmt == 9 else '.2f') + '%'
    except (ValueError, OverflowError): book.fail('Некорректное числовое значение XLSX.')
    return text


def read_spreadsheet(book, package):
    root = package.xml('xl/workbook.xml'); rel = package.relationships('xl/workbook.xml')
    strings = package.xml('xl/sharedStrings.xml', True)
    shared = [''.join(t.text or '' for t in n.iter('{' + X + '}t')) for n in strings] if strings is not None else []
    style_root = package.xml('xl/styles.xml', True)
    styles = [int(n.get('numFmtId', '0')) for n in style_root.findall('./{' + X + '}cellXfs/{' + X + '}xf')] if style_root is not None else []
    props = root.find('{' + X + '}workbookPr'); date1904 = props is not None and props.get('date1904') in {'1', 'true'}
    count = 0
    for sheet in root.findall('./{' + X + '}sheets/{' + X + '}sheet'):
        part = _relation(book, package, rel, sheet.get('{' + R + '}id'))
        content = package.xml(part); section = book.el('section'); book.body.append(section)
        section.append(book.el('h1', sheet.get('name', 'Лист')))
        table = book.el('table'); section.append(table)
        for row in content.findall('./{' + X + '}sheetData/{' + X + '}row'):
            tr = book.el('tr')
            for cell in row.findall('{' + X + '}c'):
                text = _cell_value(book, cell, shared, styles, date1904)
                if not text: continue
                count += 1
                if count > 200000: book.fail('В таблице слишком много непустых ячеек для чтения как книги.')
                address = cell.get('r', '')
                tr.append(book.el('td', (address + ': ' if address else '') + text))
            if len(tr): table.append(tr)
        if not len(table):
            section.remove(table); section.append(book.el('p', '[Пустой лист]'))
        for target, external in package.relationships(part).values():
            if not external and target.startswith('xl/drawings/drawing') and target.endswith('.xml'):
                _drawing(book, package, package.xml(target), target, section)
            elif not external and 'comments' in target.lower() and target.endswith('.xml'):
                comments = package.xml(target)
                section.append(book.el('h2', 'Комментарии'))
                for comment in comments.findall('.//{' + X + '}comment'):
                    section.append(book.el('p', comment.get('ref', '') + ': ' + ''.join(t.text or '' for t in comment.iter('{' + X + '}t'))))
    book.warnings.add('Таблица адаптирована для чтения: листы, адреса и значения ячеек сохранены. Макросы и внешние связи не выполняются; сложные числовые форматы упрощаются.')


def read_open_document(book, package, presentation):
    root = package.xml('content.xml')
    count = 0
    def paragraph(node, out):
        p = book.el('p')
        for sub in node.iter():
            if sub is node or sub.tag not in {'{' + T + '}s', '{' + T + '}tab', '{' + T + '}line-break'}: continue
            if sub.tag.endswith('}s'):
                repeat = int(sub.get('{' + T + '}c', '1'))
                if not 1 <= repeat <= 10000: book.fail('Слишком длинный пробел OpenDocument.')
                sub.text = ' ' * repeat
            elif sub.tag.endswith('}tab'): sub.text = '\t'
            else: sub.text = '\n'
        p.text = ''.join(node.itertext()); out.append(p)
    if presentation:
        for number, page in enumerate(root.findall('.//{' + D + '}page'), 1):
            section = book.el('section'); book.body.append(section)
            section.append(book.el('h1', page.get('{' + D + '}name', 'Слайд ' + str(number))))
            for n in page.iter():
                if n.tag in {'{' + T + '}p', '{' + T + '}h'}: paragraph(n, section)
                elif n.tag == '{' + D + '}image':
                    _odf_image(book, package, n, section)
                elif n.tag in {'{' + D + '}object', '{' + D + '}object-ole'}: _odf_object(book, section)
    else:
        for sheet in root.findall('.//{' + TB + '}table'):
            section = book.el('section'); book.body.append(section); section.append(book.el('h1', sheet.get('{' + TB + '}name', 'Лист')))
            table = book.el('table'); section.append(table)
            row_number = 0
            for row in sheet.findall('.//{' + TB + '}table-row'):
                repeat = int(row.get('{' + TB + '}number-rows-repeated', '1'))
                if not 1 <= repeat <= 1048576: book.fail('Некорректное повторение строк ODS.')
                cells = []; column = 0
                for cell in row:
                    if book.c.tag(cell) not in {'table-cell', 'covered-table-cell'}: continue
                    cols = int(cell.get('{' + TB + '}number-columns-repeated', '1'))
                    if not 1 <= cols <= 16384: book.fail('Некорректное повторение столбцов ODS.')
                    text = '\n'.join(''.join(n.itertext()) for n in cell.findall('{' + T + '}p'))
                    if not text:
                        text = next((cell.get('{' + O + '}' + key) for key in ['string-value', 'date-value', 'time-value', 'boolean-value', 'value'] if cell.get('{' + O + '}' + key) is not None), '')
                    formula = cell.get('{' + TB + '}formula')
                    if formula:
                        book.warnings.add('Формулы таблиц не пересчитываются: показаны сохранённые результаты. Без результата показана сама формула.')
                        if not text: text = formula
                    if text:
                        if count + cols * repeat > 200000: book.fail('В ODS слишком много непустых ячеек для чтения как книги.')
                        cells.extend((column + i + 1, text) for i in range(cols))
                    column += cols
                if cells:
                    count += len(cells) * repeat
                    for ri in range(repeat):
                        tr = book.el('tr'); table.append(tr)
                        for col, text in cells: tr.append(book.el('td', f'R{row_number + ri + 1}C{col}: {text}'))
                row_number += repeat
            for node in sheet.iter():
                if node.tag == '{' + D + '}image':
                    _odf_image(book, package, node, section)
                    book.warnings.add('Изображения листа показаны после его ячеек; исходные координаты объектов упрощены.')
                elif node.tag in {'{' + D + '}object', '{' + D + '}object-ole'}: _odf_object(book, section)
    for table in list(book.body.iter('{' + book.c.XH + '}table')):
        if not len(table): table.append(book.el('tr')); table[-1].append(book.el('td', '[Пустой лист]'))
    book.warnings.add('OpenDocument адаптирован для чтения; расположение объектов и сложная офисная вёрстка упрощены.')


def read(book, extension, package_factory, read_docx, read_odt, read_html):
    original = book.source
    if extension in {'.doc', '.dot', '.ppt', '.pps', '.pot', '.xls', '.xlt', '.wps', '.wpd'}:
        if extension in {'.wps', '.wpd'}:
            tool = book.tools_root / 'office' / ('wps2html.exe' if extension == '.wps' else 'wpd2html.exe')
            args = [str(tool), str(original)]; suffix = '.html'
        else:
            tool = book.tools_root / 'doc' / 'HomeLibDoc.exe'
            suffix = '.docx' if extension in {'.doc','.dot'} else '.pptx' if extension in {'.ppt', '.pps', '.pot'} else '.xlsx'
        if not tool.is_file():
            component = 'LegacyOffice' if extension in {'.wps', '.wpd'} else 'DocSharp'
            book.require(component, 'Для чтения ' + extension + ' нужен компонент ' + component + '.')
        if extension in {'.wps', '.wpd'}:
            if os.name == 'nt' and not ('64' in os.environ.get('PROCESSOR_ARCHITEW6432', '') or '64' in os.environ.get('PROCESSOR_ARCHITECTURE', '')):
                book.fail('Комплектный читатель WPS/WPD требует 64-разрядную Windows.')
            for dll in ['libwps-0.4.dll', 'libwpd-0.10.dll', 'librevenge-0.0.dll', 'librevenge-stream-0.0.dll',
                        'librevenge-generators-0.0.dll', 'libc++.dll', 'libunwind.dll', 'zlib1.dll']:
                if not (tool.parent / dll).is_file():
                    book.require('LegacyOffice', 'Неполный комплект чтения WPS/WPD: ' + dll)
        with tempfile.TemporaryDirectory(prefix='homelib-office-', dir=book.work_root) as work:
            prepared = Path(work) / ('prepared' + suffix)
            args = args if suffix == '.html' else [str(tool), str(original), str(prepared)]
            try:
                # Output goes to a bounded-on-read file, never an unbounded PIPE.
                log = Path(work) / 'output.log'
                with log.open('wb') as out:
                    process = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT,
                                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                    started = time.monotonic()
                    try:
                        while process.poll() is None:
                            if time.monotonic() - started > 30: raise subprocess.TimeoutExpired(args, 30)
                            if log.stat().st_size > book.c.MAX_FILE: book.fail('Подготовленный документ превышает 64 МБ.')
                            time.sleep(.025)
                    finally:
                        if process.poll() is None: process.kill()
                        process.wait()
                if process.returncode: book.fail('Компонент не смог прочитать ' + extension + ': ' + log.read_bytes()[:2000].decode('utf-8', errors='replace'))
                if suffix == '.html':
                    if log.stat().st_size > book.c.MAX_FILE: book.fail('Подготовленный документ превышает 64 МБ.')
                    read_html(book, log.read_bytes(), html5=True)
                else:
                    if not prepared.is_file() or prepared.stat().st_size > book.c.MAX_FILE: book.fail('Компонент создал неполный или слишком большой документ.')
                    book.source = prepared
                    if suffix == '.docx': read_docx(book)
                    else: read(book, suffix, package_factory, read_docx, read_odt, read_html)
            except subprocess.TimeoutExpired: book.fail('Чтение офисного документа превысило 30 секунд.')
            finally: book.source = original
        return
    if extension in {'.docm', '.dotx', '.dotm'}: read_docx(book); return
    if extension == '.ott': read_odt(book); return
    package = package_factory(book)
    try:
        if extension in {'.pptx', '.pptm', '.ppsx', '.ppsm', '.potx', '.potm'}: read_presentation(book, package)
        elif extension in {'.xlsx', '.xlsm', '.xltx', '.xltm'}: read_spreadsheet(book, package)
        elif extension in {'.odp', '.otp', '.ods', '.ots'}: read_open_document(book, package, extension in {'.odp', '.otp'})
        else: book.fail('Этот офисный формат пока не поддерживается.')
    finally: package.z.close()

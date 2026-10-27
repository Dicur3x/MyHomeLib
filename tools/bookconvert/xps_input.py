"""Windows XPS fixed pages via the small MIT HomeLibXps renderer."""
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile


def rendered_pages(book, source=None, image_pages=False, report_rendering=True):
    """Yield validated frames while retaining the private renderer job."""
    source = book.source if source is None else source
    kind = 'изображения' if image_pages else 'XPS'
    tool = book.tools_root / 'xps' / 'HomeLibXps.exe'
    if not tool.is_file():
        book.require('BookConverter', 'Модуль подготовки XPS и изображений неполон. Его нужно восстановить.')
    with tempfile.TemporaryDirectory(prefix='homelib-xps-', dir=book.work_root) as directory:
        pages = Path(directory) / 'pages.zip'
        log = Path(directory) / 'render.log'
        with log.open('wb') as output:
            process = subprocess.Popen([str(tool), *(['--image-pages'] if image_pages else []), str(source), str(pages)], stdout=output,
                                       stderr=subprocess.STDOUT,
                                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            started = time.monotonic()
            last_page = 0
            try:
                while process.poll() is None:
                    if time.monotonic() - started > 300:
                        book.fail('Подготовка ' + kind + ' превысила 5 минут.')
                    if log.stat().st_size > 1024 * 1024:
                        book.fail('Компонент XPS вернул слишком большой отчёт.')
                    lines = log.read_text(encoding='utf-8', errors='replace').splitlines()
                    progress = [line.split() for line in lines if line.startswith('PAGE ')]
                    if progress and len(progress[-1]) == 3:
                        page, total = map(int, progress[-1][1:])
                        if page > last_page:
                            book.progress('rendering' if report_rendering else 'preparing-images', page, total if report_rendering else 0)
                            last_page = page
                    time.sleep(.05)
            finally:
                if process.poll() is None: process.kill()
                process.wait()
        if process.returncode or not pages.is_file():
            details = log.read_bytes()[-4000:].decode('utf-8', errors='replace')
            details = '\n'.join(line for line in details.splitlines() if not line.startswith('PAGE '))
            book.fail('Не удалось прочитать ' + kind + ': ' + details)
        with zipfile.ZipFile(pages) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > 10000 or sum(e.file_size for e in entries) > book.c.MAX_TOTAL:
                book.fail('Подготовленные страницы XPS превышают предел чтения.')
            for number, entry in enumerate(entries, 1):
                if entry.filename != f'{number:05d}.png' or not 0 < entry.file_size <= 16 * 1024 * 1024:
                    book.fail('Нарушена последовательность подготовленных страниц XPS.')
                data = archive.read(entry)
                if not data.startswith(b'\x89PNG\r\n\x1a\n'): book.fail('Неверное изображение страницы XPS.')
                yield number, len(entries), data


def read(book, image_pages=False):
    for number, total, data in rendered_pages(book, image_pages=image_pages):
        book.scan_page(data,number,total)
        book.progress('pages', number, total)
    if image_pages:
        book.warnings.add('Все страницы исходного изображения сохранены в PNG с исходными размерами, без OCR. Текстовый поиск и изменение размера букв недоступны.')
    else:
        book.warnings.add('XPS: все страницы сохранены целиком изображениями до 1600 пикселей по большей стороне. Текстовый поиск и изменение размера букв недоступны; оформление и иллюстрации сохраняются без OCR.')

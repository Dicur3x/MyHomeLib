"""Image books and comic archives; keep every page, original files read-only."""
from pathlib import Path
import importlib.util
import posixpath
import re
import subprocess
import tempfile
import zipfile

IMAGES = {'.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp'}


def module(name):
    spec = importlib.util.spec_from_file_location('homelib_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value


def page(book, data, number):
    section = book.el('section', id='page-' + str(number)); book.body.append(section)
    section.append(book.el('h2', 'Страница ' + str(number)))
    paragraph = book.el('p'); section.append(paragraph)
    picture = book.image(data); picture.set('alt', 'Страница ' + str(number)); paragraph.append(picture)


def decode_webp(book, data):
    import ctypes as C
    import struct
    import zlib
    path = book.tools_root / 'webp/libwebp.dll'
    if not path.is_file(): book.require('WebP', 'Для изображения WebP нужен компонент WebP.')
    try: library = C.CDLL(str(path))
    except OSError: book.fail('Не удалось загрузить WebP нужной разрядности.')
    library.WebPGetInfo.argtypes = [C.c_void_p,C.c_size_t,C.POINTER(C.c_int),C.POINTER(C.c_int)]
    library.WebPGetInfo.restype = C.c_int
    library.WebPDecodeRGBA.argtypes = [C.c_void_p,C.c_size_t,C.POINTER(C.c_int),C.POINTER(C.c_int)]
    library.WebPDecodeRGBA.restype = C.c_void_p
    library.WebPFree.argtypes = [C.c_void_p];library.WebPFree.restype = None
    source = C.create_string_buffer(data);width=C.c_int();height=C.c_int()
    if not library.WebPGetInfo(source,len(data),C.byref(width),C.byref(height)) or not 0 < width.value <= 16384 or not 0 < height.value <= 16384 or width.value*height.value > 16777216:
        book.fail('Некорректное или слишком большое изображение WebP.')
    pixels = library.WebPDecodeRGBA(source,len(data),C.byref(width),C.byref(height))
    if not pixels: book.fail('WebP не удалось декодировать.')
    try: raw=C.string_at(pixels,width.value*height.value*4)
    finally: library.WebPFree(pixels)
    def chunk(kind,value):return struct.pack('>I',len(value))+kind+value+struct.pack('>I',zlib.crc32(kind+value)&0xffffffff)
    stride=width.value*4;rows=b''.join(b'\0'+raw[at:at+stride] for at in range(0,len(raw),stride))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width.value,height.value,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')


def read(book, extension):
    if extension in {'.tif','.tiff','.bmp'}:
        module('xps_input').read(book, image_pages=True)
        return
    if extension in IMAGES:
        page(book, book.source.read_bytes(), 1)
    else:
        names = []; archive = None
        try:
            if zipfile.is_zipfile(book.source):
                archive = zipfile.ZipFile(book.source)
                entries = archive.infolist()
                if len(entries) > 20000 or sum(entry.file_size for entry in entries) > book.c.MAX_TOTAL:
                    book.fail('Архив изображений превышает предел конвертации.')
                sizes = {}
                for entry in entries:
                    if entry.is_dir(): continue
                    name = entry.filename
                    if name in sizes: book.fail('В комиксе повторяются имена страниц.')
                    sizes[name] = entry.file_size
                def get(name):
                    if not 0 < sizes[name] <= 16 * 1024 * 1024: book.fail('Страница комикса превышает 16 МБ или пуста.')
                    return archive.read(name)
                names = list(sizes)
            else:
                tool = book.tools_root / '7zip/7z.exe'
                if not tool.is_file(): book.require('7-Zip', 'Для чтения этого комикса нужен 7-Zip.')
                def run(args, maximum):
                    with tempfile.TemporaryFile(dir=book.work_root) as output:
                        try:
                            process = subprocess.run([str(tool),'-sccUTF-8',*args],stdout=output,stderr=subprocess.PIPE,
                                timeout=40,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                        except subprocess.TimeoutExpired: book.fail('Чтение архива комикса превысило 40 секунд.')
                        if process.returncode: book.fail('Не удалось прочитать архив комикса: ' + process.stderr.decode('utf-8',errors='replace')[-500:])
                        if output.tell() > maximum: book.fail('Архив комикса превышает предел чтения.')
                        output.seek(0); return output.read()
                listing = run(['l','-slt','-ba','--',str(book.source)],8*1024*1024).decode('utf-8')
                sizes = {}; total = 0
                for block in re.split(r'\r?\n\s*\r?\n',listing):
                    properties = dict(line.split(' = ',1) for line in block.splitlines() if ' = ' in line)
                    if 'Path' not in properties or properties.get('Folder') == '+': continue
                    name = properties['Path']; size = int(properties.get('Size','0')); total += size
                    if name in sizes or size < 0 or total > book.c.MAX_TOTAL or len(sizes) >= 20000: book.fail('Некорректный или слишком большой архив комикса.')
                    sizes[name] = size
                def get(name):
                    if not 0 < sizes[name] <= 16*1024*1024: book.fail('Страница комикса превышает 16 МБ или пуста.')
                    data = run(['e','-so','-spd','--',str(book.source),name],16*1024*1024)
                    if len(data) != sizes[name]: book.fail('Неполная страница комикса.')
                    return data
                names = list(sizes)
            pages = []
            for name in names:
                normalized = name.replace('\\','/')
                if normalized.startswith('/') or ':' in normalized or '..' in normalized.split('/') or '\0' in normalized:
                    book.fail('Некорректное имя страницы комикса.')
                if Path(normalized).suffix.lower() in IMAGES: pages.append(name)
                elif posixpath.basename(normalized).lower() not in {'comicinfo.xml','.ds_store','thumbs.db'}:
                    book.fail('В архиве комикса найден файл, который не является страницей: ' + name[:160])
            if not pages or len(pages) > 5000: book.fail('В комиксе нет страниц или их слишком много.')
            def order(value):
                return [int(piece) if piece.isdigit() else piece.casefold() for piece in re.split(r'(\d+)',value)]
            for number, name in enumerate(sorted(pages,key=order),1):
                if Path(name).suffix.lower() in {'.tif','.tiff'}:
                    book.fail('Многостраничный TIFF внутри комикса нужно сначала открыть отдельной книгой; страницы не будут удалены молча.')
                page(book,get(name),number);book.progress('pages',number,len(pages))
        finally:
            if archive is not None: archive.close()
    book.warnings.add('Страницы книги сохранены изображениями в исходном порядке. OCR не выполняется; текстовый поиск и изменение размера букв недоступны.')

"""Image books and comic archives; keep every page, original files read-only."""
from pathlib import Path
import importlib.util
import posixpath
import re
import struct
import subprocess
import tempfile
import zipfile

IMAGES = {'.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp'}


def module(name):
    spec = importlib.util.spec_from_file_location('homelib_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value


def page(book, data, number, total=0):
    book.scan_page(data,number,total)


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


def tiff_pages(book, source, report_rendering=True):
    try:
        prepared=module('tiff_jpeg').pages(source,book.c.MAX_TOTAL)
        if prepared is not None:
            total,pictures=prepared
            for number,data in enumerate(pictures,1):yield number,total,data,'.jpg'
            return
    except (ValueError,KeyError,struct.error) as error:book.fail('Не удалось прочитать TIFF: '+str(error))
    for number,total,data in module('xps_input').rendered_pages(book,source,True,report_rendering):
        yield number,total,data,'.png'


def read(book, extension):
    if extension in {'.tif','.tiff'}:
        for number,total,data,_suffix in tiff_pages(book,book.source):
            page(book,data,number,total);book.progress('pages',number,total)
        book.warnings.add('Все страницы TIFF сохранены изображениями с исходными размерами; JPEG внутри TIFF переносится без повторного сжатия. OCR не выполняется; текстовый поиск и изменение размера букв недоступны.')
        return
    if extension=='.bmp':
        module('xps_input').read(book, image_pages=True)
        return
    if extension in IMAGES:
        page(book, book.source.read_bytes(), 1, 1)
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
                def get(name, maximum=16 * 1024 * 1024):
                    if not 0 < sizes[name] <= maximum: book.fail('Страница комикса превышает допустимый размер или пуста.')
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
                def get(name, maximum=16 * 1024 * 1024):
                    if not 0 < sizes[name] <= maximum: book.fail('Страница комикса превышает допустимый размер или пуста.')
                    data = run(['e','-so','-spd','--',str(book.source),name],maximum)
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
            with tempfile.TemporaryDirectory(prefix='homelib-comic-frames-',dir=book.work_root) as directory:
                expanded=[];prepared_bytes=0;root=Path(directory)
                for index,name in enumerate(sorted(pages,key=order)):
                    if Path(name).suffix.lower() in {'.tif','.tiff'}:
                        # A multipage TIFF is a container of pages. Its source
                        # limit matches a standalone TIFF; each decoded page
                        # still passes the usual picture/resource bounds.
                        data=get(name,book.c.MAX_TOTAL)
                        if len(data)>16*1024*1024 and data[:4] not in (b'II*\0',b'MM\0*'):
                            book.fail('Отдельное изображение комикса превышает 16 МБ; увеличенный предел предусмотрен для многостраничного TIFF.')
                        source=root/('source-'+str(index)+'.tif');source.write_bytes(data)
                        del data
                        for frame,_total,data,suffix in tiff_pages(book,source,False):
                            prepared_bytes+=len(data)
                            if prepared_bytes>book.c.MAX_TOTAL or len(expanded)>=5000:book.fail('Подготовленные страницы комикса превышают предел чтения.')
                            target=root/(str(index)+'-'+str(frame)+suffix);target.write_bytes(data)
                            expanded.append((target,None))
                        source.unlink()
                    else:
                        prepared_bytes+=sizes[name]
                        if prepared_bytes>book.c.MAX_TOTAL or len(expanded)>=5000:book.fail('Подготовленные страницы комикса превышают предел чтения.')
                        expanded.append((None,name))
                for number,(prepared,name) in enumerate(expanded,1):
                    page(book,prepared.read_bytes() if prepared is not None else get(name),number,len(expanded))
                    book.progress('pages',number,len(expanded))
        finally:
            if archive is not None: archive.close()
    book.warnings.add('Страницы книги сохранены изображениями в исходном порядке. OCR не выполняется; текстовый поиск и изменение размера букв недоступны.')

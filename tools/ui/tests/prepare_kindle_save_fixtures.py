"""Create owned, illustrated sources for the isolated native Save As test."""
import base64
import importlib.util
from pathlib import Path
import struct
import sys
import zlib


def load(path):
    spec = importlib.util.spec_from_file_location('kindle_save_fixture_api', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(profile, advanced=False):
    profile = Path(profile).resolve()
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('Only an owned native regression profile is allowed')
    root = profile / 'kindle-save-fixtures'
    root.mkdir()
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    pixels = b''.join(b'\0' + bytes((row % 256, 100, 180)) * 256 for row in range(384))
    picture = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 256, 384, 8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
    source = root / 'source.fb2'
    source.write_text('''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>sf</genre><author><first-name>Анна</first-name><last-name>Проверка</last-name></author><book-title>Kindle — проверка</book-title><coverpage><image l:href="#cover"/></coverpage><lang>ru</lang></title-info></description>
<body><section id="one"><title><p>Первая глава</p></title><p>Ёжик читает книгу. English text. <strong>Жирный текст</strong> и <emphasis>курсив</emphasis>. <a l:href="#note" type="note">1</a></p><image l:href="#cover"/></section><section id="two"><title><p>Вторая глава</p></title><p>Последний абзац — конец книги.</p></section></body>
<body name="notes"><section id="note"><title><p>1</p></title><p>Проверочная сноска.</p></section></body>
<binary id="cover" content-type="image/png">''' + base64.b64encode(picture).decode('ascii') + '</binary></FictionBook>', encoding='utf-8')
    repository = Path(__file__).resolve().parents[3]
    api = load(repository / 'tools/bookconvert/convert_book.py')
    api.convert_book(source, root / 'source.epub')
    if advanced:
        tests = repository / 'tools/bookconvert/tests'
        load(tests / 'test_text_inputs.py').docx(root / 'source.docx')
        (root / 'source.pdf').write_bytes(load(tests / 'test_legacy_fixed.py').pdf_fixture())
    print('Prepared owned FB2 and EPUB with chapters, notes, Unicode and an illustration')


if __name__ == '__main__':
    main(sys.argv[1], advanced="--advanced" in sys.argv[2:])

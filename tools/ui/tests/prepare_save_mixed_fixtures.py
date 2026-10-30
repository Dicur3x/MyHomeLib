"""Small real documents for the native mixed Save As regression."""
from pathlib import Path
import base64
import importlib.util
import io
import shutil
import subprocess
import sys
import tarfile
import zipfile
from PIL import Image, ImageDraw


def prepare(profile, runtime):
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('Owned native test profile required')
    target = profile / 'mixed-save-inputs'
    target.mkdir()
    image = Image.new('RGB', (640, 480), 'white')
    draw = ImageDraw.Draw(image)
    for y in range(20, 460, 30):
        draw.text((24, y), 'Readable illustration: ABC 0123456789', fill='black')
        draw.rectangle((400, y, 600, y + 18), fill=(y % 200, 80, 170))
    buffer = io.BytesIO()
    image.save(buffer, format='PNG')
    png = buffer.getvalue()
    text = 'Mixed native save. Full text, final sentence. Ё, Україна, 中文.'
    (target / 'source.fb2').write_text(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'
        '<description><title-info><book-title>Mixed source</book-title><lang>en</lang></title-info></description>'
        '<body><section><p>' + text + '</p><image l:href="#illustration"/></section></body>'
        '<binary id="illustration" content-type="image/png">' + base64.b64encode(png).decode() +
        '</binary></FictionBook>', encoding='utf-8')
    with zipfile.ZipFile(target / 'source.epub', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr('book.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">mixed</dc:identifier><dc:title>Mixed source</dc:title><dc:language>en</dc:language></metadata><manifest><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.png" media-type="image/png"/></manifest><spine><itemref idref="body"/></spine></package>')
        archive.writestr('body.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Mixed</title></head><body><p>' + text + '</p><p><img src="image.png" alt="Illustration"/></p></body></html>')
        archive.writestr('image.png', png)
    tests = Path(__file__).resolve().parents[2] / 'bookconvert/tests'
    spec = importlib.util.spec_from_file_location('native_mixed_helpers', tests / 'test_legacy_fixed.py')
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    (target / 'source.pdf').write_bytes(helpers.pdf_fixture())
    (target / 'scan.pdf').write_bytes(helpers.pdf_fixture(text=False))
    source = target / 'djvu-original.djvu'
    try:
        with tarfile.open(runtime / 'tools/djvu/djvulibre-3.5.29.tar.gz') as archive:
            source.write_bytes(archive.extractfile('djvulibre-3.5.29/doc/djvulibre-book-en.djvu').read())
        output = target / 'source.djvu'
        result = subprocess.run([str(runtime / 'tools/djvu/djvused.exe'), str(source), '-e',
            'select 1; save-page-with "' + str(output).replace('\\', '/') + '"'],
            capture_output=True, timeout=30, creationflags=0x08000000)
        if result.returncode or not output.is_file():
            raise ValueError('DjVu fixture generation failed: ' + result.stderr.decode(errors='replace'))
        scan = target / 'scan.djvu'
        shutil.copyfile(output, scan)
        result = subprocess.run([str(runtime / 'tools/djvu/djvused.exe'), str(scan), '-s', '-e', 'remove-txt'],
            capture_output=True, timeout=30, creationflags=0x08000000)
        if result.returncode:
            raise ValueError('Scan DjVu fixture generation failed: ' + result.stderr.decode(errors='replace'))
    finally:
        source.unlink(missing_ok=True)


if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())

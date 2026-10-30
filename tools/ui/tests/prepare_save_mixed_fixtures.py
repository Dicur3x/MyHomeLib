"""Small real documents for the native mixed Save As regression."""
from pathlib import Path
import base64
import importlib.util
import io
import json
import shutil
import subprocess
import tarfile
import zipfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw


def prepare(profile, runtime, doc_payload=None):
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
    if doc_payload is not None:
        if not doc_payload.startswith(bytes.fromhex('D0CF11E0A1B11AE1')):
            raise ValueError('A real binary Word source is required')
        doc, reference = target / 'source.doc', target / 'doc-reference.docx'
        doc.write_bytes(doc_payload)
        result = subprocess.run([str(runtime / 'tools/doc/HomeLibDoc.exe'), str(doc), str(reference)],
            capture_output=True, timeout=40, creationflags=0x08000000)
        if result.returncode:
            raise ValueError('DOC reference preparation failed: ' + result.stderr.decode(errors='replace'))
        ns = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
        with zipfile.ZipFile(reference) as archive:
            document = ET.fromstring(archive.read('word/document.xml'))
            paragraphs = [''.join(node.text or '' for node in paragraph.iter(ns + 't'))
                          for paragraph in document.findall('.//' + ns + 'body//' + ns + 'p')]
            paragraphs = [text for text in paragraphs if text.strip()]
            images = sum(name.startswith('word/media/') and not name.endswith('/') for name in archive.namelist())
        if not paragraphs:
            raise ValueError('DOC reference body is empty')
        (target / 'doc-reference.json').write_text(json.dumps(dict(paragraphs=paragraphs,images=images),
            ensure_ascii=False), encoding='utf-8')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile',type=Path)
    parser.add_argument('runtime',type=Path)
    parser.add_argument('--doc-inventory',type=Path)
    args = parser.parse_args()
    doc_payload = None
    if args.doc_inventory:
        from doc_save_conversion_probe import read_doc_sample
        doc_payload, _ = read_doc_sample(args.doc_inventory)
    prepare(args.profile.resolve(),args.runtime.resolve(),doc_payload)

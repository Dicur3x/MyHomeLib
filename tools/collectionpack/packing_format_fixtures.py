"""Small valid EPUB/PDF inputs for native JPEG XL round trips; no user data."""
import hashlib
import io
import random
import zipfile


def fixtures():
    from PIL import Image
    rng = random.Random(14014)
    images = []
    for _ in range(2):
        with io.BytesIO() as stream:
            Image.frombytes('RGB', (256, 192), rng.randbytes(256 * 192 * 3)).save(
                stream, format='JPEG', quality=92, optimize=True)
            images.append(stream.getvalue())

    # Explicit xref and direct DCT streams make every source byte testable.
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        b'/Resources << /XObject << /Im1 4 0 R /Im2 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 7 0 R >>']
    for image in images:
        objects.append(b'<< /Type /XObject /Subtype /Image /Width 256 /Height 192 /ColorSpace /DeviceRGB '
            b'/BitsPerComponent 8 /Filter /DCTDecode /Length ' + str(len(image)).encode() +
            b' >>\nstream\n' + image + b'\nendstream')
    objects.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    content = (b'BT /F1 14 Tf 20 750 Td (Native JPEG XL exact PDF) Tj ET\n'
               b'q 256 0 0 192 20 500 cm /Im1 Do Q\nq 256 0 0 192 300 500 cm /Im2 Do Q\n')
    objects.append(b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'endstream')
    pdf, offsets = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'), [0]
    for number, value in enumerate(objects, 1):
        offsets.append(len(pdf)); pdf.extend(f'{number} 0 obj\n'.encode() + value + b'\nendobj\n')
    xref = len(pdf)
    pdf.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        pdf.extend(f'{offset:010d} 00000 n \n'.encode())
    pdf.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())

    chapter = ('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Exact text</title>'
        '<link href="book.css" rel="stylesheet" type="text/css"/></head><body><h1>Native EPUB</h1>' +
        '<p>Keep this text and its inline <em>structure</em>.</p>' * 40 +
        '<img src="Images/%D0%B0%D1%80%D1%82%201.jpg" alt="Illustration"/></body></html>')
    assets = {
        'mimetype': b'application/epub+zip',
        'META-INF/container.xml': b'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'OPS/book.opf': b'''<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">native-jxl-epub</dc:identifier><dc:title>Native EPUB</dc:title><dc:language>en</dc:language><meta name="cover" content="cover"/></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="front" href="cover.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="Images/cover.jpg" media-type="image/jpeg"/><item id="art" href="Images/%D0%B0%D1%80%D1%82%201.jpg" media-type="image/jpeg"/><item id="css" href="book.css" media-type="text/css"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="asset" href="data.bin" media-type="application/octet-stream"/></manifest><spine toc="ncx"><itemref idref="front"/><itemref idref="chapter"/></spine><guide><reference type="cover" title="Cover" href="cover.xhtml"/></guide></package>''',
        'OPS/cover.xhtml': b'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head><body><img src="Images/cover.jpg" alt="Cover"/></body></html>',
        'OPS/chapter.xhtml': chapter.encode(),
        'OPS/book.css': b'p { line-height:1.25; } em { font-style:italic; }',
        'OPS/toc.ncx': b'<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="native-jxl-epub"/></head><docTitle><text>Native EPUB</text></docTitle><navMap><navPoint id="chapter" playOrder="1"><navLabel><text>Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>',
        'OPS/Images/cover.jpg': images[0], 'OPS/Images/арт 1.jpg': images[1],
        'OPS/data.bin': b'Preserve every auxiliary resource.\x00\xff' * 20,
    }
    with io.BytesIO() as stream:
        with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, data in assets.items():
                archive.writestr(name, data, compress_type=zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED)
        epub = stream.getvalue()
    return {'one.pdf': bytes(pdf), 'two.epub': epub}, {
        'pdf_sha256': hashlib.sha256(pdf).hexdigest(),
        'sizes': [len(pdf), len(epub)],
        'epub_assets': {name: hashlib.sha256(value).hexdigest() for name, value in assets.items()},
    }

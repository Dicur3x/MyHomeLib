"""Check a candidate Boko executable against direct EPUB export fixtures."""

import argparse
from base64 import b64decode
import json
from pathlib import Path
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/bookconvert/tests'))
from test_epub3_output import conversion, docx, legacy_epub, PNG
from test_conversion import png_chunk
from test_isilo_input import png_pixels
from kfx_image_input import prepare


SVG = b'''<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"
 viewBox="0 0 20 20"><title>Vector graph</title>
 <rect width="20" height="20" fill="#336699"/></svg>'''
WRAPPED = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
           + png_chunk(b'IDAT', zlib.compress(b'\x00\xcc\x33\x22\xff')) + png_chunk(b'IEND', b''))


def rich_epub(source, destination, include_inline=False):
    with zipfile.ZipFile(source) as archive, zipfile.ZipFile(destination, 'x') as result:
        package = conversion.xml(archive.read('OPS/book.opf'))
        manifest = conversion.first(package, 'manifest')
        navigation = next(node for node in manifest if node.get('properties') == 'nav')
        old_path = 'OPS/' + navigation.get('href')
        navigation.set('href', 'nav/navigation.xhtml')
        ncx = next(node for node in manifest if node.get('media-type') == 'application/x-dtbncx+xml')
        ncx_path = 'OPS/' + ncx.get('href')
        manifest.remove(ncx)
        manifest.append(conversion.element(conversion.OP, 'item', id='graph', href='art.svg',
                                           **{'media-type': 'image/svg+xml'}))
        if include_inline:
            next(node for node in manifest if node.get('id') == 'chapter').set('properties', 'svg')
            manifest.append(conversion.element(conversion.OP, 'item', id='wrapped', href='wrapped.png',
                                               **{'media-type': 'image/png'}))
        conversion.first(package, 'spine').attrib.pop('toc', None)
        for entry in archive.infolist():
            if entry.filename == ncx_path:
                continue
            data = archive.read(entry)
            if entry.filename == 'OPS/book.opf':
                data = conversion.serialized(package)
            elif entry.filename == 'OPS/text/chapter.xhtml':
                inline_svg = SVG.replace(b'Vector graph', b'Inline graph').replace(
                    b'<rect width="20"', b'<rect x="10" width="10"')
                inline = (b'<p>' + inline_svg + b'</p>'
                          b'<div><svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">'
                          b'<title>Raster wrapper</title><image width="16" height="16" '
                          b'href="../wrapped.png"/></svg></div>') if include_inline else b''
                data = data.replace(b'</body>', b'''
                    <p><em>Italic token</em> and <strong>Bold token</strong></p>
                    <p class="verse">Styled red verse</p>
                    <p><img src="../art.svg" alt="Vector graph"/></p>''' + inline + b'</body>')
            elif entry.filename == 'OPS/book.css':
                data += b'\n.verse { color: red; font-style: italic; margin-left: 2em; }'
            elif entry.filename == old_path:
                result.writestr('OPS/nav/navigation.xhtml', data.replace(b'href="text/', b'href="../text/'))
                continue
            result.writestr(entry, data)
        result.writestr('OPS/art.svg', SVG)
        if include_inline:
            result.writestr('OPS/wrapped.png', WRAPPED)


def run(exe, *args):
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True, timeout=90)
    if result.returncode:
        detail = result.stderr.decode('utf-8', 'replace').strip()
        raise RuntimeError(f'Boko exited with 0x{result.returncode & 0xffffffff:08x}. {detail}')
    return result.stdout


def check_toc(archive, expected):
    nav = conversion.xhtml(archive.read('OEBPS/nav.xhtml'))
    actual = []
    for anchor in nav.iter(f'{{{conversion.XH}}}a'):
        label = ''.join(anchor.itertext()).strip()
        target, fragment = anchor.get('href').split('#', 1)
        assert any(node.get('id') == fragment for node in
                   conversion.xhtml(archive.read('OEBPS/' + target)).iter()), label
        actual.append(label)
    assert actual == expected, actual


def check_note_links(chapters, office):
    documents = {name: conversion.xhtml(data) for name, data in chapters.items()}
    identifiers = {name: {node.get('id') for node in doc.iter() if node.get('id')}
                   for name, doc in documents.items()}
    links = []
    for name, doc in documents.items():
        for anchor in doc.iter(f'{{{conversion.XH}}}a'):
            target, separator, fragment = anchor.get('href', '').partition('#')
            if separator and (not target or target.startswith('chapter_')):
                location = 'OEBPS/' + target if target else name
                assert fragment in identifiers.get(location, ()), (name, target, fragment)
                links.append((name, location))
    assert len(links) >= (1 if office else 2), links
    if not office:
        assert all(source != target for source, target in links)


def render_illustration(rasterizer, root, svg):
    vector = root / 'diagram.svg'
    raster = root / 'diagram.png'
    vector.write_bytes(svg)
    raster.unlink(missing_ok=True)
    run(rasterizer, '--skip-system-fonts', '--zoom', '2', vector, raster)
    image = raster.read_bytes()
    assert image.startswith(b'\x89PNG\r\n\x1a\n')
    dimensions, pixels = png_pixels(image)
    if b'Raster wrapper' in svg:
        assert dimensions[:4] == (32, 32, 8, 6) and pixels[1:5] == b'\xcc\x33\x22\xff'
    elif b'Inline graph' in svg:
        assert dimensions[:4] == (40, 40, 8, 6)
        row = bytearray(pixels[1:161])
        for index in range(4, len(row)):
            left = row[index - 4]
            predictor = left if pixels[0] in (1, 4) else left // 2 if pixels[0] == 3 else 0
            row[index] = (row[index] + predictor) & 0xff
        assert row[:4] == b'\0\0\0\0' and row[-4:] == b'\x33\x66\x99\xff'
    else:
        assert dimensions[:4] == (40, 40, 8, 6) and pixels[1:5] == b'\x33\x66\x99\xff'
    return image


def verify(exe, root, font, rasterizer=None):
    legacy = root / 'legacy.epub'
    epub3 = root / 'upgraded.epub'
    rich = root / 'rich.epub'
    word = root / 'word.docx'
    office = root / 'word.epub'
    legacy_epub(legacy, font)
    conversion.convert_book(legacy, epub3, output_profile='epub3')
    rich_epub(epub3, rich, include_inline=bool(rasterizer))
    docx(word)
    conversion.convert_book(word, office, output_profile='epub3')

    fixtures = (
        (legacy, ['Chapter one', 'Note'], ('Chapter one', 'Note text', 'Cell')),
        (rich, ['Chapter one', 'Note'], ('Chapter one', 'Note text', 'Cell')),
        (office, ['Глава один', 'Подглава', 'Глава два'], ('Точная сноска', 'Ячейка')),
    )
    for source, navigation, snippets in fixtures:
        original = source.read_bytes()
        kfx = source.with_suffix('.kfx')
        restored = source.with_suffix('.roundtrip.epub')
        prepared = source
        expected_images = {}
        if source == rich and rasterizer:
            prepared = source.with_suffix('.prepared.epub')
            count = prepare(conversion, source, prepared,
                            lambda svg: render_illustration(rasterizer, root, svg))
            assert count == 3
            with zipfile.ZipFile(prepared) as archive:
                chapter = conversion.xhtml(archive.read('OPS/text/chapter.xhtml'))
                for image in chapter.iter(f'{{{conversion.XH}}}img'):
                    if label := image.get('alt'):
                        name = 'OPS/' + image.get('src').removeprefix('../')
                        expected_images[label] = archive.read(name)
            assert {'Vector graph', 'Inline graph', 'Raster wrapper'} <= expected_images.keys()
            expected_images.pop('Image')
        elif source == rich:
            expected_images = {'Vector graph': SVG}
        run(exe, 'convert', prepared, kfx)
        metadata = json.loads(run(exe, 'info', '--json', kfx))
        assert metadata['toc'][0].get('children'), metadata['toc']
        assert kfx.read_bytes().startswith(b'CONT')
        run(exe, 'convert', kfx, restored)
        with zipfile.ZipFile(restored) as archive:
            check_toc(archive, navigation)
            chapters = {name: archive.read(name) for name in archive.namelist()
                        if name.startswith('OEBPS/chapter_') and name.endswith('.xhtml')}
            body = b'\n'.join(chapters.values()).decode('utf-8')
            assert '<table' in body and all(fragment in body for fragment in snippets)
            check_note_links(chapters, source == office)
            images = [archive.read(name) for name in archive.namelist() if name.startswith('OEBPS/e')]
            if source != office:
                assert b64decode(PNG) in images
                assert any(archive.read(name) == font for name in archive.namelist()
                           if name.startswith('OEBPS/fonts/'))
            if source == rich:
                illustrations = {node.get('alt'): archive.read('OEBPS/' + node.get('src'))
                                 for chapter in chapters.values()
                                 for node in conversion.xhtml(chapter).iter()
                                 if node.get('alt') in expected_images}
                assert illustrations == expected_images
                css = archive.read('OEBPS/style.css').decode('utf-8')
                assert all(fragment in css for fragment in
                           ('font-style: italic', 'font-weight: bold', '#ff0000', 'margin-left: 2em'))
                assert all(fragment in body for fragment in ('Italic token', 'Bold token', 'Styled red verse'))
        assert source.read_bytes() == original
        if source == rich and rasterizer:
            resources = run(exe, 'kfx-dump', '--field', 'resources', kfx).decode('utf-8')
            assert sum(line.split()[1:3] == ['png', '40x40'] for line in resources.splitlines()) == 2, resources
            assert any(line.split()[1:3] == ['png', '32x32'] for line in resources.splitlines()), resources
            print('PASS external SVG, inline SVG and SVG raster wrapper are linked PNGs with alpha')
        print('PASS', source.name, navigation)

    azw8 = root / 'legacy.azw8'
    run(exe, 'convert', '-t', 'kfx', legacy, azw8)
    kfx_alias = root / 'azw8-as-kfx.kfx'
    kfx_alias.write_bytes(azw8.read_bytes())
    info = json.loads(run(exe, 'info', '--json', kfx_alias))
    assert info['toc'][0]['title'] == 'Chapter one'
    print('PASS explicit AZW8 output parses as KFX')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--writer', type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--font', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--rasterizer', type=Path)
    args = parser.parse_args()
    writer = args.writer.resolve()
    data = writer.read_bytes()
    header = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[:2] == b'MZ' and data[header:header + 4] == b'PE\0\0'
    assert struct.unpack_from('<H', data, header + 4)[0] == {'Win32': 0x14c, 'Win64': 0x8664}[args.platform]
    print(args.platform, run(writer, '--version').decode().strip())
    with TemporaryDirectory(prefix='homelibre-boko-acceptance-', dir=args.scratch) as folder:
        verify(writer, Path(folder), args.font.read_bytes(), args.rasterizer)


if __name__ == '__main__':
    main()

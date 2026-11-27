"""Optional writer boundaries and preservation; real native round-trip is separate."""
import hashlib
import base64
import importlib.util
import re
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c = load('kindle_output_test_api', ROOT / 'convert_book.py')
k = load('kindle_output_test_writer', ROOT / 'kindle_output.py')
legacy_input = load('kindle_input_test_adapter', ROOT / 'kindle_input.py')
reader = load('kindle_reflow_test_adapter', ROOT.parent / 'kindle' / 'convert_kf8.py')


class KindleOutputTests(unittest.TestCase):
    def test_unreadable_font_slots_do_not_shift_later_kindle_resources(self):
        def process_font(index, files, names, sections, data, obfuscation, start, pointer):
            if data == b'FONT-valid':
                names.append('embedded.ttf')
            return names, obfuscation, pointer

        def unpack(source, work, *, epubver, use_hd):
            self.assertTrue(use_hd)
            names = ['before.jpg']
            for index, data in enumerate((b'FONT', b'FONT-short', b'FONT-valid'), start=20):
                module.processFONT(index, None, names, None, data, [], 19, 0)
            names.append('after.jpg')
            self.assertEqual(names, ['before.jpg', None, None, 'embedded.ttf', 'after.jpg'])
            references = legacy_input.Mobi7ImageRecords(names)
            self.assertEqual(references[4], 'after.jpg')
            self.assertEqual(references[1], 'homelibre-missing-mobi-image-2.img')

        class MobiHeader:
            def getRawML(self):
                raise AssertionError('Font test does not decode text')

        module = SimpleNamespace(processFONT=process_font, unpackBook=unpack, MobiHeader=MobiHeader)
        original_reader = MobiHeader.getRawML
        self.assertEqual(reader.unpack_preserving_resource_slots(module, 'book.mobi', 'work', epubver='3'), [21])
        self.assertIs(module.processFONT, process_font)
        self.assertIs(MobiHeader.getRawML, original_reader)
        note = 'Не перенесены встроенные шрифты Kindle. Повреждённые записи: 21.'
        self.assertEqual(c.damaged_content_warnings([note]), [note])

    def test_mobi4_trims_utf8_overlap_only_when_header_and_decoded_length_confirm_it(self):
        valid = 'Первая строка'.encode()
        broken = valid[:5]+b'\xd1'+valid[5:]
        header = bytearray(0xF4)
        struct.pack_into('>I', header, 4, len(valid))
        struct.pack_into('>I', header, 0x14, 0xE4)
        struct.pack_into('>I', header, 0x68, 4)
        struct.pack_into('>H', header, 0xF2, 1)
        initial = bytes(header)
        book = SimpleNamespace(header=initial, version=4, codec='utf-8', sect=SimpleNamespace(ident=b'BOOKMOBI'))

        def reader_with(candidate):
            def read_raw(book):
                data = candidate if struct.unpack_from('>I',book.header,0x68)[0]>=5 else broken
                book.rawSize = len(data)
                return data
            return read_raw

        self.assertEqual(reader.read_mobi_text(reader_with(valid),book),valid)
        self.assertIs(book.header,initial)
        self.assertEqual(book.rawSize,len(valid))
        self.assertEqual(reader.read_mobi_text(reader_with(valid[:-1]),book),broken)
        self.assertEqual(reader.read_mobi_text(reader_with(b'\xff'*len(valid)),book),broken)
        self.assertIs(book.header,initial)
        self.assertEqual(book.rawSize,len(broken))

    def test_legacy_mobi_reads_only_identifiers_present_in_the_source_header(self):
        record = bytearray(248)
        record[16:20] = b'MOBI'
        struct.pack_into('>I', record, 20, 232)
        self.assertEqual(legacy_input.explicit_asins(record), [])
        values = (b'B012345678', b'B012345678', b'not an identifier')
        fields = b''.join(struct.pack('>II', 113, 8 + len(value)) + value for value in values)
        record.extend(b'EXTH' + struct.pack('>II', 12 + len(fields), len(values)) + fields)
        self.assertEqual(legacy_input.explicit_asins(record), ['B012345678'])
        self.assertEqual(legacy_input.explicit_asins(record[:-1]), [])

    def test_gif_cover_is_prepared_as_png_in_private_copy_and_animation_is_not_silently_lost(self):
        gif=base64.b64decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
        source=self.root/'gif.epub';output=self.root/'private-gif.epub'
        with zipfile.ZipFile(self.source) as z:entries={n:z.read(n) for n in z.namelist()}
        entries['OPS/image.png']=gif
        entries['OPS/package.opf']=entries['OPS/package.opf'].replace(b'media-type="image/png"',b'media-type="image/gif" properties="cover-image"')
        with zipfile.ZipFile(source,'w') as z:
            for name,data in entries.items():z.writestr(name,data)
        before=source.read_bytes();tool=self.root/'images.exe';tool.write_bytes(b'mocked image processor')
        png=b'\x89PNG\r\n\x1a\nfixture';warnings=set()
        def run(command,**options):
            self.assertEqual(Path(command[2]).read_bytes(),gif)
            with zipfile.ZipFile(command[3],'x') as z:z.writestr('00001.png',png)
            return SimpleNamespace(returncode=0)
        with mock.patch.object(c,'image_processor_path',return_value=tool),mock.patch.object(k.subprocess,'run',side_effect=run):
            self.assertTrue(k.canonical_input(c,source,output,warnings))
        with zipfile.ZipFile(output) as z:
            self.assertEqual(z.read('OPS/image.png'),png)
            item=next(n for n in c.xml(z.read('OPS/package.opf')).iter() if n.get('href')=='image.png')
            self.assertEqual(item.get('media-type'),'image/png');self.assertEqual(item.get('properties'),'cover-image')
        self.assertTrue(any('GIF' in x for x in warnings));self.assertEqual(source.read_bytes(),before)
        self.assertFalse(list(self.root.glob('homelibre-kindle-cover-*')))
        def animated(command,**options):
            with zipfile.ZipFile(command[3],'x') as z:
                z.writestr('00001.png',png);z.writestr('00002.png',png)
            return SimpleNamespace(returncode=0)
        with mock.patch.object(c,'image_processor_path',return_value=tool),mock.patch.object(k.subprocess,'run',side_effect=animated):
            with self.assertRaisesRegex(c.ConversionError,'несколько кадров'):
                k.png_cover(c,gif,self.root,self.root)
        self.assertFalse(list(self.root.glob('homelibre-kindle-cover-*')))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='homelibre-kindle-boundaries-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'book.epub'
        self.image = bytes(range(256))
        self.css = b'p {color: #123456}'
        with zipfile.ZipFile(self.source, 'w') as z:
            z.writestr('mimetype', 'application/epub+zip')
            z.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>')
            z.writestr('OPS/package.opf', '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="id"><metadata>
<dc:identifier id="id">original-id</dc:identifier><dc:title>Название</dc:title><dc:creator>Автор</dc:creator><dc:language>ru</dc:language>
<meta property="mhl:fb2-cover">#old-cover</meta><meta property="belongs-to-collection" id="series">Серия</meta><meta refines="#series" property="group-position">4</meta></metadata>
<manifest><item id="chapter" href="chapter.xml" media-type="application/xhtml+xml"/><item id="pic" href="image.png" media-type="image/png"/><item id="style" href="style.css" media-type="text/css"/></manifest><spine><itemref idref="chapter"/></spine></package>''')
            z.writestr('OPS/chapter.xml', '''<html:html xmlns:html="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><html:head><html:title>Глава</html:title></html:head><html:body><html:p id="anchor" data-fb2="obsolete"><html:strong>Ёжик</html:strong> <html:a href="#note" epub:type="noteref">1</html:a><html:img src="image.png" data-fb2-image="old-cover"/></html:p><html:aside id="note" epub:type="footnote">Сноска</html:aside></html:body></html:html>''')
            z.writestr('OPS/image.png', self.image)
            z.writestr('OPS/style.css', self.css)
        self.before = hashlib.sha256(self.source.read_bytes()).digest()

    def writer(self):
        tool = self.root / 'tools/kindle-export/kindling-cli.exe'
        tool.parent.mkdir(parents=True)
        tool.write_bytes(b'not executed: mocked process')
        return tool

    def assert_clean(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).digest(), self.before)
        self.assertFalse(list(self.root.glob('homelibre-kindle-output-*')))
        self.assertFalse(list(self.root.glob('.homelib-convert-*')))

    def test_mobi_reflow_uses_the_declared_outline_and_reports_bad_targets(self):
        html = self.root / 'book.html'
        html.write_text('<h1>Заголовок вне оглавления</h1><p id="filepos10">Начало</p>'
                        '<p id="filepos20">Продолжение</p>', encoding='utf-8')
        ncx = self.root / 'toc.ncx'
        ncx.write_text('''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
<navPoint><navLabel><text>Том</text></navLabel><content src="book.html#filepos10"/>
  <navPoint><navLabel><text>Глава</text></navLabel><content src="#filepos20"/></navPoint>
</navPoint>
<navPoint><navLabel><text>Утрачено</text></navLabel><content src="book.html#filepos30"/></navPoint>
</navMap></ncx>''', encoding='utf-8')
        warnings = set()
        outline = c.mobi_navigation(html, warnings)
        output = self.root / 'reading.epub'
        c.text_to_book(html, output, warnings, '.epub', document_outline=outline)
        with zipfile.ZipFile(output) as archive:
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            links = nav.findall('.//{*}nav/{*}ol/{*}li/{*}a')
            self.assertEqual([(a.text, a.get('href')) for a in links], [('Том', 'book.xhtml#filepos10')])
            nested = nav.find('.//{*}nav/{*}ol/{*}li/{*}ol/{*}li/{*}a')
            self.assertEqual((nested.text, nested.get('href')), ('Глава', 'book.xhtml#filepos20'))
            self.assertIn('Заголовок вне оглавления', c.plain(c.xml(archive.read('OEBPS/book.xhtml'))))
        self.assertTrue(any(text.startswith(c.MOBI_NAVIGATION_LOSS) for text in c.damaged_content_warnings(warnings)))

    def test_mobi_outline_keeps_valid_destinations_around_invalid_label_characters(self):
        html = self.root/'book.html'
        ncx = self.root/'toc.ncx'
        data = b'''<ncx><navMap><navPoint><navLabel><text>Vol\x1aume</text></navLabel>
          <content src="book.html#first"/>
          <navPoint><navLabel><text>Chapter 2</text></navLabel>
            <content src="book.html#second"/></navPoint>
          </navPoint><navPoint><navLabel><text>Chapter 3</text></navLabel>
            <content src="book.html#third"/></navPoint></navMap></ncx>'''
        ncx.write_bytes(data)
        warnings = set()
        self.assertEqual(c.mobi_navigation(html, warnings),
                         [('first', 'Vol\ufffdume', 1), ('second', 'Chapter 2', 2), ('third', 'Chapter 3', 1)])
        self.assertEqual(c.damaged_content_warnings(warnings),
                         ['Нечитаемые символы в оглавлении MOBI отмечены знаком � (всего 1).'])
        self.assertEqual(ncx.read_bytes(),data)

        damaged_title = data.replace(b'Vol\x1aume', b'Volume').replace(
            b'<ncx>', b'<ncx><docTitle><text>Bo\x1aok</text></docTitle>')
        ncx.write_bytes(damaged_title)
        warnings.clear()
        self.assertEqual(c.mobi_navigation(html, warnings),
                         [('first', 'Volume', 1), ('second', 'Chapter 2', 2), ('third', 'Chapter 3', 1)])
        self.assertFalse(c.damaged_content_warnings(warnings))
        self.assertEqual(ncx.read_bytes(),damaged_title)

    def test_mobi_package_keeps_other_metadata_when_the_title_contains_invalid_characters(self):
        html = self.root/'book.html'
        opf = self.root/'content.opf'
        data = b'''<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>
        <dc:title>An incomplete \x1atitle</dc:title><dc:creator>Alice & Bob</dc:creator>
        <dc:publisher>Publisher</dc:publisher><dc:language>en</dc:language>
        </metadata></package>'''
        opf.write_bytes(data)
        warnings = set()
        package = c.mobi_package(html, warnings)
        self.assertEqual({c.tag(node): c.plain(node) for node in c.first(package,'metadata')},
                         {'title': 'An incomplete \ufffdtitle', 'creator': 'Alice & Bob',
                          'publisher': 'Publisher', 'language': 'en'})
        self.assertEqual(c.damaged_content_warnings(warnings),
                         ['Нечитаемые символы в сведениях об издании MOBI отмечены знаком � (всего 1).'])
        self.assertEqual(opf.read_bytes(),data)

    def test_private_adaptation_uses_manifest_and_preserves_content_and_metadata(self):
        output = self.root / 'private.epub'
        k.canonical_input(c, self.source, output)
        with zipfile.ZipFile(output) as z:
            self.assertEqual(z.read('OPS/image.png'), self.image)
            self.assertEqual(z.read('OPS/style.css'), self.css)
            root = c.xhtml(z.read('OPS/chapter.xml'))
            self.assertEqual(root.tag, '{' + c.XH + '}html')
            self.assertNotIn(b'html:html', z.read('OPS/chapter.xml'))
            self.assertTrue(any(n.get('id') == 'anchor' for n in root.iter()))
            self.assertTrue(any(n.get('{' + c.EP + '}type') == 'noteref' and n.get('href') == '#note' for n in root.iter()))
            self.assertFalse(any(name.startswith('data-fb2') for n in root.iter() for name in n.attrib))
            metadata = c.xml(z.read('OPS/package.opf'))
            for text in ('original-id', 'Название', 'Автор', 'ru', 'Серия', '4'):
                self.assertIn(text, list(metadata.itertext()))
            self.assertFalse(any(n.get('property', '').startswith('mhl:fb2-') for n in metadata.iter()))
        self.assert_clean()

    def test_language_tag_case_is_normalized_only_in_private_metadata(self):
        values = {'UND':'und', 'EN':'en', 'eN-us':'en-US', 'ZH-hANT-tw':'zh-Hant-TW',
                  'AZ-lATN-X-LATN':'az-Latn-x-latn', 'en-A-LATN-US':'en-a-latn-us',
                  'x-PRIVATE-LATN':'x-private-latn', 'RU_RU':'RU_RU', 'EN US':'EN US'}
        source, output = self.root/'languages.epub', self.root/'private-languages.epub'
        with zipfile.ZipFile(self.source) as z:
            entries = {name:z.read(name) for name in z.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'<dc:language>ru</dc:language>',
            ''.join('<dc:language>'+value+'</dc:language>' for value in values).encode())
        with zipfile.ZipFile(source, 'w') as z:
            for name, data in entries.items(): z.writestr(name, data)
        before = source.read_bytes()
        k.canonical_input(c, source, output)
        with zipfile.ZipFile(output) as z:
            metadata = c.xml(z.read('OPS/package.opf'))
            self.assertEqual([n.text for n in metadata.iter('{'+c.DC+'}language')], list(values.values()))
            self.assertEqual(z.read('OPS/image.png'), self.image)
            self.assertEqual(z.read('OPS/style.css'), self.css)
            self.assertIn('Ёжик', ''.join(c.xhtml(z.read('OPS/chapter.xml')).itertext()))
        self.assertEqual(source.read_bytes(), before)
        self.assert_clean()

    def test_legacy_layout_materializes_paragraph_css_without_changing_modern_epub(self):
        source = self.root / 'layout.epub'
        with zipfile.ZipFile(self.source) as original:
            files = {name: original.read(name) for name in original.namelist()}
        files['OPS/chapter.xml'] = files['OPS/chapter.xml'].replace(b'</html:head>',
            b'<html:link rel="stylesheet" href="style.css"/></html:head>').replace(b'</html:body>',
            b'<html:div class="verse" id="verse"><html:p class="signature" id="credit">Credit</html:p>'
            b'<html:h3 style="text-align:center" id="heading">Heading</html:h3></html:div></html:body>')
        files['OPS/style.css'] = b'p{text-align:justify;text-indent:1.3em;margin:.45em 0}' \
                                b'.verse{margin:1em 2em}.signature{text-align:right;text-indent:0}'
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        for legacy in (False, True):
            output = self.root / f'layout-{legacy}.epub'
            k.canonical_input(c, source, output, legacy=legacy)
            with zipfile.ZipFile(output) as archive:
                chapter = c.xhtml(archive.read('OPS/chapter.xml'))
                self.assertEqual(archive.read('OPS/style.css'), files['OPS/style.css'])
            nodes = {node.get('id'): node for node in chapter.iter() if node.get('id')}
            self.assertEqual(c.plain(nodes['credit']), 'Credit')
            if legacy:
                self.assertEqual(c.tag(nodes['verse']), 'blockquote')
                self.assertEqual(nodes['credit'].get('align'), 'right')
                self.assertEqual(nodes['credit'].get('width'), '0pt')
                self.assertEqual(nodes['anchor'].get('align'), 'justify')
                self.assertEqual(nodes['anchor'].get('width'), '1.3em')
                self.assertEqual(nodes['anchor'].get('height'), '.45em')
                self.assertEqual(nodes['heading'].get('align'), 'center')
                self.assertNotIn('style', nodes['heading'].attrib)
            else:
                self.assertEqual(c.tag(nodes['verse']), 'div')
                self.assertIsNone(nodes['credit'].get('align'))
                self.assertEqual(nodes['heading'].get('style'), 'text-align:center')

    def test_external_urls_are_encoded_without_changing_local_targets_or_prose(self):
        source, output = self.root/'urls.epub', self.root/'private-urls.epub'
        with zipfile.ZipFile(self.source) as z:
            entries = {name:z.read(name) for name in z.namelist()}
        entries['OPS/chapter.xml'] = entries['OPS/chapter.xml'].replace(b'</html:p>',
            ('<html:a href="mailto:reader@example.invalid?subject=Вопрос о книге&amp;body=One%20word">Write</html:a>'
             '<html:a href="https://example.invalid/Часть 2?q=A B#ref">Public</html:a></html:p>').encode())
        with zipfile.ZipFile(source, 'w') as z:
            for name, data in entries.items(): z.writestr(name, data)
        before = source.read_bytes()
        k.canonical_input(c, source, output)
        with zipfile.ZipFile(output) as z:
            tree=c.xhtml(z.read('OPS/chapter.xml'))
            links=[n.get('href') for n in tree.iter() if c.tag(n)=='a']
            self.assertIn('#note',links)
            self.assertIn('mailto:reader@example.invalid?subject=%D0%92%D0%BE%D0%BF%D1%80%D0%BE%D1%81%20%D0%BE%20%D0%BA%D0%BD%D0%B8%D0%B3%D0%B5&body=One%20word',links)
            self.assertIn('https://example.invalid/%D0%A7%D0%B0%D1%81%D1%82%D1%8C%202?q=A%20B#ref',links)
            self.assertIn('Ёжик',''.join(tree.itertext()))
            self.assertEqual(z.read('OPS/image.png'),self.image)
        self.assertEqual(source.read_bytes(),before)

    def test_svg_math_and_note_namespaces_survive_replaced_html_root(self):
        source, output = self.root / 'foreign.epub', self.root / 'canonical.epub'
        with zipfile.ZipFile(self.source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/chapter.xml'] = files['OPS/chapter.xml'].replace(b'</html:body>',
            b'<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:image xmlns:l="http://www.w3.org/1999/xlink" l:href="image.png"/></s:svg>'
            b'<m:math xmlns:m="http://www.w3.org/1998/Math/MathML"><m:mi>x</m:mi></m:math></html:body>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        k.canonical_input(c, source, output)
        with zipfile.ZipFile(output) as archive:
            data = archive.read('OPS/chapter.xml')
            expected = c.xhtml(data)
            opening = re.search(rb'<html\b[^>]*>', data)
            self.assertIsNotNone(opening)
            replaced = re.sub(rb' xmlns:[\w-]+="[^"]*"', b'', opening[0])
            actual = c.xhtml(data[:opening.start()] + replaced + data[opening.end():])
            self.assertEqual([(n.tag, dict(n.attrib)) for n in actual.iter()],
                             [(n.tag, dict(n.attrib)) for n in expected.iter()])
            self.assertEqual(list(actual.itertext()), list(expected.itertext()))
            self.assertEqual(archive.read('OPS/image.png'), self.image)
        self.assert_clean()

    def test_legacy_cover_mime_and_missing_fonts_are_repaired_in_private_copy(self):
        with zipfile.ZipFile(self.source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/package.opf'] = (files['OPS/package.opf']
            .replace(b'id="pic" href="image.png" media-type="image/png"',
                     b'id="pic" href="image.jpg" media-type="image/jpeg" properties="cover-image"')
            .replace(b'<manifest>', b'<manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>'
                     b'<item id="font" href="fonts/present.ttf" media-type="font/ttf"/>'
                     b'<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
            .replace(b'<spine>', b'<spine toc="ncx"><itemref idref="cover" linear="no"/>'))
        files['OPS/chapter.xml'] = files['OPS/chapter.xml'].replace(b'image.png', b'image.jpg')
        files['OPS/image.jpg'] = b'\x89PNG\r\n\x1a\n' + files.pop('OPS/image.png')
        files['OPS/fonts/present.ttf'] = b'packaged-font-bytes'
        missing = b'@font-face { font-family: Missing; src: /* font */ url("fonts/missing.ttf") format("truetype"); }'
        style = (b'/* ' + missing + b' */\n'
                 b'@font-face {font-family: Keep; src:url(fonts/present.ttf)}\n'
                 b'@font-face {font-family: "Literal; src:url(missing.ttf);"; src:local("Book Font")}\n'
                 b'@font-face {font-family: Fallback; src:url(missing.ttf), url(fonts/present.ttf)}\n'
                 b'p {color: #123456}')
        files['OPS/style.css'] = missing + style
        chapter, cover, ncx = ('OPS/chapter.xml', 'OPS/cover.xhtml', 'OPS/toc.ncx')
        files[cover] = b'<html xmlns="http://www.w3.org/1999/xhtml"><body><div><img src="image.jpg"/></div></body></html>'
        files[ncx] = b'<ncx><navMap><navPoint><content src="chapter.xml#anchor"/></navPoint></navMap></ncx>'
        for keep_cover in ('no', 'caption', 'chapter-link', 'toc-link', 'startup',
                           'startup-chapter-link', 'startup-fragment', 'guide-link'):
            with self.subTest(keep_cover=keep_cover):
                payloads = dict(files)
                if keep_cover == 'caption':
                    payloads[cover] = files[cover].replace(b'</div>', b'<p>Edition detail</p></div>')
                elif keep_cover in ('chapter-link', 'startup-chapter-link'):
                    payloads[chapter] = files[chapter].replace(b'href="#note"', b'href="cover.xhtml"')
                elif keep_cover == 'toc-link':
                    payloads[ncx] = files[ncx].replace(b'chapter.xml#anchor', b'cover.xhtml')
                if keep_cover.startswith('startup') or keep_cover == 'guide-link':
                    kind = b'toc' if keep_cover == 'guide-link' else b'text'
                    link = b'cover.xhtml#top' if keep_cover == 'startup-fragment' else b'cover.xhtml'
                    guide = b'<guide><reference type="' + kind + b'" href="' + link + b'"/></guide>'
                    payloads['OPS/package.opf'] = (files['OPS/package.opf']
                        .replace(b' linear="no"', b'').replace(b'</package>', guide + b'</package>'))
                source, output = self.root / (keep_cover + '.epub'), self.root / (keep_cover + '-out.epub')
                with zipfile.ZipFile(source, 'w') as archive:
                    for name, data in payloads.items():
                        archive.writestr(name, data)
                source_hash = hashlib.sha256(source.read_bytes()).digest()
                warnings = set()
                self.assertTrue(k.canonical_input(c, source, output, warnings))
                self.assertEqual(len(warnings), 1)
                with zipfile.ZipFile(output) as archive:
                    package = c.xml(archive.read('OPS/package.opf'))
                    manifest = c.first(package, 'manifest')
                    image = next(node for node in manifest if node.get('id') == 'pic')
                    self.assertEqual(image.get('media-type'), 'image/png')
                    self.assertEqual(image.get('href'), 'image.jpg')
                    self.assertEqual(archive.read('OPS/image.jpg'), files['OPS/image.jpg'])
                    self.assertEqual(archive.read('OPS/fonts/present.ttf'), files['OPS/fonts/present.ttf'])
                    self.assertEqual(archive.read('OPS/style.css'), style)
                    self.assertEqual(archive.read(ncx), payloads[ncx])
                    spine = c.first(package, 'spine')
                    self.assertEqual(spine.get('toc'), 'ncx')
                    removed = keep_cover in ('no', 'startup')
                    self.assertEqual([item.get('idref') for item in spine], ['chapter'] if removed else ['cover', 'chapter'])
                    guide = c.first(package, 'guide')
                    if guide is not None:
                        expected = 'chapter.xml' if removed else link.decode('ascii')
                        self.assertEqual(guide[0].get('href'), expected)
                    self.assertIn(cover, archive.namelist())
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), source_hash)

    def test_jpeg_padding_preserves_encoded_image_and_app_thumbnail(self):
        jpeg = (ROOT.parent/'ui/tests/fixtures/reconstruct-original.jpg').read_bytes()
        thumbnail = b'JFXX\0\x10'+jpeg
        app_segment = b'\xff\xe0'+struct.pack('>H', len(thumbnail)+2)+thumbnail
        image = jpeg[:2]+app_segment+jpeg[2:]
        for length in (0, 1, 2, 3, 17, 512):
            with self.subTest(length=length):
                warnings = set()
                padded = image+b'\0'*length
                self.assertEqual(k.prepare_jpeg_for_kindling(c, padded, 'picture.jpg', warnings), image)
                self.assertFalse(warnings)
        warnings = set()
        multi_image = image+b'\0'*2+jpeg
        self.assertEqual(k.prepare_jpeg_for_kindling(c, multi_image+b'\0'*17, 'picture.jpg', warnings), multi_image)
        self.assertFalse(warnings)
        for data in (image[:-2]+b'\0'*17, b'not-jpeg\xff\xd9\0\0'):
            self.assertEqual(k.prepare_jpeg_for_kindling(c, data, 'picture.jpg', set()), data)

    def test_kindle_private_copy_reports_loss_of_data_after_jpeg(self):
        jpeg = (ROOT.parent/'ui/tests/fixtures/reconstruct-original.jpg').read_bytes()
        trailing = b'extra resource\xff\xd9 trailer'
        source = self.root/'jpeg-extra.epub'
        output = self.root/'kindle-jpeg.epub'
        with zipfile.ZipFile(self.source) as archive:
            entries = {name:archive.read(name) for name in archive.namelist()}
        entries['OPS/image.png'] = jpeg+trailing
        with zipfile.ZipFile(source, 'x') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        before = source.read_bytes()
        warnings = set()
        k.canonical_input(c, source, output, warnings)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('OPS/image.png'), jpeg)
            item = next(node for node in c.xml(archive.read('OPS/package.opf')).iter()
                        if node.get('href')=='image.png')
            self.assertEqual(item.get('media-type'), 'image/jpeg')
        changes = c.damaged_content_warnings(warnings)
        self.assertEqual(len(changes), 1)
        self.assertIn('OPS/image.png', changes[0])
        self.assertIn(f'{len(trailing)} байт', changes[0])
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(k.prepare_jpeg_for_kindling(c, jpeg+trailing, 'picture.jpg', None), jpeg+trailing)

    def test_updated_kindle_module_keeps_consent_with_older_book_processing(self):
        jpeg = (ROOT.parent/'ui/tests/fixtures/reconstruct-original.jpg').read_bytes()
        older = SimpleNamespace(ComponentRequired=c.ComponentRequired)
        warnings = set()
        self.assertEqual(k.prepare_jpeg_for_kindling(older, jpeg+b'\0'*17, 'picture.jpg', warnings), jpeg)
        self.assertFalse(warnings)
        with self.assertRaises(c.ComponentRequired) as requested:
            k.prepare_jpeg_for_kindling(older, jpeg+b'optional payload', 'picture.jpg', warnings)
        self.assertEqual(requested.exception.component, 'BookProcessing')

    def test_mobi_reencoding_reports_the_affected_images_and_dimensions(self):
        diagnostics = ('images/first.jpg: over 128 KB, re-encoded at quality 35 instead of 85\r\n'
                       'images/first.jpg: over 128 KB, re-encoded at quality 35 instead of 85\n'
                       'images/second.jpg: over 128 KB, re-encoded at quality 25 instead of 85 and scaled down to 500x700\n'
                       'Re-encoded 2 image(s) over 128 KB so the reader can decode them; originals kept in the HD container')
        warnings = set()
        k.record_mobi_image_losses(c, diagnostics, warnings)
        partial = sorted(c.damaged_content_warnings(warnings))
        self.assertEqual(len(partial), 2)
        self.assertIn('images/first.jpg', partial[0])
        self.assertIn('images/second.jpg', partial[1])
        self.assertIn('500 × 700', partial[1])
        older = SimpleNamespace(ComponentRequired=c.ComponentRequired)
        with self.assertRaises(c.ComponentRequired) as requested:
            k.record_mobi_image_losses(older, diagnostics, set())
        self.assertEqual(requested.exception.component, 'BookProcessing')

    def test_rtf_empty_paragraphs_keep_valid_xhtml_and_single_line_breaks(self):
        source = self.root / 'empty-paragraphs.rtf'
        source.write_bytes(br'{\rtf1\ansi First\par\par Last\line Final}')
        source_hash = hashlib.sha256(source.read_bytes()).digest()
        prepared, adapted = self.root / 'prepared.epub', self.root / 'adapted.epub'
        c.convert_book(source, prepared)
        k.canonical_input(c, prepared, adapted)
        with zipfile.ZipFile(prepared) as before, zipfile.ZipFile(adapted) as after:
            document = 'OEBPS/book.xhtml'
            original = c.xhtml(before.read(document))
            actual = c.xhtml(after.read(document))
            self.assertEqual(list(original.itertext()), list(actual.itertext()))
            self.assertEqual([c.tag(n) for n in original.iter()], [c.tag(n) for n in actual.iter()])
            self.assertIn(b'<p></p>', after.read(document))
            self.assertNotIn(b'<p />', after.read(document))
            self.assertNotIn(b'</br>', after.read(document))
            self.assertEqual(sum(c.tag(n) == 'br' for n in actual.iter()), 1)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), source_hash)
        self.assert_clean()

    def test_gif_record_padding_requires_a_complete_block_stream(self):
        image = bytes.fromhex('47494638396101000100800000000000ffffff2c00000000010001000002024401003b')
        for length in range(1, 5):
            comment = b'\x21\xfe' + bytes([length]) + b'x' * length + b'\0'
            complete = image[:19] + comment + image[19:]
            padding = b'\0' * (-len(complete) % 4)
            self.assertEqual(k.gif_without_record_padding(complete + padding), complete)
        for broken in (image[:-1], image + b'X', b'GIF89a' + b'\0' * 10,
                       image[:29] + b'\x02\x07\x3b\0\0\0'):
            aligned = broken + b'\0' * (-len(broken) % 4)
            self.assertEqual(k.gif_without_record_padding(aligned), aligned)

    def test_missing_writer_requests_only_the_kindle_output_component(self):
        with self.assertRaises(c.ComponentRequired) as caught:
            c.convert_book(self.source, self.root / 'out.mobi', tools_root=self.root / 'tools')
        self.assertEqual(caught.exception.component, 'KindleExport')
        self.assertFalse((self.root / 'out.mobi').exists())
        self.assert_clean()

    def test_only_store_cover_requirement_can_be_exempted_after_full_preflight(self):
        result = SimpleNamespace(returncode=1,
            stdout='[error R4.2.1] No internal content cover image declared.\n',
            stderr='Build aborted: 1 validation errors. Run with --no-validate to skip.')
        self.assertTrue(k.only_publication_cover_required(result, False))
        self.assertFalse(k.only_publication_cover_required(result, True))
        result.stdout += '[error R7.3] Broken chapter link.\n'
        self.assertFalse(k.only_publication_cover_required(result, False))
        result.stdout = '[error R4.2.1] No internal content cover image declared.\n'
        result.stderr = 'Native writer crashed.'
        self.assertFalse(k.only_publication_cover_required(result, False))
        self.assert_clean()

    def test_old_core_requests_book_processing_before_running_the_writer(self):
        self.writer()
        output=self.root/'old-core.mobi'
        with mock.patch.object(c,'local_foreign_namespaces',None), mock.patch.object(subprocess,'run') as process:
            with self.assertRaises(c.ComponentRequired) as caught:
                k.convert(c,self.source,output,{'tools_root':self.root/'tools'})
            self.assertEqual(caught.exception.component,'BookProcessing')
            process.assert_not_called()
        self.assertFalse(output.exists())
        self.assert_clean()

    def test_failed_native_process_never_publishes_a_partial_book(self):
        tool = self.writer()
        def failure(command, **options):
            self.assertEqual(command[0], str(tool))
            self.assertIn('--legacy-mobi', command)
            Path(command[command.index('-o') + 1]).write_bytes(b'partial book')
            return SimpleNamespace(returncode=1, stdout='', stderr='native writer failed')
        with mock.patch.object(subprocess, 'run', side_effect=failure):
            with self.assertRaisesRegex(c.ConversionError, 'native writer failed'):
                c.convert_book(self.source, self.root / 'out.mobi', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.mobi').exists())
        self.assert_clean()

    def test_legacy_mobi_removes_kf8_and_keeps_text_images_and_cover_metadata(self):
        exth_items = ((121, b'\0\0\0\x04'), (129, b'kindle:embed:0001'),
                      (201, b'\0'*4), (536, b'960x1280:0-2|'))
        exth = b''.join(struct.pack('>II', identity, 8 + len(payload)) + payload for identity, payload in exth_items)
        header = bytearray(280)
        header[16:20] = b'MOBI'
        struct.pack_into('>I', header, 20, 264)
        struct.pack_into('>I', header, 36, 6)
        struct.pack_into('>II', header, 84, len(header) + 12 + len(exth), 5)
        struct.pack_into('>I', header, 128, 0x1850)
        record = header + b'EXTH' + struct.pack('>II', 12 + len(exth), len(exth_items)) + exth + b'Title'
        next_header = bytearray(40)
        next_header[16:20] = b'MOBI'
        struct.pack_into('>I', next_header, 36, 8)
        records = (record, b'legacy text', b'legacy image', b'BOUNDARY', next_header, b'KF8 text', k.MOBI_EOF)
        prefix = bytearray(78)
        prefix[60:68] = b'BOOKMOBI'
        struct.pack_into('>H', prefix, 76, len(records))
        positions = []
        offset = 80 + 8 * len(records)
        for data in records:
            positions.append(offset)
            offset += len(data)
        source = self.root / 'dual.mobi'
        original = prefix + b''.join(struct.pack('>II', pos, 2*i) for i, pos in enumerate(positions))
        source.write_bytes(original + b'\0\0' + b''.join(records))
        original_hash = hashlib.sha256(source.read_bytes()).digest()
        with self.assertRaisesRegex(c.ConversionError, 'самостоятельной книгой'):
            k.validate_output(c, source, '.mobi')

        output = self.root / 'legacy.mobi'
        k.extract_legacy_mobi(c, source, output)
        k.validate_output(c, output, '.mobi')
        with output.open('rb') as stream:
            _, _, offsets = k.palm_records(c, stream, output.stat().st_size)
            stream.seek(offsets[0])
            legacy_record = stream.read(offsets[1] - offsets[0])
            _, _, _, title, items = k.mobi_exth(c, legacy_record)
            self.assertEqual(legacy_record[title:title + 5], b'Title')
            self.assertEqual(struct.unpack_from('>I', legacy_record, 128)[0], 0x50)
            self.assertEqual(dict(items), {121: b'\xff'*4, 129: b'', 201: b'\0'*4})
            self.assertEqual(len(offsets), 4)
            self.assertEqual(stream.read(offsets[2] - offsets[1]), b'legacy text')
            self.assertEqual(stream.read(offsets[3] - offsets[2]), b'legacy image')
            self.assertEqual(stream.read(), k.MOBI_EOF)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), original_hash)

        metadata_output = self.root / 'metadata.mobi'
        additions = [(101, b'Publisher'), (103, 'длинная аннотация\n'.encode('utf-8') * 1100),
                     (104, b'9780000000000'), (105, b'first subject'), (105, b'second subject')]
        output_hash = hashlib.sha256(output.read_bytes()).digest()
        self.assertEqual(k.update_publication_records(c, output, metadata_output, additions), metadata_output)
        k.validate_output(c, metadata_output, '.mobi')
        with metadata_output.open('rb') as stream:
            _, _, metadata_offsets = k.palm_records(c, stream, metadata_output.stat().st_size)
            self.assertGreater(metadata_offsets[1], offsets[1])
            stream.seek(metadata_offsets[0])
            new_record = stream.read(metadata_offsets[1] - metadata_offsets[0])
            _, _, _, new_title, new_items = k.mobi_exth(c, new_record)
            self.assertEqual(new_items, items + additions)
            self.assertEqual(new_record[new_title:new_title + 5], b'Title')
            self.assertEqual(stream.read(), output.read_bytes()[offsets[1]:])
        self.assertEqual(hashlib.sha256(output.read_bytes()).digest(), output_hash)

    def test_kf8_reader_preserves_resources_and_removes_only_binary_package_diagnostics(self):
        source = self.root / 'unpacked.epub'
        output = self.root / 'reader.epub'
        metadata = b'<package><metadata/><manifest/><spine/></package>'
        diagnostics = b'<!-- BEGIN INFORMATION ONLY \n<meta name="Container_Id" content="_KS\x03"/>\nEND INFORMATION ONLY -->'
        files = {'mimetype': b'application/epub+zip',
                 'META-INF/container.xml': b'<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
                 'OPS/package.opf': metadata + diagnostics, 'OPS/chapter.xhtml': b'<html><body>Real content.</body></html>',
                 'OPS/illustration.jpg': b'\xff\xd8\xff\x01\xff\xd9'}
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        initial = source.read_bytes()
        reader.write_reader_epub(source, output)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.namelist(), list(files))
            self.assertEqual(archive.infolist()[0].compress_type, zipfile.ZIP_STORED)
            self.assertEqual(archive.read('OPS/package.opf'), metadata)
            for name in files.keys() - {'OPS/package.opf'}:
                self.assertEqual(archive.read(name), files[name])
        unchanged = self.root / 'clean-reader.epub'
        reader.write_reader_epub(output, unchanged)
        self.assertEqual(unchanged.read_bytes(), output.read_bytes())
        self.assertEqual(source.read_bytes(), initial)

    def test_long_validation_report_keeps_the_error_before_the_warnings(self):
        self.writer()
        failure = SimpleNamespace(returncode=1, stdout='[error R4.2.4] Duplicate cover.\n' +
            '[warning R10.4.5] Image name does not match its format.\n' * 100,
            stderr='Build aborted: 1 validation errors.')
        with mock.patch.object(subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(c.ConversionError, 'R4.2.4.*Duplicate cover'):
                c.convert_book(self.source, self.root / 'out.azw3', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.azw3').exists())
        self.assert_clean()

    def test_timeout_is_reported_and_removes_private_intermediates(self):
        self.writer()
        with mock.patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('kindling', 300)):
            with self.assertRaisesRegex(c.ConversionError, '5 минут'):
                c.convert_book(self.source, self.root / 'out.azw3', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.azw3').exists())
        self.assert_clean()

    def test_existing_result_and_source_are_never_replaced(self):
        result = self.root / 'out.mobi'
        result.write_bytes(b'previous saved book')
        with mock.patch.object(subprocess, 'run') as run:
            with self.assertRaises(c.ConversionError):
                c.convert_book(self.source, result, tools_root=self.root / 'tools')
            run.assert_not_called()
        self.assertEqual(result.read_bytes(), b'previous saved book')
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()

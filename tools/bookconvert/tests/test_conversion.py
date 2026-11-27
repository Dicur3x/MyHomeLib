"""Structure and data preservation tests; optional independent XSD/EPUBCheck."""
from pathlib import Path
from collections import Counter
import base64, hashlib, importlib.util, json, os, struct, subprocess, sys, tempfile, unittest, zipfile, zlib
import xml.etree.ElementTree as ET
from unittest import mock
from urllib.parse import quote_from_bytes

MODULE = Path(__file__).resolve().parents[1] / 'convert_book.py'
spec = importlib.util.spec_from_file_location('convert_book', MODULE)
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

FB2 = '''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<stylesheet type="text/css">.special {color:purple}</stylesheet>
<description><title-info><genre>unrecognised</genre><author><first-name>Анна</first-name><last-name>Автор</last-name></author><book-title>Книга &amp; проверка</book-title><annotation><p>Аннотация</p></annotation><coverpage><image l:href="#cover"/></coverpage><lang>ru</lang><sequence name="Серия" number="2"/></title-info><document-info><author><nickname>Fixture</nickname></author><date value="2026-10-13">2026-10-13</date><id>original-identifier</id><version>1</version></document-info></description>
<body><section id="one"><title><p>Первая глава</p></title><section id="one-prose"><p id="para">Ё, ї, є, ґ, ў, English. 😀 &lt;Текст&gt; <strong>жирный</strong>, <emphasis>курсив</emphasis>, <style name="special">цвет</style>. <a l:href="#note" type="note">6</a>.</p><p><image l:href="#cover"/></p></section><section id="nested"><title><p>Подглава</p></title><poem><stanza><v>Строка один</v><v>Строка два</v></stanza></poem><cite><p>Цитата</p></cite><table><tr><th>Заголовок</th><td>Ячейка</td></tr></table></section></section><section id="two"><title><p>Вторая глава</p></title><p>Конец.</p></section></body>
<body name="notes"><section id="note"><title><p>6</p></title><p>Сноска &amp; текст.</p></section></body>
<binary id="cover" content-type="image/png">{image}</binary><binary id="unused" content-type="image/png">{image}</binary></FictionBook>'''
def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
PNG = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
       + png_chunk(b'IDAT', zlib.compress(b'\0\x12\x34\x56\xff')) + png_chunk(b'IEND', b''))

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def shape(node, include_tail=False): return (node.tag, sorted(node.attrib.items()), node.text, node.tail if include_tail else None, [shape(n,True) for n in node])

class ConversionTests(unittest.TestCase):

    def test_epub2_roundtrip_preserves_fb2_description_styles_and_cover(self):
        source_hash = digest(self.source)
        epub_path = self.root / 'legacy.epub'
        c.convert_book(self.source, epub_path, output_profile='epub2')
        with zipfile.ZipFile(epub_path) as archive:
            metadata = c.first(c.xml(archive.read('OEBPS/package.opf')), 'metadata')
            retained = {node.get('name') for node in c.children(metadata, 'meta')}
            self.assertTrue({c.FB2_DESCRIPTION_METADATA, c.FB2_IMAGES_METADATA,
                             c.FB2_STYLESHEETS_METADATA}.issubset(retained))
        restored = self.root / 'legacy-roundtrip.fb2'
        c.convert_book(epub_path, restored)
        self.validate_fb2(restored)
        original, restored_book = (c.xml(path.read_bytes()) for path in (self.source, restored))
        for field in ('stylesheet', 'description'):
            self.assertEqual(shape(c.first(restored_book, field)), shape(c.first(original, field)))
        self.assertEqual({node.get('id'): base64.b64decode(c.plain(node)) for node in c.children(restored_book, 'binary')},
                         {'cover': PNG, 'unused': PNG})
        self.assertEqual(digest(self.source), source_hash)

        text_only = self.root / 'legacy-text-only.fb2'
        c.convert_book(epub_path, text_only, image_quality='none')
        self.validate_fb2(text_only)
        text_book = c.xml(text_only.read_bytes())
        self.assertFalse(c.children(text_book, 'binary'))
        info = c.first(c.first(text_book, 'description'), 'title-info')
        self.assertIsNone(c.first(info, 'coverpage'))
        self.assertEqual(c.first(info, 'sequence').get('number'), '2')

    def test_fb2_css_type_selectors_follow_converted_elements(self):
        original = ('/* image must stay here */ image + p, #title .image { text-align:center; '
                    'font-weight:bold; content:"image + p {}" } '
                    '@media screen { section > title, p > emphasis { font-style:italic } } '
                    'a[title="image"] { color:blue } #caption { background-image: none }')
        source = self.root / 'authored.fb2'
        source.write_text(FB2.replace('{image}', base64.b64encode(PNG).decode())
                          .replace('.special {color:purple}', original.replace('>', '&gt;')), encoding='utf8')
        exported = self.root / 'authored.epub'
        c.convert_book(source, exported)
        with zipfile.ZipFile(exported) as book:
            css = book.read('OEBPS/book.css').decode('utf8')
            self.assertIn('/* image must stay here */ img + p, #title .image', css)
            self.assertIn('content:"image + p {}"', css)
            self.assertIn('@media screen { section > header, p > em {', css)
            self.assertIn('a[title="image"]', css)
            self.assertIn('background-image: none', css)
        returned = self.root / 'authored-roundtrip.fb2'
        c.convert_book(exported, returned)
        style = c.first(c.xml(returned.read_bytes()), 'stylesheet')
        self.assertEqual(c.plain(style), original)

    def test_publication_fields_survive_standard_epub_and_fb2(self):
        source = self.generic(extra_metadata=(
            '<dc:description>Первый абзац.\nВторой абзац.</dc:description>'
            '<dc:publisher>Издательство «Пример»</dc:publisher>'
            '<dc:date xmlns:opf="http://www.idpf.org/2007/opf" opf:event="creation">1990</dc:date>'
            '<dc:date>2002-11-15</dc:date>'
            '<dc:identifier id="print-id">5-699-01480-2</dc:identifier>'
            '<meta refines="#print-id" property="identifier-type" scheme="onix:codelist5">02</meta>'))
        fb2 = self.root / 'publication.fb2'
        c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        description = c.first(c.xml(fb2.read_bytes()), 'description')
        publication = c.first(description, 'publish-info')
        self.assertEqual({c.tag(node): c.plain(node) for node in publication},
                         {'publisher': 'Издательство «Пример»', 'year': '2002', 'isbn': '5-699-01480-2'})
        annotation = c.first(c.first(description, 'title-info'), 'annotation')
        self.assertEqual([c.plain(node) for node in annotation], ['Первый абзац.', 'Второй абзац.'])

        output = self.root / 'publication.epub'
        c.convert_book(fb2, output)
        with zipfile.ZipFile(output) as result:
            metadata = c.first(c.xml(result.read('OEBPS/package.opf')), 'metadata')
            for name, value in (('publisher', 'Издательство «Пример»'), ('date', '2002'),
                                ('identifier', 'urn:isbn:5-699-01480-2'), ('description', 'Первый абзац.\nВторой абзац.')):
                self.assertIn(value, [c.plain(node) for node in c.children(metadata, name)])

    def test_epub_people_keep_authors_and_translators_in_their_own_roles(self):
        extra = ('<dc:creator id="translator">Анна Переводчик</dc:creator>'
                 '<meta refines="#translator" property="role" scheme="marc:relators">trl</meta>'
                 '<dc:contributor id="author">Борис Соавтор</dc:contributor>'
                 '<meta refines="#author" property="role" scheme="marc:relators">aut</meta>'
                 '<dc:creator xmlns:opf="http://www.idpf.org/2007/opf" opf:role="ill">Художник EPUB</dc:creator>'
                 '<dc:contributor xmlns:opf="http://www.idpf.org/2007/opf" opf:role="trl">Вера Переводчик</dc:contributor>')
        source = self.generic(extra_metadata=extra)
        book_path = self.root / 'roles.fb2'
        c.convert_book(source, book_path)
        self.validate_fb2(book_path)
        title_info = c.first(c.first(c.xml(book_path.read_bytes()), 'description'), 'title-info')
        self.assertEqual([c.plain(node) for node in c.children(title_info, 'author')], ['Автор EPUB', 'Борис Соавтор'])
        self.assertEqual([c.plain(node) for node in c.children(title_info, 'translator')], ['Анна Переводчик', 'Вера Переводчик'])
        for profile in ('epub2', 'epub3'):
            exported = self.root / (profile + '.epub')
            c.convert_book(book_path, exported, output_profile=profile)
            with zipfile.ZipFile(exported) as archive:
                metadata = c.first(c.xml(archive.read('OEBPS/package.opf')), 'metadata')
            self.assertEqual(c.read_epub_people(metadata),
                             (['Автор EPUB', 'Борис Соавтор'], ['Анна Переводчик', 'Вера Переводчик']))

    def test_epub_series_uses_the_fb2_sequence_without_inventing_a_number(self):
        cases = (
            ('<meta property="belongs-to-collection" id="one">Основная</meta>'
             '<meta refines="#one" property="collection-type">series</meta>'
             '<meta refines="#one" property="group-position">7</meta>'
             '<meta refines="#one" property="belongs-to-collection" id="two">Вложенная</meta>'
             '<meta refines="#two" property="collection-type">series</meta>'
             '<meta refines="#two" property="group-position">3.2</meta>'
             '<meta property="belongs-to-collection" id="three">Комплект</meta>'
             '<meta refines="#three" property="collection-type">set</meta>',
             [('Основная', '7'), ('Вложенная', None)], True),
            ('<meta name="calibre:series" content="Ранее изданная" />'
             '<meta name="calibre:series_index" content="5.0" />', [('Ранее изданная', '5')], False),
        )
        for index, (extra, expected, limited) in enumerate(cases):
            with self.subTest(index=index):
                source = self.generic(extra_metadata=extra)
                exported = self.root / f'series-{index}.fb2'
                report = c.convert_book(source, exported)
                self.validate_fb2(exported)
                description = c.first(c.xml(exported.read_bytes()), 'description')
                self.assertEqual([(n.get('name'), n.get('number')) for n in c.children(c.first(description, 'title-info'), 'sequence')],
                                 expected)
                self.assertEqual(any('Составной номер' in warning for warning in report['warnings']), limited)
                if limited:
                    raw = c.xml(base64.b64decode(c.plain(c.first(description, 'custom-info'))))
                    self.assertTrue(any(c.plain(n) == '3.2' and n.get('refines') == '#two' for n in raw))
                epub = self.root / f'series-{index}.epub'
                c.convert_book(exported, epub)
                with zipfile.ZipFile(epub) as archive:
                    metadata = c.first(c.xml(archive.read('OEBPS/package.opf')), 'metadata')
                self.assertEqual([c.plain(n) for n in metadata if n.get('property') == 'belongs-to-collection'],
                                 [name for name, _ in expected])

    def test_epub_keeps_referenced_raster_declared_as_text(self):
        source = self.generic(first='<p><img src="image.png" alt="Diagram"/></p>', second='<p>End.</p>')
        with zipfile.ZipFile(source) as archive:
            entries = {n: archive.read(n) for n in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(b'media-type="image/png"', b'media-type="text/plain"')
        with zipfile.ZipFile(source, 'w') as archive:
            for filename,data in entries.items():
                archive.writestr(filename, data)
        output = self.root / 'raster-declared-as-text.fb2'
        result = c.convert_book(source, output)
        self.validate_fb2(output)
        self.assertFalse(c.damaged_content_warnings(result['warnings']))
        book = c.xml(output.read_bytes())
        binary, = c.children(book, 'binary')
        self.assertEqual(binary.get('content-type'), 'image/png')
        self.assertEqual(base64.b64decode(c.plain(binary)), PNG)

    def test_epub_preserves_math_as_sized_images_and_reports_unrendered_formulas(self):
        formula = ('<math xmlns="http://www.w3.org/1998/Math/MathML"><mtable>'
                   '<mtr><mtd><mi>x</mi></mtd><mtd><msup><mi>y</mi><mn>2</mn></msup></mtd></mtr>'
                   '<mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr></mtable></math>')
        unsupported = ('<math xmlns="http://www.w3.org/1998/Math/MathML">'
                       '<annotation-xml><script>untrusted</script></annotation-xml></math>')
        source = self.generic(first=f'<p>До {formula} после {formula}</p><p>{unsupported} конец.</p>',
                              second='<p>Конец книги.</p>')
        before = digest(source)
        tools = self.root / 'tools'
        module = tools / 'epub-pdf'
        (module / 'runtime').mkdir(parents=True)
        (module / 'runtime/HomeLibEpubPdf.exe').touch()
        pixels = b'\x00' + b'\x12\x34\x56\xff' * 2
        raster = (PNG[:8] + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0))
                  + png_chunk(b'IDAT', zlib.compress(pixels * 2)) + png_chunk(b'IEND', b''))
        (module / 'epub_pdf_output.py').write_text(
            'def render_math(renderer, work, count, maximum, checkpoint):\n'
            '    assert count == 1\n'
            '    document = (work / "formulas.html").read_text(encoding="utf-8")\n'
            '    assert "<mtable>" in document and "<msup>" in document\n'
            '    assert "untrusted" not in document and "<script>" not in document\n'
            f'    (work / "formula-0000.png").write_bytes({raster!r})\n', encoding='utf-8')
        output = self.root / 'formulas.fb2'
        report = c.convert_book(source, output, tools_root=tools, allow_partial_epub=True, streaming=True)
        self.assertEqual(digest(source), before)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        body = c.first(book, 'body')
        images = list(body.iter('{' + c.FB + '}image'))
        self.assertEqual(len(images), 2)
        references = [node.get('{' + c.XL + '}href') for node in images]
        self.assertEqual(references[0], references[1])
        self.assertEqual(images[0].get('alt'), '[[x, (y)^(2)]; [a, b]]')
        binary = next(node for node in c.children(book, 'binary') if node.get('id') == references[0][1:])
        self.assertEqual(base64.b64decode(c.plain(binary)), raster)
        self.assertEqual(sum(node.get('name') == c.FB2_IMAGE_SIZE_PREFIX + '1-1' for node in body.iter()), 2)
        notices = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any(msg.startswith('Формулы EPUB сохранены как изображения') for msg in notices))
        self.assertTrue(any(msg.startswith('Элемент EPUB не перенесён') for msg in notices))

        with zipfile.ZipFile(source) as archive:
            chapter = self.root / 'chapter.xhtml'
            chapter.write_bytes(archive.read('OPS/chapter.xhtml'))
        # Render only supported outer formulas, with positions from the same DOM order as the reader.
        worker = MODULE.with_name('epub_math_reader.py')
        output = self.root / 'reader-formulas.zip'
        subprocess.run([sys.executable, '-I', '-B', str(worker), str(chapter), str(output), str(tools), '3'], check=True)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.namelist(), ['0.png', '1.png'])
            self.assertEqual([archive.read(name) for name in archive.namelist()], [raster, raster])
        mismatch = self.root / 'reader-mismatch.zip'
        subprocess.run([sys.executable, '-I', '-B', str(worker), str(chapter), str(mismatch), str(tools), '2'], check=True)
        self.assertFalse(mismatch.exists())
        self.assertEqual(digest(source), before)

    def test_empty_epub_spine_item_with_only_closing_tags_keeps_content(self):
        template = self.generic(first='<h1>Первая</h1><p>Текст до пустой главы.</p>'
                                      '<p><img src="image.png" alt="Рисунок"/></p>')
        with zipfile.ZipFile(template) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}

        source = self.root / 'closing-only.epub'
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, b'\xef\xbb\xbf</body>\r\n</html>\n' if name == 'OPS/notes.xhtml' else data)
        original = digest(source)
        fb2 = self.root / 'closing-only.fb2'
        report = c.convert_book(source, fb2)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        self.assertIn('Исправлена разметка пустого раздела EPUB «notes.xhtml».', report['warnings'])
        book = c.xml(fb2.read_bytes())
        self.assertEqual(c.plain(c.first(book, 'body')), 'ПерваяТекст до пустой главы.')
        self.assertEqual([base64.b64decode(n.text) for n in c.children(book, 'binary')], [PNG])

        self.assertEqual(digest(source), original)

        broken = self.root / 'closing-with-content.epub'
        with zipfile.ZipFile(broken, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, b'Unrecoverable fragment</body></html>' if name == 'OPS/notes.xhtml' else data)
        destination = self.root / 'broken-output.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'Некорректная структура XML'):
            c.convert_book(broken, destination)
        self.assertFalse(destination.exists())

        empty = self.root / 'all-chapters-empty.epub'
        with zipfile.ZipFile(empty, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, b'</body></html>' if name.endswith('.xhtml') else data)
        with self.assertRaisesRegex(c.ConversionError, 'отсутствуют главы для чтения'):
            c.convert_book(empty, destination)
        self.assertFalse(destination.exists())

    def test_epub_marks_missing_spine_item_and_preserves_available_chapters(self):
        source = self.generic(first='<p>Начало <a href="absent.xhtml">К пропущенному разделу</a>.</p>',
                              second='<p>Конец <img src="image.png"/></p>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'</manifest>', b'<item id="gone" href="absent.xhtml" media-type="application/xhtml+xml"/></manifest>'
        ).replace(b'<itemref idref="n"/>', b'<itemref idref="gone"/><itemref idref="n"/>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        before = digest(source)
        output = self.root / 'partial.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'absent.xhtml'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        marker = '[В архиве EPUB отсутствует раздел «OPS/absent.xhtml».]'
        result = c.convert_book(source, output, allow_partial_epub=True)
        self.validate_fb2(output)
        self.assertIn('В архиве EPUB отсутствуют файлы из порядка чтения (1). '
                      'В книге отмечены следующие пропуски: OPS/absent.xhtml.',
                      c.damaged_content_warnings(result['warnings']))
        book = c.xml(output.read_bytes())
        paragraphs = [''.join(node.itertext()) for node in book.iter(f'{{{c.FB}}}p')]
        self.assertLess(paragraphs.index('Начало К пропущенному разделу.'), paragraphs.index(marker))
        self.assertTrue(any(p.startswith('Конец') for p in paragraphs[paragraphs.index(marker)+1:]))
        self.assertEqual([base64.b64decode(n.text) for n in c.children(book, 'binary')], [PNG])
        target = self.root / 'partial.epub'
        c.convert_book(source, target, allow_partial_epub=True)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual({name: archive.read(name) for name in entries}, entries)
            self.assertEqual(c.plain(c.first(c.xhtml(archive.read('OPS/absent.xhtml')), 'body')), marker)
        self.assertEqual(digest(source), before)

        gone = self.root / 'nothing-to-read.epub'
        with zipfile.ZipFile(gone, 'w') as archive:
            for name, data in entries.items():
                if not name.endswith('.xhtml'):
                    archive.writestr(name, data)
        with self.assertRaisesRegex(c.ConversionError, 'отсутствуют главы для чтения'):
            c.convert_book(gone, self.root/'nothing.fb2', allow_partial_epub=True)
        self.assertFalse((self.root/'nothing.fb2').exists())

    def test_epub_keeps_title_text_after_nested_paragraphs(self):
        source = self.generic(first='<h1 id="title"><a id="title-note"/>Author'
                              '<p class="softbreak">&#160;</p>Original title'
                              '<p class="softbreak">&#160;</p><em>Original subtitle</em><br/></h1>',
                              second='<p><a href="chapter.xhtml#title-note">Back to title</a></p>')
        output = self.root / 'title-page.fb2'
        c.convert_book(source, output)
        self.validate_fb2(output)
        root = c.xml(output.read_bytes())
        title = root.find('.//{' + c.FB + '}body//{' + c.FB + '}title')
        self.assertEqual([c.plain(p) for p in c.children(title, 'p') if c.plain(p)],
                         ['Author', 'Original title', 'Original subtitle'])
        self.assertEqual(c.plain(title.find('.//{' + c.FB + '}emphasis')), 'Original subtitle')
        link = root.find('.//{' + c.FB + '}a')
        self.assertTrue(any('#' + p.get('id', '') == link.get('{' + c.XL + '}href') for p in c.children(title, 'p')))

    def test_truncated_epub_recovers_scan_order_and_checksums_after_approval(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'truncated.epub'
            images = ('OEBPS/images/leaf0000.png', 'OEBPS/images/leaf0002.png', 'OEBPS/images/orphan.png')
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr('mimetype', b'application/epub+zip')
                archive.writestr('META-INF/container.xml',
                                 f'<container xmlns="{c.CN}"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
                for n, text in ((0, 'Начало'), (2, 'Конец')):
                    archive.writestr(f'OEBPS/leaf{n:04}.html',
                                     f'<html xmlns="{c.XH}"><head><meta name="generator" content="abbyy to epub tool, v0.1"/></head>'
                                     f'<body><p>{text}</p><img src="images/leaf{n:04}.png" alt=""/></body></html>')
                for path in images:
                    archive.writestr(path, PNG)
            packed = source.read_bytes()
            source.write_bytes(packed[:packed.index(b'PK\x01\x02')])
            original_hash = digest(source)
            restored = root / 'restored.epub'
            self.assertEqual(c.detect_input(source), '.epub')
            with self.assertRaisesRegex(c.ConversionError, 'нужно подтверждение'):
                c.convert_book(source, restored)
            self.assertFalse(restored.exists())
            result = c.convert_book(source, restored, allow_partial_epub=True)
            self.assertTrue(any('leaf0001.html' in warning for warning in c.damaged_content_warnings(result['warnings'])))
            with zipfile.ZipFile(restored) as archive:
                self.assertEqual([archive.read(path) for path in images], [PNG] * 3)
                opf = c.xml(archive.read('OEBPS/content.opf'))
                manifest = {item.get('id'): item.get('href') for item in c.first(opf, 'manifest')}
                order = [manifest[item.get('idref')] for item in c.first(opf, 'spine')]
                self.assertEqual(order, ['leaf0000.html', 'leaf0001.html', 'leaf0002.html', 'homelibre-recovered-images.xhtml'])
            fb2 = root / 'restored.fb2'
            c.convert_book(source, fb2, allow_partial_epub=True)
            book = c.xml(fb2.read_bytes())
            self.assertFalse(any(item.get('info-type') == c.FB2_EPUB_OUTLINE
                                 for item in c.children(c.first(book, 'description'), 'custom-info')))
            text = c.plain(book)
            self.assertLess(text.index('Начало'), text.index('Исходная страница leaf0001.html отсутствует'))
            self.assertLess(text.index('Исходная страница leaf0001.html отсутствует'), text.index('Конец'))
            self.assertEqual(digest(source), original_hash)

    def test_truncated_abbyy_epub_keeps_interleaved_text_and_scans(self):
        contents = {
            'leaf0001.html': '<img src="images/leaf0001.png" alt="Обложка"/>',
            'intro.html': '<p>Вступление</p>',
            'part0000.html': '<div id="page-1"><p>Конец первого тома.</p></div>',
            'leaf0259.html': '<img src="images/leaf0259.png" alt="Титульный лист второго тома"/>',
            'part0001.html': '<div id="page-1"><p>Начало второго тома.</p></div>',
        }
        assets = {'OEBPS/images/leaf0001.png': PNG, 'OEBPS/images/leaf0259.png': PNG,
                  'OEBPS/stylesheet.css': b'.body { text-align: left; }'}

        def truncate(path, order, generator=None):
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('mimetype', b'application/epub+zip', compress_type=zipfile.ZIP_STORED)
                archive.writestr('META-INF/container.xml',
                                 f'<container xmlns="{c.CN}"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
                for name, data in assets.items():
                    archive.writestr(name, data)
                for name in order:
                    archive.writestr('OEBPS/' + name,
                                     f'<html xmlns="{c.XH}"><head><meta name="generator" '
                                     f'content="{generator or "abbyy to epub tool, v0.2"}"/></head>'
                                     f'<body>{contents[name]}</body></html>')
            raw = path.read_bytes()
            path.write_bytes(raw[:raw.index(b'PK\x01\x02')])

        source = self.root / 'mixed-truncated.epub'
        epub = self.root / 'mixed-recovered.epub'
        fb2 = self.root / 'mixed-recovered.fb2'
        truncate(source, list(contents))
        checksum = digest(source)
        with self.assertRaisesRegex(c.ConversionError, 'нужно подтверждение'):
            c.convert_book(source, epub)
        self.assertFalse(epub.exists())
        report = c.convert_book(source, epub, allow_partial_epub=True)
        self.assertTrue(any('в порядке записей архива' in warning
                            for warning in c.damaged_content_warnings(report['warnings'])))
        with zipfile.ZipFile(epub) as archive:
            opf = c.xml(archive.read('OEBPS/content.opf'))
            manifest = {item.get('id'): item.get('href') for item in c.first(opf, 'manifest')}
            self.assertEqual([manifest[item.get('idref')] for item in c.first(opf, 'spine')], list(contents))
            for path, data in assets.items():
                self.assertEqual(archive.read(path), data)
            nav = c.xml(archive.read('OEBPS/homelibre-recovered-nav.xhtml'))
            self.assertEqual([link.get(c.EPUB_START_ONLY) for link in nav.iter() if c.tag(link) == 'a'], ['1'])
        c.convert_book(source, fb2, allow_partial_epub=True)
        self.validate_fb2(fb2)
        book = c.xml(fb2.read_bytes())
        bodies = c.children(book, 'body')
        self.assertEqual([c.plain(node) for body in bodies for node in body.iter()
                          if c.tag(node) == 'p' and c.plain(node)],
                         ['Вступление', 'Конец первого тома.', 'Начало второго тома.'])
        self.assertEqual(sum(c.tag(node) == 'image' for body in bodies for node in body.iter()), 2)
        self.assertEqual(digest(source), checksum)

        refusal = self.root / 'ambiguous.epub'
        for order, generator in ((list(reversed(contents)), None), (list(contents), 'Other tool')):
            truncate(source, order, generator)
            with self.subTest(order=order, generator=generator):
                with self.assertRaisesRegex(c.ConversionError, 'исходный порядок|порядок чтения'):
                    c.convert_book(source, refusal, allow_partial_epub=True)
                self.assertFalse(refusal.exists())

    def test_truncated_epub_keeps_the_first_chapter_prefix_and_original_spine(self):
        paragraphs = [f'Абзац {index:03d} с читаемым текстом.' for index in range(300)]
        source = self.generic(first=''.join(f'<p>{line}</p>' for line in paragraphs),
                              second='<p>Текст утраченной следующей главы.</p>',
                              extra_metadata='<meta name="cover" content="i"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        chapter = 'OPS/chapter.xhtml'
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'</package>', b'<guide><reference href="notes.xhtml" type="cover"/></guide></package>')
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('mimetype', entries.pop('mimetype'), compress_type=zipfile.ZIP_STORED)
            for name in ('META-INF/container.xml', 'OPS/package.opf', 'OPS/image.png', chapter, 'OPS/notes.xhtml', 'OPS/book.css'):
                archive.writestr(name, entries[name])
            info = archive.getinfo(chapter)
        packed = bytearray(source.read_bytes())
        name_length, extra_length = struct.unpack_from('<HH', packed, info.header_offset + 26)
        data_start = info.header_offset + 30 + name_length + extra_length
        # Reproduce the stale deflate option bits on the stored mimetype record.
        packed[6] = 6
        source.write_bytes(packed[:data_start + info.compress_size // 2])
        original = digest(source)
        self.assertEqual(c.detect_input(source), '.epub')

        for extension in ('.epub', '.fb2'):
            output = self.root / ('recovered-prefix' + extension)
            with self.assertRaisesRegex(c.ConversionError, 'нужно подтверждение'):
                c.convert_book(source, output)
            self.assertFalse(output.exists())
            report = c.convert_book(source, output, allow_partial_epub=True)
            warnings = c.damaged_content_warnings(report['warnings'])
            self.assertTrue(any('доступное начало раздела' in warning and chapter in warning for warning in warnings))
            self.assertTrue(any('OPS/notes.xhtml' in warning for warning in warnings))
            if extension == '.epub':
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read('OPS/image.png'), PNG)
                    opf = c.xml(archive.read('OPS/package.opf'))
                    self.assertEqual([item.get('idref') for item in c.first(opf, 'spine')], ['c', 'n'])
                    placeholder = c.xhtml(archive.read('OPS/notes.xhtml'))
                    self.assertEqual(next(node for node in placeholder.iter() if c.tag(node) == 'img').get('src'), 'image.png')
                    text = ''.join(c.plain(c.xhtml(archive.read(name))) for name in (chapter, 'OPS/notes.xhtml'))
            else:
                self.validate_fb2(output)
                book = c.xml(output.read_bytes())
                cover = next(node for node in book.iter() if c.tag(node) == 'coverpage')
                self.assertIsNotNone(c.first(cover, 'image'))
                self.assertEqual([base64.b64decode(node.text) for node in c.children(book, 'binary')], [PNG])
                text = c.plain(c.first(book, 'body'))
            self.assertIn(paragraphs[0], text)
            self.assertNotIn(paragraphs[-1], text)
            self.assertLess(text.index(paragraphs[10]), text.index('Конец раздела EPUB'))
            self.assertLess(text.index('Конец раздела EPUB'), text.index('отсутствует раздел «OPS/notes.xhtml»'))
        self.assertEqual(digest(source), original)

    def test_epub_with_truncated_metadata_preserves_spine_and_navigation(self):
        source = self.root / 'metadata-tail.epub'
        package = (f'<package xmlns="{c.OP}" version="2.0"><metadata/><manifest>'
                   '<item id="A" href="a.html" media-type="application/xhtml+xml"/>'
                   '<item id="B" href="b.html" media-type="application/xhtml+xml"/>'
                   '<item id="n" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
                   '</manifest><spine toc="n"><itemref idref="B"/><itemref idref="A"/></spine><')
        container = f'<container xmlns="{c.CN}"><rootfiles><rootfile full-path="content.opf"/></rootfiles></c'
        nav = ('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
               '<navPoint id="p1"><navLabel><text>Second filename first</text></navLabel>'
               '<content src="b.html#middle"/></navPoint></navMa')
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('mimetype', 'application/epub+zip')
            archive.writestr('META-INF/container.xml', container)
            archive.writestr('content.opf', package)
            archive.writestr('toc.ncx', nav)
            archive.writestr('a.html', f'<html xmlns="{c.XH}"><body><p>Last paragraph survives.</p>'
                             '<p><a href="old.html#middle">Second filename first</a></p>'
                             '<p><a href="unrelated.html#middle">Different label</a></p></body></html>')
            archive.writestr('b.html', '<!DOCTYPE html><html><head><link rel="stylesheet" href="book.css"></head>'
                             '<body><p id="middle">First <em>paragraph</em> survives.</p></body></html>')
            archive.writestr('book.css', 'p{font-size:1em}')
        original = digest(source)
        restored, fb2 = self.root / 'restored.epub', self.root / 'restored.fb2'
        for target in (restored, fb2):
            with self.assertRaisesRegex(c.ConversionError, 'нужно подтверждение'):
                c.convert_book(source, target)
            self.assertFalse(target.exists())
        report = c.convert_book(source, restored, reading=True)
        self.assertIn('container.xml, content.opf, toc.ncx', report['warnings'][0])
        with zipfile.ZipFile(restored) as archive:
            spine = c.first(c.xml(archive.read('content.opf')), 'spine')
            self.assertEqual([item.get('idref') for item in spine], ['B', 'A'])
            point = c.first(c.first(c.xml(archive.read('toc.ncx')), 'navMap'), 'navPoint')
            self.assertEqual(c.first(point, 'content').get('src'), 'b.html#middle')
            page = c.xml(archive.read('b.html'))
            self.assertEqual(next(n for n in page.iter() if n.get('id') == 'middle').tag, '{' + c.XH + '}p')
            links = [n.get('href') for n in c.xml(archive.read('a.html')).iter() if c.tag(n) == 'a']
            self.assertEqual(links, ['b.html#middle', 'unrelated.html#middle'])
            self.assertEqual(archive.read('book.css'), b'p{font-size:1em}')
        c.convert_book(source, fb2, allow_partial_epub=True)
        self.validate_fb2(fb2)
        text = c.plain(c.xml(fb2.read_bytes()))
        self.assertLess(text.index('First paragraph survives.'), text.index('Last paragraph survives.'))
        self.assertEqual(digest(source), original)

    def test_generated_kindle_navigation_escapes_labels_without_relaxing_other_xml(self):
        raw=(f'<html xmlns="{c.XH}"><body><nav><a href="part.xhtml?one=1&two=2">'
             'Hard & soft &amp; exact &#38; entities</a><!--keep & comment-->'
             '<![CDATA[keep & data]]></nav></body></html>').encode()
        document,changed=c.kindle_generated_xhtml(raw)
        self.assertTrue(changed)
        link=next(n for n in document.iter() if c.tag(n)=='a')
        self.assertEqual(link.get('href'),'part.xhtml?one=1&two=2')
        self.assertEqual(link.text,'Hard & soft & exact & entities')
        self.assertIn('keep & data',''.join(document.itertext()))
        self.assertFalse(c.kindle_generated_xhtml(c.serialized(document))[1])
        with self.assertRaises(c.ConversionError):c.kindle_xhtml(raw)
        for bad in (b'<html><body><p>A & B</body></html>',b'<html><body>A & B &unknown;</body></html>'):
            with self.assertRaises(c.ConversionError):c.kindle_generated_xhtml(bad)

    def test_generated_kindle_chapter_recovers_pagebreak_and_title(self):
        raw = b'<html><head><title>Hard & soft</title></head><body><p>A<mbp:pagebreak/>B</p></body></html>'
        document, changed = c.kindle_generated_xhtml(raw)
        self.assertTrue(changed)
        self.assertEqual(document.findtext('./head/title'), 'Hard & soft')
        self.assertEqual(document.find('./body/p/br').tail, 'B')
        self.assertEqual(document.find('./body/p').text, 'A')

    def test_fb2_keeps_a_quote_embedded_in_an_epub_heading(self):
        source = self.generic(first='<h1 id="chapter">Начало<blockquote><p>Цитата</p></blockquote>'
                                    'Продолжение</h1><p>Конец</p>', second='<p>Примечание</p>')
        output = self.root / 'heading-quote.fb2'
        c.convert_book(source, output)
        book = c.xml(output.read_bytes())
        section = next(node for node in book.iter('{' + c.FB + '}section')
                       if c.plain(c.first(node, 'title')) == 'Начало')
        self.assertEqual([(c.tag(child), c.plain(child)) for child in section],
                         [('title', 'Начало'), ('cite', 'Цитата'), ('p', 'Продолжение'), ('p', 'Конец')])

    def test_fb2_keeps_nested_quotes_in_reading_order(self):
        source = self.generic(
            first='<blockquote id="outer"><p>До <blockquote id="inner"><p><em>Цитата</em>'
                  '<img src="image.png" alt="Рисунок"/></p></blockquote> после</p></blockquote>'
                  '<p><a href="#outer">Внешняя</a> и <a href="#inner">Внутренняя</a></p>',
            notes_in_spine=False)
        output = self.root / 'nested-quotes.fb2'
        report = c.convert_book(source, output)
        book = c.xml(output.read_bytes())
        section = next(n for n in book.iter() if c.tag(n) == 'section' and c.plain(n) == 'До Цитата после')
        self.assertEqual([(c.tag(n), c.plain(n)) for n in section],
                         [('p', 'До'), ('cite', 'Цитата'), ('p', 'после')])
        cite = c.first(section, 'cite')
        self.assertEqual(c.plain(next(cite.iter('{' + c.FB + '}emphasis'))), 'Цитата')
        picture = next(cite.iter('{' + c.FB + '}image'))
        self.assertEqual(picture.get('alt'), 'Рисунок')
        images = {n.get('id'): base64.b64decode(n.text) for n in c.children(book, 'binary')}
        self.assertEqual(images[picture.get('{' + c.XL + '}href')[1:]], PNG)
        targets = {c.plain(n): n.get('{' + c.XL + '}href') for n in book.iter('{' + c.FB + '}a')}
        self.assertEqual(targets, {'Внешняя': '#' + section.get('id'), 'Внутренняя': '#' + cite.get('id')})
        self.assertTrue(any('Сложная цитата' in warning for warning in c.damaged_content_warnings(report['warnings'])))
        self.validate_fb2(output)
        quote_info = next(n for n in c.children(c.first(book, 'description'), 'custom-info')
                          if n.get('info-type') == c.FB2_QUOTE_SECTIONS)
        self.assertEqual(quote_info.text, section.get('id'))
        epub = self.root / 'nested-quotes-restored.epub'
        c.convert_book(output, epub)
        self.validate_epub(epub)
        with zipfile.ZipFile(epub) as archive:
            blocks = [node for name in archive.namelist() if name.endswith('.xhtml')
                      for node in c.xhtml(archive.read(name)).iter(f'{{{c.XH}}}blockquote')]
        outer = next(node for node in blocks if node.get('id') == section.get('id'))
        self.assertEqual(c.plain(outer), 'До Цитата после')
        self.assertIsNotNone(outer.find(f'{{{c.XH}}}blockquote'))
        roundtrip = self.root / 'nested-quotes-restored.fb2'
        c.convert_book(epub, roundtrip)
        self.validate_fb2(roundtrip)
        restored = c.xml(roundtrip.read_bytes())
        restored_info = next(n for n in c.children(c.first(restored, 'description'), 'custom-info')
                             if n.get('info-type') == c.FB2_QUOTE_SECTIONS)
        self.assertEqual(restored_info.text, quote_info.text)

    def test_plain_divs_within_epub_quote_keep_the_fb2_citation(self):
        source = self.generic(first='<blockquote id="outer"><div>Start <em>with style</em>'
                                    '<div><p id="middle">Quoted paragraph</p></div>End of quote</div></blockquote>'
                                    '<p><a href="#middle">Destination</a></p>',notes_in_spine=False)
        output = self.root / 'simple-quote.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        [cite] = list(book.iter(f'{{{c.FB}}}cite'))
        self.assertEqual([c.plain(node) for node in cite], ['Start with style', 'Quoted paragraph', 'End of quote'])
        self.assertEqual(c.plain(next(cite.iter(f'{{{c.FB}}}emphasis'))), 'with style')
        self.assertEqual(next(book.iter(f'{{{c.FB}}}a')).get(f'{{{c.XL}}}href'), '#' + cite[1].get('id'))
        self.assertFalse(c.damaged_content_warnings(report['warnings']))

    def test_streamed_fb2_round_trip_keeps_text_and_binary_data(self):
        epub = self.root / 'source.epub'
        fb2 = self.root / 'streamed.fb2'
        result = self.root / 'roundtrip.epub'
        c.convert_book(self.source, epub)
        c.epub_to_fb2(epub, fb2, set(), stream_images={})
        restored = c.xml(fb2.read_bytes())
        self.assertEqual([base64.b64decode(node.text) for node in c.children(restored, 'binary')], [PNG, PNG])
        self.assertIn('Цитата', c.plain(c.first(restored, 'body')))
        with mock.patch.object(c, 'MAX_FILE', 1024):
            c.fb2_to_epub(fb2, result, set(), maximum=c.MAX_TOTAL)
        with zipfile.ZipFile(result) as archive:
            names = [name for name in archive.namelist() if name.startswith('OEBPS/images/')]
            self.assertEqual([archive.read(name) for name in names], [PNG, PNG])
            self.assertIn('Цитата', archive.read('OEBPS/body-1.xhtml').decode('utf-8'))

    def test_epub_table_with_column_group_keeps_grid_and_links_in_fb2(self):
        source = self.generic(
            first='<p><a href="#columns">К таблице</a></p><table><colgroup id="columns">'
                  '<col width="35%"/><col class="wide"/></colgroup><tbody>'
                  '<tr><th>A</th><th>B</th></tr><tr><td>1</td><td><strong>2</strong></td></tr>'
                  '</tbody></table>',
            second='<p>Конец</p>', css='col.wide {width:65%}')
        destination = self.root / 'table-with-columns.fb2'
        report = c.convert_book(source, destination)
        self.validate_fb2(destination)
        root = c.xml(destination.read_bytes())
        table, = root.iter(f'{{{c.FB}}}table')
        self.assertEqual([[c.plain(cell) for cell in row] for row in table], [['A', 'B'], ['1', '2']])
        self.assertEqual(len(list(table.iter(f'{{{c.FB}}}strong'))), 1)
        link = next(root.iter(f'{{{c.FB}}}a'))
        self.assertEqual(link.get(f'{{{c.XL}}}href'), '#' + table.get('id'))
        warnings = c.damaged_content_warnings(report['warnings'])
        self.assertEqual(len(warnings), 1)
        self.assertTrue(warnings[0].startswith('Размеры или оформление столбцов EPUB'))

    def test_epub_table_cell_fills_survive_fb2_and_epub_round_trip(self):
        source = self.generic(
            first='<table><tr><td class="warm"><p>First</p><p>Second</p></td>'
                  '<td class="warm" style="/* author */ background-color:#abcdef">Inline</td>'
                  '<td id="fixed" class="warm" style="background-color:#abcdef">Priority</td>'
                  '<td class="warm" style="background:transparent">Reset</td>'
                  '<td class="quoted">No fill</td></tr></table>',
            second='<table><tr><td class="warm">Other chapter</td></tr></table>',
            css='td.warm {background-color:#8c4} td.warm {background-color:#123} '
                '#fixed {background-color:#ff5500 !important} '
                'td.quoted {content:";background-color:#ff0000;"}',
            head='<link rel="stylesheet" href="book.css" type="text/css"/>')
        with zipfile.ZipFile(source) as archive:
            members = {name: archive.read(name) for name in archive.namelist()}
        members['OPS/notes.xhtml'] = members['OPS/notes.xhtml'].replace(
            b'<link rel="stylesheet" href="book.css" type="text/css"/>',
            b'<style>td.warm {background:#456}</style>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in members.items():
                archive.writestr(name, data)
        fb2 = self.root / 'table-fills.fb2'
        c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        before = c.xml(fb2.read_bytes())
        cells = list(before.iter(f'{{{c.FB}}}td'))
        expected = [c.FB2_TABLE_LINE_STYLE + ';background-color:#112233', 'background-color:#abcdef',
                    'background-color:#ff5500', None, None, 'background-color:#445566']
        self.assertEqual([cell.get('style') for cell in cells], expected)
        self.assertEqual(c.plain(cells[0]).split(), ['First', 'Second'])

        epub = self.root / 'table-fills.epub'
        c.convert_book(fb2, epub)
        with zipfile.ZipFile(epub) as archive:
            cells = [cell for name in archive.namelist() if name.endswith('.xhtml')
                     for cell in c.xml(archive.read(name)).iter(f'{{{c.XH}}}td')]
        self.assertEqual([cell.get('style') for cell in cells], expected)
        restored = self.root / 'table-fills-restored.fb2'
        c.convert_book(epub, restored)
        self.validate_fb2(restored)
        self.assertEqual([cell.get('style') for cell in c.xml(restored.read_bytes()).iter(f'{{{c.FB}}}td')], expected)

    def test_epub_table_borders_and_padding_keep_cascade_order_in_fb2_and_epub(self):
        source = self.generic(
            first='<table class="matrix"><tr><td class="edge" style="padding:8px 2px">First</td>'
                  '<td style="border:0; padding:expression(3px); border-image:url(http://example.invalid)">Second</td>'
                  '</tr></table>',
            second='<p>End</p>',
            css='table.matrix {border-collapse:collapse} .edge {border:1px solid #123456} '
                'td.edge {border-left:none; padding-top:0 !important; border-bottom-width:2px}',
            head='<link rel="stylesheet" href="book.css" type="text/css"/>')
        destination = self.root / 'cell-geometry.fb2'
        c.convert_book(source, destination)
        self.validate_fb2(destination)
        table, = c.xml(destination.read_bytes()).iter(f'{{{c.FB}}}table')
        self.assertEqual(table.get('style'), 'border-collapse:collapse')
        expected = 'border:1px solid #123456;border-left:none;border-bottom-width:2px;padding:8px 2px;padding-top:0'
        self.assertEqual([cell.get('style') for cell in table[0]], [expected, 'border:0'])
        self.assertEqual([c.plain(cell) for cell in table[0]], ['First', 'Second'])

        result = self.root / 'cell-geometry.epub'
        c.convert_book(destination, result)
        with zipfile.ZipFile(result) as archive:
            table, = [node for name in archive.namelist() if name.endswith('.xhtml')
                      for node in c.xml(archive.read(name)).iter(f'{{{c.XH}}}table')]
        self.assertEqual(table.get('style'), 'border-collapse:collapse')
        self.assertEqual([cell.get('style') for cell in table[0]], [expected, 'border:0'])

    def test_epub_export_does_not_parse_the_complete_fb2_tree(self):
        source = self.generic()
        destination = self.root / 'chapters.fb2'
        progress = []
        parse = c.xml

        def individual_parts_only(data, *args, **kwargs):
            self.assertNotIn(b'<FictionBook', data)
            return parse(data, *args, **kwargs)

        with mock.patch.object(c, 'xml', side_effect=individual_parts_only):
            c.convert_book(source, destination, progress=lambda *step: progress.append(step))
        c.validate_fb2_output(c.xml(destination.read_bytes()))
        self.assertTrue(any(stage == 'checking-fb2-sections' for stage, _, _ in progress))

    def test_streamed_fb2_accepts_body_prefix_and_rejects_a_late_title(self):
        source = self.root / 'preface-and-notes.fb2'
        source.write_text(f'''<FictionBook xmlns="{c.FB}" xmlns:l="{c.XL}">
            <body><image l:href="#cover"/><title><p>Оглавление</p></title>
            <epigraph><p>Цитата</p></epigraph><section><p><a l:href="#note">Текст</a></p></section></body>
            <body name="notes"><title><p>Примечания</p></title>
            <section id="note"><p>Сноска</p></section></body>
            <binary id="cover" content-type="image/png"/></FictionBook>''', encoding='utf-8')
        c.validate_streamed_fb2(source)
        book = c.xml(source.read_bytes())
        body = c.first(book, 'body')
        title = c.first(body, 'title')
        body.remove(title)
        body.append(title)
        source.write_bytes(c.serialized(book))
        with self.assertRaisesRegex(c.ConversionError, 'заголовок расположен после'):
            c.validate_streamed_fb2(source)

    def test_generated_chm_sections_stream_to_fb2_with_cross_section_links(self):
        source = self.generic(
            first='<h1 id="one">Первая</h1><p><a href="notes.xhtml#inline">Вторая</a>'
                  '<img src="image.png" width="2" height="3"/></p>',
            second='<h1>Вторая</h1><table><tr><td><p><span id="inline">Ячейка</span>'
                   '<a href="chapter.xhtml#one">Назад</a></p></td></tr></table>')
        spool = self.root / 'spool'
        spool.mkdir()
        ordinary = self.root / 'ordinary.fb2'
        streamed = self.root / 'streamed-chm.fb2'
        ordinary_warnings, streamed_warnings = set(), set()
        c.epub_to_fb2(source, ordinary, ordinary_warnings, stream_images={}, use_navigation=False)
        c.epub_to_fb2(source, streamed, streamed_warnings, stream_images={}, use_navigation=False,
                     generated_sections=spool)
        c.validate_streamed_fb2(streamed)
        self.validate_fb2(streamed)
        actual = c.xml(streamed.read_bytes())
        expected = c.xml(ordinary.read_bytes())
        for tag in ('body', 'binary', 'stylesheet'):
            self.assertEqual([c.serialized(node) for node in c.children(actual, tag)],
                             [c.serialized(node) for node in c.children(expected, tag)])
        self.assertEqual(streamed_warnings, ordinary_warnings)
        link = next(c.first(actual, 'body').iter('{' + c.FB + '}a'))
        link.set('{' + c.XL + '}href', '#missing')
        streamed.write_bytes(c.serialized(actual))
        with self.assertRaisesRegex(c.ConversionError, 'отсутствует цель ссылки'):
            c.validate_streamed_fb2(streamed)

    def test_streamed_fb2_keeps_chapter_order_links_and_body_across_epub_parts(self):
        source, epub, restored = (self.root / name for name in ('big.fb2', 'big.epub', 'restored.fb2'))
        paragraphs = '<p>Текст главы.</p>' * 26000
        source.write_text(f'''<FictionBook xmlns="{c.FB}" xmlns:l="{c.XL}"><description><title-info>
            <genre>unrecognised</genre><author><nickname>Автор</nickname></author><book-title>Книга</book-title><lang>ru</lang>
            </title-info></description><body id="main"><section id="start"><title><p>Первая глава</p></title>
            <p><a l:href="#end">Вторая глава</a></p>{paragraphs}</section>
            <section id="end"><title><p>Вторая глава</p></title><p><a l:href="#start">В начало</a></p>{paragraphs}</section>
            </body></FictionBook>''', encoding='utf-8')
        with mock.patch.object(c, 'MAX_FILE', source.stat().st_size - 1):
            c.fb2_to_epub(source, epub, set(), maximum=c.MAX_TOTAL)
        with zipfile.ZipFile(epub) as archive:
            first = c.xml(archive.read('OEBPS/body-1.xhtml'))
            last = c.xml(archive.read('OEBPS/body-1-2.xhtml'))
            self.assertIn('body-1-2.xhtml#end', {n.get('href') for n in first.iter()})
            self.assertIn('body-1.xhtml#start', {n.get('href') for n in last.iter()})
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            self.assertEqual([n.get('href') for n in nav.iter() if c.tag(n) == 'a'],
                             ['body-1.xhtml#start', 'body-1-2.xhtml#end'])
        c.epub_to_fb2(epub, restored, set())
        [body] = c.children(c.xml(restored.read_bytes()), 'body')
        self.assertEqual(body.get('id'), 'main')
        self.assertEqual([n.get('id') for n in c.children(body, 'section')], ['start', 'end'])
        self.assertEqual([n.get('{' + c.XL + '}href') for n in body.iter() if c.tag(n) == 'a'], ['#end', '#start'])

    def test_large_fb2_keeps_body_prefixes_trailing_text_and_named_notes(self):
        source = self.root / 'named-bodies.fb2'
        source.write_text(f'''<FictionBook xmlns="{c.FB}" xmlns:l="{c.XL}">
            <description><title-info><genre>unrecognised</genre><author><nickname>Автор</nickname></author>
            <book-title>Книга</book-title><lang>ru</lang></title-info></description>
            <body id="reading">Предисловие<section id="first"><p>Первая <a l:href="#note">Сноска</a></p></section>
            Между разделами<section><p>Вторая</p></section>После разделов</body>
            <body name="notes"><section id="note"><p>Текст сноски <a l:href="#first">Назад</a></p></section></body>
            </FictionBook>''', encoding='utf-8')
        ordinary = self.root / 'ordinary.epub'
        streamed = self.root / 'streamed.epub'
        c.fb2_to_epub(source, ordinary, set())
        with mock.patch.object(c, 'MAX_FILE', source.stat().st_size - 1):
            c.fb2_to_epub(source, streamed, set(), maximum=c.MAX_TOTAL)
        with zipfile.ZipFile(ordinary) as expected, zipfile.ZipFile(streamed) as actual:
            for filename in ('body-1.xhtml', 'body-2.xhtml', 'nav.xhtml'):
                self.assertEqual(c.serialized(c.xml(actual.read('OEBPS/' + filename))),
                                 c.serialized(c.xml(expected.read('OEBPS/' + filename))))

    def test_ibooks_html_keeps_ordinary_chapters_but_refuses_widgets(self):
        epub = self.generic(first='<p>Первый абзац<p>Второй абзац', notes_in_spine=False)
        with zipfile.ZipFile(epub) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        opf = c.xml(files['OPS/package.opf'])
        chapter = next(item for item in c.first(opf, 'manifest') if item.get('id') == 'c')
        chapter.set('media-type', 'application/x-ibooks-html')
        for href in ('chapter.xhtml', 'interactive.wdgt/chapter.xhtml'):
            chapter.set('href', href)
            with zipfile.ZipFile(epub, 'w') as archive:
                for name, data in files.items():
                    if name == 'OPS/chapter.xhtml':
                        archive.writestr('OPS/' + href, data)
                    else:
                        archive.writestr(name, c.serialized(opf) if name == 'OPS/package.opf' else data)
            output = self.root / (Path(href).parent.name + 'ibooks.fb2')
            if href.startswith('interactive'):
                with self.assertRaisesRegex(c.ConversionError, 'виджет Apple Books'):
                    c.convert_book(epub, output)
                self.assertFalse(output.exists())
            else:
                c.convert_book(epub, output)
                text = c.plain(c.xml(output.read_bytes()))
                self.assertIn('Первый абзац', text)
                self.assertIn('Второй абзац', text)

    def test_multimedia_preview_keeps_the_poster_and_reports_lost_media(self):
        source = self.generic(first='<p>Текст перед роликом.</p><video title="Обложка" poster="image.png">'
                                   '<source src="cover.mp4"/><p>Описание ролика.</p></video>'
                                   '<audio src="sample.m4a"/><p>Последний абзац.</p>', notes_in_spine=False)
        output = self.root / 'media.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'video'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        result = c.convert_book(source, output, allow_partial_epub=True)
        book = c.xml(output.read_bytes())
        self.assertEqual([base64.b64decode(node.text) for node in c.children(book, 'binary')], [PNG])
        for words in ('Текст перед роликом.', 'Описание ролика.', 'Последний абзац.'):
            self.assertIn(words, c.plain(c.first(book, 'body')))
        self.assertEqual(set(c.damaged_content_warnings(result['warnings'])), {
            'Видео EPUB не перенесено: «Обложка».', 'Аудио EPUB не перенесено: «sample.m4a».'})

    def test_partial_epub_recovers_a_chapter_with_mismatched_tags(self):
        source = self.generic(first='<p>До ошибки.</div><p>После ошибки.</p>'
                                     '<p><a href="../../outside.xhtml">Текст ссылки</a></p>',
                              notes_in_spine=False)
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(files['OPS/package.opf'])
        missing_style = c.element(c.OP, 'item', id='absent-style', href='absent.css', **{'media-type': 'text/css'})
        c.first(package, 'manifest').append(missing_style)
        files['OPS/package.opf'] = c.serialized(package)
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        output = self.root / 'recovered.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'Ссылка EPUB выходит за пределы книги'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        result = c.convert_book(source, output, allow_partial_epub=True)
        document = c.first(c.xml(output.read_bytes()), 'body')
        text = c.plain(document)
        self.assertIn('До ошибки.', text)
        self.assertIn('После ошибки.', text)
        self.assertIn('Текст ссылки', text)
        self.assertFalse(any('outside.xhtml' in node.get('{' + c.XL + '}href', '') for node in document.iter()))
        self.assertIn(c.EPUB_CLOSING_TAG_REPAIR, result['warnings'])
        warnings = c.damaged_content_warnings(result['warnings'])
        for part in ('Ссылка выходит за пределы книги', '«absent.css»'):
            self.assertTrue(any(part in notice for notice in warnings), warnings)

    def test_epub_balances_closing_tags_without_changing_other_markup(self):
        source = self.generic(
            first='<h1 id="chapter">Начало</h1><div><span class="kept"><p>Текст '
                  '<em>с выделением</em>.</p></div></span>'
                  '<blockquote>Цитата</blockquote></blockquote><p><a href="#chapter">Назад</a> '
                  '<img src="image.png"/></p>',
            second='<p>Следующий раздел.</p>')
        part = 'OPS/chapter.xhtml'
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        expected = files[part].replace(b'</p></div></span>', b'</p></span></div>').replace(
            b'</blockquote></blockquote>', b'</blockquote>')
        before = digest(source)
        epub = self.root / 'balanced.epub'
        report = c.convert_book(source, epub)
        self.assertIn(c.EPUB_CLOSING_TAG_REPAIR, report['warnings'])
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            self.assertEqual(archive.read(part), expected)
            self.assertEqual({name for name in files if archive.read(name) != files[name]}, {part})
        fb2 = self.root / 'balanced.fb2'
        c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        body = c.first(c.xml(fb2.read_bytes()), 'body')
        self.assertIn('с выделением', [c.plain(n) for n in body.iter('{' + c.FB + '}emphasis')])
        self.assertTrue(any(c.plain(n) == 'Назад' for n in body.iter('{' + c.FB + '}a')))
        self.assertEqual(digest(source), before)

    def test_epub_truncated_chapter_requires_partial_export_and_keeps_available_content(self):
        source = self.generic(first='<h1 id="chapter">Начало</h1><div><p>До конца файла.</p></div>',
                              second='<p>Другая глава.</p>')
        part = 'OPS/chapter.xhtml'
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        original = files[part]
        files[part] = original.removesuffix(b'</div></body></html>')
        self.assertNotEqual(original, files[part])
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        before = digest(source)
        for suffix in ('.epub', '.fb2'):
            output = self.root / ('accepted' + suffix)
            with self.assertRaisesRegex(c.ConversionError, 'chapter.xhtml.*подтверждение'):
                c.convert_book(source, output)
            self.assertFalse(output.exists())
            report = c.convert_book(source, output, allow_partial_epub=True)
            warnings = c.damaged_content_warnings(report['warnings'])
            self.assertTrue(any(w.startswith(c.EPUB_TRUNCATED_CHAPTER) and 'chapter.xhtml' in w for w in warnings))
            if suffix == '.epub':
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read(part), original)
            else:
                self.validate_fb2(output)
                text = c.plain(c.first(c.xml(output.read_bytes()), 'body'))
                self.assertLess(text.index('До конца файла.'), text.index('Другая глава.'))
        self.assertEqual(digest(source), before)
        for unclosed in (b'<svg><g/>', b'<p>Text<img sr'):
            bad = b'<html><body>' + unclosed
            with self.assertRaises(c.ConversionError):
                c.read_epub_content(bad, set(), allow_partial_epub=True)

    def test_epub_recovers_intact_text_after_an_incomplete_container_start(self):
        source = self.generic(first='<p id="before">Before.</p>\n<p id="after">After.</p>',
                              second='<p>Next chapter.</p>')
        part = 'OPS/chapter.xhtml'
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        original = files[part]
        files[part] = original.replace(b'\n<p id="after">', b'\n<p c\n<p id="after">')
        self.assertNotEqual(original, files[part])
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        before = digest(source)
        for suffix in ('.epub', '.fb2'):
            output = self.root / ('incomplete-tag' + suffix)
            with self.assertRaisesRegex(c.ConversionError, 'chapter.xhtml.*подтверждение'):
                c.convert_book(source, output)
            self.assertFalse(output.exists())
            report = c.convert_book(source, output, allow_partial_epub=True)
            self.assertTrue(any(w.startswith(c.EPUB_DANGLING_START) and 'chapter.xhtml' in w
                                for w in c.damaged_content_warnings(report['warnings'])))
            if suffix == '.epub':
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read(part), original)
            else:
                self.validate_fb2(output)
                body = c.first(c.xml(output.read_bytes()), 'body')
                parts = [c.plain(p) for p in body.iter('{' + c.FB + '}p')]
                self.assertEqual(parts, ['Before.', 'After.', 'Next chapter.'])
        self.assertEqual(digest(source), before)

    def test_epub_recovers_inline_truncation_and_marks_a_chapter_without_body(self):
        source = self.generic(first='<div><h3\n<p>Доступный абзац.</p></div>', second='<p>Другая глава.</p>')
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/chapter.xhtml'] = files['OPS/chapter.xhtml'].removesuffix(b'</div></body></html>')
        files['OPS/notes.xhtml'] = f'<html xmlns="{c.XH}"><head><title>Фрагмент'.encode()

        def write_source():
            with zipfile.ZipFile(source, 'w') as archive:
                for name, data in files.items():
                    archive.writestr(name, data)

        write_source()
        original = digest(source)
        for suffix in ('.epub', '.fb2'):
            output = self.root / ('partial' + suffix)
            with self.assertRaisesRegex(c.ConversionError, 'подтверждение'):
                c.convert_book(source, output)
            self.assertFalse(output.exists())
            report = c.convert_book(source, output, allow_partial_epub=True)
            warnings = c.damaged_content_warnings(report['warnings'])
            self.assertTrue(any(w.startswith(c.EPUB_DANGLING_START) and 'chapter.xhtml' in w for w in warnings))
            self.assertTrue(any(w.startswith(c.EPUB_MISSING_BODY) and 'notes.xhtml' in w for w in warnings))
            if suffix == '.epub':
                with zipfile.ZipFile(output) as archive:
                    text = ''.join(c.plain(c.xhtml(archive.read(name))) for name in ('OPS/chapter.xhtml', 'OPS/notes.xhtml'))
            else:
                self.validate_fb2(output)
                text = c.plain(c.first(c.xml(output.read_bytes()), 'body'))
            self.assertLess(text.index('Доступный абзац.'), text.index('В разделе EPUB отсутствует содержимое'))
            self.assertIn('Фрагмент', text)
        self.assertEqual(digest(source), original)

        files['OPS/chapter.xhtml'] = b'\n\t'
        write_source()
        for suffix in ('.epub', '.fb2'):
            output = self.root / ('empty' + suffix)
            with self.assertRaisesRegex(c.ConversionError, 'глав'):
                c.convert_book(source, output, allow_partial_epub=True)
            self.assertFalse(output.exists())

    def test_epub_rejoins_readable_markup_after_the_closed_chapter(self):
        source = self.generic(first='<h1 id="chapter">Opening</h1><p>Chapter end.</p>', second='<p>Next chapter.</p>')
        part = 'OPS/chapter.xhtml'
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files[part] += (b'<br><p><center>Appendix <em>keeps emphasis</em> '
                        b'<a href="#chapter">Back to the start</a>.</center><p>Last line.')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        source_digest = digest(source)

        fb2 = self.root / 'appended.fb2'
        report = c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        self.assertEqual(c.damaged_content_warnings(report['warnings']), [])
        self.assertIn(c.EPUB_TRAILING_MARKUP_REPAIR, report['warnings'])
        body = c.first(c.xml(fb2.read_bytes()), 'body')
        text = c.plain(body)
        positions = [text.index(phrase) for phrase in ('Chapter end.', 'Appendix', 'Last line.', 'Next chapter.')]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('keeps emphasis', [c.plain(n) for n in body.iter('{' + c.FB + '}emphasis')])
        link = next(n for n in body.iter('{' + c.FB + '}a') if c.plain(n) == 'Back to the start')
        self.assertIn(link.get('{' + c.XL + '}href')[1:], {n.get('id') for n in body.iter()})

        epub = self.root / 'appended.epub'
        c.convert_book(source, epub)
        c.validate_epub_output(epub)
        with zipfile.ZipFile(epub) as archive:
            self.assertEqual({name for name in files if archive.read(name) != files[name]}, {part})
            chapter = c.xhtml(archive.read(part))
            centered = next(node for node in chapter.iter() if node.get('style') == 'text-align:center')
            self.assertIn('Appendix', c.plain(centered))
        self.assertEqual(digest(source), source_digest)

        for fragment in (b'<html><body>Second document</body></html>', b'<script>Active code</script>'):
            chapter = files[part].split(b'<br><p><center>')[0] + fragment
            with self.assertRaisesRegex(c.ConversionError, 'junk after document element'):
                c.read_epub_content(chapter, set())

    def test_kindle_skeleton_namespaces_preserve_text_and_note_semantics(self):
        raw = ('<html:html><html:body><html:p>Ёжик <html:a epub:type="noteref" href="#note">1</html:a>'
               '</html:p></html:body></html:html>').encode('utf-8')
        document, changed = c.kindle_xhtml(raw)
        self.assertTrue(changed)
        self.assertEqual(document.tag, '{http://www.w3.org/1999/xhtml}html')
        link = next(n for n in document.iter() if c.tag(n) == 'a')
        self.assertEqual(link.get('{http://www.idpf.org/2007/ops}type'), 'noteref')
        self.assertIn('Ёжик', ''.join(document.itertext()))
        valid = c.serialized(document)
        self.assertFalse(c.kindle_xhtml(valid)[1])
        for invalid in (b'<html><body><unknown:element/></body></html>',
                        b'<html><body><p>broken</body></html>',
                        b'<!DOCTYPE html [<!ENTITY unsafe SYSTEM "file:///never-read">]><html><body>&unsafe;</body></html>'):
            with self.assertRaises(c.ConversionError):
                c.kindle_xhtml(invalid)

    def test_fb2_jpeg_aliases_and_mislabeled_images_keep_bytes(self):
        jpeg = base64.b64decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwC/RRRXwx9uf//Z')
        cases = [('image/jpg', jpeg, 'image/jpeg', '.jpg'),
                 (' IMAGE/PJPEG ; legacy=yes ', jpeg, 'image/jpeg', '.jpg'),
                 ('image/png', jpeg, 'image/jpeg', '.jpg'),
                 ('image/jpg', PNG, 'image/png', '.png'),
                 ('application/octet-stream', PNG, 'image/png', '.png')]
        for index, (declared, image, expected, suffix) in enumerate(cases):
            with self.subTest(declared=declared, expected=expected):
                source = self.root/f'alias-{index}.fb2'
                source.write_text(FB2.replace('image/png', declared).replace('{image}', base64.b64encode(image).decode()), encoding='utf-8')
                original = source.read_bytes()
                output = self.root/f'alias-{index}.epub'
                c.convert_book(source, output)
                self.assertEqual(source.read_bytes(), original)
                with zipfile.ZipFile(output) as archive:
                    package = c.xml(archive.read('OEBPS/package.opf'))
                    images = [n for n in package.iter() if n.get('media-type', '').startswith('image/')]
                    self.assertEqual(len(images), 2)
                    for item in images:
                        self.assertEqual(item.get('media-type'), expected)
                        self.assertTrue(item.get('href').endswith(suffix))
                        self.assertEqual(archive.read('OEBPS/'+item.get('href')), image)
        with self.assertRaises(c.ConversionError):
            c.fb2_image_type(b'unknown data', 'image/not-supported')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-conversion-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root/'source.fb2'; self.source.write_text(FB2.replace('{image}',base64.b64encode(PNG).decode()), encoding='utf-8')
        self.original = digest(self.source)
    def tearDown(self):
        self.assertEqual(digest(self.source), self.original)
        self.assertFalse(list(self.root.glob('.homelib-convert-*')))
    def test_plain_text_starting_with_angle_marker_is_not_xml(self):
        text = '<|title|>\nVisible text.'
        for encoding in ('utf-8', 'utf-8-sig', 'utf-16'):
            for suffix in ('.txt', '.unknown'):
                source = self.root / f'angle-{encoding}{suffix}'
                source.write_text(text, encoding=encoding)
                self.assertEqual(c.detect_input(source), '.txt')
                for target in ('.fb2', '.epub'):
                    output = source.with_suffix(target)
                    c.convert_book(source, output)
                    if target == '.fb2':
                        body = c.xml(output.read_bytes())
                    else:
                        with zipfile.ZipFile(output) as archive:
                            name = next(name for name in archive.namelist() if name.endswith('.xhtml') and not name.endswith('/nav.xhtml'))
                            body = c.xml(archive.read(name))
                    self.assertIn('<|title|>', c.plain(body))
                    self.assertIn('Visible text.', c.plain(body))
                    output.unlink()
        source = self.root / 'markup.txt'
        source.write_text('<?xml version="1.0"?><catalogue/>', encoding='utf-8-sig')
        self.assertEqual(c.detect_input(source), '.xml')

    def test_fb2_declared_windows_1251_preserves_real_encoding(self):
        text = ('<?xml version="1.0" encoding="windows-1251"?>'
                '<FictionBook xmlns="'+c.FB+'"><description><title-info><author><last-name>Сорокин</last-name>'
                '</author><book-title>Книга с кодировкой</book-title><lang>ru</lang></title-info></description>'
                '<body><section><p>Русский текст с буквой ё.</p></section></body></FictionBook>')
        for encoding in ('utf-8', 'utf-8-sig', 'windows-1251'):
            with self.subTest(encoding=encoding):
                source = self.root/(encoding+'.fb2')
                source.write_bytes(text.encode(encoding))
                original = source.read_bytes()
                converted = source.with_suffix('.epub')
                c.convert_book(source, converted)
                with zipfile.ZipFile(converted) as archive:
                    self.assertIn('Книга с кодировкой', archive.read('OEBPS/package.opf').decode('utf-8'))
                    self.assertIn('Русский текст с буквой ё.', archive.read('OEBPS/body-1.xhtml').decode('utf-8'))
                self.assertEqual(source.read_bytes(), original)
                copied = self.root/(encoding+'-copy.fb2')
                c.convert_book(source, copied)
                self.assertEqual(copied.read_bytes(), original)
        mixed = text.encode('utf-8') + b'\xff'
        self.assertEqual(c.repair_fb2_encoding(mixed), mixed)

    def test_already_target_format_is_validated_and_copied_without_rewriting(self):
        target=self.root/'same.fb2';c.convert_book(self.source,target)
        self.assertEqual(target.read_bytes(),self.source.read_bytes())
        epub=self.generic();target=self.root/'same.epub';c.convert_book(epub,target)
        self.assertEqual(target.read_bytes(),epub.read_bytes())
        # Content still wins over an apparently matching target suffix.
        disguised=self.root/'actually-fb2.epub';disguised.write_bytes(self.source.read_bytes())
        converted=self.root/'actual.epub';c.convert_book(disguised,converted)
        with zipfile.ZipFile(converted) as archive:self.assertIsNone(archive.testzip())
    def validate_fb2(self, path):
        schema = os.environ.get('HOMELIB_TEST_FB2_SCHEMA')
        if schema:
            from lxml import etree
            validator = etree.XMLSchema(etree.parse(schema))
            self.assertTrue(validator.validate(etree.parse(str(path))), str(validator.error_log))
    def test_broken_source_fb2_links_keep_labels_and_valid_notes_still_work(self):
        source = self.root/'broken-links.fb2'
        book = ET.parse(self.source).getroot()
        paragraph = next(n for n in book.iter('{'+c.FB+'}p') if n.get('id') == 'para')
        for target, note in [('#absent-note', True), ('#botbybase_bot?startgroup=1', False)]:
            link = c.element(c.FB, 'a', 'Visible ', **{'{'+c.XL+'}href':target})
            if note:
                link.set('type', 'note'); link.set('id', 'broken-anchor')
            style = c.element(c.FB, 'style'); style.append(c.element(c.FB, 'strong', 'label')); link.append(style)
            link[-1].tail = ' end'
            paragraph.append(link); link.tail = ' after '
        paragraph.append(c.element(c.FB, 'a', 'To preserved label', **{'{'+c.XL+'}href':'#broken-anchor'}))
        source.write_bytes(c.serialized(book)); before = digest(source)
        epub, result = self.root/'broken-links.epub', self.root/'links-back.fb2'
        report = c.convert_book(source, epub)
        self.assertTrue(any('отсутствуют цели ссылок: 2' in n for n in report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            body = c.xml(archive.read('OEBPS/body-1.xhtml'))
            self.assertEqual(c.plain(body).count('Visible label end after'), 2)
            broken = [n for n in body.iter() if n.get('data-homelib-source-href')]
            self.assertEqual(len(broken), 2)
            self.assertTrue(all(c.tag(n)=='span' and not n.get('href') and not n.get('{'+c.EP+'}type') for n in broken))
            valid = next(n for n in body.iter() if n.get('href')=='body-2.xhtml#note')
            self.assertEqual(valid.get('{'+c.EP+'}type'), 'noteref')
        c.convert_book(epub, result); c.validate_fb2_output(ET.parse(result).getroot()); self.validate_fb2(result)
        back = ET.parse(result).getroot()
        self.assertEqual(c.plain(back).count('Visible label end after'), 2)
        self.assertTrue(any(n.get('{'+c.XL+'}href')=='#note' for n in back.iter('{'+c.FB+'}a')))
        label_link=next(n for n in back.iter('{'+c.FB+'}a') if c.plain(n)=='To preserved label')
        self.assertEqual(label_link.get('{'+c.XL+'}href'),'#para')
        self.assertTrue(any(n.get('id')=='para' for n in back.iter('{'+c.FB+'}p')))
        self.assertEqual(digest(source), before)
    def test_nonstandard_fb2_breaks_keep_text_formatting_and_targets(self):
        book = ET.parse(self.source).getroot()
        paragraph = c.element(c.FB, 'p', 'Before ')
        bold = c.element(c.FB, 'strong', 'Bold before'); paragraph.append(bold)
        line = c.element(c.FB, 'br', id='line-break'); bold.append(line); line.tail = 'Bold after'
        paragraph.append(c.element(c.FB, 'br')); paragraph[-1].tail = 'After'
        paragraph.append(c.element(c.FB, 'a', 'Break target', **{'{'+c.XL+'}href':'#line-break'}))
        c.first(c.first(book, 'body'), 'section').append(paragraph)
        source = self.root/'breaks.fb2'; source.write_bytes(c.serialized(book)); before = digest(source)
        epub, result = self.root/'breaks.epub', self.root/'breaks-back.fb2'
        report = c.convert_book(source, epub)
        self.assertTrue(any('br' in n for n in report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            body = c.xml(archive.read('OEBPS/body-1.xhtml'))
            self.assertEqual(len(list(body.iter('{'+c.XH+'}br'))), 2)
            self.assertIn('Before Bold beforeBold afterAfterBreak target', c.plain(body))
        c.convert_book(epub, result); back = ET.parse(result).getroot()
        c.validate_fb2_output(back); self.validate_fb2(result)
        self.assertEqual(sum(c.plain(n).count('Bold before') + c.plain(n).count('Bold after') for n in back.iter('{'+c.FB+'}strong')), 2)
        self.assertTrue(any(n.get('id')=='line-break' for n in back.iter()))
        self.assertTrue(any(n.get('{'+c.XL+'}href')=='#line-break' for n in back.iter('{'+c.FB+'}a')))
        self.assertEqual(digest(source), before)
    def test_same_fb2_retains_source_defects_but_generated_defects_fail(self):
        book = ET.parse(self.source).getroot()
        paragraph = next(n for n in book.iter('{'+c.FB+'}p') if n.get('id') == 'para')
        paragraph.append(c.element(c.FB, 'p', 'Nested original paragraph'))
        source = self.root/'source-layout.fb2'; source.write_bytes(c.serialized(book)); before = digest(source)
        output = self.root/'unchanged-layout.fb2'
        report = c.convert_book(source, output)
        self.assertEqual(output.read_bytes(), source.read_bytes())
        self.assertTrue(any('исходной FB2 есть ошибки разметки' in n for n in report['warnings']))
        stripped = self.root/'layout-without-images.fb2'
        c.convert_book(source, stripped, image_quality='none')
        stripped_book = ET.parse(stripped).getroot()
        self.assertIn('Nested original paragraph', c.plain(stripped_book))
        self.assertFalse(list(stripped_book.iter('{'+c.FB+'}image')))
        with self.assertRaises(c.ConversionError): c.validate_fb2_output(book)
        baseline = c.Counter(key for key, _ in c.fb2_output_issues(book))
        c.validate_fb2_output(book, baseline)
        paragraph.append(c.element(c.FB, 'p', 'New broken paragraph'))
        with self.assertRaises(c.ConversionError): c.validate_fb2_output(book, baseline)
        self.assertEqual(digest(source), before)
    def test_unambiguous_duplicate_and_unnamed_binary_resources_are_preserved(self):
        book = ET.parse(self.source).getroot()
        original = c.children(book, 'binary')[0]
        duplicate = ET.fromstring(ET.tostring(original)); book.append(duplicate)
        unnamed = ET.fromstring(ET.tostring(original)); unnamed.attrib.pop('id'); book.append(unnamed)
        source = self.root/'image-identities.fb2'; source.write_bytes(c.serialized(book)); before = digest(source)
        epub, result = self.root/'image-identities.epub', self.root/'image-identities-back.fb2'
        report = c.convert_book(source, epub)
        self.assertTrue(any('повторяющимся идентификатором' in n for n in report['warnings']))
        self.assertTrue(any('без идентификатора' in n for n in report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            images = [name for name in archive.namelist() if name.startswith('OEBPS/images/')]
            self.assertEqual(len(images), 3)
            self.assertTrue(all(archive.read(name)==PNG for name in images))
        c.convert_book(epub, result); back = ET.parse(result).getroot()
        c.validate_fb2_output(back); self.validate_fb2(result)
        self.assertEqual(len(c.children(back, 'binary')), 3)
        self.assertEqual(digest(source), before)
    def test_conflicting_source_images_keep_all_bytes_and_text_anchor_identities(self):
        for kind in ('conflict', 'body-id'):
            book = ET.parse(self.source).getroot(); binary = c.children(book, 'binary')[0]
            if kind=='conflict':
                other = ET.fromstring(ET.tostring(binary)); other.text = base64.b64encode(PNG+b'other').decode(); book.append(other)
            else:
                picture = next(c.first(book,'body').iter('{'+c.FB+'}image')); picture.set('id', 'cover')
                paragraph = c.first(c.first(c.first(book,'body'),'section'),'section')[0]
                paragraph.append(c.element(c.FB,'a','Text anchor link',**{'{'+c.XL+'}href':'#cover'}))
                c.first(book,'stylesheet').text += '\n.picture {background-image:url("#cover");}'
            source = self.root/(kind+'.fb2'); source.write_bytes(c.serialized(book)); before = digest(source)
            output, restored = self.root/(kind+'.epub'), self.root/(kind+'-back.fb2')
            report = c.convert_book(source, output); self.assertTrue(report['warnings'])
            with zipfile.ZipFile(output) as archive:
                values = [archive.read(n) for n in archive.namelist() if n.startswith('OEBPS/images/')]
                self.assertEqual(Counter(values), Counter(base64.b64decode(c.plain(n)) for n in c.children(book,'binary')))
            c.convert_book(output,restored); self.validate_fb2(restored)
            result = ET.parse(restored).getroot(); c.validate_fb2_output(result)
            self.assertEqual(Counter(base64.b64decode(c.plain(n)) for n in c.children(result,'binary')),
                             Counter(base64.b64decode(c.plain(n)) for n in c.children(book,'binary')))
            identities = [n.get('id') for n in result.iter() if n.get('id')]
            self.assertEqual(len(identities),len(set(identities)))
            if kind=='body-id':
                self.assertIn('cover',identities)
                self.assertTrue(any(n.get('{'+c.XL+'}href')=='#cover' for n in result.iter('{'+c.FB+'}a')))
                for n in result.iter('{'+c.FB+'}image'): self.assertNotEqual(n.get('{'+c.XL+'}href'),'#cover')
            else:
                self.assertTrue(any('первый вариант' in n for n in report['warnings']))
            self.assertEqual(digest(source),before)
    def test_corrupt_source_images_fail_without_output(self):
        book=ET.parse(self.source).getroot(); c.children(book,'binary')[0].text='not base64!'
        source=self.root/'corrupt.fb2';source.write_bytes(c.serialized(book));before=digest(source)
        output=self.root/'corrupt.epub'
        with self.assertRaises(c.ConversionError):c.convert_book(source,output)
        self.assertFalse(output.exists());self.assertEqual(digest(source),before)
    def test_truncated_fb2_image_requires_consent_and_keeps_other_images(self):
        book = ET.parse(self.source).getroot()
        picture_link = '{'+c.XL+'}href'
        cover = next(book.iter('{'+c.FB+'}coverpage'))
        cover[0].set(picture_link, '#broken')
        section = next(n for n in c.first(book, 'body').iter('{'+c.FB+'}section') if n.get('id') == 'one-prose')
        section.append(c.element(c.FB, 'image', **{picture_link: '#broken'}))
        section.append(c.element(c.FB, 'p', 'Text after the broken illustration.'))
        book.append(c.element(c.FB, 'binary', 'YQ', id='broken', **{'content-type': 'image/png'}))
        source = self.root/'truncated.fb2'
        source.write_bytes(c.serialized(book).rsplit(b'</', 2)[0])
        before = digest(source)
        for extension in ('.fb2', '.epub'):
            with self.subTest(extension=extension):
                result = self.root/('recovered'+extension)
                with self.assertRaises(c.FB2ImageRecoveryRequired):
                    c.convert_book(source, result)
                self.assertFalse(result.exists())
                report = c.convert_book(source, result, skip_damaged_fb2_image=True)
                self.assertIn('Повреждённая обложка «broken» пропущена.', report['warnings'])
                if extension == '.fb2':
                    output = c.xml(result.read_bytes())
                    c.validate_fb2_output(output)
                    images = [base64.b64decode(c.plain(n)) for n in c.children(output, 'binary')]
                else:
                    with zipfile.ZipFile(result) as archive:
                        output = c.xml(archive.read('OEBPS/body-1.xhtml'))
                        images = [archive.read(n) for n in archive.namelist() if n.startswith('OEBPS/images/')]
                self.assertEqual(images, [PNG, PNG])
                text = c.plain(output)
                self.assertIn('[Повреждённая обложка пропущена]', text)
                self.assertIn('[Повреждённое изображение пропущено]Text after the broken illustration.', text)
        self.assertEqual(digest(source), before)
        self.assertFalse(list(self.root.glob('homelib-fb2-image-recovery-*')))
    def test_source_title_mixed_text_gets_paragraphs_without_losing_inline_content(self):
        book=ET.parse(self.source).getroot(); title=next(book.iter('{'+c.FB+'}title'))
        title.text='Before '; emphasis=c.element(c.FB,'emphasis','Italic');emphasis.tail=' between '
        title.insert(0,emphasis);title[-1].tail=' trailing text'
        expected=c.plain(title);source=self.root/'mixed-title.fb2';source.write_bytes(c.serialized(book));before=digest(source)
        epub,restored=self.root/'mixed-title.epub',self.root/'mixed-title-back.fb2'
        report=c.convert_book(source,epub);self.assertTrue(any('Текст заголовка' in n for n in report['warnings']))
        c.convert_book(epub,restored);self.validate_fb2(restored)
        result=ET.parse(restored).getroot();c.validate_fb2_output(result)
        actual=next(result.iter('{'+c.FB+'}title'));self.assertEqual(c.plain(actual),expected)
        self.assertTrue(any(c.plain(n)=='Italic' for n in actual.iter('{'+c.FB+'}emphasis')))
        self.assertEqual(digest(source),before)
    def validate_epub(self, path):
        checker, java = os.environ.get('HOMELIB_TEST_EPUBCHECK'), os.environ.get('HOMELIB_TEST_JAVA')
        if checker and java:
            result = subprocess.run([java, '-jar', checker, str(path)], capture_output=True, timeout=30, creationflags=0x08000000)
            self.assertEqual(result.returncode, 0, result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))
    def generic(self, first='<h1 id="chapter">Первая</h1><p>Обычный <strong>жирный</strong> текст <a id="back" epub:type="noteref" href="notes.xhtml#n">6</a>.</p>', second='<aside id="n" epub:type="footnote"><p>6. Текст сноски <a href="chapter.xhtml#back">↩</a></p></aside>', css='', *, notes_in_spine=True, extra_metadata='', head=''):
        path = self.root/'generic.epub'
        package = f'''<package xmlns="{c.OP}" version="3.0" unique-identifier="id"><metadata xmlns:dc="{c.DC}"><dc:title>Проверка EPUB</dc:title><dc:creator>Автор EPUB</dc:creator><dc:language>be</dc:language><dc:identifier id="id">fixture</dc:identifier><meta property="dcterms:modified">2026-10-13T00:00:00Z</meta>{extra_metadata}</metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="n" href="notes.xhtml" media-type="application/xhtml+xml"/><item id="i" href="image.png" media-type="image/png"/><item id="css" href="book.css" media-type="text/css"/></manifest><spine><itemref idref="c"/>{'<itemref idref="n"/>' if notes_in_spine else ''}</spine></package>'''
        container = f'<container xmlns="{c.CN}" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
        with zipfile.ZipFile(path,'w') as z:
            z.writestr('mimetype','application/epub+zip'); z.writestr('META-INF/container.xml',container); z.writestr('OPS/package.opf',package)
            for name, content in [('chapter.xhtml',first),('notes.xhtml',second)]:
                z.writestr('OPS/'+name, f'<html xmlns="{c.XH}" xmlns:epub="{c.EP}"><head><title>Тест</title>{head}</head><body>{content}</body></html>')
            z.writestr('OPS/image.png',PNG); z.writestr('OPS/book.css',css)
        return path
    def test_epub_repairs_empty_namespace_prefix_in_package_and_chapters(self):
        literal = f'xmlns:="{c.XH}"'
        source = self.generic(first=(
            f'<div {literal}><h1 id="a">Первая глава</h1>'
            f'<p title=\'Сохранить {literal} в атрибуте\'><![CDATA[{literal}]]></p>'
            '<p><a href="notes.xhtml#second">Ко второй главе</a></p></div>'),
            second='<h1 id="second">Вторая глава</h1><p><img src="image.png"/></p>')
        with zipfile.ZipFile(source) as archive:
            contents = {name: archive.read(name) for name in archive.namelist()}
        for name, uri in (('OPS/package.opf',c.OP),('OPS/chapter.xhtml',c.XH),('OPS/notes.xhtml',c.XH)):
            contents[name] = contents[name].replace(f'xmlns="{uri}"'.encode(), f'xmlns: = "{uri}"'.encode(), 1)
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in contents.items():
                archive.writestr(name, data)
        before = digest(source)
        output = self.root/'repaired-namespace.fb2'
        result = c.convert_book(source, output)
        self.assertEqual(digest(source), before)
        self.assertIn(c.EPUB_NAMESPACE_REPAIR, result['warnings'])
        self.assertEqual(c.damaged_content_warnings(result['warnings']), [])
        book = c.xml(output.read_bytes())
        paragraphs = list(book.iter('{'+c.FB+'}p'))
        text = ' '.join(c.plain(p) for p in paragraphs)
        self.assertLess(text.index('Первая глава'), text.index('Вторая глава'))
        self.assertIn(literal, text)
        link = next(n for n in book.iter('{'+c.FB+'}a') if c.plain(n) == 'Ко второй главе')
        self.assertTrue(link.get('{'+c.XL+'}href','').startswith('#'))
        self.assertEqual([base64.b64decode(n.text) for n in c.children(book,'binary')], [PNG])
        repaired = self.root/'repaired-namespace.epub'
        result = c.convert_book(source, repaired)
        self.assertIn(c.EPUB_NAMESPACE_REPAIR, result['warnings'])
        with zipfile.ZipFile(repaired) as archive:
            changed = {name for name, data in contents.items() if archive.read(name) != data}
            self.assertEqual(changed, {'OPS/package.opf','OPS/chapter.xhtml','OPS/notes.xhtml'})
            for name in changed:
                ET.fromstring(archive.read(name))
            self.assertIn(literal.encode(), archive.read('OPS/chapter.xhtml'))
        markdown = self.root/'repaired-namespace.md'
        result = c.convert_book(source, markdown, output_profile='md')
        self.assertIn(c.EPUB_NAMESPACE_REPAIR, result['warnings'])
        text = markdown.read_text(encoding='utf-8')
        self.assertLess(text.index('Первая глава'), text.index('Вторая глава'))
        self.assertEqual(digest(source), before)

    def test_epub_namespace_repair_changes_only_real_declarations(self):
        literal = f'xmlns:="{c.XH}"'
        effect = f'<html {literal}>'
        opaque = f'<!-- <div {literal}> --><?sample {literal}?>'
        body = f'{opaque}<p style=\'{literal}\'><![CDATA[<div {literal}>]]></p></html>'
        control = f'<html xmlns="{c.XH}">'+body
        for encoding, bom in (('utf-8',b''),('utf-16-le',b'\xff\xfe'),('utf-16-be',b'\xfe\xff')):
            with self.subTest(encoding=encoding):
                data = bom+(effect+body).encode(encoding)
                self.assertEqual(c.repair_epub_namespace(data),bom+control.encode(encoding))
                warnings = set()
                self.assertEqual(c.xml(data,namespace_warnings=warnings).tag,'{'+c.XH+'}html')
                self.assertEqual(warnings, {c.EPUB_NAMESPACE_REPAIR})
        duplicate = f'<html {literal} xmlns="{c.XH}"/>'.encode()
        with self.assertRaises(c.ConversionError):
            c.xml(duplicate,namespace_warnings=set())
        with self.assertRaises(c.ConversionError):
            c.xml(effect.encode()+b'</html>')

    def test_epub_recovers_html_with_svg_namespace_declarations(self):
        source = self.generic(first=(
            '<p>Первая строка<br>Вторая строка</p>'
            f'<svg xmlns="{c.SVG}" xmlns:xlink="{c.XL}">'
            '<image xlink:href="image.png"/></svg>'), second='<p>Следующая глава</p>')
        output = self.root/'repaired-html-svg.fb2'
        result = c.convert_book(source, output, allow_partial_epub=True)
        self.assertEqual(c.damaged_content_warnings(result['warnings']),
                         ['Исправлена повреждённая разметка главы EPUB «chapter.xhtml».'])
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        paragraphs = list(book.iter(f'{{{c.FB}}}p'))
        self.assertEqual([c.plain(node) for node in paragraphs], ['Первая строка', 'Вторая строка', '', 'Следующая глава'])
        self.assertIsNotNone(paragraphs[2].find(f'.//{{{c.FB}}}image'))
        self.assertEqual(len(list(book.iter(f'{{{c.FB}}}image'))), 1)
        self.assertEqual([base64.b64decode(node.text) for node in c.children(book, 'binary')], [PNG])

    def test_epub_links_to_illustrations_have_readable_fb2_destinations(self):
        source = self.generic(first=(
            '<p><a href="image.png">Иллюстрация в тексте</a> '
            '<a href="image.png">Повтор ссылки</a> '
            '<a href="standalone.png">Отдельная иллюстрация</a></p>'), second=(
            '<p id="figure">Подпись <img src="image.png" alt="Основная иллюстрация"/></p>'
            '<p><img src="image.png" alt="Повтор иллюстрации"/></p>'))
        with zipfile.ZipFile(source, 'a') as package:
            package.writestr('OPS/standalone.png', PNG)
        output = self.root/'picture-links.fb2'
        result = c.convert_book(source, output)
        self.assertFalse(c.damaged_content_warnings(result['warnings']))
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        href = f'{{{c.XL}}}href'
        indexed = {'#' + node.get('id'): node for node in book.iter() if node.get('id')}
        links = {c.plain(node): indexed[node.get(href)] for node in book.iter(f'{{{c.FB}}}a')}
        self.assertIs(links['Иллюстрация в тексте'], links['Повтор ссылки'])
        picture = next(links['Иллюстрация в тексте'].iter(f'{{{c.FB}}}image'))
        self.assertEqual(picture.get('alt'), 'Основная иллюстрация')
        self.assertEqual(c.plain(links['Иллюстрация в тексте']), 'Подпись')
        standalone = next(links['Отдельная иллюстрация'].iter(f'{{{c.FB}}}image'))
        self.assertNotEqual(standalone.get(href), picture.get(href))
        self.assertEqual(len(list(book.iter(f'{{{c.FB}}}image'))), 3)
        for item in (standalone, picture):
            self.assertEqual(base64.b64decode(indexed[item.get(href)].text), PNG)

        spool = self.root/'image-links-spool'
        spool.mkdir()
        streamed = self.root/'image-links-streamed.fb2'
        warnings = set()
        c.epub_to_fb2(source, streamed, warnings, stream_images={}, generated_sections=spool)
        c.validate_streamed_fb2(streamed)
        self.validate_fb2(streamed)
        self.assertFalse(c.damaged_content_warnings(warnings))
        actual = c.xml(streamed.read_bytes())
        self.assertEqual(c.serialized(c.first(actual, 'body')), c.serialized(c.first(book, 'body')))

    def test_epub_css_image_resources_remain_resolvable_after_fb2_export(self):
        source = self.generic(first='<h1>Глава</h1><p class="mark">Текст главы.</p>',
                              notes_in_spine=False,
                              head='<style>.second{background:url("images/tick (on).png")}</style>')
        with zipfile.ZipFile(source) as archive:
            contents = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(contents['OPS/package.opf'])
        style = next(item for item in c.first(package, 'manifest') if item.get('id') == 'css')
        style.set('href', 'Styles/screen.css')
        contents['OPS/package.opf'] = c.serialized(package)
        del contents['OPS/book.css']
        contents['OPS/Styles/screen.css'] = (
            r'.mark{background:url(../images/tick\20 \(on\).png)}'
            r'/* Keep url(inside-comment.png) verbatim. */'
            r'.mark::after{content:"url(inside-string.png)"}')
        contents['OPS/images/tick (on).png'] = PNG
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in contents.items():
                archive.writestr(name, data)
        original = digest(source)
        fb2 = self.root/'styled.fb2'
        report = c.convert_book(source, fb2)
        self.assertEqual(c.damaged_content_warnings(report['warnings']), [])
        book = c.xml(fb2.read_bytes())
        binaries = {node.get('id'): base64.b64decode(node.text) for node in c.children(book, 'binary')}
        stylesheet = c.first(book, 'stylesheet').text
        urls = []
        c.rewrite_css_urls(stylesheet, lambda ref, token: urls.append(ref) or token)
        self.assertEqual(len(urls), 2)
        self.assertEqual(len(set(urls)), 1)
        self.assertTrue(urls[0].startswith('#'))
        self.assertEqual(binaries[urls[0][1:]], PNG)
        self.assertIn('url(inside-comment.png)', stylesheet)
        self.assertIn('content:"url(inside-string.png)"', stylesheet)

        reopened = self.root/'reopened.epub'
        c.convert_book(fb2, reopened, reading=True)
        with zipfile.ZipFile(reopened) as archive:
            stylesheet = archive.read('OEBPS/book.css').decode('utf-8')
            reopened_urls = []
            c.rewrite_css_urls(stylesheet, lambda ref, token: reopened_urls.append(ref) or token)
            self.assertEqual(len(reopened_urls), 2)
            self.assertEqual(reopened_urls[0], reopened_urls[1])
            self.assertEqual(archive.read('OEBPS/'+reopened_urls[0]), PNG)
        text_only = self.root/'text-only-styled.fb2'
        c.convert_book(reopened, text_only, image_quality='none')
        self.assertFalse(c.children(c.xml(text_only.read_bytes()), 'binary'))
        c.convert_book(text_only, self.root/'text-only-styled.epub', reading=True)
        self.assertEqual(digest(source), original)

    def test_epub_preserves_css_list_images_and_author_numbering(self):
        source = self.generic(
            first='<ul class="checks"><li>Checked item</li><li class="quiet">Unmarked item</li>'
                  '<li style="list-style-image:none">Fallback glyph</li></ul>'
                  '<ol class="letters" start="26"><li>Letter Z</li><li>Letter AA</li></ol>',
            second='<ul class="checks"><li>Default elsewhere</li></ul>',
            head='<link rel="stylesheet" href="Styles/list.css"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(b'href="book.css"', b'href="Styles/list.css"')
        entries['OPS/notes.xhtml'] = entries['OPS/notes.xhtml'].replace(
            b'<link rel="stylesheet" href="Styles/list.css"/>', b'')
        entries['OPS/Styles/list.css'] = (b'ul.checks {list-style: square url("../image.png") inside}'
                                         b'li.quiet {list-style:none !important}'
                                         b'ol.letters {list-style-type:upper-latin}'
                                         b'@media print {ul.checks {list-style:none}}')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        output = self.root/'list-markers.fb2'
        result = c.convert_book(source, output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        paragraphs = {c.plain(node):node for node in book.iter(f'{{{c.FB}}}p')}
        checked = paragraphs['Checked item']
        marker = checked.find(f'{{{c.FB}}}style')
        self.assertEqual(marker.get('name'),c.EPUB_LIST_MARKER_STYLE)
        ref = c.first(marker,'image').get(f'{{{c.XL}}}href')
        binary = next(node for node in c.children(book,'binary') if node.get('id')==ref[1:])
        self.assertEqual(base64.b64decode(binary.text),PNG)
        self.assertEqual(len(list(book.iter(f'{{{c.FB}}}image'))),1)
        for label in ('Unmarked item','▪ Fallback glyph','Z. Letter Z','AA. Letter AA','• Default elsewhere'):
            self.assertIn(label,paragraphs)
        self.assertFalse(c.damaged_content_warnings(result['warnings']))

    def test_epub_css_missing_image_is_reported_before_partial_export(self):
        source = self.generic(first='<p class="mark">Книга без значка.</p>', notes_in_spine=False,
                              css='.mark{background: red url(icons/absent.png)}')
        output = self.root/'partial-styled.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'icons/absent.png'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        report = c.convert_book(source, output, allow_partial_epub=True)
        self.assertIn('Ресурс оформления EPUB не перенесён: «icons/absent.png». Таблица стилей «book.css».',
                      c.damaged_content_warnings(report['warnings']))
        book = c.xml(output.read_bytes())
        self.assertIn('background: red none', c.first(book, 'stylesheet').text)
        self.assertIn('Книга без значка.', c.plain(c.first(book, 'body')))

    def test_epub_reports_binary_stylesheet_and_preserves_readable_styles(self):
        source = self.generic(first='<p class="mark">Styled paragraph</p>',
                              css='.mark{font-weight:bold}',
                              head='<link rel="stylesheet" href="bad.css"/>')
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(files['OPS/package.opf'])
        c.first(package, 'manifest').append(c.element(c.OP, 'item', id='bad-style', href='bad.css',
                                                       **{'media-type': 'text/css'}))
        files['OPS/package.opf'] = c.serialized(package)
        files['OPS/bad.css'] = b'\x03=\x00\xff'
        files['OPS/book.css'] = '.mark{font-weight:bold}\fp{font-style:italic}'.encode('utf-16')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        before = digest(source)
        output = self.root / 'readable-style.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'bad.css.*подтверждение'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        report = c.convert_book(source, output, allow_partial_epub=True)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        self.assertEqual(c.first(book, 'stylesheet').text,
                         '.mark{font-weight:bold}\np{font-style:italic}')
        bold = next(c.first(book, 'body').iter('{' + c.FB + '}strong'))
        self.assertEqual(c.plain(bold), 'Styled paragraph')
        warnings = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any('Таблица стилей EPUB недоступна' in w and 'bad.css' in w for w in warnings))
        self.assertEqual(digest(source), before)

    def test_epub_reports_shared_missing_decoration_once_across_chapters(self):
        source = self.generic(
            first='<p class="mark">Первый раздел.</p>',
            second='<p class="mark">Второй раздел.</p>',
            css='.mark{background:url(icons/shared.png)}.single{background:url(icons/single.png)}',
            head='<style>.mark{background:url(./icons/shared.png)}</style>')
        output = self.root / 'shared-decoration.fb2'
        with self.assertRaises(c.ConversionError):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        report = c.convert_book(source, output, allow_partial_epub=True)
        notices = [warning for warning in c.damaged_content_warnings(report['warnings'])
                   if warning.startswith('Ресурс оформления EPUB')]
        self.assertEqual(len(notices), 2)
        shared, = [warning for warning in notices if 'shared.png' in warning]
        single, = [warning for warning in notices if 'single.png' in warning]
        self.assertIn('Число файлов — 3.', shared)
        self.assertNotIn('Число файлов', single)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        self.assertIn('Первый раздел.', c.plain(body))
        self.assertIn('Второй раздел.', c.plain(body))
        c.convert_book(output, self.root/'partial-styled.epub', reading=True)

    def test_epub_to_fb2_resolves_the_image_catalogue_once(self):
        names = [f'images/page%20{i}.png' for i in range(64)]
        epub = self.generic(first='<h1>Images</h1>' + ''.join(f'<p><img src="{name}"/></p>' for name in names),
                            notes_in_spine=False)
        with zipfile.ZipFile(epub) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(files['OPS/package.opf'])
        manifest = c.first(package, 'manifest')
        for i, name in enumerate(names):
            manifest.append(c.element(c.OP, 'item', id=f'picture-{i}', href=name, **{'media-type': 'image/png'}))
            files['OPS/'+name.replace('%20', ' ')] = PNG
        manifest.append(c.element(c.OP, 'item', id='alias', href='./'+names[0], **{'media-type': 'application/octet-stream'}))
        files['OPS/package.opf'] = c.serialized(package)
        with zipfile.ZipFile(epub, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)

        before = digest(epub)
        output = self.root/'illustrated.fb2'
        resolve = c.EpubArchive.resolve
        lookups = Counter()
        def counted(archive, current, reference):
            if current == 'OPS/package.opf' and reference in names:
                lookups[reference] += 1
            return resolve(archive, current, reference)
        with mock.patch.object(c.EpubArchive, 'resolve', counted):
            c.convert_book(epub, output)
        self.assertEqual(lookups, Counter(names))
        book = ET.parse(output).getroot()
        images = c.children(book, 'binary')
        self.assertEqual(len(images), len(names) + 1)  # Keep the unused fixture image too.
        self.assertTrue(all(image.get('content-type') == 'image/png' and
                            base64.b64decode(c.plain(image)) == PNG for image in images))
        refs = [image.get('{'+c.XL+'}href') for image in book.iter('{'+c.FB+'}image')]
        self.assertEqual(refs, ['#'+image.get('id') for image in images[:-1]])
        self.assertEqual(digest(epub), before)

    def test_fb2_cover_is_readable_in_epub_and_round_trips_without_an_extra_image(self):
        epub = self.root / 'with-cover.epub'
        restored = self.root / 'restored.fb2'
        c.convert_book(self.source, epub)

        with zipfile.ZipFile(epub) as archive:
            package = c.xml(archive.read('OEBPS/package.opf'))
            manifest = {n.get('id'): n for n in c.first(package, 'manifest')}
            order = [manifest[n.get('idref')].get('href') for n in c.first(package, 'spine')]
            self.assertEqual(order[:2], ['cover.xhtml', 'body-1.xhtml'])
            cover = c.first(c.xml(archive.read('OEBPS/cover.xhtml')), 'body')
            self.assertEqual(cover.get('{' + c.EP + '}type'), 'cover')
            self.assertEqual(c.plain(cover), '')
            image = c.first(cover, 'img')
            cover_resource = next(n for n in manifest.values() if n.get('properties') == 'cover-image')
            self.assertEqual(cover_resource.get('href'), image.get('src'))
            self.assertEqual(archive.read('OEBPS/' + image.get('src')), PNG)
            body = c.xml(archive.read('OEBPS/body-1.xhtml'))
            self.assertEqual([n.get('src') for n in body.iter('{' + c.XH + '}img')], [image.get('src')])
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            self.assertFalse(any(n.get('href', '').startswith('cover.xhtml') for n in nav.iter()))

        self.assertEqual(c.convert_book(epub, restored)['warnings'], [])
        book = c.xml(restored.read_bytes())
        original = c.xml(self.source.read_bytes())
        self.assertEqual(shape(c.first(book, 'description')), shape(c.first(original, 'description')))
        self.assertEqual([shape(n) for n in c.children(book, 'body')],
                         [shape(n) for n in c.children(original, 'body')])
        self.assertEqual([base64.b64decode(n.text) for n in c.children(book, 'binary')], [PNG, PNG])

    def test_edited_or_linked_fb2_cover_page_is_kept_when_exporting_back_from_epub(self):
        epub = self.root / 'with-cover.epub'
        c.convert_book(self.source, epub)
        for case, entry in (('edited', 'cover.xhtml'), ('linked', 'body-1.xhtml')):
            with self.subTest(case=case):
                copy = self.root / (case + '.epub')
                with zipfile.ZipFile(epub) as archive, zipfile.ZipFile(copy, 'w') as destination:
                    for name in archive.namelist():
                        data = archive.read(name)
                        if name == 'OEBPS/' + entry:
                            html = c.xml(data)
                            if case == 'edited':
                                c.first(html, 'body').append(c.element(c.XH, 'p', 'Подпись к обложке'))
                            else:
                                paragraph = html.find('.//{' + c.XH + '}p')
                                paragraph.append(c.element(c.XH, 'a', 'К обложке', href='cover.xhtml'))
                            data = c.serialized(html)
                        destination.writestr(name, data)

                converted = self.root / (case + '.fb2')
                c.convert_book(copy, converted)
                book = c.xml(converted.read_bytes())
                first_section = c.first(c.first(book, 'body'), 'section')
                self.assertIsNotNone(next(first_section.iter('{' + c.FB + '}image'), None))
                if case == 'edited':
                    self.assertIn('Подпись к обложке', c.plain(first_section))
                else:
                    link = next(n for n in book.iter('{' + c.FB + '}a') if c.plain(n) == 'К обложке')
                    self.assertEqual(link.get('{' + c.XL + '}href'), '#' + first_section.get('id'))

    def test_fb2_explicit_body_and_poem_titles_keep_epub_navigation_targets(self):
        source = self.root / 'titles.fb2'
        source.write_text(self.source.read_text('utf-8').replace(
            '<body><section id="one">', '<body><title><p>Заголовок тома</p></title><section id="one">'
        ).replace('<poem><stanza>', '<poem><title><p>Название стихотворения</p></title><stanza>'), 'utf-8')
        output = self.root / 'titles.epub'
        c.convert_book(source, output)
        with zipfile.ZipFile(output) as archive:
            nav = c.xml(archive.read('OEBPS/nav.xhtml')).find('.//{' + c.XH + '}nav')
            links = list(nav.iter('{' + c.XH + '}a'))
            self.assertEqual([c.plain(link) for link in links],
                             ['Заголовок тома', 'Первая глава', 'Подглава', 'Название стихотворения',
                              'Вторая глава', '6'])
            for link in links:
                filename, identity = link.get('href').split('#')
                document = c.xml(archive.read('OEBPS/' + filename))
                node = next(n for n in document.iter() if n.get('id') == identity)
                header = node if c.tag(node) == 'header' else c.first(node, 'header')
                self.assertEqual(c.plain(header), c.plain(link))
        restored = self.root / 'roundtrip-titles.fb2'
        c.convert_book(output, restored)
        self.assertEqual([shape(n) for n in c.children(c.xml(source.read_bytes()), 'body')],
                         [shape(n) for n in c.children(c.xml(restored.read_bytes()), 'body')])

    def test_rich_round_trip(self):
        self.validate_fb2(self.source)
        epub, fb2 = self.root/'result.epub', self.root/'result.fb2'
        c.convert_book(self.source, epub); self.validate_epub(epub)
        result = c.convert_book(epub, fb2); self.assertEqual(result['warnings'], [])
        self.validate_fb2(fb2)
        before, after = ET.parse(self.source).getroot(), ET.parse(fb2).getroot()
        self.assertEqual(shape(c.first(before,'description')), shape(c.first(after,'description')))
        self.assertEqual([shape(b) for b in c.children(before,'body')], [shape(b) for b in c.children(after,'body')])
        self.assertEqual([shape(b) for b in c.children(before,'stylesheet')], [shape(b) for b in c.children(after,'stylesheet')])
        self.assertEqual({b.get('id'):base64.b64decode(c.plain(b)) for b in c.children(after,'binary')}, {'cover':PNG,'unused':PNG})
        with zipfile.ZipFile(epub) as z:
            self.assertEqual(z.infolist()[0].filename,'mimetype'); self.assertEqual(z.infolist()[0].compress_type,zipfile.ZIP_STORED)
            nav=ET.fromstring(z.read('OEBPS/nav.xhtml')); toc=next(n for n in nav.iter() if c.tag(n)=='nav'); ol=c.first(toc,'ol')
            self.assertEqual([c.plain(c.first(li,'a')) for li in ol], ['Первая глава','Вторая глава','6'])
            self.assertEqual(c.plain(c.first(c.first(ol[0],'ol')[0],'a')), 'Подглава')
    def test_nested_tables_keep_text_images_and_anchor_targets_with_warning(self):
        epub = self.generic(first='''<h1 id="back">Nested layout</h1>
          <table id="outer"><tr id="row"><td id="cell">OuterBefore
          <table id="inner"><tr><td><strong>InnerWords</strong><img src="image.png"/></td></tr></table>
          OuterAfter</td><td>NextCell</td></tr></table>
          <p><a href="#outer">outer</a> / <a href="#row">row</a> /
          <a href="#cell">cell</a> / <a href="#inner">inner</a></p>''')
        before = digest(epub); output = self.root/'nested.fb2'
        report = c.convert_book(epub, output); self.validate_fb2(output)
        book = ET.parse(output).getroot(); body = c.first(book, 'body'); text = ''.join(body.itertext())
        words = ['OuterBefore', 'InnerWords', 'OuterAfter', 'NextCell']
        self.assertEqual([text.count(word) for word in words], [1]*len(words))
        self.assertEqual([text.index(word) for word in words], sorted(text.index(word) for word in words))
        ids = {n.get('id') for n in book.iter() if n.get('id')}
        targets = {c.plain(link): link.get('{'+c.XL+'}href').removeprefix('#') for link in book.iter('{'+c.FB+'}a')}
        self.assertLessEqual(set(targets.values()), ids)
        table, = body.iter('{' + c.FB + '}table')
        row, = table
        left, right = row
        self.assertEqual(table.get('id'), targets['outer'])
        self.assertEqual(left.get('id'), targets['row'])
        self.assertEqual(left.get('id'), targets['cell'])
        self.assertEqual(left.get('id'), targets['inner'])
        self.assertEqual(c.plain(right), 'NextCell')
        self.assertEqual(len(list(left.iter('{' + c.FB + '}image'))), 1)
        self.assertTrue(any(base64.b64decode(c.plain(n)) == PNG for n in c.children(book, 'binary')))
        self.assertTrue(any(warning.startswith('Вложенные таблицы развёрнуты внутри ячеек FB2')
                            and warning.endswith('выберите EPUB.')
                            for warning in c.damaged_content_warnings(report['warnings'])))
        self.assertEqual(digest(epub), before)

    def test_nonstandard_table_keeps_quotation_order_and_link(self):
        epub = self.generic(first='''<table id="table"><tr><td>First cell</td></tr>
          <blockquote id="quote"><p>Quoted paragraph</p></blockquote>
          <tr><td>Last cell</td></tr></table><p><a href="#quote">Quotation</a></p>''', second='<p>End</p>')
        output = self.root/'table-quotation.fb2'
        report = c.convert_book(epub, output)
        self.validate_fb2(output)
        root = ET.parse(output).getroot()
        text = ''.join(c.first(root, 'body').itertext())
        self.assertLess(text.index('First cell'), text.index('Quoted paragraph'))
        self.assertLess(text.index('Quoted paragraph'), text.index('Last cell'))
        self.assertTrue(any('Нестандартные таблицы' in warning for warning in report['warnings']))

    def test_table_paragraph_anchor_is_kept_on_the_cell(self):
        epub = self.generic(first='''<table><tr><td><p>Some text <sup id="return-here">21</sup></p></td></tr></table>
            <p><a href="#return-here">Return to the table</a></p>''', second='<p>End</p>')
        output = self.root / 'table-link.fb2'
        c.convert_book(epub, output)
        self.validate_fb2(output)
        root = ET.parse(output).getroot()
        cell = next(root.iter('{' + c.FB + '}td'))
        link = next(node for node in root.iter('{' + c.FB + '}a') if c.plain(node) == 'Return to the table')
        self.assertIsNotNone(cell.get('id'))
        self.assertEqual(link.get('{' + c.XL + '}href'), '#' + cell.get('id'))

    def test_table_cell_breaks_survive_fb2_epub_roundtrip(self):
        source = self.generic(first='''<table><tr><td align="right"><p>First
           <strong>value</strong><br/><br/>Second value</p><p>Third value</p></td>
           <td>Ordinary
           value</td></tr></table>''', notes_in_spine=False)
        fb2, epub = self.root / 'cell-lines.fb2', self.root / 'cell-lines.epub'
        c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        cell, ordinary = ET.parse(fb2).getroot().iter('{' + c.FB + '}td')
        self.assertEqual(c.plain(cell).rstrip(), 'First value\n\nSecond value\nThird value')
        self.assertEqual(cell.get('style'), c.FB2_TABLE_LINE_STYLE)
        self.assertEqual(c.plain(ordinary), 'Ordinary value')
        self.assertIsNone(ordinary.get('style'))

        c.convert_book(fb2, epub)
        self.validate_epub(epub)
        with zipfile.ZipFile(epub) as archive:
            recovered, ordinary = [td for path in archive.namelist() if path.endswith('.xhtml')
                                   for td in c.xml(archive.read(path)).iter('{' + c.XH + '}td')]
            self.assertEqual(c.plain(recovered), c.plain(cell))
            self.assertEqual(recovered.get('style'), 'text-align:right;' + c.FB2_TABLE_LINE_STYLE)
            self.assertIsNone(ordinary.get('style'))

    def test_picture_placement_sizes_survive_fb2_and_roundtrip_to_epub(self):
        source = self.generic(first='''<h1 id="target">Illustrations</h1>
            <p><img src="image.png" width="44" height="9"/></p>
            <p><a href="#target"><img src="image.png" width="40"/></a></p>
            <p><a href="#target">Label <img src="image.png" height="7"/></a></p>''', notes_in_spine=False)
        fb2 = self.root / 'picture-placements.fb2'
        report = c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        book = ET.parse(fb2).getroot()
        extents = [style for style in book.iter('{' + c.FB + '}style') if any(c.fb2_image_size(style.get('name', '')))]
        self.assertEqual([c.fb2_image_size(style.get('name')) for style in extents], [(44, 9), (40, 0)])
        self.assertEqual(c.tag(extents[1][0]), 'a')
        self.assertEqual(len(list(book.iter('{' + c.FB + '}image'))), 3)
        self.assertIn(PNG, [base64.b64decode(binary.text) for binary in c.children(book, 'binary')])
        damage = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any('внутри составных ссылок не перенесены' in message for message in damage))
        self.assertTrue(any('сохранены в FB2 для HomeLibre Reader (2)' in message
                            and message.endswith('выберите EPUB.') for message in damage))

        epub = self.root / 'picture-placements.epub'
        c.convert_book(fb2, epub)
        self.validate_epub(epub)
        with zipfile.ZipFile(epub) as archive:
            pictures = [image for path in archive.namelist() if path.endswith('.xhtml')
                        for image in c.xml(archive.read(path)).iter('{' + c.XH + '}img')]
        self.assertEqual([(image.get('width'), image.get('height')) for image in pictures],
                         [('44', '9'), ('40', None), (None, None)])
        self.assertEqual([image.get('style') for image in pictures], ['aspect-ratio:44/9', None, None])

    def test_fb2_recovers_complete_and_incomplete_baseline_jpeg_separately(self):
        def segment(marker, payload):
            return b'\xff'+bytes([marker])+struct.pack('>H',len(payload)+2)+payload

        def header(rows):
            frame = b'\x08'+struct.pack('>HH',rows,8)+b'\x01\x01\x11\x00'
            codes = b'\x01'+bytes(16)
            return (b'\xff\xd8'+segment(0xc0,frame)+segment(0xdb,b'\0'+bytes([1])*64)+
                    segment(0xc4,b'\0'+codes+b'\x10'+codes)+segment(0xda,b'\x01\x01\0\0\x3f\0'))

        # Each 8x8 block has a zero DC difference and an AC end symbol, two zero bits total.
        healthy = header(40)+b'\0\x3f\xff\xd9'
        shortened = header(40)+b'\0'
        expected_partial = header(32)+b'\0\xff\xd9'
        invalid_scan_marker = header(40)+b'\0\xff\x85\xff\xd9'
        repaired, notice = c.recover_book_jpeg(invalid_scan_marker, set(), 'damaged.jpg')
        self.assertEqual(repaired, expected_partial)
        self.assertIn('32 из 40', notice)
        self.assertEqual(c.recover_book_jpeg(healthy, set()), (healthy, ''))
        data = {'complete.jpg':healthy[:-1], 'partial.jpg':shortened,
                'unreadable.jpg':header(40), 'healthy.png':PNG}
        def canceled():
            raise c.ConversionError('JPEG canceled')
        with self.assertRaisesRegex(c.ConversionError, 'JPEG canceled'):
            c.recover_book_jpeg(shortened, set(), check=canceled)
        book = c.element(c.FB,'FictionBook')
        title = c.element(c.FB,'title-info')
        title.extend([c.element(c.FB,'book-title','Рисунки JPEG'),c.element(c.FB,'lang','ru')])
        cover = c.element(c.FB,'coverpage')
        cover.append(c.element(c.FB,'image',**{'{'+c.XL+'}href':'#partial.jpg'}))
        title.insert(1,cover)
        description = c.element(c.FB,'description')
        description.append(title)
        book.append(description)
        body = c.element(c.FB,'body')
        section = c.element(c.FB,'section')
        body.append(section)
        book.append(body)
        section.append(c.element(c.FB,'p','Текст до рисунков.'))
        for name,payload in data.items():
            section.append(c.element(c.FB,'image', **{'{'+c.XL+'}href':'#'+name}))
            book.append(c.element(c.FB,'binary',base64.b64encode(payload).decode('ascii'),id=name,
                                  **{'content-type':'image/jpeg' if name.endswith('.jpg') else 'image/png'}))
        section.append(c.element(c.FB,'p','Текст после рисунков.'))
        source = self.root/'jpeg-recovery.fb2'
        source.write_bytes(c.serialized(book))
        source_hash = digest(source)
        output = self.root/'jpeg-recovery.epub'
        report = c.convert_book(source,output)
        self.assertEqual(digest(source),source_hash)
        self.assertIn('Восстановлены конечные маркеры JPEG с полными данными изображения.',report['warnings'])
        losses = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any('partial.jpg' in warning and '32 из 40' in warning for warning in losses))
        self.assertTrue(any('unreadable.jpg' in warning for warning in losses))
        self.assertFalse(any('complete.jpg' in warning for warning in losses))
        with zipfile.ZipFile(output) as archive:
            images = [archive.read(name) for name in archive.namelist() if name.startswith('OEBPS/images/')]
            self.assertEqual(images,[healthy,expected_partial,PNG])
            cover = c.xml(archive.read('OEBPS/cover.xhtml'))
            self.assertIn('Сохранены верхние 32 из 40 строк.',c.plain(cover))
            xhtml = c.xml(archive.read('OEBPS/body-1.xhtml'))
            self.assertIn('Сохранены верхние 32 из 40 строк.',c.plain(xhtml))
            self.assertIn('[Повреждённое изображение JPEG пропущено]',c.plain(xhtml))
            self.assertLess(c.plain(xhtml).index('Текст до рисунков.'),c.plain(xhtml).index('Текст после рисунков.'))

    def test_epub_keeps_verified_restart_rows_and_progressive_scans_in_fb2(self):
        def marker(code, payload):
            return b'\xff'+bytes([code])+struct.pack('>H',len(payload)+2)+payload

        def header(sof, rows):
            codes = b'\x01'+bytes(16)
            return (b'\xff\xd8'+marker(sof,b'\x08'+struct.pack('>HH',rows,8)+b'\x01\x01\x11\x00')+
                    marker(0xdb,b'\0'+bytes([1])*64)+marker(0xc4,b'\0'+codes+b'\x10'+codes))

        def scan(first, last):
            return marker(0xda, b'\x01\x01\x00'+bytes([first,last,0]))

        dri = marker(0xdd, b'\x00\x01')
        restart = header(0xc0,40) + dri + scan(0,63) + b'\x3f\xff\xd0\x3f\xff\xd1' + bytes(20)
        expected_restart = header(0xc0,16) + dri + scan(0,63) + b'\x3f\xff\xd0\x3f\xff\xd9'
        preview = header(0xc2,8) + scan(0,0) + b'\x7f' + scan(1,5) + b'\x7f'
        progressive = preview + scan(6,63)
        source = self.generic(first='<p><img src="restart.jpg" width="8" height="40"/></p>'
                                     '<p><img src="preview.jpg"/><img src="missing.jpg"/></p>')
        with zipfile.ZipFile(source, 'a') as archive:
            archive.writestr('OPS/restart.jpg',restart)
            archive.writestr('OPS/preview.jpg',progressive)
        before = digest(source)
        output = self.root/'recovered-jpegs.fb2'
        warnings = set()
        c.epub_to_fb2(source, output, warnings, stream_images={})
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        self.assertEqual([base64.b64decode(c.plain(n)) for n in c.children(book,'binary')],
                         [expected_restart,preview+b'\xff\xd9',PNG])
        body = c.plain(c.first(book,'body'))
        self.assertIn('16 из 40 строк',body)
        self.assertIn('Полных проходов: 2',body)
        self.assertIn('missing.jpg',body)
        self.assertFalse(any(c.fb2_image_has_layout(n.get('name','')) for n in book.iter()))
        losses = c.damaged_content_warnings(warnings)
        self.assertTrue(any('restart.jpg' in w and '16 из 40' in w for w in losses))
        self.assertTrue(any('preview.jpg' in w and 'Полных проходов: 2' in w for w in losses))
        self.assertEqual(digest(source),before)

        whole_progressive = header(0xc2,8) + scan(0,0) + b'\x7f' + scan(1,63) + b'\x7f'
        full_warnings = set()
        self.assertEqual(c.recover_book_jpeg(whole_progressive,full_warnings), (whole_progressive+b'\xff\xd9',''))
        self.assertEqual(c.damaged_content_warnings(full_warnings),[])

        def canceled():
            raise c.ConversionError('Progressive JPEG canceled')
        with self.assertRaisesRegex(c.ConversionError,'Progressive JPEG canceled'):
            c.recover_book_jpeg(progressive,set(),check=canceled)

    def test_jpeg_intrinsic_size_does_not_add_an_fb2_layout_warning(self):
        def segment(marker, payload):
            return b'\xff' + bytes([marker]) + struct.pack('>H', len(payload) + 2) + payload

        frame = segment(0xc0, b'\x08\x00\x03\x00\x05\x01\x01\x11\0')
        huffman_codes = b'\x01' + bytes(16)
        jpeg = (b'\xff\xd8' + segment(0xfe, b'Comment with a marker: \xff\xc0') + frame
                + segment(0xdb, b'\0' + bytes([1]) * 64)
                + segment(0xc4, b'\0' + huffman_codes + b'\x10' + huffman_codes)
                + segment(0xda, b'\x01\x01\0\0\x3f\0') + b'\x3f\xff\xd9')
        self.assertEqual(c.raster_header_size(jpeg), (5, 3))
        self.assertEqual(c.raster_header_size(b'\xff\xd8' + frame[:-1]), (0, 0))
        for endian, order in (('<', b'II'), ('>', b'MM')):
            for orientation, size in ((1, (5, 3)), (3, (5, 3)), (6, (0, 0))):
                with self.subTest(endian=endian, orientation=orientation):
                    exif_header = (b'Exif\0\0' + order + struct.pack(endian + 'HIHHHIHHI',
                                   42, 8, 1, 0x0112, 3, 1, orientation, 0, 0))
                    exif = segment(0xe1, exif_header)
                    self.assertEqual(c.raster_header_size(jpeg[:2] + exif + jpeg[2:]), size)
        malformed_exif = segment(0xe1, b'Exif\0\0II*\0\x08\0\0\0')
        self.assertEqual(c.raster_header_size(jpeg[:2] + malformed_exif + jpeg[2:]), (0, 0))

        source = self.generic(first='''<h1>JPEG layout</h1>
            <p><img src="image.jpg" width="5" height="3"/></p>
            <p><img src="image.jpg" width="5"/></p>
            <p><img src="image.jpg" width="7" height="3"/></p>''', notes_in_spine=False)
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/package.opf'] = files['OPS/package.opf'].replace(b'image.png', b'image.jpg').replace(b'image/png', b'image/jpeg')
        del files['OPS/image.png']
        files['OPS/image.jpg'] = jpeg
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)

        output = self.root / 'jpeg-placement.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        root = c.xml(output.read_bytes())
        sizes = [c.fb2_image_size(node.get('name', '')) for node in root.iter('{' + c.FB + '}style')]
        self.assertEqual([size for size in sizes if any(size)], [(7, 3)])
        self.assertEqual(len(list(root.iter('{' + c.FB + '}image'))), 3)
        self.assertEqual(base64.b64decode(c.first(root, 'binary').text), jpeg)
        damage = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any('сохранены в FB2 для HomeLibre Reader (1)' in message for message in damage))

    def test_table_caption_headings_and_empty_tables_keep_fb2_valid(self):
        epub = self.generic(first='''<h1>Chapter</h1><p>Intro text</p>
            <table id="empty"><tbody/></table>
            <table><caption><h2 id="results">Results</h2></caption>
                <tbody><tr/><tr><td>Result cell</td></tr></tbody></table>
            <p><a href="#empty">Empty table link</a> <a href="#results">Results link</a></p>''',
            notes_in_spine=False)
        output = self.root / 'table-caption.fb2'
        report = c.convert_book(epub, output)
        self.validate_fb2(output)
        self.assertTrue(any(w.startswith('Таблицы без строк заменены пустыми абзацами при сохранении в FB2')
                            for w in c.damaged_content_warnings(report['warnings'])))
        book = ET.parse(output).getroot()
        body = c.first(book, 'body')
        text = ''.join(body.itertext())
        self.assertLess(text.index('Intro text'), text.index('Results'))
        self.assertLess(text.index('Results'), text.index('Result cell'))
        table, = body.iter('{' + c.FB + '}table')
        self.assertEqual([c.plain(row) for row in table], ['', 'Result cell'])
        links = {c.plain(link): link.get('{' + c.XL + '}href', '').removeprefix('#')
                 for link in body.iter('{' + c.FB + '}a')}
        anchors = {node.get('id'): node for node in body.iter() if node.get('id')}
        self.assertEqual(c.plain(anchors[links['Empty table link']]), '')
        self.assertEqual(c.plain(anchors[links['Results link']]), 'Results')

    def test_epub_table_spans_preserve_merged_cells_and_repair_invalid_attributes(self):
        source = self.generic(first='''<table>
            <thead><tr><th colspan="NaN">Heading</th><th colspan="0">Value</th></tr></thead>
            <tbody><tr><td rowspan="0">Group</td><td colspan=" +02suffix">Merged</td></tr>
                <tr><td rowspan="-4">First</td><td rowspan="">Second</td></tr></tbody>
            <tbody><tr><td rowspan="0">Separate group</td><td>Other</td></tr></tbody>
            <tfoot><tr><td colspan="2">Footer</td></tr></tfoot>
            </table><table><tr><td colspan="''' + '9' * 5000 + '''">Wide</td></tr></table>''',
            notes_in_spine=False)
        original = digest(source)
        fb2 = self.root / 'table-spans.fb2'
        result = c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        self.assertEqual(c.damaged_content_warnings(result['warnings']), [])
        self.assertEqual(sum('Недопустимые размеры объединения' in warning for warning in result['warnings']), 1)
        book = c.xml(fb2.read_bytes())
        tables = list(book.iter('{' + c.FB + '}table'))
        self.assertEqual([len(table) for table in tables], [5, 1])
        cells = [cell for table in tables for row in table for cell in row]
        self.assertEqual([(c.plain(cell), cell.get('colspan'), cell.get('rowspan')) for cell in cells], [
            ('Heading', None, None), ('Value', None, None), ('Group', None, '2'), ('Merged', '2', None),
            ('First', None, None), ('Second', None, None), ('Separate group', None, '1'),
            ('Other', None, None), ('Footer', '2', None), ('Wide', '1000', None),
        ])
        self.assertEqual(digest(source), original)

    def test_table_headings_keep_separate_navigation_targets_and_cell_content(self):
        source = self.generic(first='''<h1>Chapter</h1><table><tr><td colspan="2">
            <p>Before</p><h2 id="one">First <em>heading</em></h2><p>Between</p>
            <h2 id="two">Second heading</h2><p>After</p></td></tr></table><h1>Last</h1>''',
            notes_in_spine=False)
        fb2, epub = self.root / 'table-heading.fb2', self.root / 'table-heading.epub'
        result = c.convert_book(source, fb2)
        self.validate_fb2(fb2)
        self.assertTrue(any(message.startswith('Заголовки в ячейках таблиц сохранены')
                            for message in c.damaged_content_warnings(result['warnings'])))
        book = ET.parse(fb2).getroot()
        cell = next(book.iter('{' + c.FB + '}td'))
        labels = ['First heading', 'Second heading']
        markers = c.children(cell, 'style')
        self.assertEqual([c.plain(marker) for marker in markers], labels)
        self.assertTrue(all(marker.get('name') == c.FB2_TABLE_HEADING + '2' for marker in markers))
        self.assertEqual(cell.get('colspan'), '2')
        self.assertEqual(' '.join(c.plain(cell).split()), 'Before First heading Between Second heading After')
        self.assertEqual(c.plain(next(cell.iter('{' + c.FB + '}emphasis'))), 'heading')

        c.convert_book(fb2, epub)
        self.validate_epub(epub)
        with zipfile.ZipFile(epub) as archive:
            nav_path = next(path for path in archive.namelist() if path.endswith('/nav.xhtml'))
            nav = c.xml(archive.read(nav_path))
            links = list(nav.iter('{' + c.XH + '}a'))
            self.assertEqual([c.plain(link) for link in links], ['Chapter', *labels, 'Last'])
            targets = [link.get('href').split('#') for link in links[1:3]]
            self.assertNotEqual(targets[0][1], targets[1][1])
            for (path, fragment), label in zip(targets, labels):
                document = c.xml(archive.read(nav_path.rsplit('/', 1)[0] + '/' + path))
                target = next(node for node in document.iter() if node.get('id') == fragment)
                self.assertEqual((target.get('role'), target.get('aria-level'), c.plain(target)),
                                 ('heading', '2', label))

        recovered = self.root / 'table-heading-recovered.fb2'
        c.convert_book(epub, recovered)
        self.validate_fb2(recovered)
        new_cell = next(ET.parse(recovered).getroot().iter('{' + c.FB + '}td'))
        self.assertEqual(ET.tostring(new_cell), ET.tostring(cell))

    def test_complex_quotation_keeps_headings_links_images_and_text_with_warning(self):
        epub = self.generic(first='''<h1 id="back">Before quote</h1><blockquote id="quote"><div>
          <h2 id="quote-heading">QuotationHeading</h2><p>QuotationWords <strong>BoldWords</strong>
          <img src="image.png"/><a href="#quote-heading">return</a></p>
          <blockquote><p>InnerQuotation</p></blockquote></div></blockquote><p>AfterQuotation</p>''')
        output = self.root/'quote.fb2'; report = c.convert_book(epub, output); self.validate_fb2(output)
        book = ET.parse(output).getroot(); text = ''.join(c.first(book,'body').itertext())
        for word in ['QuotationHeading','QuotationWords','BoldWords','InnerQuotation','AfterQuotation']:
            self.assertEqual(text.count(word), 1)
        ids = {n.get('id') for n in book.iter() if n.get('id')}
        for link in book.iter('{'+c.FB+'}a'):
            self.assertIn(link.get('{'+c.XL+'}href').removeprefix('#'), ids)
        self.assertTrue(any(base64.b64decode(c.plain(n)) == PNG for n in c.children(book,'binary')))
        self.assertTrue(any('Сложная цитата' in warning for warning in report['warnings']))

    def test_generic_links_notes_and_metadata(self):
        epub=self.generic(); before=digest(epub); fb2=self.root/'generic.fb2'; c.convert_book(epub,fb2)
        self.validate_fb2(fb2); self.assertEqual(digest(epub),before)
        book=ET.parse(fb2).getroot(); ti=c.first(c.first(book,'description'),'title-info')
        self.assertEqual(c.plain(c.first(ti,'book-title')),'Проверка EPUB'); self.assertEqual(c.plain(c.first(ti,'lang')),'be')
        ids={n.get('id') for n in book.iter() if n.get('id')}
        for link in book.iter('{'+c.FB+'}a'): self.assertIn(link.get('{'+c.XL+'}href','')[1:],ids)
        notes=[n for n in c.children(book,'body') if n.get('name')=='notes']; self.assertEqual(len(notes),1); self.assertIn('Текст сноски',c.plain(notes[0]))

    def epub_with_fragment_manifest_entries(self, defect=''):
        source = self.generic(
            '<p><a href="Images/notes.xhtml#one">First diagram</a></p>'
            '<p><a href="Images/notes.xhtml#two">Second diagram</a></p>',
            '<p><a id="one"><img src="image.png" alt="First"/></a></p>'
            '<p id="two"><img src="other.png" alt="Second"/></p>'
            + ('<p id="two">Ambiguous destination</p>' if defect == 'ambiguous' else ''),
            notes_in_spine=False)
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        if defect == 'spine':
            entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
                b'</spine>', b'<itemref idref="copy"/></spine>')
        elif defect == 'real-resource':
            entries['OPS/Images/notes.xhtml'] = entries['OPS/notes.xhtml']
        elif defect == 'missing':
            entries['OPS/notes.xhtml'] = entries['OPS/notes.xhtml'].replace(b'id="two"', b'id="other"')
        records = '<item id="other" href="other.png" media-type="image/png"/>'
        for marker in ('one', 'two'):
            href = f'Images/notes.xhtml#{marker}'
            records += f'<item id="copy" href="{href}" media-type="image/xhtml#{marker}"/>'
            entries['OPS/' + href] = f'<!doctype html><p id="{marker}">Saved web page</p>'.encode()
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(b'</manifest>', records.encode() + b'</manifest>')
        entries['OPS/other.png'] = (PNG[:33] + png_chunk(b'IDAT', zlib.compress(b'\0\xff\x34\x56\xff'))
                                   + png_chunk(b'IEND', b''))
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        return source, (entries['OPS/image.png'], entries['OPS/other.png'])

    def test_epub_resolves_duplicate_fragment_records_to_declared_gallery(self):
        source, images = self.epub_with_fragment_manifest_entries()
        before = digest(source)
        output = self.root / 'gallery.fb2'
        result = c.convert_book(source, output)
        self.assertEqual(digest(source), before)
        self.assertFalse(c.damaged_content_warnings(result['warnings']))
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        href = '{' + c.XL + '}href'
        anchors = {node.get('id'): node for node in book.iter() if node.get('id')}
        links = list(book.iter('{' + c.FB + '}a'))
        self.assertEqual([c.plain(link) for link in links], ['First diagram', 'Second diagram'])
        self.assertNotEqual(links[0].get(href), links[1].get(href))
        self.assertEqual(Counter(base64.b64decode(c.plain(node)) for node in c.children(book, 'binary')),
                         Counter(images))
        for link in links:
            self.assertIn(link.get(href)[1:], anchors)
        with zipfile.ZipFile(source) as archive:
            self.assertIn('OPS/Images/notes.xhtml#two', archive.namelist())

    def test_epub_keeps_error_when_fragment_records_have_no_proven_replacement(self):
        for defect in ('ambiguous', 'missing', 'spine', 'real-resource'):
            with self.subTest(defect=defect):
                source, _ = self.epub_with_fragment_manifest_entries(defect)
                output = self.root / 'ambiguous-gallery.fb2'
                with self.assertRaisesRegex(c.ConversionError, 'Один идентификатор EPUB обозначает разные ресурсы: copy'):
                    c.convert_book(source, output, allow_partial_epub=True)
                self.assertFalse(output.exists())

    def test_epub_recovers_missing_numeric_paths_to_unambiguous_local_anchors(self):
        source = self.generic(
            '<p><a href="./101">First numeric link</a> <a href="./102">Second numeric link</a> '
            '<a href="./103">Ambiguous anchor</a> <a href="./104">Existing file</a> '
            '<a href="./999">Unknown target</a> <a href="101">Bare numeric link</a> '
            '<a href="./102?source=other">Different resource</a> '
            '<a href="./105">Repeated in one chapter</a></p>'
            '<p id="103">First duplicate</p><p id="105">Another anchor</p><p id="105">Same ID</p>',
            '<p><a name="101"/>First target text.</p><p id="102">Second target text.</p>'
            '<p id="103">Second duplicate</p><p id="104">Anchor with a file of the same name</p>')
        with zipfile.ZipFile(source, 'a') as package:
            package.writestr('OPS/104', b'Existing relative resource')
        output = self.root/'numeric-bookmarks.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        anchors = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        links = {c.plain(node): node.get('{' + c.XL + '}href') for node in body.iter('{' + c.FB + '}a')}
        self.assertEqual({label: anchors[ref.removeprefix('#')] for label, ref in links.items()},
                         {'First numeric link': 'First target text.', 'Second numeric link': 'Second target text.',
                          'Bare numeric link': 'First target text.'})
        notices = c.damaged_content_warnings(report['warnings'])
        for href in ('./103', './104', './999', './102?source=other', './105'):
            self.assertTrue(any(f'«{href}»' in notice for notice in notices), notices)
        self.assertEqual(len(notices), 5)

    def test_epub_does_not_infer_numeric_link_from_one_matching_anchor(self):
        source = self.generic('<p><a href="./101">Single numeric path</a></p>',
                              '<p id="101">Only matching anchor</p>')
        output = self.root/'single-numeric.fb2'
        result = c.convert_book(source, output)
        self.validate_fb2(output)
        self.assertFalse(list(c.xml(output.read_bytes()).iter('{' + c.FB + '}a')))
        self.assertTrue(any('«./101»' in msg for msg in c.damaged_content_warnings(result['warnings'])))

    def test_epub_splits_nested_links_without_losing_text_or_styles(self):
        source = self.generic(
            '<p><a href="https://example.test/outer"><strong>Before '
            '<a href="./101"><em>Middle</em></a> after</strong> end</a>.</p>'
            '<p><a href="./102"><strong><a href="./102">Repeated</a></strong></a></p>'
            '<p><a href="https://example.test/unlabelled"><a href="./101">Only inner</a></a></p>',
            '<p id="101">First destination</p><p id="102">Second destination</p>')
        output = self.root / 'nested-links.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        link_tag, href = '{' + c.FB + '}a', '{' + c.XL + '}href'
        self.assertEqual([''.join(p.itertext()) for p in body.iter('{' + c.FB + '}p')][:3],
                         ['Before Middle after end.', 'Repeated', 'Only inner'])
        links = list(body.iter(link_tag))
        self.assertTrue(all(list(link.iter(link_tag)) == [link] for link in links))
        destinations = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        self.assertEqual([(c.plain(link), destinations.get(link.get(href)[1:], link.get(href))) for link in links],
                         [('Before', 'https://example.test/outer'), ('Middle', 'First destination'),
                          ('after end', 'https://example.test/outer'), ('Repeated', 'Second destination'),
                          ('Only inner', 'First destination')])
        bold = [c.plain(node) for node in body.iter('{' + c.FB + '}strong')]
        self.assertEqual(bold, ['Before', 'Middle', 'after', 'Repeated'])
        self.assertEqual([c.plain(node) for node in body.iter('{' + c.FB + '}emphasis')], ['Middle'])
        notices = c.damaged_content_warnings(report['warnings'])
        self.assertEqual(len(notices), 1, notices)
        self.assertIn('https://example.test/unlabelled', notices[0])

    def test_missing_epub_image_keeps_text_and_reports_its_number(self):
        source = self.generic('<p>Before <img src="absent.png" alt="Portrait"/> after.</p>',
                              '<p>Last paragraph.</p>')
        output = self.root / 'partial.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.plain(c.first(c.xml(output.read_bytes()), 'body'))
        self.assertIn('Before [Изображение 1 недоступно.] Portrait after.', body)
        self.assertIn('Изображение 1 недоступно. Portrait', c.damaged_content_warnings(report['warnings']))

    def test_epub_empty_or_malformed_image_addresses_identify_the_chapter(self):
        source = self.generic('<p>Before <img src=""/> between <img src="http://[not-an-address/p.png"/>'
                              ' after <img src="image.png"/> end.</p>')
        before = digest(source)
        output = self.root / 'image-addresses.fb2'
        report = c.convert_book(source, output, allow_partial_epub=True)
        self.validate_fb2(output)
        notices = c.damaged_content_warnings(report['warnings'])
        self.assertIn('Изображение 1 недоступно. В разделе «chapter.xhtml» не указан файл изображения.', notices)
        self.assertTrue(any(message.startswith('Изображение 2 недоступно. В разделе «chapter.xhtml» некорректный адрес')
                            for message in notices))
        book = c.xml(output.read_bytes())
        text = c.plain(c.first(book, 'body'))
        self.assertTrue(all(token in text for token in ('Before', 'between', 'after', 'end.')))
        binary, = c.children(book, 'binary')
        self.assertEqual(base64.b64decode(c.plain(binary)), PNG)
        self.assertEqual(digest(source), before)

    def with_navigation(self, source, navigation, *, epub3=False, spine_index=None, cover=None):
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(files['OPS/package.opf'])
        manifest = c.first(package, 'manifest')
        name = 'nav.xhtml' if epub3 else 'toc.ncx'
        item = c.element(c.OP, 'item', id='navigation', href=name,
                         **{'media-type': 'application/xhtml+xml' if epub3 else 'application/x-dtbncx+xml'})
        if epub3: item.set('properties', 'nav')
        else: c.first(package, 'spine').set('toc', 'navigation')
        manifest.append(item)
        if spine_index is not None:
            c.first(package, 'spine').insert(spine_index, c.element(c.OP, 'itemref', idref='navigation'))
        if cover:
            guide = c.element(c.OP, 'guide')
            guide.append(c.element(c.OP, 'reference', type='cover', href=cover))
            package.append(guide)
        files['OPS/package.opf'] = c.serialized(package)
        files['OPS/'+name] = navigation
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items(): archive.writestr(name, data)
        return source

    def test_ncx_title_paragraphs_keep_hierarchy_styles_text_and_links(self):
        source = self.generic('''<div id="start"><p> </p><p class="bold">Chapter 1 <span>Walking</span></p>
          <p>FirstProse <a href="#detail">details</a>.</p>
          <p id="detail"><span>Subchapter</span></p><p>SecondProse</p>
          <h2 id="existing">ExistingHeading</h2><p>LastProse</p>
          <p id="different">OrdinaryParagraph</p><p><a href="#start">return</a></p></div>''',
          '<p>EndOfBook</p>', 'p.bold{font-weight:bold}')
        ncx = '''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint><navLabel><text>Chapter 1 Walking</text></navLabel><content src="chapter.xhtml#start"/>
            <navPoint><navLabel><text>Subchapter</text></navLabel><content src="chapter.xhtml#detail"/></navPoint>
          </navPoint><navPoint><navLabel><text>DifferentLabel</text></navLabel><content src="chapter.xhtml#different"/></navPoint>
          <navPoint><navLabel><text>ExistingHeading</text></navLabel><content src="chapter.xhtml#existing"/></navPoint>
          </navMap></ncx>'''
        self.with_navigation(source, ncx); before = digest(source); output = self.root/'ncx.fb2'
        c.convert_book(source, output); self.validate_fb2(output)
        book = ET.parse(output).getroot(); body = c.first(book, 'body')
        titles = list(body.iter('{'+c.FB+'}title'))
        self.assertEqual([c.plain(n) for n in titles], ['Chapter 1 Walking', 'Subchapter', 'ExistingHeading'])
        self.assertTrue(list(titles[0].iter('{'+c.FB+'}strong')))
        chapter = next(n for n in body.iter('{'+c.FB+'}section') if c.first(n,'title') is titles[0])
        subchapter = next(n for n in body.iter('{'+c.FB+'}section') if c.first(n,'title') is titles[1])
        self.assertIn(subchapter, list(chapter))
        for value in ['FirstProse', 'SecondProse', 'LastProse', 'OrdinaryParagraph', 'EndOfBook']:
            self.assertEqual(c.plain(body).count(value), 1)
        self.assertNotIn('DifferentLabel', c.plain(body))
        ids = {n.get('id') for n in body.iter() if n.get('id')}
        for link in body.iter('{'+c.FB+'}a'): self.assertIn(link.get('{'+c.XL+'}href')[1:], ids)
        converted_epub = self.root/'restored-outline.epub'
        c.convert_book(output, converted_epub)
        with zipfile.ZipFile(converted_epub) as archive:
            toc = c.xhtml(archive.read('OEBPS/nav.xhtml'))
            links = list(toc.iter('{' + c.XH + '}a'))
            self.assertEqual([c.plain(n) for n in links],
                             ['Chapter 1 Walking', 'Subchapter', 'DifferentLabel', 'ExistingHeading'])
            listing = c.first(next(toc.iter('{' + c.XH + '}nav')), 'ol')
            self.assertEqual(len(c.children(listing, 'li')), 3)
            self.assertEqual(c.plain(c.first(c.first(c.first(listing, 'li'), 'ol'), 'li')), 'Subchapter')
            chapter_document = c.xhtml(archive.read('OEBPS/body-1.xhtml'))
            destinations = {n.get('id'): c.plain(n) for n in chapter_document.iter() if n.get('id')}
            self.assertEqual(destinations[links[2].get('href').split('#',1)[1]], 'OrdinaryParagraph')
        self.assertEqual(digest(source), before)

    def test_epub3_toc_promotes_only_matching_local_existing_title(self):
        source = self.generic('''<p><a id="глава+1"/>Название <span>главы</span></p><p>UnchangedProse</p>
          <p id="other">NotTheLabel</p><p id="pic"><img src="image.png"/>PictureParagraph</p>''', '<p>End</p>')
        nav = f'''<html xmlns="{c.XH}" xmlns:epub="{c.EP}"><head><title>TOC</title></head><body>
          <nav epub:type="landmarks"><ol><li><a href="chapter.xhtml#other">NotTheLabel</a></li></ol></nav>
          <nav epub:type="toc"><ol><li><a href="chapter.xhtml#%D0%B3%D0%BB%D0%B0%D0%B2%D0%B0+1">Название   главы</a></li>
            <li><a href="chapter.xhtml#other">DifferentLabel</a></li>
            <li><a href="chapter.xhtml#pic">PictureParagraph</a></li>
            <li><a href="https://example.invalid/chapter">RemoteHeading</a></li></ol></nav></body></html>'''
        self.with_navigation(source, nav, epub3=True); output = self.root/'nav.fb2'
        c.convert_book(source, output); self.validate_fb2(output)
        book = ET.parse(output).getroot(); body = c.first(book, 'body')
        self.assertEqual([c.plain(n) for n in body.iter('{'+c.FB+'}title')], ['Название главы'])
        self.assertEqual(c.plain(body).count('UnchangedProse'), 1)
        self.assertEqual(base64.b64decode(c.plain(c.children(book,'binary')[0])), PNG)

    def test_epub_spine_navigation_keeps_bidirectional_links_and_hidden_entries(self):
        source = self.generic('<h1 id="chapter">First chapter</h1><p>Opening text. '
                              '<a href="nav.xhtml#entry">Return to contents</a></p>',
                              '<p id="page3">Closing text.</p>')
        nav = f'''<html xmlns="{c.XH}" xmlns:epub="{c.EP}"><body>
          <nav epub:type="toc"><h2>Publisher contents</h2><ol>
            <li id="entry"><a href="chapter.xhtml#chapter">First chapter</a></li>
            <li hidden="hidden"><a href="notes.xhtml#page3">Hidden branch</a></li>
          </ol></nav><p>Publisher note after contents.</p>
          <nav epub:type="page-list" hidden=""><ol>
            <li><a href="notes.xhtml#page3">Printed page 3</a></li>
          </ol></nav></body></html>'''
        self.with_navigation(source, nav, epub3=True, spine_index=1)
        original = digest(source)
        output = self.root / 'spine-navigation.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        text = c.plain(body)
        labels = ['Opening text.', 'Publisher contents', 'Publisher note after contents.',
                  'Closing text.', 'Hidden branch', 'Printed page 3']
        self.assertEqual([text.index(label) for label in labels], sorted(text.index(label) for label in labels))
        self.assertNotIn('1. First chapter', text)
        link_tag, href = '{' + c.FB + '}a', '{' + c.XL + '}href'
        by_id = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        self.assertEqual({c.plain(link): by_id[link.get(href)[1:]] for link in body.iter(link_tag)},
                         {'Return to contents': 'First chapter', 'First chapter': 'First chapter',
                          'Hidden branch': 'Closing text.', 'Printed page 3': 'Closing text.'})
        self.assertEqual(len(c.damaged_content_warnings(report['warnings'])), 1)
        self.assertEqual(digest(source), original)

    def test_html_link_with_empty_fragment_leads_to_document_start(self):
        source = self.root / 'top.html'
        source.write_text('<h1>Opening heading</h1><p><a href="#">Return to top</a> '
                          '<a href="#missing">Unknown target</a></p>', encoding='utf8')
        output = self.root / 'top.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        href = '{' + c.XL + '}href'
        links = {c.plain(link): link.get(href) for link in body.iter('{' + c.FB + '}a')}
        self.assertEqual(links, {'Return to top': '#' + body[0].get('id')})
        self.assertTrue(c.plain(body[0]).startswith('Opening heading'))
        self.assertIn('Unknown target', c.plain(body))
        self.assertEqual([line for line in report['warnings'] if line.startswith('Не найдена цель внутренней ссылки')],
                         ['Не найдена цель внутренней ссылки «#missing». Текст ссылки сохранён.'])

    def test_epub_navigation_cover_link_uses_declared_cover_when_only_fragment_is_missing(self):
        source = self.generic('<p>Opening text. <a href="nav.xhtml">Publisher contents</a></p>',
                              '<p><img src="image.png" alt="Cover"/>Cover document.</p>')
        nav = f'''<html xmlns="{c.XH}" xmlns:epub="{c.EP}"><body>
          <nav epub:type="toc"><ol><li><a href="chapter.xhtml">First chapter</a></li></ol></nav>
          <nav epub:type="landmarks" hidden="hidden"><ol><li><a href="notes.xhtml#Cover">To cover</a></li>
            <li><a href="notes.xhtml#NoSuchPlace">Unconfirmed fragment</a></li></ol></nav></body></html>'''
        self.with_navigation(source, nav, epub3=True, cover='notes.xhtml')
        output = self.root / 'declared-cover.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        by_id = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        links = {c.plain(node): node.get('{' + c.XL + '}href')[1:] for node in body.iter('{' + c.FB + '}a')}
        self.assertEqual(by_id[links['To cover']], 'Cover document.')
        self.assertNotIn('Unconfirmed fragment', links)
        self.assertIn('Unconfirmed fragment', c.plain(body))
        notices = c.damaged_content_warnings(report['warnings'])
        self.assertTrue(any(warning.startswith('Метка обложки EPUB отсутствует') for warning in notices), notices)
        self.assertTrue(any('notes.xhtml#NoSuchPlace' in warning for warning in notices), notices)

    def test_epub_repairs_missing_cover_link_only_in_declared_inline_contents(self):
        source = self.generic('''<ol><li><a href="obsolete/cover.xhtml"><span>Cover</span></a></li>
          <li><a href="obsolete/appendix.xhtml">Appendix</a></li>
          <li><a href="notes.xhtml">Existing cover link</a></li></ol>''',
          '''<p><img src="image.png" alt="Cover"/>Actual cover.</p>
          <p><a href="obsolete/cover.xhtml">Cover</a></p>''')
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package = c.xml(files['OPS/package.opf'])
        guide = c.element(c.OP, 'guide')
        guide.append(c.element(c.OP, 'reference', type='toc', href='chapter.xhtml#contents'))
        guide.append(c.element(c.OP, 'reference', type='cover', href='notes.xhtml', title='Cover'))
        package.append(guide)
        files['OPS/package.opf'] = c.serialized(package)
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        original = digest(source)
        output = self.root / 'guide-cover.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        by_id = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        links = [(c.plain(node), by_id[node.get('{' + c.XL + '}href')[1:]])
                 for node in body.iter('{' + c.FB + '}a')]
        self.assertEqual([target for label, target in links if label == 'Cover'], ['Actual cover.Cover'])
        self.assertIn(('Existing cover link', 'Actual cover.Cover'), links)
        self.assertTrue(any('obsolete/appendix.xhtml' in warning for warning in report['warnings']))
        self.assertTrue(any('obsolete/cover.xhtml' in warning for warning in report['warnings']))
        self.assertEqual(digest(source), original)

    def test_epub_recovers_declared_image_with_unmarked_utf8_zip_name(self):
        name = 'схема.png'
        source = self.generic(f'<p>Before <img src="{name}"/> after.</p>')
        class UnmarkedUtf8(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode('utf-8'), self.flag_bits & ~0x800

        editable = self.root/'zip-name-repair.epub'
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(editable, 'w') as archive:
            for item in original.infolist():
                data = original.read(item)
                if item.filename.endswith('.opf'):
                    data = data.replace(b'href="image.png"', f'href="{name}"'.encode())
                if item.filename.endswith('/image.png'):
                    item = UnmarkedUtf8(item.filename.replace('image.png', name))
                archive.writestr(item, data)
        before = digest(editable)
        with zipfile.ZipFile(editable) as archive:
            self.assertFalse(any(item.filename.endswith(name) for item in archive.infolist()))
        output = self.root/'zip-name-repair.fb2'
        report = c.convert_book(editable,output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        self.assertEqual(base64.b64decode(c.children(book,'binary')[0].text), PNG)
        self.assertNotIn('Изображение 1 недоступно', c.plain(book))
        self.assertTrue(any(w.startswith('Восстановлены имена изображений EPUB') for w in report['warnings']))
        self.assertEqual(digest(editable), before)

    def test_epub_outline_restores_confirmed_opening_title_and_cover_fragments(self):
        for epub3 in (False, True):
            with self.subTest(epub3=epub3):
                source = self.generic('<p><em>Opening title</em></p><p>Chapter text.</p>'
                                      '<p><a href="chapter.xhtml#old">Open title</a></p>'
                                      '<h2>Later heading</h2><p id="real">Valid target.</p>',
                                      '<p><img src="image.png" alt="Cover"/>Cover document.</p>')
                items = [('Opening title', 'chapter.xhtml#old'), ('Cover', 'notes.xhtml#Cover'),
                         ('Later heading', 'chapter.xhtml#unknown'), ('Existing', 'chapter.xhtml#real')]
                if epub3:
                    nodes = ''.join(f'<li><a href="{link}">{label}</a></li>' for label, link in items)
                    nav = f'<html xmlns:epub="{c.EP}"><body><nav epub:type="toc"><ol>{nodes}</ol></nav></body></html>'
                else:
                    nodes = ''.join(f'<navPoint><navLabel><text>{label}</text></navLabel>'
                                    f'<content src="{link}"/></navPoint>' for label, link in items)
                    nav = f'<ncx><navMap>{nodes}</navMap></ncx>'
                self.with_navigation(source, nav, epub3=epub3, cover='notes.xhtml')
                output = self.root / f'confirmed-outline-{epub3}.fb2'
                original = digest(source)
                report = c.convert_book(source, output)
                self.validate_fb2(output)
                book = c.xml(output.read_bytes())
                outline = next(n.text for n in c.children(c.first(book, 'description'), 'custom-info')
                               if n.get('info-type') == c.FB2_EPUB_OUTLINE)
                targets = {node.get('id'): c.plain(node) for node in c.first(book, 'body').iter() if node.get('id')}
                entries = [line.split('\t') for line in outline.splitlines()]
                self.assertEqual([label for _, _, label in entries], ['Opening title', 'Cover', 'Existing'])
                self.assertTrue(targets[entries[0][0]].startswith('Opening title'))
                self.assertEqual(targets[entries[1][0]], 'Cover document.')
                self.assertEqual(targets[entries[2][0]], 'Valid target.')
                self.assertIn('Не перенесены переходы оглавления EPUB (1): «Later heading».',
                              c.damaged_content_warnings(report['warnings']))
                self.assertFalse(any('Не найдена цель ссылки EPUB' in line for line in report['warnings']))
                self.assertEqual(digest(source), original)

    def test_broken_optional_ncx_does_not_prevent_readable_text_conversion(self):
        for navigation in ['<ncx><broken>', '<!DOCTYPE ncx [<!ENTITY title "unsafe">]><ncx/>']:
            source = self.with_navigation(self.generic('<h1>RealHeading</h1><p>ReadableText</p>', '<p>End</p>'), navigation)
            output = self.root/'broken-nav.fb2'
            report = c.convert_book(source, output); self.validate_fb2(output)
            body = c.first(ET.parse(output).getroot(), 'body')
            self.assertEqual([c.plain(n) for n in body.iter('{'+c.FB+'}title')], ['RealHeading'])
            self.assertIn('ReadableText', c.plain(body))
            self.assertTrue(any('Оглавление EPUB' in warning for warning in report['warnings']))
            output.unlink()

    def test_epub_blank_cover_is_reported_and_reading_page_image_survives(self):
        source = self.generic('<p><img src="image.png"/></p>', '<h1>Chapter</h1><p>Readable text.</p>',
                              extra_metadata='<meta name="cover" content="cover"/>')
        with zipfile.ZipFile(source) as archive:
            contents = {name: archive.read(name) for name in archive.namelist()}
        contents['OPS/package.opf'] = contents['OPS/package.opf'].replace(
            b'</manifest>', b'<item id="cover" href="cover.jpg" media-type="image/jpeg"/></manifest>')
        contents['OPS/cover.jpg'] = b'\n'
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in contents.items():
                archive.writestr(name, data)
        original = digest(source)
        output = self.root/'without-broken-cover.fb2'
        result = c.convert_book(source, output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        self.assertIsNone(c.first(c.first(c.first(book,'description'),'title-info'),'coverpage'))
        self.assertEqual([base64.b64decode(node.text) for node in c.children(book,'binary')], [PNG])
        self.assertIn('Readable text.', c.plain(c.first(book,'body')))
        self.assertEqual(c.damaged_content_warnings(result['warnings']),
                         ['Не удалось прочитать обложку EPUB «OPS/cover.jpg».'])
        self.assertEqual(digest(source),original)

    def test_epub_inline_raster_keeps_repeated_placements_in_both_fb2_writers(self):
        picture = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
                   + png_chunk(b'IDAT', zlib.compress(b'\0\x44\x55\x66\xff')) + png_chunk(b'IEND', b''))
        base64_text = base64.b64encode(picture).decode('ascii').replace('=', '%3D')
        wrapped = base64_text[:24] + '&#10;' + base64_text[24:]
        source = self.generic(f'<p>First<img src="DATA:image/png;BASE64,{wrapped}" alt="One"/></p>',
                              f'<p>Second<img src="data:image/png,{quote_from_bytes(picture, safe="")}" alt="Two"/></p>'
                              '<p>Third<img src="data:image/png;base64,invalid-characters"/>End.</p>')
        original = digest(source)
        for streaming in (None, {}):
            with self.subTest(streaming=streaming is not None):
                output = self.root / 'inline-result.fb2'
                warnings = set()
                c.epub_to_fb2(source, output, warnings, stream_images=streaming, allow_partial_epub=True)
                self.validate_fb2(output)
                book = c.xml(output.read_bytes())
                images = list(c.first(book, 'body').iter('{' + c.FB + '}image'))
                self.assertEqual([node.get('alt') for node in images], ['One', 'Two'])
                ids = {node.get('{' + c.XL + '}href').removeprefix('#') for node in images}
                self.assertEqual(len(ids), 1)
                [binary] = [node for node in c.children(book, 'binary') if node.get('id') in ids]
                self.assertEqual(binary.get('content-type'), 'image/png')
                self.assertEqual(base64.b64decode(binary.text), picture)
                self.assertIn('Встроенная иллюстрация в «notes.xhtml».', '\n'.join(c.damaged_content_warnings(warnings)))
                self.assertNotIn('invalid-characters', output.read_text(encoding='utf-8'))
                self.assertFalse(list(self.root.glob('homelibre-fb2-images-*')))
                output.unlink()
        self.assertEqual(digest(source), original)

    def test_epub_inline_svg_round_trips_as_the_original_vector(self):
        vector = (b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="17" height="19">'
                  b'<defs><clipPath id="a"><circle cx="3" cy="3" r="3"/></clipPath></defs>'
                  b'<style>.art {clip-path:url(#a);fill:#692a35}</style>'
                  b'<rect class="art" x="1" y="2" width="7" height="8"/></svg>')
        raw = quote_from_bytes(vector, safe='')
        encoded = base64.b64encode(vector).decode('ascii')
        source = self.generic(f'<p>A<img src="data:image/svg+xml,{raw}" alt="First"/>B</p>',
                              f'<p>C<img src="data:image/svg+xml;base64,{encoded}" alt="Second"/>D</p>')
        original = digest(source)
        for stream_images in (None, {}):
            with self.subTest(streaming=stream_images is not None):
                fb2 = self.root / 'vector.fb2'
                epub = self.root / 'vector-roundtrip.epub'
                warnings = set()
                c.epub_to_fb2(source, fb2, warnings, stream_images=stream_images, allow_partial_epub=True)
                self.assertFalse(c.damaged_content_warnings(warnings))
                self.validate_fb2(fb2)
                book = ET.parse(fb2).getroot()
                [resource] = [item for item in c.children(book, 'binary') if item.get('content-type') == 'image/svg+xml']
                self.assertEqual(base64.b64decode(resource.text), vector)
                images = list(c.first(book, 'body').iter('{' + c.FB + '}image'))
                self.assertEqual([(item.get('alt'),item.get('{' + c.XL + '}href')) for item in images],
                                 [('First', '#' + resource.get('id')), ('Second', '#' + resource.get('id'))])
                c.convert_book(fb2, epub)
                with zipfile.ZipFile(epub) as archive:
                    [member] = [name for name in archive.namelist() if name.endswith('.svg')]
                    self.assertEqual(archive.read(member), vector)
                self.assertFalse(list(self.root.glob('homelibre-fb2-images-*')))
                fb2.unlink()
                epub.unlink()
        self.assertEqual(digest(source), original)

    def test_epub_inline_svg_with_unavailable_resources_leaves_a_specific_warning(self):
        for vector in (b'<svg><image href="drawing.png"/></svg>',
                       b'<svg><style>.art {fill:url(palette.svg#pink)}</style></svg>',
                       b'<svg><rect onload="example"/></svg>',
                       b'<?xml-stylesheet href="palette.css"?><svg/>',
                       b'<!DOCTYPE svg SYSTEM "paper.dtd"><svg/>',
                       b'<svg><rect></svg>'):
            with self.subTest(vector=vector):
                data_url = 'data:image/svg+xml,' + quote_from_bytes(vector, safe='')
                source = self.generic(f'<p>Before<img src="{data_url}" alt="Drawing"/>After</p>', '<p>Notes</p>')
                output = self.root/'vector-warning.fb2'
                warnings = set()
                c.epub_to_fb2(source, output, warnings, allow_partial_epub=True)
                diagnostic = c.damaged_content_warnings(warnings)
                self.assertTrue(any(message.startswith('SVG в «chapter.xhtml»') for message in diagnostic))
                book = ET.parse(output).getroot()
                self.assertIn('After', c.plain(c.first(book, 'body')))
                self.assertFalse(any(item.get('content-type') == 'image/svg+xml' for item in c.children(book, 'binary')))
                output.unlink()

    def test_ncx_labels_at_document_boundaries_do_not_replace_prose(self):
        source = self.generic('<p id="intro">IntroductoryProse</p>', '<h1>ExistingAfterword</h1><p>FinalProse</p>')
        ncx = '''<ncx><navMap><navPoint><navLabel><text>Introduction</text></navLabel><content src="chapter.xhtml"/></navPoint>
          <navPoint><navLabel><text>DifferentAfterwordLabel</text></navLabel><content src="notes.xhtml"/></navPoint></navMap></ncx>'''
        self.with_navigation(source, ncx); output = self.root/'document-titles.fb2'
        c.convert_book(source, output); self.validate_fb2(output)
        book = ET.parse(output).getroot()
        body = c.first(book, 'body')
        self.assertEqual([c.plain(n) for n in body.iter('{'+c.FB+'}title')], ['ExistingAfterword'])
        self.assertEqual(c.plain(body).count('IntroductoryProse'), 1)
        self.assertEqual(c.plain(body).count('FinalProse'), 1)
        self.assertNotIn('Introduction', c.plain(body))
        metadata = next(n.text for n in c.children(c.first(book, 'description'),'custom-info')
                        if n.get('info-type') == c.FB2_EPUB_OUTLINE)
        self.assertEqual([line.split('\t')[-1] for line in metadata.splitlines()],
                         ['Introduction', 'DifferentAfterwordLabel'])

    def test_ncx_whole_document_title_is_not_repeated_before_an_illustration(self):
        source = self.generic('''<p><img src="image.png" alt="Cover"/></p>
          <h1>Existing Chapter</h1><p>Chapter prose.</p>''', '<p>Afterword prose.</p>')
        ncx = '''<ncx><navMap>
          <navPoint><navLabel><text>Existing Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint>
          <navPoint><navLabel><text>Afterword</text></navLabel><content src="notes.xhtml"/></navPoint>
          </navMap></ncx>'''
        self.with_navigation(source, ncx)
        output = self.root / 'cover-first.fb2'
        c.convert_book(source, output)
        self.validate_fb2(output)
        body = c.first(ET.parse(output).getroot(), 'body')
        self.assertEqual([c.plain(n) for n in body.iter('{'+c.FB+'}title')], ['Existing Chapter'])
        significant = [c.tag(node) for node in body.iter() if c.tag(node) in {'title', 'image'}]
        self.assertEqual(significant, ['image', 'title'])

    def test_generic_lists_tables_breaks_css_and_images(self):
        epub=self.generic('<div><h1>Глава</h1><p class="bold">Первая<br/>Вторая <em>третья<br/>четвёртая</em></p><ol><li>Один</li><li>Два</li></ol><table><tbody><tr><th>Колонка</th><td>Значение</td></tr></tbody></table><p><img src="image.png" alt="Картинка"/></p></div>', '<p>Завершение</p>', '.bold{font-weight:bold}')
        fb2=self.root/'styles.fb2'; c.convert_book(epub,fb2); self.validate_fb2(fb2)
        book=ET.parse(fb2).getroot(); text=c.plain(book)
        for word in ['Первая','Вторая','третья','четвёртая','1. Один','2. Два','Значение','Завершение']: self.assertIn(word,text)
        self.assertTrue(list(book.iter('{'+c.FB+'}strong')))
        self.assertEqual(base64.b64decode(c.plain(c.children(book,'binary')[0])),PNG)
    def test_does_not_replace_output_or_source(self):
        output=self.root/'existing.epub'; output.write_bytes(b'personal existing file')
        with self.assertRaises(c.ConversionError): c.convert_book(self.source,output)
        self.assertEqual(output.read_bytes(),b'personal existing file')
        with self.assertRaises(c.ConversionError): c.convert_book(self.source,self.source)
    def test_failure_cleans_only_owned_temp(self):
        source=self.root/'bad.fb2'; source.write_bytes(b'<broken>')
        output=self.root/'failed.epub'
        with self.assertRaises(c.ConversionError): c.convert_book(source,output)
        self.assertFalse(output.exists()); self.assertEqual(source.read_bytes(),b'<broken>')
    def test_utf16_internal_entity_rejected(self):
        source=self.root/'entities.fb2'; source.write_bytes('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY a "replacement">]><x>&a;</x>'.encode('utf-16'))
        with self.assertRaises(c.ConversionError): c.convert_book(source,self.root/'entities.epub')
    def test_external_doctype_does_not_fetch(self):
        self.assertEqual(c.tag(c.xml(b'<!DOCTYPE html SYSTEM "https://invalid.example/never-fetch"><html/>')),'html')
    def test_unrepresentable_content_reports_failure(self):
        for content in ['<p>Текст</p><video src="video.mp4"/>','<p><object data="example.bin"/></p>']:
            epub=self.generic(content,'<p>Конец</p>'); before=digest(epub)
            with self.assertRaises(c.ConversionError): c.convert_book(epub,self.root/'unsupported.fb2')
            self.assertEqual(digest(epub),before); self.assertFalse((self.root/'unsupported.fb2').exists())
    def test_broken_epub_link_keeps_its_text_with_a_warning(self):
        epub = self.generic('<p><a href="missing.xhtml#gone">Ссылка</a></p>', '<p>Конец</p>')
        out = self.root / 'broken-link.fb2'
        result = c.convert_book(epub, out)
        self.validate_fb2(out)
        self.assertIn('Ссылка', c.plain(c.first(c.xml(out.read_bytes()), 'body')))
        self.assertTrue(any('missing.xhtml#gone' in warning for warning in c.damaged_content_warnings(result['warnings'])))

    def test_malformed_external_epub_link_keeps_literal_example(self):
        source = self.generic('''<pre>Selector <a href="http://&quot;]:not([href^=&quot;http://example.test">http://"]:not([href^="http://example.test</a> tail.</pre>
            <p><a href="https://example.test/about">Valid link</a></p>''', '<p>End.</p>')
        output = self.root / 'bad-external-href.fb2'
        before = digest(source)
        with self.assertRaisesRegex(c.ConversionError, 'Некорректный адрес ссылки EPUB.*подтверждение'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        report = c.convert_book(source, output, allow_partial_epub=True)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        self.assertIn('Selector http://"]:not([href^="http://example.test tail.', c.plain(body))
        self.assertEqual([node.get('{' + c.XL + '}href') for node in body.iter('{' + c.FB + '}a')],
                         ['https://example.test/about'])
        self.assertTrue(any(w.startswith('Некорректный адрес ссылки EPUB') for w in
                            c.damaged_content_warnings(report['warnings'])))
        self.assertEqual(digest(source), before)

    def test_epub_duplicate_anchors_keep_both_paragraphs(self):
        epub = self.generic('<p id="part">Первый.</p><p id="part">Второй.</p><p><a href="#part">Переход</a></p>', '<p>Конец.</p>')
        output = self.root / 'duplicate-anchors.fb2'
        report = c.convert_book(epub, output)
        self.validate_fb2(output)
        body = c.first(c.xml(output.read_bytes()), 'body')
        paragraphs = {c.plain(node): node for node in body.iter() if c.tag(node) == 'p'}
        self.assertNotEqual(paragraphs['Первый.'].get('id'), paragraphs['Второй.'].get('id'))
        link = next(node for node in body.iter() if c.tag(node) == 'a')
        self.assertEqual(link.get('{' + c.XL + '}href'), '#' + paragraphs['Первый.'].get('id'))
        self.assertTrue(any('Повторяющиеся метки EPUB' in warning for warning in report['warnings']))

    def test_ncx_disambiguates_duplicate_anchors_using_exact_heading_text(self):
        source = self.generic(
            '<h1 id="part">Part I</h1><h1 id="part"><br/></h1>'
            '<h1 id="title"></h1><h1 id="title"><span>Antaeus</span></h1>'
            '<h2 id="same">Repeated</h2><h2 id="same">Repeated</h2>', '<p>End.</p>')
        self.with_navigation(source, '''<ncx><navMap>
          <navPoint><navLabel><text>Part I</text></navLabel><content src="chapter.xhtml#part"/></navPoint>
          <navPoint><navLabel><text>Antaeus</text></navLabel><content src="chapter.xhtml#title"/></navPoint>
          <navPoint><navLabel><text>Repeated</text></navLabel><content src="chapter.xhtml#same"/></navPoint>
          </navMap></ncx>''')
        before = digest(source)
        output = self.root / 'duplicate-toc-anchors.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        outline = next(n.text for n in c.children(c.first(book, 'description'), 'custom-info')
                       if n.get('info-type') == c.FB2_EPUB_OUTLINE)
        targets = {node.get('id'): c.plain(node) for node in c.first(book, 'body').iter() if node.get('id')}
        entries = [line.split('\t') for line in outline.splitlines()]
        self.assertEqual([(label, targets[anchor]) for anchor, _, label in entries],
                         [('Part I', 'Part I'), ('Antaeus', 'Antaeus')])
        self.assertIn('Не перенесены переходы оглавления EPUB (1): «Repeated».',
                      c.damaged_content_warnings(report['warnings']))
        self.assertEqual(digest(source), before)

    def test_external_epub_image_is_never_loaded_and_gets_a_marker(self):
        epub = self.generic('<p>До <img alt="Карта" src="https://invalid.example/image.png"/> после.</p>')
        output = self.root / 'external.fb2'
        report = c.convert_book(epub, output)
        self.validate_fb2(output)
        self.assertIn('До [Изображение 1 недоступно.] Карта после.', c.plain(c.xml(output.read_bytes())))
        self.assertIn('Изображение 1 недоступно. Карта', c.damaged_content_warnings(report['warnings']))
    def test_archive_traversal_and_duplicate_names_rejected(self):
        bad=self.root/'bad.epub'
        with zipfile.ZipFile(bad,'w') as z: z.writestr('../escape.xml','data')
        with self.assertRaises(c.ConversionError): c.convert_book(bad,self.root/'bad.fb2')
    def test_zip_and_xml_target_validation(self):
        epub=self.root/'result.epub'; c.convert_book(self.source,epub)
        with zipfile.ZipFile(epub) as z:
            self.assertIsNone(z.testzip())
            for name in z.namelist():
                if name.endswith(('.xhtml','.xml','.opf')): ET.fromstring(z.read(name))
    def test_headings_in_containers_and_interblock_text(self):
        epub=self.generic('<div>Вступление <span>в строке</span>.<h1 id="a">Часть</h1><p>Абзац А</p>Между абзацами<h2>Раздел</h2><p>Абзац Б</p><h2>Другой раздел</h2><p>Абзац В</p></div>', '<p>Завершение</p>')
        output=self.root/'containers.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); text=c.plain(c.first(book,'body'))
        for value in ['Вступление в строке.','Абзац А','Между абзацами','Абзац Б','Абзац В']: self.assertIn(value,text)
        parts=[n for n in book.iter('{'+c.FB+'}section') if c.first(n,'title') is not None]
        self.assertEqual([c.plain(c.first(n,'title')) for n in parts],['Часть','Раздел','Другой раздел'])
        self.assertEqual([c.plain(c.first(n,'title')) for n in c.children(parts[0],'section') if c.first(n,'title') is not None],['Раздел','Другой раздел'])
    def test_list_numbering_anchors_and_nested_paragraphs(self):
        epub=self.generic('<p><a href="#last">К последнему пункту</a></p><ol start="4"><li><p>Первый <em>важный</em></p><p>Продолжение</p></li><li value="9" id="last"><span>Последний</span><ul><li>Вложенный</li></ul></li></ol>', '<p>Конец</p>')
        output=self.root/'lists.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); paragraphs=[c.plain(n) for n in book.iter('{'+c.FB+'}p')]
        for text in ['4. Первый важный','Продолжение','9. Последний','• Вложенный']: self.assertIn(text,paragraphs)
        link=next(book.iter('{'+c.FB+'}a')); target=link.get('{'+c.XL+'}href')[1:]
        self.assertTrue(any(n.get('id')==target and '9. Последний' in c.plain(n) for n in book.iter()))
    def test_list_with_wrapped_items_retains_text_order_numbering_and_links(self):
        epub = self.generic('''<p><a href="#term">К пояснению</a></p><ol start="4">
            <span>Вступление к списку</span><div><li><a id="term">Пояснение</a></li>
            <li>Второй пункт<ul><li>Вложенный</li></ul></li></div><p>Между пунктами</p>
            <li value="9">Последний пункт</li></ol>''', '<p>Конец</p>')
        output = self.root / 'wrapped-list.fb2'
        c.convert_book(epub, output)
        self.validate_fb2(output)
        body = c.first(ET.parse(output).getroot(), 'body')
        paragraphs = [c.plain(n) for n in body.iter('{' + c.FB + '}p')]
        order = ['Вступление к списку', '4. Пояснение', '5. Второй пункт',
                 '• Вложенный', 'Между пунктами', '9. Последний пункт']
        self.assertEqual([p for p in paragraphs if p in order], order)
        href = next(body.iter('{' + c.FB + '}a')).get('{' + c.XL + '}href')
        target = next(n for n in body.iter() if n.get('id') == href[1:])
        self.assertEqual(c.plain(target), '4. Пояснение')
    def test_notes_outside_spine_and_without_fragment(self):
        for reference in ['notes.xhtml#n','notes.xhtml']:
            epub=self.generic('<p>Ссылка <a epub:type="noteref" href="'+reference+'">6</a></p>', '<aside id="n" epub:type="footnote"><p>6. Примечание</p></aside>', notes_in_spine=False)
            output=self.root/('notes-'+str(len(list(self.root.glob('notes-*.fb2'))))+'.fb2')
            c.convert_book(epub,output); self.validate_fb2(output)
            book=ET.parse(output).getroot(); notes=next(n for n in c.children(book,'body') if n.get('name')=='notes')
            self.assertEqual(c.plain(notes).count('6. Примечание'),1)
            target=next(book.iter('{'+c.FB+'}a')).get('{'+c.XL+'}href')[1:]
            self.assertTrue(any(n.get('id')==target for n in notes.iter()))

    def test_epub_recovers_nonbreaking_space_in_unique_link_targets(self):
        source = self.generic('''<p><a href="#chapter%C2%A0id">Recovered</a>
            <a href="#exact%C2%A0id">Exact</a><a href="#other%C2%A0id">Ambiguous</a>
            <a epub:type="noteref" href="notes.xhtml#note%C2%A0body">Footnote</a></p>
            <h1 id="chapter id">Chapter</h1><p id="exact id">Alternate target</p>
            <p id="exact&#160;id">Exact target</p><p id="other id">First duplicate</p>
            <p id="other id">Second duplicate</p>''',
            '<aside id="note body" epub:type="footnote"><p>Note text</p></aside>', notes_in_spine=False)
        self.with_navigation(source, '''<ncx><navMap><navPoint><navLabel><text>Chapter</text></navLabel>
            <content src="chapter.xhtml#chapter%C2%A0id"/></navPoint></navMap></ncx>''')
        original = digest(source)
        output = self.root / 'spaced-anchors.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        bodies = c.children(book, 'body')
        link_tag = '{' + c.FB + '}a'
        href = '{' + c.XL + '}href'
        targets = {node.get('id'): c.plain(node) for body in bodies for node in body.iter() if node.get('id')}
        links = {c.plain(node): targets[node.get(href)[1:]] for node in bodies[0].iter(link_tag)}
        self.assertEqual(links, {'Recovered': 'Chapter', 'Exact': 'Exact target', 'Footnote': 'Note text'})
        self.assertEqual(bodies[-1].get('name'), 'notes')
        outline = next(n.text for n in c.children(c.first(book, 'description'), 'custom-info')
                       if n.get('info-type') == c.FB2_EPUB_OUTLINE)
        self.assertEqual(targets[outline.split('\t')[0]], 'Chapter')
        warnings = c.damaged_content_warnings(report['warnings'])
        self.assertEqual(len(warnings), 1, warnings)
        self.assertIn('#other%C2%A0id', warnings[0])
        self.assertEqual(digest(source), original)

    def test_preformatted_examples_keep_inline_images_links_and_whitespace(self):
        epub = self.generic(
            '<p><a href="#example">Go to example</a></p>'
            '<pre id="example">  first\n\t<strong>print</strong><a href="#result"> output</a>'
            '<img src="image.png" alt="Terminal key"/> last\n</pre>'
            '<table><tr><td id="result"><pre>  code <img src="image.png" alt="Cell key"/> end</pre></td></tr></table>',
            notes_in_spine=False)
        output = self.root / 'preformatted.fb2'
        c.convert_book(epub, output)
        self.validate_fb2(output)
        book = ET.parse(output).getroot()
        body = c.first(book, 'body')
        first, cell = body.iter('{' + c.FB + '}code')
        self.assertEqual(''.join(first.itertext()), '  first\n\tprint output last\n')
        self.assertEqual(''.join(cell.itertext()), '  code  end')
        self.assertEqual(c.first(first, 'strong').text, 'print')
        images = [c.first(first, 'image'), c.first(cell, 'image')]
        self.assertEqual([image.get('alt') for image in images], ['Terminal key', 'Cell key'])
        href = '{' + c.XL + '}href'
        binary, = c.children(book, 'binary')
        self.assertEqual([image.get(href) for image in images], ['#' + binary.get('id')] * 2)
        self.assertEqual(base64.b64decode(binary.text), PNG)
        example, link = body.iter('{' + c.FB + '}a')
        self.assertEqual(next(n for n in body.iter() if n.get('id') == example.get(href)[1:])[0], first)
        self.assertEqual(next(n for n in body.iter() if n.get('id') == link.get(href)[1:])[0], cell)
    def test_table_caption_and_cell_paragraphs(self):
        epub=self.generic('<table id="t"><caption>Описание таблицы</caption><tbody><tr><td><p>Один <strong>жирный</strong></p><p>Два</p></td><td>Три<br/>Четыре</td></tr></tbody></table>', '<p>Конец</p>')
        output=self.root/'table.fb2'; result=c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); self.assertIn('Описание таблицы',c.plain(book))
        cells=list(book.iter('{'+c.FB+'}td')); self.assertIn('Один жирный\nДва',c.plain(cells[0]))
        self.assertIn('Три\nЧетыре',c.plain(cells[1])); self.assertTrue(list(cells[0].iter('{'+c.FB+'}strong')))
        self.assertTrue(any('ячеек' in warning for warning in result['warnings']))
    def test_basic_css_cascade_and_embedded_styles(self):
        epub=self.generic('<p class="bold" style="font-weight:normal">Обычный</p><p class="bold">Жирный</p><p class="slant">Курсив</p>', '<p>Конец</p>', '.bold{font-weight:bold}p{font-weight:normal}', head='<style>.slant{font-style:italic}</style>')
        output=self.root/'cascade.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); paragraphs={c.plain(p):p for p in book.iter('{'+c.FB+'}p')}
        self.assertFalse(list(paragraphs['Обычный'].iter('{'+c.FB+'}strong')))
        self.assertTrue(list(paragraphs['Жирный'].iter('{'+c.FB+'}strong')))
        self.assertTrue(list(paragraphs['Курсив'].iter('{'+c.FB+'}emphasis')))
    def test_generic_metadata_is_kept_even_without_direct_equivalent(self):
        epub=self.generic('<p>Текст</p>','<p>Конец</p>',extra_metadata='<dc:description>Описание книги</dc:description><dc:subject>Тема</dc:subject><dc:publisher>Издательство</dc:publisher><dc:rights>Права</dc:rights>')
        output=self.root/'metadata.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        description=c.first(ET.parse(output).getroot(),'description'); ti=c.first(description,'title-info')
        self.assertEqual(c.plain(c.first(ti,'annotation')),'Описание книги'); self.assertEqual(c.plain(c.first(ti,'keywords')),'Тема')
        saved=c.xml(base64.b64decode(c.plain(c.first(description,'custom-info'))))
        values={c.tag(n):c.plain(n) for n in saved}; self.assertEqual(values['publisher'],'Издательство'); self.assertEqual(values['rights'],'Права'); self.assertEqual(values['identifier'],'fixture')
    def test_legacy_xhtml_entities_and_source_encoding(self):
        data=('<?xml version="1.0" encoding="windows-1251"?><!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "https://invalid.example/xhtml.dtd"><html xmlns="'+c.XH+'"><body><p>Текст&nbsp;&copy; конец</p></body></html>').encode('cp1251')
        self.assertEqual(c.plain(c.xhtml(data)),'Текст\u00a0© конец')
        with self.assertRaises(c.ConversionError): c.xhtml(b'<!DOCTYPE html [<!ENTITY mine "x">]><html>&mine;</html>')

    def test_epub_restores_named_html_entities_without_a_doctype(self):
        source = self.generic('<p title="&eacute;">D&eacute;j&agrave;&nbsp;vu © <![CDATA[&agrave;]]></p>',
                              second='<p>Fin.</p>')
        output = self.root / 'named-entities.fb2'
        before = digest(source)
        result = c.convert_book(source, output)
        self.assertFalse(c.damaged_content_warnings(result['warnings']))
        self.validate_fb2(output)
        self.assertEqual(digest(source), before)
        self.assertIn('Déjà\u00a0vu © &agrave;', c.plain(c.first(c.xml(output.read_bytes()), 'body')))
        paragraph = c.xhtml(b'<html><p title="&eacute;"><![CDATA[<?xml encoding="latin1"?>&nbsp;]]></p></html>')[0]
        self.assertEqual(paragraph.get('title'), 'é')
        self.assertEqual(paragraph.text, '<?xml encoding="latin1"?>&nbsp;')
        with self.assertRaisesRegex(c.ConversionError, 'undefined entity'):
            c.xhtml(b'<html><p>&eacute;&unknown;</p></html>')
    def test_legacy_epub_reexport_keeps_bytes_and_validates_named_entities(self):
        source = self.generic()
        with zipfile.ZipFile(source) as archive:
            original = {n: archive.read(n) for n in archive.namelist()}
        original['OPS/chapter.xml'] = original.pop('OPS/chapter.xhtml')
        original['OPS/package.opf'] = original['OPS/package.opf'].replace(b'chapter.xhtml', b'chapter.xml')
        content = ('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
                   '"https://invalid.example/never-fetch.dtd"><html xmlns="'+c.XH+
                   '"><body><p>Полный текст&nbsp;&copy; и конец</p></body></html>')
        for index, encoding in enumerate(('utf-8', 'windows-1251', 'utf-16')):
            with self.subTest(encoding=encoding):
                chapter = ('<?xml version="1.0" encoding="'+encoding+'"?>'+content).encode(encoding)
                entries = dict(original, **{'OPS/chapter.xml': chapter})
                with zipfile.ZipFile(source, 'w') as archive:
                    for name, data in entries.items(): archive.writestr(name, data)
                before = source.read_bytes(); target = self.root / ('legacy-'+str(index)+'.epub')
                c.convert_book(source, target)
                self.assertEqual(target.read_bytes(), before)
                repaired = self.root / ('kindle-legacy-'+str(index)+'.epub')
                c.kindle_epub(source, repaired)
                with zipfile.ZipFile(repaired) as archive:
                    self.assertEqual(archive.read('OPS/chapter.xml'), chapter)
                self.assertEqual(source.read_bytes(), before)
        for index, chapter in enumerate((content.replace('&nbsp;', '&unknown;'),
                '<!DOCTYPE html [<!ENTITY a "replacement">]><html xmlns="'+c.XH+'"><body><p>&a;</p></body></html>',
                content.replace('</p>', '</broken>'))):
            entries = dict(original, **{'OPS/chapter.xml': chapter.encode('utf-8')})
            with zipfile.ZipFile(source, 'w') as archive:
                for name, data in entries.items(): archive.writestr(name, data)
            target = self.root / ('invalid-legacy-'+str(index)+'.epub'); before = source.read_bytes()
            with self.assertRaises(c.ConversionError): c.convert_book(source, target)
            self.assertFalse(target.exists()); self.assertEqual(source.read_bytes(), before)

    def test_generated_chapter_ids_do_not_collide_with_source_ids(self):
        text=self.source.read_text(encoding='utf-8').replace('<section id="one">','<section id="chapter-1">').replace('<section id="two">','<section>')
        source=self.root/'ids.fb2'; source.write_text(text,encoding='utf-8'); output=self.root/'ids.epub'
        c.convert_book(source,output); self.validate_epub(output)
        with zipfile.ZipFile(output) as archive:
            ids=[n.get('id') for n in c.xml(archive.read('OEBPS/body-1.xhtml')).iter() if n.get('id')]
            self.assertEqual(len(ids),len(set(ids))); self.assertIn('chapter-1',ids)

    def test_epub_start_link_does_not_become_a_chapter_after_conversion(self):
        title = 'Заглавие книги'
        plain = self.root/'plain.txt'
        plain.write_text('Обычный абзац без заголовка заканчивается точкой.\n', encoding='utf-8')
        fb2 = self.root/'plain.fb2'
        original = c.xml(self.source.read_bytes())
        description = c.first(original, 'description')
        c.first(c.first(description, 'title-info'), 'book-title').text = title
        body = c.first(original, 'body')
        for notes in c.children(original, 'body')[1:]:
            original.remove(notes)
        body.clear()
        section = c.element(c.FB, 'section')
        section.append(c.element(c.FB, 'p', 'Обычный абзац без заголовка заканчивается точкой.'))
        body.append(section)
        fb2.write_bytes(c.serialized(original))

        for source in (plain, fb2):
            with self.subTest(source=source.suffix):
                epub = self.root/f'{source.suffix[1:]}-plain.epub'
                c.convert_book(source, epub, title=title)
                c.validate_epub_output(epub)
                with zipfile.ZipFile(epub) as archive:
                    nav = c.xml(archive.read('OEBPS/nav.xhtml'))
                    [link] = nav.iter('{' + c.XH + '}a')
                    self.assertEqual(link.get(c.EPUB_START_ONLY), '1')
                    self.assertNotIn('#', link.get('href'))
                back = epub.with_suffix('.fb2')
                c.convert_book(epub, back)
                self.validate_fb2(back)
                book = c.xml(back.read_bytes())
                body = c.first(book, 'body')
                self.assertFalse(list(body.iter('{' + c.FB + '}title')))
                self.assertNotIn(title, c.plain(body))
                self.assertIn('заканчивается точкой.', c.plain(body))

    def test_invalid_generated_structure_never_publishes_result(self):
        epub=self.generic('<p><span data-fb2="table"><span data-fb2="p">Неправильная таблица</span></span></p>','<p>Конец</p>')
        with self.assertRaises(c.ConversionError): c.convert_book(epub,self.root/'invalid.fb2')
        self.assertFalse((self.root/'invalid.fb2').exists())
    def test_report_never_replaces_source_or_existing_file(self):
        destination=self.root/'cli.epub'; report=self.root/'report.json'; report.write_bytes(b'user data')
        for path in [report,self.source]:
            result=subprocess.run([sys.executable,'-X','utf8',str(MODULE),str(self.source),str(destination),'--report',str(path)],capture_output=True,timeout=10,creationflags=0x08000000)
            self.assertEqual(result.returncode,1); self.assertFalse(destination.exists())
        self.assertEqual(report.read_bytes(),b'user data')
    def test_sibling_subsections_share_one_nav_list(self):
        book=ET.parse(self.source).getroot(); section=c.first(c.first(book,'body'),'section')
        for number in range(3):
            nested=c.element(c.FB,'section'); title=c.element(c.FB,'title'); title.append(c.element(c.FB,'p','Дополнение '+str(number))); nested.append(title); nested.append(c.element(c.FB,'p','Текст')); section.append(nested)
        source=self.root/'sibling.fb2'; source.write_bytes(c.serialized(book)); output=self.root/'sibling.epub'
        c.convert_book(source,output); self.validate_epub(output)
        with zipfile.ZipFile(output) as archive:
            nav=c.xml(archive.read('OEBPS/nav.xhtml')); toc=next(n for n in nav.iter() if c.tag(n)=='nav'); item=c.first(toc,'ol')[0]
            self.assertEqual(len(c.children(item,'ol')),1)
            self.assertEqual([c.plain(c.first(n,'a')) for n in c.first(item,'ol')],['Подглава','Дополнение 0','Дополнение 1','Дополнение 2'])
    def test_fb2_body_tree_and_whitespace_are_exactly_preserved(self):
        book=ET.parse(self.source).getroot(); body=c.first(book,'body'); body.text='\n  '
        section=c.first(body,'section'); section.text='\n   '; section[-1].tail='\n  '
        title=c.first(section,'title'); title.text='\n     '; title[0].tail='\n   '
        # Block-level images are legal and must keep their position and ID.
        section[-1].append(c.element(c.FB,'image',**{'{'+c.XL+'}href':'#cover'}))
        source=self.root/'whitespace.fb2'; source.write_bytes(c.serialized(book)); epub=self.root/'whitespace.epub'; output=self.root/'whitespace-output.fb2'
        c.convert_book(source,epub); c.convert_book(epub,output); self.validate_fb2(output)
        after=ET.parse(output).getroot()
        self.assertEqual([shape(n) for n in c.children(book,'body')],[shape(n) for n in c.children(after,'body')])
    def test_epub_keeps_the_repeated_cover_in_reading_order(self):
        source = self.generic(first='<p id="first-cover"><img src="image.png" alt="Cover"/></p>',
                              second='<p><a href="chapter.xhtml#first-cover">Between the covers.</a></p>',
                              extra_metadata='<meta name="cover" content="i"/>')
        with zipfile.ZipFile(source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        opf = c.xml(files['OPS/package.opf'])
        c.first(opf, 'spine').append(c.element(c.OP, 'itemref', idref='c'))
        files['OPS/package.opf'] = c.serialized(opf)
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        output = self.root/'repeat-cover.fb2'
        report = c.convert_book(source, output)
        self.assertEqual(c.damaged_content_warnings(report['warnings']), [])
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        sections = c.children(c.first(book, 'body'), 'section')
        self.assertEqual(len(sections), 3)
        expected = ['image', 'text', 'image']
        self.assertEqual(['image' if list(section.iter('{' + c.FB + '}image')) else 'text'
                          for section in sections], expected)
        self.assertEqual(c.plain(sections[1]), 'Between the covers.')
        self.assertFalse(any(n.get('id') for n in sections[2].iter()))
        description = c.first(book, 'description')
        cover = c.first(c.first(description, 'title-info'), 'coverpage')
        self.assertTrue(c.fb2_cover_already_in_body(description, c.children(book,'body'), cover))

        streamed = self.root/'repeat-cover-streamed.fb2'
        c.epub_to_fb2(source, streamed, set(), stream_images={})
        self.validate_fb2(streamed)
        streamed_book = c.xml(streamed.read_bytes())
        self.assertEqual(shape(c.first(streamed_book, 'body')), shape(c.first(book, 'body')))
        self.assertEqual([c.plain(n) for n in c.children(streamed_book, 'binary')],
                         [c.plain(n) for n in c.children(book, 'binary')])

        epub = self.root/'repeat-cover.epub'
        c.convert_book(output, epub)
        c.validate_epub_output(epub)
        with zipfile.ZipFile(epub) as archive:
            self.assertNotIn('OEBPS/cover.xhtml', archive.namelist())
            copy = c.xhtml(archive.read('OEBPS/body-1.xhtml'))
            body = c.first(copy, 'body')
            self.assertEqual([c.tag(n) for n in body.iter() if c.tag(n) in {'img','a'}], ['img','a','img'])
            package = c.xml(archive.read('OEBPS/package.opf'))
            self.assertTrue(any(item.get('properties') == 'cover-image' for item in c.first(package,'manifest')))

    def test_epub2_cover_metadata_is_preserved(self):
        epub=self.generic('<p>Текст</p>','<p>Конец</p>',extra_metadata='<meta name="cover" content="i"/>')
        output=self.root/'cover.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); ti=c.first(c.first(book,'description'),'title-info'); cover=c.first(ti,'coverpage')
        self.assertIsNotNone(cover); identity=cover[0].get('{'+c.XL+'}href')[1:]
        binary=next(n for n in c.children(book,'binary') if n.get('id')==identity); self.assertEqual(base64.b64decode(c.plain(binary)),PNG)

    def test_epub_cover_outside_linear_spine_is_displayed_only_once(self):
        source = self.generic(first='<p><a href="cover.xhtml#publisher-cover">Open cover</a></p>',
                              second='<p>Next chapter</p>', extra_metadata='<meta name="cover" content="i"/>')
        with zipfile.ZipFile(source) as archive:
            original = {name: archive.read(name) for name in archive.namelist()}
        cover_page = (f'<html xmlns="{c.XH}"><head><title>Cover</title></head><body>'
                      '<p id="publisher-cover"><img src="image.png" alt="Cover"/></p>'
                      '<p>Publisher caption</p></body></html>').encode()

        for is_in_spine, has_guide in ((True, True), (False, True), (True, False)):
            with self.subTest(is_in_spine=is_in_spine, has_guide=has_guide):
                opf = c.xml(original['OPS/package.opf'])
                manifest = c.first(opf, 'manifest')
                manifest.append(c.element(c.OP, 'item', id='cover-page', href='cover.xhtml',
                                          **{'media-type': 'application/xhtml+xml'}))
                if is_in_spine:
                    c.first(opf, 'spine').insert(0, c.element(c.OP, 'itemref', idref='cover-page', linear='no'))
                if has_guide:
                    guide = c.element(c.OP, 'guide')
                    guide.append(c.element(c.OP, 'reference', type='cover', title='Cover', href='cover.xhtml'))
                    opf.append(guide)
                page = cover_page if has_guide else cover_page.replace(b'<p>Publisher caption</p>', b'')
                entries = {**original, 'OPS/package.opf': c.serialized(opf), 'OPS/cover.xhtml': page}
                case = self.root/f'cover-{is_in_spine}-{has_guide}.epub'
                with zipfile.ZipFile(case, 'w') as archive:
                    for name, data in entries.items():
                        archive.writestr(name, data)

                output = case.with_suffix('.fb2')
                c.convert_book(case, output)
                self.validate_fb2(output)
                book = c.xml(output.read_bytes())
                description, body = c.first(book, 'description'), c.first(book, 'body')
                metadata_cover = c.first(c.first(description, 'title-info'), 'coverpage')
                self.assertTrue(c.fb2_cover_already_in_body(description, [body], metadata_cover))
                [section_picture] = body.iter(f'{{{c.FB}}}image')
                self.assertEqual(section_picture.attrib, metadata_cover[0].attrib | {'alt': 'Cover'})
                cover_link = next(body.iter(f'{{{c.FB}}}a'))
                link_target = cover_link.get(f'{{{c.XL}}}href').removeprefix('#')
                self.assertIsNotNone(next((node for node in body.iter() if node.get('id') == link_target), None))
                if has_guide:
                    self.assertIn('Publisher caption', c.plain(body))

                reverse = self.root/f'reverse-{is_in_spine}-{has_guide}.epub'
                c.convert_book(output, reverse)
                c.validate_epub_output(reverse)
                with zipfile.ZipFile(reverse) as archive:
                    self.assertNotIn('OEBPS/cover.xhtml', archive.namelist())
                    document = c.xhtml(archive.read('OEBPS/body-1.xhtml'))
                    self.assertEqual(len(list(document.iter(f'{{{c.XH}}}img'))), 1)

    def test_epub_uses_declared_cover_path_without_embedding_html_as_an_image(self):
        source = self.generic(extra_metadata='<meta name="cover" content="image.png"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'</manifest>', b'<item id="web-copy" href="Images/cover.xhtml" media-type="image/xhtml"/></manifest>')
        entries['OPS/Images/cover.xhtml'] = b'<!doctype html><img src="https://example.test/cover.png">'
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        for streaming in (False, True):
            with self.subTest(streaming=streaming):
                output = self.root / f'cover-path-{streaming}.fb2'
                report = c.convert_book(source, output, streaming=streaming)
                self.validate_fb2(output)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                book = c.xml(output.read_bytes())
                cover = next(book.iter('{' + c.FB + '}coverpage'))[0]
                binary, = c.children(book, 'binary')
                self.assertEqual(cover.get('{' + c.XL + '}href'), '#' + binary.get('id'))
                self.assertEqual(binary.get('content-type'), 'image/png')
                self.assertEqual(base64.b64decode(c.plain(binary)), PNG)

    def test_epub_xhtml_cover_outside_spine_keeps_cover_page_and_original_image(self):
        source = self.generic(first='<h1>Chapter</h1><p><a href="notes.xhtml#caption">Обложка</a></p>',
                              second='<p><img src="image.png" alt="Картинка обложки"/></p>'
                                     '<p id="caption">Подпись издателя</p>',
                              notes_in_spine=False, extra_metadata='<meta name="cover" content="n"/>')
        before = digest(source)
        output = self.root/'publisher-cover.fb2'
        report = c.convert_book(source, output)
        self.validate_fb2(output)
        self.assertEqual(c.damaged_content_warnings(report['warnings']), [])
        book = ET.parse(output).getroot()
        image_link = '{'+c.XL+'}href'
        cover = c.first(c.first(c.first(book,'description'),'title-info'),'coverpage')
        body = c.first(book,'body')
        cover_section = body[0]
        cover_image = next(cover_section.iter('{'+c.FB+'}image'))
        self.assertEqual(cover[0].get(image_link), cover_image.get(image_link))
        self.assertEqual(cover[0].get('alt'), 'Картинка обложки')
        self.assertIn('Подпись издателя', c.plain(cover_section))
        self.assertIn('Chapter', c.plain(body[1]))
        caption = next(n for n in cover_section.iter('{'+c.FB+'}p') if c.plain(n) == 'Подпись издателя')
        link = next(body.iter('{'+c.FB+'}a'))
        self.assertEqual(link.get(image_link), '#'+caption.get('id'))
        binary, = c.children(book,'binary')
        self.assertEqual(cover[0].get(image_link), '#'+binary.get('id'))
        self.assertEqual(base64.b64decode(binary.text), PNG)
        self.assertEqual(digest(source), before)

    def test_epub_cover_with_multiple_images_keeps_the_cover_page_without_guessing(self):
        source = self.generic(first='<p>Текст книги</p>',
                              second='<p><img src="image.png"/><img src="border.png"/></p>',
                              notes_in_spine=False, extra_metadata='<meta name="cover" content="n"/>')
        with zipfile.ZipFile(source,'a') as archive:
            archive.writestr('OPS/border.png', PNG)
        output = self.root/'two-cover-images.fb2'
        report = c.convert_book(source, output, allow_partial_epub=True)
        book = c.xml(output.read_bytes())
        self.assertIsNone(c.first(c.first(c.first(book,'description'),'title-info'),'coverpage'))
        body = c.first(book,'body')
        self.assertEqual(len(list(body[0].iter('{'+c.FB+'}image'))), 2)
        self.assertIn('Текст книги', c.plain(body[1]))
        self.assertIn('Страница обложки EPUB перенесена в книгу без отдельной обложки FB2.',
                      c.damaged_content_warnings(report['warnings']))

    def test_repeated_line_breaks_keep_blank_line(self):
        epub=self.generic('<p>Один<br/><br/>Два</p>','<p>Конец</p>'); output=self.root/'breaks.fb2'
        c.convert_book(epub,output); self.validate_fb2(output)
        body=c.first(ET.parse(output).getroot(),'body'); section=next(n for n in body.iter() if c.tag(n)=='section' and any(c.tag(p)=='p' and c.plain(p)=='Один' for p in n))
        self.assertEqual([(c.tag(n),c.plain(n)) for n in section], [('p','Один'),('empty-line',''),('p','Два')])
    def test_output_race_keeps_other_writer_file(self):
        output=self.root/'race.epub'; name='rename' if os.name=='nt' else 'link'; publish=getattr(c.os,name)
        def competing_writer(source,destination):
            Path(destination).write_bytes(b'another writer'); return publish(source,destination)
        with mock.patch.object(c.os,name,competing_writer):
            with self.assertRaises(FileExistsError): c.convert_book(self.source,output)
        self.assertEqual(output.read_bytes(),b'another writer')
    def test_duplicate_epub_resources_fail_without_output(self):
        import warnings
        source=self.root/'duplicate.epub'
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(source,'w') as archive:
                archive.writestr('duplicate.xhtml','first'); archive.writestr('duplicate.xhtml','second')
        with self.assertRaises(c.ConversionError): c.convert_book(source,self.root/'duplicate.fb2')
        self.assertFalse((self.root/'duplicate.fb2').exists())
    def test_same_catalog_entry_is_coalesced_but_ambiguity_fails(self):
        for ambiguous in [False,True]:
            source=self.generic('<p>Текст</p>','<p>Конец</p>')
            with zipfile.ZipFile(source) as archive: resources={n:archive.read(n) for n in archive.namelist()}
            duplicate='<item id="c" href="'+('notes.xhtml' if ambiguous else 'chapter.xhtml')+'" media-type="application/xhtml+xml"/>'
            resources['OPS/package.opf']=resources['OPS/package.opf'].replace(b'</manifest>',duplicate.encode()+b'</manifest>')
            with zipfile.ZipFile(source,'w') as archive:
                for name,data in resources.items(): archive.writestr(name,data)
            output=self.root/('catalog-'+str(ambiguous)+'.fb2')
            if ambiguous:
                with self.assertRaises(c.ConversionError): c.convert_book(source,output)
                self.assertFalse(output.exists())
            else:
                result=c.convert_book(source,output); self.validate_fb2(output)
                self.assertTrue(any('одинаковые' in warning for warning in result['warnings']))
    def test_single_raster_in_svg_keeps_bytes_and_transforms_require_partial_export(self):
        svg='<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="'+c.XL+'" viewBox="0 0 1 1"><title>Описание</title><image width="1" height="1" xlink:href="image.png"/></svg>'
        source=self.generic('<p>Текст</p>'+svg,'<p>Конец</p>'); output=self.root/'svg.fb2'
        c.convert_book(source,output); self.validate_fb2(output); book=ET.parse(output).getroot()
        self.assertEqual(base64.b64decode(c.plain(c.children(book,'binary')[0])),PNG)
        image=next(c.first(book,'body').iter('{'+c.FB+'}image')); self.assertEqual(image.get('alt'),'Описание')
        for label, style, viewport, succeeds in [
            ('responsive', 'max-width: 100%;', '0 0 1 1', True),
            ('cover-height', 'height: 100%; text-align: center;', '0 0 1 1', True),
            ('cover-opacity', 'height: 100%; opacity: .5;', '0 0 1 1', False),
            ('cropped', 'max-width: 100%;', '0 0 2 1', False),
            ('narrow', 'max-width: 80%;', '0 0 1 1', False),
            ('rotated', 'max-width: 100%; transform: rotate(90deg)', '0 0 1 1', False),
        ]:
            wrapped = svg.replace('viewBox="0 0 1 1"', 'viewBox="'+viewport+'"')
            wrapped = wrapped.replace('<image ', '<image style="'+style+'" ')
            source = self.generic('<p>Текст</p>'+wrapped, '<p>Конец</p>')
            result = self.root/(label+'.fb2')
            if succeeds:
                c.convert_book(source,result); self.validate_fb2(result)
                raster = c.children(ET.parse(result).getroot(),'binary')[0]
                self.assertEqual(base64.b64decode(c.plain(raster)),PNG)
            else:
                with self.assertRaises(c.ConversionError): c.convert_book(source,result)
                self.assertFalse(result.exists())
                converted = c.convert_book(source, result, allow_partial_epub=True)
                self.validate_fb2(result)
                raster = c.children(ET.parse(result).getroot(), 'binary')[0]
                self.assertEqual(base64.b64decode(c.plain(raster)), PNG)
                self.assertTrue(any(notice.startswith('Оформление иллюстрации SVG упрощено')
                                    for notice in c.damaged_content_warnings(converted['warnings'])))
        for label, tag, offset, succeeds in (
            ('zero-offset', '<image ', '0 0', True),
            ('zero-offset-viewport', '<svg ', '+0, -0.0', True),
            ('shifted', '<image ', '-0.5 0', False),
            ('shifted-viewport', '<svg ', '1 0', False),
        ):
            with self.subTest(offset=offset, element=tag):
                wrapped = svg.replace(tag, f'{tag}transform="translate({offset})" ')
                source = self.generic('<p>Текст</p>' + wrapped, '<p>Конец</p>')
                result = self.root / (label + '.fb2')
                if succeeds:
                    report = c.convert_book(source, result)
                    self.validate_fb2(result)
                    self.assertFalse(c.damaged_content_warnings(report['warnings']))
                    self.assertEqual(base64.b64decode(c.first(c.xml(result.read_bytes()), 'binary').text), PNG)
                else:
                    with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                        c.convert_book(source, result)
                    self.assertFalse(result.exists())
        source=self.generic('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0,0L1,1"/></svg>','<p>Конец</p>')
        with self.assertRaisesRegex(c.ConversionError, 'Выберите «Оставить EPUB»'):
            c.convert_book(source,self.root/'vector.fb2')
        self.assertFalse((self.root/'vector.fb2').exists())

    def test_svg_cover_keeps_its_raster_when_percentage_height_uses_intrinsic_ratio(self):
        source = self.generic(second='<p>Text</p>', extra_metadata='<meta name="cover" content="c"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        wrapper = (f'<html xmlns="{c.XH}"><head><title>Cover</title>{{head}}</head><body><div>'
                   f'<svg xmlns="{c.SVG}" width="100%" height="100%" viewBox="0 0 1 1" preserveAspectRatio="none">'
                   '<image width="1" height="1" href="image.png" alt="Cover"/>'
                   '</svg></div></body></html>')
        for label, head, source_layout, partial in (
            ('intrinsic', '<style>@page {margin: 0pt} body { padding:0; text-align: center }</style>', '', False),
            ('fixed-height', '<style>html, body, div {height:100%}</style>', '', True),
            ('linked', '<link rel="stylesheet" href="cover.css"/>', '', True),
            ('pre-paginated', '', '<meta property="rendition:layout">pre-paginated</meta>', True),
        ):
            with self.subTest(layout=label):
                candidate = self.root/(label+'.epub')
                candidate_entries = entries | {'OPS/chapter.xhtml': wrapper.format(head=head).encode('utf-8'),
                                               'OPS/cover.css': b'div {height: 300px; overflow: hidden}'}
                if source_layout:
                    candidate_entries['OPS/package.opf'] = candidate_entries['OPS/package.opf'].replace(
                        b'</metadata>', source_layout.encode('utf-8') + b'</metadata>')
                with zipfile.ZipFile(candidate, 'w') as archive:
                    for path, data in candidate_entries.items():
                        archive.writestr(path, data)
                output = candidate.with_suffix('.fb2')
                if partial:
                    with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                        c.convert_book(candidate, output)
                    self.assertFalse(output.exists())
                else:
                    report = c.convert_book(candidate, output)
                    self.validate_fb2(output)
                    [binary] = c.children(c.xml(output.read_bytes()), 'binary')
                    self.assertEqual(base64.b64decode(binary.text), PNG)
                    self.assertEqual(c.damaged_content_warnings(report['warnings']), [])

    def test_linked_svg_cover_styles_preserve_verified_viewports(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        source = self.generic(second='<p>Text</p>', extra_metadata='<meta name="cover" content="c"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {path: archive.read(path) for path in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'</manifest>', b'<item id="publisher-css" href="styles/cover.css" media-type="text/css"/></manifest>')
        wrapper = (f'<html xmlns="{c.XH}"><head><title>Cover</title>'
                   '<link rel="stylesheet" type="text/css" href="styles/cover.css"/>'
                   '</head><body class="page"><div class="wrapper">'
                   f'<svg xmlns="{c.SVG}" width="100%" height="100%" viewBox="0 0 {{width}} 1" '
                   'preserveAspectRatio="none" class="cover">'
                   '<image width="{width}" height="1" href="image.png" id="art" alt="Cover"/>'
                   '</svg></div></body></html>')
        safe = ('@page {margin-top: 5pt} .page {display:block; font-size:1em; margin:0 5pt; padding:0} '
                'div.wrapper {display:block} .cover {width:auto; height:auto} '
                '.unrelated {width:10px; transform:rotate(90deg); font-family:"Serif; {notes}"} ')
        for label, extra, width, safe_to_export in (
            ('matching', '', 1, True),
            ('different-ratio', '', 2, True),
            ('fixed-viewport', '.cover {height:50px}', 1, False),
            ('clipping-container', '.wrapper {height:30px; overflow:hidden}', 1, False),
            ('altered-raster', 'image#art {opacity:.5}', 1, False),
            ('quoted-target', 'image#art {filter:url("blocked.svg#art")}', 1, False),
            ('unclosed-string', '.unrelated {font-family:"Incomplete\n} .cover {height:40px}', 1, False),
            ('conditional-rule', '@media screen { .cover {height:40px} }', 1, False),
            ('unresolved-import', '@import url(other.css);', 1, False),
        ):
            with self.subTest(label=label):
                candidate = self.root/(label+'.epub')
                with zipfile.ZipFile(candidate, 'w') as archive:
                    for name, data in (entries | {'OPS/chapter.xhtml': wrapper.format(width=width).encode(),
                                                  'OPS/styles/cover.css': (safe + extra).encode()}).items():
                        archive.writestr(name, data)
                output = candidate.with_suffix('.fb2')
                if safe_to_export:
                    if width != 1 and not (tools / 'kfx-export' / 'resvg.exe').is_file():
                        self.skipTest('SVG renderer from KfxExport is required')
                    report = c.convert_book(candidate, output, tools_root=tools)
                    self.assertEqual(c.damaged_content_warnings(report['warnings']), [])
                    self.validate_fb2(output)
                    book = c.xml(output.read_bytes())
                    saved = {'#' + node.get('id'): base64.b64decode(node.text) for node in c.children(book, 'binary')}
                    self.assertIn(PNG, saved.values())
                    [cover] = c.first(book, 'body').iter(f'{{{c.FB}}}image')
                    image = saved[cover.get(f'{{{c.XL}}}href')]
                    self.assertEqual(c.raster_header_size(image), (width, 1))
                    if width == 1:
                        self.assertEqual(image, PNG)
                else:
                    with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                        c.convert_book(candidate, output)
                    self.assertFalse(output.exists())

    def test_svg_single_picture_presentation_attributes_require_consent(self):
        output = self.root / 'presentation.fb2'
        for attribute in ('opacity="0.5"', 'visibility="hidden"', 'preserveAspectRatio="xMidYMid slice"'):
            with self.subTest(attribute=attribute):
                picture = (f'<svg xmlns="{c.SVG}" viewBox="0 0 1 1">'
                           f'<image {attribute} width="1" height="1" href="image.png"/></svg>')
                source = self.generic('<p>Текст</p>' + picture, '<p>Конец</p>')
                with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                    c.convert_book(source, output)
                self.assertFalse(output.exists())

    def test_reflowable_svg_cover_preserves_viewport_and_original_raster(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if not (tools / 'kfx-export' / 'resvg.exe').is_file():
            self.skipTest('SVG renderer from KfxExport is required')
        source = self.generic(second='<p>Text</p>', extra_metadata='<meta name="cover" content="c"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/chapter.xhtml'] = (
            f'<html xmlns="{c.XH}"><head><title>Cover</title></head><body><div>'
            f'<svg xmlns="{c.SVG}" width="100%" height="100%" viewBox="0 0 4 2" preserveAspectRatio="none">'
            '<image width="4" height="2" href="image.png" alt="Cover"/></svg></div></body></html>').encode()
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        output = self.root / 'intrinsic-viewbox.fb2'
        report = c.convert_book(source, output, tools_root=tools, streaming=True)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        self.validate_fb2(output)
        book = c.xml(output.read_bytes())
        cover = next(book.iter(f'{{{c.FB}}}coverpage'))[0]
        image, = c.first(book, 'body').iter(f'{{{c.FB}}}image')
        link = f'{{{c.XL}}}href'
        self.assertEqual(image.get(link), cover.get(link))
        pictures = {'#' + node.get('id'): base64.b64decode(node.text) for node in c.children(book, 'binary')}
        self.assertIn(PNG, pictures.values())
        self.assertEqual(c.raster_header_size(pictures[image.get(link)]), (4, 2))

    def test_reflowable_svg_cover_keeps_its_trailing_caption(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if not (tools / 'kfx-export' / 'resvg.exe').is_file():
            self.skipTest('SVG renderer from KfxExport is required')
        source = self.generic(second='<p>Chapter text</p>', extra_metadata='<meta name="cover" content="c"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        normal_flow = 'float:none; margin:10px 0px; text-align:center'
        for caption_style, width in ((normal_flow, 'width="100%"'), (normal_flow, ''),
                                     ('position:absolute; top:0; left:0', 'width="100%"')):
            with self.subTest(caption_style=caption_style, width=width):
                entries['OPS/chapter.xhtml'] = (
                    f'<html xmlns="{c.XH}"><head><title>Cover</title></head><body><div>'
                    f'<svg xmlns="{c.SVG}" {width} height="100%" viewBox="0 0 4 2" preserveAspectRatio="none">'
                    '<image width="4" height="2" href="image.png"/></svg></div>'
                    f'<div style="{caption_style}"><p><a href="https://example.org/art">'
                    '<em>Source caption</em></a></p></div></body></html>').encode()
                with zipfile.ZipFile(source, 'w') as archive:
                    for name, data in entries.items():
                        archive.writestr(name, data)
                destination = self.root / 'caption.fb2'
                if caption_style.startswith('position'):
                    with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                        c.convert_book(source, destination, tools_root=tools)
                    self.assertFalse(destination.exists())
                    continue
                report = c.convert_book(source, destination, tools_root=tools, streaming=True)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                self.validate_fb2(destination)
                book = c.xml(destination.read_bytes())
                body = c.first(book, 'body')
                picture, = body.iter(f'{{{c.FB}}}image')
                link, = body.iter(f'{{{c.FB}}}a')
                self.assertEqual(c.plain(link), 'Source caption')
                self.assertEqual(link.get(f'{{{c.XL}}}href'), 'https://example.org/art')
                self.assertLess(list(body.iter()).index(picture), list(body.iter()).index(link))
                artwork = next(entry for entry in c.children(book, 'binary')
                               if '#' + entry.get('id') == picture.get(f'{{{c.XL}}}href'))
                self.assertEqual(c.raster_header_size(base64.b64decode(artwork.text)), (4, 2))
                self.assertIn(PNG, [base64.b64decode(entry.text) for entry in c.children(book, 'binary')])
                destination.unlink()

    def test_percentage_svg_cover_round_trips_width_and_correct_raster_type(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if not (tools / 'kfx-export' / 'resvg.exe').is_file():
            self.skipTest('SVG renderer from KfxExport is required')
        page = (
            f'<div><svg xmlns="{c.SVG}" width="65.25%" height="100%" viewBox="0 0 4 2" preserveAspectRatio="none">'
            '<image width="4" height="2" href="image.png"/></svg></div>')
        source = self.generic(first=page, second='<p>First chapter text</p>', extra_metadata='<meta name="cover" content="i"/>')
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(b'media-type="image/png"', b'media-type="image/jpeg"')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        original = digest(source)
        destination = self.root / 'percentage-width.fb2'
        report = c.convert_book(source, destination, tools_root=tools, streaming=True)
        self.validate_fb2(destination)
        warnings = c.damaged_content_warnings(report['warnings'])
        self.assertEqual(len(warnings), 1)
        self.assertIn('Размеры размещения иллюстраций сохранены в FB2', warnings[0])

        marker = c.FB2_IMAGE_WIDTH_PREFIX + '6525'
        book = c.xml(destination.read_bytes())
        style, = [node for node in book.iter(f'{{{c.FB}}}style') if node.get('name') == marker]
        image, = c.children(style, 'image')
        cover, = next(book.iter(f'{{{c.FB}}}coverpage'))
        self.assertEqual(cover.get(f'{{{c.XL}}}href'), image.get(f'{{{c.XL}}}href'))
        self.assertTrue(any(node.get('info-type') == c.FB2_EPUB_COVER_IN_BODY
                            for node in c.children(c.first(book,'description'), 'custom-info')))
        assets = {'#' + node.get('id'): node for node in c.children(book, 'binary')}
        self.assertIn(f'style[name="{marker}"] image{{width:65.25%;', c.first(book,'stylesheet').text)
        self.assertEqual(c.raster_header_size(base64.b64decode(assets[image.get(f'{{{c.XL}}}href')].text)), (4, 2))
        originals = [node for node in assets.values() if base64.b64decode(node.text) == PNG]
        self.assertEqual([node.get('content-type') for node in originals], ['image/png'])

        epub = self.root / 'percentage-width.epub'
        c.convert_book(destination, epub, tools_root=tools)
        with zipfile.ZipFile(epub) as archive:
            layouts = [
                node for filename in archive.namelist() if filename.endswith('.xhtml')
                for node in c.xml(archive.read(filename)).iter(f'{{{c.XH}}}img')
                if marker in node.get('class', '').split()
            ]
        self.assertEqual(len(layouts), 1)
        self.assertEqual(layouts[0].get('style'), c.relative_image_css('65.25%'))
        roundtrip = self.root / 'percentage-width-roundtrip.fb2'
        c.convert_book(epub, roundtrip, tools_root=tools)
        self.validate_fb2(roundtrip)
        self.assertTrue(any(node.get('name') == marker for node in c.xml(roundtrip.read_bytes()).iter(f'{{{c.FB}}}style')))
        self.assertEqual(digest(source), original)

    def test_svg_raster_cover_with_solid_background_requests_renderer(self):
        source = self.svg_background_cover()
        output = self.root / 'rendered.fb2'
        with self.assertRaises(c.ComponentRequired) as required:
            c.convert_book(source, output, tools_root=self.root / 'empty-tools')
        self.assertEqual(required.exception.component, 'KfxExport')
        self.assertFalse(output.exists())

    def test_svg_raster_cover_with_solid_background_survives_fb2_export(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if not (tools / 'kfx-export' / 'resvg.exe').is_file():
            self.skipTest('SVG renderer from KfxExport is required')
        source = self.svg_background_cover()
        output = self.root / 'rendered.fb2'
        report = c.convert_book(source, output, tools_root=tools)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        streamed = self.root / 'streamed-rendered.fb2'
        c.epub_to_fb2(source, streamed, set(), tools_root=tools, stream_images={})
        covers = []
        for path in (output, streamed):
            self.validate_fb2(path)
            book = ET.parse(path).getroot()
            [image] = list(c.first(book, 'body').iter(f'{{{c.FB}}}image'))
            self.assertEqual(image.get('alt'), 'Описание')
            identifier = image.get(f'{{{c.XL}}}href').removeprefix('#')
            binary = next(node for node in c.children(book, 'binary') if node.get('id') == identifier)
            covers.append(base64.b64decode(binary.text))
        self.assertEqual(covers[0], covers[1])
        self.assertEqual(c.raster_header_size(covers[0]), (3, 1))

    def test_cropped_svg_cover_uses_the_same_view_in_fb2_metadata_and_body(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if not (tools / 'kfx-export' / 'resvg.exe').is_file():
            self.skipTest('SVG renderer from KfxExport is required')
        source = self.generic(first=(f'<svg xmlns="{c.SVG}" viewBox="0 1 2 2" width="100%" height="100%">'
                                     '<image width="2" height="4" href="image.png" alt="Обложка"/></svg>'),
                              second='<p>Текст книги</p>', extra_metadata='<meta name="cover" content="i"/>')
        svg_cover = bytes.fromhex('ff0000ff 00ff00ff 0000ffff 00ffffff')
        rows = b''.join(b'\0' + svg_cover[index:index + 4] * 2 for index in range(0, len(svg_cover), 4))
        raster = (PNG[:8] + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 4, 8, 6, 0, 0, 0)) +
                  png_chunk(b'IDAT', zlib.compress(rows)) + png_chunk(b'IEND', b''))
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/image.png'] = raster
        entries['OPS/package.opf'] = entries['OPS/package.opf'].replace(
            b'</package>', b'<guide><reference type="cover" href="chapter.xhtml"/></guide></package>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        before = digest(source)
        output = self.root / 'cropped.fb2'
        with self.assertRaises(c.ComponentRequired) as required:
            c.convert_book(source, output, tools_root=self.root / 'empty-tools')
        self.assertEqual(required.exception.component, 'KfxExport')
        self.assertFalse(output.exists())

        for streaming in (False, True):
            with self.subTest(streaming=streaming):
                output = self.root / f'cropped-{streaming}.fb2'
                report = c.convert_book(source, output, tools_root=tools, streaming=streaming)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                self.validate_fb2(output)
                book = c.xml(output.read_bytes())
                cover = next(book.iter(f'{{{c.FB}}}coverpage'))
                body = c.first(book, 'body')
                self.assertTrue(c.fb2_cover_already_in_body(c.first(book, 'description'), [body], cover))
                [visible] = list(body.iter(f'{{{c.FB}}}image'))
                self.assertEqual(visible.get('alt'), 'Обложка')
                pictures = {'#' + node.get('id'): base64.b64decode(node.text) for node in c.children(book, 'binary')}
                self.assertEqual(len(pictures), 2)
                self.assertIn(raster, pictures.values())
                self.assertEqual(c.raster_header_size(pictures[visible.get(f'{{{c.XL}}}href')]), (2, 2))
        self.assertEqual(digest(source), before)

    def test_svg_image_percentage_sizing_keeps_viewport_and_original_raster(self):
        wrapper = (f'<svg xmlns="{c.SVG}" viewBox="0 0 20 20" width="100%" height="99%">'
                   '<image width="20" height="20" style="height: 60%; width: 75.5%; text-align: center" '
                   'href="image.png" alt="Cover"/></svg>')
        parsed = c.xhtml(wrapper.encode())
        drawing = c.svg_cropped_raster(parsed, parsed[0], c.svg_picture_sizing(parsed, parsed[0]))
        self.assertEqual((drawing.get('width'), drawing.get('height')), ('20', '20'))
        self.assertEqual((drawing[0].get('width'), drawing[0].get('height')), ('75.5%', '60%'))
        source = self.generic(first=wrapper, second='<p>Text</p>')
        output = self.root / 'sized.fb2'
        with self.assertRaises(c.ComponentRequired) as required:
            c.convert_book(source, output, tools_root=self.root / 'empty-tools')
        self.assertEqual(required.exception.component, 'KfxExport')
        self.assertFalse(output.exists())
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', MODULE.parents[1]))
        if (tools / 'kfx-export' / 'resvg.exe').is_file():
            report = c.convert_book(source, output, tools_root=tools)
            self.assertFalse(c.damaged_content_warnings(report['warnings']))
            self.validate_fb2(output)
            book = c.xml(output.read_bytes())
            [visible] = c.first(book, 'body').iter(f'{{{c.FB}}}image')
            assets = {'#' + node.get('id'): base64.b64decode(node.text) for node in c.children(book, 'binary')}
            self.assertIn(PNG, assets.values())
            self.assertEqual(c.raster_header_size(assets[visible.get(f'{{{c.XL}}}href')]), (20, 20))
        for style in ('height: 60%; opacity: .5', 'height: 60%; transform: rotate(5deg)', 'height: 0%'):
            with self.subTest(style=style):
                variant = self.generic(first=wrapper.replace('height: 60%; width: 75.5%; text-align: center', style),
                                       second='<p>Text</p>')
                refused = self.root / 'unsupported.fb2'
                with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
                    c.convert_book(variant, refused, tools_root=tools)
                self.assertFalse(refused.exists())
        with zipfile.ZipFile(source) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['OPS/chapter.xhtml'] = entries['OPS/chapter.xhtml'].replace(
            b'<body>', b'<head><style>svg image {opacity: .5}</style></head><body>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        refused = self.root / 'compound-selector.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'Преобразованное изображение SVG'):
            c.convert_book(source, refused, tools_root=tools)
        self.assertFalse(refused.exists())

    def svg_background_cover(self):
        svg = (f'<svg xmlns="{c.SVG}" xmlns:xlink="{c.XL}" viewBox="0 0 3 1" width="100%" height="100%">'
               '<title>Описание</title><rect width="3" height="100%" fill="#000007"/>'
               '<image width="3" height="1" transform="translate(0 0)" xlink:href="image.png"/></svg>')
        return self.generic('<p>Текст</p>' + svg, '<p>Конец</p>')

    def test_percent_encoded_resource_paths_and_unicode_anchors(self):
        source=self.generic('<h1 id="глава">Заголовок</h1><p><a href="#%D0%B3%D0%BB%D0%B0%D0%B2%D0%B0">К заголовку</a><img src="picture%20space.png"/></p>','<p>Конец</p>')
        with zipfile.ZipFile(source) as archive: resources={n:archive.read(n) for n in archive.namelist()}
        resources['OPS/picture space.png']=resources.pop('OPS/image.png'); resources['OPS/package.opf']=resources['OPS/package.opf'].replace(b'href="image.png"',b'href="picture%20space.png"')
        with zipfile.ZipFile(source,'w') as archive:
            for name,data in resources.items(): archive.writestr(name,data)
        output=self.root/'paths.fb2'; c.convert_book(source,output); self.validate_fb2(output); book=ET.parse(output).getroot()
        link=next(book.iter('{'+c.FB+'}a')); identity=link.get('{'+c.XL+'}href')[1:]
        self.assertTrue(any(n.get('id')==identity and c.plain(n)=='Заголовок' for n in book.iter()))
        self.assertEqual(base64.b64decode(c.plain(c.children(book,'binary')[0])),PNG)
    def test_unused_local_manifest_images_are_retained(self):
        source=self.generic('<p>Текст без картинки</p>','<p>Конец</p>'); output=self.root/'unused-image.fb2'
        c.convert_book(source,output); self.validate_fb2(output)
        binaries=c.children(ET.parse(output).getroot(),'binary'); self.assertEqual(len(binaries),1)
        self.assertEqual(base64.b64decode(c.plain(binaries[0])),PNG)
    def test_fb2_font_urls_do_not_create_broken_epub(self):
        source=self.root/'font-css.fb2'; text=self.source.read_text(encoding='utf-8').replace('.special {color:purple}','@font-face{font-family:Publisher;src:url(fonts/missing.ttf)} .special {color:purple}'); source.write_text(text,encoding='utf-8')
        output=self.root/'font-css.epub'; result=c.convert_book(source,output); self.validate_epub(output)
        self.assertTrue(any('внешних шрифтов' in warning for warning in result['warnings']))
        with zipfile.ZipFile(output) as archive:
            css=archive.read('OEBPS/book.css').decode(); self.assertNotIn('missing.ttf',css); self.assertIn('color:purple',css)
    def test_unknown_css_resource_fails_instead_of_broken_output(self):
        source=self.root/'image-css.fb2'; text=self.source.read_text(encoding='utf-8').replace('.special {color:purple}', 'body{background-image:url(missing.png)}'); source.write_text(text,encoding='utf-8')
        with self.assertRaises(c.ConversionError): c.convert_book(source,self.root/'image-css.epub')
        self.assertFalse((self.root/'image-css.epub').exists())
    def test_untitled_section_wrappers_do_not_distort_toc_hierarchy(self):
        book=ET.parse(self.source).getroot(); body=c.first(book,'body'); wrapped=[]
        for index,section in enumerate(list(body)):
            for depth in range(3+index*2):
                container=c.element(c.FB,'section'); container.append(section); section=container
            wrapped.append(section)
        body[:]=wrapped; source=self.root/'wrapped.fb2'; source.write_bytes(c.serialized(book)); output=self.root/'wrapped.epub'
        self.validate_fb2(source); c.convert_book(source,output); self.validate_epub(output)
        with zipfile.ZipFile(output) as archive:
            nav=c.xml(archive.read('OEBPS/nav.xhtml')); toc=next(n for n in nav.iter() if c.tag(n)=='nav'); contents=c.first(toc,'ol')
            self.assertEqual([c.plain(c.first(n,'a')) for n in contents],['Первая глава','Вторая глава','6'])
            self.assertEqual([c.plain(c.first(n,'a')) for n in c.first(contents[0],'ol')],['Подглава'])

if __name__=='__main__': unittest.main(verbosity=2)

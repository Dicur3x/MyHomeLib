"""Independent text/structure/resource oracles for additional book inputs."""
from pathlib import Path
import base64
import hashlib
import importlib.util
import os
import posixpath
import subprocess
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib

spec = importlib.util.spec_from_file_location('convert_book', Path(__file__).resolve().parents[1] / 'convert_book.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
PNG = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\x12\x34\x56\xff')) + chunk(b'IEND', b'')
TEXT = 'Ё, ї, є, ґ, ў. English. 😀'
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'


def docx(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Глава один</w:t></w:r></w:p>
        <w:p><w:r><w:t>{TEXT}</w:t></w:r><w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>Жирный курсив</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>
        <w:p><w:bookmarkStart w:id="4" w:name="point"/><w:r><w:drawing><a:blip r:embed="image"/></w:drawing></w:r></w:p>
        <w:p><w:hyperlink w:anchor="point"><w:r><w:t>Ссылка</w:t></w:r></w:hyperlink></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Подглава</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Ячейка</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Глава два</w:t></w:r></w:p>
        </w:body></w:document>''')
        z.writestr('word/_rels/document.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="image" Target="/word/media/p.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/></Relationships>')
        z.writestr('word/styles.xml', f'<w:styles xmlns:w="{W}"><w:style w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style><w:style w:styleId="Heading2"><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style></w:styles>')
        z.writestr('word/footnotes.xml', f'<w:footnotes xmlns:w="{W}"><w:footnote w:id="2"><w:p><w:r><w:t>Точная сноска</w:t></w:r></w:p></w:footnote></w:footnotes>')
        z.writestr('word/media/p.png', PNG)
        z.writestr('docProps/core.xml', '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Документ</dc:title><dc:creator>Автор</dc:creator></cp:coreProperties>')


def odt(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('content.xml', f'''<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:xlink="http://www.w3.org/1999/xlink">
        <office:automatic-styles><style:style style:name="B"><style:text-properties fo:font-weight="bold" fo:font-style="italic"/></style:style></office:automatic-styles>
        <office:body><office:text><text:h text:outline-level="1">Глава один</text:h><text:p>{TEXT}<text:span text:style-name="B">Жирный курсив</text:span><text:note text:id="n1"><text:note-citation>1</text:note-citation><text:note-body><text:p>Точная сноска</text:p></text:note-body></text:note></text:p>
        <text:p><draw:frame><draw:image xlink:href="Pictures/p.png"/></draw:frame></text:p><text:h text:outline-level="2">Подглава</text:h><text:h text:outline-level="1">Глава два</text:h></office:text></office:body></office:document-content>''')
        z.writestr('Pictures/p.png', PNG)


def fb3(path):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('fb3/body.xml', f'''<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body" id="00000000-0000-0000-0000-000000000001"><section id="s1"><title><p>Глава один</p></title><section id="s1-text"><p>{TEXT} <strong><em>Жирный курсив</em></strong> <note href="n1">1</note></p><p><img src="image"/></p></section><section id="s1-sub"><title><p>Подглава</p></title><p>Подглавный текст.</p></section></section><section id="s2"><title><p>Глава два</p></title><p>Конец</p></section><notes><notebody id="n1"><p>Точная сноска</p></notebody></notes></fb3-body>''')
        z.writestr('fb3/_rels/body.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="image" Target="images/p.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/></Relationships>')
        z.writestr('fb3/images/p.png', PNG)
        z.writestr('fb3/description.xml', '''<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description"
 id="00000000-0000-0000-0000-000000000001" version="2.5">
<title><main>FB3 книга</main><alternatives>Другое название</alternatives></title>
<fb3-relations>
  <subject link="author" id="00000000-0000-0000-0000-000000000003"><title><main>Анна Морозова</main></title>
    <first-name>Анна</first-name><last-name>Морозова</last-name></subject>
  <subject link="translator" id="00000000-0000-0000-0000-000000000002"><title><main>Человек</main></title>
    <last-name>Человек</last-name></subject>
</fb3-relations><lang>ru</lang>
<paper-publish-info title="Бумажное издание" publisher="Издательство Ёжик" city="Киев" year="2025"><isbn>5-699-01480-2</isbn></paper-publish-info>
<paper-publish-info title="Другое издание" publisher="Второе издательство" city="Одесса" year="2026"/>
<annotation><p><strong>Мысль</strong> — <em>описание</em> книги.</p><br/><p><a href="#s1">Первая глава</a>.
<a href="https://example.invalid/book">Сайт книги</a>.</p></annotation></fb3-description>''')


class TextInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='HomeLibRu-text-test-'); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()

    def test_md5_checksums_are_not_books(self):
        source = self.root / 'checksums.md5'
        output = self.root / 'copy.epub'
        source.write_text('1303695e4372a76fdb2d605daae1b3e6 *Книга.pdf\n', encoding='utf-8-sig')
        self.assertEqual(c.detect_input(source), '.md5')
        with self.assertRaisesRegex(c.ConversionError, 'контрольных сумм MD5'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())
        source.write_text(TEXT, encoding='utf-8')
        self.assertEqual(c.detect_input(source), '.txt')
        self.outputs(source, TEXT)

    def test_leading_angle_bracket_url_is_preserved_as_plain_text(self):
        source = self.root / 'attributed.txt'
        link = '<https://example.test/books/>'
        paragraph = 'Обычный текст после ссылки.'
        source.write_bytes((link + '\r\n\r\n' + paragraph).encode('cp1251'))
        self.assertEqual(c.detect_input(source), '.txt')
        self.outputs(source, (link, paragraph))
        source.write_bytes(b'<catalogue/>')
        self.assertEqual(c.detect_input(source), '.xml')

    def outputs(self, source, required, image=False, rich=False, chapters=False):
        before = hashlib.sha256(source.read_bytes()).digest()
        for target in ['.epub', '.fb2']:
            output = self.root / (source.name + target); report = c.convert_book(source, output, title='Каталожное название', author='Каталожный автор', language='ru')
            self.assertGreater(report['size'], 100)
            if target == '.epub':
                with zipfile.ZipFile(output) as z:
                    self.assertIsNone(z.testzip()); body = c.xml(z.read('OEBPS/book.xhtml')); nav = c.xml(z.read('OEBPS/nav.xhtml'))
                    self.assertTrue(all(x in ''.join(body.itertext()) for x in required))
                    if image: self.assertIn(PNG, [z.read(n) for n in z.namelist() if '/images/' in n])
                    if rich:
                        self.assertTrue(any(c.tag(n) == 'strong' for n in body.iter())); self.assertTrue(any(c.tag(n) == 'em' for n in body.iter()))
                    if chapters:
                        ol = next(n for n in nav.iter() if c.tag(n) == 'ol')
                        self.assertEqual(len(ol), 2); self.assertEqual(len(c.first(ol[0], 'ol')), 1)
                checker, java = os.environ.get('HOMELIB_TEST_EPUBCHECK'), os.environ.get('HOMELIB_TEST_JAVA')
                if checker and java:
                    r = subprocess.run([java, '-jar', checker, str(output)], capture_output=True, timeout=30, creationflags=0x08000000)
                    self.assertEqual(r.returncode, 0, r.stdout.decode(errors='replace') + r.stderr.decode(errors='replace'))
            else:
                root = c.xml(output.read_bytes()); c.validate_fb2_output(root); text = ''.join(root.itertext())
                for value in required: self.assertIn(value, text)
                if image: self.assertIn(PNG, [base64.b64decode(n.text) for n in root if c.tag(n) == 'binary'])
                if rich:
                    self.assertTrue(any(c.tag(n) == 'strong' for n in root.iter())); self.assertTrue(any(c.tag(n) == 'emphasis' for n in root.iter()))
                schema = os.environ.get('HOMELIB_TEST_FB2_SCHEMA')
                if schema:
                    from lxml import etree
                    validator = etree.XMLSchema(etree.parse(schema)); self.assertTrue(validator.validate(etree.parse(str(output))), str(validator.error_log))
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)
        self.assertFalse(list(self.root.glob('.homelib-convert-*')))
    def test_txt_unicode_and_cp1251(self):
        for name, encoding, text in [('unicode', 'utf-8', TEXT), ('legacy', 'cp1251', 'Старая кодировка — ё')]:
            source = self.root / (name + '.txt'); source.write_bytes((text + '\n\nВторая строка').encode(encoding)); self.outputs(source, [text, 'Вторая строка'])

    def test_txt_detects_legacy_cyrillic_and_keeps_lines(self):
        lines = ['Это была первая встреча. Когда он приехал, она уже была там.',
                 'После беседы они решили, что завтра вместе пойдут за ёлкой.']
        for encoding in ('cp866', 'koi8-r', 'cp1251', 'utf-8'):
            with self.subTest(encoding=encoding):
                source = self.root / (encoding + '.txt')
                raw = ('\r\n'.join(lines) + '\r\n\x1a').encode(encoding)
                source.write_bytes(raw)
                for target in ('.epub', '.fb2'):
                    output = self.root / (source.stem + target)
                    report = c.convert_book(source, output)
                    self.assertFalse(c.damaged_content_warnings(report['warnings']))
                    if target == '.epub':
                        with zipfile.ZipFile(output) as archive:
                            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
                    else:
                        body = c.first(c.xml(output.read_bytes()), 'body')
                    self.assertEqual([''.join(p.itertext()) for p in body.iter() if c.tag(p) == 'p'], lines)
                self.assertEqual(source.read_bytes(), raw)

    def test_txt_box_drawing_preserves_fixed_columns(self):
        source = self.root / 'diagram.txt'
        frame = ['    ┌──────────┐', '    │ а  б   в │', '    └──────────┘']
        prose = ['Обычный текст.', '', 'Следующий абзац.']
        original = '\r\n'.join([*prose[:2], *frame, *prose[2:]]).encode('utf-8')
        source.write_bytes(original)
        epub, fb2, restored = (self.root / name for name in ('copy.epub', 'copy.fb2', 'restored.epub'))
        report = c.convert_book(source, epub)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            expected = [('p', prose[0]), ('p', ''), ('pre', '\n'.join(frame)), ('p', prose[2])]
            self.assertEqual([(c.tag(node), ''.join(node.itertext())) for node in body], expected)
            self.assertEqual(body[2].get('class'), c.TEXT_FRAME_STYLE)
            css = archive.read('OEBPS/book.css').decode()
            self.assertIn(f'.{c.TEXT_FRAME_STYLE}{{white-space:pre;overflow-x:auto;font-family:monospace;', css)
        report = c.convert_book(source, fb2)
        self.assertTrue(any(w.startswith('Выравнивание таблиц и схем в FB2')
                            for w in c.damaged_content_warnings(report['warnings'])))
        book = c.xml(fb2.read_bytes())
        self.assertEqual([''.join(node.itertext()) for node in book.iter('{' + c.FB + '}p')
                          if node.get('style') == c.TEXT_FRAME_STYLE], frame)
        schema = os.environ.get('HOMELIB_TEST_FB2_SCHEMA')
        if schema:
            from lxml import etree
            etree.XMLSchema(etree.parse(schema)).assertValid(etree.parse(str(fb2)))
        c.convert_book(fb2, restored)
        with zipfile.ZipFile(restored) as archive:
            documents = [c.xml(archive.read(p)) for p in archive.namelist()
                         if p.endswith('.xhtml') and '/nav.' not in p]
            self.assertEqual([''.join(node.itertext()) for doc in documents for node in doc.iter()
                              if c.TEXT_FRAME_STYLE in node.get('class', '').split()], frame)
            self.assertIn(f'.{c.TEXT_FRAME_STYLE} code{{white-space:pre;', archive.read('OEBPS/book.css').decode())
        self.assertEqual(source.read_bytes(), original)

    def test_txt_recognizes_whole_space_aligned_tables_and_diagram_labels(self):
        source = self.root / 'columns.faq'
        table = ['Имя        Код      Данные', '', 'Вход        01      Разрешён',
                 'Выход       02      Закрыт', 'Нейтраль    10      Открыт',
                 '            20      Остальные']
        diagram = ['    │      ║', '', '    179']
        prose = ['Обычный   абзац с одиночным двойным отступом.', 'Следующий   абзац.',
                 'И ещё один абзац.', 'Конец главы.']
        lines = [*prose[:3], '', *table, '', *diagram, '', prose[3]]
        raw = '\r\n'.join(lines).encode('utf-8')
        source.write_bytes(raw)
        epub, fb2 = self.root / 'copy.epub', self.root / 'copy.fb2'
        report = c.convert_book(source, epub)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            self.assertEqual([node.text.split('\n') for node in body if c.tag(node) == 'pre'], [table, diagram])
            self.assertEqual([node.text for node in body if c.tag(node) == 'p' and node.text], prose)
        report = c.convert_book(source, fb2)
        self.assertTrue(any(w.startswith('Выравнивание таблиц и схем в FB2')
                            for w in c.damaged_content_warnings(report['warnings'])))
        book = c.xml(fb2.read_bytes())
        self.assertEqual([''.join(node.itertext()) for node in book.iter('{' + c.FB + '}p')
                          if node.get('style') == c.TEXT_FRAME_STYLE], [*table, *diagram])
        self.assertEqual(source.read_bytes(), raw)

    def test_txt_interior_control_still_reports_damage(self):
        source = self.root / 'damaged.txt'
        source.write_bytes('До отметки\x1aпосле отметки'.encode('utf-8'))
        output = self.root / 'damaged.epub'
        report = c.convert_book(source, output)
        self.assertTrue(c.damaged_content_warnings(report['warnings']))
        with zipfile.ZipFile(output) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            self.assertIn('До отметки�после отметки', ''.join(body.itertext()))

    def test_txt_restores_consistent_dos_bullets(self):
        source = self.root / 'dos-list.txt'
        intro = 'Это была первая встреча. Когда он приехал, она уже была там.'
        bullets = '\r\n \x07Первый шаг\r\n\x07 Второй шаг\r\n\x07 Третий шаг.'
        for name, trailing in (('list', ''), ('damaged', ' Внутри\x07строки.')):
            with self.subTest(trailing=trailing):
                source.write_bytes((intro + bullets + trailing).encode('cp866'))
                output = self.root / (name + '.epub')
                report = c.convert_book(source, output)
                with zipfile.ZipFile(output) as archive:
                    body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
                    text = ''.join(body.itertext())
                if trailing:
                    self.assertTrue(c.damaged_content_warnings(report['warnings']))
                    self.assertIn('Внутри�строки.', text)
                else:
                    self.assertFalse(c.damaged_content_warnings(report['warnings']))
                    self.assertEqual(text.count('•'), 3)
    def test_word_drawing_preserves_character_width_and_height(self):
        helper = Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools/doc/HomeLibDoc.exe'
        if os.name != 'nt' or not helper.is_file():
            self.skipTest('The Windows Word drawing renderer is not built')
        try:
            from PIL import Image, ImageChops
        except ImportError:
            self.skipTest('Pillow is required to compare glyph bounds')
        drawing = f'''<figure xmlns:w="{W}" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
            xmlns:s="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
            <s:wsp><s:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5080000" cy="1270000"/></a:xfrm>
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></s:spPr>
            <s:txbx><w:txbxContent><w:p><w:r><w:rPr><w:rFonts w:ascii="Arial"/><w:sz w:val="48"/>
            <w:w w:val="SCALE"/></w:rPr><w:t>MMMMMM</w:t></w:r></w:p></w:txbxContent></s:txbx>
            <s:bodyPr lIns="0" rIns="0" tIns="0" bIns="0"><a:noAutofit/></s:bodyPr></s:wsp></figure>'''
        widths = {}
        heights = {}
        for percent in (7, 50, 100, 200):
            xml = self.root / f'{percent}.xml'
            png = xml.with_suffix('.png')
            xml.write_text(drawing.replace('SCALE', str(percent)), encoding='utf-8')
            process = subprocess.run([helper, '--drawingml-to-png', xml, png], capture_output=True,
                                     timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(process.returncode, 0, process.stderr)
            with Image.open(png) as rendered:
                rgb = rendered.convert('RGB')
                left, top, right, bottom = ImageChops.difference(rgb, Image.new('RGB', rgb.size, 'white')).getbbox()
            widths[percent] = right - left
            heights[percent] = bottom - top
        for percent in (7, 50, 200):
            self.assertAlmostEqual(widths[percent], widths[100] * percent / 100, delta=5)
            self.assertAlmostEqual(heights[percent], heights[100], delta=2)

    def test_docx_textbox_renders_its_bullet_and_keeps_repeated_paragraphs(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        source = self.root / 'boxed-bullets.docx'
        properties = ('<w:tabs><w:tab w:val="left" w:pos="360"/></w:tabs>'
                      '<w:ind w:left="360" w:hanging="360"/>')
        automatic = ('<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>'
                     f'{properties}</w:pPr><w:r><w:t>Повтор</w:t></w:r>')
        explicit = properties + '</w:pPr><w:r><w:t>§</w:t><w:tab/><w:t>Повтор</w:t></w:r>'

        def box(paragraph):
            lines = f'<w:p><w:pPr>{paragraph}</w:p>' * 2
            return ('<w:p><w:r><w:pict><v:shape type="#_x0000_t202" filled="f" stroked="f" '
                    'style="position:absolute;width:220pt;height:64pt;margin-left:10pt;margin-top:20pt;'
                    'mso-position-horizontal-relative:page;mso-position-vertical-relative:page">'
                    f'<v:textbox inset="0,0,0,0"><w:txbxContent>{lines}</w:txbxContent></v:textbox>'
                    '</v:shape></w:pict></w:r></w:p>')

        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:v="urn:schemas-microsoft-com:vml">
                <w:body>{box(automatic)}{box(explicit)}</w:body></w:document>''')
            archive.writestr('word/numbering.xml', f'''<w:numbering xmlns:w="{W}">
                <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/>
                <w:lvlText w:val="§"/><w:lvlJc w:val="left"/></w:lvl></w:abstractNum>
                <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>''')
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        report = c.convert_book(source, epub, tools_root=tools)
        self.assertFalse(any(message.startswith('Не перенесён объект DOCX') for message in report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            book = c.xml(archive.read('OEBPS/book.xhtml'))
            images = list(book.iter(f'{{{c.XH}}}img'))
            self.assertEqual(len(images), 2)
            self.assertEqual(images[0].get('alt'), 'Повтор\nПовтор')
            self.assertEqual(archive.read('OEBPS/' + images[0].get('src')), archive.read('OEBPS/' + images[1].get('src')))
        c.convert_book(source, fb2, tools_root=tools)
        book = c.xml(fb2.read_bytes())
        c.validate_fb2_output(book)
        self.assertEqual([node.get('alt').count('Повтор') for node in book.iter(f'{{{c.FB}}}image')], [2, 2])

    def test_docx_recreates_framed_pages_in_their_original_order(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')

        def frame(label, x, y):
            return ('<w:r><w:pict><v:shape type="#_x0000_t202" filled="f" stroked="f" '
                    f'style="position:absolute;width:180pt;height:40pt;margin-left:{x}pt;margin-top:{y}pt;'
                    'mso-position-horizontal-relative:page;mso-position-vertical-relative:page">'
                    '<v:textbox inset="0,0,0,0"><w:txbxContent>'
                    f'<w:p><w:r><w:t>{label}</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></w:r>')

        size = '<w:sectPr><w:pgSz w:w="11910" w:h="16840"/></w:sectPr>'
        first_section = size.replace('<w:sectPr>', '<w:sectPr><w:type w:val="continuous"/>')
        pages = (f'<w:p>{frame("Рамка слева", 50, 60)}{frame("Рамка ниже", 80, 300)}</w:p>'
                 f'<w:p><w:pPr><w:spacing w:after="0"/>{first_section}</w:pPr></w:p>'
                 f'<w:p>{frame("Следующая страница", 40, 80)}</w:p>{size}')

        def source_with(body, name):
            source = self.root / name
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr('word/document.xml', f'<w:document xmlns:w="{W}" xmlns:v="urn:schemas-microsoft-com:vml">'
                                 f'<w:body>{body}</w:body></w:document>')
            return source

        source = source_with(pages, 'framed.docx')
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        result = c.convert_book(source, epub, tools_root=tools)
        self.assertEqual(len(c.damaged_content_warnings(result['warnings'])), 1)
        expected = ['Рамка слева\nРамка ниже', 'Следующая страница']
        with zipfile.ZipFile(epub) as archive:
            package = c.xml(archive.read('OEBPS/package.opf'))
            self.assertEqual(c.plain(package.find(f'.//{{{c.OP}}}meta[@property="rendition:layout"]')), 'pre-paginated')
            source_hashes = []
            for name, label in zip(('book.xhtml', 'book-2.xhtml'), expected):
                book = c.xml(archive.read('OEBPS/' + name))
                image, = book.iter(f'{{{c.XH}}}img')
                self.assertEqual(image.get('alt'), label)
                image_data = archive.read('OEBPS/' + image.get('src'))
                width, height = struct.unpack_from('>II', image_data, 16)
                self.assertEqual(book.find(f'.//{{{c.XH}}}meta[@name="viewport"]').get('content'),
                                 f'width={width}, height={height}')
                source_hashes.append(hashlib.sha256(image_data).digest())
        c.convert_book(source, fb2, tools_root=tools)
        book = c.xml(fb2.read_bytes()); c.validate_fb2_output(book)
        self.assertEqual([image.get('alt') for image in book.iter(f'{{{c.FB}}}image')], expected)
        self.assertEqual([hashlib.sha256(base64.b64decode(node.text)).digest() for node in book.iter(f'{{{c.FB}}}binary')],
                         source_hashes)

        mixed = source_with('<w:p><w:r><w:t>Обычный абзац</w:t></w:r></w:p>' + pages, 'mixed.docx')
        mixed_epub = mixed.with_suffix('.epub'); c.convert_book(mixed, mixed_epub, tools_root=tools)
        with zipfile.ZipFile(mixed_epub) as archive:
            package = c.xml(archive.read('OEBPS/package.opf'))
            self.assertIsNone(package.find(f'.//{{{c.OP}}}meta[@property="rendition:layout"]'))
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            self.assertIn('Обычный абзац', c.plain(body))
            self.assertEqual(len(list(body.iter(f'{{{c.XH}}}img'))), 3)

    def test_word_vml_freeform_matches_equivalent_absolute_geometry(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        helper = tools / 'doc' / 'HomeLibDoc.exe'
        if os.name != 'nt' or not helper.is_file():
            self.skipTest('Windows Word drawing renderer required')
        drawing = '''<figure xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
          <v:group style="width:120pt;height:100pt" coordsize="2400,2000" o:allowincell="f">
            <v:shape type="#_x0000_t32" o:connectortype="straight" strokecolor="#333333"
              style="left:200;top:100;width:1900;height:1500;flip:x"/>
            <v:shape coordsize="1000,850" fillcolor="#a7bfde" stroked="f" path="PATH"
              style="left:500;top:300;width:1300;height:1200;mso-width-relative:page"><v:path arrowok="t"/></v:shape>
            <v:oval fillcolor="#7ba0cd" stroked="f" style="left:320;top:540;width:900;height:500;rotation:ANGLE"/>
          </v:group></figure>'''
        samples = (
            ('m1000,100r,750l300,850hfc150,770,,485,150,300hav130,-120,470,-260,850,-200haxe', '4423680fd'),
            ('m1000,100l1000,850 300,850c150,770,0,485,150,300 280,180,620,40,1000,100xe', '67.5'),
            ('m1000,100l1000,850j300,850xe', '67.5'),
        )
        request = self.root / 'figures.xml'
        request.write_text('<figures>' + ''.join(drawing.replace('PATH', path).replace('ANGLE', angle)
                                                for path, angle in samples) + '</figures>', encoding='utf-8')
        output = self.root / 'figures.zip'
        process = subprocess.run([helper, '--drawingml-to-png-batch', request, output], capture_output=True,
                                 timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(process.returncode, 0, process.stderr)
        with zipfile.ZipFile(output) as images:
            self.assertEqual(images.namelist(), ['0.png', '1.png'])
            self.assertEqual(images.read('0.png'), images.read('1.png'))

    def test_html_fragment_legacy_entities_and_inline_styles(self):
        source = self.root/'book.html'; (self.root/'image.png').write_bytes(PNG)
        source.write_bytes(('<html lang="ru"><head><meta charset="windows-1251"><title>HTML книга</title><script>NOT BOOK</script></head><body><h1>Глава один</h1><p>Ё &amp; текст <b><i>Жирный курсив</i></b><img src="image.png"><h2>Подглава</h2><p id="end">Конец<br>Новая строка</p><h1>Глава два</h1><a href="#end">Ссылка</a></body></html>').encode('cp1251'))
        self.outputs(source, ['Ё & текст', 'Жирный курсив', 'Новая строка'], True, True, True)
        with zipfile.ZipFile(self.root/'book.html.epub') as z: self.assertNotIn('NOT BOOK', z.read('OEBPS/book.xhtml').decode())

    def test_legacy_mobi_cover_is_preserved_without_changing_the_reading_order(self):
        images = self.root / 'Images'
        images.mkdir()
        cover = images / 'cover00003.png'
        cover.write_bytes(PNG)
        source = self.root / 'book.html'
        source.write_text('<html><body><h1>First chapter</h1><p>Text</p></body></html>', encoding='utf-8')
        package = self.root / 'content.opf'
        declaration = ('<package><metadata><meta name="cover" content="cover"/></metadata><manifest>'
                       '<item id="cover" href="Images/cover00003.png" media-type="image/png"/>'
                       '<item id="thumb" href="Images/thumb00004.png" media-type="image/png"/>'
                       '</manifest></package>')
        package.write_text(declaration, encoding='utf-8')
        warnings = set()
        asset = c.mobi_cover_asset(c.mobi_package(source, warnings), source, warnings)
        self.assertEqual(asset, cover)
        self.assertFalse(warnings)
        epub = self.root / 'out.epub'
        c.text_to_book(source, epub, warnings, '.epub', cover_asset=asset)
        with zipfile.ZipFile(epub) as archive:
            manifest = c.first(c.xml(archive.read('OEBPS/package.opf')), 'manifest')
            item, = [node for node in manifest if node.get('properties') == 'cover-image']
            self.assertEqual(archive.read('OEBPS/' + item.get('href')), PNG)
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            self.assertEqual([c.tag(node) for node in body], ['h1', 'p'])
            self.assertEqual(c.plain(body), 'First chapterText')
        fb2 = self.root / 'out.fb2'
        c.text_to_book(source, fb2, warnings, '.fb2', cover_asset=asset)
        root = c.xml(fb2.read_bytes())
        picture, = root.findall('.//{*}coverpage/{*}image')
        binary, = root.findall('{*}binary')
        self.assertEqual(picture.get('{' + c.XL + '}href'), '#' + binary.get('id'))
        self.assertEqual(base64.b64decode(binary.text), PNG)
        self.assertFalse(c.damaged_content_warnings(warnings))

        # A thumbnail does not give the original cover a replacement target.
        (images / 'thumb00004.png').write_bytes(PNG)
        cover.unlink()
        missing = set()
        self.assertIsNone(c.mobi_cover_asset(c.mobi_package(source, missing), source, missing))
        self.assertTrue(c.damaged_content_warnings(missing))
        package.write_text(declaration.replace('Images/cover00003.png', '../cover00003.png'), encoding='utf-8')
        self.assertIsNone(c.mobi_cover_asset(c.mobi_package(source, set()), source, set()))

    def test_mobi_publication_fields_survive_epub_and_fb2(self):
        source = self.root / 'book.html'
        source.write_text('<p>Текст книги</p>', encoding='utf-8')
        package = c.xml(f'''<package xmlns="{c.OP}" xmlns:opf="{c.OP}" xmlns:dc="{c.DC}" unique-identifier="uid">
            <metadata><dc:title>Издание</dc:title><dc:language>ru</dc:language><dc:identifier id="uid">2718</dc:identifier>
            <dc:creator>Один автор</dc:creator><dc:creator>Второй автор</dc:creator>
            <dc:contributor opf:role="trl">Переводчик</dc:contributor>
            <dc:identifier opf:scheme="ISBN">978-5-498-07948-6</dc:identifier>
            <dc:publisher>Издательство</dc:publisher><dc:date>2020-04-03</dc:date><dc:source>История издания</dc:source>
            <dc:subject>Жанр 1</dc:subject><dc:subject>Жанр 2</dc:subject><dc:description>Аннотация</dc:description>
            <dc:rights>Права</dc:rights></metadata></package>'''.encode('utf-8'))
        publication = c.mobi_publication_metadata(package, ('B012345678',))
        warnings = set()
        saved = self.root / 'publication.epub'
        c.text_to_book(source, saved, warnings, '.epub', publication_metadata=publication, title='Название каталога')
        with zipfile.ZipFile(saved) as archive:
            actual = c.first(c.xml(archive.read('OEBPS/package.opf')), 'metadata')
        self.assertEqual(c.plain(c.first(actual, 'title')), 'Издание')
        self.assertEqual([(n.get('id'), c.plain(n)) for n in c.children(actual, 'identifier')],
                         [('book-id', '2718'), (None, 'urn:isbn:978-5-498-07948-6')])
        self.assertEqual(c.read_epub_people(actual), (['Один автор', 'Второй автор'], ['Переводчик']))
        self.assertEqual(c.epub_custom_metadata(actual, 'mhl:kindle-asin'), 'B012345678')

        fb2 = self.root / 'publication.fb2'
        c.text_to_book(source, fb2, warnings, '.fb2', publication_metadata=publication)
        root = c.xml(fb2.read_bytes())
        self.assertEqual([c.plain(n) for n in root.findall('.//{*}title-info/{*}author')], ['Один автор', 'Второй автор'])
        self.assertEqual([c.plain(n) for n in root.findall('.//{*}title-info/{*}translator')], ['Переводчик'])
        self.assertEqual(c.plain(root.find('.//{*}publish-info/{*}year')), '2020')
        self.assertEqual(c.plain(root.find('.//{*}publish-info/{*}isbn')), '978-5-498-07948-6')
        self.assertEqual(c.plain(root.find('.//{*}title-info/{*}annotation')), 'Аннотация')
        metadata, = [n for n in root.findall('.//{*}custom-info') if n.get('info-type') == 'HomeLib Ru: EPUB metadata (XML/base64)']
        original = c.xml(base64.b64decode(metadata.text, validate=True))
        self.assertEqual(c.plain(c.first(original, 'date')), '2020-04-03')
        self.assertEqual(c.plain(c.first(original, 'rights')), 'Права')
        self.assertEqual(c.epub_custom_metadata(original, 'mhl:kindle-asin'), 'B012345678')
        self.assertFalse(c.damaged_content_warnings(warnings))

    def test_word_html_heading_paragraphs_keep_navigation_levels(self):
        source = self.root / 'word-headings.htm'
        source.write_text('''<html><body><h1>Volume</h1>
            <p class="MsoToc7">Printed contents row</p><h3>Chapter</h3>
            <p class="center MsoHeading7" id="deep">Deep <em>heading</em></p>
            <p><a href="#deep">Return to heading</a></p>
            <p class="MsoHeading7X">Ordinary paragraph</p>
            <p class="MsoHeading7" role="heading" aria-level="3">Explicit level</p>
            </body></html>''', encoding='utf-8')
        epub = self.root / 'word-headings.epub'
        c.convert_book(source, epub)
        with zipfile.ZipFile(epub) as package:
            body = c.first(c.xml(package.read('OEBPS/book.xhtml')), 'body')
            nav = c.xml(package.read('OEBPS/nav.xhtml'))
        headings = [node for node in body.iter() if c.html_heading_level(node)]
        self.assertEqual([(c.plain(node), c.html_heading_level(node)) for node in headings],
                         [('Volume', 1), ('Chapter', 3), ('Deep heading', 7), ('Explicit level', 3)])
        self.assertEqual((headings[2].get('role'), headings[2].get('aria-level')), ('heading', '7'))
        self.assertEqual([c.plain(node) for node in nav.iter('{' + c.XH + '}a')],
                         ['Volume', 'Chapter', 'Deep heading', 'Explicit level'])

        fb2 = self.root / 'word-headings.fb2'
        c.convert_book(source, fb2)
        book = c.xml(fb2.read_bytes())
        c.validate_fb2_output(book)
        body = c.first(book, 'body')
        self.assertEqual([c.plain(node) for node in body.iter('{' + c.FB + '}title')],
                         ['Volume', 'Chapter', 'Deep heading', 'Explicit level'])
        self.assertIn('Printed contents row', c.plain(body))
        self.assertIn('Ordinary paragraph', c.plain(body))
        links = list(body.iter('{' + c.FB + '}a'))
        self.assertEqual(len(links), 1)
        target_id = links[0].get('{' + c.XL + '}href')[1:]
        self.assertEqual(c.plain(next(node for node in body.iter() if node.get('id') == target_id)), 'Deep heading')

    def test_html_keeps_source_image_descriptions(self):
        source = self.root / 'illustrations.html'
        (self.root / 'image.png').write_bytes(PNG)
        (self.root / 'broken.png').write_bytes(b'not an image')
        source.write_text('''<html><body>
          <p>Before <img src="missing.gif" alt="  Название &amp; дата  "> after.</p>
          <p><img src="broken.png" alt="Подпись к рисунку"></p>
          <p><img src="image.png" alt="Ёж и яблоко"></p>
          <p><img alt="Только описание"></p>
          </body></html>''', encoding='utf-8')

        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = self.root / ('illustrations' + suffix)
                report = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        self.assertEqual([archive.read(name) for name in archive.namelist()
                                          if '/images/' in name], [PNG])
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                    self.assertEqual([base64.b64decode(node.text) for node in document.iter()
                                      if c.tag(node) == 'binary'], [PNG])
                body = c.first(document, 'body')
                body_text = c.plain(body)
                self.assertIn('Before [Изображение 1 недоступно.] Название & дата after.', body_text)
                self.assertIn('[Изображение 2 недоступно.] Подпись к рисунку', body_text)
                self.assertIn('Только описание', body_text)
                self.assertEqual([node.get('alt') for node in body.iter()
                                  if c.tag(node) in {'img', 'image'}], ['Ёж и яблоко'])
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertTrue(all(any(filename in warning for warning in warnings)
                                    for filename in ('missing.gif', 'broken.png')))

    def test_legacy_html_fragment_recovers_only_an_existing_target(self):
        from urllib.parse import unquote

        source = self.root / 'legacy-fragments.htm'
        source.write_bytes(('''<html><body>
          <p><a href="#%D0%81">UTF8</a><a href="#%DF+B">Plus</a>
          <a href="#%DF+C">Space</a><a href="#%DF+D">Missing</a></p>
          <p id="Ё">Original UTF8 target</p><p id="РЃ">Alternative code page</p>
          <p id="Я+B">Literal plus</p><p id="Я B">Other target</p><p id="Я C">Legacy space</p>
          </body></html>''').encode('cp1251'))

        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = self.root / ('legacy-links' + suffix)
                report = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        root = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    root = c.first(c.xml(output.read_bytes()), 'body')
                    c.validate_fb2_output(c.xml(output.read_bytes()))
                targets = {n.get('id'): c.plain(n) for n in root.iter() if n.get('id')}
                links = {}
                for node in root.iter():
                    if c.tag(node) == 'a':
                        href = node.get('href') or node.get('{' + c.XL + '}href', '')
                        if href:
                            links[c.plain(node)] = targets[unquote(href[1:])]
                self.assertEqual(links, {'UTF8': 'Original UTF8 target', 'Plus': 'Literal plus', 'Space': 'Legacy space'})
                self.assertIn('Missing', c.plain(root))
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertEqual(len(warnings), 1)
                self.assertIn('#%DF+D', warnings[0])

    def test_html_redundant_nested_spans_keep_text_and_inline_style(self):
        source = self.root / 'nested-spans.html'
        source.write_text('<p>До ' + '<span>' * 400 + '<b><i>формула</i></b>' +
                          '</span>' * 400 + ' после.</p>', encoding='utf-8')
        self.outputs(source, ['До формула после.'], rich=True)

    def test_html_implicitly_closes_head_at_first_paragraph(self):
        source = self.root / 'omitted-head-end.htm'
        source.write_text('<html><head><title>Заголовок файла</title><template>Скрыто</template>'
                          '<p>Первый абзац</p><p>Последний абзац</p></html>', encoding='utf-8')
        self.outputs(source, ['Первый абзац', 'Последний абзац'])
        with zipfile.ZipFile(self.root / 'omitted-head-end.htm.epub') as archive:
            self.assertNotIn('Скрыто', archive.read('OEBPS/book.xhtml').decode('utf-8'))
    def test_html_optional_description_list_end_tags(self):
        source = self.root/'book.shtml'
        entries = ''.join(f'<dt>Term {i}<dd><em>Definition {i}' for i in range(180))
        source.write_text(f'<html><body><dl>{entries}</dl><p>After the list</p></body></html>', encoding='utf-8')
        self.outputs(source, ['Term 0', 'Definition 0', 'Term 179', 'Definition 179', 'After the list'])
        with zipfile.ZipFile(self.root/'book.shtml.epub') as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            listing = next(node for node in body.iter() if c.tag(node) == 'dl')
            self.assertEqual([c.tag(node) for node in listing], ['dt', 'dd'] * 180)
            self.assertEqual(c.plain(listing[-1]), 'Definition 179')
    def test_html_external_counter_does_not_block_offline_conversion(self):
        source = self.root/'book.shtml'
        source.write_text('<html><body><p>Chapter text<img width="1" height="1" alt="" src="https://example.invalid/counter"></p></body></html>', encoding='utf-8')
        self.outputs(source, ['Chapter text'])
        with zipfile.ZipFile(self.root/'book.shtml.epub') as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertFalse(any(c.tag(node) == 'img' for node in body.iter()))

    def test_empty_html_layout_image_keeps_menu_text_without_inventing_pixels(self):
        source=self.root/'menu.htm'
        source.write_text('<html><body><p>Before<IMG border=0 height=1 src= width=4>After'
                          '<img width="4" height="1" src=""/>'
                          '<img src="data:image/png;base64,'+base64.b64encode(PNG).decode()+'"/>'
                          '</p><p>Last paragraph.</p></body></html>',encoding='utf-8')
        self.outputs(source,['Before After','Last paragraph.'],True)
        with zipfile.ZipFile(self.root/'menu.htm.epub') as z:
            tree=c.xml(z.read('OEBPS/book.xhtml'))
            self.assertEqual(sum(c.tag(n)=='img' for n in tree.iter()),1)
        for index,tag in enumerate([
            '<img src="width=4" width="4" height="1">',
            '<img title="src= width=4" src="width=4" width="4" height="1">',
            '<img src= width=400 height=600>',
            '<img height=1 src= width=4 alt="Meaningful illustration">']):
            book=self.root/('missing-image-'+str(index)+'.htm')
            book.write_text('<html><body><p>Text'+tag+'</p></body></html>',encoding='utf-8')
            before=book.read_bytes()
            for suffix in ['.epub','.fb2']:
                output=self.root/(book.stem+suffix)
                result=c.convert_book(book,output)
                self.assertTrue(any(item.startswith('Изображение 1 недоступно.')
                                    for item in c.damaged_content_warnings(result['warnings'])))
                if suffix=='.epub':
                    with zipfile.ZipFile(output) as archive: content=c.xml(archive.read('OEBPS/book.xhtml'))
                else: content=c.first(c.xml(output.read_bytes()),'body')
                self.assertIn('[Изображение 1 недоступно.]',''.join(content.itertext()))
                self.assertFalse(any(c.tag(node) in {'img','image'} for node in content.iter()))
            self.assertEqual(book.read_bytes(),before)

    def test_html5_layout_repair_keeps_unicode_offsets_anchors_and_quoted_images(self):
        spec=importlib.util.spec_from_file_location('layout_html_input',Path(__file__).resolve().parents[1]/'text_inputs.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        (self.root/'width=4').write_bytes(PNG)
        for html5 in [False,True]:
            source=self.root/('layout-'+str(html5)+'.htm')
            source.write_text('<html><head><title>Menu</title></head><body>Ё 😀\r\n<p>Before\r\n'
                              '<img border=0 height=1 src= width=4 id="a&amp;b" class="spacer">After</p>\r\n'
                              '<p><img title="src= width=4" src="width=4" width=4 height=1></p>'
                              '<p>Last paragraph.</p></body></html>',encoding='utf-8')
            before=source.read_bytes();warnings=set();book=module.Book(c,source,warnings)
            module.read_html(book,before,html5=html5)
            output=self.root/('layout-'+str(html5)+'.epub');book.finish(output)
            with zipfile.ZipFile(output) as z:
                tree=c.xml(z.read('OEBPS/book.xhtml'));text=' '.join(''.join(tree.itertext()).split())
                self.assertIn('Ё 😀',text);self.assertIn('Before After',text);self.assertIn('Last paragraph.',text)
                self.assertTrue(any(n.get('id')=='a&b' and n.get('class')=='spacer' for n in tree.iter()))
                self.assertEqual(sum(c.tag(n)=='img' for n in tree.iter()),1)
                self.assertIn(PNG,[z.read(name) for name in z.namelist() if '/images/' in name])
            self.assertEqual(source.read_bytes(),before)
            self.assertTrue(any('служебное изображение' in warning for warning in warnings))

    def test_html_duplicate_anchors_keep_first_target_and_do_not_take_later_ids(self):
        source=self.root/'anchors.htm'
        source.write_text('<html><body><p id="a">First target.</p><p id="a">Second paragraph.</p>'
                          '<p id="a-homelibre-2">Existing later target.</p>'
                          '<p><a id="original-id" name="mixed">Earlier named anchor.</a></p>'
                          '<p id="mixed">Explicit ID target.</p>'
                          '<p><a id="modern" name="legacy"></a>Both names target this line.</p>'
                          '<p><a href="#a">First link</a> <a href="#a-homelibre-2">Later link</a>'
                          '<a href="#mixed">Explicit link</a> <a href="#legacy">Legacy link</a> '
                          '<a href="#modern">Modern link</a></p></body></html>',encoding='utf-8')
        self.outputs(source,['First target.','Second paragraph.','Existing later target.','Explicit ID target.',
                             'Both names target this line.'])
        with zipfile.ZipFile(self.root/'anchors.htm.epub') as z:
            tree=c.xml(z.read('OEBPS/book.xhtml'))
            nodes=[n for n in tree.iter() if n.get('id')]
            self.assertEqual(len(nodes),len({n.get('id') for n in nodes}))
            by_id={n.get('id'):n for n in nodes}
            self.assertEqual(c.plain(by_id['a']),'First target.')
            self.assertEqual(c.plain(by_id['a-homelibre-2']),'Existing later target.')
            self.assertEqual(c.plain(by_id['mixed']),'Explicit ID target.')
            self.assertIn(by_id['legacy'], list(by_id['modern']))
            self.assertTrue(any(n.get('href')=='#a' and c.plain(n)=='First link' for n in tree.iter()))
            self.assertTrue(any(n.get('href')=='#a-homelibre-2' for n in tree.iter()))

    def test_html_layout_cell_keeps_separate_fb2_index_destinations(self):
        source = self.root / 'index.htm'
        source.write_text('<p><a href="#A">First link</a> <a href="#B">Second link</a></p>'
                          '<table width="100%" cellspacing="0" cellpadding="0"><tr><td>'
                          '<p><a id="letter-a" name="A"></a>First destination.</p>'
                          '<p><a id="letter-b" name="B"></a>Second destination.</p>'
                          '</td></tr></table>'
                          '<table width="100%" border="1" cellspacing="0" cellpadding="0"><tr><td>'
                          '<p>Actual table.</p></td></tr></table>', encoding='utf-8')
        self.outputs(source, ['First destination.', 'Second destination.', 'Actual table.'])
        fb2 = c.xml((self.root / 'index.htm.fb2').read_bytes())
        body = c.first(fb2, 'body')
        targets = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
        links = {c.plain(node): node.get('{' + c.XL + '}href') for node in body.iter() if c.tag(node) == 'a'}
        self.assertEqual(targets[links['First link'][1:]], 'First destination.')
        self.assertEqual(targets[links['Second link'][1:]], 'Second destination.')
        self.assertEqual([c.plain(node) for node in body.iter() if c.tag(node) == 'table'], ['Actual table.'])

    def test_docx(self):
        source = self.root/'book.docx'; docx(source); self.outputs(source, [TEXT, 'Точная сноска', 'Ячейка'], True, True, True)

    def test_docx_large_footnotes_keep_link_order_and_nested_references(self):
        source = self.root / 'large-notes.docx'
        unused = '<w:r><w:rPr><w:lang w:val="en"/></w:rPr><w:t>Unused</w:t></w:r>' * 16
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body><w:p>
              <w:r><w:t>Body text.</w:t><w:footnoteReference w:id="11000"/><w:endnoteReference w:id="5"/></w:r>
              </w:p></w:body></w:document>''')
            with package.open('word/footnotes.xml', 'w') as part:
                part.write(f'<w:footnotes xmlns:w="{W}">'.encode())
                for number in range(1, 9001):
                    part.write(f'<w:footnote w:id="{number}"><w:p>{unused}</w:p></w:footnote>'.encode())
                part.write(b'''<w:footnote w:id="11001"><w:p><w:r><w:t>Nested note.</w:t></w:r></w:p></w:footnote>
                  <w:footnote w:id="11000"><w:p><w:r><w:t>First note.</w:t>
                  <w:footnoteReference w:id="11001"/></w:r></w:p></w:footnote>
                  <w:footnote w:id="11000"><w:p><w:r><w:t>Duplicate content.</w:t></w:r></w:p></w:footnote>
                  </w:footnotes>''')
            package.writestr('word/endnotes.xml', f'''<w:endnotes xmlns:w="{W}"><w:endnote w:id="5">
              <w:p><w:r><w:t>Endnote text.</w:t></w:r></w:p></w:endnote></w:endnotes>''')

        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                    notes = list(chapter.iter(f'{{{c.XH}}}aside'))
                    links = [node.get('href') for node in chapter.iter(f'{{{c.XH}}}a')]
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                    note_body = next(body for body in c.children(chapter, 'body') if body.get('name') == 'notes')
                    notes = c.children(note_body, 'section')
                    links = [node.get(f'{{{c.XL}}}href') for node in chapter.iter(f'{{{c.FB}}}a')
                             if node.get('type') == 'note']
                self.assertEqual(len(notes), 3)
                for note, expected in zip(notes, ('First note.', 'Endnote text.', 'Nested note.'), strict=True):
                    self.assertIn(expected, c.plain(note))
                self.assertEqual(links, ['#' + note.get('id') for note in notes])

    def test_docx_notes_keep_the_authored_number_fields_in_note_text(self):
        source = self.root / 'note-markers.docx'
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body><w:p><w:r>
              <w:t>Body text.</w:t><w:footnoteReference w:id="4"/>
              <w:footnoteReference w:id="7" w:customMarkFollows="1"/><w:t>†</w:t>
              <w:endnoteReference w:id="9"/>
              </w:r></w:p></w:body></w:document>''')
            package.writestr('word/footnotes.xml', f'''<w:footnotes xmlns:w="{W}">
              <w:footnote w:id="4"><w:p><w:r><w:t xml:space="preserve">Before </w:t><w:footnoteRef/>
              <w:t xml:space="preserve"> after.</w:t></w:r></w:p></w:footnote>
              <w:footnote w:id="7"><w:p><w:r><w:t>† Custom marker is literal.</w:t></w:r></w:p></w:footnote>
              </w:footnotes>''')
            package.writestr('word/endnotes.xml', f'''<w:endnotes xmlns:w="{W}">
              <w:endnote w:id="9"><w:p><w:r><w:endnoteRef/><w:t xml:space="preserve"> Endnote.</w:t>
              </w:r></w:p></w:endnote></w:endnotes>''')
            package.writestr('word/settings.xml', f'''<w:settings xmlns:w="{W}">
              <w:footnotePr><w:numStart w:val="12"/></w:footnotePr>
              <w:endnotePr><w:numFmt w:val="lowerRoman"/></w:endnotePr>
              </w:settings>''')

        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                    notes = list(chapter.iter(f'{{{c.XH}}}aside'))
                    self.assertEqual([note.get(f'{{{c.EP}}}type') for note in notes],
                                     ['footnote', 'footnote', 'endnote'])
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                    note_body = next(body for body in c.children(chapter, 'body') if body.get('name') == 'notes')
                    notes = c.children(note_body, 'section')
                self.assertEqual([c.plain(note) for note in notes],
                                 ['Before 12 after.', '† Custom marker is literal.', 'i Endnote.'])

    def test_docx_inline_canvas_preserves_shape_positions_and_surrounding_text(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        import io
        from PIL import Image

        def shape(preset, x, y, width, height, color):
            return (f'<wps:wsp><wps:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{width}" cy="{height}"/>'
                    f'</a:xfrm><a:prstGeom prst="{preset}"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="{color}"/>'
                    '</a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:round/>'
                    '</a:ln><a:effectLst/></wps:spPr></wps:wsp>')

        source = self.root / 'canvas.docx'
        modern = (shape('rect', 127000, 127000, 508000, 381000, 'FF0000') +
                  shape('ellipse', 889000, 254000, 508000, 381000, '0000FF'))
        with zipfile.ZipFile(source, 'w') as doc:
            doc.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
              xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
              xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
              xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
              xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
              xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
              <w:body><w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r><w:r><mc:AlternateContent>
                <mc:Choice Requires="wpc"><w:drawing><wp:inline><wp:extent cx="1524000" cy="762000"/>
                  <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas">
                    <wpc:wpc><wpc:bg><a:noFill/></wpc:bg><wpc:whole/>{modern}</wpc:wpc>
                  </a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice>
                <mc:Fallback><w:t>Fallback representation</w:t></mc:Fallback>
              </mc:AlternateContent></w:r><w:r><w:t xml:space="preserve"> after.</w:t></w:r></w:p></w:body>
              </w:document>''')

        pictures = []
        for ext in ('.epub', '.fb2'):
            with self.subTest(ext=ext):
                out = source.with_suffix(ext)
                report = c.convert_book(source, out, tools_root=tools)
                losses = c.damaged_content_warnings(report['warnings'])
                if ext == '.epub':
                    self.assertFalse(losses)
                else:
                    warning, = losses
                    self.assertTrue(warning.startswith('Размеры размещения иллюстраций сохранены в FB2'))
                if ext == '.epub':
                    with zipfile.ZipFile(out) as book:
                        body = c.first(c.xml(book.read('OEBPS/book.xhtml')), 'body')
                        image, = list(body.iter(f'{{{c.XH}}}img'))
                        self.assertEqual((image.get('width'), image.get('height')), ('160', '80'))
                        data = book.read('OEBPS/' + image.get('src'))
                else:
                    root = c.xml(out.read_bytes())
                    c.validate_fb2_output(root)
                    body = c.first(root, 'body')
                    canvas, = [n for n in body.iter(f'{{{c.FB}}}style') if n.get('name') == c.WORD_CANVAS_STYLE]
                    self.assertEqual(canvas[0].get('name'), c.FB2_IMAGE_SIZE_PREFIX + '160-80')
                    banner, = c.children(root, 'binary')
                    data = base64.b64decode(banner.text)
                self.assertEqual(' '.join(c.plain(body).split()), 'Before after.')
                with Image.open(io.BytesIO(data)) as image:
                    self.assertEqual(image.size, (480, 240))
                    self.assertEqual(image.getpixel((100, 100)), (255, 0, 0, 255))
                    self.assertEqual(image.getpixel((360, 140)), (0, 0, 255, 255))
                    self.assertEqual(image.getpixel((250, 100))[3], 0)
                pictures.append(data)
        self.assertEqual(len(pictures), 2)
        self.assertEqual(pictures[0], pictures[1])

    def test_docx_list_export_preserves_numbering_levels_styles_and_indent(self):
        source = self.root / 'structured-lists.docx'
        word = f'xmlns:w="{W}"'

        def item(text, number_id=None, level=None, style='', extra=''):
            style_ref = f'<w:pStyle w:val="{style}"/>' if style else ''
            number = f'<w:numId w:val="{number_id}"/>' if number_id is not None else ''
            number_level = f'<w:ilvl w:val="{level}"/>' if level is not None else ''
            numbering = f'<w:numPr>{number_level}{number}</w:numPr>' if number or number_level else ''
            return f'<w:p><w:pPr>{style_ref}{numbering}{extra}</w:pPr><w:r><w:t>{text}</w:t></w:r></w:p>'

        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'<w:document {word}><w:body>' + ''.join((
                item('First outer', 4, 0), item('First nested', style='NestedChild'), item('Interlude'),
                item('Second nested', 4, 1), item('Second outer', 4, 0),
                item('Restarted nested', 4, 1, extra='<w:ind w:start="900"/>'),
                item('Standalone bullet', 9, 0), item('Style numbering suppressed', 0, style='NestedChild'),
                item('First continuing', 4, 2), item('Third outer', 4, 0), item('Second continuing', 4, 2),
            )) + '</w:body></w:document>')
            package.writestr('word/_rels/document.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
                 Target="/word/lists/author%20lists.xml"/>
                </Relationships>''')
            package.writestr('word/styles.xml', f'''<w:styles {word}>
                <w:style w:type="paragraph" w:styleId="NestedBase"><w:pPr><w:numPr><w:numId w:val="4"/></w:numPr></w:pPr></w:style>
                <w:style w:type="paragraph" w:styleId="NestedChild"><w:basedOn w:val="NestedBase"/></w:style>
                </w:styles>''')
            package.writestr('word/lists/author lists.xml', f'''<w:numbering {word}>
                <w:abstractNum w:abstractNumId="2">
                  <w:lvl w:ilvl="0"><w:start w:val="2"/><w:numFmt w:val="upperRoman"/><w:lvlText w:val="(%1)"/>
                    <w:pPr><w:ind w:left="360" w:hanging="240"/></w:pPr></w:lvl>
                  <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2)"/>
                    <w:pStyle w:val="NestedBase"/><w:pPr><w:ind w:left="720" w:hanging="240"/></w:pPr></w:lvl>
                  <w:lvl w:ilvl="2"><w:start w:val="5"/><w:numFmt w:val="decimalZero"/><w:lvlText w:val="[%3]"/>
                    <w:lvlRestart w:val="0"/></w:lvl>
                </w:abstractNum>
                <w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/>
                    <w:lvlText w:val="§"/><w:suff w:val="nothing"/></w:lvl></w:abstractNum>
                <w:num w:numId="4"><w:abstractNumId w:val="2"/>
                    <w:lvlOverride w:ilvl="0"><w:startOverride w:val="4"/></w:lvlOverride></w:num>
                <w:num w:numId="9"><w:abstractNumId w:val="3"/></w:num>
                </w:numbering>''')

        expected = ['(IV) First outer', 'IV.a) First nested', 'Interlude', 'IV.b) Second nested',
                    '(V) Second outer', 'V.a) Restarted nested', '§Standalone bullet',
                    'Style numbering suppressed', '[05] First continuing', '(VI) Third outer',
                    '[06] Second continuing']
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                    paragraphs = list(chapter.iter(f'{{{c.XH}}}p'))
                    self.assertIn('margin-left:45pt', paragraphs[5].get('style', ''))
                    self.assertIn('text-indent:-12pt', paragraphs[5].get('style', ''))
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                    paragraphs = list(c.first(chapter, 'body').iter(f'{{{c.FB}}}p'))
                    marker = paragraphs[5].get('style')
                    self.assertTrue(marker)
                    stylesheet = '\n'.join(c.plain(n) for n in c.children(chapter, 'stylesheet'))
                    self.assertIn(f'p[style="{marker}"]{{margin-left:45pt;text-indent:-12pt}}', stylesheet)
                self.assertEqual([c.plain(node) for node in paragraphs], expected)

        reopened = source.with_name('reopened.epub')
        c.convert_book(source.with_suffix('.fb2'), reopened)
        with zipfile.ZipFile(reopened) as package:
            chapters = [c.xml(package.read(name)) for name in package.namelist() if name.endswith('.xhtml')]
        nested, = [node for doc in chapters for node in doc.iter(f'{{{c.XH}}}p')
                   if c.plain(node) == 'V.a) Restarted nested']
        self.assertEqual(nested.get('style'), 'margin-left:45pt;text-indent:-12pt')

    def test_docx_progress_measures_main_markup_and_reports_notes_separately(self):
        source = self.root / 'word-progress.docx'
        main = (f'<w:document xmlns:w="{W}"><w:body>'
                '<w:p><w:r><w:footnoteReference w:id="1"/></w:r></w:p>'
                + ('<w:p><w:r><w:t>' + 'Original text. ' * 3000 + '</w:t></w:r></w:p>') * 3
                + '</w:body></w:document>').encode()
        notes = (f'<w:footnotes xmlns:w="{W}"><w:footnote w:id="1"><w:p><w:r><w:t>'
                 + 'Note. ' * 15000 + '</w:t></w:r></w:p></w:footnote></w:footnotes>').encode()
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', main)
            archive.writestr('word/footnotes.xml', notes)
        progress = []
        output = source.with_suffix('.epub')
        c.convert_book(source, output, progress=lambda *step: progress.append(step))
        main_progress = [item[1:] for item in progress if item[0] == 'preparing-docx']
        note_progress = [item[1:] for item in progress if item[0] == 'preparing-docx-notes']
        self.assertEqual(main_progress, [(step, 3) for step in range(4)])
        self.assertEqual(note_progress, [(0, 0), (1, 0), (2, 0)])
        self.assertLess(progress.index(('preparing-docx', 3, 3)),
                        progress.index(('preparing-docx-notes', 0, 0)))

    def test_docx_russian_list_markers_survive_old_and_current_word_formats(self):
        source = self.root / 'russian-lists.docx'
        word = f'xmlns:w="{W}"'
        groups = (('msonfc58', 8, ['з', 'и', 'к', 'л']),
                  ('msonfc59', 28, ['Ю', 'Я', 'Аа', 'Аб']),
                  ('russianLower', 28, ['ю', 'я', 'аа', 'аб']),
                  ('russianUpper', 24, ['Ш', 'Щ', 'Ы', 'Э']))
        items, numbering, expected = [], [], []
        for identity, (form, start, markers) in enumerate(groups, 1):
            numbering.append(f'<w:abstractNum w:abstractNumId="{identity}"><w:lvl w:ilvl="0">'
                             f'<w:start w:val="{start}"/><w:numFmt w:val="{form}"/><w:lvlText w:val="%1)"/>'
                             f'</w:lvl></w:abstractNum><w:num w:numId="{identity}">'
                             f'<w:abstractNumId w:val="{identity}"/></w:num>')
            for position, label in enumerate(markers, 1):
                text = f'Item {identity}.{position}'
                items.append(f'<w:p><w:pPr><w:numPr><w:numId w:val="{identity}"/></w:numPr></w:pPr>'
                             f'<w:r><w:t>{text}</w:t></w:r></w:p>')
                expected.append(f'{label}) {text}')
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'<w:document {word}><w:body>{"".join(items)}</w:body></w:document>')
            package.writestr('word/numbering.xml', f'<w:numbering {word}>{"".join(numbering)}</w:numbering>')
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                    paragraphs = chapter.iter(f'{{{c.XH}}}p')
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                    paragraphs = c.first(chapter, 'body').iter(f'{{{c.FB}}}p')
                self.assertEqual([c.plain(node) for node in paragraphs], expected)

    def test_docx_picture_bullet_is_preserved_or_reports_missing_asset(self):
        for available in (True, False):
            source = self.root / f'picture-bullet-{available}.docx'
            word = f'xmlns:w="{W}"'
            with zipfile.ZipFile(source, 'w') as package:
                package.writestr('word/document.xml', f'''<w:document {word}><w:body><w:p><w:pPr>
                    <w:numPr><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Original item.</w:t></w:r>
                    </w:p></w:body></w:document>''')
                package.writestr('word/numbering.xml', f'''<w:numbering {word}
                    xmlns:v="urn:schemas-microsoft-com:vml" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                    <w:numPicBullet w:numPicBulletId="8"><w:pict><v:shape><v:imagedata r:id="i"/></v:shape></w:pict></w:numPicBullet>
                    <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/>
                      <w:lvlText w:val="§"/><w:lvlPicBulletId w:val="8"/></w:lvl></w:abstractNum>
                    <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num></w:numbering>''')
                package.writestr('word/_rels/numbering.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                    <Relationship Id="i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/p.png"/>
                    </Relationships>''')
                if available:
                    package.writestr('word/media/p.png', PNG)

            for suffix in ('.epub', '.fb2'):
                with self.subTest(available=available, suffix=suffix):
                    output = source.with_suffix(suffix)
                    report = c.convert_book(source, output)
                    if suffix == '.epub':
                        with zipfile.ZipFile(output) as package:
                            root = c.xml(package.read('OEBPS/book.xhtml'))
                            marks = list(root.iter(f'{{{c.XH}}}img'))
                            if available:
                                mark, = marks
                                self.assertEqual(mark.get('class'), c.EPUB_LIST_MARKER_STYLE)
                                self.assertEqual(package.read('OEBPS/' + mark.get('src')), PNG)
                    else:
                        root = c.xml(output.read_bytes())
                        c.validate_fb2_output(root)
                        marks = list(root.iter(f'{{{c.FB}}}image'))
                        if available:
                            mark, = marks
                            style, = [n for n in root.iter(f'{{{c.FB}}}style') if n.get('name') == c.EPUB_LIST_MARKER_STYLE]
                            self.assertIs(style[0], mark)
                            binary, = c.children(root, 'binary')
                            self.assertEqual(base64.b64decode(binary.text), PNG)
                    losses = c.damaged_content_warnings(report['warnings'])
                    if available:
                        self.assertIn('Original item.', c.plain(root))
                        self.assertFalse(losses)
                    else:
                        self.assertFalse(marks)
                        self.assertIn('§ Original item.', c.plain(root))
                        self.assertTrue(any('недоступен рисунок «8»' in loss for loss in losses))

    def test_docx_note_labels_follow_word_numbering_and_keep_repeated_targets(self):
        source = self.root / 'note-labels.docx'
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/_rels/document.xml.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="s" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="props/book-settings.xml"/>
              <Relationship Id="n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes" Target="/word/notes/book%20endnotes.xml"/>
              </Relationships>''')
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body><w:p>
              <w:r><w:t>Text A.</w:t><w:footnoteReference w:id="7"/></w:r>
              <w:r><w:t>Text B.</w:t><w:endnoteReference w:id="7"/></w:r>
              <w:r><w:t>Text C.</w:t><w:footnoteReference w:id="7"/></w:r>
              <w:r><w:footnoteReference w:id="8" w:customMarkFollows="1"/><w:t>†</w:t><w:t>Custom tail.</w:t></w:r>
              <w:r><w:footnoteReference w:id="8"/><w:footnoteReference w:id="9"/><w:endnoteReference w:id="8"/></w:r>
              </w:p></w:body></w:document>''')
            package.writestr('word/props/book-settings.xml', f'''<w:settings xmlns:w="{W}">
              <w:footnotePr><w:numFmt w:val="lowerRoman"/><w:numStart w:val="4"/></w:footnotePr>
              <w:endnotePr><w:numFmt w:val="decimalZero"/><w:numStart w:val="9"/></w:endnotePr>
              </w:settings>''')
            for family, path, ids in (('footnote', 'word/footnotes.xml', (7, 8, 9)),
                                      ('endnote', 'word/notes/book endnotes.xml', (7, 8))):
                package.writestr(path, f'<w:{family}s xmlns:w="{W}">' + ''.join(
                    f'<w:{family} w:id="{identity}"><w:p><w:r><w:t>{family} {identity} body.</w:t></w:r></w:p></w:{family}>'
                    for identity in ids) + f'</w:{family}s>')

        for suffix, marker in (('.epub', f'{{{c.EP}}}type'), ('.fb2', 'type')):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                    href, kind = 'href', 'noteref'
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                    href, kind = f'{{{c.XL}}}href', 'note'
                notes = [node for node in chapter.iter() if c.tag(node) == 'a' and node.get(marker) == kind]
                self.assertEqual([c.plain(node) for node in notes], ['iv', '09', 'iv', '†', '†', 'v', '10'])
                self.assertEqual(notes[0].get(href), notes[2].get(href))
                self.assertEqual(notes[3].get(href), notes[4].get(href))
                self.assertNotEqual(notes[0].get(href), notes[1].get(href))
                self.assertIn('Custom tail.', c.plain(chapter))
                self.assertEqual(c.plain(chapter).count('†'), 2)
                for contents in ('footnote 7 body.', 'footnote 8 body.', 'footnote 9 body.',
                                 'endnote 7 body.', 'endnote 8 body.'):
                    self.assertEqual(c.plain(chapter).count(contents), 1)

    def test_docx_damaged_note_settings_keep_note_text_and_report_numbering_loss(self):
        source = self.root / 'damaged-note-settings.docx'
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body><w:p>
              <w:r><w:t>Body text.</w:t><w:footnoteReference w:id="1"/></w:r></w:p></w:body></w:document>''')
            package.writestr('word/footnotes.xml', f'''<w:footnotes xmlns:w="{W}"><w:footnote w:id="1">
              <w:p><w:r><w:t>Original note.</w:t></w:r></w:p></w:footnote></w:footnotes>''')
            package.writestr('word/settings.xml', f'<w:settings xmlns:w="{W}"><w:footnotePr>')

        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                result = c.convert_book(source, output)
                warning, = c.damaged_content_warnings(result['warnings'])
                self.assertIn('Файл настроек повреждён', warning)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as package:
                        chapter = c.xml(package.read('OEBPS/book.xhtml'))
                else:
                    chapter = c.xml(output.read_bytes())
                    c.validate_fb2_output(chapter)
                self.assertEqual(c.plain(chapter).count('Original note.'), 1)

    def test_docx_missing_footnote_pictures_keep_authored_alternative_text(self):
        source = self.root / 'quote.docx'
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body><w:p><w:r>
                <w:t>Примечание</w:t><w:footnoteReference w:id="23"/>
                </w:r></w:p></w:body></w:document>''')
            package.writestr('word/footnotes.xml', f'''<w:footnotes xmlns:w="{W}"
                xmlns:v="urn:schemas-microsoft-com:vml"><w:footnote w:id="23"><w:tbl><w:tr>
                <w:tc><w:p><w:r><w:pict><v:shapetype id="_x0000_t75"/>
                <v:shape type="#_x0000_t75" alt="«"/></w:pict></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>Цитата из книги</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:pict><v:shape type="#_x0000_t75" alt="»"/>
                </w:pict></w:r></w:p></w:tc>
                </w:tr></w:tbl></w:footnote></w:footnotes>''')
        for extension in ('epub', 'fb2'):
            output = self.root / f'quote.{extension}'
            report = c.convert_book(source, output)
            losses = c.damaged_content_warnings(report['warnings'])
            self.assertEqual(len(losses), 2)
            self.assertIn('Сохранён альтернативный текст («).', losses[0])
            self.assertIn('Сохранён альтернативный текст (»).', losses[1])
            if extension == 'fb2':
                root = c.xml(output.read_bytes())
                c.validate_fb2_output(root)
                cells = list(root.iter(f'{{{c.FB}}}td'))
            else:
                with zipfile.ZipFile(output) as package:
                    chapters = [name for name in package.namelist() if name.endswith('.xhtml')
                                and not name.endswith('/nav.xhtml')]
                    cells = [cell for name in chapters for cell in c.xml(package.read(name)).iter(f'{{{c.XH}}}td')]
            self.assertEqual([c.plain(cell) for cell in cells], ['«', 'Цитата из книги', '»'])

    def test_docx_full_width_rules_keep_each_placement(self):
        source = self.root / 'horizontal-rules.docx'

        def rule(height, extra=''):
            return (f'<w:p><w:r><w:pict><v:rect style="width:0;height:{height}pt" o:hr="t" '
                    f'o:hrstd="t" o:hrnoshade="t" fillcolor="#a0a0a0" stroked="f" {extra}/></w:pict></w:r></w:p>')

        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
                xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"><w:body>
                <w:p><w:r><w:t>Начало</w:t></w:r></w:p>
                <w:tbl><w:tr><w:tc>{rule('.6')}<w:p><w:r><w:t>Ячейка</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>Справа</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
                {rule('.7')}{rule('.6', 'o:hrpct="250"')}
                <w:p><w:r><w:t>Конец</w:t></w:r></w:p>
                </w:body></w:document>''')

        def epub_rules(path):
            with zipfile.ZipFile(path) as package:
                result = []
                for chapter in package.namelist():
                    if chapter.endswith('.xhtml') and not chapter.endswith('/nav.xhtml'):
                        for image in c.xml(package.read(chapter)).iter(f'{{{c.XH}}}img'):
                            result.append(image.get('style'))
                return result

        epub, fb2, roundtrip = (self.root / name for name in ('rule.epub', 'rule.fb2', 'rule-roundtrip.epub'))
        report = c.convert_book(source, epub)
        damage = c.damaged_content_warnings(report['warnings'])
        self.assertEqual(sum(message.startswith('Не перенесён объект DOCX') for message in damage), 1)
        expected = ['display:block;width:100%;height:0.6pt', 'display:block;width:100%;height:0.7pt']
        self.assertEqual(epub_rules(epub), expected)

        c.convert_book(source, fb2)
        root = c.xml(fb2.read_bytes())
        c.validate_fb2_output(root)
        lines = [n for n in root.iter(f'{{{c.FB}}}style') if c.word_rule_height(n.get('name', ''))]
        self.assertEqual([c.word_rule_height(line.get('name')) for line in lines], [12, 14])
        self.assertEqual(len({line[0].get(f'{{{c.XL}}}href') for line in lines}), 1)
        first_cell = next(root.iter(f'{{{c.FB}}}td'))
        self.assertIn(lines[0], list(first_cell.iter()))
        c.convert_book(fb2, roundtrip)
        self.assertEqual(epub_rules(roundtrip), expected)

    def test_docx_anchored_horizontal_line_keeps_its_dimensions_and_paragraph(self):
        source = self.root / 'anchored-line.docx'

        def rule(end='329.8pt,2.2pt', after=''):
            return (f'<w:p><w:r><w:pict><v:line from="-.15pt,2.2pt" to="{end}" strokeweight=".25pt" '
                    'strokecolor="#104880" style="position:absolute;z-index:-100;mso-wrap-style:square;'
                    'mso-position-horizontal-relative:text;mso-position-vertical-relative:text">'
                    f'<o:lock/></v:line></w:pict>{after}</w:r></w:p>')

        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
                xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"><w:body>
                <w:p><w:r><w:t>До линии</w:t></w:r></w:p>{rule()}
                <w:p><w:r><w:t>После линии</w:t></w:r></w:p>
                {rule('329.8pt,2.7pt')}{rule(after='<w:t>Смешанный абзац</w:t>')}
                </w:body></w:document>''')
        epub, fb2, restored = (self.root / name for name in ('line.epub', 'line.fb2', 'line-back.epub'))
        report = c.convert_book(source, epub)
        self.assertEqual(len(c.damaged_content_warnings(report['warnings'])), 2)
        c.convert_book(source, fb2)
        book = c.xml(fb2.read_bytes())
        c.validate_fb2_output(book)
        marker = 'homelibre-word-line-6599:47:-3'
        markers = [node.get('name') for node in book.iter(f'{{{c.FB}}}style') if c.word_line_geometry(node.get('name', ''))]
        self.assertEqual(markers, [marker])
        c.convert_book(fb2, restored)
        images = []
        for path in (epub, restored):
            with zipfile.ZipFile(path) as package:
                chapters = [name for name in package.namelist() if name.endswith('.xhtml') and not name.endswith('/nav.xhtml')]
                for chapter in chapters:
                    body = c.first(c.xml(package.read(chapter)), 'body')
                    for index, paragraph in enumerate(p for p in body.iter(f'{{{c.XH}}}p')):
                        image = next(paragraph.iter(f'{{{c.XH}}}img'), None)
                        if image is None:
                            continue
                        self.assertEqual(index, 1)
                        self.assertIn(marker, image.get('class', '').split())
                        self.assertIn('width:329.95pt;height:2.35pt', image.get('style', ''))
                        self.assertIn('margin-left:-0.15pt', image.get('style', ''))
                        images.append(package.read(posixpath.normpath(posixpath.join(posixpath.dirname(chapter), image.get('src')))))
        self.assertEqual(len(images), 2)
        self.assertEqual(images[0], images[1])
        self.assertEqual(images[0][25], 6)  # RGBA keeps the vertical offset transparent.

    def test_docx_margin_lines_stay_attached_to_their_paragraph(self):
        source = self.root / 'margin-lines.docx'
        epub, fb2, roundtrip = (self.root / name for name in ('book.epub', 'book.fb2', 'fb2.epub'))
        wp = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'

        def rule(side, top, width='1500'):
            return f'''<w:drawing><wp:anchor behindDoc="1">
              <wp:positionH relativeFrom="margin"><wp:posOffset>31750</wp:posOffset></wp:positionH>
              <wp:positionV relativeFrom="paragraph"><wp:posOffset>{top}</wp:posOffset></wp:positionV>
              <wp:extent cx="{width}" cy="635000"/><wp:wrapNone/>
              <wp:docPr name="HomeLibreMarginRule-{side}-10-240" id="1"/>
            </wp:anchor></w:drawing>'''

        with zipfile.ZipFile(source, 'w') as z:
            z.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:wp="{wp}"><w:body>
              <w:p><w:r>{rule('left', -635)}{rule('left', -635)}</w:r><w:r><w:t>Начало</w:t></w:r></w:p>
              <w:p><w:r>{rule('right', 635)}{rule('left', 0, '0')}<w:t>Продолжение</w:t></w:r></w:p>
            </w:body></w:document>''')

        def xhtml_rows(path):
            with zipfile.ZipFile(path) as z:
                book, = (name for name in z.namelist() if name.endswith('.xhtml') and '/nav.' not in name)
                body = c.first(c.xml(z.read(book)), 'body')
                self.assertIn('padding-right:', body.get('style'))
                groups = []
                for paragraph in body.iter(f'{{{c.XH}}}p'):
                    self.assertIn('position:relative', paragraph.get('style'))
                    self.assertFalse(any(c.tag(n) == 'img' for n in paragraph))
                    marks = [c.margin_rule_class(node) for node in paragraph]
                    for node, marker in zip(paragraph, marks):
                        self.assertIn(c.margin_rule_geometry(marker)[0] + ':-', node.get('style'))
                    groups.append((''.join(paragraph.itertext()), marks))
                return groups

        left = c.MARGIN_RULE_PREFIX + 'left:10:240:31750:-635:635000:1500'
        right = c.MARGIN_RULE_PREFIX + 'right:10:240:31750:635:635000:1500'
        expected = [('Начало', [left, left]), ('Продолжение', [right])]
        initial = c.convert_book(source, epub)
        self.assertEqual(xhtml_rows(epub), expected)
        self.assertTrue(any('Пропущено линий: 1.' in msg for msg in c.damaged_content_warnings(initial['warnings'])))
        output = c.convert_book(source, fb2)
        root = c.xml(fb2.read_bytes())
        c.validate_fb2_output(root)
        paragraphs = c.first(root, 'body').iter(f'{{{c.FB}}}p')
        self.assertEqual([(''.join(p.itertext()), [n.get('name') for n in p]) for p in paragraphs], expected)
        self.assertTrue(any('Другие читалки FB2' in msg for msg in c.damaged_content_warnings(output['warnings'])))
        c.convert_book(fb2, roundtrip)
        self.assertEqual(xhtml_rows(roundtrip), expected)

    def test_docx_floating_line_previews_keep_images_and_request_consent(self):
        source = self.root / 'floating-line-previews.docx'
        identities = ('rIdHomeLibreFloatingLineGroup1', 'rIdHomeLibreLinePage2', 'rIdHomeLibreParagraphRuleStart3')
        marker = 'homelibre-word-line-9470:30:86'
        pictures = ''.join(f'<w:p><w:r><w:drawing><a:blip r:embed="{identity}"/></w:drawing></w:r></w:p>'
                           for identity in identities[:2])
        pictures += (f'<w:p><w:r><w:drawing><wp:inline><wp:docPr descr="{marker}"/>'
                     f'<a:blip r:embed="{identities[2]}"/></wp:inline></w:drawing></w:r></w:p>')
        relationships = ''.join(f'<Relationship Id="{identity}" Target="media/lines.png"/>'
                                for identity in identities)
        with zipfile.ZipFile(source, 'w') as package:
            package.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body>
                <w:p><w:r><w:t>Текст перед линиями</w:t></w:r></w:p>
                {pictures}<w:p><w:r><w:t>Текст после линий</w:t></w:r></w:p></w:body></w:document>''')
            package.writestr('word/_rels/document.xml.rels', '<Relationships '
                             'xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                             + relationships + '</Relationships>')
            package.writestr('word/media/lines.png', PNG)
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertTrue(any(message.startswith('Линии старого DOC') for message in warnings))
                self.assertTrue(any(message.startswith('Страница схемы старого DOC') for message in warnings))
                self.assertTrue(any(message.startswith('Разделители страниц DOC') for message in warnings))
                if extension == '.epub':
                    with zipfile.ZipFile(output) as package:
                        document = c.xml(package.read('OEBPS/book.xhtml'))
                        images = document.findall('.//{*}img')
                        self.assertTrue(all(package.read('OEBPS/' + node.get('src')) == PNG for node in images))
                    self.assertEqual(images[0].get('class'), 'paragraph-rule')
                    self.assertIn(marker, images[-1].get('class', '').split())
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                    images = document.findall('.//{*}image')
                    [asset] = document.findall('./{*}binary')
                    self.assertEqual(base64.b64decode(asset.text), PNG)
                    self.assertTrue(any(node.get('name') == marker for node in document.iter(f'{{{c.FB}}}style')))
                self.assertEqual(len(images), 3)
                self.assertEqual(''.join(c.first(document, 'body').itertext()),
                                 'Текст перед линиямиТекст после линий')

    def test_docx_preserves_deep_outline_levels_and_body_text_override(self):
        source = self.root / 'deep-outline.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>
                <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:r><w:t>Раздел</w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Седьмой"/></w:pPr><w:r><w:t>Седьмой уровень</w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Наследник"/></w:pPr><w:r><w:t>Девятый уровень</w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Наследник"/><w:outlineLvl w:val="7"/></w:pPr>
                    <w:r><w:t>Восьмой уровень</w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Heading1"/><w:outlineLvl w:val="9"/></w:pPr>
                    <w:r><w:t>Обычный абзац</w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t> </w:t></w:r></w:p>
                <w:p><w:pPr><w:pStyle w:val="Heading9"/></w:pPr>
                    <w:r><w:drawing><a:blip r:embed="figure"/></w:drawing></w:r></w:p>
                <w:tbl><w:tr><w:tc><w:p><w:pPr><w:outlineLvl w:val="8"/></w:pPr>
                    <w:r><w:t>Заголовок ячейки</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
                <w:p><w:pPr><w:pStyle w:val="Heading9"/></w:pPr><w:r><w:t>Последний заголовок</w:t></w:r></w:p>
                </w:body></w:document>''')
            archive.writestr('word/styles.xml', f'''<w:styles xmlns:w="{W}">
                <w:style w:type="paragraph" w:styleId="Седьмой"><w:pPr><w:outlineLvl w:val="6"/></w:pPr></w:style>
                <w:style w:type="paragraph" w:styleId="Девятый"><w:pPr><w:outlineLvl w:val="8"/></w:pPr></w:style>
                <w:style w:type="paragraph" w:styleId="Наследник"><w:basedOn w:val="Девятый"/></w:style>
                </w:styles>''')
            archive.writestr('word/_rels/document.xml.rels', '<Relationships><Relationship Id="figure" Target="media/figure.png"/></Relationships>')
            archive.writestr('word/media/figure.png', PNG)
        labels = ['Раздел', 'Седьмой уровень', 'Девятый уровень', 'Восьмой уровень',
                  'Заголовок ячейки', 'Последний заголовок']
        self.outputs(source, labels + ['Обычный абзац'], image=True)
        with zipfile.ZipFile(self.root / 'deep-outline.docx.epub') as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            links = list(nav.iter('{' + c.XH + '}a'))
            self.assertEqual([c.plain(link) for link in links], labels)
            by_id = {node.get('id'): node for node in body.iter() if node.get('id')}
            self.assertEqual([c.plain(by_id[link.get('href').split('#')[1]]) for link in links], labels)
            self.assertEqual([node.get('aria-level') for node in body.iter() if node.get('role') == 'heading'],
                             ['7', '9', '8', '9', '9'])
            nested = next(nav.iter('{' + c.XH + '}ol'))
            section = c.first(nested[0], 'ol')
            levels = c.first(section[0], 'ol')
            self.assertEqual([c.plain(c.first(node, 'a')) for node in levels], labels[2:4])
            self.assertEqual([c.plain(c.first(node, 'a')) for node in c.first(levels[1], 'ol')], labels[4:])
        target = self.root / 'deep-outline.docx.fb2'
        fb2 = c.first(c.xml(target.read_bytes()), 'body')
        self.assertEqual([c.plain(node) for node in fb2.iter('{' + c.FB + '}title')], labels[:4] + labels[5:])
        table_heading = next(node for node in fb2.iter() if node.get('name') == c.FB2_TABLE_HEADING + '9')
        self.assertEqual(c.plain(table_heading), labels[4])
        roundtrip = self.root / 'deep-outline-roundtrip.epub'
        c.convert_book(target, roundtrip)
        with zipfile.ZipFile(roundtrip) as archive:
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            self.assertEqual([c.plain(link) for link in nav.iter('{' + c.XH + '}a')], labels)

    def test_docx_title_styles_keep_multiline_navigation_labels(self):
        source = self.root / 'word-title.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body>
              <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:rPr><w:b/></w:rPr>
                <w:br w:type="page"/><w:t>Дополнение</w:t><w:br/><w:t>к разделу</w:t>
              </w:r></w:p>
              <w:p><w:pPr><w:pStyle w:val="Title"/><w:outlineLvl w:val="9"/></w:pPr>
                <w:r><w:t>Текст без пункта</w:t></w:r></w:p>
              <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:br/></w:r></w:p>
            </w:body></w:document>''')
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        c.convert_book(source, epub)
        with zipfile.ZipFile(epub) as archive:
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            [link] = nav.findall('.//{*}a')
            self.assertEqual(c.plain(link), 'Дополнение к разделу')
            document = c.xml(archive.read('OEBPS/book.xhtml'))
            [heading] = document.findall('.//{*}h1')
            self.assertEqual(link.get('href'), 'book.xhtml#' + heading.get('id'))
            self.assertEqual(len(heading.findall('.//{*}br')), 2)
        c.convert_book(source, fb2)
        document = c.xml(fb2.read_bytes())
        c.validate_fb2_output(document)
        [title] = c.first(document, 'body').findall('.//{*}title')
        self.assertEqual([c.plain(line) for line in title if c.plain(line)], ['Дополнение', 'к разделу'])

    def test_docx_field_instructions_are_hidden_but_literal_text_survives(self):
        source = self.root / 'field.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body>
                <w:p><w:r><w:t>До поля.</w:t><w:fldChar w:fldCharType="begin"/></w:r></w:p>
                <w:p><w:r><w:instrText>INSTRUCTION_OUTER</w:instrText>
                    <w:fldChar w:fldCharType="begin"/><w:instrText>INSTRUCTION_NESTED</w:instrText>
                    <w:fldChar w:fldCharType="separate"/><w:instrText>INSTRUCTION_NESTED_RESULT</w:instrText>
                    <w:fldChar w:fldCharType="end"/><w:instrText>INSTRUCTION_OUTER_TAIL</w:instrText></w:r></w:p>
                <w:p><w:r><w:fldChar w:fldCharType="separate"/><w:instrText>Результат поля.</w:instrText>
                    <w:fldChar w:fldCharType="end"/></w:r></w:p>
                <w:p><w:r><w:t>Обычный</w:t><w:instrText xml:space="preserve"> текст.</w:instrText></w:r></w:p>
                <w:p><w:r><w:instrText>Следующий абзац.</w:instrText></w:r></w:p>
                </w:body></w:document>''')
        self.outputs(source, ['До поля.', 'Результат поля.', 'Обычный текст.', 'Следующий абзац.'])
        with zipfile.ZipFile(self.root / 'field.docx.epub') as archive:
            self.assertNotIn(b'INSTRUCTION_', archive.read('OEBPS/book.xhtml'))
        self.assertNotIn(b'INSTRUCTION_', (self.root / 'field.docx.fb2').read_bytes())

    def test_docx_white_page_overlays_report_loss_without_inserting_labels_in_prose(self):
        source = self.root / 'white-page-overlays.docx'
        style = ('position:absolute;margin-left:7.2pt;margin-top:532.8pt;width:72.05pt;height:21.65pt;'
                 'mso-position-horizontal-relative:page;mso-position-vertical-relative:page;z-index:4;')
        white = f'<w:pict><v:rect id="shape1" type="#_x0000_t1" stroked="f" style="{style}"/></w:pict>'
        under = white.replace('z-index:4', 'z-index:-4').replace('shape1', 'shape2')
        colored = white.replace('id="shape1"', 'id="shape3" fillcolor="#ff0000"')
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:v="urn:schemas-microsoft-com:vml">
                <w:body><w:p><w:r><w:t>До</w:t>{white}<w:t xml:space="preserve"> и после.</w:t></w:r></w:p>
                <w:p><w:r>{white.replace('shape1', 'shape4')}{under}{colored}<w:t>Второй абзац.</w:t></w:r></w:p>
                </w:body></w:document>''')
        before = source.read_bytes()
        for extension in ('.epub', '.fb2'):
            output = source.with_suffix(extension)
            result = c.convert_book(source, output)
            warnings = c.damaged_content_warnings(result['warnings'])
            [overlay] = [message for message in warnings if message.startswith(c.DOCX_PAGE_OVERLAYS)]
            self.assertIn('(2)', overlay)
            self.assertIn('исходный формат', overlay)
            self.assertEqual(sum(message.startswith('Не перенесён объект DOCX') for message in warnings), 2)
            if extension == '.epub':
                with zipfile.ZipFile(output) as book:
                    root = c.xml(book.read('OEBPS/book.xhtml'))
            else:
                root = c.xml(output.read_bytes())
                c.validate_fb2_output(root)
            self.assertEqual(c.plain(root.findall('.//{*}body//{*}p')[0]), 'До и после.')
        self.assertEqual(source.read_bytes(), before)

    def test_docx_hidden_runs_preserve_visible_content_and_field_boundaries(self):
        source = self.root / 'hidden-word-content.docx'
        drawing = '<w:pict><v:shape><v:imagedata r:id="picture"/></v:shape></w:pict>'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/styles.xml', f'''<w:styles xmlns:w="{W}">
              <w:style w:type="paragraph" w:styleId="Hide"><w:rPr><w:vanish/></w:rPr></w:style>
              <w:style w:type="paragraph" w:styleId="Inherited"><w:basedOn w:val="Hide"/></w:style>
              <w:style w:type="paragraph" w:styleId="Cleared"><w:basedOn w:val="Hide"/>
                <w:rPr><w:vanish w:val="off"/></w:rPr></w:style>
              <w:style w:type="character" w:styleId="Toggle"><w:rPr><w:vanish w:val="on"/></w:rPr></w:style>
            </w:styles>''')
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:v="urn:schemas-microsoft-com:vml"><w:body>
              <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:bookmarkStart w:id="4" w:name="title"/>
                <w:r><w:t>Видимый заголовок</w:t></w:r>
                <w:r><w:rPr><w:vanish/></w:rPr><w:t>HIDDEN_TITLE</w:t></w:r></w:p>
              <w:p><w:r>{drawing}</w:r><w:r><w:rPr><w:vanish/></w:rPr>{drawing}</w:r></w:p>
              <w:p><w:pPr><w:pStyle w:val="Inherited"/></w:pPr>
                <w:hyperlink w:anchor="title"><w:r><w:t>HIDDEN_LINK</w:t></w:r></w:hyperlink>
                <w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t>Прямое раскрытие</w:t></w:r>
                <w:r><w:rPr><w:rStyle w:val="Toggle"/></w:rPr><w:t>Раскрытие стилем</w:t></w:r></w:p>
              <w:p><w:pPr><w:pStyle w:val="Cleared"/></w:pPr><w:r><w:t>Открытый стиль</w:t></w:r></w:p>
              <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r></w:p>
              <w:p><w:r><w:instrText>HIDDEN_FIELD</w:instrText></w:r></w:p>
              <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r>
                <w:r><w:instrText>Результат поля</w:instrText><w:fldChar w:fldCharType="end"/></w:r></w:p>
            </w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels',
                             f'<Relationships><Relationship Id="picture" Type="{R}/image" '
                             'Target="media/figure.png"/></Relationships>')
            archive.writestr('word/media/figure.png', PNG)
        before = source.read_bytes()
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        for output in (epub, fb2):
            c.convert_book(source, output)
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
            [image] = chapter.findall('.//{*}img')
            self.assertEqual(archive.read('OEBPS/' + image.get('src')), PNG)
            nav = c.xml(archive.read('OEBPS/nav.xhtml'))
            [link] = nav.findall('.//{*}a')
            self.assertEqual(c.plain(link), 'Видимый заголовок')
        fb2_document = c.xml(fb2.read_bytes())
        c.validate_fb2_output(fb2_document)
        [image] = fb2_document.findall('.//{*}body//{*}image')
        self.assertTrue(image.get('{' + c.XL + '}href'))
        for document in (chapter, fb2_document):
            text = c.plain(document)
            for expected in ('Видимый заголовок', 'Прямое раскрытие', 'Раскрытие стилем', 'Открытый стиль', 'Результат поля'):
                self.assertIn(expected, text)
            self.assertNotIn('HIDDEN_', text)
        self.assertEqual(source.read_bytes(), before)

    def test_reflowed_word_plot_keeps_image_and_reports_layout_change(self):
        source = self.root / 'plot.docx'
        identity = 'rIdHomeLibreFigure1'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                <w:body><w:p><w:r><w:t>Подпись графика</w:t></w:r></w:p>
                <w:p><w:r><w:drawing><wp:inline>
                <wp:docPr id="1" name="Plot" descr="E, t"/>
                <a:graphic><a:graphicData><a:blip r:embed="{identity}"/></a:graphicData></a:graphic>
                </wp:inline></w:drawing></w:r></w:p></w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels',
                             f'<Relationships><Relationship Id="{identity}" Type="{R}/image" '
                             f'Target="media/plot.png"/></Relationships>')
            archive.writestr('word/media/plot.png', PNG)
        before = source.read_bytes()
        target = source.with_suffix('.epub')
        report = c.convert_book(source, target)
        self.assertTrue(any(note.startswith('Графики старого DOC') for note in
                            c.damaged_content_warnings(report['warnings'])))
        with zipfile.ZipFile(target) as archive:
            root = c.xml(archive.read('OEBPS/book.xhtml'))
            [figure] = [node for node in root.iter() if c.tag(node) == 'img']
            self.assertIn('Подпись графика', c.plain(root))
            self.assertEqual(figure.get('alt'), 'E, t')
            self.assertEqual(archive.read('OEBPS/' + figure.get('src')), PNG)
        self.assertEqual(source.read_bytes(), before)

    def test_docx_object_preview_stays_in_place_without_opening_the_object(self):
        source = self.root / 'equation.docx'
        vml = 'urn:schemas-microsoft-com:vml'
        office = 'urn:schemas-microsoft-com:office:office'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}" xmlns:v="{vml}" xmlns:o="{office}"><w:body>
                <w:p><w:r><w:t>Term before</w:t><w:object><v:shape style="width:35.25pt;height:12.75pt"><v:imagedata r:id="preview"/></v:shape>
                <o:OLEObject r:id="object" ProgID="Equation.DSMT4"/></w:object><w:t>Term after</w:t></w:r></w:p>
                <w:p><w:r><w:object><v:shape><v:imagedata r:id="missing"/></v:shape><o:OLEObject r:id="object"/></w:object></w:r></w:p>
                </w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', f'''<Relationships>
                <Relationship Id="preview" Type="{R}/image" Target="media/formula.png"/>
                <Relationship Id="missing" Type="{R}/image" Target="media/missing.png"/>
                <Relationship Id="object" Type="{R}/oleObject" Target="embeddings/formula.bin"/>
                </Relationships>''')
            archive.writestr('word/media/formula.png', PNG)
            archive.writestr('word/embeddings/formula.bin', b'Not an executable equation.')
        original = source.read_bytes()
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                target = source.with_suffix(extension)
                report = c.convert_book(source, target)
                notices = c.damaged_content_warnings(report['warnings'])
                self.assertTrue(any('Данные для редактирования объектов не перенесены' in item for item in notices))
                self.assertTrue(any('missing.png' in item for item in notices))
                if extension == '.epub':
                    with zipfile.ZipFile(target) as archive:
                        root = c.xml(archive.read('OEBPS/book.xhtml'))
                        body = c.first(root, 'body')
                        [image] = [n for n in body.iter() if c.tag(n) == 'img']
                        self.assertEqual(image.get('width'), '47')
                        self.assertEqual(archive.read('OEBPS/' + image.get('src')), PNG)
                        self.assertFalse(any(name.endswith('.bin') for name in archive.namelist()))
                else:
                    root = c.xml(target.read_bytes())
                    c.validate_fb2_output(root)
                    body = c.first(root, 'body')
                    [image] = [n for n in body.iter() if c.tag(n) == 'image']
                    [binary] = [n for n in root if c.tag(n) == 'binary']
                    self.assertEqual(base64.b64decode(binary.text), PNG)
                paragraph = next(n for n in body.iter() if image in n)
                self.assertEqual(paragraph.text, 'Term before')
                self.assertEqual(image.tail, 'Term after')
        self.assertEqual(source.read_bytes(), original)
    def test_docx_compatibility_branches_keep_textbox_tables_once(self):
        source = self.root / 'word-compatibility.docx'
        box = '''<w:txbxContent><w:p><w:r><w:t>Подпись в рамке</w:t></w:r></w:p>
          <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Первый столбец</w:t></w:r></w:p></w:tc>
          <w:tc><w:p><w:r><w:t>Второй столбец</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:txbxContent>'''
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
              xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
              xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
              xmlns:v="urn:schemas-microsoft-com:vml" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>До рамки</w:t>
              <mc:AlternateContent>
              <mc:Choice Requires="wps"><w:drawing><wps:wsp><wps:txbx>{box}</wps:txbx></wps:wsp></w:drawing></mc:Choice>
              <mc:Fallback><w:pict><v:shape><v:textbox>{box}</v:textbox></v:shape></w:pict></mc:Fallback>
              </mc:AlternateContent><w:t>После рамки</w:t></w:r></w:p>
              <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="wps"><w:drawing><wps:wsp><a:blip r:embed="missing"/></wps:wsp></w:drawing></mc:Choice>
              <mc:Fallback><w:pict><v:shape><v:imagedata r:id="image"/></v:shape></w:pict></mc:Fallback>
              </mc:AlternateContent></w:r></w:p></w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', '''<Relationships
              xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="image" Target="media/p.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
              </Relationships>''')
            archive.writestr('word/media/p.png', PNG)
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = self.root / ('compatibility' + suffix)
                metadata = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        self.assertEqual([archive.read(name) for name in archive.namelist() if '/images/' in name], [PNG])
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                body = c.first(document, 'body')
                text = c.plain(body)
                self.assertEqual(text.count('Подпись в рамке'), 1)
                self.assertLess(text.index('До рамки'), text.index('Подпись в рамке'))
                self.assertLess(text.index('Второй столбец'), text.index('После рамки'))
                tables = [node for node in body.iter() if c.tag(node) == 'table']
                self.assertEqual(len(tables), 1)
                self.assertEqual([c.plain(n) for n in tables[0].iter() if c.tag(n) == 'td'], ['Первый столбец', 'Второй столбец'])
                self.assertEqual([c.plain(n) for n in body.iter() if c.tag(n) == 'strong'], ['До рамки', 'После рамки'])
                self.assertFalse(any(c.tag(d) == 'table' for n in body.iter() if c.tag(n) == 'p' for d in n.iter()))
                warning, = c.damaged_content_warnings(metadata['warnings'])
                self.assertIn('Текст и таблицы рамки сохранены', warning)

    def test_docx_reports_lost_layout_of_picture_only_drawing_groups(self):
        source = self.root / 'grouped-pictures.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
                xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:v="urn:schemas-microsoft-com:vml"><w:body>
                <w:p><w:r><w:t>Схемы</w:t></w:r></w:p>
                <w:p><w:r><w:drawing><wpg:wgp><pic:pic><pic:blipFill><a:blip r:embed="p"/>
                </pic:blipFill></pic:pic><wpg:grpSp><pic:pic><pic:blipFill><a:blip r:embed="p"/>
                </pic:blipFill></pic:pic></wpg:grpSp></wpg:wgp></w:drawing></w:r></w:p>
                <w:p><w:r><w:pict><v:group><v:shape><v:imagedata r:id="p"/></v:shape></v:group>
                </w:pict></w:r></w:p></w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', '''<Relationships
                xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="p" Target="media/p.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
                </Relationships>''')
            archive.writestr('word/media/p.png', PNG)
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertEqual(len(warnings), 2)
                for index, warning in enumerate(warnings, 1):
                    self.assertIn(f'№ {index} (составной рисунок)', warning)
                    self.assertIn('Встроенные изображения сохранены отдельно', warning)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        root = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    root = c.xml(output.read_bytes())
                    c.validate_fb2_output(root)
                body = c.first(root, 'body')
                self.assertEqual(sum(c.tag(n) in {'img', 'image'} for n in body.iter()), 3)

    def test_docx_vertical_merges_follow_table_columns(self):
        source = self.root / 'word-merged-cells.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body>
              <w:tbl><w:tblGrid><w:gridCol/><w:gridCol/><w:gridCol/><w:gridCol/></w:tblGrid>
                <w:tr><w:trPr><w:gridBefore w:val="1"/></w:trPr>
                  <w:tc><w:tcPr><w:gridSpan w:val="2"/><w:vMerge w:val="restart"/></w:tcPr>
                    <w:p><w:r><w:t>Общая ячейка</w:t></w:r></w:p></w:tc>
                  <w:tc><w:p><w:r><w:t>Справа сверху</w:t></w:r></w:p></w:tc>
                </w:tr>
                <w:tr><w:tc><w:p><w:r><w:t>Слева</w:t></w:r></w:p></w:tc>
                  <w:tc><w:tcPr><w:gridSpan w:val="2"/><w:vMerge/></w:tcPr><w:p/></w:tc>
                  <w:tc><w:p><w:r><w:t>Справа посередине</w:t></w:r></w:p></w:tc>
                </w:tr>
                <w:tr><w:trPr><w:gridBefore w:val="1"/><w:gridAfter w:val="1"/></w:trPr>
                  <w:tc><w:tcPr><w:gridSpan w:val="2"/><w:vMerge w:val="continue"/></w:tcPr><w:p/></w:tc>
                </w:tr>
                <w:tr><w:tc><w:p><w:r><w:t>Новая строка</w:t></w:r></w:p></w:tc></w:tr>
              </w:tbl></w:body></w:document>''')
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                [table] = document.findall('.//{*}table')
                row1, row2, row3, row4 = table.findall('./{*}tr')
                self.assertEqual([(n.get('colspan'), n.get('rowspan'), c.plain(n)) for n in row1],
                                 [(None, None, ''), ('2', '3', 'Общая ячейка'), (None, None, 'Справа сверху')])
                self.assertEqual([c.plain(n) for n in row2], ['Слева', 'Справа посередине'])
                self.assertEqual([c.plain(n) for n in row3], ['', ''])
                self.assertEqual([c.plain(n) for n in row4], ['Новая строка'])
                self.assertFalse(c.damaged_content_warnings(report['warnings']))

    def test_docx_field_hyperlinks_keep_cached_result_and_surrounding_runs(self):
        source = self.root / 'word-fields.docx'
        docx(source)
        with zipfile.ZipFile(source) as archive:
            members = {name: archive.read(name) for name in archive.namelist()}
        extra = rb'''
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Before </w:t>
          <w:fldChar w:fldCharType="begin"/><w:instrText> HYPER</w:instrText></w:r>
          <w:r><w:instrText>LINK "https://example.test/article" \o "Details" </w:instrText>
          <w:fldChar w:fldCharType="separate"/><w:instrText>Linked </w:instrText></w:r>
          <w:r><w:rPr><w:i/></w:rPr><w:t>title</w:t><w:fldChar w:fldCharType="end"/><w:t> after</w:t></w:r></w:p>
        <w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText> TOC </w:instrText>
          <w:fldChar w:fldCharType="separate"/><w:fldChar w:fldCharType="begin"/>
          <w:instrText> HYPERLINK \l "point" </w:instrText><w:fldChar w:fldCharType="separate"/>
          <w:t>Bookmark label</w:t><w:fldChar w:fldCharType="end"/><w:fldChar w:fldCharType="end"/></w:r></w:p>
        <w:p><w:fldSimple w:instr="HYPERLINK &quot;mailto:reader@example.test&quot;">
           <w:r><w:t>Mail label</w:t></w:r></w:fldSimple></w:p>
        <w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText> HYPERLINK "file:///local.txt" </w:instrText>
          <w:fldChar w:fldCharType="separate"/><w:t>Local file label</w:t><w:fldChar w:fldCharType="end"/></w:r></w:p>
        '''
        members['word/document.xml'] = members['word/document.xml'].replace(b'</w:body>', extra + b'</w:body>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in members.items():
                archive.writestr(name, data)
        before = source.read_bytes()
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = self.root / ('word-field-links' + extension)
                c.convert_book(source, output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        content = c.xml(archive.read('OEBPS/book.xhtml'))
                    key = 'href'
                else:
                    content = c.xml(output.read_bytes())
                    c.validate_fb2_output(content)
                    key = '{' + c.XL + '}href'
                links = {''.join(node.itertext()): node for node in content.iter() if c.tag(node) == 'a'}
                self.assertEqual(links['Linked title'].get(key), 'https://example.test/article')
                self.assertTrue(links['Bookmark label'].get(key).startswith('#'))
                self.assertEqual(links['Mail label'].get(key), 'mailto:reader@example.test')
                self.assertNotIn('Local file label', links)
                self.assertIn('Before Linked title after', ''.join(content.itertext()))
                self.assertNotIn('HYPERLINK', ''.join(content.itertext()))
                emphasis = 'em' if extension == '.epub' else 'emphasis'
                self.assertTrue(any(c.tag(node) == emphasis for node in links['Linked title'].iter()))
                if extension == '.epub':
                    self.assertEqual(links['Linked title'].get('title'), 'Details')
        self.assertEqual(source.read_bytes(), before)

    def test_docx_grouped_vml_caption_remains_available_to_reader_after_export(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        source = self.root / 'word-group.docx'
        label = 'Подпись схемы'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:v="urn:schemas-microsoft-com:vml">
              <w:body><w:p><w:r><w:t>Текст книги</w:t></w:r></w:p><w:p><w:r><w:pict>
                <v:group style="width:120pt;height:48pt" coordsize="2400,960">
                  <v:rect type="#_x0000_t1" style="width:2400;height:960">
                    <v:textbox><w:txbxContent><w:p><w:r><w:t>{label}</w:t></w:r></w:p></w:txbxContent></v:textbox>
                  </v:rect>
                </v:group>
              </w:pict></w:r></w:p></w:body></w:document>''')
        epub = self.root / 'word-group.epub'
        c.convert_book(source, epub, tools_root=tools)
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
        image, = chapter.iter('{' + c.XH + '}img')
        self.assertIn('word-diagram', image.get('class', '').split())
        self.assertEqual(image.get('alt'), label)
        self.assertNotIn(label, c.plain(c.first(chapter, 'body')))

        fb2 = self.root / 'word-group.fb2'
        c.convert_book(source, fb2, tools_root=tools)
        diagram, = c.xml(fb2.read_bytes()).iter('{' + c.FB + '}image')
        self.assertTrue(diagram.get('{' + c.XL + '}href').startswith('#word_diagram_'))
        self.assertEqual(diagram.get('alt'), label)

    def test_docx_vml_oval_stays_in_the_source_paragraph(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        source = self.root / 'word-oval.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
              xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w10="urn:schemas-microsoft-com:office:word">
              <w:body><w:p><w:r><w:t>Before </w:t><w:pict>
                <v:oval style="width:9.9pt;height:9.9pt;mso-position-horizontal-relative:char;mso-position-vertical-relative:line"
                  strokecolor="#002774">
                  <v:textbox><w:txbxContent><w:p><w:pPr><w:ind w:left="0"/></w:pPr></w:p></w:txbxContent></v:textbox>
                  <w10:wrap type="none"/><w10:anchorlock/>
                </v:oval>
              </w:pict><w:t> after.</w:t></w:r></w:p></w:body></w:document>''')
        for extension, namespace, tag in (('epub', c.XH, 'img'), ('fb2', c.FB, 'image')):
            with self.subTest(extension=extension):
                target = self.root / ('word-oval.' + extension)
                c.convert_book(source, target, tools_root=tools)
                if extension == 'epub':
                    with zipfile.ZipFile(target) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    document = c.xml(target.read_bytes())
                paragraph, = [node for node in document.iter('{' + namespace + '}p') if 'Before' in (node.text or '')]
                oval, = paragraph.iter('{' + namespace + '}' + tag)
                self.assertEqual((paragraph.text.strip(), oval.tail.strip()), ('Before', 'after.'))

    def test_docx_skips_only_unpainted_floating_connectors(self):
        shape_namespace = 'http://schemas.microsoft.com/office/word/2010/wordprocessingShape'
        connector = '''<mc:AlternateContent><mc:Choice Requires="wps"><w:drawing>
            <wp:anchor behindDoc="1"><wp:simplePos x="0" y="0"/>
            <wp:positionH relativeFrom="page"><wp:posOffset>44450</wp:posOffset></wp:positionH>
            <wp:positionV relativeFrom="page"><wp:posOffset>9047480</wp:posOffset></wp:positionV>
            <wp:extent cx="6258560" cy="0"/><wp:effectExtent l="0" t="0" r="0" b="0"/>
            <wp:wrapNone/><wp:docPr id="1" name="Connector"/><wp:cNvGraphicFramePr/>
            <a:graphic><a:graphicData><wps:wsp><wps:cNvCnPr/><wps:spPr>
            <a:xfrm><a:off x="0" y="0"/><a:ext cx="6258560" cy="0"/></a:xfrm>
            <a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom><a:ln w="20320"/>
            </wps:spPr><wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:anchor>
            </w:drawing></mc:Choice><mc:Fallback><w:pict>
            <v:shape type="#_x0000_t32" stroked="f"><w10:wrap anchorx="page" anchory="page"/></v:shape>
            </w:pict></mc:Fallback></mc:AlternateContent>'''
        painted = connector.replace('<a:ln w="20320"/>',
                                    '<a:ln w="20320"><a:solidFill><a:srgbClr val="004488"/></a:solidFill></a:ln>')
        source = self.root / 'word-invisible-connector.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
                xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wps="{shape_namespace}"
                xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w10="urn:schemas-microsoft-com:office:word">
                <w:body><w:p><w:r><w:t>Начало</w:t>{connector}<w:t>После</w:t></w:r></w:p>
                <w:p><w:r>{painted}<w:t>Конец</w:t></w:r></w:p></w:body></w:document>''')
        for extension in ('.epub', '.fb2'):
            report = c.convert_book(source, source.with_suffix(extension))
            warnings = c.damaged_content_warnings(report['warnings'])
            self.assertEqual(warnings, ['Не перенесён объект DOCX № 1 (рисунок или диаграмма).'])

    def test_docx_standalone_vml_textbox_keeps_outline_location_and_caption(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        label = 'Текст в рамке'
        for name, box_attributes in [('supported', ''), ('unsupported', ' inset="1cm,1cm,1cm,1cm"')]:
            source = self.root / (name + '-box.docx')
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"
                    xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"><w:body>
                  <w:p><w:r><w:t>До рамки</w:t></w:r></w:p><w:p><w:r><w:pict>
                    <v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe"/>
                    <v:shape type="#_x0000_t202" style="position:absolute;margin-left:1pt;width:120pt;height:40pt;">
                      <v:textbox{box_attributes}><w:txbxContent><w:p><w:r><w:t>{label}</w:t></w:r></w:p></w:txbxContent></v:textbox>
                    </v:shape>
                  </w:pict></w:r></w:p><w:p><w:r><w:t>После рамки</w:t></w:r></w:p>
                  </w:body></w:document>''')
            epub = self.root / (name + '-box.epub')
            report = c.convert_book(source, epub, tools_root=tools)
            with zipfile.ZipFile(epub) as archive:
                body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
                images = list(body.iter('{' + c.XH + '}img'))
                if name == 'supported':
                    image, = images
                    self.assertEqual(image.get('class'), 'word-textbox-left')
                    self.assertEqual(image.get('alt'), label)
                    self.assertEqual(c.plain(body), 'До рамкиПосле рамки')
                    self.assertTrue(any('Положение на печатной странице может отличаться' in warning for warning in report['warnings']))
                else:
                    self.assertFalse(images)
                    self.assertIn(label, c.plain(body))
                    self.assertTrue(any('Не перенесён объект' in warning for warning in report['warnings']))

    def test_docx_group_keeps_vml_photo_and_caption_line_breaks(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        try:
            from PIL import Image, ImageChops
        except ImportError:
            self.skipTest('Pillow is required to compare picture and caption placement')
        source = self.root / 'caption-with-photo.docx'
        from io import BytesIO
        photo = BytesIO()
        Image.new('RGB', (10, 6), 'red').save(photo, 'PNG')
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w10="urn:schemas-microsoft-com:office:word">
                <w:body><w:p><w:r><w:pict><v:group style="position:absolute;width:120pt;height:64pt"
                  coordorigin="100" coordsize="2400,1280">
                  <v:shape type="#_x0000_t75" style="position:absolute;left:100;width:2400;height:600">
                    <v:imagedata r:id="photo" grayscale="t"/>
                  </v:shape>
                  <v:shape type="#_x0000_t202" style="position:absolute;left:100;top:660;width:2400;height:620"
                    filled="f" strokeweight="0">
                    <v:textbox inset="0,0,0,0"><w:txbxContent><w:p><w:r><w:t>Первая строка</w:t>
                      <w:br/><w:t>Вторая строка</w:t></w:r></w:p></w:txbxContent></v:textbox>
                  </v:shape><w10:wrap type="topAndBottom" anchorx="margin"/>
                </v:group></w:pict></w:r></w:p></w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', '''<Relationships
                xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="photo" Target="media/photo.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
                </Relationships>''')
            archive.writestr('word/media/photo.png', photo.getvalue())
        epub = source.with_suffix('.epub')
        report = c.convert_book(source, epub, tools_root=tools)
        self.assertTrue(any('Обтекание текстом' in warning for warning in c.damaged_content_warnings(report['warnings'])))
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
            [image] = chapter.iter('{' + c.XH + '}img')
            raster = archive.read('OEBPS/' + image.get('src'))
        self.assertEqual(image.get('alt'), 'Первая строка\nВторая строка')
        with Image.open(BytesIO(raster)) as diagram:
            rgb = diagram.convert('RGB')
            sampled = rgb.getpixel((diagram.width // 2, diagram.height // 5))
            self.assertEqual(sampled[0], sampled[1])
            self.assertEqual(sampled[1], sampled[2])
            self.assertAlmostEqual(sampled[0], 76, delta=2)
            caption_band = rgb.crop((0, diagram.height // 2, diagram.width, diagram.height))
            ink = ImageChops.difference(caption_band, Image.new('RGB', caption_band.size, 'white'))
            row_has_text = [ink.crop((0, y, ink.width, y + 1)).getbbox() is not None for y in range(ink.height)]
            self.assertEqual(sum(not previous and current for previous,current in zip([False] + row_has_text, row_has_text)), 2)
        fb2 = source.with_suffix('.fb2')
        c.convert_book(source, fb2, tools_root=tools)
        book = c.xml(fb2.read_bytes())
        c.validate_fb2_output(book)
        [image] = book.iter('{' + c.FB + '}image')
        [binary] = c.children(book, 'binary')
        self.assertEqual(image.get('alt'), 'Первая строка\nВторая строка')
        self.assertEqual(base64.b64decode(binary.text), raster)

    def test_docx_picture_only_vml_textbox_keeps_the_embedded_picture(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('Pillow is required to compare the picture pixels')
        from io import BytesIO
        source = self.root / 'photo-only-textbox.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:v="urn:schemas-microsoft-com:vml"><w:body><w:p><w:r><w:t>До рамки</w:t></w:r>
                <w:r><w:pict><v:shape type="#_x0000_t202" style="position:absolute;width:66pt;height:42pt"
                  filled="f" stroked="f"><v:textbox inset="0,0,0,0"><w:txbxContent><w:p><w:r><w:pict>
                  <v:shape type="#_x0000_t75" style="width:66pt;height:42pt"><v:imagedata r:id="photo"/>
                  </v:shape></w:pict></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></w:r>
                <w:r><w:t>После рамки</w:t></w:r></w:p></w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', '''<Relationships
                xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="photo" Target="media/photo.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
                </Relationships>''')
            archive.writestr('word/media/photo.png', PNG)
        output = source.with_suffix('.epub')
        c.convert_book(source, output, tools_root=tools)
        with zipfile.ZipFile(output) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
            [image] = chapter.iter('{' + c.XH + '}img')
            self.assertEqual(image.get('class'), 'word-textbox')
            with Image.open(BytesIO(archive.read('OEBPS/' + image.get('src')))) as raster:
                self.assertEqual(raster.convert('RGB').getpixel((raster.width // 2, raster.height // 2)), (18, 52, 86))

    def test_docx_textbox_keeps_inline_picture_label_and_link(self):
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3] / 'Program/Out/Bin64/tools'))
        if os.name != 'nt' or not (tools / 'doc' / 'HomeLibDoc.exe').is_file():
            self.skipTest('Windows Word drawing renderer required')
        source = self.root / 'word-textbox.docx'
        address = 'https://example.org/reference'
        label = 'Подпись со ссылкой'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
              <w:p><w:r><w:t>До рамки</w:t></w:r><w:r><w:drawing><wp:anchor>
                <wp:positionH relativeFrom="leftMargin"><wp:align>left</wp:align></wp:positionH>
                <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
                  <wps:wsp><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2540000" cy="254000"/></a:xfrm>
                    <a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="F2F2F2"/></a:solidFill></wps:spPr>
                  <wps:txbx><w:txbxContent><w:p><w:pPr><w:contextualSpacing/></w:pPr>
                  <w:r><w:rPr><w:noProof/><w:position w:val="-4"/></w:rPr><w:drawing><wp:inline>
                    <wp:extent cx="127000" cy="127000"/><a:graphic>
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                      <pic:pic><pic:blipFill><a:blip r:embed="logo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="127000" cy="127000"/></a:xfrm>
                          <a:prstGeom prst="rect"/></pic:spPr></pic:pic></a:graphicData></a:graphic>
                  </wp:inline></w:drawing></w:r><w:hyperlink r:id="ref"><w:r><w:rPr><w:color w:val="0F2B46"/>
                    <w:sz w:val="18"/><w:u w:val="single"/></w:rPr><w:t>{label}</w:t></w:r></w:hyperlink>
                  </w:p></w:txbxContent></wps:txbx><wps:bodyPr tIns="0" bIns="0"/></wps:wsp>
                </a:graphicData></a:graphic></wp:anchor></w:drawing></w:r><w:r><w:t>После рамки</w:t></w:r></w:p>
              </w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', f'''<Relationships
                xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="logo" Target="media/logo.png" Type="{R}/image"/>
                <Relationship Id="ref" Target="{address}" TargetMode="External" Type="{R}/hyperlink"/>
                </Relationships>''')
            archive.writestr('word/media/logo.png', PNG)
        for suffix, image_tag, link_tag in (('.epub', 'img', 'href'), ('.fb2', 'image', f'{{{c.XL}}}href')):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output, tools_root=tools)
                [warning] = c.damaged_content_warnings(report['warnings'])
                self.assertIn('Положение на печатной странице может отличаться', warning)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        root = c.xml(archive.read('OEBPS/book.xhtml'))
                        [data] = [archive.read(name) for name in archive.namelist() if '/images/' in name]
                else:
                    root = c.xml(output.read_bytes())
                    c.validate_fb2_output(root)
                    [binary] = c.children(root, 'binary')
                    data = base64.b64decode(binary.text)
                    self.assertTrue(binary.get('id').startswith('word_textbox_left_'))
                body = c.first(root, 'body')
                [picture] = [node for node in body.iter() if c.tag(node) == image_tag]
                self.assertEqual(picture.get('alt'), label)
                self.assertEqual([c.plain(node) for node in body.iter() if node.get(link_tag) == address], [label])
                self.assertGreater(c.raster_header_size(data)[0], 200)

    def test_docx_covered_rows_and_invalid_merges_keep_content(self):
        source = self.root / 'word-full-row-merge.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}"><w:body>
              <w:tbl><w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr>
                <w:p><w:r><w:t>Данные начала</w:t></w:r></w:p></w:tc></w:tr>
              <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc></w:tr>
              <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr>
                <w:p><w:r><w:t>Данные продолжения</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
              <w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/><w:vMerge w:val="restart"/></w:tcPr>
                <w:p><w:r><w:t>Две колонки</w:t></w:r></w:p></w:tc></w:tr>
              <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc>
                <w:tc><w:p><w:r><w:t>Соседняя ячейка</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
              </w:body></w:document>''')
        original = source.read_bytes()
        for suffix, input_file in (('.epub', source), ('.fb2', source), ('.fb2', source.with_suffix('.epub'))):
            with self.subTest(suffix=suffix, input=input_file.suffix):
                output = source.with_suffix(suffix) if input_file == source else self.root / 'round-trip.fb2'
                report = c.convert_book(input_file, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                table, malformed = document.findall('.//{*}table')
                rows = table.findall('./{*}tr')
                self.assertEqual(len(rows), 3 if suffix == '.epub' else 2)
                self.assertEqual(rows[0][0].get('rowspan'), '2' if suffix == '.epub' else None)
                self.assertEqual([c.plain(n) for row in rows for n in row],
                                 ['Данные начала', 'Данные продолжения'])
                invalid_rows = malformed.findall('./{*}tr')
                self.assertIsNone(invalid_rows[0][0].get('rowspan'))
                self.assertEqual([c.plain(n) for n in invalid_rows[1]], ['', 'Соседняя ячейка'])
                warnings = c.damaged_content_warnings(report['warnings'])
                if input_file == source:
                    self.assertEqual(sum(w.startswith('Вертикальное объединение ячеек DOCX') for w in warnings), 2)
                self.assertEqual(any(w.startswith('Строки таблицы, полностью занятые объединёнными ячейками') for w in warnings),
                                 suffix == '.fb2')
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt', 'Windows image decoder is required')
    def test_docx_picture_crop_is_per_placement_and_keeps_the_original(self):
        source = self.root / 'cropped-picture.docx'
        png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 6, 0, 0, 0)) +
               chunk(b'IDAT', zlib.compress(b''.join(b'\0' + bytes([y * 30, 90, 35, 255]) * 8
                                                     for y in range(8)))) + chunk(b'IEND', b''))
        drawings = ''.join(
            f'<w:p><w:r><w:drawing><pic:pic><pic:blipFill><a:blip r:embed="picture"/>{rect}'
            f'</pic:blipFill></pic:pic></w:drawing></w:r></w:p>' for rect in (
                '<a:srcRect l="25000" t="-25%" r="25%" b="25000"/>',
                '<a:srcRect/>',
                '<a:srcRect l="90000" r="20000"/>'))
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document xmlns:w="{W}" xmlns:r="{R}"
              xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
              xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>
              <w:p><w:r><w:t>Иллюстрации</w:t></w:r></w:p>{drawings}</w:body></w:document>''')
            archive.writestr('word/_rels/document.xml.rels', '''<Relationships
                xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="picture" Target="media/p.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
                </Relationships>''')
            archive.writestr('word/media/p.png', png)
        original = source.read_bytes()
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        body = c.xml(archive.read('OEBPS/book.xhtml'))
                        images = [archive.read('OEBPS/' + node.get('src')) for node in body.iter() if c.tag(node) == 'img']
                else:
                    body = c.xml(output.read_bytes())
                    c.validate_fb2_output(body)
                    bins = {node.get('id'):base64.b64decode(node.text) for node in body.iter() if c.tag(node) == 'binary'}
                    images = [bins[node.get('{' + c.XL + '}href')[1:]] for node in c.first(body,'body').iter()
                              if c.tag(node) == 'image']
                self.assertEqual([struct.unpack_from('>II', data, 16) for data in images], [(4, 8), (8, 8), (8, 8)])
                self.assertEqual(images[1:], [png, png])
                self.assertEqual(len(c.damaged_content_warnings(report['warnings'])), 1)
                self.assertIn('Обрезка изображения DOCX не перенесена', c.damaged_content_warnings(report['warnings'])[0])
        self.assertEqual(source.read_bytes(), original)

    def test_docx_unpainted_empty_textbox_does_not_block_the_book(self):
        source = self.root/'empty-box.docx'; docx(source)
        with zipfile.ZipFile(source) as z: entries={n:z.read(n) for n in z.namelist()}
        box = ('<w:p><w:r><w:pict xmlns:v="urn:schemas-microsoft-com:vml">'
               '<v:shapetype id="empty-type"/><v:shape filled="f" stroked="f" type="#empty-type">'
               '<v:textbox><w:txbxContent><w:p><w:pPr><w:spacing w:line="202"/></w:pPr>'
               '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">   </w:t></w:r>'
               '<w:r><w:t xml:space="preserve"/></w:r></w:p></w:txbxContent></v:textbox>'
               '</v:shape></w:pict></w:r></w:p>').encode()
        entries['word/document.xml']=entries['word/document.xml'].replace(b'</w:body>',box+b'</w:body>')
        with zipfile.ZipFile(source,'w') as z:
            for name,data in entries.items():z.writestr(name,data)
        self.outputs(source,[TEXT,'Точная сноска','Ячейка'],True,True,True)
        for index, changed in enumerate([
            box.replace(b'</w:rPr>',b'</w:rPr><w:t>Keep this text</w:t>'),
            box.replace(b'filled="f"',b'filled="t"'),
            box.replace(b'</w:rPr>',b'</w:rPr><w:sym w:char="F041"/>'),
            box.replace(b'<v:textbox>',b'<v:textbox style="background:red">'),
            box.replace(b'</v:textbox>',b'</v:textbox><v:imagedata/>'),
            box.replace(b'</w:pPr>',b'<w:shd w:fill="808080"/></w:pPr>')]):
            damaged=self.root/('visible-box-'+str(index)+'.docx')
            with zipfile.ZipFile(damaged,'w') as z:
                for name,data in entries.items():z.writestr(name,data.replace(box,changed) if name=='word/document.xml' else data)
            before=damaged.read_bytes()
            for suffix in ['.epub','.fb2']:
                out=self.root/(damaged.stem+suffix)
                report = c.convert_book(damaged, out)
                self.assertTrue(any(note.startswith('Не перенесён объект DOCX № 1')
                                    for note in c.damaged_content_warnings(report['warnings'])))
                if suffix == '.epub':
                    with zipfile.ZipFile(out) as archive: content = c.xml(archive.read('OEBPS/book.xhtml'))
                else: content = c.xml(out.read_bytes())
                if index == 0: self.assertIn('Keep this text', c.plain(content))
            self.assertEqual(damaged.read_bytes(),before)

    def test_docx_empty_inline_picture_frames_keep_dimensions_and_paragraph_style(self):
        source = self.root / 'picture-spacers.docx'
        namespaces = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
                      'xmlns:v="urn:schemas-microsoft-com:vml" xmlns:office="urn:schemas-microsoft-com:office:office"')
        frame = '<v:shape type="#picture" style="width:24.2pt;height:24.2pt"/>'
        template = '<v:shapetype id="picture" office:spt="75" filled="f" stroked="f"><v:path/></v:shapetype>'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml', f'''<w:document {namespaces}><w:body>
              <w:p><w:pPr><w:jc w:val="center"/><w:shd w:val="clear" w:fill="ABC5E2"/></w:pPr>
                <w:r><w:pict>{template}{frame}</w:pict></w:r></w:p>
              <w:p><w:r><w:t>Before</w:t><w:pict>{frame}</w:pict><w:t>After</w:t></w:r></w:p>
              <w:p><w:r><w:pict>{frame.replace('/>', ' filled="t"/>')}</w:pict></w:r></w:p>
            </w:body></w:document>''')
        marker = 'homelibre-word-space-484-484'
        paragraph = 'homelibre-word-space-paragraph-center-abc5e2'
        epub = self.root / 'spacers.epub'
        fb2 = self.root / 'spacers.fb2'
        result = c.convert_book(source, epub)
        self.assertEqual(sum('Не перенесён объект DOCX' in note for note in c.damaged_content_warnings(result['warnings'])), 1)
        result = c.convert_book(epub, fb2)
        self.assertTrue(any('Размеры пустых рамок FB2' in note for note in c.damaged_content_warnings(result['warnings'])))
        root = c.xml(fb2.read_bytes())
        c.validate_fb2_output(root)
        self.assertEqual(sum(n.get('name') == marker for n in root.iter()), 2)
        self.assertEqual(sum(n.get('style') == paragraph for n in root.iter()), 1)
        stylesheet = next(n for n in root if c.tag(n) == 'stylesheet').text
        self.assertIn('width:24.2pt;height:24.2pt', stylesheet)
        self.assertIn('text-align:center;background-color:#abc5e2', stylesheet)
        if schema := os.environ.get('HOMELIB_TEST_FB2_SCHEMA'):
            from lxml import etree
            etree.XMLSchema(etree.parse(schema)).assertValid(etree.parse(str(fb2)))
        roundtrip = self.root / 'spacers-roundtrip.epub'
        c.convert_book(fb2, roundtrip)
        for book in (epub, roundtrip):
            with self.subTest(book=book.name), zipfile.ZipFile(book) as archive:
                self.assertIsNone(archive.testzip())
                self.assertFalse(any('/images/' in name for name in archive.namelist()))
                documents = [c.xml(archive.read(name)) for name in archive.namelist()
                             if name.endswith('.xhtml') and not name.endswith('/nav.xhtml')]
                elements = [n for content in documents for n in content.iter()]
                spans = [n for n in elements if marker in n.get('class', '').split()]
                self.assertEqual(len(spans), 2)
                self.assertTrue(all('width:24.2pt;height:24.2pt' in n.get('style', '') for n in spans))
                self.assertTrue(any('text-align:center;background-color:#abc5e2' in n.get('style', '') for n in elements))
                self.assertIn('BeforeAfter', ''.join(''.join(content.itertext()) for content in documents))

    def test_docx_empty_wordart_is_not_missing_content(self):
        source = self.root/'wordart.docx'
        docx(source)
        with zipfile.ZipFile(source) as archive:
            members = {name: archive.read(name) for name in archive.namelist()}
        pict = b'''
        <w:p><w:r><w:pict xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
          <v:shapetype id="art" o:spt="136" path="m@7,l@8,m@5,21600l@6,21600e">
            <v:path textpathok="t"/><v:textpath on="t" fitpath="t"/>
          </v:shapetype>
          <v:shape id="shape1" type="#art" style="position:absolute;width:40pt;height:20pt;">
            <v:shadow color="#868686" on="t"/>
            <v:textpath fitshape="t" style="font-family:Arial;v-text-kern:t;" string="ART_TEXT"/>
          </v:shape>
        </w:pict></w:r></w:p>'''
        blank = pict.replace(b'ART_TEXT', b' ')
        variants = [
            (blank, False),
            (pict.replace(b'ART_TEXT', b'&#13;'), True),
            (pict.replace(b'ART_TEXT', b'Visible WordArt'), True),
            (blank.replace(b'<v:shadow', b'<v:line/><v:shadow'), True),
            (blank.replace(b'position:absolute', b'position:relative'), True),
            (blank.replace(b'v-text-kern:t;', b'text-decoration:underline;'), True),
        ]
        for number, (drawing, warns) in enumerate(variants):
            with self.subTest(number=number):
                with zipfile.ZipFile(source, 'w') as archive:
                    for name, data in members.items():
                        if name == 'word/document.xml':
                            data = data.replace(b'</w:body>', drawing + b'</w:body>')
                        archive.writestr(name, data)
                before = source.read_bytes()
                for target in ('.epub', '.fb2'):
                    output = self.root/f'wordart-{number}{target}'
                    report = c.convert_book(source, output)
                    warnings = c.damaged_content_warnings(report['warnings'])
                    self.assertEqual(any('объект DOCX № 1' in warning for warning in warnings), warns)
                    if not warns:
                        self.assertFalse(warnings)
                self.assertEqual(source.read_bytes(), before)

    def test_odt(self):
        source = self.root/'book.odt'; odt(source); self.outputs(source, [TEXT, 'Точная сноска'], True, True, True)
    def test_fb3(self):
        source = self.root/'book.fb3'; fb3(source); self.outputs(source, [TEXT, 'Точная сноска', 'Подглавный текст.'], True, True, True)
        original = source.read_bytes()
        with zipfile.ZipFile(self.root/'book.fb3.epub') as archive:
            metadata = c.first(c.xml(archive.read('OEBPS/package.opf')), 'metadata')
            for tag, value in (('title', 'FB3 книга'), ('creator', 'Анна Морозова'), ('contributor', 'Человек'),
                               ('publisher', 'Издательство Ёжик'), ('date', '2025')):
                self.assertEqual(c.plain(c.first(metadata, tag)), value)
            self.assertTrue(any(n.get('property') == 'role' and c.plain(n) == 'trl' for n in metadata))
            self.assertIn('urn:isbn:5-699-01480-2', [c.plain(n) for n in c.children(metadata, 'identifier')])
            self.assertEqual(c.plain(c.first(metadata, 'identifier')), 'urn:uuid:00000000-0000-0000-0000-000000000001')
            self.assertIn('Мысль — описание книги.\n\n', c.plain(c.first(metadata, 'description')))

        epub2, exported = self.root/'book-v2.epub', self.root/'roundtrip.fb2'
        c.convert_book(source, epub2, output_profile='epub2')
        c.convert_book(epub2, exported)
        for path in (self.root/'book.fb3.fb2', exported):
            root = c.xml(path.read_bytes())
            c.validate_fb2_output(root)
            description = c.first(root, 'description')
            title = c.first(description, 'title-info')
            author = c.first(title, 'author')
            self.assertEqual(c.plain(c.first(author, 'first-name')), 'Анна')
            self.assertEqual(c.plain(c.first(author, 'last-name')), 'Морозова')
            self.assertEqual(c.plain(c.first(c.first(title, 'translator'), 'nickname')), 'Человек')
            annotation = c.first(title, 'annotation')
            self.assertEqual([c.tag(n) for n in annotation], ['p', 'empty-line', 'p'])
            self.assertEqual(c.plain(c.first(annotation[0], 'strong')), 'Мысль')
            self.assertEqual(c.plain(c.first(annotation[0], 'emphasis')), 'описание')
            internal, external = [n.get('{' + c.XL + '}href') for n in c.children(annotation[2], 'a')]
            self.assertTrue(internal.startswith('#') and any(n.get('id') == internal[1:] for n in root.iter()))
            self.assertEqual(external, 'https://example.invalid/book')
            edition = c.first(description, 'publish-info')
            self.assertEqual({c.tag(n): c.plain(n) for n in edition},
                             {'book-name': 'Бумажное издание', 'publisher': 'Издательство Ёжик', 'city': 'Киев',
                              'year': '2025', 'isbn': '5-699-01480-2'})
            info = c.first(description, 'document-info')
            self.assertEqual(c.plain(c.first(info, 'id')), '00000000-0000-0000-0000-000000000001')
            self.assertEqual(c.plain(c.first(info, 'version')), '2.5')
        self.assertEqual(source.read_bytes(), original)

    def test_fb3_block_and_inline_line_breaks(self):
        source = self.root/'breaks.fb3'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('fb3/body.xml', '<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body"><section><p>First line<br/>Second line</p><br/><p>Next paragraph</p></section></fb3-body>')
        self.outputs(source, ['First line', 'Second line', 'Next paragraph'])
        with zipfile.ZipFile(self.root/'breaks.fb3.epub') as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertEqual(sum(c.tag(node) == 'br' for node in body.iter()), 2)
        book = c.xml((self.root/'breaks.fb3.fb2').read_bytes())
        self.assertTrue(any(c.tag(node) == 'empty-line' for node in book.iter()))

    def test_fb3_declared_parts_and_svg_ignore_filename_conventions(self):
        source = self.root/'declared.zip'
        vector = b'<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="#409080"/></svg>'
        declaration = b'<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"\n "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('[Content_Types].xml', '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Override PartName="/TEXT/%D0%9A%D0%BD%D0%B8%D0%B3%D0%B0" ContentType="application/fb3-body+xml"/>
<Override PartName="/META/INFO.xml" ContentType="application/fb3-description+xml"/>
</Types>''')
            archive.writestr('text/%D0%9A%D0%BD%D0%B8%D0%B3%D0%B0', '''<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
<section><title id="chapter-title"><p id="title-line">Chapter title</p></title>
<p id="duplicate">Diagram before text.</p><p><img src="drawing" alt="Diagram"/></p>
<p id="duplicate">Following text. <a href="#duplicate">First paragraph</a>. <a href="#chapter-title">Heading</a>.
<a href="#title-line">Heading line</a>.</p></section></fb3-body>''')
            archive.writestr('_rels/.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="thumbnail" Target="/Pictures/Geometry.JPEG" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>
</Relationships>''')
            archive.writestr('text/_rels/%D0%9A%D0%BD%D0%B8%D0%B3%D0%B0.rels', '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="drawing" Target="../Pictures/Geometry.JPEG" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>
</Relationships>''')
            archive.writestr('pictures/geometry.jpeg', declaration + vector)
            archive.writestr('meta/info.xml', '''<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description">
<title><main>Declared title</main></title><lang>en</lang></fb3-description>''')
        self.assertEqual(c.detect_input(source), '.fb3')
        before = source.read_bytes()
        epub, fb2 = self.root/'declared.epub', self.root/'declared.fb2'
        report = c.convert_book(source, epub)
        self.assertTrue(any('Повторяющиеся метки FB3' in warning for warning in report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            drawings = [archive.read(n) for n in archive.namelist() if n.endswith('.svg')]
            self.assertEqual(drawings, [vector])
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            image, = (n for n in body.iter() if c.tag(n) == 'img')
            self.assertEqual(image.get('alt'), 'Diagram')
            anchors = {n.get('id'): c.plain(n) for n in body.iter() if n.get('id')}
            self.assertEqual(anchors['duplicate'], 'Diagram before text.')
            self.assertIn('Following text.', anchors['duplicate-homelibre-2'])
            self.assertEqual(anchors['chapter-title'], 'Chapter title')
            self.assertIn('title-line', anchors)
            cover, = (n for n in c.xml(archive.read('OEBPS/package.opf')).iter()
                      if n.get('properties') == 'cover-image')
            self.assertTrue(cover.get('href').endswith('.svg'))
        c.convert_book(source, fb2)
        document = c.xml(fb2.read_bytes())
        c.validate_fb2_output(document)
        fb2_anchors = {n.get('id') for n in document.iter() if n.get('id')}
        links = {c.plain(n): n.get('{' + c.XL + '}href') for n in document.iter() if c.tag(n) == 'a'}
        for label in ('Heading', 'Heading line'):
            self.assertTrue(links[label].startswith('#') and links[label][1:] in fb2_anchors)
        picture, = c.children(document, 'binary')
        self.assertEqual(picture.get('content-type'), 'image/svg+xml')
        self.assertEqual(base64.b64decode(picture.text), vector)
        self.assertEqual(source.read_bytes(), before)

    def test_fb3_missing_declared_description_keeps_prose_and_reports_loss(self):
        source = self.root/'missing-description.fb3'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('[Content_Types].xml', '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Override PartName="/fb3/body.xml" ContentType="application/fb3-body+xml"/>
<Override PartName="/fb3/description.xml" ContentType="application/fb3-description+xml"/>
</Types>''')
            archive.writestr('fb3/body.xml', '''<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
<section><p>Available prose.</p></section></fb3-body>''')
        output = self.root/'missing-description.epub'
        report = c.convert_book(source, output, title='Catalogue title')
        with zipfile.ZipFile(output) as archive:
            self.assertIn(b'Available prose.', archive.read('OEBPS/book.xhtml'))
            self.assertIn(b'Catalogue title', archive.read('OEBPS/package.opf'))
        self.assertTrue(any(warning.startswith('Описание FB3 недоступно')
                            for warning in c.damaged_content_warnings(report['warnings'])))
    def test_rtf_paragraph_alignment_and_page_frame_warning(self):
        source = self.root / 'aligned.rtf'
        source.write_bytes(
            br'{\rtf1\ansi \pard\qc {\b Center}\par \qr {\i Right}\par Inherited\par '
            br'\pard\qj Justified\par \pard\ql Left\par \pard Plain\par '
            br'\pard\qc\phpg\pvpg\posx120\posy240\absw720 Framed\par '
            br'\pard\phpg\pvmrg\posx120\posy240\absw720 Margin\par '
            br'\pard {\*\layout\qr\phpg\pvpg\posx120\posy240\absw720 Hidden}After}')
        expected = dict(Center='center', Right='right', Inherited='right', Justified='justify',
                        Left='left', Plain=None, Framed='center', Margin=None, After=None)
        warning = ('Рамки RTF с привязкой к странице перенесены в основной текст. '
                   'Положение на странице изменится. Затронуто абзацев — 1.')
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                self.assertIn(warning, c.damaged_content_warnings(report['warnings']))
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        doc = c.xml(archive.read('OEBPS/book.xhtml'))
                    self.assertEqual({''.join(p.itertext()): p.get('style') for p in doc.findall('.//{*}p')},
                                     {label: 'text-align:'+value if value else None
                                      for label, value in expected.items()})
                else:
                    doc = c.xml(output.read_bytes())
                    c.validate_fb2_output(doc)
                    self.assertEqual({''.join(p.itertext()): p.get('style')
                                      for p in c.first(doc, 'body').findall('.//{*}p')},
                                     {label: f'{c.WORD_SPACER_PARAGRAPH}{value}-none' if value else None
                                      for label, value in expected.items()})
                    stylesheet = c.plain(c.first(doc, 'stylesheet'))
                    for value in ('left', 'right', 'center', 'justify'):
                        self.assertIn(f'p[style="{c.WORD_SPACER_PARAGRAPH}{value}-none"]{{text-align:{value}}}', stylesheet)

    def test_rtf_formatted_supplementary_unicode(self):
        source = self.root/'жирный emoji.rtf'
        source.write_bytes(br'{\rtf1\ansi\uc1 before {\b\i\u-10179?\u-8704?}\line after}')
        self.outputs(source, ['before ', '😀', 'after'], rich=True)
        with zipfile.ZipFile(self.root/(source.name+'.epub')) as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertEqual(c.plain(c.first(body, 'body')), 'before 😀after')
            self.assertTrue(any(c.tag(n) == 'strong' and c.plain(n) == '😀' for n in body.iter()))
        output = c.xml((self.root/(source.name+'.fb2')).read_bytes())
        self.assertEqual(c.plain(c.first(output, 'body')), 'before 😀after')
        self.assertTrue(any(c.tag(n) == 'emphasis' and c.plain(n) == '😀' for n in output.iter()))
    def test_rtf_unicode_fallback_controls_and_group_boundaries(self):
        fallbacks = [br'\emdash ', br'\tab ', br'\bin3 xyz', br'\~', br'{', br'\uc2\u1040\emdash\~']
        # Each case represents exactly АB; fallback commands and binary data
        # are alternate ANSI text, while a new group terminates skipping.
        for index, fallback in enumerate(fallbacks):
            with self.subTest(fallback=fallback):
                source = self.root/('fallback-'+str(index)+'.rtf')
                if fallback == br'{': content = br'\u1040{B}'
                elif fallback.startswith(br'\uc2'): content = fallback+b'B'
                else: content = br'\u1040'+fallback+b'B'
                source.write_bytes(br'{\rtf1\ansi\uc1 '+content+b'}')
                self.outputs(source, ['АB'])
                with zipfile.ZipFile(self.root/(source.name+'.epub')) as archive:
                    body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
                    self.assertEqual(c.plain(body), 'АB')
                book = c.xml((self.root/(source.name+'.fb2')).read_bytes())
                self.assertEqual(c.plain(c.first(book, 'body')), 'АB')
    def test_markdown(self):
        source = self.root/'book.md'; (self.root/'image.png').write_bytes(PNG)
        source.write_text('# Глава один\n\n'+TEXT+' **Жирный *курсив***[^1]\n\n![Иллюстрация](image.png)\n\n## Подглава\n\n> Цитата\n\n1. Первый\n2. Второй\n\n```python\nprint("Точный код")\n```\n\n# Глава два\n\n[^1]: Точная сноска\n',encoding='utf-8')
        self.outputs(source, [TEXT, 'Жирный курсив', 'Точная сноска', 'Точный код'], True, True, True)

    def test_markdown_static_anchors_roundtrip_through_active_content_filter(self):
        source=self.root/'anchors.md'
        source.write_text('[Next](#destination)\n\n<a id="destination"></a>\n\n'
                          '## Destination\n\n<img src="data:image/png;base64,'+base64.b64encode(PNG).decode()+'" onerror="bad()">\n\n'
                          '<script>bad script text</script>\n\n'
                          '<p onclick="bad()">Visible text <a href="javascript:bad()">Safe words</a></p>\n\n'
                          '\\<literal\\> and `<a id="code-only"></a>`\n',encoding='utf-8')
        before=source.read_bytes();output=self.root/'static.epub';c.convert_book(source,output)
        with zipfile.ZipFile(output) as z:
            body=c.first(c.xml(z.read('OEBPS/book.xhtml')),'body')
            self.assertTrue(any(n.get('id')=='destination' for n in body.iter()))
            self.assertTrue(any(n.get('href')=='#destination' for n in body.iter()))
            self.assertFalse(any(n.get('id')=='code-only' for n in body.iter()))
            self.assertFalse(any(c.tag(n)=='script' or any(k.startswith('on') for k in n.attrib) or n.get('href','').startswith('javascript:') for n in body.iter()))
            self.assertIn('Safe words',''.join(body.itertext()));self.assertIn('<literal>',''.join(body.itertext()))
            self.assertNotIn('bad script text',''.join(body.itertext()))
            self.assertTrue(any(c.tag(n)=='img' for n in body.iter()))
        self.assertEqual(source.read_bytes(),before)
    def test_rtf_unicode_groups_escapes_and_picture(self):
        source = self.root/'book.rtf'
        def rtf_unicode(text): return ''.join('\\u' + str(int.from_bytes(text.encode('utf-16-le')[i:i+2], 'little', signed=True)) + '?' for i in range(0, len(text.encode('utf-16-le')), 2))
        source.write_bytes(('{\\rtf1\\ansi\\ansicpg1251\\uc1 {\\fonttbl{\\f0 Times;}}\\outlinelevel0 Глава один\\par '+rtf_unicode(TEXT)+' {\\b\\i Жирный курсив} \\{скобки\\}\\par {\\pict\\pngblip '+PNG.hex()+'}\\par Конец}').encode('cp1251'))
        self.outputs(source, [TEXT, 'Жирный курсив', '{скобки}', 'Конец'], True, True)

    def test_long_unicode_rtf_counts_text_runs_instead_of_characters(self):
        source = self.root / 'long-unicode.rtf'
        count = 500001
        source.write_bytes(br'{\rtf1\ansi\uc1 ' + br'\u1046?' * count + b'}')
        output = source.with_suffix('.epub')
        report = c.convert_book(source, output)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        with zipfile.ZipFile(output) as archive:
            chapter = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            [paragraph] = chapter.findall('./{*}p')
            self.assertEqual(paragraph.text, 'Ж' * count)

    def test_word_rtf_preserves_primary_picture_and_ignores_its_fallback(self):
        source = self.root / 'word-picture.rtf'
        hex_picture = PNG.hex().encode('ascii')
        source.write_bytes(
            br'{\rtf1\ansi\ansicpg1251{\stylesheet{\s1\ansicpg949 ' + b"\\'e5\\'ea;}}"
            br'Before{\*\shppict{\pict{\*\picprop 1234}\pngblip ' +
            hex_picture[:17] + b'\r\n' + hex_picture[17:] +
            br'}}{\nonshppict{\pict\wmetafile8 unreadable}}After}')
        self.outputs(source, ['Before', 'After'], image=True)
        with zipfile.ZipFile(self.root / 'word-picture.rtf.epub') as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertEqual(sum(c.tag(node) == 'img' for node in body.iter()), 1)

    def test_rtf_preserves_standalone_starred_picture(self):
        source = self.root / 'starred-picture.rtf'
        source.write_bytes(br'{\rtf1 Before{\*\pict\pngblip ' + PNG.hex().encode('ascii') + b'}After}')
        self.outputs(source, ['Before', 'After'], image=True)
        with zipfile.ZipFile(self.root / 'starred-picture.rtf.epub') as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            self.assertEqual([c.tag(node) for node in body.iter() if c.tag(node) == 'img'], ['img'])

    def test_rtf_preserves_independent_picture_sizes(self):
        source = self.root / 'picture-sizes.rtf'
        picture = PNG.hex().encode('ascii')
        controls = (
            br'\picwgoal900\pichgoal600\picscalex150\picscaley50',
            br'\pichgoal1200\picscalex300\picscaley50',
            br'\picwgoal360',
            b'',
        )
        original = br'{\rtf1 ' + b''.join(
            br'{\pict\pngblip' + dimensions + b' ' + picture + br'}\par '
            for dimensions in controls
        ) + b'}'
        source.write_bytes(original)
        expected = [(90, 20), (3, 40), (24, 1)]

        epub = source.with_suffix('.epub')
        epub_report = c.convert_book(source, epub)
        self.assertFalse(c.damaged_content_warnings(epub_report['warnings']))
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
            images = chapter.findall('.//{*}img')
            self.assertEqual([(image.get('width'), image.get('height')) for image in images],
                             [(str(width), str(height)) for width, height in expected] + [(None, None)])
            self.assertEqual([image.get('style') for image in images],
                             [f'aspect-ratio:{width}/{height}' for width, height in expected] + [None])
            for image in images:
                self.assertEqual(archive.read('OEBPS/' + image.get('src')), PNG)

        fb2 = source.with_suffix('.fb2')
        fb2_report = c.convert_book(source, fb2)
        book = c.xml(fb2.read_bytes())
        styles = [c.fb2_image_size(node.get('name', '')) for node in book.findall('.//{*}style')]
        self.assertEqual([size for size in styles if any(size)], expected)
        self.assertEqual(len(book.findall('.//{*}image')), 4)
        [binary] = book.findall('./{*}binary')
        self.assertEqual(base64.b64decode(binary.text), PNG)
        [warning] = c.damaged_content_warnings(fb2_report['warnings'])
        self.assertIn('выберите EPUB.', warning)
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt', 'Windows image decoder is required')
    def test_rtf_picture_crop_changes_only_the_selected_placement(self):
        source = self.root/'cropped-picture.rtf'
        png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 6, 0, 0, 0)) +
               chunk(b'IDAT', zlib.compress(b''.join(b'\0' + bytes([y * 30, 90, 35, 255]) * 8
                                                     for y in range(8)))) + chunk(b'IEND', b''))
        crop = br'\picwgoal1200\pichgoal1200\piccropl300\piccropr300\piccropt-300\piccropb300\picscalex200\picscaley50'
        invalid = br'\picwgoal1200\pichgoal1200\piccropl1100\piccropr500'
        original = br'{\rtf1 ' + b''.join(
            br'{\pict\pngblip' + placement + b' ' + png.hex().encode('ascii') + br'}\par '
            for placement in (crop, b'', invalid, br'\piccropl60')
        ) + b'}'
        source.write_bytes(original)

        spec = importlib.util.spec_from_file_location('text_inputs', Path(c.__file__).with_name('text_inputs.py'))
        text_inputs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(text_inputs)
        book = text_inputs.Book(c, source, set())
        book.work_root = self.root
        text_inputs.read_rtf(book, source.read_bytes())
        images = book.body.findall('.//{*}img')
        self.assertEqual([(image.get('width'), image.get('height')) for image in images],
                         [('80', '40'), (None, None), ('80', '80'), ('4', '8')])
        resources = [book.resources[image.get('src')][0] for image in images]
        self.assertEqual([c.raster_header_size(data) for data in resources], [(4, 8), (8, 8), (8, 8), (4, 8)])
        self.assertEqual(resources[1:3], [png, png])
        self.assertEqual(c.damaged_content_warnings(book.warnings),
                         ['Обрезка иллюстраций RTF не перенесена. Изображения сохранены целиком.'])
        self.assertEqual(source.read_bytes(), original)

    def test_rtf_picture_shapes_and_recovery_of_a_valid_fallback(self):
        source = self.root/'floating.rtf'
        picture = br'{\pict\pngblip\picwgoal900\picscalex150 '+PNG.hex().encode('ascii')+b'}'
        source.write_bytes(
            br'{\rtf1 Before\par '
            br'{\shp{\*\shpinst{\sp{\sn shapeType}{\sv 75}}{\sp{\sn pib}{\sv '+picture+
            br'}}}{\shprslt Old picture placeholder}}\par '
            br'{\shp{\*\shpinst{\sp{\sn description}{\sv MetadataOnly}}{\shptxt Visible box text}}}\par '
            br'{\shp{\*\shpinst{\sp{\sn shapeType}{\sv 1}}}}\par '
            br'{\* \shppict{\pict invalid}} '+b'\r\n'+br'{\nonshppict'+picture+br'}\par '
            br'{\nonshppict'+picture+br'}\par After}')
        before = source.read_bytes()
        for extension, tag in (('.epub', 'img'), ('.fb2', 'image')):
            output = source.with_suffix(extension)
            with self.subTest(extension=extension):
                report = c.convert_book(source,output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        images = [node for node in document.iter() if c.tag(node)==tag]
                        self.assertTrue(all(archive.read('OEBPS/'+node.get('src'))==PNG for node in images))
                        self.assertEqual([node.get('width') for node in images],['90']*3)
                else:
                    document = c.xml(output.read_bytes())
                    images = [node for node in document.iter() if c.tag(node)==tag]
                    [data] = document.findall('./{*}binary')
                    self.assertEqual(base64.b64decode(data.text),PNG)
                self.assertEqual(len(images),3)
                content = ''.join(c.first(document,'body').itertext())
                self.assertLess(content.index('Before'),content.index('Visible box text'))
                self.assertLess(content.index('Visible box text'),content.index('After'))
                self.assertIn('[Фигура RTF № 3 не перенесена.]',content)
                self.assertNotIn('MetadataOnly',content)
                self.assertNotIn('Old picture placeholder',content)
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertEqual(len(warnings), 2 if extension == '.epub' else 3)
                self.assertFalse(any('Изображение ' in warning for warning in warnings))
        self.assertEqual(source.read_bytes(),before)

    def test_rtf_group_keeps_editable_labels_and_one_composite_picture(self):
        source = self.root/'grouped-drawing.rtf'
        picture = br'{\pict\pngblip '+PNG.hex().encode('ascii')+b'}'
        source.write_bytes(
            br'{\rtf1 Before\par {\shpgrp{\*\shpinst'
            br'{\shp{\*\shpinst{\sp{\sn pib}{\sv '+picture+br'}}}}'
            br'{\shp{\*\shpinst{\sp{\sn description}{\sv Hidden metadata}}'
            br'{\shptxt First label\par Second label}}{\shprslt Alternate wording}}}'
            br'{\shprslt'+picture+br'}}\par After}')
        for extension, tag in (('.epub', 'img'), ('.fb2', 'image')):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        [image] = [node for node in document.iter() if c.tag(node) == tag]
                        self.assertEqual(archive.read('OEBPS/'+image.get('src')), PNG)
                else:
                    document = c.xml(output.read_bytes())
                    self.assertEqual(sum(c.tag(node) == tag for node in document.iter()), 1)
                text = ''.join(c.first(document, 'body').itertext())
                self.assertLess(text.index('Before'), text.index('First label'))
                self.assertLess(text.index('First label'), text.index('Second label'))
                self.assertLess(text.index('Second label'), text.index('After'))
                self.assertNotIn('Hidden metadata', text)
                self.assertNotIn('Alternate wording', text)
                self.assertTrue(any('Положение плавающих объектов RTF изменено' in warning
                                    for warning in c.damaged_content_warnings(report['warnings'])))

    def test_rtf_group_preserves_original_picture_with_or_without_matching_preview(self):
        source = self.root/'grouped-original.rtf'
        alternate = PNG[:-12] + chunk(b'tEXt', b'Comment\0Group preview') + PNG[-12:]
        uid = b'0123456789abcdef0123456789abcdef'

        def picture(raw, identifier, width=b'900'):
            return (br'{\pict\pngblip\picwgoal' + width + br'\pichgoal600{\*\blipuid ' + identifier +
                    b'}' + raw.hex().encode('ascii') + b'}')

        for name, original, preview, expected in (
            ('same-uid', PNG, picture(alternate, uid), PNG),
            ('different-uid', PNG, picture(alternate, b'0123456789abcdef0123456789abcdee'), alternate),
            ('different-placement', PNG, picture(alternate, uid, b'800'), alternate),
            ('missing-uid', PNG, picture(alternate, b''), alternate),
            ('missing-preview', PNG, b'', PNG),
            ('damaged-original', b'invalid picture', picture(alternate, uid), alternate),
            ('damaged-preview', PNG, picture(b'invalid picture', b''), PNG),
        ):
            with self.subTest(case=name):
                source.write_bytes(
                    br'{\rtf1 {\shpgrp{\*\shpinst{\shp{\*\shpinst{\sp{\sn pib}{\sv ' +
                    picture(original, uid) + br'}}}}{\shp{\*\shpinst{\shptxt Drawing label}}}}' +
                    (br'{\shprslt' + preview + b'}' if preview else b'') + b'}}')
                output = self.root/(name+'.epub')
                report = c.convert_book(source, output)
                if name == 'damaged-preview':
                    self.assertTrue(any('Часть изображений RTF в запасном представлении не читается' in warning
                                        for warning in c.damaged_content_warnings(report['warnings'])))
                with zipfile.ZipFile(output) as archive:
                    document = c.xml(archive.read('OEBPS/book.xhtml'))
                    [image] = document.findall('.//{*}img')
                    self.assertEqual(archive.read('OEBPS/'+image.get('src')), expected)
                    self.assertEqual(''.join(c.first(document, 'body').itertext()).count('Drawing label'), 1)

    def test_rtf_empty_picture_pair_is_reported_once(self):
        source = self.root/'empty-preview.rtf'
        source.write_bytes(br'{\rtf1 Before{\*\shppict}{\nonshppict}After}')
        output = source.with_suffix('.epub')
        report = c.convert_book(source,output)
        with zipfile.ZipFile(output) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')),'body')
            self.assertEqual(''.join(body.itertext()), 'Before[Изображение 1 недоступно.]After')
        self.assertEqual(sum(warning.startswith('Изображение ') for warning in
                             c.damaged_content_warnings(report['warnings'])),1)

    def test_rtf_horizontal_rules_keep_authored_extents(self):
        source = self.root / 'rules.rtf'

        def shape(height, **fields):
            properties = dict(shapeType=0, shapePath=4, geoRight=6421, geoBottom=height, **fields)
            pairs = ''.join(r'{\sp{\sn %s}{\sv %s}}' % field for field in properties.items())
            return (r'{\shp{\*\shpinst\shpleft100\shpright6521\shptop0\shpbottom%d'
                    r'\shpbxpage\shpbypara%s}}' % (height, pairs)).encode('ascii')

        stroke = dict(pVerticies='8;2;(0,0);(6421,0)', pSegmentInfo='2;5;16384;45824;1;45824;32768',
                      fLine=1, lineWidth=9525, lineColor=0x123456)
        strip = shape(20, pVerticies='8;5;(3000,0);(0,0);(0,11);(3000,11);(3000,0)',
                      pSegmentInfo='2;12;16384;45824;1;45824;1;45824;1;45824;1;45824;24577;32768',
                      fFilled=1, fLine=0, fillColor=0)
        source.write_bytes(br'{\rtf1 Before\par ' + shape(0, **stroke) + br'\par Between' + strip +
                           br'\par ' + shape(0, rotation=65536, **stroke) + br'\par After}')
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        images = document.findall('.//{*}img')
                        widths = [c.raster_header_size(archive.read('OEBPS/' + node.get('src'))) for node in images]
                    self.assertEqual([node.get('class') for node in images], ['paragraph-rule'] * 2)
                    self.assertIn('width:321.05pt;height:0.75pt', images[0].get('style'))
                    self.assertIn('width:150pt;height:0.55pt', images[1].get('style'))
                else:
                    document = c.xml(output.read_bytes())
                    self.assertEqual(len(document.findall('.//{*}image')), 2)
                    widths = [c.raster_header_size(base64.b64decode(node.text))
                              for node in document.findall('./{*}binary')]
                self.assertEqual(widths, [(428, 1), (200, 1)])
                text = ''.join(c.first(document, 'body').itertext())
                self.assertEqual(text, 'BeforeBetween[Фигура RTF № 3 не перенесена.]After')
                warnings = c.damaged_content_warnings(report['warnings'])
                self.assertEqual([warning for warning in warnings if 'фигура RTF №' in warning],
                                 ['Не перенесена фигура RTF № 3.'])

    def test_rtf_positioned_horizontal_lines_keep_strokes_and_padding(self):
        source = self.root / 'positioned-lines.rtf'

        def shape(top, origin='column', extra=''):
            return (r'{\shp{\*\shpinst\shpleft300\shptop%d\shpright900\shpbottom%d'
                    r'\shpbx%s\shpbypara\shpwr3\shpfhdr0\shpfblwtxt1'
                    r'{\sp{\sn shapeType}{\sv 20}}{\sp{\sn lineWidth}{\sv 19050}}'
                    r'{\sp{\sn lineColor}{\sv 66051}}%s}}' % (top, top, origin, extra)).encode('ascii')

        compatibility = (shape(45, extra=r'{\sp{\sn fLayoutInCell}{\sv 0}}' * 2)[:-1] +
                         br'{\shprslt{\*\do\dobxcolumn\dobypara\dpline\dpptx0\dppty0\dpptx600\dppty0'
                         br'\dpx300\dpy45\dpxsize600\dpysize0\dplinew30\dplinecor3\dplinecog2\dplinecob1}}}')
        overhang = (compatibility.replace(br'\shpleft300', br'\shpleft-90')
                     .replace(br'\shpright900', br'\shpright510').replace(br'\dpx300', br'\dpx-90'))
        source.write_bytes(br'{\rtf1 Beginning\par ' + shape(-90) + br' First\par ' +
                           shape(45,'margin') + br' Second\par ' + shape(0, 'page') + br' Third\par ' +
                           compatibility + br'\par ' + compatibility.replace(br'\dplinew30', br'\dplinew31') +
                           br'\par ' + overhang + b'}')
        expected = [('homelibre-word-line-900:120:0', (60, 8), (20, 0, 60, 2)),
                    ('homelibre-word-line-900:75:0', (60, 5), (20, 3, 60, 5)),
                    ('homelibre-word-line-900:75:0', (60, 5), (20, 3, 60, 5)),
                    ('homelibre-word-line-600:75:-90', (40, 5), (0, 3, 40, 5))]
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        placements = [(node.get('class'), archive.read('OEBPS/'+node.get('src')))
                                      for node in document.findall('.//{*}img')]
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                    resources = {node.get('id'): base64.b64decode(node.text)
                                 for node in document.findall('./{*}binary')}
                    placements = [(node.get('name'), resources[node[0].get('{'+c.XL+'}href')[1:]])
                                  for node in document.findall('.//{*}style') if node.find('{*}image') is not None]
                self.assertEqual(len(placements), len(expected))
                for (marker, data), (name, (width, height), bbox) in zip(placements, expected):
                    self.assertEqual(marker, name)
                    self.assertEqual(c.raster_header_size(data), (width, height))
                    start = data.index(b'IDAT')
                    length = struct.unpack_from('>I', data, start-4)[0]
                    pixels = zlib.decompress(data[start+4:start+4+length])
                    stride = 1+4*width
                    first_x, first_y, last_x, last_y = bbox
                    previous = bytes(4*width)
                    for y in range(height):
                        self.assertEqual(pixels[y*stride], 2)
                        row = bytes((part+above) & 255 for part, above in
                                    zip(pixels[y*stride+1:(y+1)*stride], previous))
                        for x in range(width):
                            pixel = row[4*x:4*x+4]
                            expected_alpha = 255 if first_x <= x < last_x and first_y <= y < last_y else 0
                            self.assertEqual(pixel[3], expected_alpha)
                            if expected_alpha:
                                self.assertEqual(pixel[:3], b'\x03\x02\x01')
                        previous = row
                self.assertEqual([warning for warning in report['warnings'] if 'фигура RTF №' in warning],
                                 ['Не перенесена фигура RTF № 3.', 'Не перенесена фигура RTF № 5.'])

    @unittest.skipUnless(os.name == 'nt', 'Windows raster composition')
    def test_rtf_vertical_rule_extends_above_its_picture(self):
        source = self.root / 'vertical-rule.rtf'
        line = (br'{\shp{\*\shpinst\shpleft240\shptop-300\shpright240\shpbottom600'
                br'\shpbxcolumn\shpbypara\shpwr3{\sp{\sn shapeType}{\sv 20}}}'
                br'{\shprslt{\*\do\dobxcolumn\dobypara\dpline\dpptx0\dppty0\dpptx0\dppty900'
                br'\dpx240\dpy-300\dpxsize0\dpysize900\dplinew30\dplinecor0\dplinecog0\dplinecob0}}}')
        pixels = (b'\0' + b'\x12\x34\x56\xff' * 32) * 48
        raster = (PNG[:8] + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 48, 8, 6, 0, 0, 0)) +
                  chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
        picture = br'{\pict\pngblip\picwgoal480\pichgoal720 ' + raster.hex().encode('ascii') + b'}'
        invalid = line.replace(br'\dpy-300', br'\dpy-315')
        original = (br'{\rtf1 Before\par '+line+picture+br'\par '+line+br'Alongside\par '+invalid+
                    br'\par After}')
        source.write_bytes(original)
        for extension in ('.epub', '.fb2'):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source, output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        resources = [archive.read('OEBPS/' + node.get('src')) for node in document.findall('.//{*}img')]
                else:
                    document = c.xml(output.read_bytes())
                    binaries = {node.get('id'): base64.b64decode(node.text) for node in document.findall('./{*}binary')}
                    resources = [binaries[node.get('{' + c.XL + '}href')[1:]] for node in document.findall('.//{*}body//{*}image')]
                self.assertEqual([c.raster_header_size(data) for data in resources], [(32, 68), (2, 60)])
                self.assertEqual(''.join(c.first(document, 'body').itertext()),
                                 'BeforeAlongside[Фигура RTF № 3 не перенесена.]After')
                self.assertEqual([warning for warning in c.damaged_content_warnings(report['warnings'])
                                  if 'фигура RTF №' in warning], ['Не перенесена фигура RTF № 3.'])
        self.assertEqual(source.read_bytes(), original)

    def test_rtf_shape_removes_only_a_matching_word_picture_preview(self):
        source = self.root / 'word-picture-shape.rtf'
        hex_picture = PNG.hex().encode('ascii')

        def shape(preview_width):
            property_picture = br'{\pict\pngblip\picwgoal900\pichgoal600 ' + hex_picture + b'}'
            preview_picture = (br'{\pict\pngblip\picwgoal' + str(preview_width).encode('ascii')
                               + br'\pichgoal600 ' + hex_picture + b'}')
            return (br'{\shp{\*\shpinst{\sp{\sn pib}{\sv ' + property_picture
                    + br'}}{\shptxt Before{\object{\*\objclass Word.Picture.8}'
                    + br'{\result ' + preview_picture + br'}}After}}{\shprslt Legacy preview}}')

        module_spec = importlib.util.spec_from_file_location('text_inputs', Path(c.__file__).with_name('text_inputs.py'))
        text_inputs = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(text_inputs)
        book = text_inputs.Book(c, source, set())
        text_inputs.read_rtf(book, br'{\rtf1 ' + shape(900) + br'\par ' + shape(1200) + b'}')
        first, second = book.body.findall('./{*}p')
        self.assertEqual(''.join(first.itertext()), 'BeforeAfter')
        self.assertEqual(''.join(second.itertext()), 'BeforeAfter')
        self.assertEqual([node.get('width') for node in first.findall('./{*}img')], ['60'])
        self.assertEqual([node.get('width') for node in second.findall('./{*}img')], ['60', '80'])
        warnings = c.damaged_content_warnings(book.warnings)
        self.assertTrue(any('Положение плавающих объектов RTF' in warning for warning in warnings))
        self.assertFalse(any('не перенесён встроенный объект' in warning.lower() for warning in warnings))

    def test_rtf_table_keeps_rows_combined_cells_and_inline_content(self):
        source = self.root/'rtf-table.rtf'
        picture = br'{\pict\pngblip '+PNG.hex().encode('ascii')+b'}'
        original = (
            br'{\rtf1 Before\par '
            br'\trowd\trhdr\clvmgf\cellx1000\clmgf\cellx2000\clmrg\cellx3000'
            br'\pard\intbl Shared\cell Wide\cell\cell\row '
            br'\trowd\cellx1000\cellx2000\cellx3000'
            br'\pard\intbl\cell Middle {\b bold} '+picture+br'\par'
            br'{\pard\itap0 Another paragraph}continued\cell Right\cell'
            br'{\trowd\clvmrg\cellx1000\cellx2000\cellx3000\row}'
            br'\pard After\par}')
        source.write_bytes(original)
        for extension, image_tag in (('.epub','img'),('.fb2','image')):
            with self.subTest(extension=extension):
                output = source.with_suffix(extension)
                report = c.convert_book(source,output)
                if extension == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                        [image] = document.findall('.//{*}img')
                        self.assertEqual(archive.read('OEBPS/'+image.get('src')),PNG)
                else:
                    document = c.xml(output.read_bytes())
                    [data] = document.findall('./{*}binary')
                    self.assertEqual(base64.b64decode(data.text),PNG)
                [table] = document.findall('.//{*}table')
                top, bottom = table.findall('./{*}tr')
                self.assertEqual([c.tag(n) for n in top],['th','th'])
                self.assertEqual([n.get('rowspan') for n in top],['2',None])
                self.assertEqual(top[1].get('colspan'),'2')
                self.assertEqual([''.join(''.join(n.itertext()).split()) for n in bottom],
                                 ['MiddleboldAnotherparagraphcontinued','Right'])
                self.assertIsNotNone(bottom[0].find('.//{*}'+image_tag))
                self.assertIsNotNone(bottom[0].find('.//{*}strong'))
                text = ''.join(c.first(document,'body').itertext())
                self.assertLess(text.index('Before'),text.index('Shared'))
                self.assertLess(text.index('Right'),text.index('After'))
                self.assertFalse(c.damaged_content_warnings(report['warnings']))
        self.assertEqual(source.read_bytes(),original)

    def test_rtf_nested_table_keeps_outer_grid_in_both_formats(self):
        source = self.root/'rtf-nested.rtf'
        source.write_bytes(
            br'{\rtf1 \trowd\cellx1400\cellx2200\pard\intbl Outer\par '
            br'\pard\intbl\itap2 Inner A\nestcell Inner B\nestcell'
            br'{\*\nesttableprops\trowd\cellx600\cellx1200\nestrow}'
            br'{\nonesttables Fallback only\par}'
            br'\pard\intbl\itap1 After inner\cell '
            br'\pard\intbl Sibling\cell\row\pard Done}')
        epub = source.with_suffix('.epub')
        report = c.convert_book(source,epub)
        with zipfile.ZipFile(epub) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')),'body')
        outer, inner = body.findall('.//{*}table')
        self.assertEqual(len(outer.findall('./{*}tr/{*}td')),2)
        self.assertEqual([''.join(n.itertext()) for n in inner.findall('./{*}tr/{*}td')],['Inner A','Inner B'])
        self.assertNotIn('Fallback only',''.join(body.itertext()))
        self.assertFalse(c.damaged_content_warnings(report['warnings']))

        fb2 = source.with_suffix('.fb2')
        report = c.convert_book(source,fb2)
        [table] = c.xml(fb2.read_bytes()).findall('.//{*}table')
        left, right = table.findall('./{*}tr/{*}td')
        self.assertEqual(' '.join(''.join(left.itertext()).split()), 'Outer Inner A Inner B After inner')
        self.assertEqual(''.join(right.itertext()).strip(),'Sibling')
        self.assertTrue(any(warning.startswith('Вложенные таблицы RTF') for warning in
                            c.damaged_content_warnings(report['warnings'])))

    def test_rtf_table_uses_physical_cell_edges_for_unmarked_colspan(self):
        source = self.root/'rtf-grid.rtf'
        source.write_bytes(
            br'{\rtf1\trowd\cellx1200\cellx2400\pard\intbl Wide\cell Right\cell\row'
            br'\trowd\cellx600\cellx1200\cellx2400\pard\intbl A\cell B\cell C\cell\row}')
        output = source.with_suffix('.epub')
        c.convert_book(source,output)
        with zipfile.ZipFile(output) as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')),'body')
        top,bottom = body.findall('./{*}table/{*}tr')
        self.assertEqual([cell.get('colspan') for cell in top],['2',None])
        self.assertEqual([cell.get('style') for cell in bottom],['width:25.0000%','width:25.0000%','width:50.0000%'])

    def test_rtf_truncated_table_row_preserves_readable_cells(self):
        source = self.root/'rtf-broken-row.rtf'
        source.write_bytes(br'{\rtf1 \trowd\cellx1200\cellx2400\pard\intbl First\cell Second}')
        output = source.with_suffix('.epub')
        report = c.convert_book(source,output)
        with zipfile.ZipFile(output) as archive:
            document = c.xml(archive.read('OEBPS/book.xhtml'))
        self.assertEqual([''.join(n.itertext()) for n in document.findall('.//{*}tr/{*}td')],['First','Second'])
        self.assertTrue(any('обрывается' in warning for warning in c.damaged_content_warnings(report['warnings'])))

    def test_rtf_object_result_is_retained_and_only_actual_losses_are_reported(self):
        picture = br'{\*\shppict{\pict\pngblip ' + PNG.hex().encode('ascii') + b'}}'
        empty_object = (br'{\object\objemb{\*\objdata }{\result ' + picture +
                        br'{\nonshppict{\pict unreadable}}}}')
        object_with_data = (br'{\object\objemb{\objclass HiddenClass}'
                            br'{\*\objdata\bin4 {A}B{\result HiddenData}}'
                            br'{\result Visible result}}')
        missing_preview = br'{\object\objemb{\*\objdata 4142}}'
        fixtures = (
            ('static', br'{\rtf1 Before ' + empty_object + b' after.}', False),
            ('partial', br'{\rtf1 Before ' + empty_object + object_with_data + missing_preview + b' after.}', True),
        )
        for name, data, partial in fixtures:
            source = self.root / (name + '.rtf')
            source.write_bytes(data)
            for extension in ('.epub', '.fb2'):
                with self.subTest(name=name, extension=extension):
                    output = source.with_suffix(extension)
                    report = c.convert_book(source, output)
                    warnings = c.damaged_content_warnings(report['warnings'])
                    if extension == '.epub':
                        with zipfile.ZipFile(output) as archive:
                            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
                            [image] = [node for node in body.iter() if c.tag(node) == 'img']
                            self.assertEqual(archive.read('OEBPS/' + image.get('src')), PNG)
                    else:
                        document = c.xml(output.read_bytes())
                        body = c.first(document, 'body')
                        [image] = [node for node in body.iter() if c.tag(node) == 'image']
                        [binary] = [node for node in document if c.tag(node) == 'binary']
                        self.assertEqual(base64.b64decode(binary.text), PNG)
                    text = ''.join(body.itertext())
                    self.assertNotIn('Встроенный объект RTF № 1', text)
                    self.assertNotIn('Hidden', text)
                    self.assertIn('Before', text)
                    self.assertIn('after.', text)
                    if partial:
                        self.assertIn('Visible result', text)
                        self.assertIn('Встроенный объект RTF № 3 не перенесён', text)
                        self.assertEqual(len(warnings), 2)
                        self.assertTrue(any('Данные для редактирования' in warning for warning in warnings))
                    else:
                        self.assertFalse(warnings)
                    self.assertEqual(source.read_bytes(), data)

    def test_bad_inputs_publish_nothing(self):
        for ext, content in [('.rtf', b'{\\rtf1 {broken'), ('.docx', b'PK\x03\x04\x00broken'), ('.odt', b'PK\x03\x04\x00broken'), ('.html', b'<p><img src="../secret.png">')]:
            source = self.root/('bad' + ext); source.write_bytes(content); output = self.root/('bad' + ext + '.fb2')
            with self.assertRaises((c.ConversionError, zipfile.BadZipFile)): c.convert_book(source, output)
            self.assertFalse(output.exists()); self.assertFalse(list(self.root.glob('.homelib-convert-*')))

    def test_project_and_proprietary_containers_are_never_plain_text(self):
        cases=[(b'SQLite format 3\0stub','.sqlite'),(b'ICEContainer 1.0!'+b'\0'*16,'.ibk'),
               (b'CoolReader 3 Cache File v3.03.09','.cr3'),(b'\rJAP-Frame-Set1\x01\0\0','.jap'),
               (b'ASMJS[::]64[::]0[::]<html><p>Code is not a book</p></html>','.sm'),
               (b'b1:as v:0.4 n:1 t:1','.b1'),(b'\0'*60+b'.rgoCERI'+b'\0'*10,'.rgo')]
        for index,(data,expected) in enumerate(cases):
            with self.subTest(format=expected):
                source=self.root/f'proprietary-{index}.wrong.pdf';source.write_bytes(data)
                self.assertEqual(c.detect_input(source),expected)
                for target in ['.fb2','.epub']:
                    output=self.root/(source.name+target)
                    with self.assertRaises(c.ConversionError):c.convert_book(source,output)
                    self.assertFalse(output.exists())
                self.assertEqual(source.read_bytes(),data)

    def test_compound_detection_beyond_prefix_and_cyclic_chain(self):
        directory,fat_sector=256,257
        data=bytearray((fat_sector+4)*512);data[:8]=bytes.fromhex('d0cf11e0a1b11ae1')
        data[28:32]=b'\xfe\xff\x09\0'
        def put(at,value):struct.pack_into('<I',data,at,value)
        put(44,3);put(48,directory);put(68,0xfffffffe)
        for at in range(76,512,4):put(at,0xffffffff)
        for index in range(3):put(76+index*4,fat_sector+index)
        offset=(directory+1)*512;chain=(fat_sector+3)*512+(directory%128)*4
        put(chain,0xfffffffe)
        for name,expected in [('WordDocument','.doc'),('PowerPoint Document','.ppt'),('Workbook','.xls')]:
            encoded=(name+'\0').encode('utf-16-le');data[offset:offset+64]=b'\0'*64
            data[offset:offset+len(encoded)]=encoded;struct.pack_into('<H',data,offset+64,len(encoded));data[offset+66]=2
            source=self.root/'far-office.wrong.pdf';source.write_bytes(data)
            self.assertEqual(c.detect_input(source),expected)
        data[offset+66]=0;put(chain,directory);source.write_bytes(data)
        self.assertEqual(c.detect_input(source),'.ole')
        output=self.root/'cycle.epub'
        with self.assertRaises(c.ConversionError):c.convert_book(source,output)
        self.assertFalse(output.exists())

    def test_works_compound_detection_uses_stream_signature_including_mini_stream(self):
        def works(magic, mini=False, cycle=False, stream_name='CONTENTS'):
            data=bytearray(11*512);data[:8]=bytes.fromhex('d0cf11e0a1b11ae1')
            data[28:34]=b'\xfe\xff\x09\0\x06\0'
            def put(at,value):struct.pack_into('<I',data,at,value)
            put(44,1);put(48,0);put(56,4096);put(68,0xfffffffe)
            for at in range(76,512,4):put(at,0xffffffff)
            put(76,1);put(1024,0xfffffffe)
            put(1024+2*4,2 if cycle else 3);put(1024+3*4,0xfffffffe)
            for at,name,kind,start,size in [(512,'Root Entry',5,2,2048),
                                           (640,stream_name,2,16 if cycle else 9 if mini else 2,64 if mini else 4096)]:
                encoded=(name+'\0').encode('utf-16-le');data[at:at+len(encoded)]=encoded
                struct.pack_into('<H',data,at+64,len(encoded));data[at+66]=kind
                put(at+116,start);struct.pack_into('<Q',data,at+120,size)
            offset=2048+64 if mini else 1536;data[offset:offset+7]=magic
            return data
        for mini in [False,True]:
            for magic in [b'CHNKWKS',b'CHNKINK']:
                with self.subTest(mini=mini,magic=magic):
                    source=self.root/'works-wrong.pdf';source.write_bytes(works(magic,mini))
                    self.assertEqual(c.detect_input(source),'.wps')
        for data in [works(b'UNKNOWN'),works(b'CHNKWKS',True,True),
                     works(b'CHNKWKS',stream_name='Unrelated')]:
            source=self.root/'unknown.wps';source.write_bytes(data)
            self.assertEqual(c.detect_input(source),'.ole')

    def test_wrong_extension_is_content_driven_for_text_html_and_docx(self):
        original=self.root/'fixture.docx';docx(original)
        inputs=[('docx',original.read_bytes(),'.docx','Точная сноска'),
                ('plain','Полный обычный текст. Финальная строка.'.encode('utf-8'),'.txt','Финальная строка.'),
                ('html','<p>Начало <b>Жирное слово</b>.</p><p>Конец книги.</p>'.encode('utf-8'),'.html','Жирное слово')]
        for kind,data,detected,expected in inputs:
            for extension in ['.unknown','.dic','.epab','.fb2','.zip','.pdf','.приключение','']:
                with self.subTest(kind=kind,extension=extension):
                    source=self.root/(kind+extension);source.write_bytes(data)
                    self.assertEqual(c.detect_input(source),detected)
                    for target in ['.fb2','.epub']:
                        output=self.root/(kind+extension+target+'.out'+target)
                        c.convert_book(source,output)
                        if target=='.fb2':tree=c.xml(output.read_bytes())
                        else:
                            with zipfile.ZipFile(output) as package:tree=c.xml(package.read('OEBPS/book.xhtml'))
                        self.assertIn(expected,''.join(tree.itertext()))
                    self.assertEqual(source.read_bytes(),data)
    def test_stored_zip_with_pdf_member_is_not_a_pdf(self):
        source=self.root/'renamed.book'
        with zipfile.ZipFile(source,'w',zipfile.ZIP_STORED) as archive:
            archive.writestr('book.pdf',b'%PDF-1.4 embedded member')
            archive.writestr('text.txt',b'Complete ordinary text.')
        self.assertEqual(c.detect_input(source),'.zip')

    def test_abw_text_emphasis_links_images_and_body_boundary(self):
        source=self.root/'renamed.pdf'
        source.write_text('<abiword xmlns="http://www.abisource.com/awml.dtd" xmlns:xlink="http://www.w3.org/1999/xlink">'
            '<metadata><m key="dc.title">Название</m></metadata><history>Do not insert history</history>'
            '<styles><s name="Strong" props="font-weight:bold"/></styles><section>'
            '<p style="Heading 1">Глава</p><p>Точный <c style="Strong">жирный текст</c> и конец.</p>'
            '<p><bookmark name="destination"/><a xlink:href="#destination">Ссылка</a><image dataid="pic"/></p>'
            '</section><data><d name="pic" base64="yes">'+base64.b64encode(PNG).decode()+'</d></data></abiword>',encoding='utf-8')
        self.outputs(source,['Точный жирный текст и конец.','Ссылка'],image=True)
        tree=c.xml((self.root/(source.name+'.fb2')).read_bytes())
        self.assertNotIn('Do not insert history',''.join(tree.itertext()))
        self.assertTrue(any(c.tag(n)=='strong' and c.plain(n)=='жирный текст' for n in tree.iter()))
    def test_missing_docx_note_and_external_image(self):
        for text in ['<w:footnoteReference w:id="99"/>', '<w:object/>']:
            source = self.root/'bad.docx'
            with zipfile.ZipFile(source, 'w') as z: z.writestr('word/document.xml', f'<w:document xmlns:w="{W}"><w:body><w:p><w:r>{text}</w:r></w:p></w:body></w:document>')
            with self.assertRaises(c.ConversionError): c.convert_book(source, self.root/'bad.epub')
    def test_inline_html_spaces_and_rtf_font_codepage(self):
        source = self.root/'fragment.html'; source.write_text('<b>Раз</b> <i>два</i> три', encoding='utf-8')
        self.outputs(source, ['Раз', 'два', ' три'])
        with zipfile.ZipFile(self.root/'fragment.html.epub') as z:
            self.assertIn('Раз два три', ''.join(c.xml(z.read('OEBPS/book.xhtml')).itertext()))
        source = self.root/'charset.rtf'
        source.write_bytes(('{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fcharset204 Times;}}\\f0 Русский ё}').encode('cp1251'))
        self.outputs(source, ['Русский ё'])
    def test_link_spans_and_tag_specific_html_attributes(self):
        source = self.root/'links.html'
        source.write_text('<p id="end"><a href="#end"><span><b>Ссылка</b></span></a></p><p value="bad">Текст</p><ol start="2"><li value="3">Пункт</li></ol><ul><li value="1">Маркер</li></ul>',encoding='utf-8')
        self.outputs(source, ['Ссылка', 'Текст', 'Пункт'])
        tree=c.xml((self.root/'links.html.fb2').read_bytes())
        for link in tree.iter('{'+c.FB+'}a'):
            for style in link.iter('{'+c.FB+'}style'): self.assertNotIn('name',style.attrib)
        with zipfile.ZipFile(self.root/'links.html.epub') as z:
            body=c.xml(z.read('OEBPS/book.xhtml'))
            self.assertTrue(all('value' not in n.attrib for n in body.iter() if c.tag(n)!='li'))
            self.assertTrue(all('value' not in n.attrib for ul in body.iter('{'+c.XH+'}ul') for n in ul))
    def test_kindle_epub_packaging_repair_keeps_resources(self):
        source=self.root/'chapter.html'; (self.root/'image.png').write_bytes(PNG)
        source.write_text('<p>Точный текст<img src="image.png"></p>',encoding='utf-8')
        initial=self.root/'initial.epub'; c.convert_book(source,initial)
        with zipfile.ZipFile(initial) as z: files={n:z.read(n) for n in z.namelist()}
        document=c.xml(files['OEBPS/book.xhtml'])
        next(n for n in document.iter() if c.tag(n)=='img').set('cid','kindle-internal')
        body=next(n for n in document.iter() if c.tag(n)=='body')
        svg=ET.SubElement(body,'{http://www.w3.org/2000/svg}svg',{'viewBox':'0 0 20 20'})
        ET.SubElement(svg,'{http://www.w3.org/2000/svg}circle',{'cx':'10','cy':'10','r':'5'})
        files['OEBPS/book.xhtml']=c.serialized(document)
        package_path='OEBPS/package.opf'
        package=c.xml(files[package_path]); spine=c.first(package,'spine')
        cover_id='inserted'
        ET.SubElement(c.first(package,'manifest'),'{'+c.OP+'}item',
                      {'id':cover_id,'media-type':'application/xhtml+xml','href':'Text/cover_page.xhtml'})
        spine.insert(0,ET.Element('{'+c.OP+'}itemref',{'idref':'x_ref_cover','linear':'no'}))
        guide=ET.SubElement(package,'{'+c.OP+'}guide')
        ET.SubElement(guide,'{'+c.OP+'}reference',{'type':'cover','title':'Cover','href':'Text/cover_page.xhtml'})
        files[package_path]=c.serialized(package)
        files['OEBPS/Text/cover_page.xhtml']=('<html xmlns="'+c.XH+'"><body><p>Cover page</p></body></html>').encode()
        incoming=self.root/'kindle.epub'
        with zipfile.ZipFile(incoming,'w') as z:
            for name,data in files.items(): z.writestr(name,data)
        output=self.root/'fixed.epub'; warnings=set(); c.kindle_epub(incoming,output,warnings)
        with zipfile.ZipFile(output) as z:
            fixed=c.xml(z.read('OEBPS/book.xhtml')); package=c.xml(z.read('OEBPS/package.opf'))
            self.assertEqual(c.first(package,'spine')[0].attrib,{'idref':cover_id,'linear':'no'})
            self.assertTrue(any('ссылка на страницу обложки' in value for value in warnings))
            self.assertTrue(all('cid' not in n.attrib for n in fixed.iter()))
            self.assertIn('svg',next(n for n in package.iter() if n.get('href')=='book.xhtml').get('properties','').split())
            for name,data in files.items():
                if '/images/' in name: self.assertEqual(z.read(name),data)
        checker,java=os.environ.get('HOMELIB_TEST_EPUBCHECK'),os.environ.get('HOMELIB_TEST_JAVA')
        if checker and java:
            result=subprocess.run([java,'-jar',checker,str(output)],capture_output=True,timeout=30,creationflags=0x08000000)
            self.assertEqual(result.returncode,0,(result.stdout+result.stderr).decode(errors='replace'))
    def test_kindle_unpack_binary_info_comment_does_not_damage_real_metadata(self):
        source = self.root / 'source.txt'
        source.write_text('Текст книги с корректными метаданными.', encoding='utf-8')
        initial = self.root / 'initial.epub'
        c.convert_book(source, initial)
        with zipfile.ZipFile(initial) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        package_path = 'OEBPS/package.opf'
        original = files[package_path]
        comment = b'\n<!-- BEGIN INFORMATION ONLY \n<meta name="Container_Id" content="t\x00\x80\xff"/>\nEND INFORMATION ONLY -->'
        for index, damaged in enumerate([original + comment, original + b'\x00',
                original + comment.replace(b'BEGIN INFORMATION ONLY', b'CUSTOM DEBUG COMMENT')]):
            incoming, output = self.root / f'unpacked-{index}.epub', self.root / f'repaired-{index}.epub'
            with zipfile.ZipFile(incoming, 'w') as archive:
                for name, data in files.items():
                    archive.writestr(name, damaged if name == package_path else data)
            if index:
                with self.assertRaises(c.ConversionError):
                    c.kindle_epub(incoming, output)
                self.assertFalse(output.exists())
                continue
            c.kindle_epub(incoming, output)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(list(c.xml(original).itertext()), list(c.xml(archive.read(package_path)).itertext()))
                for name, data in files.items():
                    if name != package_path:
                        self.assertEqual(archive.read(name), data)

    def test_invalid_encrypted_kindle_publishes_nothing(self):
        import struct
        tools = Path(os.environ.get('HOMELIB_TEST_TOOLS', Path(__file__).resolve().parents[3]/'Program/Out/Bin64/tools'))
        if not (tools/'kindle/convert_kf8.py').is_file() or not (tools/'kindle/lib/kindleunpack.py').is_file():
            self.skipTest('optional Kindle decoder required to inspect malformed Palm records')
        data=bytearray(126); data[60:68]=b'BOOKMOBI'; data[78:82]=struct.pack('>I',86)
        data[102:106]=b'MOBI'; data[98:100]=b'\x00\x01'
        source=self.root/'protected.azw'; source.write_bytes(data); output=self.root/'protected.fb2'
        with self.assertRaisesRegex(c.ConversionError, 'Повреждена таблица записей MOBI'):
            c.convert_book(source, output, tools_root=tools)
        self.assertEqual(source.read_bytes(), data)
        self.assertFalse(output.exists()); self.assertFalse(list(self.root.glob('.homelib-convert-*')))

    def test_docx_many_small_runs_are_processed_in_order(self):
        source = self.root / 'many-runs.docx'
        run = '<w:r><w:rPr><w:rFonts w:ascii="Test"/></w:rPr><w:t>т</w:t></w:r>'
        paragraphs = [
            f'<w:p><w:r><w:t>Блок {i}: </w:t></w:r>{run * 220}</w:p>'
            for i in range(600)
        ]
        margin_rule = ('<w:r><w:pict><v:line from="-41.5pt,474pt" to="-41.5pt,516.25pt" '
                       'style="mso-position-horizontal-relative:margin;z-index:1;"/></w:pict></w:r>')
        for index in (0, 20, 440):
            paragraphs[index] = paragraphs[index].replace('</w:p>', margin_rule + '</w:p>')
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('word/document.xml', f'<w:document xmlns:w="{W}" '
                             f'xmlns:v="urn:schemas-microsoft-com:vml"><w:body>{"".join(paragraphs)}</w:body></w:document>')
        expected = [f'Блок {i}: ' + 'т' * 220 for i in range(600)]
        before = hashlib.sha256(source.read_bytes()).digest()
        for extension in ['.epub', '.fb2']:
            output = self.root / ('many-runs' + extension)
            result = c.convert_book(source, output)
            self.assertIn('Не перенесены вертикальные линии на полях DOCX. Пропущено линий: 3.',
                          c.damaged_content_warnings(result['warnings']))
            if extension == '.epub':
                with zipfile.ZipFile(output) as archive:
                    root = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
            else:
                root = c.first(c.xml(output.read_bytes()), 'body')
            self.assertEqual([c.plain(node) for node in root.iter() if c.tag(node) == 'p'], expected)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), before)

    def test_document_with_many_small_word_blocks_keeps_every_paragraph(self):
        source = self.root / 'many-word-blocks.docx'
        output = self.root / 'many-word-blocks.epub'
        # Each block fits the streaming parser's bound. Together they exceed
        # the old two-million-element limit on the whole document.
        empty_runs = b'<w:r><w:t/></w:r>' * 500
        expected = [f'Параграф {number}' for number in range(2001)]
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            with archive.open('word/document.xml', 'w') as part:
                part.write(f'<w:document xmlns:w="{W}"><w:body>'.encode())
                for paragraph in expected:
                    part.write(b'<w:p>')
                    part.write(empty_runs)
                    part.write(f'<w:r><w:t>{paragraph}</w:t></w:r></w:p>'.encode())
                part.write(b'</w:body></w:document>')
        c.convert_book(source, output)
        with zipfile.ZipFile(output) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
        self.assertEqual([c.plain(node) for node in chapter.iter('{' + c.XH + '}p')], expected)

    def test_docx_dtd_does_not_publish_partial_output(self):
        source = self.root / 'entities.docx'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('word/document.xml',
                             (f'<!DOCTYPE w:document [<!ENTITY text "injected">]>'
                              f'<w:document xmlns:w="{W}"><w:body><w:p><w:r><w:t>&text;</w:t>'
                              '</w:r></w:p></w:body></w:document>').encode('utf-16'))
        output = self.root / 'entities.epub'
        with self.assertRaisesRegex(c.ConversionError, 'DTD'):
            c.convert_book(source, output)
        self.assertFalse(output.exists())

    def test_docx_large_parallel_text_keeps_every_table_row(self):
        source = self.root / 'parallel-text.docx'
        # These runs take the table beyond 500,000 elements while leaving
        # each individual row small enough to process independently.
        empty_runs = '<w:r><w:t/></w:r>' * 275
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            with archive.open('word/document.xml', 'w') as part:
                part.write(f'<w:document xmlns:w="{W}"><w:body>'.encode())
                part.write(b'<w:p><w:r><w:t>Before</w:t></w:r></w:p>')
                part.write(b'<w:tbl><w:tblGrid><w:gridCol/><w:gridCol/></w:tblGrid>')
                for i in range(1000):
                    row = (f'<w:tr><w:tc><w:p>{empty_runs}<w:r><w:t>Line {i}</w:t></w:r></w:p></w:tc>'
                           f'<w:tc><w:p><w:r><w:t>Строка {i}</w:t></w:r></w:p></w:tc></w:tr>')
                    part.write(row.encode())
                part.write(b'</w:tbl><w:p><w:r><w:t>After</w:t></w:r></w:p></w:body></w:document>')
        for suffix in ('.epub', '.fb2'):
            with self.subTest(suffix=suffix):
                output = source.with_suffix(suffix)
                report = c.convert_book(source, output)
                if suffix == '.epub':
                    with zipfile.ZipFile(output) as archive:
                        document = c.xml(archive.read('OEBPS/book.xhtml'))
                else:
                    document = c.xml(output.read_bytes())
                    c.validate_fb2_output(document)
                [table] = document.findall('.//{*}table')
                rows = [[c.plain(cell) for cell in row] for row in table]
                self.assertEqual(rows, [[f'Line {i}', f'Строка {i}'] for i in range(1000)])
                paragraphs = [c.plain(node) for node in document.iter() if c.tag(node) == 'p']
                self.assertEqual((paragraphs[0], paragraphs[-1]), ('Before', 'After'))
                self.assertFalse(c.damaged_content_warnings(report['warnings']))

    def test_php_code_does_not_become_a_book(self):
        source = self.root / 'script.txt'
        output = self.root / 'script.epub'
        for encoding in ['utf-8-sig', 'utf-16']:
            source.write_text("<?php echo '%PDF-1.7';", encoding=encoding)
            self.assertEqual(c.detect_input(source), '.php')
            for options in [{}, {'output_profile': 'kepub'}]:
                with self.assertRaisesRegex(c.ConversionError, 'PHP-код'):
                    c.convert_book(source, output, **options)
                self.assertFalse(output.exists())
        source = self.root / 'ordinary.php'
        source.write_text(f'<html><body><p>{TEXT}</p></body></html>', encoding='utf-8')
        self.assertEqual(c.detect_input(source), '.html')
        self.outputs(source, [TEXT])


if __name__ == '__main__': unittest.main()

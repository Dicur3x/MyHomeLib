"""Independent text/structure/resource oracles for additional book inputs."""
from pathlib import Path
import base64
import hashlib
import importlib.util
import os
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
        z.writestr('fb3/description.xml', '<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description"><title><main>FB3 книга</main></title><fb3-relations><subject link="translator" id="00000000-0000-0000-0000-000000000002"><title><main>Человек</main></title><last-name>Человек</last-name></subject></fb3-relations><lang>ru</lang><paper-publish-info title="FB3 книга" publisher="Издательство Ёжик" city="Киев" year="2025"><isbn>978-fixture</isbn></paper-publish-info><annotation><p>Мысль — краткое описание книги.</p></annotation></fb3-description>')


class TextInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='HomeLibRu-text-test-'); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
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
    def test_html_fragment_legacy_entities_and_inline_styles(self):
        source = self.root/'book.html'; (self.root/'image.png').write_bytes(PNG)
        source.write_bytes(('<html lang="ru"><head><meta charset="windows-1251"><title>HTML книга</title><script>NOT BOOK</script></head><body><h1>Глава один</h1><p>Ё &amp; текст <b><i>Жирный курсив</i></b><img src="image.png"><h2>Подглава</h2><p id="end">Конец<br>Новая строка</p><h1>Глава два</h1><a href="#end">Ссылка</a></body></html>').encode('cp1251'))
        self.outputs(source, ['Ё & текст', 'Жирный курсив', 'Новая строка'], True, True, True)
        with zipfile.ZipFile(self.root/'book.html.epub') as z: self.assertNotIn('NOT BOOK', z.read('OEBPS/book.xhtml').decode())
    def test_docx(self):
        source = self.root/'book.docx'; docx(source); self.outputs(source, [TEXT, 'Точная сноска', 'Ячейка'], True, True, True)
    def test_odt(self):
        source = self.root/'book.odt'; odt(source); self.outputs(source, [TEXT, 'Точная сноска'], True, True, True)
    def test_fb3(self):
        source = self.root/'book.fb3'; fb3(source); self.outputs(source, [TEXT, 'Точная сноска', 'Подглавный текст.'], True, True, True)
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
    def test_rtf_unicode_groups_escapes_and_picture(self):
        source = self.root/'book.rtf'
        def rtf_unicode(text): return ''.join('\\u' + str(int.from_bytes(text.encode('utf-16-le')[i:i+2], 'little', signed=True)) + '?' for i in range(0, len(text.encode('utf-16-le')), 2))
        source.write_bytes(('{\\rtf1\\ansi\\ansicpg1251\\uc1 {\\fonttbl{\\f0 Times;}}\\outlinelevel0 Глава один\\par '+rtf_unicode(TEXT)+' {\\b\\i Жирный курсив} \\{скобки\\}\\par {\\pict\\pngblip '+PNG.hex()+'}\\par Конец}').encode('cp1251'))
        self.outputs(source, [TEXT, 'Жирный курсив', '{скобки}', 'Конец'], True, True)
    def test_bad_inputs_publish_nothing(self):
        for ext, content in [('.rtf', b'{\\rtf1 {broken'), ('.docx', b'not zip'), ('.odt', b'not zip'), ('.html', b'<p><img src="../secret.png">')]:
            source = self.root/('bad' + ext); source.write_bytes(content); output = self.root/('bad' + ext + '.fb2')
            with self.assertRaises((c.ConversionError, zipfile.BadZipFile)): c.convert_book(source, output)
            self.assertFalse(output.exists()); self.assertFalse(list(self.root.glob('.homelib-convert-*')))
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
        incoming=self.root/'kindle.epub'
        with zipfile.ZipFile(incoming,'w') as z:
            for name,data in files.items(): z.writestr(name,data)
        output=self.root/'fixed.epub'; c.kindle_epub(incoming,output)
        with zipfile.ZipFile(output) as z:
            fixed=c.xml(z.read('OEBPS/book.xhtml')); package=c.xml(z.read('OEBPS/package.opf'))
            self.assertTrue(all('cid' not in n.attrib for n in fixed.iter()))
            self.assertIn('svg',next(n for n in package.iter() if n.get('href')=='book.xhtml').get('properties','').split())
            for name,data in files.items():
                if '/images/' in name: self.assertEqual(z.read(name),data)
        checker,java=os.environ.get('HOMELIB_TEST_EPUBCHECK'),os.environ.get('HOMELIB_TEST_JAVA')
        if checker and java:
            result=subprocess.run([java,'-jar',checker,str(output)],capture_output=True,timeout=30,creationflags=0x08000000)
            self.assertEqual(result.returncode,0,(result.stdout+result.stderr).decode(errors='replace'))
    def test_kindle_encryption_rejected_before_unpacking(self):
        import struct
        data=bytearray(126); data[60:68]=b'BOOKMOBI'; data[78:82]=struct.pack('>I',86)
        data[102:106]=b'MOBI'; data[98:100]=b'\x00\x01'
        source=self.root/'protected.azw'; source.write_bytes(data); output=self.root/'protected.fb2'
        with self.assertRaises(c.ConversionError) as error: c.convert_book(source,output)
        self.assertIn('Encrypted Kindle',str(error.exception)); self.assertEqual(source.read_bytes(),data)
        self.assertFalse(output.exists()); self.assertFalse(list(self.root.glob('.homelib-convert-*')))


if __name__ == '__main__': unittest.main()

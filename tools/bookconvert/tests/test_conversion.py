"""Structure and data preservation tests; optional independent XSD/EPUBCheck."""
from pathlib import Path
import base64, hashlib, importlib.util, json, os, struct, subprocess, sys, tempfile, unittest, zipfile, zlib
import xml.etree.ElementTree as ET
from unittest import mock

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
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-conversion-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root/'source.fb2'; self.source.write_text(FB2.replace('{image}',base64.b64encode(PNG).decode()), encoding='utf-8')
        self.original = digest(self.source)
    def tearDown(self):
        self.assertEqual(digest(self.source), self.original)
        self.assertFalse(list(self.root.glob('.homelib-convert-*')))
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
          <p><a href="#outer">outer</a><a href="#row">row</a><a href="#cell">cell</a><a href="#inner">inner</a></p>''')
        before = digest(epub); output = self.root/'nested.fb2'
        report = c.convert_book(epub, output); self.validate_fb2(output)
        book = ET.parse(output).getroot(); body = c.first(book, 'body'); text = ''.join(body.itertext())
        words = ['OuterBefore', 'InnerWords', 'OuterAfter', 'NextCell']
        self.assertEqual([text.count(word) for word in words], [1]*len(words))
        self.assertEqual([text.index(word) for word in words], sorted(text.index(word) for word in words))
        ids = {n.get('id') for n in book.iter() if n.get('id')}
        for link in book.iter('{'+c.FB+'}a'):
            self.assertIn(link.get('{'+c.XL+'}href').removeprefix('#'), ids)
        self.assertTrue(any(base64.b64decode(c.plain(n)) == PNG for n in c.children(book, 'binary')))
        self.assertTrue(any('Вложенные таблицы' in warning for warning in report['warnings']))
        self.assertEqual(digest(epub), before)

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
        for content in ['<p>Текст</p><video src="video.mp4"/>','<p><a href="missing.xhtml#gone">Ссылка</a></p>','<p><img src="https://invalid.example/image.png"/></p>']:
            epub=self.generic(content,'<p>Конец</p>'); before=digest(epub)
            with self.assertRaises(c.ConversionError): c.convert_book(epub,self.root/'unsupported.fb2')
            self.assertEqual(digest(epub),before); self.assertFalse((self.root/'unsupported.fb2').exists())
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
    def test_notes_outside_spine_and_without_fragment(self):
        for reference in ['notes.xhtml#n','notes.xhtml']:
            epub=self.generic('<p>Ссылка <a epub:type="noteref" href="'+reference+'">6</a></p>', '<aside id="n" epub:type="footnote"><p>6. Примечание</p></aside>', notes_in_spine=False)
            output=self.root/('notes-'+str(len(list(self.root.glob('notes-*.fb2'))))+'.fb2')
            c.convert_book(epub,output); self.validate_fb2(output)
            book=ET.parse(output).getroot(); notes=next(n for n in c.children(book,'body') if n.get('name')=='notes')
            self.assertEqual(c.plain(notes).count('6. Примечание'),1)
            target=next(book.iter('{'+c.FB+'}a')).get('{'+c.XL+'}href')[1:]
            self.assertTrue(any(n.get('id')==target for n in notes.iter()))
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
    def test_generated_chapter_ids_do_not_collide_with_source_ids(self):
        text=self.source.read_text(encoding='utf-8').replace('<section id="one">','<section id="chapter-1">').replace('<section id="two">','<section>')
        source=self.root/'ids.fb2'; source.write_text(text,encoding='utf-8'); output=self.root/'ids.epub'
        c.convert_book(source,output); self.validate_epub(output)
        with zipfile.ZipFile(output) as archive:
            ids=[n.get('id') for n in c.xml(archive.read('OEBPS/body-1.xhtml')).iter() if n.get('id')]
            self.assertEqual(len(ids),len(set(ids))); self.assertIn('chapter-1',ids)
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
    def test_epub2_cover_metadata_is_preserved(self):
        epub=self.generic('<p>Текст</p>','<p>Конец</p>',extra_metadata='<meta name="cover" content="i"/>')
        output=self.root/'cover.fb2'; c.convert_book(epub,output); self.validate_fb2(output)
        book=ET.parse(output).getroot(); ti=c.first(c.first(book,'description'),'title-info'); cover=c.first(ti,'coverpage')
        self.assertIsNotNone(cover); identity=cover[0].get('{'+c.XL+'}href')[1:]
        binary=next(n for n in c.children(book,'binary') if n.get('id')==identity); self.assertEqual(base64.b64decode(c.plain(binary)),PNG)
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
    def test_single_raster_in_svg_keeps_bytes_and_complex_svg_fails(self):
        svg='<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="'+c.XL+'" viewBox="0 0 1 1"><title>Описание</title><image width="1" height="1" xlink:href="image.png"/></svg>'
        source=self.generic('<p>Текст</p>'+svg,'<p>Конец</p>'); output=self.root/'svg.fb2'
        c.convert_book(source,output); self.validate_fb2(output); book=ET.parse(output).getroot()
        self.assertEqual(base64.b64decode(c.plain(c.children(book,'binary')[0])),PNG)
        image=next(c.first(book,'body').iter('{'+c.FB+'}image')); self.assertEqual(image.get('alt'),'Описание')
        source=self.generic('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0,0L1,1"/></svg>','<p>Конец</p>')
        with self.assertRaises(c.ConversionError): c.convert_book(source,self.root/'vector.fb2')
        self.assertFalse((self.root/'vector.fb2').exists())
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

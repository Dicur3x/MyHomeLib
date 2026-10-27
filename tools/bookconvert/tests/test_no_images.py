"""Text-only exports keep prose/notes and remove all image representations."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile

from test_conversion import c, FB2, PNG
from test_image_input import TOOLS
NOTE = '[Изображение не включено в эту копию]'


class NoImages(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-text-export-')
        self.root = Path(self.temporary.name)
        self.source = self.root/'source.fb2'
        text = FB2.replace('{image}',base64.b64encode(PNG).decode('ascii'))
        text = text.replace('<p><image l:href="#cover"/></p>',
                            '<p>До <image l:href="#cover"/> после. <strong>Подпись</strong> хвост.</p>')
        self.source.write_text(text,encoding='utf-8')
        self.epub = self.root/'source.epub'
        c.convert_book(self.source,self.epub)

    def tearDown(self):
        self.temporary.cleanup()

    def check_text_only(self, path):
        checked = path
        if path.suffix == '.epub':
            with zipfile.ZipFile(path) as source:
                self.assertIsNone(source.testzip())
                self.assertEqual(source.infolist()[0].filename,'mimetype')
                self.assertEqual(source.infolist()[0].compress_type,zipfile.ZIP_STORED)
                for entry in source.infolist():
                    self.assertNotIn(Path(entry.filename).suffix.lower(),{'.png','.jpeg','.jpg','.gif','.webp','.svg'})
                    if entry.filename.endswith('.opf'):
                        package = c.xml(source.read(entry))
                        self.assertFalse([n for n in package.iter() if n.get('media-type','').startswith('image/')])
                        self.assertFalse([n for n in package.iter() if 'cover-image' in n.get('properties','').split()])
            checked = path.with_suffix('.checked.fb2')
            c.convert_book(path,checked)
        root = c.xml(checked.read_bytes())
        self.assertIn(NOTE,''.join(root.itertext()))
        self.assertFalse([n for n in root.iter() if c.tag(n) in {'image','coverpage'}])
        self.assertFalse([n for n in root if c.tag(n)=='binary' and n.get('content-type','').startswith('image/')])
        self.assertIn('До  после. Подпись хвост.',''.join(root.itertext()).replace(NOTE,''))
        self.assertIn('Ё, ї, є, ґ, ў, English. 😀',''.join(root.itertext()))
        self.assertIn('Сноска & текст.',''.join(root.itertext()))
        footnote = next(n for n in root.iter() if c.tag(n)=='a' and n.get('type')=='note')
        self.assertEqual(footnote.get('{'+c.XL+'}href'),'#note')
        self.assertTrue(any(n.get('id')=='note' for n in root.iter()))

    def test_all_fb2_epub_directions_keep_text_notes_inline_tails_and_sources(self):
        for source in (self.source,self.epub):
            original = hashlib.sha256(source.read_bytes()).digest()
            for suffix in ('.fb2','.epub'):
                with self.subTest(source=source.suffix,target=suffix):
                    output = self.root/('without-'+source.suffix[1:]+suffix)
                    report = c.convert_book(source,output,image_quality='none',tools_root=self.root/'absent-tools')
                    self.check_text_only(output)
                    self.assertTrue(any('без изображений' in warning for warning in report['warnings']))
                    self.assertEqual(hashlib.sha256(source.read_bytes()).digest(),original)
        self.assertFalse(list(self.root.glob('homelib-*'))+list(self.root.glob('.homelib-*')))

    def test_unrestored_external_pictures_need_no_decoder_for_explicit_text_only(self):
        # FLibrary's intermediate source has image references but keeps their
        # actual bytes in companion archives. Explicit omission can remove the
        # references directly, before any reader/decoder restores those bytes.
        source = self.root/'unrestored.fb2'
        document = c.xml(self.source.read_bytes())
        for node in list(document):
            if c.tag(node) == 'binary': document.remove(node)
        source.write_bytes(c.serialized(document))
        epub = self.root/'unrestored.epub'
        with zipfile.ZipFile(self.epub) as original, zipfile.ZipFile(epub,'w') as output:
            for entry in original.infolist():
                if Path(entry.filename).suffix.lower() in {'.png','.jpg','.jpeg'}: continue
                output.writestr(entry,original.read(entry))
        for original in (source,epub):
            original_hash = hashlib.sha256(original.read_bytes()).digest()
            for suffix in ('.fb2','.epub'):
                target = self.root/('text-from-unrestored-'+original.suffix[1:]+suffix)
                report = c.convert_book(original,target,image_quality='none',tools_root=self.root/'no-decoders')
                self.check_text_only(target)
                self.assertTrue(any('без изображений' in warning for warning in report['warnings']))
                self.assertEqual(hashlib.sha256(original.read_bytes()).digest(),original_hash)
        self.assertFalse(list(self.root.glob('homelib-*'))+list(self.root.glob('.homelib-*')))

    def test_small_images_offer_text_only_without_an_encoder_and_exact_size(self):
        for source in (self.source,self.epub):
            for suffix in ('.fb2','.epub'):
                options,choice = self.root/'options.json',self.root/'choice.txt'
                error,estimates = [],[]
                def choose():
                    try:
                        until = time.monotonic()+20
                        while not options.exists():
                            if time.monotonic()>until: raise AssertionError('No text-only choice')
                            time.sleep(.01)
                        value = json.loads(options.read_text('utf-8'))
                        self.assertGreater(value['sizes']['none'],0)
                        estimates.append(value['sizes']['none'])
                        choice.write_text('none',encoding='utf-8')
                    except BaseException as failure:
                        error.append(failure);choice.write_text('cancel',encoding='utf-8')
                thread = threading.Thread(target=choose);thread.start()
                output = self.root/('chosen-'+source.suffix[1:]+suffix)
                try: c.convert_book(source,output,image_quality='ask',image_options=options,
                                    image_choice=choice,tools_root=self.root/'no-codec')
                except c.ConversionError:
                    thread.join(21)
                    if error: raise error[0]
                    raise
                finally: thread.join(21)
                self.assertFalse(thread.is_alive());self.assertFalse(error,error)
                self.assertEqual(output.stat().st_size,estimates[0])
                self.check_text_only(output)
                options.unlink();choice.unlink()

    def test_epub_removes_webp_gif_svg_backgrounds_cover_and_references_keeps_fonts(self):
        source = self.root/'mixed.epub'
        container = '<container xmlns="'+c.CN+'"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>'
        package = ('<package xmlns="'+c.OP+'" version="3.0"><metadata xmlns:dc="'+c.DC+'">'
                   '<dc:title>Mixed images</dc:title><dc:language>ru</dc:language><dc:identifier id="id">test</dc:identifier>'
                   '<meta name="cover" content="png"/></metadata><manifest>'+
                   ''.join('<item id="'+i+'" href="'+name+'" media-type="'+mime+'"'+extra+'/>' for i,name,mime,extra in [
                       ('chapter','chapter.xhtml','application/xhtml+xml',''),('notes','notes.xhtml','application/xhtml+xml',''),
                       ('cover','cover.xhtml','application/xhtml+xml',''),('nav','nav.xhtml','application/xhtml+xml',' properties="nav"'),
                       ('plates','plates.xhtml','application/xhtml+xml',''),
                       ('png','cover.png','image/png',' properties="cover-image"'),('webp','image.webp','image/webp',''),
                       ('gif','image.gif','image/gif',''),('svg','image.svg','image/svg+xml',''),('css','book.css','text/css',''),
                       ('font','font.woff','font/woff','')])+
                   '</manifest><spine><itemref idref="cover"/><itemref idref="chapter"/><itemref idref="plates"/><itemref idref="notes"/></spine>'
                   '<guide><reference type="cover" href="cover.xhtml"/></guide></package>')
        def page(body):return '<html xmlns="'+c.XH+'" xmlns:epub="'+c.EP+'"><head><title>Title</title></head><body>'+body+'</body></html>'
        with zipfile.ZipFile(source,'w') as output:
            for name,data in {'mimetype':'application/epub+zip','META-INF/container.xml':container,'OPS/book.opf':package,
                'OPS/chapter.xhtml':page('<p id="back">Начало <img src="image.webp"/> середина <img src="image.gif"/> конец.</p>'
                     '<p><svg xmlns="http://www.w3.org/2000/svg"><text>Vector drawing</text></svg> После вектора.</p>'
                     '<p style="background-image:url(cover.png)">Абзац <a epub:type="noteref" href="notes.xhtml#n">1</a>.</p>'),
                'OPS/notes.xhtml':page('<aside id="n" epub:type="footnote"><p>Примечание <a href="chapter.xhtml#back">назад</a>.</p></aside>'),
                'OPS/cover.xhtml':page('<img src="cover.png"/>'),
                'OPS/plates.xhtml':page('<h1>Отдельная глава с рисунками</h1><img src="cover.png"/>'),
                'OPS/nav.xhtml':page('<nav epub:type="toc"><ol><li><a href="cover.xhtml">Обложка</a></li><li><a href="chapter.xhtml">Текст</a></li></ol></nav>'),
                'OPS/book.css':'@font-face{font-family:Reader;src:url(font.woff)} body{background-image:url("cover.png")}',
                'OPS/cover.png':PNG,'OPS/image.webp':b'RIFF\x04\0\0\0WEBP','OPS/image.gif':b'GIF89a',
                'OPS/image.svg':'<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>',
                'OPS/font.woff':b'original-font-bytes'}.items():output.writestr(name,data)
        before = source.read_bytes();output = self.root/'mixed-text.epub'
        c.convert_book(source,output,image_quality='none')
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('OPS/font.woff'),b'original-font-bytes')
            self.assertNotIn('OPS/cover.xhtml',archive.namelist())
            self.assertIn('Отдельная глава с рисунками',archive.read('OPS/plates.xhtml').decode('utf-8'))
            self.assertNotIn('cover.png',archive.read('OPS/book.css').decode())
            self.assertIn('url(font.woff)',archive.read('OPS/book.css').decode())
            for name in ['OPS/chapter.xhtml','OPS/notes.xhtml','OPS/nav.xhtml']:
                root = c.xml(archive.read(name));text=''.join(root.itertext())
                self.assertFalse([n for n in root.iter() if c.tag(n) in {'img','svg','picture'}])
                for n in root.iter():
                    self.assertNotEqual(n.get('href'),'cover.xhtml')
                if name.endswith('chapter.xhtml'):
                    self.assertIn('Начало  середина  конец.',text.replace(NOTE,''))
                    self.assertEqual(text.count(NOTE),3)
                    self.assertTrue(any(n.get('href')=='notes.xhtml#n' for n in root.iter()))
            opf = c.xml(archive.read('OPS/book.opf'))
            self.assertFalse([n for n in opf.iter() if n.get('idref')=='cover' or c.tag(n)=='reference' or n.get('name')=='cover'])
            self.assertFalse([n for n in opf.iter() if n.get('media-type','').startswith('image/')])
        self.assertEqual(source.read_bytes(),before)

    def test_image_only_book_and_scan_fail_without_empty_output(self):
        source = self.root/'only-images.fb2'
        source.write_text('<FictionBook xmlns="'+c.FB+'" xmlns:l="'+c.XL+'"><description><title-info>'
            '<book-title>Scan</book-title></title-info></description><body><section><title><p>Страница 1</p></title>'
            '<image l:href="#page"/></section></body><binary id="page" content-type="image/png">'+
            base64.b64encode(PNG).decode()+'</binary></FictionBook>',encoding='utf-8')
        scan = self.root/'scan.png';scan.write_bytes(PNG)
        for path in (source,scan):
            before = path.read_bytes()
            for suffix in ('.fb2','.epub'):
                output = self.root/('empty'+suffix)
                with self.assertRaisesRegex(c.ConversionError,'распознать'):
                    c.convert_book(path,output,image_quality='none')
                self.assertFalse(output.exists());self.assertEqual(path.read_bytes(),before)
        existing = self.root/'existing.fb2';existing.write_bytes(b'user output')
        with self.assertRaises(c.ConversionError):c.convert_book(self.source,existing,image_quality='none')
        self.assertEqual(existing.read_bytes(),b'user output')
        self.assertFalse(list(self.root.glob('homelib-*'))+list(self.root.glob('.homelib-*')))

    def test_cli_none_and_reading_keep_their_separate_behaviour(self):
        output = self.root/'cli.fb2'
        process = subprocess.run([str(TOOLS/'kindle/python/python.exe'),'-I','-B','-X','utf8',str(Path(c.__file__)),
                                  str(self.source),str(output),'--image-quality','none'],capture_output=True,timeout=20,
                                 creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        self.assertEqual(process.returncode,0,process.stdout.decode('utf-8',errors='replace'))
        self.check_text_only(output)
        reading = self.root/'read.epub'
        c.convert_book(self.source,reading,reading=True,image_quality='none')
        with zipfile.ZipFile(reading) as archive:
            self.assertTrue(any(n.endswith('.png') for n in archive.namelist()))

    def test_webp_only_choice_needs_no_image_decoder_and_image_link_keeps_its_caption(self):
        source = self.root/'webp-only.fb2'
        text = self.source.read_text('utf-8').replace(base64.b64encode(PNG).decode(),
                   base64.b64encode(b'RIFF\x04\0\0\0WEBP').decode()).replace('image/png','image/webp')
        text = text.replace('<strong>Подпись</strong>','<a l:href="#unused"><strong>Подпись</strong></a>')
        source.write_text(text,encoding='utf-8')
        options,choice = self.root/'options.json',self.root/'choice.txt'
        failures=[]
        def choose():
            try:
                until=time.monotonic()+20
                while not options.exists():
                    if time.monotonic()>until:raise AssertionError('WebP text-only choice was not offered')
                    time.sleep(.01)
                value=json.loads(options.read_text('utf-8'))
                self.assertEqual(value['sampled'],0)
                self.assertGreater(value['sizes']['none'],0)
                choice.write_text('none',encoding='utf-8')
            except BaseException as error:
                failures.append(error);choice.write_text('cancel',encoding='utf-8')
        thread=threading.Thread(target=choose);thread.start()
        output=self.root/'webp-text.fb2'
        try:c.convert_book(source,output,image_quality='ask',image_options=options,image_choice=choice,tools_root=self.root/'absent')
        finally:thread.join(21)
        self.assertFalse(thread.is_alive());self.assertFalse(failures,failures)
        self.check_text_only(output)
        epub=self.root/'webp-text.epub'
        c.convert_book(source,epub,image_quality='none')
        self.check_text_only(epub)

    def test_legacy_cyrillic_encoding_is_kept_instead_of_doubling_text_size(self):
        source=self.root/'legacy.fb2'
        book=c.xml(self.source.read_bytes())
        paragraph=next(n for body in c.children(book,'body') for n in body.iter() if c.tag(n)=='p')
        paragraph.text='Текст для старой читалки. '*20000
        source.write_bytes(c.ET.tostring(book,encoding='windows-1251',xml_declaration=True))
        output=self.root/'legacy-text.fb2'
        c.convert_book(source,output,image_quality='none')
        self.assertIn(b"encoding='windows-1251'",output.read_bytes()[:100])
        self.assertLess(output.stat().st_size,source.stat().st_size)
        self.assertIn(paragraph.text,c.plain(c.xml(output.read_bytes())))

    def test_picture_directly_in_fb2_body_gets_a_valid_section_for_its_note(self):
        source=self.root/'body-picture.fb2'
        text=self.source.read_text('utf-8').replace('<body><section','<body><image l:href="#cover"/><section',1)
        source.write_text(text,encoding='utf-8')
        c.validate_fb2_output(c.xml(source.read_bytes()))
        for suffix in ('.fb2','.epub'):
            output=self.root/('body-note'+suffix)
            c.convert_book(source,output,image_quality='none')
            self.check_text_only(output)
            if suffix=='.fb2':
                body=c.first(c.xml(output.read_bytes()),'body')
                self.assertEqual(c.tag(body[0]),'section')
                self.assertEqual(c.plain(body[0]),NOTE)


if __name__ == '__main__': unittest.main()

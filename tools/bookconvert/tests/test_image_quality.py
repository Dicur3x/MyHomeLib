"""Export size choices, source identity, real Windows encoding and cancellation."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile
from unittest.mock import patch

from test_image_input import c, fixed, TOOLS
from test_xps_input import middle_pixel


def wait_options(path, seconds, message):
    """The Windows file may briefly exist but still be sharing-locked.

    Retry only absence/sharing errors within the original handshake deadline.
    Published but invalid JSON must fail immediately, never be retried away.
    """
    deadline = time.monotonic() + seconds
    while True:
        try:
            return json.loads(path.read_text(encoding='utf-8'))
        except (FileNotFoundError, PermissionError):
            if time.monotonic() >= deadline:
                raise AssertionError(message)
            time.sleep(.02)


class QualityHandshakeTests(unittest.TestCase):
    def test_transient_absence_and_sharing_lock_require_complete_json(self):
        path = Path('unused-handshake-test.json')
        with patch.object(Path, 'read_text', side_effect=[
                FileNotFoundError(), PermissionError(), '{"images":2}']) as read:
            self.assertEqual(wait_options(path, 1, 'No estimate'), {'images': 2})
            self.assertEqual(read.call_count, 3)
        with patch.object(Path, 'read_text', return_value='{'):
            with self.assertRaises(json.JSONDecodeError):
                wait_options(path, 1, 'No estimate')

    def test_permanent_sharing_lock_still_fails_within_the_same_deadline(self):
        with patch.object(Path, 'read_text', side_effect=PermissionError()):
            with self.assertRaisesRegex(AssertionError, 'No estimate'):
                wait_options(Path('unused-handshake-test.json'), .03, 'No estimate')


class ImageQuality(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        width, height = 900, 1200
        noise = random.Random(534).randbytes(width*height)
        raw = bytearray()
        # Fine three-pixel table rules over a noisy scan background. A low
        # quality encoder must not turn this into a blank/low-resolution page.
        for y in range(height):
            for x in range(width):
                shade = 15 if x%90 < 3 or y%30 < 3 else 224+noise[y*width+x]%31
                raw.extend((shade,shade,shade))
        cls.picture = fixed.png(raw,width,height)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = Path(self.temporary.name)
        self.source = self.root/'scan.png'; self.source.write_bytes(self.picture)
        self.original = hashlib.sha256(self.picture).hexdigest()

    def tearDown(self): self.temporary.cleanup()

    def assert_clean(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(),self.original)
        self.assertFalse(list(self.root.glob('homelib-*')))
        self.assertFalse(list(self.root.glob('.homelib-*')))

    def pictures(self,path):
        if path.suffix == '.fb2':
            root = c.xml(path.read_bytes(),c.MAX_TOTAL)
            return [base64.b64decode(n.text) for n in root if c.tag(n)=='binary']
        with zipfile.ZipFile(path) as archive:
            root = c.xml(archive.read('OEBPS/package.opf'))
            for node in root.iter():
                if c.tag(node)=='item' and node.get('media-type','').startswith('image/'):
                    data = archive.read('OEBPS/'+node.get('href'))
                    self.assertEqual(node.get('media-type'),'image/jpeg' if data.startswith(b'\xff\xd8') else 'image/png')
                    return [data]
        self.fail('No image in EPUB')

    def test_all_profiles_both_targets_keep_pages_and_estimates_match(self):
        for extension in ('.fb2','.epub'):
            sizes = []; estimates = []
            for profile in ('high','balanced','economy'):
                options = self.root/'options.json'; choice = self.root/'choice.txt'
                failure = []
                def choose():
                    try:
                        value = wait_options(options, 25, 'No image estimate')
                        self.assertEqual(value['images'],1); self.assertEqual(value['sampled'],1)
                        self.assertEqual(value['format'],extension[1:].upper())
                        self.assertEqual(value['sizes'],value['split_sizes'])
                        self.assertEqual(value['sizes'],value['auto_sizes'])
                        self.assertLessEqual(value['sizes']['economy'],value['sizes']['balanced'])
                        self.assertLessEqual(value['sizes']['balanced'],value['sizes']['high'])
                        estimates.append(value['sizes'][profile])
                        choice.write_text(profile,encoding='utf-8')
                    except BaseException as error:
                        failure.append(error)
                        choice.write_text('cancel',encoding='utf-8')
                thread = threading.Thread(target=choose);thread.start()
                output = self.root/(profile+extension)
                try:
                    c.convert_book(self.source,output,tools_root=TOOLS,image_quality='ask',image_options=options,image_choice=choice)
                except c.ConversionError:
                    if failure:raise failure[0]
                    raise
                finally: thread.join(26)
                self.assertFalse(thread.is_alive()); self.assertFalse(failure,failure)
                pictures = self.pictures(output);self.assertEqual(len(pictures),1)
                if profile=='high':self.assertEqual(pictures[0],self.picture)
                sizes.append(output.stat().st_size)
                options.unlink();choice.unlink();self.assert_clean()
            self.assertLess(sizes[-1],sizes[0]*.65)
            for actual,estimate in zip(sizes,estimates):
                self.assertLess(abs(actual-estimate),max(4096,actual*.05))

    def test_reading_and_default_conversion_keep_original_images(self):
        for metadata in ({},{'reading':True,'image_quality':'economy'}):
            output = self.root/('read'+str(len(list(self.root.iterdir())))+'.epub')
            c.convert_book(self.source,output,tools_root=TOOLS,**metadata)
            self.assertEqual(self.pictures(output),[self.picture]);self.assert_clean()

    def test_reading_ignores_export_scan_layout(self):
        picture=fixed.png(bytes([240,240,240])*1501*900,1501,900)
        source=self.root/'reading-spread.png'; source.write_bytes(picture)
        output=self.root/'reading-spread.epub'
        c.convert_book(source,output,tools_root=TOOLS,reading=True,image_quality='economy',
                       scan_layout='split',scan_exclude='1')
        self.assertEqual(self.pictures(output),[picture]); self.assert_clean()

    def test_original_choice_and_zip_estimates_keep_full_resolution(self):
        for extension in ('.fb2','.epub'):
            options=self.root/'original-options.json'; choice=self.root/'original-choice.txt'
            captured=[]; failure=[]
            def choose():
                try:
                    value=wait_options(options,30,'No original/ZIP estimate')
                    self.assertIn('original',value['sizes'])
                    self.assertEqual(set(value['zip_sizes']),{'original','high','balanced','economy','none'})
                    self.assertEqual(value['zip_sizes']['none'],0)  # This source is a scan.
                    self.assertGreater(value['sizes']['original'],0)
                    self.assertGreater(value['zip_sizes']['original'],0)
                    captured.append(value); choice.write_text('original',encoding='utf-8')
                except BaseException as error:
                    failure.append(error); choice.write_text('cancel',encoding='utf-8')
            thread=threading.Thread(target=choose); thread.start()
            output=self.root/('original-choice'+extension)
            try:c.convert_book(self.source,output,tools_root=TOOLS,image_quality='ask',image_options=options,image_choice=choice)
            finally:thread.join(31)
            self.assertFalse(thread.is_alive()); self.assertFalse(failure,failure)
            self.assertEqual(self.pictures(output),[self.picture])
            packed=output.with_suffix(extension+'.zip')
            with zipfile.ZipFile(packed,'w',compression=zipfile.ZIP_DEFLATED) as archive:archive.write(output,output.name)
            estimate=captured[0]['zip_sizes']['original']; actual=packed.stat().st_size
            self.assertLess(abs(actual-estimate),max(8192,actual*.10))
            options.unlink(); choice.unlink(); self.assert_clean()

    @unittest.skipUnless(os.name=='nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'Windows PDFium')
    def test_pdf_spread_original_estimate_matches_default_rendering(self):
        drawing=b'0.96 0.96 0.96 rg 0 0 1000 500 re f 0 0 0 rg '+b' '.join(
            f'{x} {y} 8 3 re f'.encode('ascii') for y in range(30,470,15) for x in range(20,980,15))
        objects=[b'<< /Type /Catalog /Pages 2 0 R >>',
            b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1000 500] /Resources << >> /Contents 4 0 R >>',
            b'<< /Length '+str(len(drawing)).encode('ascii')+b' >>\nstream\n'+drawing+b'\nendstream']
        data=b'%PDF-1.4\n'; offsets=[0]
        for number,obj in enumerate(objects,1):
            offsets.append(len(data)); data+=f'{number} 0 obj\n'.encode('ascii')+obj+b'\nendobj\n'
        xref=len(data); data+=b'xref\n0 5\n0000000000 65535 f \n'
        data+=b''.join(f'{offset:010d} 00000 n \n'.encode('ascii') for offset in offsets[1:])
        data+=b'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n'+str(xref).encode('ascii')+b'\n%%EOF\n'
        source=self.root/'scan-spread.pdf'; source.write_bytes(data)
        ordinary=self.root/'scan-default.fb2'; c.convert_book(source,ordinary,tools_root=TOOLS)
        options=self.root/'pdf-options.json'; choice=self.root/'pdf-choice.txt'; captured=[]; failure=[]
        def choose():
            try:
                value=wait_options(options,30,'No PDF original-quality estimate')
                self.assertTrue(value['scan_pages']); captured.append(value)
                choice.write_text('original',encoding='utf-8')
            except BaseException as error:
                failure.append(error); choice.write_text('cancel',encoding='utf-8')
        thread=threading.Thread(target=choose); thread.start(); output=self.root/'scan-estimated.fb2'
        try:c.convert_book(source,output,tools_root=TOOLS,image_quality='ask',image_options=options,image_choice=choice)
        finally:thread.join(31)
        self.assertFalse(thread.is_alive()); self.assertFalse(failure,failure)
        self.assertEqual(self.pictures(ordinary),self.pictures(output))
        self.assertLess(abs(output.stat().st_size-captured[0]['sizes']['original']),max(8192,output.stat().st_size*.10))
        self.assertEqual(source.read_bytes(),data); self.assert_clean()

    def test_illustrated_fb2_and_epub_offer_quality_preserve_text_cover_and_gif(self):
        # A flowing book, not a scan: two illustrations, a separate GIF,
        # cover metadata and paragraphs around the images must all survive.
        noise = random.Random(535).randbytes(600 * 900 * 3)
        color = fixed.png(bytes((180, 40, 20)[i % 3] + (v & 15)
                                for i, v in enumerate(noise)), 600, 900)
        gif = base64.b64decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
        originals = {'color': color, 'grid': self.picture, 'icon': gif}
        source = self.root / 'illustrated.fb2'
        source.write_text('<FictionBook xmlns="' + c.FB + '" xmlns:l="' + c.XL + '">'
            '<description><title-info><genre>child_tale</genre><author><first-name>Имя</first-name>'
            '<last-name>Автора</last-name></author><book-title>Иллюстрированная книга</book-title>'
            '<lang>ru</lang><coverpage><image l:href="#color"/></coverpage></title-info></description>'
            '<body><section><title><p>Глава ёжика</p></title><p>Перед цветной иллюстрацией.</p>'
            '<image l:href="#color"/><p>Между картинками — обычный текст.</p>'
            '<image l:href="#grid"/><image l:href="#icon"/><p>Конец истории.</p></section></body>' +
            ''.join('<binary id="' + name + '" content-type="' +
                    ('image/gif' if name == 'icon' else 'image/png') + '">' +
                    base64.b64encode(data).decode('ascii') + '</binary>'
                    for name, data in originals.items()) + '</FictionBook>', encoding='utf-8')
        epub = self.root / 'illustrated.epub'
        c.convert_book(source, epub, tools_root=TOOLS)
        for input_path in (source, epub):
            source_hash = hashlib.sha256(input_path.read_bytes()).hexdigest()
            for extension in ('.fb2', '.epub'):
                options = self.root / 'options.json'; choice = self.root / 'choice.txt'
                failure, estimates = [], []

                def choose():
                    try:
                        value = wait_options(options, 45, 'Illustrated book did not offer image quality')
                        self.assertEqual(value['images'], 2)  # GIF is preserved directly.
                        self.assertEqual(value['sampled'], 2)
                        sizes = value['sizes']
                        self.assertLessEqual(sizes['economy'], sizes['balanced'])
                        self.assertLess(sizes['balanced'], sizes['high'])
                        estimates.append(sizes['economy'])
                        choice.write_text('economy', encoding='utf-8')
                    except BaseException as error:
                        failure.append(error); choice.write_text('cancel', encoding='utf-8')

                thread = threading.Thread(target=choose); thread.start()
                output = self.root / ('optimized-' + input_path.suffix[1:] + extension)
                try:
                    c.convert_book(input_path, output, tools_root=TOOLS, image_quality='ask',
                                   image_options=options, image_choice=choice)
                finally:
                    thread.join(46)
                self.assertFalse(thread.is_alive()); self.assertFalse(failure, failure)
                self.assertLess(abs(output.stat().st_size - estimates[0]), max(8192, output.stat().st_size * .05))
                checked = output
                if extension == '.epub':
                    checked = output.with_suffix('.checked.fb2')
                    c.convert_book(output, checked, tools_root=TOOLS)
                book = c.xml(checked.read_bytes(), c.MAX_TOTAL)
                self.assertEqual([c.plain(n) for body in c.children(book, 'body')
                                  for n in body.iter() if c.tag(n) == 'p'],
                                 ['Глава ёжика', 'Перед цветной иллюстрацией.',
                                  'Между картинками — обычный текст.', 'Конец истории.'])
                binaries = {n.get('id'): base64.b64decode(n.text)
                            for n in c.children(book, 'binary')}
                self.assertEqual(set(binaries), set(originals))
                self.assertEqual(binaries['icon'], gif)
                self.assertLess(sum(map(len, binaries.values())), sum(map(len, originals.values())) * .8)
                self.assertEqual([n.get('{' + c.XL + '}href') for n in book.iter()
                                  if c.tag(n) == 'image'], ['#color', '#color', '#grid', '#icon'])
                self.assertEqual(hashlib.sha256(input_path.read_bytes()).hexdigest(), source_hash)
                options.unlink(); choice.unlink(); self.assert_clean()

    def test_cli_canceled_quality_never_publishes_output(self):
        options=self.root/'options.json';choice=self.root/'choice.txt';output=self.root/'canceled.epub'
        process=subprocess.Popen([str(TOOLS/'kindle/python/python.exe'),'-I','-B','-X','utf8',str(Path(c.__file__)),str(self.source),str(output),
                                  '--tools-root',str(TOOLS),'--image-quality','ask','--image-options',str(options),'--image-choice',str(choice)],
                                 stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        try:
            started=time.monotonic()
            while not options.exists() and process.poll() is None and time.monotonic()-started<25:time.sleep(.03)
            self.assertTrue(options.exists());choice.write_text('cancel',encoding='utf-8')
            log=process.communicate(timeout=15)[0]
            self.assertNotEqual(process.returncode,0);self.assertIn('отменён',json.loads(log.decode('utf-8'))['error'])
            self.assertFalse(output.exists());self.assert_clean()
        finally:
            if process.poll() is None:process.kill();process.wait()

    def test_existing_output_survives_quality_conversion(self):
        output=self.root/'existing.epub';output.write_bytes(b'user data')
        with self.assertRaises(c.ConversionError):c.convert_book(self.source,output,tools_root=TOOLS,image_quality='economy')
        self.assertEqual(output.read_bytes(),b'user data');self.assert_clean()

    def test_invalid_large_raster_cannot_be_published_after_quality_choice(self):
        self.source.write_bytes(b'\x89PNG\r\n\x1a\n'+bytes(150000))
        self.original=hashlib.sha256(self.source.read_bytes()).hexdigest()
        output=self.root/'broken.epub'
        with self.assertRaises(c.ConversionError):
            c.convert_book(self.source,output,tools_root=TOOLS,image_quality='economy')
        self.assertFalse(output.exists());self.assert_clean()

    def test_existing_fb2_over_64_mib_can_be_recompressed(self):
        source=self.root/'large.fb2';output=self.root/'smaller.fb2'
        with source.open('wb') as stream:
            stream.write(('<FictionBook xmlns="'+c.FB+'" xmlns:l="'+c.XL+'">'
                '<description><title-info><book-title>Scan</book-title><lang>ru</lang></title-info></description>'
                '<body><section><p>Fine grid</p><image l:href="#scan"/></section></body>'
                '<binary id="scan" content-type="image/png">').encode())
            stream.write(base64.b64encode(self.picture))
            for _ in range(65):stream.write(b' '*1024*1024)
            stream.write(b'</binary></FictionBook>')
        with source.open('rb') as stream:before=hashlib.file_digest(stream,'sha256').hexdigest()
        with self.assertRaises(c.ConversionError):c.convert_book(source,output,tools_root=TOOLS)
        c.convert_book(source,output,tools_root=TOOLS,image_quality='economy')
        self.assertLess(output.stat().st_size,2*1024*1024)
        self.assertIn('Fine grid',c.plain(c.xml(output.read_bytes())))
        self.assertEqual(len(self.pictures(output)),1)
        with source.open('rb') as stream:self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(),before)
        self.assert_clean()

    def ordered_pictures(self,path):
        if path.suffix=='.fb2':
            document=c.xml(path.read_bytes(),c.MAX_TOTAL)
            images={node.get('id'):base64.b64decode(node.text) for node in document if c.tag(node)=='binary'}
            return [images[node.get('{'+c.XL+'}href')[1:]] for node in document.iter() if c.tag(node)=='image']
        with zipfile.ZipFile(path) as archive:
            document=c.xml(archive.read('OEBPS/book.xhtml'))
            return [archive.read('OEBPS/'+node.get('src')) for node in document.iter() if c.tag(node)=='img']

    def test_split_spreads_keep_odd_center_pixels_order_and_portrait_cover(self):
        width,height=2001,1200
        spread=fixed.png((bytes([180,40,20])*1000+bytes([20,60,180])*1001)*height,width,height)
        cover=fixed.png(bytes([40,160,80])*(600*900),600,900)
        source=self.root/'spreads.cbz'
        with zipfile.ZipFile(source,'w') as archive:
            archive.writestr('01.png',cover);archive.writestr('02.png',spread)
        before=source.read_bytes()
        for extension in ('.fb2','.epub'):
            output=self.root/('split'+extension)
            c.convert_book(source,output,tools_root=TOOLS,image_quality='high',scan_layout='split')
            pictures=self.ordered_pictures(output)
            self.assertEqual(len(pictures),3)
            self.assertEqual([tuple(int.from_bytes(data[at:at+4],'big') for at in (16,20)) for data in pictures],
                             [(600,900),(1000,1200),(1001,1200)])
            self.assertEqual([middle_pixel(data) for data in pictures],[(40,160,80),(180,40,20),(20,60,180)])
            self.assertEqual(source.read_bytes(),before);self.assert_clean()
        output=self.root/'unsplit.epub'
        c.convert_book(source,output,tools_root=TOOLS,image_quality='high')
        self.assertEqual(len(self.ordered_pictures(output)),2)
        output=self.root/'except-last.epub'
        c.convert_book(source,output,tools_root=TOOLS,image_quality='high',scan_layout='split',scan_exclude='2')
        self.assertEqual(len(self.ordered_pictures(output)),2)
        self.assertEqual(self.ordered_pictures(output)[-1],spread)

    def test_scan_choice_occurs_before_whole_book_and_batches_keep_every_page(self):
        source=self.root/'many.cbz'
        # Forty physical spreads use one real raster payload; references must
        # remain forty/eighty pages even when resource bytes are deduplicated.
        # A 1500x900 scan exercises the layout-specific size estimates.
        scan=fixed.png((bytes([230,230,230])*1500)*900,1500,900)
        with zipfile.ZipFile(source,'w') as archive:
            for number in range(40):archive.writestr(f'{number:03}.png',scan)
        options=self.root/'stream-options.json';choice=self.root/'stream-choice.txt';failure=[];pages=[]
        def progress(stage,completed,total):
            if stage=='pages':pages.append(completed)
        def choose():
            try:
                value=wait_options(options,30,'No early scan choice')
                self.assertTrue(value['scan_pages']);self.assertEqual(value['images'],40)
                self.assertEqual(value['sampled'],9);self.assertLess(max(pages,default=0),10)
                self.assertEqual(set(value['split_sizes']),{'original','high','balanced','economy','none'})
                self.assertEqual(value['sizes']['none'],0)  # Scans are the book's pages, not optional artwork.
                choice.write_text('economy|split|except=1,40',encoding='utf-8')
            except BaseException as error:
                failure.append(error)
                choice.write_text('cancel',encoding='utf-8')
        thread=threading.Thread(target=choose);thread.start()
        output=self.root/'many.epub'
        try:c.convert_book(source,output,tools_root=TOOLS,image_quality='ask',image_options=options,image_choice=choice,progress=progress)
        finally:thread.join(31)
        self.assertFalse(thread.is_alive());self.assertFalse(failure,failure)
        self.assertEqual(len(self.ordered_pictures(output)),78)
        self.assertEqual(pages[-1],40);self.assert_clean()

    def test_invalid_scan_page_exceptions_never_publish_a_book(self):
        for index,value in enumerate(('0','5001','3-1','1,','1;2','-2','1-5001')):
            output=self.root/f'rejected-{index}.epub'
            with self.assertRaises(c.ConversionError):
                c.convert_book(self.source,output,tools_root=TOOLS,image_quality='economy',scan_layout='split',scan_exclude=value)
            self.assertFalse(output.exists());self.assert_clean()

    def test_automatic_spread_boundary_moves_between_crease_and_blank_gutter(self):
        width,height=2000,900
        source=self.root/'moving-spine.cbz';cuts=(860,1140)
        with zipfile.ZipFile(source,'w') as archive:
            for number,cut in enumerate(cuts):
                raw=bytearray(bytes([245,245,245])*(width*height))
                for y in range(80,820):
                    if y%28<6:
                        for left,right in ((50,cut-40),(cut+40,width-50)):
                            raw[(y*width+left)*3:(y*width+right)*3]=bytes([35,35,35])*(right-left)
                    if number==0:
                        raw[(y*width+cut-3)*3:(y*width+cut+3)*3]=bytes([60,60,60])*6
                archive.writestr(f'{number:02}.png',fixed.png(raw,width,height))
        before=source.read_bytes()
        for extension in ('.fb2','.epub'):
            output=self.root/('moving'+extension)
            # An explicit layout also works with the default image quality.
            c.convert_book(source,output,tools_root=TOOLS,scan_layout='auto')
            pictures=self.ordered_pictures(output);self.assertEqual(len(pictures),4)
            widths=[int.from_bytes(data[16:20],'big') for data in pictures]
            for at,cut in enumerate(cuts):
                self.assertLessEqual(abs(widths[at*2]-cut),6)
                self.assertEqual(sum(widths[at*2:at*2+2]),width)
                self.assertEqual([int.from_bytes(data[20:24],'big') for data in pictures[at*2:at*2+2]],[height,height])
            self.assertEqual(source.read_bytes(),before);self.assert_clean()

    def test_automatic_layout_keeps_uncertain_picture_whole_and_reports_page(self):
        width,height=1200,700
        # No crease or empty strip through this full-width illustration.
        raw=bytes(random.Random(735).randbytes(width*height*3))
        source=self.root/'wide.png';source.write_bytes(fixed.png(raw,width,height))
        output=self.root/'uncertain.epub'
        report=c.convert_book(source,output,tools_root=TOOLS,image_quality='high',scan_layout='auto')
        pictures=self.ordered_pictures(output);self.assertEqual(len(pictures),1)
        self.assertEqual(pictures[0],source.read_bytes())
        self.assertTrue(any('граница разворота' in warning and '№ 1' in warning for warning in report['warnings']))
        output=self.root/'forced.epub'
        c.convert_book(source,output,tools_root=TOOLS,image_quality='high',scan_layout='split')
        self.assertEqual(len(self.ordered_pictures(output)),2);self.assert_clean()

    def test_scan_split_preserves_exif_visual_order_and_individual_color_profile(self):
        import struct,zlib
        jpeg=base64.b64decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCABgAEADAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD4/r+dz/SAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgDzev9lD/GcKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgAoAKACgD//Z')
        for orientation,expected in ((5,((180,40,20),(20,60,180))),(6,((20,60,180),(180,40,20))),
                                     (7,((20,60,180),(180,40,20))),(8,((180,40,20),(20,60,180)))):
            exif=b'Exif\0\0MM\0*'+struct.pack('>IHHHI',8,1,274,3,1)+struct.pack('>H',orientation)+b'\0\0'+bytes(4)
            data=jpeg[:2]+b'\xff\xe1'+struct.pack('>H',len(exif)+2)+exif+jpeg[2:]
            source=self.root/f'oriented-{orientation}.jpg';source.write_bytes(data)
            output=self.root/f'oriented-{orientation}.epub'
            c.convert_book(source,output,tools_root=TOOLS,image_quality='economy',scan_layout='split')
            pictures=self.ordered_pictures(output);self.assertEqual(len(pictures),2)
            self.assertEqual([(int.from_bytes(p[16:20],'big'),int.from_bytes(p[20:24],'big')) for p in pictures],[(48,64)]*2)
            for picture,color in zip(pictures,expected):
                self.assertTrue(all(abs(a-b)<=5 for a,b in zip(middle_pixel(picture),color)))
            self.assertEqual(source.read_bytes(),data)
            output=self.root/f'keep-{orientation}.epub'
            c.convert_book(source,output,tools_root=TOOLS,image_quality='economy')
            self.assertEqual(self.ordered_pictures(output),[data])
        profile=base64.b64decode('AAACTGxjbXMEQAAAbW50clJHQiBYWVogB+oACgAXAA8AMQANYWNzcE1TRlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPbWAAEAAAAA0y1sY21zAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALZGVzYwAAAQgAAAA2Y3BydAAAAUAAAABMd3RwdAAAAYwAAAAUY2hhZAAAAaAAAAAsclhZWgAAAcwAAAAUYlhZWgAAAeAAAAAUZ1hZWgAAAfQAAAAUclRSQwAAAggAAAAgZ1RSQwAAAggAAAAgYlRSQwAAAggAAAAgY2hybQAAAigAAAAkbWx1YwAAAAAAAAABAAAADGVuVVMAAAAaAAAAHABzAFIARwBCACAAYgB1AGkAbAB0AC0AaQBuAABtbHVjAAAAAAAAAAEAAAAMZW5VUwAAADAAAAAcAE4AbwAgAGMAbwBwAHkAcgBpAGcAaAB0ACwAIAB1AHMAZQAgAGYAcgBlAGUAbAB5WFlaIAAAAAAAAPbWAAEAAAAA0y1zZjMyAAAAAAABDEIAAAXe///zJQAAB5MAAP2Q///7of///aIAAAPcAADAblhZWiAAAAAAAABvoAAAOPUAAAOQWFlaIAAAAAAAACSfAAAPhAAAtsNYWVogAAAAAAAAYpcAALeHAAAY2XBhcmEAAAAAAAMAAAACZmYAAPKnAAANWQAAE9AAAApbY2hybQAAAAAAAwAAAACj1wAAVHsAAEzNAACZmgAAJmYAAA9c')
        data=fixed.png((bytes([180,40,20])*600+bytes([20,60,180])*600)*700,1200,700)
        payload=b'Book profile\0\0'+zlib.compress(profile);kind=b'iCCP'
        chunk=struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
        data=data[:33]+chunk+data[33:]
        source=self.root/'profile.png';source.write_bytes(data);output=self.root/'profile.epub'
        c.convert_book(source,output,tools_root=TOOLS,image_quality='economy',scan_layout='split')
        pictures=self.ordered_pictures(output);self.assertEqual(len(pictures),2)
        for picture in pictures:
            at=8;found=False
            while at<len(picture):
                size=int.from_bytes(picture[at:at+4],'big')
                if picture[at+4:at+8]==b'iCCP':
                    block=picture[at+8:at+8+size];end=block.index(0)
                    self.assertEqual(zlib.decompress(block[end+2:]),profile);found=True
                at+=size+12
            self.assertTrue(found,'Cropped scan lost its color profile')
        self.assertEqual(source.read_bytes(),data);self.assert_clean()

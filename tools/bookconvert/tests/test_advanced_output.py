from base64 import b64decode, b64encode
from contextlib import closing
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import advanced_output
import convert_book as conversion
import epub_pdf_output
from test_text_inputs import docx


FB2 = '''<?xml version="1.0" encoding="utf-8"?>
<f:FictionBook xmlns:f="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<f:description><f:title-info><f:genre>sf</f:genre>
<f:author><f:first-name>Anna</f:first-name><f:last-name>Fixture</f:last-name></f:author>
<f:book-title>Export fixture</f:book-title><f:lang>en</f:lang></f:title-info>
<f:document-info><f:author><f:nickname>HomeLibre</f:nickname></f:author>
<f:id>27bcc9a4-52de-4bac-bad3-555e3cfd0d2c</f:id><f:version>1</f:version></f:document-info></f:description>
<f:body><f:section id="chapter"><f:title><f:p>First chapter</f:p></f:title>
<f:p>Text before the illustration. <f:a l:href="#note" type="note">1</f:a></f:p>
<f:table><f:tr><f:td>Test table</f:td></f:tr></f:table>
<f:image l:href="#pixel"/><f:p>Text after the illustration.</f:p></f:section></f:body>
<f:body name="notes"><f:section id="note"><f:p>Note body.</f:p></f:section></f:body>
<f:binary id="pixel" content-type="image/png">{image}</f:binary></f:FictionBook>'''
PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR6kAAAAASUVORK5CYII='


def rich_epub(path):
    package = f'''<package xmlns="{conversion.OP}" xmlns:dc="{conversion.DC}" version="3.0">
      <metadata><dc:title>Reader fixture</dc:title><dc:creator>Sample Author</dc:creator></metadata>
      <manifest>
        <item id="first" href="one.xhtml" media-type="application/xhtml+xml"/>
        <item id="second" href="two.xhtml" media-type="application/xhtml+xml"/>
        <item id="notes" href="appendix/notes.xhtml" media-type="application/xhtml+xml"/>
        <item id="image" href="pixel.png" media-type="image/png"/>
        <item id="unsafe" href="unsafe.svg" media-type="image/svg+xml"/>
      </manifest>
      <spine><itemref idref="first"/><itemref idref="second"/></spine></package>'''
    chapters = {
        'one.xhtml': '''<h2>First chapter</h2>
          <p><strong>Bold</strong> and <em>italic</em>. &lt;literal&gt; *star* &amp;copy;</p>
          <p><a href="two.xhtml#next">Go to chapter two</a> <a epub:type="noteref" href="appendix/notes.xhtml#n1">1</a></p>
          <table><tr><th>Header A</th><th>Header B</th></tr><tr><td>Cell A</td><td>Cell B</td></tr></table>
          <ol start="3"><li>List item</li></ol><p>---</p>
          <p><img src="pixel.png" alt="First image"/></p>
          <p><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><title>Chart</title><rect width="8" height="8" fill="#369"/></svg>After chart.</p>
          <p><img src="unsafe.svg" alt="Blocked diagram"/><img src="https://example.invalid/a.png" alt="Outside image"/></p>
          <script>Unsafe source script</script>''',
        'two.xhtml': '''<h2 id="next">Second chapter</h2>
          <p><img src="pixel.png" alt="Same image"/> <a href="https://example.invalid/a(b)">Public link</a></p>''',
        'appendix/notes.xhtml': '''<aside id="n1"><p>Note body with its own image.</p>
          <p><img src="../pixel.png" alt="Note image"/></p></aside>''',
    }
    with zipfile.ZipFile(path, 'x') as archive:
        archive.writestr('mimetype', 'application/epub+zip')
        archive.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
        archive.writestr('OPS/book.opf', package)
        for name, body in chapters.items():
            archive.writestr('OPS/' + name, f'<html xmlns="{conversion.XH}" xmlns:epub="{conversion.EP}"><body>{body}</body></html>')
        archive.writestr('OPS/pixel.png', b64decode(PNG))
        archive.writestr('OPS/unsafe.svg', '<svg xmlns="http://www.w3.org/2000/svg"><script>bad</script></svg>')


class AdvancedOutputTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.work = Path(scratch.name)
        self.tools = self.work / 'tools'
        self.source = self.work / 'source.fb2'
        self.original = FB2.format(image=PNG).encode()
        self.source.write_bytes(self.original)

    def test_only_selected_writer_is_requested(self):
        epub = self.work / 'source.epub'
        conversion.convert_book(self.source, epub)
        office = self.work / 'document.docx'
        docx(office)
        for source, profile, component in [(self.source, 'epub2', 'FB2Export'), (epub, 'kepub', 'KoboExport'),
                                           (epub, 'pdf', 'EpubPdfExport'), (office, 'kepub', 'KoboExport'),
                                           (office, 'pdf', 'EpubPdfExport'), (self.source, 'kfx', 'FB2Export'),
                                           (epub, 'kfx', 'KfxExport'), (office, 'azw8', 'KfxExport')]:
            output = self.work / ('book' + advanced_output.OUTPUT_SUFFIXES[profile])
            with self.assertRaises(conversion.ComponentRequired) as failure:
                conversion.convert_book(source, output, output_profile=profile, tools_root=self.tools)
            self.assertEqual(failure.exception.component, component)
            self.assertFalse(output.exists())

    def test_epub_to_markdown_keeps_structure_links_and_local_images(self):
        epub = self.work / 'independent.epub'
        rich_epub(epub)
        original = epub.read_bytes()
        output = self.work / 'book.md'
        result = conversion.convert_book(epub, output, output_profile='md', tools_root=self.tools)
        text = output.read_text(encoding='utf-8')
        self.assertTrue(text.startswith('# Reader fixture\n\nSample Author\n'))
        self.assertLess(text.index('## First chapter'), text.index('## Second chapter'))
        self.assertIn(r'**Bold** and *italic*. \<literal\> \*star\* \&copy;', text)
        self.assertIn('| Header A | Header B |', text)
        self.assertIn('| Cell A | Cell B |', text)
        self.assertIn('3. List item', text)
        self.assertIn(r'\---', text)
        link = re.search(r'\[Go to chapter two\]\(#(hl-chapter-[\d-]+)\)', text)
        self.assertIsNotNone(link)
        self.assertIn(f'<a id="{link[1]}"></a>\n\n## Second chapter', text)
        self.assertEqual(text.count('Note body with its own image.'), 1)
        self.assertIn('[^note-1]: Note body', text)
        self.assertIn('![Note image][hl-image-1]', text)
        self.assertIn('![Same image][hl-image-1]', text)
        self.assertEqual(text.count(PNG), 1)
        svg = re.search(r'data:image/svg\+xml;base64,([^>]+)', text)
        self.assertIsNotNone(svg)
        chart = conversion.xml(b64decode(svg[1]))
        self.assertEqual(conversion.tag(chart[1]), 'rect')
        self.assertIn('After chart.', text)
        self.assertIn('Blocked diagram', text)
        self.assertIn('Outside image', text)
        self.assertNotIn('https://example.invalid/a.png', text)
        self.assertIn('[Public link](https://example.invalid/a%28b%29)', text)
        self.assertNotIn('Unsafe source script', text)
        self.assertTrue(any('шрифты' in item for item in result['warnings']))
        self.assertEqual(result['size'], output.stat().st_size)
        self.assertEqual(epub.read_bytes(), original)
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

    def test_docx_to_markdown_uses_local_writer_and_image_choice(self):
        source = self.work / 'document.docx'
        docx(source)
        original = source.read_bytes()
        with zipfile.ZipFile(source) as office:
            image = b64encode(office.read('word/media/p.png')).decode('ascii')
        for quality in ('original', 'none'):
            with self.subTest(quality=quality):
                output = self.work / (quality + '.md')
                conversion.convert_book(source, output, output_profile='md', image_quality=quality, tools_root=self.tools)
                text = output.read_text(encoding='utf-8')
                for fragment in ('Глава один', '| Ячейка |', '[^note-1]: Точная сноска'):
                    self.assertIn(fragment, text)
                self.assertEqual(image in text, quality == 'original')
                self.assertEqual('data:image/' in text, quality == 'original')
        self.assertEqual(source.read_bytes(), original)

    def test_markdown_cancel_during_writing_leaves_no_copy(self):
        source = self.work / 'cancel.epub'
        rich_epub(source)
        output = self.work / 'cancel.md'
        writing = False

        def progress(stage, done, total):
            nonlocal writing
            if stage == 'advanced-writing':
                writing = True

        def check():
            if writing:
                raise InterruptedError('cancel')

        with self.assertRaises(InterruptedError):
            conversion.convert_book(source, output, output_profile='md', tools_root=self.tools,
                                    progress=progress, cancel_check=check)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

    def test_missing_kfx_writer_and_existing_output_are_left_alone(self):
        epub = self.work / 'source.epub'
        conversion.convert_book(self.source, epub)
        output = self.work / 'copy.kfx'
        with self.assertRaises(conversion.ComponentRequired) as error:
            conversion.convert_book(epub, output, output_profile='kfx', tools_root=self.tools)
        self.assertEqual(error.exception.component, 'KfxExport')
        self.assertFalse(output.exists())
        output.write_bytes(b'keep this file')
        with self.assertRaises(conversion.ConversionError):
            conversion.convert_book(self.source, output, output_profile='kfx', tools_root=self.tools)
        self.assertEqual(output.read_bytes(), b'keep this file')

    def test_kindle_container_requires_bounded_descriptor_and_payload(self):
        descriptor = b'\xe0\x01\x00\xea'
        head = b'CONT\x02\x00' + struct.pack('<III', 22, 18, 4)
        for profile in ('kfx', 'azw8'):
            output = self.work / ('book.' + profile)
            output.write_bytes(head + descriptor + b'ENTY\x01\x00')
            advanced_output.validate_output(conversion, output, profile)
            for broken in (head[:16], head + descriptor, head + b'junkENTY',
                           head[:10] + struct.pack('<I', 0xffffffff) + head[14:] + descriptor + b'ENTY',
                           head + descriptor + b'junk'):
                with self.subTest(profile=profile, broken=broken):
                    output.write_bytes(broken)
                    with self.assertRaisesRegex(conversion.ConversionError, 'повреждённую книгу Kindle'):
                        advanced_output.validate_output(conversion, output, profile)

    def test_epub_pdf_server_only_serves_known_resources_with_private_prefix(self):
        epub = self.work / 'source.epub'
        conversion.convert_book(self.source, epub)
        viewer = self.work / 'viewer'
        viewer.mkdir()
        (viewer / 'vivliostyle.js').write_bytes(b'module.exports = {};')
        (viewer / 'private.txt').write_bytes(b'must not be served')
        with closing(conversion.EpubArchive(epub)) as archive:
            with epub_pdf_output.local_book(archive, viewer) as (origin, prefix):
                with urlopen(origin + prefix + 'viewer/host.js', timeout=2) as response:
                    self.assertIn(b'allowScripts: false', response.read())
                    self.assertIn('script-src ' + origin + prefix + 'viewer/',
                                  response.headers['Content-Security-Policy'])
                with urlopen(origin + prefix + 'book/META-INF/container.xml', timeout=2) as response:
                    self.assertIn("script-src 'none'", response.headers['Content-Security-Policy'])
                    self.assertEqual(response.read(), archive.read('META-INF/container.xml'))
                for path in ('/viewer/host.js', prefix + 'viewer/private.txt',
                             prefix + 'book/%2e%2e/viewer/host.js'):
                    with self.assertRaises(HTTPError) as error:
                        urlopen(origin + path, timeout=2)
                    self.assertEqual(error.exception.code, 404)
                    error.exception.close()

    def test_epub_pdf_browser_scratch_is_removed_with_profile(self):
        work = self.work / 'render'
        work.mkdir()
        with patch.object(epub_pdf_output.subprocess, 'Popen') as popen:
            def launch(*_args, env, **_kwargs):
                scratch = Path(env['TEMP'])
                self.assertEqual(env['TMP'], str(scratch))
                self.assertEqual(scratch.parent, work.parent)
                self.assertNotEqual(scratch, work)
                (scratch / 'browser-file.tmp').write_bytes(b'private browser data')
                (work / 'browser-profile').mkdir()
                process = popen.return_value
                process.poll.return_value = process.returncode = 0
                process.communicate.return_value = (None, b'')
                return process

            popen.side_effect = launch
            epub_pdf_output.render_pdf(conversion, self.work / 'renderer', work, 'url', 'prefix', lambda: None)
        self.assertFalse((work / 'browser-profile').exists())
        self.assertFalse(list(self.work.glob('w2-*')))

    @unittest.skipUnless(os.environ.get('HOMELIBRE_EPUB_PDF_TOOLS'), 'needs the packaged WebView2 writer and Runtime')
    def test_epub_pdf_preserves_text_and_leaves_no_runtime_profile(self):
        tools = Path(os.environ['HOMELIBRE_EPUB_PDF_TOOLS'])
        generated = self.work / 'generated.epub'
        conversion.convert_book(self.source, generated)
        epub = self.work / 'source.epub'
        # The source TOC must survive even when visible titles use plain paragraphs.
        with zipfile.ZipFile(generated) as source, zipfile.ZipFile(epub, 'x') as changed:
            for member in source.infolist():
                data = source.read(member)
                if member.filename == 'OEBPS/body-1.xhtml':
                    self.assertIn(b'<html:h2 ', data)
                    data = data.replace(b'<html:h2 ', b'<html:p ').replace(b'</html:h2>', b'</html:p>')
                changed.writestr(member, data)
        original = epub.read_bytes()
        # Exercise a temporary path long enough to reproduce WebView2 startup
        # failures when its scratch directory is nested under the browser profile.
        work = self.work / ('pdf-' + 'x' * max(0, 168 - len(str(self.work / 'pdf-'))))
        work.mkdir()
        output = work / 'book.pdf'
        with patch.dict(os.environ, {
            'WEBVIEW2_BROWSER_EXECUTABLE_FOLDER': str(self.work / 'missing-browser'),
            'WEBVIEW2_USER_DATA_FOLDER': str(self.work / 'outside-profile'),
        }):
            result = conversion.convert_book(epub, output, output_profile='pdf', tools_root=tools)
        from pypdf import PdfReader
        pdf = PdfReader(output)
        text = ' '.join(page.extract_text() for page in pdf.pages)
        self.assertIn('Text before the illustration.', text)
        self.assertIn('Test table', text)
        self.assertIn('Note body.', text)
        self.assertEqual(pdf.metadata.title, 'Export fixture')
        bookmark = next(entry for entry in pdf.outline if entry.title == 'First chapter')
        self.assertIn('Text before the illustration.', pdf.pages[pdf.get_destination_page_number(bookmark)].extract_text())
        self.assertEqual(output.stat().st_size, result['size'])
        self.assertEqual(epub.read_bytes(), original)
        self.assertFalse((self.work / 'outside-profile').exists())
        self.assertEqual(list(work.iterdir()), [output])

    @unittest.skipUnless(os.environ.get('HOMELIBRE_ADVANCED_WRITERS'), 'needs pinned installed writers')
    def test_real_writers_preserve_content_and_use_separate_modules(self):
        tools = Path(os.environ['HOMELIBRE_ADVANCED_WRITERS'])
        for profile, suffix in advanced_output.OUTPUT_SUFFIXES.items():
            with self.subTest(profile=profile):
                output = self.work / (profile + suffix)
                result = conversion.convert_book(self.source, output, output_profile=profile, tools_root=tools)
                self.assertEqual(result['size'], output.stat().st_size)
        epub = self.work / 'epub3.epub'
        kobo = self.work / 'direct.kepub.epub'
        conversion.convert_book(epub, kobo, output_profile='kepub', tools_root=tools)
        with zipfile.ZipFile(epub) as before, zipfile.ZipFile(kobo) as after:
            for name in before.namelist():
                if name.endswith(('.css', '.png', '.jpg', '.svg', '.ttf')):
                    self.assertEqual(before.read(name), after.read(name), name)
            chapters = b' '.join(after.read(n) for n in after.namelist() if n.endswith('.xhtml'))
            for text in (b'koboSpan', b'Test table', b'Note body.', b'Text after the illustration.'):
                self.assertIn(text, chapters)
        stripped = self.work / 'stripped.epub'
        conversion.convert_book(self.source, stripped, output_profile='epub3', image_quality='none', tools_root=tools)
        with zipfile.ZipFile(stripped) as archive:
            chapters = b' '.join(archive.read(n) for n in archive.namelist() if n.endswith('.xhtml'))
            self.assertIn(b'Text after the illustration.', chapters)
            self.assertFalse(any(n.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.svg')) for n in archive.namelist()))
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

    @unittest.skipUnless(os.environ.get('HOMELIBRE_ADVANCED_WRITERS') and os.environ.get('HOMELIBRE_EPUB_PDF_TOOLS'),
                         'needs the packaged Kobo and WebView2 writers')
    def test_docx_uses_epub_preparation_preserving_notes_tables_and_image(self):
        tools = Path(os.environ['HOMELIBRE_ADVANCED_WRITERS'])
        source = self.work / 'document.docx'
        docx(source)
        original = source.read_bytes()
        kobo = self.work / 'document.kepub.epub'
        conversion.convert_book(source, kobo, output_profile='kepub', tools_root=tools)
        with zipfile.ZipFile(source) as office, zipfile.ZipFile(kobo) as converted:
            image = office.read('word/media/p.png')
            self.assertTrue(any(converted.read(name) == image for name in converted.namelist() if name.endswith('.png')))
            content = b' '.join(converted.read(name) for name in converted.namelist() if name.endswith('.xhtml'))
            for fragment in ('Глава один', 'Ячейка', 'Точная сноска'):
                self.assertIn(fragment.encode(), content)
            self.assertIn(b'koboSpan', content)
        output = self.work / 'document.pdf'
        conversion.convert_book(source, output, output_profile='pdf', tools_root=tools)
        from pypdf import PdfReader
        document = PdfReader(output)
        content = ' '.join(page.extract_text() for page in document.pages)
        for fragment in ('Глава один', 'Ячейка', 'Точная сноска'):
            self.assertIn(fragment, content)
        self.assertTrue(any(page.images for page in document.pages))
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

    def test_cancel_running_writer_terminates_child(self):
        process = None
        start = advanced_output.subprocess.Popen

        def capture(*args, **kwargs):
            nonlocal process
            process = start(*args, **kwargs)
            return process

        def cancel():
            raise InterruptedError('cancel')

        with patch.object(advanced_output.subprocess, 'Popen', side_effect=capture):
            with self.assertRaises(InterruptedError):
                advanced_output.run_writer(conversion, [sys.executable, '-c', 'import time; time.sleep(60)'],
                                           self.work, cancel)
        self.assertIsNotNone(process)
        self.assertIsNotNone(process.poll())


if __name__ == '__main__':
    unittest.main()

from contextlib import closing
import os
from pathlib import Path
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
        for source, profile, component in [(self.source, 'epub2', 'FB2Export'), (epub, 'kepub', 'KoboExport'),
                                           (epub, 'pdf', 'EpubPdfExport')]:
            output = self.work / ('book' + advanced_output.OUTPUT_SUFFIXES[profile])
            with self.assertRaises(conversion.ComponentRequired) as failure:
                conversion.convert_book(source, output, output_profile=profile, tools_root=self.tools)
            self.assertEqual(failure.exception.component, component)
            self.assertFalse(output.exists())

    def test_unsupported_route_and_existing_output_are_left_alone(self):
        epub = self.work / 'source.epub'
        conversion.convert_book(self.source, epub)
        output = self.work / 'copy.kfx'
        with self.assertRaises(conversion.ConversionError):
            conversion.convert_book(epub, output, output_profile='kfx', tools_root=self.tools)
        self.assertFalse(output.exists())
        output.write_bytes(b'keep this file')
        with self.assertRaises(conversion.ConversionError):
            conversion.convert_book(self.source, output, output_profile='kfx', tools_root=self.tools)
        self.assertEqual(output.read_bytes(), b'keep this file')

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

    @unittest.skipUnless(os.environ.get('HOMELIBRE_EPUB_PDF_TOOLS'), 'needs the packaged WebView2 writer and Runtime')
    def test_epub_pdf_preserves_text_and_leaves_no_runtime_profile(self):
        tools = Path(os.environ['HOMELIBRE_EPUB_PDF_TOOLS'])
        epub = self.work / 'source.epub'
        conversion.convert_book(self.source, epub)
        original = epub.read_bytes()
        output = self.work / 'book.pdf'
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
        self.assertEqual(output.stat().st_size, result['size'])
        self.assertEqual(epub.read_bytes(), original)
        self.assertFalse((self.work / 'outside-profile').exists())
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

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

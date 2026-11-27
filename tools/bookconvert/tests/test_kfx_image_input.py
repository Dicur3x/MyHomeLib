"""Safety and archive integrity for EPUB SVG preparation."""

from base64 import b64decode
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import zipfile

from test_epub3_output import conversion, legacy_epub, PNG
from test_conversion import PNG as VALID_PNG
from kfx_image_input import prepare


def subtitled_epub(base, output):
    chapter = ('<p>Before clip <video poster="../cover.png" src="../film.mp4">'
               '<track src="../captions.vtt" label="English"/><track src="../repair.vtt" srclang="ru"/>'
               '<track src="https://example.invalid/captions.vtt"/><em>Authored fallback.</em></video> After clip.</p>')
    tracks = ('<item id="captions" href="captions.vtt" media-type="text/vtt"/>'
              '<item id="repair" href="repair.vtt" media-type="text/vtt"/>')
    cues = ('WEBVTT\r\n\r\nNOTE invisible editor note\r\n\r\nSTYLE\r\n::cue { color: yellow }\r\n\r\n'
            'first-id\r\n00:01.200 --> 00:04.300 align:start\r\n<v Host><i>First line\r\nnext line</i></v>\r\n\r\n'
            '00:07.500 --> 00:10.000\r\n<b>Second</b> <00:08.000>&amp; &lt;tag&gt; <ruby>字<rt>zi</rt></ruby>\r\n')
    with zipfile.ZipFile(base) as archive, zipfile.ZipFile(output, 'x') as result:
        for entry in archive.infolist():
            data = archive.read(entry)
            if entry.filename == 'OPS/text/chapter.xhtml':
                data = data.replace(b'</body>', chapter.encode('utf-8') + b'</body>')
            elif entry.filename == 'OPS/book.opf':
                data = data.replace(b'</manifest>', tracks.encode('utf-8') + b'</manifest>')
            elif entry.filename == 'OPS/cover.png':
                data = VALID_PNG
            result.writestr(entry, data)
        result.writestr('OPS/captions.vtt', cues.encode('utf-8-sig'))
        result.writestr('OPS/repair.vtt', 'WEBVTT\n\n00:bad --> 00:11.000\nЧитаемая реплика.\n'.encode('utf-8'))


class KfxImageInputTest(unittest.TestCase):
    def test_static_gif_decoder_remaps_images_without_changing_source(self):
        gif = b64decode('R0lGODdhAQABAIAAAP8AAP///ywAAAAAAQABAAACAkQBADs=')
        with zipfile.ZipFile(self.base) as archive, zipfile.ZipFile(self.source, 'x') as result:
            for entry in archive.infolist():
                data = archive.read(entry)
                if entry.filename == 'OPS/cover.png':
                    entry.filename = 'OPS/picture.gif'
                    data = gif
                elif entry.filename == 'OPS/book.opf':
                    data = data.replace(b'cover.png', b'picture.gif').replace(b'image/png', b'image/gif')
                elif entry.filename == 'OPS/text/chapter.xhtml':
                    data = data.replace(b'cover.png', b'picture.gif')
                result.writestr(entry, data)
        original = self.source.read_bytes()
        with self.assertRaises(conversion.ComponentRequired) as missing:
            prepare(conversion, self.source, self.output, lambda *_: self.fail('No SVG'))
        self.assertEqual(missing.exception.component, 'ImageProcessing')
        self.assertFalse(self.output.exists())
        def decode(data):
            self.assertEqual(data, gif)
            return b64decode(PNG)
        self.assertEqual(prepare(conversion, self.source, self.output, lambda *_: self.fail('No SVG'), decode_gif=decode), 1)
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn('OPS/picture.gif', archive.namelist())
            root = conversion.xhtml(archive.read('OPS/text/chapter.xhtml'))
            image = next(node for node in root.iter() if conversion.tag(node) == 'img')
            path, _ = conversion.EpubArchive.resolve(None, 'OPS/text/chapter.xhtml', image.get('src'))
            self.assertEqual(archive.read(path), b64decode(PNG))
            package = conversion.xml(archive.read('OPS/book.opf'))
            self.assertFalse(any(item.get('media-type') == 'image/gif' for item in package.iter()))
        self.assertEqual(self.source.read_bytes(), original)

    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.base = self.root / 'base.epub'
        self.source = self.root / 'source.epub'
        self.output = self.root / 'prepared.epub'
        legacy_epub(self.base)

    def with_vector(self, vector, signed=False):
        with zipfile.ZipFile(self.base) as archive, zipfile.ZipFile(self.source, 'x') as result:
            for entry in archive.infolist():
                data = archive.read(entry)
                if entry.filename == 'OPS/text/chapter.xhtml':
                    data = data.replace(b'</body>', vector + b'After the drawing.</body>')
                result.writestr(entry, data)
            if signed:
                result.writestr('META-INF/signatures.xml', b'<signatures/>')

    def test_wrapper_only_reads_epub_resources_and_preserves_adjacent_text(self):
        self.with_vector(b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
                         b'<title>Diagram</title><image href="../cover.png" width="1" height="1"/></svg>')
        original = self.source.read_bytes()
        calls = []

        def render(svg):
            calls.append(svg)
            return b64decode(PNG)

        self.assertEqual(prepare(conversion, self.source, self.output, render), 1)
        self.assertEqual(len(calls), 1)
        self.assertIn(b'data:image/png;base64,', calls[0])
        self.assertEqual(self.source.read_bytes(), original)
        with zipfile.ZipFile(self.output) as archive:
            self.assertIn(b'After the drawing.', archive.read('OPS/text/chapter.xhtml'))
            self.assertIn(b'alt="Diagram"', archive.read('OPS/text/chapter.xhtml'))
            self.assertEqual(archive.read('OPS/cover.png'), b64decode(PNG))

    def test_external_files_and_signed_packages_are_rejected_before_rendering(self):
        for label, image, signed in (
                ('external', b'<image href="file:///C:/Windows/win.ini"/>', False),
                ('remote', b'<image href="https://example.invalid/diagram.png"/>', False),
                ('outside', b'<image href="../../../secret.png"/>', False),
                ('signed', b'<rect width="1" height="1"/>', True)):
            with self.subTest(label=label):
                self.source = self.root / (label + '.epub')
                self.with_vector(b'<svg xmlns="http://www.w3.org/2000/svg">' + image + b'</svg>', signed)
                original = self.source.read_bytes()
                with self.assertRaises(conversion.ConversionError):
                    prepare(conversion, self.source, self.output,
                            lambda *_: self.fail('Rejected vectors must never reach the renderer.'))
                self.assertFalse(self.output.exists())
                self.assertEqual(self.source.read_bytes(), original)

    def test_no_vector_does_not_make_a_copy_or_start_renderer(self):
        self.assertEqual(prepare(conversion, self.base, self.output,
                                 lambda *_: self.fail('No SVG needs rendering.')), 0)
        self.assertFalse(self.output.exists())

    def test_media_without_new_images_preserves_the_authored_poster_and_fallback(self):
        self.with_vector(b'<p><video id="clip" poster="../cover.png" width="80" aria-label="Original cover">'
                         b'<source id="video-source" src="../film.mp4"/>'
                         b'<track src="../captions.vtt"/><em>Fallback text</em> and its tail.</video></p>'
                         b'<p><audio id="track" src="../music.mp3"/></p>'
                         b'<p><a href="#clip">Go to poster</a></p>')
        original = self.source.read_bytes()
        warnings = set()
        self.assertEqual(prepare(conversion, self.source, self.output,
                                 lambda *_: self.fail('The original PNG needs no rendering.'), warnings=warnings), 0)
        self.assertTrue(self.output.is_file())
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read('OPS/cover.png'), b64decode(PNG))
            root = conversion.xhtml(archive.read('OPS/text/chapter.xhtml'))
        ids = {node.get('id'): node for node in root.iter() if node.get('id')}
        poster, = conversion.children(ids['clip'], 'img')
        self.assertEqual((poster.get('src'), poster.get('width'), poster.get('alt')),
                         ('../cover.png', '80', 'Original cover'))
        self.assertEqual(conversion.plain(ids['clip']), 'Fallback text and its tail.')
        self.assertEqual(conversion.plain(conversion.first(ids['clip'], 'em')), 'Fallback text')
        self.assertEqual(conversion.plain(ids['track']), '[Аудио «music.mp3» доступно в исходном EPUB.]')
        self.assertIn('video-source', ids)
        self.assertTrue(any(node.get('href') == '#clip' for node in root.iter()))
        self.assertFalse(any(conversion.tag(node) in {'video', 'audio', 'source', 'track'} for node in root.iter()))
        notices = conversion.damaged_content_warnings(warnings)
        self.assertEqual(len(notices), 3)
        self.assertTrue(any('показано статично: «film.mp4»' in notice for notice in notices))
        self.assertTrue(any('«../captions.vtt»' in notice for notice in notices))
        self.assertEqual(self.source.read_bytes(), original)

    def test_multimedia_subtitles_remain_readable_in_static_exports(self):
        import markdown_output

        subtitled_epub(self.base, self.source)
        original = self.source.read_bytes()
        warnings = set()
        prepare(conversion, self.source, self.output, lambda *_: self.fail('Original PNG needs no rendering.'),
                warnings=warnings)
        with zipfile.ZipFile(self.output) as archive:
            prepared = conversion.xhtml(archive.read('OPS/text/chapter.xhtml'))
            self.assertEqual(archive.read('OPS/cover.png'), VALID_PNG)
        fb2 = self.root / 'subtitles.fb2'
        result = conversion.convert_book(self.source, fb2, allow_partial_epub=True)
        book = conversion.xml(fb2.read_bytes())
        self.assertIn(VALID_PNG, [b64decode(node.text) for node in conversion.children(book, 'binary')])
        markdown = self.root / 'subtitles.md'
        markdown_warnings = set()
        markdown_output.convert(conversion, self.source, markdown, markdown_warnings, None)
        for body in (conversion.plain(prepared), conversion.plain(conversion.first(book, 'body')),
                     markdown.read_text(encoding='utf-8')):
            for expected in ('Authored fallback.', 'Субтитры — English', '00:01.200 — 00:04.300',
                             'Host —', 'First line', 'next line', '00:07.500 — 00:10.000',
                             'Second', '字 (zi)', 'Читаемая реплика.', 'After clip.'):
                self.assertIn(expected, body)
            for omitted in ('first-id', 'invisible editor note', '::cue', '00:08.000'):
                self.assertNotIn(omitted, body)
            self.assertLess(body.index('First line'), body.index('next line'))
            self.assertLess(body.index('next line'), body.index('Читаемая реплика.'))
        self.assertEqual([conversion.plain(node) for node in prepared.iter() if conversion.tag(node) == 'em'],
                         ['Authored fallback.', 'First line', 'next line'])
        self.assertTrue({'Authored fallback.', 'First line', 'next line'} <=
                        {conversion.plain(node) for node in book.iter() if conversion.tag(node) == 'emphasis'})
        self.assertTrue(any('<tag>' in conversion.plain(node) for node in prepared.iter()))
        self.assertFalse(any(conversion.tag(node) == 'tag' for node in prepared.iter()))
        for messages in (warnings, result['warnings'], markdown_warnings):
            notices = conversion.damaged_content_warnings(messages)
            self.assertTrue(any('Субтитры EPUB восстановлены частично' in notice for notice in notices))
            self.assertTrue(any('example.invalid' in notice for notice in notices))
            self.assertFalse(any('Субтитры EPUB сохранены отдельным текстом' in notice for notice in notices))
        self.assertEqual(self.source.read_bytes(), original)

    def test_webp_requests_its_decoder_and_remaps_the_existing_resource(self):
        webp = b64decode('UklGRh4AAABXRUJQVlA4TBEAAAAvAQAAEAdQqEYUuYaBiOh/AAA=')
        with zipfile.ZipFile(self.base) as archive, zipfile.ZipFile(self.source, 'x') as result:
            for entry in archive.infolist():
                data = archive.read(entry)
                if entry.filename == 'OPS/cover.png':
                    entry.filename = 'OPS/cover.webp'
                    data = webp
                elif entry.filename == 'OPS/book.opf':
                    data = data.replace(b'cover.png', b'cover.webp').replace(b'image/png', b'image/webp')
                elif entry.filename == 'OPS/text/chapter.xhtml':
                    data = data.replace(b'cover.png', b'cover.webp')
                result.writestr(entry, data)
        original = self.source.read_bytes()
        def no_svg(*_):
            self.fail('WebP must use the WebP decoder.')
        with self.assertRaises(conversion.ComponentRequired) as error:
            prepare(conversion, self.source, self.output, no_svg)
        self.assertEqual(error.exception.component, 'WebP')
        self.assertFalse(self.output.exists())
        def decode(data):
            self.assertEqual(data, webp)
            return b64decode(PNG)
        self.assertEqual(prepare(conversion, self.source, self.output, no_svg, decode_webp=decode), 1)
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn('OPS/cover.webp', archive.namelist())
            chapter = conversion.xhtml(archive.read('OPS/text/chapter.xhtml'))
            image = next(node for node in chapter.iter() if conversion.tag(node) == 'img')
            self.assertEqual(archive.read('OPS/' + image.get('src').removeprefix('../')), b64decode(PNG))
        self.assertEqual(self.source.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()

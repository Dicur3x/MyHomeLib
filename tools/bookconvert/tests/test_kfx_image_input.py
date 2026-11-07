"""Safety and archive integrity for EPUB SVG preparation."""

from base64 import b64decode
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import zipfile

from test_epub3_output import conversion, legacy_epub, PNG
from kfx_image_input import prepare


class KfxImageInputTest(unittest.TestCase):
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

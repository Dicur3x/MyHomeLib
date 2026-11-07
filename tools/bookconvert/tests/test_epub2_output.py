"""Regression for explicit EPUB 2 export without a lossy FB2 intermediate."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import zipfile

from test_epub3_output import conversion, docx, legacy_epub


class Epub2OutputTest(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.original = self.root / 'original.epub'
        self.source = self.root / 'source.epub'
        self.output = self.root / 'output.epub'
        legacy_epub(self.original)
        conversion.convert_book(self.original, self.source, output_profile='epub3')

    def test_nested_navigation_assets_and_note_links(self):
        original = self.source.read_bytes()
        conversion.convert_book(self.source, self.output, output_profile='epub2')
        self.assertEqual(conversion.validate_epub_output(self.output), {'2'})
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as output:
            self.assertEqual(output.infolist()[0].compress_type, zipfile.ZIP_STORED)
            for member in ('OPS/text/chapter.xhtml', 'OPS/text/note.xhtml', 'OPS/book.css', 'OPS/cover.png'):
                self.assertEqual(source.read(member), output.read(member), member)
            opf = conversion.xml(output.read('OPS/book.opf'))
            spine = conversion.first(opf, 'spine')
            item = next(item for item in conversion.first(opf, 'manifest') if item.get('id') == spine.get('toc'))
            self.assertEqual(item.get('href'), 'nav/legacy.ncx')
            ncx = conversion.xml(output.read('OPS/nav/legacy.ncx'))
            points = list(ncx.iter('{http://www.daisy.org/z3986/2005/ncx/}navPoint'))
            self.assertIn(points[1], list(points[0]))
            self.assertEqual([conversion.first(point, 'content').get('src') for point in points],
                             ['../text/chapter.xhtml#chapter', '../text/note.xhtml#note'])
            self.assertEqual(len(conversion.first(ncx, 'pageList')), 1)
            creator = conversion.first(conversion.first(opf, 'metadata'), 'creator')
            self.assertEqual(creator.get('{' + conversion.OP + '}role'), 'aut')
        self.assertEqual(self.source.read_bytes(), original)

    def test_existing_epub2_is_copied_unchanged(self):
        conversion.convert_book(self.original, self.output, output_profile='epub2')
        self.assertEqual(self.original.read_bytes(), self.output.read_bytes())

    def test_docx_creates_ncx_and_keeps_links_notes_and_illustration(self):
        word = self.root / 'test.docx'
        docx(word)
        report = conversion.convert_book(word, self.output, output_profile='epub2', tools_root=self.root / 'no-writers')
        with zipfile.ZipFile(self.output) as archive:
            ncx, = [name for name in archive.namelist() if name.endswith('.ncx')]
            self.assertIn('Глава один'.encode(), archive.read(ncx))
            chapters = archive.read('OEBPS/book.xhtml')
            self.assertIn('Точная сноска'.encode(), chapters)
            self.assertIn(b'href="#', chapters)
            self.assertTrue(any(name.endswith('.png') for name in archive.namelist()))
        self.assertEqual(conversion.validate_epub_output(self.output), {'2'})
        self.assertTrue(any('метки EPUB 3' in warning for warning in report['warnings']))

    def test_fixed_layout_and_active_chapters_fail_before_output(self):
        layout = conversion.element(conversion.OP, 'meta', 'pre-paginated', property='rendition:layout')
        video = conversion.element(conversion.XH, 'video')
        isolated_direction = conversion.element(conversion.XH, 'bdi', 'Direction-sensitive text')
        for member, parent, extra, expected in (
                ('OPS/book.opf', 'metadata', layout, 'Фиксированную'),
                ('OPS/text/chapter.xhtml', 'body', video, 'video'),
                ('OPS/text/note.xhtml', 'body', isolated_direction, 'bdi')):
            with self.subTest(member=member):
                candidate = self.root / (Path(member).stem + '.epub')
                with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(candidate, 'x') as output:
                    for item in source.infolist():
                        data = source.read(item)
                        if item.filename == member:
                            document = conversion.xml(data)
                            conversion.first(document, parent).append(extra)
                            data = conversion.serialized(document)
                        output.writestr(item, data)
                original = candidate.read_bytes()
                with self.assertRaisesRegex(conversion.ConversionError, expected):
                    conversion.convert_book(candidate, self.output, output_profile='epub2')
                self.assertFalse(self.output.exists())
                self.assertEqual(candidate.read_bytes(), original)
                self.assertFalse(list(self.root.glob('homelibre-advanced-*')))

    def test_html5_strike_retains_visible_text_and_style(self):
        candidate = self.root / 'strike.epub'
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(candidate, 'x') as output:
            for item in source.infolist():
                data = source.read(item)
                if item.filename == 'OPS/text/chapter.xhtml':
                    document = conversion.xml(data)
                    paragraph = conversion.element(conversion.XH, 'p')
                    paragraph.append(conversion.element(conversion.XH, 's', 'Old amount', style='color:red'))
                    conversion.first(document, 'body').append(paragraph)
                    data = conversion.serialized(document)
                output.writestr(item, data)
        conversion.convert_book(candidate, self.output, output_profile='epub2')
        with zipfile.ZipFile(self.output) as output:
            document = conversion.xhtml(output.read('OPS/text/chapter.xhtml'))
            strike = next(node for node in document.iter() if node.text == 'Old amount')
            self.assertEqual(conversion.tag(strike), 'span')
            self.assertEqual(strike.get('style'), 'color:red;text-decoration:line-through')

    def test_cancel_preserves_source_and_cleans_staging(self):
        original = self.source.read_bytes()
        writing = False

        def progress(stage, done, total):
            nonlocal writing
            writing |= stage == 'advanced-writing'

        def check():
            if writing:
                raise InterruptedError('cancelled')

        with self.assertRaises(InterruptedError):
            conversion.convert_book(self.source, self.output, output_profile='epub2', progress=progress, cancel_check=check)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), original)
        self.assertFalse(list(self.root.glob('homelibre-advanced-*')))

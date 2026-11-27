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

    def test_epub2_keeps_a_series_and_its_fractional_position(self):
        candidate = self.root / 'series.epub'
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(candidate, 'x') as output:
            for item in source.infolist():
                data = source.read(item)
                if item.filename == 'OPS/book.opf':
                    package = conversion.xml(data)
                    metadata = conversion.first(package, 'metadata')
                    metadata.extend((
                        conversion.element(conversion.OP, 'meta', 'Новая серия',
                                           property='belongs-to-collection', id='series'),
                        conversion.element(conversion.OP, 'meta', 'series', property='collection-type', refines='#series'),
                        conversion.element(conversion.OP, 'meta', '2.4', property='group-position', refines='#series'),
                    ))
                    data = conversion.serialized(package)
                output.writestr(item, data)
        original = candidate.read_bytes()
        report = conversion.convert_book(candidate, self.output, output_profile='epub2')
        with zipfile.ZipFile(candidate) as source, zipfile.ZipFile(self.output) as output:
            package = conversion.xml(output.read('OPS/book.opf'))
            metadata = conversion.first(package, 'metadata')
            self.assertEqual(conversion.epub_custom_metadata(metadata, 'calibre:series'), 'Новая серия')
            self.assertEqual(conversion.epub_custom_metadata(metadata, 'calibre:series_index'), '2.4')
            for path in ('OPS/text/chapter.xhtml', 'OPS/text/note.xhtml', 'OPS/book.css', 'OPS/cover.png'):
                self.assertEqual(source.read(path), output.read(path))
        self.assertFalse(any('дополнительных сведений' in warning for warning in report['warnings']))
        self.assertEqual(candidate.read_bytes(), original)

    def test_onix_isbn_remains_an_isbn_in_epub2_and_fb2(self):
        candidate = self.root / 'publication.epub'
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(candidate, 'x') as output:
            for item in source.infolist():
                data = source.read(item)
                if item.filename == 'OPS/book.opf':
                    package = conversion.xml(data)
                    metadata = conversion.first(package, 'metadata')
                    metadata.append(conversion.element(conversion.DC, 'identifier', '9780306406157', id='edition'))
                    metadata.append(conversion.element(conversion.OP, 'meta', '15', property='identifier-type',
                                                       refines='#edition', scheme='onix:codelist5'))
                    data = conversion.serialized(package)
                output.writestr(item, data)
        conversion.convert_book(candidate, self.output, output_profile='epub2')
        with zipfile.ZipFile(self.output) as archive:
            package = conversion.xml(archive.read('OPS/book.opf'))
            identifier = next(n for n in conversion.first(package, 'metadata') if n.get('id') == 'edition')
            self.assertEqual(identifier.get('{' + conversion.OP + '}scheme'), 'ISBN')
        fb2 = self.root / 'publication.fb2'
        conversion.convert_book(self.output, fb2)
        description = conversion.first(conversion.xml(fb2.read_bytes()), 'description')
        self.assertEqual(conversion.plain(conversion.first(conversion.first(description, 'publish-info'), 'isbn')),
                         '9780306406157')

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

    def test_local_media_becomes_static_with_original_assets_and_fallback(self):
        candidate = self.root / 'media.epub'
        assets = {'clip.mp4': ('video/mp4', b'test video record'),
                  'speech.mp3': ('audio/mpeg', b'test audio record'),
                  'captions.vtt': ('text/vtt', b'WEBVTT\n')}
        media = f'''<div xmlns="{conversion.XH}"><video id="film" poster="../cover.png" width="200">
              <source src="../clip.mp4#t=2"/>Fallback prose after the source.
              <track id="captions" src="../captions.vtt" label="Russian"/>
              <p><em>Published description.</em></p></video>
              <audio src="../speech.mp3" title="Published audio"/></div>'''
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(candidate, 'x') as output:
            for item in source.infolist():
                data = source.read(item)
                if item.filename == 'OPS/book.opf':
                    package = conversion.xml(data)
                    manifest = conversion.first(package, 'manifest')
                    for name, (mimetype, _) in assets.items():
                        manifest.append(conversion.element(conversion.OP, 'item', id=name, href=name,
                                                           **{'media-type': mimetype}))
                    data = conversion.serialized(package)
                elif item.filename == 'OPS/text/chapter.xhtml':
                    document = conversion.xml(data)
                    conversion.first(document, 'body').append(conversion.xml(media.encode()))
                    data = conversion.serialized(document)
                output.writestr(item, data)
            for name, (_, data) in assets.items():
                output.writestr('OPS/' + name, data)
        original = candidate.read_bytes()
        report = conversion.convert_book(candidate, self.output, output_profile='epub2')
        with zipfile.ZipFile(candidate) as source, zipfile.ZipFile(self.output) as output:
            for name in (*assets, 'cover.png', 'book.css', 'text/note.xhtml'):
                self.assertEqual(source.read('OPS/' + name), output.read('OPS/' + name))
            package = conversion.xml(output.read('OPS/book.opf'))
            manifest = {item.get('id'): item for item in conversion.first(package, 'manifest')}
            for name, expected_href in [('clip.mp4', 'cover.png'), ('captions.vtt', 'cover.png'),
                                        ('speech.mp3', 'text/chapter.xhtml')]:
                self.assertEqual(manifest[manifest[name].get('fallback')].get('href'), expected_href)
            chapter = conversion.xml(output.read('OPS/text/chapter.xhtml'))
            film = next(node for node in chapter.iter() if node.get('id') == 'film')
            self.assertEqual(next(film.iter('{' + conversion.XH + '}img')).get('width'), '200')
            self.assertEqual([(item.get('data'), item.get('title')) for item in film.iter('{' + conversion.XH + '}object')],
                             [('../clip.mp4#t=2', 'clip.mp4'), ('../captions.vtt', 'Russian (captions.vtt)')])
            self.assertTrue(any(node.get('id') == 'captions' for node in film.iter()))
            self.assertIn('Fallback prose after the source.', conversion.plain(film))
            self.assertEqual(conversion.plain(next(film.iter('{' + conversion.XH + '}em'))), 'Published description.')
            self.assertFalse(any(conversion.tag(n) in {'video', 'audio', 'track', 'source'} for n in chapter.iter()))
        warnings = conversion.damaged_content_warnings(report['warnings'])
        self.assertTrue(all(any(name in warning for warning in warnings) for name in assets))
        self.assertEqual(candidate.read_bytes(), original)

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
                with self.assertRaisesRegex(conversion.ConversionError, expected + '.*Выберите EPUB 3'):
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

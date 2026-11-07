"""Regression for explicit EPUB 3 export with the original reading resources."""
from base64 import b64decode
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import zipfile

from test_advanced_output import conversion, PNG, docx


def legacy_epub(path, font=None):
    package = f'''<package xmlns="{conversion.OP}" xmlns:opf="{conversion.OP}" xmlns:dc="{conversion.DC}"
          version="2.0" unique-identifier="book">
        <metadata><dc:identifier id="book">urn:uuid:70d62b4b-8a32-4261-bfe0-c77d7797ba18</dc:identifier>
          <dc:title>Legacy book</dc:title><dc:language>en</dc:language>
          <dc:creator opf:role="aut" opf:file-as="Author, Sample">Sample Author</dc:creator>
          <meta name="cover" content="cover"/></metadata>
        <manifest>
          <item id="toc" href="nav/legacy.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
          <item id="note" href="text/note.xhtml" media-type="application/xhtml+xml"/>
          <item id="cover" href="cover.png" media-type="image/png"/>
          <item id="css" href="book.css" media-type="text/css"/>
          {'<item id="font" href="book.ttf" media-type="application/vnd.ms-opentype"/>' if font else ''}
        </manifest><spine toc="toc"><itemref idref="chapter"/><itemref idref="note"/></spine>
      </package>'''
    ncx = '''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="urn:uuid:70d62b4b-8a32-4261-bfe0-c77d7797ba18"/>
      <meta name="dtb:depth" content="2"/><meta name="dtb:totalPageCount" content="1"/>
      <meta name="dtb:maxPageNumber" content="1"/></head><docTitle><text>Legacy book</text></docTitle>
      <navMap><navPoint id="first" playOrder="1"><navLabel><text>Chapter one</text></navLabel>
      <content src="../text/chapter.xhtml#chapter"/>
      <navPoint id="child" playOrder="2"><navLabel><text>Note</text></navLabel>
      <content src="../text/note.xhtml#note"/></navPoint></navPoint></navMap>
      <pageList><pageTarget id="p1" value="1" type="normal" playOrder="1"><navLabel><text>1</text></navLabel>
      <content src="../text/chapter.xhtml#chapter"/></pageTarget></pageList></ncx>'''
    chapters = {
        'chapter': '''<h1 id="chapter">Chapter one</h1><p><a href="note.xhtml#note">Note</a></p>
          <table><tr><th>Header</th></tr><tr><td>Cell</td></tr></table>
          <p><img src="../cover.png" alt="Image"/></p>''',
        'note': '<h1 id="note">Note text</h1><p><a href="chapter.xhtml#chapter">Back</a></p>',
    }
    with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', f'''<container xmlns="{conversion.CN}" version="1.0">
            <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>
            </rootfiles></container>''')
        archive.writestr('OPS/book.opf', package)
        archive.writestr('OPS/nav/legacy.ncx', ncx)
        for name, body in chapters.items():
            archive.writestr('OPS/text/' + name + '.xhtml',
                             f'<html xmlns="{conversion.XH}" xml:lang="en"><head><title>{name}</title>'
                             '<link rel="stylesheet" type="text/css" href="../book.css"/></head>'
                             f'<body>{body}</body></html>')
        css = "td { color: #039; }"
        if font:
            archive.writestr('OPS/book.ttf', font)
            css += " @font-face {font-family: Book;src:url(book.ttf);} body{font-family: Book;}"
        archive.writestr('OPS/book.css', css)
        archive.writestr('OPS/cover.png', b64decode(PNG))


class Epub3OutputTest(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.work = Path(scratch.name)
        self.source = self.work / 'legacy.epub'
        self.output = self.work / 'out.epub'
        legacy_epub(self.source)

    def test_legacy_upgrade_keeps_assets_and_nested_navigation(self):
        original = self.source.read_bytes()
        conversion.convert_book(self.source, self.output, output_profile='epub3')
        self.assertEqual(conversion.validate_epub_output(self.output), {'3'})
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as result:
            self.assertEqual(result.infolist()[0].filename, 'mimetype')
            self.assertEqual(result.infolist()[0].compress_type, zipfile.ZIP_STORED)
            for member in set(source.namelist()) - {'OPS/book.opf'}:
                self.assertEqual(result.read(member), source.read(member), member)
            package = conversion.xml(result.read('OPS/book.opf'))
            items = conversion.first(package, 'manifest')
            self.assertEqual(next(item for item in items if item.get('id') == 'cover').get('properties'), 'cover-image')
            nav, = [item for item in items if item.get('properties') == 'nav']
            document = conversion.xhtml(result.read('OPS/' + nav.get('href')))
            toc, pages = list(document.iter('{' + conversion.XH + '}nav'))
            anchors = list(toc.iter('{' + conversion.XH + '}a'))
            self.assertEqual([(node.text, node.get('href')) for node in anchors],
                             [('Chapter one', 'text/chapter.xhtml#chapter'), ('Note', 'text/note.xhtml#note')])
            self.assertEqual(len(list(toc.iter('{' + conversion.XH + '}ol'))), 2)
            self.assertEqual(pages.get('{' + conversion.EP + '}type'), 'page-list')
        self.assertEqual(self.source.read_bytes(), original)

    def test_existing_epub3_is_byte_identical(self):
        conversion.convert_book(self.source, self.output, output_profile='epub3')
        second = self.work / 'second.epub'
        conversion.convert_book(self.output, second, output_profile='epub3')
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

    def test_docx_to_epub3_needs_no_fb2_writer(self):
        word = self.work / 'input.docx'
        docx(word)
        conversion.convert_book(word, self.output, output_profile='epub3', tools_root=self.work / 'no-writers')
        with zipfile.ZipFile(self.output) as archive:
            self.assertTrue(any('Точная сноска'.encode() in archive.read(name)
                                for name in archive.namelist() if name.endswith('.xhtml')))
        self.assertEqual(conversion.validate_epub_output(self.output), {'3'})

    def test_canceled_upgrade_keeps_source_and_leaves_no_copy(self):
        original = self.source.read_bytes()
        writing = False

        def progress(stage, done, total):
            nonlocal writing
            writing |= stage == 'advanced-writing'

        def check():
            if writing:
                raise InterruptedError('canceled')

        with self.assertRaises(InterruptedError):
            conversion.convert_book(self.source, self.output, output_profile='epub3',
                                    cancel_check=check, progress=progress)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), original)
        self.assertFalse(list(self.work.glob('homelibre-advanced-*')))

    def test_legacy_signed_package_is_not_rewritten(self):
        with zipfile.ZipFile(self.source, 'a') as archive:
            archive.writestr('META-INF/signatures.xml', '<signatures/>')
        original = self.source.read_bytes()
        with self.assertRaisesRegex(conversion.ConversionError, 'подпись'):
            conversion.convert_book(self.source, self.output, output_profile='epub3')
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), original)

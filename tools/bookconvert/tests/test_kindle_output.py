"""Optional writer boundaries and preservation; real native round-trip is separate."""
import hashlib
import importlib.util
import re
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c = load('kindle_output_test_api', ROOT / 'convert_book.py')
k = load('kindle_output_test_writer', ROOT / 'kindle_output.py')


class KindleOutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='homelibre-kindle-boundaries-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'book.epub'
        self.image = bytes(range(256))
        self.css = b'p {color: #123456}'
        with zipfile.ZipFile(self.source, 'w') as z:
            z.writestr('mimetype', 'application/epub+zip')
            z.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>')
            z.writestr('OPS/package.opf', '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="id"><metadata>
<dc:identifier id="id">original-id</dc:identifier><dc:title>Название</dc:title><dc:creator>Автор</dc:creator><dc:language>ru</dc:language>
<meta property="mhl:fb2-cover">#old-cover</meta><meta property="belongs-to-collection" id="series">Серия</meta><meta refines="#series" property="group-position">4</meta></metadata>
<manifest><item id="chapter" href="chapter.xml" media-type="application/xhtml+xml"/><item id="pic" href="image.png" media-type="image/png"/><item id="style" href="style.css" media-type="text/css"/></manifest><spine><itemref idref="chapter"/></spine></package>''')
            z.writestr('OPS/chapter.xml', '''<html:html xmlns:html="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><html:head><html:title>Глава</html:title></html:head><html:body><html:p id="anchor" data-fb2="obsolete"><html:strong>Ёжик</html:strong> <html:a href="#note" epub:type="noteref">1</html:a><html:img src="image.png" data-fb2-image="old-cover"/></html:p><html:aside id="note" epub:type="footnote">Сноска</html:aside></html:body></html:html>''')
            z.writestr('OPS/image.png', self.image)
            z.writestr('OPS/style.css', self.css)
        self.before = hashlib.sha256(self.source.read_bytes()).digest()

    def writer(self):
        tool = self.root / 'tools/kindle-export/kindling-cli.exe'
        tool.parent.mkdir(parents=True)
        tool.write_bytes(b'not executed: mocked process')
        return tool

    def assert_clean(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).digest(), self.before)
        self.assertFalse(list(self.root.glob('homelibre-kindle-output-*')))
        self.assertFalse(list(self.root.glob('.homelib-convert-*')))

    def test_private_adaptation_uses_manifest_and_preserves_content_and_metadata(self):
        output = self.root / 'private.epub'
        k.canonical_input(c, self.source, output)
        with zipfile.ZipFile(output) as z:
            self.assertEqual(z.read('OPS/image.png'), self.image)
            self.assertEqual(z.read('OPS/style.css'), self.css)
            root = c.xhtml(z.read('OPS/chapter.xml'))
            self.assertEqual(root.tag, '{' + c.XH + '}html')
            self.assertNotIn(b'html:html', z.read('OPS/chapter.xml'))
            self.assertTrue(any(n.get('id') == 'anchor' for n in root.iter()))
            self.assertTrue(any(n.get('{' + c.EP + '}type') == 'noteref' and n.get('href') == '#note' for n in root.iter()))
            self.assertFalse(any(name.startswith('data-fb2') for n in root.iter() for name in n.attrib))
            metadata = c.xml(z.read('OPS/package.opf'))
            for text in ('original-id', 'Название', 'Автор', 'ru', 'Серия', '4'):
                self.assertIn(text, list(metadata.itertext()))
            self.assertFalse(any(n.get('property', '').startswith('mhl:fb2-') for n in metadata.iter()))
        self.assert_clean()

    def test_svg_math_and_note_namespaces_survive_replaced_html_root(self):
        source, output = self.root / 'foreign.epub', self.root / 'canonical.epub'
        with zipfile.ZipFile(self.source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/chapter.xml'] = files['OPS/chapter.xml'].replace(b'</html:body>',
            b'<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:image xmlns:l="http://www.w3.org/1999/xlink" l:href="image.png"/></s:svg>'
            b'<m:math xmlns:m="http://www.w3.org/1998/Math/MathML"><m:mi>x</m:mi></m:math></html:body>')
        with zipfile.ZipFile(source, 'w') as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        k.canonical_input(c, source, output)
        with zipfile.ZipFile(output) as archive:
            data = archive.read('OPS/chapter.xml')
            expected = c.xhtml(data)
            opening = re.search(rb'<html\b[^>]*>', data)
            self.assertIsNotNone(opening)
            replaced = re.sub(rb' xmlns:[\w-]+="[^"]*"', b'', opening[0])
            actual = c.xhtml(data[:opening.start()] + replaced + data[opening.end():])
            self.assertEqual([(n.tag, dict(n.attrib)) for n in actual.iter()],
                             [(n.tag, dict(n.attrib)) for n in expected.iter()])
            self.assertEqual(list(actual.itertext()), list(expected.itertext()))
            self.assertEqual(archive.read('OPS/image.png'), self.image)
        self.assert_clean()

    def test_legacy_cover_mime_and_missing_fonts_are_repaired_in_private_copy(self):
        with zipfile.ZipFile(self.source) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['OPS/package.opf'] = (files['OPS/package.opf']
            .replace(b'id="pic" href="image.png" media-type="image/png"',
                     b'id="pic" href="image.jpg" media-type="image/jpeg" properties="cover-image"')
            .replace(b'<manifest>', b'<manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>'
                     b'<item id="font" href="fonts/present.ttf" media-type="font/ttf"/>'
                     b'<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
            .replace(b'<spine>', b'<spine toc="ncx"><itemref idref="cover" linear="no"/>'))
        files['OPS/chapter.xml'] = files['OPS/chapter.xml'].replace(b'image.png', b'image.jpg')
        files['OPS/image.jpg'] = b'\x89PNG\r\n\x1a\n' + files.pop('OPS/image.png')
        files['OPS/fonts/present.ttf'] = b'packaged-font-bytes'
        missing = b'@font-face { font-family: Missing; src: /* font */ url("fonts/missing.ttf") format("truetype"); }'
        style = (b'/* ' + missing + b' */\n'
                 b'@font-face {font-family: Keep; src:url(fonts/present.ttf)}\n'
                 b'@font-face {font-family: "Literal; src:url(missing.ttf);"; src:local("Book Font")}\n'
                 b'@font-face {font-family: Fallback; src:url(missing.ttf), url(fonts/present.ttf)}\n'
                 b'p {color: #123456}')
        files['OPS/style.css'] = missing + style
        chapter, cover, ncx = ('OPS/chapter.xml', 'OPS/cover.xhtml', 'OPS/toc.ncx')
        files[cover] = b'<html xmlns="http://www.w3.org/1999/xhtml"><body><div><img src="image.jpg"/></div></body></html>'
        files[ncx] = b'<ncx><navMap><navPoint><content src="chapter.xml#anchor"/></navPoint></navMap></ncx>'
        for keep_cover in ('no', 'caption', 'chapter-link', 'toc-link', 'startup',
                           'startup-chapter-link', 'startup-fragment', 'guide-link'):
            with self.subTest(keep_cover=keep_cover):
                payloads = dict(files)
                if keep_cover == 'caption':
                    payloads[cover] = files[cover].replace(b'</div>', b'<p>Edition detail</p></div>')
                elif keep_cover in ('chapter-link', 'startup-chapter-link'):
                    payloads[chapter] = files[chapter].replace(b'href="#note"', b'href="cover.xhtml"')
                elif keep_cover == 'toc-link':
                    payloads[ncx] = files[ncx].replace(b'chapter.xml#anchor', b'cover.xhtml')
                if keep_cover.startswith('startup') or keep_cover == 'guide-link':
                    kind = b'toc' if keep_cover == 'guide-link' else b'text'
                    link = b'cover.xhtml#top' if keep_cover == 'startup-fragment' else b'cover.xhtml'
                    guide = b'<guide><reference type="' + kind + b'" href="' + link + b'"/></guide>'
                    payloads['OPS/package.opf'] = (files['OPS/package.opf']
                        .replace(b' linear="no"', b'').replace(b'</package>', guide + b'</package>'))
                source, output = self.root / (keep_cover + '.epub'), self.root / (keep_cover + '-out.epub')
                with zipfile.ZipFile(source, 'w') as archive:
                    for name, data in payloads.items():
                        archive.writestr(name, data)
                source_hash = hashlib.sha256(source.read_bytes()).digest()
                warnings = set()
                self.assertTrue(k.canonical_input(c, source, output, warnings))
                self.assertEqual(len(warnings), 1)
                with zipfile.ZipFile(output) as archive:
                    package = c.xml(archive.read('OPS/package.opf'))
                    manifest = c.first(package, 'manifest')
                    image = next(node for node in manifest if node.get('id') == 'pic')
                    self.assertEqual(image.get('media-type'), 'image/png')
                    self.assertEqual(image.get('href'), 'image.jpg')
                    self.assertEqual(archive.read('OPS/image.jpg'), files['OPS/image.jpg'])
                    self.assertEqual(archive.read('OPS/fonts/present.ttf'), files['OPS/fonts/present.ttf'])
                    self.assertEqual(archive.read('OPS/style.css'), style)
                    self.assertEqual(archive.read(ncx), payloads[ncx])
                    spine = c.first(package, 'spine')
                    self.assertEqual(spine.get('toc'), 'ncx')
                    removed = keep_cover in ('no', 'startup')
                    self.assertEqual([item.get('idref') for item in spine], ['chapter'] if removed else ['cover', 'chapter'])
                    guide = c.first(package, 'guide')
                    if guide is not None:
                        expected = 'chapter.xml' if removed else link.decode('ascii')
                        self.assertEqual(guide[0].get('href'), expected)
                    self.assertIn(cover, archive.namelist())
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), source_hash)

    def test_jpeg_record_padding_preserves_codestream_and_unknown_tails(self):
        for length in (1, 2, 3):
            image = b'\xff\xd8\xff' + b'x' * (7 - length) + b'\xff\xd9'
            padded = image + b'\0' * length
            self.assertEqual(len(padded) % 4, 0)
            self.assertEqual(k.jpeg_without_record_padding(padded), image)
            self.assertEqual(k.jpeg_without_record_padding(image), image)
        for data in (b'\xff\xd8\xffbroken!!!', b'not-jpeg\xff\xd9\0\0',
                     b'\xff\xd8\xffphoto!\xff\xd9X', b'\xff\xd8\xffabc\xff\xd9\0\0\0\0'):
            self.assertEqual(k.jpeg_without_record_padding(data), data)

    def test_rtf_empty_paragraphs_keep_valid_xhtml_and_single_line_breaks(self):
        source = self.root / 'empty-paragraphs.rtf'
        source.write_bytes(br'{\rtf1\ansi First\par\par Last\line Final}')
        source_hash = hashlib.sha256(source.read_bytes()).digest()
        prepared, adapted = self.root / 'prepared.epub', self.root / 'adapted.epub'
        c.convert_book(source, prepared)
        k.canonical_input(c, prepared, adapted)
        with zipfile.ZipFile(prepared) as before, zipfile.ZipFile(adapted) as after:
            document = 'OEBPS/book.xhtml'
            original = c.xhtml(before.read(document))
            actual = c.xhtml(after.read(document))
            self.assertEqual(list(original.itertext()), list(actual.itertext()))
            self.assertEqual([c.tag(n) for n in original.iter()], [c.tag(n) for n in actual.iter()])
            self.assertIn(b'<p></p>', after.read(document))
            self.assertNotIn(b'<p />', after.read(document))
            self.assertNotIn(b'</br>', after.read(document))
            self.assertEqual(sum(c.tag(n) == 'br' for n in actual.iter()), 1)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), source_hash)
        self.assert_clean()

    def test_gif_record_padding_requires_a_complete_block_stream(self):
        image = bytes.fromhex('47494638396101000100800000000000ffffff2c00000000010001000002024401003b')
        for length in range(1, 5):
            comment = b'\x21\xfe' + bytes([length]) + b'x' * length + b'\0'
            complete = image[:19] + comment + image[19:]
            padding = b'\0' * (-len(complete) % 4)
            self.assertEqual(k.gif_without_record_padding(complete + padding), complete)
        for broken in (image[:-1], image + b'X', b'GIF89a' + b'\0' * 10,
                       image[:29] + b'\x02\x07\x3b\0\0\0'):
            aligned = broken + b'\0' * (-len(broken) % 4)
            self.assertEqual(k.gif_without_record_padding(aligned), aligned)

    def test_missing_writer_requests_only_the_kindle_output_component(self):
        with self.assertRaises(c.ComponentRequired) as caught:
            c.convert_book(self.source, self.root / 'out.mobi', tools_root=self.root / 'tools')
        self.assertEqual(caught.exception.component, 'KindleExport')
        self.assertFalse((self.root / 'out.mobi').exists())
        self.assert_clean()

    def test_only_store_cover_requirement_can_be_exempted_after_full_preflight(self):
        result = SimpleNamespace(returncode=1,
            stdout='[error R4.2.1] No internal content cover image declared.\n',
            stderr='Build aborted: 1 validation errors. Run with --no-validate to skip.')
        self.assertTrue(k.only_publication_cover_required(result, False))
        self.assertFalse(k.only_publication_cover_required(result, True))
        result.stdout += '[error R7.3] Broken chapter link.\n'
        self.assertFalse(k.only_publication_cover_required(result, False))
        result.stdout = '[error R4.2.1] No internal content cover image declared.\n'
        result.stderr = 'Native writer crashed.'
        self.assertFalse(k.only_publication_cover_required(result, False))
        self.assert_clean()

    def test_failed_native_process_never_publishes_a_partial_book(self):
        tool = self.writer()
        def failure(command, **options):
            self.assertEqual(command[0], str(tool))
            self.assertIn('--legacy-mobi', command)
            Path(command[command.index('-o') + 1]).write_bytes(b'partial book')
            return SimpleNamespace(returncode=1, stdout='', stderr='native writer failed')
        with mock.patch.object(subprocess, 'run', side_effect=failure):
            with self.assertRaisesRegex(c.ConversionError, 'native writer failed'):
                c.convert_book(self.source, self.root / 'out.mobi', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.mobi').exists())
        self.assert_clean()

    def test_long_validation_report_keeps_the_error_before_the_warnings(self):
        self.writer()
        failure = SimpleNamespace(returncode=1, stdout='[error R4.2.4] Duplicate cover.\n' +
            '[warning R10.4.5] Image name does not match its format.\n' * 100,
            stderr='Build aborted: 1 validation errors.')
        with mock.patch.object(subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(c.ConversionError, 'R4.2.4.*Duplicate cover'):
                c.convert_book(self.source, self.root / 'out.azw3', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.azw3').exists())
        self.assert_clean()

    def test_timeout_is_reported_and_removes_private_intermediates(self):
        self.writer()
        with mock.patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('kindling', 300)):
            with self.assertRaisesRegex(c.ConversionError, '5 минут'):
                c.convert_book(self.source, self.root / 'out.azw3', tools_root=self.root / 'tools')
        self.assertFalse((self.root / 'out.azw3').exists())
        self.assert_clean()

    def test_existing_result_and_source_are_never_replaced(self):
        result = self.root / 'out.mobi'
        result.write_bytes(b'previous saved book')
        with mock.patch.object(subprocess, 'run') as run:
            with self.assertRaises(c.ConversionError):
                c.convert_book(self.source, result, tools_root=self.root / 'tools')
            run.assert_not_called()
        self.assertEqual(result.read_bytes(), b'previous saved book')
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()

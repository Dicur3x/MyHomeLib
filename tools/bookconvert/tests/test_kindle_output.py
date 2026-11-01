"""Optional writer boundaries and preservation; real native round-trip is separate."""
import hashlib
import importlib.util
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

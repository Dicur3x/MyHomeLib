"""First-use requests must survive conversion failure reports for every module."""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('converter_missing', ROOT / 'convert_book.py')
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)


class MissingComponents(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-missing-module-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'empty-tools'
        self.tools.mkdir()

    def module(self, name):
        spec = importlib.util.spec_from_file_location('missing_' + name, ROOT / (name + '.py'))
        result = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(result)
        return result

    def book(self):
        class Book:
            tools_root = self.tools
            work_root = self.root
            source = self.root / 'source'

            def require(self, component, message):
                raise converter.ComponentRequired(component, message)

            def fail(self, message):
                raise converter.ConversionError(message)
        return Book()

    def check(self, component, action):
        with self.assertRaises(converter.ComponentRequired) as raised:
            action()
        self.assertEqual(raised.exception.component, component)

    def test_pdf_and_djvu_request_their_own_modules(self):
        fixed = self.module('fixed_layout')
        self.check('PDFium', lambda: fixed.read_pdf(self.book(), self.tools))
        self.check('DjVuLibre', lambda: fixed.read_djvu(self.book(), self.tools))

    def test_image_and_office_dependencies_request_the_correct_module(self):
        self.check('WebP', lambda: self.module('image_input').decode_webp(self.book(), b''))
        self.check('BookConverter', lambda: next(self.module('xps_input').rendered_pages(self.book())))
        office = self.module('office_inputs')
        for extension, component in (('.doc', 'DocSharp'), ('.ppt', 'DocSharp'),
                                     ('.xls', 'DocSharp'), ('.wps', 'BookConverter'), ('.wpd', 'BookConverter')):
            with self.subTest(extension=extension):
                self.check(component, lambda: office.read(self.book(), extension, None, None, None, None))

    def test_pdf_and_djvu_cli_report_module_without_creating_output(self):
        for suffix, header, component in (('.pdf', b'%PDF-1.4\n', 'PDFium'),
                                           ('.djvu', b'AT&TFORM\0\0\0\0DJVU', 'DjVuLibre')):
            with self.subTest(suffix=suffix):
                source = self.root / ('source' + suffix)
                source.write_bytes(header)
                destination = self.root / (suffix[1:] + '.epub')
                report = self.root / (suffix[1:] + '.json')
                process = subprocess.run([sys.executable, '-I', '-B', '-X', 'utf8', str(ROOT / 'convert_book.py'),
                                          str(source), str(destination), '--tools-root', str(self.tools),
                                          '--report', str(report)], capture_output=True, timeout=15)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(json.loads(report.read_text(encoding='utf-8'))['required_component'], component)
                self.assertFalse(destination.exists())
                self.assertEqual(source.read_bytes(), header)


if __name__ == '__main__':
    unittest.main()

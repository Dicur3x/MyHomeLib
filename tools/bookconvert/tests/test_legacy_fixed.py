"""New containers and fixed-page conversion: actual engines, not mocked output."""
from pathlib import Path
import base64
import hashlib
import importlib.util
import os
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib
from email.message import EmailMessage

ROOT = Path(__file__).resolve().parents[1]
def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
c, legacy, fixed = module('convert_book'), module('legacy_inputs'), module('fixed_layout')
TOOLS = Path(os.environ.get('HOMELIB_TEST_TOOLS', ROOT.parents[1] / 'Program/Out/Bin64/tools'))


def pdf_fixture(text=True, ocr=False):
    # Tiny independent PDF writer for a deterministic text/illustration fixture.
    content = b'q 90 0 0 65 40 170 cm /Im Do Q\n'
    if text:
        content += b'BT /F1 12 Tf ' + (b'3 Tr ' if ocr else b'')
        content += b'40 260 Td (First readable paragraph with an illustration below.) Tj 0 -150 Td (Last paragraph preserves the final sentence.) Tj ET\n'
    rgb = bytes([20, 80, 180]) * (20 * 20)
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> /XObject << /Im 6 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'endstream',
               b'<< /Type /XObject /Subtype /Image /Width 20 /Height 20 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ' + str(len(zlib.compress(rgb))).encode() + b' >>\nstream\n' + zlib.compress(rgb) + b'\nendstream']
    result = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1): offsets.append(len(result)); result.extend(str(i).encode() + b' 0 obj\n' + obj + b'\nendobj\n')
    xref = len(result); result.extend(b'xref\n0 7\n0000000000 65535 f \n')
    for offset in offsets[1:]: result.extend(f'{offset:010} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF'.encode()); return bytes(result)


def pdb_fixture(text, compressed=False, kind=b'TEXtREAd'):
    record = b'\x00\x02\x00\x00' if compressed else b'\x00\x01\x00\x00'
    record += struct.pack('>IHHI', len(text), 1, 4096, 0)
    header = bytearray(78); header[:5] = b'Book\0'; header[60:68] = kind; header[76:78] = b'\0\2'
    return bytes(header) + struct.pack('>II', 94, 0) + struct.pack('>II', 110, 1) + record + text


class LegacyFixed(unittest.TestCase):
    def setUp(self): self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def convert(self, extension, data, target='.epub'):
        source = self.root / ('source' + extension); source.write_bytes(data); before = hashlib.sha256(data).hexdigest()
        output = self.root / ('output' + target)
        report = c.convert_book(source, output, tools_root=TOOLS)
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)
        if target == '.epub':
            with zipfile.ZipFile(output) as z:
                self.assertIsNone(z.testzip()); body = ET.fromstring(z.read('OEBPS/book.xhtml'))
                images = [n for n in z.namelist() if '/images/' in n]
        else: body = ET.parse(output).getroot(); images = [n for n in body if c.tag(n) == 'binary']
        return report, ''.join(body.itertext()), images
    def test_palmdoc_plain_and_bad_record_bounds(self):
        _, text, _ = self.convert('.pdb', pdb_fixture('Привет, мир. Конец книги.'.encode('cp1251')), '.fb2')
        self.assertIn('Привет, мир. Конец книги.', text)
        bad = bytearray(pdb_fixture(b'hello')); bad[78:82] = b'\xff' * 4
        source = self.root / 'bad.pdb'; source.write_bytes(bad)
        with self.assertRaises(c.ConversionError): c.convert_book(source, self.root / 'bad.epub')
        self.assertFalse((self.root / 'bad.epub').exists())
    def test_palmdoc_backreferences_overlap_and_bounds(self):
        self.assertEqual(legacy.palmdoc(b'abc\x80\x1b', self.fail), b'abcabcabc')
        self.assertEqual(legacy.palmdoc(b'\xe1', self.fail), b' a')
        with self.assertRaises(AssertionError): legacy.palmdoc(b'\x80\0', self.fail)
    def test_ztxt_bounded_stream_and_corruption(self):
        text = 'Текст zTXT. Конец книги.'.encode('cp1251')
        header = struct.pack('>HHI', 0x012c, 1, len(text)) + b'\0' * 8
        pdb = bytearray(pdb_fixture(b'ignored', kind=b'zTXTGPlm'))
        payload = bytes(pdb[:94]) + header + zlib.compress(text)
        _, body, _ = self.convert('.pdb', payload, '.fb2')
        self.assertIn('Текст zTXT. Конец книги.', body)
        bad = self.root / 'broken.pdb'; bad.write_bytes(bytes(pdb[:94]) + header + b'not zlib')
        with self.assertRaisesRegex(c.ConversionError, 'zTXT'): c.convert_book(bad, self.root / 'bad.fb2')
        self.assertFalse((self.root / 'bad.fb2').exists())

    def test_mhtml_legacy_nested_layout_has_valid_blocks(self):
        msg = EmailMessage(); msg.set_content('<html><body><p><b>Before<table><tr><td><table><tr><td>Inside</table></table>After</b><ul><li>Final<li>Last</ul>', subtype='html', charset='utf-8')
        report, text, _ = self.convert('.mht', msg.as_bytes(), '.fb2')
        self.assertTrue(all(word in text for word in ['Before','Inside','After','Final','Last']))
        self.assertTrue(any('вёрстка упрощена' in w for w in report['warnings']))
        root = ET.parse(self.root/'output.fb2').getroot()
        self.assertFalse(any(c.tag(node) == 'tr' for node in root.iter()))
        self.assertFalse(any(c.tag(n) in {'p','div','table'} for p in root.iter() if c.tag(p) == 'p' for n in p))

    def test_pdb_other_container_not_misidentified(self):
        source = self.root / 'isilo.pdb'; source.write_bytes(pdb_fixture(b'private data', kind=b'SDocSilX'))
        with self.assertRaisesRegex(c.ConversionError, 'SDocSilX'): c.convert_book(source, self.root / 'unsupported.fb2')
        self.assertFalse((self.root / 'unsupported.fb2').exists())
    def test_tcr_dictionary_and_renamed_signature(self):
        text = 'Первая строка.\nПоследняя строка.'.encode('cp1251')
        dictionary = b''.join(bytes([1, i]) for i in range(256))
        _, body, _ = self.convert('.123456', b'!!8-Bit!!' + dictionary + text)
        self.assertIn('Первая строка.', body); self.assertIn('Последняя строка.', body)
    def test_wri_plain_and_objects_rejected(self):
        text = 'Книга Write. Конец.'.encode('cp1251'); header = bytearray(128); header[:2] = b'1\xbe'; header[14:18] = struct.pack('<I', 128 + len(text))
        _, body, _ = self.convert('.wri', bytes(header) + text); self.assertIn('Книга Write.', body)
        source = self.root / 'object.wri'; header[14:18] = struct.pack('<I', 130); source.write_bytes(header + b'\x16\x01')
        with self.assertRaisesRegex(c.ConversionError, 'объекты'): c.convert_book(source, self.root / 'object.epub')
    def test_mhtml_cid_image_uses_no_external_fetch(self):
        png = fixed.png(b'\x30\x60\x90' * 4, 2, 2)
        msg = EmailMessage(); msg.set_type('multipart/related'); html = EmailMessage()
        html.set_content('<html><body><h1>Глава</h1><p>Начало.</p><img src="cid:picture"/><p>Конец.</p></body></html>', subtype='html', charset='utf-8'); msg.attach(html)
        image = EmailMessage(); image.set_content(png, maintype='image', subtype='png'); image['Content-ID'] = '<picture>'; msg.attach(image)
        _, body, images = self.convert('.mhtml', msg.as_bytes()); self.assertIn('Конец.', body); self.assertEqual(len(images), 1)
    def test_mhtml_missing_image_fails_without_output(self):
        msg = EmailMessage(); msg.set_content('<html><body><p>Book</p><img src="https://invalid.example/image.jpg"/></body></html>', subtype='html', charset='utf-8')
        source = self.root / 'missing.mht'; source.write_bytes(msg.as_bytes())
        with self.assertRaisesRegex(c.ConversionError, 'отсутствует'): c.convert_book(source, self.root / 'missing.fb2')
        self.assertFalse((self.root / 'missing.fb2').exists())
    def test_djvu_quoted_utf8_octal_and_ppm_bounds(self):
        quoted = '(line 0 0 10 10 "\\320\\237\\321\\200\\320\\270\\320\\262\\320\\265\\321\\202")'
        self.assertEqual(fixed.sexpressions(quoted, self.fail)[0][-1], 'Привет')
        self.assertEqual(fixed.sexpressions('(line 0 0 1 1 "Привет")', self.fail)[0][-1], 'Привет')
        pixels = bytes([32,10,13,0,255,1])
        self.assertEqual(fixed.ppm(b'P6\n# comment\n2 1\n255\n'+pixels, self.fail), (pixels,2,1))
        with self.assertRaises(AssertionError): fixed.ppm(b'P6\n2 1\n255\n'+pixels[:-1], self.fail)

    def test_multicolumn_order_and_quality(self):
        lines = [{'text': 'Header', 'box': (0, 0, 300, 10)}]
        lines += [{'text': f'{side}{n}', 'box': (x, 40+n*13, x+110, 50+n*13)} for side,x in [('L',0),('R',180)] for n in range(5)]
        self.assertEqual([n['text'] for n in fixed.order_lines(lines)], ['Header'] + [f'L{n}' for n in range(5)] + [f'R{n}' for n in range(5)])
        self.assertTrue(fixed.readable('Обычный распознанный текст.'))
        self.assertFalse(fixed.readable('\ue001\ufffd \ue002\ufffd ????'))
    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_actual_pdfium_text_and_illustration(self):
        report, text, images = self.convert('.123456', pdf_fixture(), '.fb2')
        self.assertIn('First readable paragraph', text); self.assertIn('Last paragraph preserves', text); self.assertGreaterEqual(len(images), 1)
        self.assertTrue(any('OCR' in w for w in report['warnings']))
    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_ocr_layer_allowed_and_scan_rejected(self):
        report, text, _ = self.convert('.pdf', pdf_fixture(ocr=True)); self.assertIn('First readable', text)
        self.assertTrue(any('OCR' in w for w in report['warnings']))
        source = self.root / 'scan.pdf'; source.write_bytes(pdf_fixture(text=False))
        with self.assertRaisesRegex(c.ConversionError, 'Сканы'): c.convert_book(source, self.root / 'scan.epub', tools_root=TOOLS)
        self.assertFalse((self.root / 'scan.epub').exists())


if __name__ == '__main__': unittest.main()

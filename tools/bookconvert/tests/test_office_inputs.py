"""Office import structure/content oracles; no installed Office is used."""
from pathlib import Path
import hashlib
import importlib.util
import os
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

from test_text_inputs import PNG

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('office_conversion_test', ROOT / 'convert_book.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
TOOLS = Path(os.environ.get('HOMELIB_TEST_TOOLS', ROOT.parents[1] / 'Program/Out/Bin64/tools'))
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
X = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
O = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
T = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
TB = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0'
D = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0'
XL = 'http://www.w3.org/1999/xlink'


def relationships(*pairs):
    return '<Relationships xmlns="' + PR + '">' + ''.join('<Relationship Id="' + key + '" Target="' + target + '"/>' for key, target in pairs) + '</Relationships>'


def fixture(path, kind, malicious=False):
    with zipfile.ZipFile(path, 'w') as z:
        if kind == 'pptx':
            z.writestr('ppt/presentation.xml', f'<p:presentation xmlns:p="{P}" xmlns:r="{R}"><p:sldIdLst><p:sldId r:id="second"/><p:sldId r:id="first"/></p:sldIdLst></p:presentation>')
            z.writestr('ppt/_rels/presentation.xml.rels', relationships(('first','slides/slide1.xml'),('second','slides/slide2.xml')))
            z.writestr('ppt/slides/slide2.xml', f'<p:sld xmlns:p="{P}" xmlns:a="{A}" xmlns:r="{R}"><p:spTree><p:sp><p:txBody><a:p><a:r><a:rPr b="1"/><a:t>Первый слайд — Ё, ї, ў</a:t></a:r></a:p></p:txBody></p:sp><p:pic><a:blip r:embed="image"/></p:pic></p:spTree></p:sld>')
            z.writestr('ppt/slides/_rels/slide2.xml.rels', relationships(('image','../media/image.png')))
            z.writestr('ppt/slides/slide1.xml', f'<p:sld xmlns:p="{P}" xmlns:a="{A}"><p:sp><p:txBody><a:p><a:r><a:t>Последнее предложение.</a:t></a:r></a:p></p:txBody></p:sp></p:sld>')
            z.writestr('ppt/media/image.png', PNG)
            if malicious:
                z.writestr('ppt/slides/_rels/slide1.xml.rels', '<Relationships/>')
                z.writestr('ppt/slides/slide3.xml', '<unused/>')
        elif kind == 'xlsx':
            z.writestr('xl/workbook.xml', f'<workbook xmlns="{X}" xmlns:r="{R}"><sheets><sheet name="Данные" r:id="one"/></sheets></workbook>')
            z.writestr('xl/_rels/workbook.xml.rels', relationships(('one','worksheets/sheet1.xml')))
            z.writestr('xl/sharedStrings.xml', f'<sst xmlns="{X}"><si><r><t>Начало таблицы.</t></r></si></sst>')
            z.writestr('xl/worksheets/sheet1.xml', f'<worksheet xmlns="{X}"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1"><v>42</v></c></row><row r="3"><c r="A3"><f>1+2</f><v>3</v></c><c r="B3"><f>NOW()</f></c><c r="C3" t="inlineStr"><is><t>Последнее предложение.</t></is></c></row></sheetData></worksheet>')
        else:
            namespaces = f'xmlns:office="{O}" xmlns:text="{T}" xmlns:table="{TB}" xmlns:draw="{D}" xmlns:xlink="{XL}"'
            if kind == 'ods':
                content = '<office:spreadsheet><table:table table:name="Первый лист"><table:table-row><table:table-cell><text:p>Начало таблицы.</text:p></table:table-cell><table:table-cell table:number-columns-repeated="2" office:value="42"/></table:table-row><table:table-row table:number-rows-repeated="1048574"><table:table-cell/></table:table-row><table:table-row><table:table-cell><text:p>Последнее предложение.</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet>'
                mime = 'spreadsheet'
            else:
                content = '<office:presentation><draw:page draw:name="Начало"><draw:frame><text:p>Первый слайд — Ё, ї, ў</text:p><draw:image xlink:href="Pictures/image.png"/></draw:frame></draw:page><draw:page><text:p>Последнее предложение.</text:p></draw:page></office:presentation>'
                mime = 'presentation'; z.writestr('Pictures/image.png', PNG)
            z.writestr('mimetype', 'application/vnd.oasis.opendocument.' + mime)
            if malicious: content = content.replace('table:number-columns-repeated="2"', 'table:number-columns-repeated="999999999"')
            z.writestr('content.xml', f'<office:document-content {namespaces}><office:body>{content}</office:body></office:document-content>')


class OfficeInputs(unittest.TestCase):
    def test_legacy_bitmap_preserved_and_empty_worksheet_valid(self):
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'pictures.ods'
            bmp = b'BM' + struct.pack('<IHHI', 62, 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, 2, 1, 1, 24, 0, 8, 0, 0, 0, 0) + b'\x00\x00\xff\x00\xff\x00\0\0'
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr('mimetype', 'application/vnd.oasis.opendocument.spreadsheet')
                z.writestr('content.xml', f'<office:document-content xmlns:office="{O}" xmlns:table="{TB}" xmlns:draw="{D}" xmlns:xlink="{XL}"><office:body><office:spreadsheet><table:table table:name="Пустой лист"/><table:table table:name="Рисунок"><draw:frame><draw:image xlink:href="Pictures/image.bmp"/></draw:frame></table:table></office:spreadsheet></office:body></office:document-content>')
                z.writestr('Pictures/image.bmp', bmp)
            target = source.with_suffix('.fb2'); c.convert_book(source, target, tools_root=TOOLS)
            content = c.xml(target.read_bytes()); c.validate_fb2_output(content)
            self.assertIn('[Пустой лист]', c.plain(content))
            import base64
            binary = content.find('{' + c.FB + '}binary')
            image = base64.b64decode(binary.text)
            self.assertTrue(image.startswith(b'\x89PNG\r\n\x1a\n'))
            self.assertEqual(struct.unpack('>II', image[16:24]), (2, 1))

    def test_unsupported_office_object_strict_export_and_visible_reading_placeholder(self):
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'objects.odp'
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr('mimetype', 'application/vnd.oasis.opendocument.presentation')
                z.writestr('content.xml', f'<office:document-content xmlns:office="{O}" xmlns:text="{T}" xmlns:draw="{D}"><office:body><office:presentation><draw:page><text:p>Текст слайда.</text:p><draw:object/></draw:page></office:presentation></office:body></office:document-content>')
            target = source.with_suffix('.epub')
            with self.assertRaises(c.ConversionError): c.convert_book(source, target, tools_root=TOOLS)
            self.assertFalse(target.exists())
            warnings = c.convert_book(source, target, tools_root=TOOLS, reading=True)
            with zipfile.ZipFile(target) as z:
                text = '\n'.join(c.plain(c.xhtml(z.read(n))) for n in z.namelist() if n.endswith('.xhtml'))
            self.assertIn('Текст слайда.', text); self.assertIn('[Встроенный объект', text)
            self.assertTrue(any('пометкой' in warning for warning in warnings['warnings']))

    def test_office_packages_both_book_formats_and_numeric_extensions(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            for kind in ['pptx', 'xlsx', 'ods', 'odp']:
                source = root / (kind + '.123456'); fixture(source, kind)
                original = hashlib.sha256(source.read_bytes()).hexdigest()
                for ext in ['.epub', '.fb2']:
                    target = root / (kind + ext); warnings = c.convert_book(source, target, tools_root=TOOLS)
                    self.assertTrue(warnings)
                    if ext == '.epub':
                        with zipfile.ZipFile(target) as z:
                            contents = [c.xhtml(z.read(n)) for n in z.namelist() if n.endswith('.xhtml') and not n.endswith('/nav.xhtml')]
                            text = '\n'.join(c.plain(n) for n in contents)
                            images = [n for n in z.namelist() if '/images/' in n]
                    else:
                        content = c.xml(target.read_bytes()); c.validate_fb2_output(content)
                        text = c.plain(content); images = content.findall('{' + c.FB + '}binary')
                    self.assertIn('Последнее предложение.', text)
                    if kind in {'pptx', 'odp'}:
                        self.assertLess(text.index('Первый слайд'), text.index('Последнее предложение.'))
                        self.assertEqual(len(images), 1)
                    else:
                        self.assertIn('Начало таблицы.', text); self.assertIn('42', text)
                    if kind == 'xlsx':
                        self.assertIn('C1: 42', text); self.assertIn('A3: 3', text); self.assertIn('=NOW()', text)
                    self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original)

    def test_repeated_nonempty_odf_cells_are_bounded(self):
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'bad.ods'; fixture(source, 'ods', True); target = source.with_suffix('.fb2')
            with self.assertRaises(c.ConversionError): c.convert_book(source, target)
            self.assertFalse(target.exists())

    def test_external_slide_is_rejected_without_partial_output(self):
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'external.pptx'; target = source.with_suffix('.epub')
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr('ppt/presentation.xml', f'<p:presentation xmlns:p="{P}" xmlns:r="{R}"><p:sldIdLst><p:sldId r:id="s"/></p:sldIdLst></p:presentation>')
                z.writestr('ppt/_rels/presentation.xml.rels', f'<Relationships xmlns="{PR}"><Relationship Id="s" TargetMode="External" Target="https://example.invalid/secret"/></Relationships>')
            with self.assertRaises(c.ConversionError): c.convert_book(source, target)
            self.assertFalse(target.exists())


if __name__ == '__main__': unittest.main()

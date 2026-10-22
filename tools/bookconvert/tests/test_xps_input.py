"""Actual Windows XPS rendering, page identity and rejected external markup."""
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

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('xps_conversion_api', ROOT / 'convert_book.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
TOOLS = Path(os.environ.get('HOMELIB_TEST_TOOLS', ROOT.parents[1] / 'Program/Out/Bin64/tools'))
NS = 'http://schemas.microsoft.com/xps/2005/06'


def fixture(path, extra=''):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                   ''.join('<Default Extension="' + suffix + '" ContentType="application/vnd.ms-package.xps-' + kind + '+xml"/>'
                           for suffix, kind in [('fdseq','fixeddocumentsequence'),('fdoc','fixeddocument'),('fpage','fixedpage')]) +
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/></Types>')
        z.writestr('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="R" Type="' + NS + '/fixedrepresentation" Target="book.fdseq"/></Relationships>')
        z.writestr('book.fdseq', '<FixedDocumentSequence xmlns="' + NS + '"><DocumentReference Source="book.fdoc"/></FixedDocumentSequence>')
        z.writestr('book.fdoc', '<FixedDocument xmlns="' + NS + '"><PageContent Source="1.fpage"/><PageContent Source="2.fpage"/></FixedDocument>')
        for index, color in enumerate(['#FF2050B0','#FFB03020'], 1):
            z.writestr(str(index) + '.fpage', '<FixedPage xmlns="' + NS + '" Width="300" Height="400" xml:lang="en-US"><Path Fill="' + color + '" Data="M 20,20 L 280,20 280,380 20,380 Z"/>' + extra + '</FixedPage>')


def middle_pixel(png):
    at = 8; compressed = bytearray()
    while at < len(png):
        size = int.from_bytes(png[at:at+4], 'big'); kind = png[at+4:at+8]; data = png[at+8:at+8+size]
        if kind == b'IHDR': width,height,depth,color,*_ = struct.unpack('>IIBBBBB',data)
        elif kind == b'IDAT': compressed.extend(data)
        at += size + 12
    if depth != 8 or color not in {2,6}: raise AssertionError('Unexpected native PNG layout')
    bpp = 4 if color == 6 else 3; stride = width*bpp
    data = zlib.decompress(compressed); previous = bytearray(stride)
    for y in range(height//2+1):
        method = data[y*(stride+1)]; row = bytearray(data[y*(stride+1)+1:(y+1)*(stride+1)])
        for x in range(stride):
            a = row[x-bpp] if x >= bpp else 0; b = previous[x]; upper_left = previous[x-bpp] if x >= bpp else 0
            if method == 1: row[x] = (row[x]+a)&255
            elif method == 2: row[x] = (row[x]+b)&255
            elif method == 3: row[x] = (row[x]+(a+b)//2)&255
            elif method == 4:
                p=a+b-upper_left; distances=[abs(p-a),abs(p-b),abs(p-upper_left)]
                row[x] = (row[x]+[a,b,upper_left][distances.index(min(distances))])&255
            elif method != 0: raise AssertionError('Unexpected PNG filter')
        previous = row
    return tuple(previous[(width//2)*bpp:(width//2)*bpp+3])


class XpsInput(unittest.TestCase):
    def setUp(self): self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()

    def test_real_renderer_both_outputs_preserve_page_order_colors_and_original(self):
        source = self.root / 'wrong.unknown'; fixture(source)
        original = source.read_bytes(); self.assertEqual(c.detect_input(source), '.xps')
        results = []
        for extension in ['.epub','.fb2']:
            output = self.root / ('output' + extension)
            report = c.convert_book(source, output, tools_root=TOOLS)
            self.assertTrue(any('XPS' in warning for warning in report['warnings']))
            if extension == '.epub':
                with zipfile.ZipFile(output) as z:
                    body = ET.fromstring(z.read('OEBPS/book.xhtml'))
                    images = {name:z.read(name) for name in z.namelist() if '/images/' in name}
                    ordered = [images['OEBPS/' + node.get('src')] for node in body.iter() if c.tag(node) == 'img']
            else:
                body = ET.parse(output).getroot()
                images = {node.get('id'):base64.b64decode(node.text) for node in body if c.tag(node) == 'binary'}
                ordered = [images[node.get('{' + c.XL + '}href')[1:]] for node in body.iter() if c.tag(node) == 'image']
            self.assertEqual(len(ordered), 2)
            self.assertIn('Страница 2', ''.join(body.itertext()))
            results.append([hashlib.sha256(data).hexdigest() for data in ordered])
            # Independently decode PNG filters using only the standard library.
            for data, expected in zip(ordered,[(32,80,176),(176,48,32)]):
                self.assertEqual(middle_pixel(data), expected)
            self.assertEqual(source.read_bytes(), original)
        self.assertEqual(results[0], results[1])
        self.assertFalse(list(self.root.glob('homelib-xps-*')))

    def test_external_resources_and_arbitrary_markup_do_not_publish(self):
        for index, extra in enumerate([
            '<Path><Path.Fill><ImageBrush ImageSource="https://invalid.example/image.png"/></Path.Fill></Path>',
            '<ObjectDataProvider xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/>',
            '<Canvas RenderTransform="{x:Static Something}" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>'
        ]):
            source = self.root / ('reject' + str(index) + '.xps'); fixture(source, extra)
            output = self.root / ('reject' + str(index) + '.epub')
            with self.assertRaises(c.ConversionError): c.convert_book(source, output, tools_root=TOOLS)
            self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob('homelib-xps-*')))

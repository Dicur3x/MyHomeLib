"""Full image books: all TIFF frames, comic order, actual WebP and source identity."""
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

from test_xps_input import middle_pixel

ROOT = Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('image_converter',ROOT/'convert_book.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
spec=importlib.util.spec_from_file_location('image_fixed',ROOT/'fixed_layout.py')
fixed=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixed)
TOOLS=Path(os.environ.get('HOMELIB_TEST_TOOLS',ROOT.parents[1]/'Program/Out/Bin64/tools'))


def tiff():
    result=bytearray(b'II*\0'+struct.pack('<I',8))
    for index,color in enumerate([(32,80,176),(176,48,32)]):
        at=8+index*144
        entries=[(256,4,1,2),(257,4,1,2),(258,3,3,at+126),(259,3,1,1),(262,3,1,2),
                 (273,4,1,at+132),(277,3,1,3),(278,4,1,2),(279,4,1,12),(284,3,1,1)]
        result.extend(struct.pack('<H',len(entries)))
        for tag,kind,count,value in entries:result.extend(struct.pack('<HHII',tag,kind,count,value))
        result.extend(struct.pack('<I',at+144 if index==0 else 0))
        result.extend(struct.pack('<HHH',8,8,8));result.extend(bytes(color)*4)
    return bytes(result)


class ImageInput(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def images(self,source,extension):
        output=self.root/('output'+extension)
        before=hashlib.sha256(source.read_bytes()).hexdigest()
        report=c.convert_book(source,output,tools_root=TOOLS)
        self.assertTrue(report['warnings'])
        self.assertEqual(before,hashlib.sha256(source.read_bytes()).hexdigest())
        if extension=='.epub':
            with zipfile.ZipFile(output) as z:
                body=ET.fromstring(z.read('OEBPS/book.xhtml'))
                result=[z.read('OEBPS/'+n.get('src')) for n in body.iter() if c.tag(n)=='img']
        else:
            body=ET.parse(output).getroot()
            images={n.get('id'):base64.b64decode(n.text) for n in body if c.tag(n)=='binary'}
            result=[images[n.get('{'+c.XL+'}href')[1:]] for n in body.iter() if c.tag(n)=='image']
        output.unlink();return result

    def test_all_tiff_frames_and_unknown_suffix(self):
        source=self.root/'wrong.unknown';source.write_bytes(tiff())
        for extension in ['.fb2','.epub']:
            images=self.images(source,extension);self.assertEqual(len(images),2)
            self.assertEqual([middle_pixel(p) for p in images],[(32,80,176),(176,48,32)])
        self.assertFalse(list(self.root.glob('homelib-xps-*')))

    def test_comic_numeric_order_and_exact_png_resources(self):
        source=self.root/'wrong.dat'
        colors=[(30,60,90),(90,60,30),(60,90,30)]
        pages=[fixed.png(bytes(rgb)*4,2,2) for rgb in colors]
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
            for name,data in zip(['10.png','1.png','2.png'],pages):z.writestr(name,data)
            z.writestr('ComicInfo.xml','<ComicInfo/>')
        self.assertEqual(c.detect_input(source),'.cbz')
        for extension in ['.epub','.fb2']:
            self.assertEqual(self.images(source,extension),[pages[1],pages[2],pages[0]])

    def test_webp_uses_actual_native_decoder_and_retains_alpha(self):
        source=self.root/'image.webp'
        source.write_bytes(base64.b64decode('UklGRjoAAABXRUJQVlA4TC4AAAAvAUAAEB8gJCBTshFGEAsmkcyfsFtIQBgm+79GFggQkqQ4sh4Eqt45foAQ0f8I'))
        images=self.images(source,'.epub');self.assertEqual(len(images),1)
        self.assertEqual(images[0][:8],b'\x89PNG\r\n\x1a\n');self.assertEqual(images[0][25],6)
        at=8;compressed=bytearray()
        while at<len(images[0]):
            size=int.from_bytes(images[0][at:at+4],'big')
            if images[0][at+4:at+8]==b'IDAT':compressed.extend(images[0][at+8:at+8+size])
            at+=size+12
        raw=zlib.decompress(compressed)
        self.assertEqual([raw[4],raw[8],raw[13],raw[17]],[0,128,255,80])

    def test_comic_rejects_other_documents_and_ambiguous_names(self):
        for index,name in enumerate(['../page.png','notes.txt']):
            source=self.root/('reject'+str(index)+'.cbz')
            with zipfile.ZipFile(source,'w') as z:z.writestr('1.png',fixed.png(bytes([20,40,60])*4,2,2));z.writestr(name,b'foreign')
            output=self.root/('reject'+str(index)+'.epub')
            with self.assertRaises(c.ConversionError):c.convert_book(source,output,tools_root=TOOLS)
            self.assertFalse(output.exists())

"""Independent baseline JPEG strips: restart boundaries, all pages, native decode."""
import importlib.util
import base64
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

import test_image_input as fixture
from test_xps_input import middle_pixel

ROOT,TOOLS=fixture.ROOT,fixture.TOOLS

spec=importlib.util.spec_from_file_location('tiff_jpeg_test',ROOT/'tiff_jpeg.py')
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)


def jpeg_tiff(pages=1):
    def segment(marker,data):return b'\xff'+bytes([marker])+struct.pack('>H',len(data)+2)+data
    # Quantization=1; DC category 0 uses code 0, category 8 uses code 10.
    # AC EOB uses code 0. These two complete strips decode to gray 128 and 144.
    tables=b'\xff\xd8'+segment(0xdb,b'\0'+bytes([1])*64)
    tables+=segment(0xc4,b'\0'+bytes([1,1])+bytes(14)+bytes([0,8])+b'\x10'+bytes([1])+bytes(15)+b'\0')+b'\xff\xd9'
    header=b'\xff\xd8'+segment(0xc0,bytes([8])+struct.pack('>HH',8,8)+b'\x01\x01\x11\0')
    header+=segment(0xda,b'\x01\x01\0\0\x3f\0')
    strips=[header+b'\x3f\xff\xd9',header+b'\xa0\x1f\xff\xd9']
    start=8+pages*(2+11*12+4);table_at=start+16*pages;pixels=table_at+len(tables)
    data=b'II*\0'+struct.pack('<I',8)
    for page in range(pages):
        entries=[(256,4,1,8),(257,4,1,16),(258,3,1,8),(259,3,1,7),(262,3,1,1),
                 (273,4,2,start+16*page),(277,3,1,1),(278,4,1,8),(279,4,2,start+16*page+8),(284,3,1,1),(347,7,len(tables),table_at)]
        data+=struct.pack('<H',len(entries))+b''.join(struct.pack('<HHII',*e) for e in entries)
        data+=struct.pack('<I',8+(page+1)*138 if page+1<pages else 0)
    for page in range(pages):
        offsets=[pixels,pixels+len(strips[0])];sizes=list(map(len,strips))
        if page%2:offsets.reverse();sizes.reverse()
        data+=struct.pack('<IIII',*offsets,*sizes)
    return data+tables+b''.join(strips)


class TiffJpeg(unittest.TestCase):
    # Reuse source/result validation, without rerunning the image base suite.
    setUp=fixture.ImageInput.setUp
    tearDown=fixture.ImageInput.tearDown
    images=fixture.ImageInput.images
    def test_joined_strips_decode_in_native_renderer_without_recompression(self):
        source=self.root/'strips.tif';source.write_bytes(jpeg_tiff())
        expected_count,prepared=t.pages(source,256*1024*1024)
        prepared=list(prepared);self.assertEqual(expected_count,1)
        self.assertIn(b'\xff\xdd\x00\x04\x00\x01',prepared[0])
        self.assertIn(b'\x3f\xff\xd0\xa0\x1f',prepared[0])
        picture=self.root/'joined.jpg';picture.write_bytes(prepared[0]);output=self.root/'decoded.zip'
        subprocess.run([str(TOOLS/'xps/HomeLibXps.exe'),'--image-pages',str(picture),str(output)],
                       check=True,capture_output=True,timeout=15,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        with zipfile.ZipFile(output) as archive:png=archive.read('00001.png')
        self.assertEqual(middle_pixel(png,True),(128,128,128))
        self.assertEqual(middle_pixel(png),(144,144,144))
        for extension in ['.fb2','.epub']:
            self.assertEqual(self.images(source,extension),prepared)

    def test_cyclic_and_truncated_tiff_do_not_publish_partial_layout(self):
        damaged=bytearray(jpeg_tiff());struct.pack_into('<I',damaged,8+2+11*12,8)
        with self.assertRaises(ValueError):t.plans(damaged)
        with self.assertRaises(ValueError):t.plans(jpeg_tiff()[:-1])

    def test_all_jpeg_tiff_frames_keep_distinct_page_order(self):
        source=self.root/'две страницы.tiff';source.write_bytes(jpeg_tiff(2))
        count,pictures=t.pages(source,256*1024*1024);pictures=list(pictures)
        self.assertEqual(count,2);self.assertNotEqual(pictures[0],pictures[1])
        for extension in ['.fb2','.epub']:
            self.assertEqual(self.images(source,extension),pictures)

    def test_large_fb2_reading_preparation_keeps_the_ordinary_input_limit(self):
        source=self.root/'large.fb2';output=self.root/'large.epub'
        picture=fixture.fixed.png(bytes([30,60,90])*4,2,2)
        with source.open('wb') as stream:
            stream.write(('<FictionBook xmlns="'+fixture.c.FB+'" xmlns:l="'+fixture.c.XL+'">'
                '<description><title-info><book-title>Large image FB2</book-title><lang>ru</lang></title-info></description>'
                '<body><section><p>Visible text</p><image l:href="#one"/></section></body>'
                '<binary id="one" content-type="image/png">').encode())
            stream.write(base64.b64encode(picture))
            for _ in range(65):stream.write(b' '*1024*1024)
            stream.write(b'</binary></FictionBook>')
        with self.assertRaises(fixture.c.ConversionError):fixture.c.convert_book(source,output,tools_root=TOOLS)
        self.assertFalse(output.exists())
        fixture.c.convert_book(source,output,tools_root=TOOLS,reading=True)
        with zipfile.ZipFile(output) as archive:
            image=next(n for n in archive.namelist() if n.endswith('.png'))
            self.assertEqual(archive.read(image),picture)
            self.assertIn(b'Visible text',archive.read('OEBPS/body-1.xhtml'))

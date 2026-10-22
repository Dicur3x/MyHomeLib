"""HA CRC/bounds, upstream compressed vector, DOC handoff and exact originals."""
from pathlib import Path
import importlib.util
import os
import struct
import tempfile
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location('ha_test_'+name,ROOT/(name+'.py'))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
c=module('convert_book');ha=module('ha_input')
TOOLS=Path(os.environ.get('HOMELIB_TEST_TOOLS',ROOT.parents[1]/'Program/Out/Bin64/tools'))


def stored(name,data):
    return b'HA\x01\0'+struct.pack('<BIIII',32,len(data),len(data),zlib.crc32(data),0)+b'\0'+name.encode()+b'\0\0'+data


class HaInput(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def test_upstream_asc_vector_and_crc(self):
        data=(ROOT/'tests/fixtures/ha-asc-apache-license.ha').read_bytes()
        entry=ha.entries(data)[0];raw=ha.unpack(data,entry)
        self.assertEqual(len(raw),11357);self.assertIn(b'Apache License',raw)
        bad=bytearray(data);bad[-8]^=1
        with self.assertRaises(ValueError):ha.unpack(bytes(bad),ha.entries(bytes(bad))[0])
    def test_stored_text_both_formats_unknown_extension_and_no_leftovers(self):
        source=self.root/'book.unknown'
        for index,name in enumerate(['book.txt','book.unknown','book.wrong.pdf','12345']):
            data=stored(name,b'Complete original English text. Last sentence.');source.write_bytes(data)
            self.assertEqual(c.detect_input(source),'.ha')
            for ext in ['.epub','.fb2']:
                output=self.root/('result'+str(index)+ext);report=c.convert_book(source,output,tools_root=TOOLS)
                self.assertTrue(any('CRC32' in warning for warning in report['warnings']))
                self.assertEqual(source.read_bytes(),data);self.assertGreater(output.stat().st_size,100)
        self.assertFalse(list(self.root.glob('homelib-ha-*')))
    def test_second_book_with_unknown_name_cannot_be_discarded(self):
        one=stored('one.txt',b'First complete book.');two=stored('12345',b'Second complete book.')
        source=self.root/'two.ha';source.write_bytes(b'HA\x02\0'+one[4:]+two[4:]);output=self.root/'result.epub'
        with self.assertRaisesRegex(ValueError,'ровно одно'):c.convert_book(source,output,tools_root=TOOLS)
        self.assertFalse(output.exists());self.assertFalse(list(self.root.glob('homelib-ha-*')))
    def test_header_and_member_bounds_reject_without_output(self):
        for index,data in enumerate([b'HA\x01\0',stored('../book.txt',b'Text'),stored('book.txt',b'Text')[:-1]]):
            source=self.root/('bad'+str(index)+'.ha');source.write_bytes(data);output=self.root/(str(index)+'.epub')
            with self.assertRaises((ValueError,c.ConversionError)):c.convert_book(source,output,tools_root=TOOLS)
            self.assertFalse(output.exists())

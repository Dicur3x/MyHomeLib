"""GPL-3.0-only. Independent vectors and bounds for the isolated decoder."""
import ctypes
import io
import os
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'vendor'))
from calibre_legacy import native_api
from calibre_legacy import palm_crypto
from calibre_legacy.compat import LitError
from calibre_legacy.lrf.document import LRFDocument
from calibre_legacy.lrf.objects import Text

TOOLS=Path(os.environ.get('HOMELIB_TEST_TOOLS',ROOT.parents[1]/'Program/Out/Bin64/tools'))
LIBRARY=TOOLS/'bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll'


@unittest.skipUnless(os.name=='nt' and LIBRARY.is_file(),'bundled native legacy decoder')
class NativeLegacy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):native_api.configure(LIBRARY)

    def test_pc1_pinned_independent_vectors_both_directions(self):
        # Frozen from DeDRM_tools 7379b453's reviewed pure-Python PC1, not the
        # production C implementation or an encrypt/decrypt round-trip oracle.
        vectors=[(bytes(range(16)),bytes(range(64)),
            '24b76aabf590a267e35cb05eccf11fad1b6a95f1c6782451b2ac036a84ff538d5665fe0e94f06f7e0a9e167b2514cdd2205ff94cd74e7d65352fbef4a3015b46'),
            (b'0123456789ABCDEF',b'Container compatibility. Final sentence!',
            'a027d49f403c4c7ae409fe4e913356ddab1e94614a10d0b02f00a3f1baae258423008f85a80b15da')]
        for key,plain,encoded in vectors:
            with self.subTest(key=key):
                self.assertEqual(native_api.pc1(key,plain,False),bytes.fromhex(encoded))
                self.assertEqual(native_api.pc1(key,bytes.fromhex(encoded)),plain)

    def test_lit_specific_des_vector_and_native_bounds(self):
        native_api.msdes.deskey(bytes.fromhex('133457799bbcdff1'),0)
        cipher=native_api.msdes.des(bytes.fromhex('0123456789abcdef'))
        # LIT deliberately uses OpenCLit's substituted S boxes (spr.h), not
        # standard DES's 85e813540f0ab405 answer for this key/plaintext.
        self.assertEqual(cipher.hex(),'b95a0c9072207039')
        native_api.msdes.deskey(bytes.fromhex('133457799bbcdff1'),1)
        self.assertEqual(native_api.msdes.des(cipher).hex(),'0123456789abcdef')
        buffer=ctypes.create_string_buffer(32)
        self.assertNotEqual(native_api._library.hl_lzx(buffer,1,buffer,32,14),0)
        self.assertNotEqual(native_api._library.hl_des(buffer,buffer,buffer,7,0),0)
        self.assertNotEqual(native_api._library.hl_pc1(buffer,buffer,buffer,-1,1),0)
        with self.assertRaises(LitError):native_api.pc1(b'bad',b'input')
        native_api.lzx.init(15)
        with self.assertRaises(LitError):native_api.lzx.decompress(b'broken stream',32)

    def test_container_key_records_preserve_trailer_and_reject_wrong_key(self):
        key=b'0123456789ABCDEF';plain=b'Complete book text. Last sentence.';trailer=b'IDX\x84'
        header=bytearray(312)
        struct.pack_into('>HHIHHHH',header,0,1,0,len(plain),1,4096,2,0)
        header[16:20]=b'MOBI';struct.pack_into('>I',header,20,248)
        struct.pack_into('>I',header,104,6);struct.pack_into('>H',header,242,2)
        standard=bytes.fromhex('723833b0b4f2e3cadf0901d6e2e03f96');verify=0x10203040
        struct.pack_into('>IIII',header,168,264,1,48,0)
        cookie=struct.pack('>II',verify,1)+key+b'\0'*8
        struct.pack_into('>IIIBxxx32s',header,264,verify,48,0,sum(standard)&255,native_api.pc1(standard,cookie,False))
        palm=bytearray(94);palm[60:68]=b'BOOKMOBI';struct.pack_into('>H',palm,76,2)
        struct.pack_into('>II',palm,78,94,0);struct.pack_into('>II',palm,86,94+len(header),1)
        source=bytes(palm+header)+native_api.pc1(key,plain,False)+trailer
        result=palm_crypto.decode(source)
        self.assertEqual(result[94+len(header):],plain+trailer)
        self.assertEqual(result[94+12:94+14],b'\0\0')
        self.assertEqual(source[94+12:94+14],b'\0\2')
        damaged=bytearray(source);damaged[94+264+12]^=1
        with self.assertRaisesRegex(ValueError,'индивидуальный ключ'):palm_crypto.decode(bytes(damaged))
        damaged=bytearray(source);struct.pack_into('>I',damaged,94+168,0xfffffff0)
        with self.assertRaisesRegex(ValueError,'bounds'):palm_crypto.decode(bytes(damaged))


class LegacyBounds(unittest.TestCase):
    def test_lrf_final_untagged_text_is_not_duplicated(self):
        class Style:
            def as_dict(self):return {}
        class Document:objects={7:Style()}
        node=Text.__new__(Text);node._document=Document();node.style_id=7
        # Literal run followed by the final untagged UTF16 tail.
        beginning='First text '.encode('utf-16-le');tail='Final sentence.'.encode('utf-16-le')
        node.stream=b'\xcc\xf5'+struct.pack('<H',len(beginning))+beginning+tail
        node.initialize()
        self.assertEqual(str(node),'First text Final sentence.')

    def test_lrf_object_index_rejects_duplicate_id_overlap_and_wrong_tag_id(self):
        # Small independent LRF index; validation occurs before object parsing.
        for count,offset in [(0,88),(20001,88),(1,0xfffffff0)]:
            header=bytearray(88);header[:8]=b'L\0R\0F\0\0\0';struct.pack_into('<H',header,8,1000)
            struct.pack_into('<QQ',header,16,count,offset)
            with self.assertRaises(ValueError):LRFDocument(io.BytesIO(header))
        class ObjectFixture:
            number_of_objects=2;object_index_offset=108;keep_parsing=True;_size=140
            def _parse_object(self,object_id,stream,size):self.objects[object_id]=object()
        for index in [[(7,88,10,0),(7,98,10,0)],[(7,88,16,0),(8,98,10,0)],[(7,88,30,0),(8,98,10,0)]]:
            fixture=ObjectFixture();fixture._file=io.BytesIO(b'\0'*108+b''.join(struct.pack('<IIII',*row) for row in index))
            with self.assertRaises(ValueError):LRFDocument._parse_objects(fixture)

    def test_palm_table_and_trailer_bounds_fail_without_native_loading(self):
        for data in [b'BOOKMOBI',b'\0'*86]:
            with self.assertRaises(ValueError):palm_crypto.decode(data)
        for data,flags in [(b'',2),(b'\xff',2),(b'\x80',2),(b'\x03',1)]:
            with self.assertRaises(ValueError):palm_crypto.trailing_size(data,flags)


if __name__=='__main__':unittest.main()

"""First-page XPS preview through the native catalogue helper, on owned G: data."""
from pathlib import Path
import ctypes
from ctypes import wintypes
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile

from test_xps_input import fixture, middle_pixel

STAGE = Path(os.environ.get('HL_XPS_COVER_STAGE', 'G:/HL-b14-external/xps-cover-native'))
BINARY = Path(os.environ.get('HL_XPS_COVER_BINARY', ''))
HELPER = Path(os.environ.get('HL_XPS_COVER_HELPER', ''))
FAKE = Path(os.environ.get('HL_XPS_COVER_FAKE', ''))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class NativeXpsCover(unittest.TestCase):
    def setUp(self):
        if os.name != 'nt': self.skipTest('Windows rendering required')
        if not os.environ.get('HL_XPS_COVER_BINARY'): self.skipTest('Native preview driver not configured')
        self.assertTrue(STAGE.resolve().is_relative_to(Path('G:/HL-b14-external').resolve()))
        self.assertTrue(BINARY.is_file() and HELPER.is_file() and FAKE.is_file())
        STAGE.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='HomeLibRu-native-', dir=STAGE)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.exe = self.root/'XpsCoverTest.exe'
        shutil.copyfile(BINARY, self.exe)
        for name in ['uselocaldata', 'uselocaltemp']: (self.root/name).touch()
        (self.root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')

    def run_native(self, source, mode='cover', helper=HELPER):
        before = sha(source)
        (self.root/'request.json').write_text(json.dumps(dict(mode=mode, tool=str(helper), source=str(source))), encoding='utf-8')
        result = subprocess.run([str(self.exe)], cwd=self.root, timeout=40,
            env={**os.environ, 'TEMP':str(self.root), 'TMP':str(self.root)},
            creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8', errors='replace')+result.stderr.decode('utf-8', errors='replace'))
        report = json.loads((self.root/'result.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(report['status'], 'PASS')
        self.assertEqual(before, sha(source), 'preview changed its source')
        self.assertFalse(list((self.root/'Temp').iterdir()), 'preview left temporary output')
        return report

    def test_real_cover_renders_only_first_page_with_expected_pixels(self):
        source = self.root/'Книга с пробелом # %.xps'; fixture(source)
        self.run_native(source)
        png = (self.root/'cover.png').read_bytes()
        self.assertEqual(struct.unpack('>II', png[16:24]), (450,600))
        self.assertEqual(middle_pixel(png), (32,80,176))

    def test_legacy_full_render_still_has_two_pages(self):
        source = self.root/'ordinary.xps'; fixture(source); before = sha(source)
        target = self.root/'full.zip'
        result = subprocess.run([str(HELPER), str(source), str(target)], timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        with zipfile.ZipFile(target) as z:
            self.assertEqual(z.namelist(), ['00001.png','00002.png'])
            self.assertEqual([middle_pixel(z.read(n)) for n in z.namelist()], [(32,80,176),(176,48,32)])
        self.assertEqual(before, sha(source))

    def test_missing_optional_module_explains_without_installing(self):
        source = self.root/'book.xps'; fixture(source)
        report = self.run_native(source, 'reject', self.root/'not-installed.exe')
        self.assertIn('модуль', report['message'])
        self.assertFalse((self.root/'cover.png').exists())

    def test_active_markup_on_later_page_is_rejected_too(self):
        source = self.root/'unsafe.xps'; fixture(source)
        with zipfile.ZipFile(source) as z: entries = {n:z.read(n) for n in z.namelist()}
        entries['2.fpage'] = entries['2.fpage'].replace(b'</FixedPage>', b'<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/></FixedPage>')
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
            for n,v in entries.items(): z.writestr(n,v)
        self.assertTrue(self.run_native(source, 'reject')['failed'])
        self.assertFalse((self.root/'cover.png').exists())

    def test_truncated_xps_is_rejected_and_cleaned(self):
        source = self.root/'broken.xps'; source.write_bytes(b'PK\x03\x04broken')
        self.assertTrue(self.run_native(source, 'reject')['failed'])

    def test_oxps_cover_and_full_conversion_preserve_first_page_and_order(self):
        source=self.root/'Книга с пробелом # %.oxps'
        fixture(source, namespace='http://schemas.openxps.org/oxps/v1.0')
        self.run_native(source)
        png=(self.root/'cover.png').read_bytes()
        self.assertEqual(struct.unpack('>II',png[16:24]),(450,600))
        self.assertEqual(middle_pixel(png),(32,80,176))
        target=self.root/'all-pages.zip';before=sha(source)
        result=subprocess.run([str(HELPER),str(source),str(target)],timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        with zipfile.ZipFile(target) as z:
            self.assertEqual(z.namelist(),['00001.png','00002.png'])
            self.assertEqual([middle_pixel(z.read(n)) for n in z.namelist()],[(32,80,176),(176,48,32)])
        self.assertEqual(before,sha(source))

    def test_oxps_resource_dictionary_is_resolved_in_the_normalized_package(self):
        ns='http://schemas.openxps.org/oxps/v1.0';source=self.root/'dictionary.oxps'
        fixture(source,namespace=ns)
        with zipfile.ZipFile(source) as z:entries={n:z.read(n) for n in z.namelist()}
        entries['1.fpage']=('<FixedPage xmlns="'+ns+'" xmlns:x="'+ns+'/resourcedictionary-key" Width="300" Height="400" xml:lang="en-US"><FixedPage.Resources><ResourceDictionary><SolidColorBrush x:Key="cover" Color="#FF2050B0"/></ResourceDictionary></FixedPage.Resources><Path Fill="{StaticResource cover}" Data="M 0,0 L 300,0 300,400 0,400 Z"/></FixedPage>').encode()
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
            for n,v in entries.items():z.writestr(n,v)
        self.run_native(source)
        self.assertEqual(middle_pixel((self.root/'cover.png').read_bytes()),(32,80,176))

    def resource_book(self,source,part,payload,mime,body,namespace='http://schemas.openxps.org/oxps/v1.0'):
        fixture(source,namespace=namespace)
        with zipfile.ZipFile(source) as z:entries={n:z.read(n) for n in z.namelist()}
        entries['[Content_Types].xml']=entries['[Content_Types].xml'].replace(b'</Types>',
            ('<Override PartName="/'+part+'" ContentType="'+mime+'"/></Types>').encode())
        entries['1.fpage']=('<FixedPage xmlns="'+namespace+'" Width="300" Height="400" xml:lang="en-US">'+body+'</FixedPage>').encode()
        entries['_rels/1.fpage.rels']=('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="resource" Type="'+namespace+'/required-resource" Target="'+part+'"/></Relationships>').encode()
        entries[part]=payload
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
            for n,v in entries.items():z.writestr(n,v)

    def test_oxps_embedded_png_and_jpeg_xr_keep_their_pixels(self):
        from PIL import Image
        jxr=Path(os.environ['HL_XPS_JXR'])
        png=io.BytesIO();Image.new('RGB',(24,32),(32,80,176)).save(png,format='PNG')
        for suffix,mime,payload in [('png','image/png',png.getvalue()),('jxr','image/vnd.ms-photo',jxr.read_bytes())]:
            with self.subTest(kind=suffix):
                source=self.root/('picture-'+suffix+'.oxps');part='Resources/cover.'+suffix
                body='<Path Data="M 0,0 L 300,0 300,400 0,400 Z"><Path.Fill><ImageBrush ImageSource="'+part+'" Viewbox="0,0,24,32" Viewport="0,0,300,400" ViewboxUnits="Absolute" ViewportUnits="Absolute"/></Path.Fill></Path>'
                self.resource_book(source,part,payload,mime,body)
                self.run_native(source)
                self.assertEqual(middle_pixel((self.root/'cover.png').read_bytes()),(32,80,176))

    def test_oxps_embedded_font_glyphs_match_the_xps_shape(self):
        from PIL import Image
        font=Path(os.environ['HL_XPS_FONT']);before=sha(font);masks=[]
        for extension,namespace in [('oxps','http://schemas.openxps.org/oxps/v1.0'),('xps','http://schemas.microsoft.com/xps/2005/06')]:
            source=self.root/('glyph.'+extension)
            self.resource_book(source,'Resources/font.ttf',font.read_bytes(),'application/vnd.ms-opentype',
                '<Glyphs Fill="#FF000000" FontUri="Resources/font.ttf" FontRenderingEmSize="100" OriginX="90" OriginY="270" UnicodeString="A"/>',namespace)
            self.run_native(source)
            with Image.open(self.root/'cover.png') as picture:
                raw=picture.convert('RGB').tobytes();pixels=zip(raw[0::3],raw[1::3],raw[2::3])
            mask={i for i,pixel in enumerate(pixels) if max(pixel)<128};self.assertGreater(len(mask),500);masks.append(mask)
        self.assertGreater(len(masks[0]&masks[1])/len(masks[0]|masks[1]),.95)
        self.assertEqual(before,sha(font))

    def test_missing_openxps_windows_api_has_a_specific_explanation(self):
        source=self.root/'api-unavailable.oxps';fixture(source,namespace='http://schemas.openxps.org/oxps/v1.0')
        report=self.run_native(source,'reject',FAKE)
        self.assertIn('Windows 8',report['message'])

    def test_oxps_later_active_markup_and_external_relationships_are_rejected(self):
        ns='http://schemas.openxps.org/oxps/v1.0'
        for i,change in enumerate(['active','external','page-limit']):
            source=self.root/('reject-'+str(i)+'.oxps');fixture(source,namespace=ns)
            with zipfile.ZipFile(source) as z:entries={n:z.read(n) for n in z.namelist()}
            if change=='active':entries['2.fpage']=entries['2.fpage'].replace(b'</FixedPage>',b'<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/></FixedPage>')
            elif change=='external':entries['_rels/.rels']=entries['_rels/.rels'].replace(b'Target="book.fdseq"',b'Target="https://invalid.example/remote.fdseq"')
            else:entries['book.fdoc']=('<FixedDocument xmlns="'+ns+'">'+'<PageContent Source="1.fpage"/>'*5001+'</FixedDocument>').encode()
            with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
                for n,v in entries.items():z.writestr(n,v)
            self.assertTrue(self.run_native(source,'reject')['failed'])

    def test_oxps_later_page_is_not_prepared_for_cover_rendering(self):
        source=self.root/'later.oxps';fixture(source,namespace='http://schemas.openxps.org/oxps/v1.0')
        with zipfile.ZipFile(source) as z:entries={n:z.read(n) for n in z.namelist()}
        # Valid XML in the permitted namespace, but impossible page dimensions.
        # The first-page request must not materialize/render this later page.
        entries['2.fpage']=entries['2.fpage'].replace(b'Width="300"',b'Width="NaN"')
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
            for n,v in entries.items():z.writestr(n,v)
        self.run_native(source)
        self.assertEqual(middle_pixel((self.root/'cover.png').read_bytes()),(32,80,176))

    def test_unexpected_helper_page_bundle_is_rejected(self):
        source = self.root/'two-pages.zip'
        with zipfile.ZipFile(source,'w') as z:
            z.writestr('00001.png', b'first'); z.writestr('00002.png', b'second')
        self.assertTrue(self.run_native(source, 'reject', FAKE)['failed'])

    def test_oversized_helper_image_is_rejected(self):
        source = self.root/'large.zip'
        with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z: z.writestr('00001.png', b'x'*(2*1024*1024+1))
        self.assertTrue(self.run_native(source, 'reject', FAKE)['failed'])

    def test_crc_mismatch_is_rejected(self):
        source = self.root/'bad-crc.zip'
        with zipfile.ZipFile(source,'w') as z: z.writestr('00001.png', b'known-cover-payload')
        source.write_bytes(source.read_bytes().replace(b'known-cover-payload',b'wrong-cover-payload'))
        self.assertTrue(self.run_native(source, 'reject', FAKE)['failed'])

    def test_cancel_terminates_started_helper_and_cleans_output(self):
        source = self.root/'wait-source.xps'; fixture(source)
        self.assertTrue(self.run_native(source, 'cancel', FAKE)['canceled'])
        pid_file = Path(str(source)+'.pid')
        self.assertTrue(pid_file.is_file(), 'helper never started')
        pid = int(pid_file.read_text())
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        handle = kernel.OpenProcess(0x1000, False, pid)
        if handle:
            try:
                code = wintypes.DWORD()
                kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
                self.assertTrue(kernel.GetExitCodeProcess(handle,ctypes.byref(code)))
                self.assertNotEqual(code.value,259,'canceled decoder remains alive')
            finally:
                kernel.CloseHandle.argtypes = [wintypes.HANDLE]; kernel.CloseHandle(handle)


if __name__ == '__main__': unittest.main()

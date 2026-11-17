"""First-page XPS preview through the native catalogue helper, on owned G: data."""
from pathlib import Path
import ctypes
from ctypes import wintypes
import hashlib
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

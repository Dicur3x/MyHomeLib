"""A Windows status reader cannot abort the measured native operation."""
import ctypes
import json
import os
from pathlib import Path
import unittest

from benchmark_native_collection_transfer_completion import publish_progress
from pack_collection import temporary_work_directory


@unittest.skipUnless(os.name == 'nt', 'Windows sharing contract')
class BenchmarkProgressTests(unittest.TestCase):
    def test_locked_status_keeps_previous_json_then_publishes_after_reader_closes(self):
        with temporary_work_directory(Path('G:/HL-b14-external'), 'HomeLibre-progress-') as directory:
            stage = Path(directory); path = stage/'progress.json'
            path.write_text('{"previous": true}', encoding='utf-8')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,
                                           ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = kernel.CreateFileW(str(path),0x80000000,3,None,3,0,None)
            self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
            report = dict(status='INCOMPLETE',native_pid=12345)
            try:
                self.assertFalse(publish_progress(stage, report))
                self.assertEqual(json.loads(path.read_text()), {'previous':True})
                self.assertEqual(report['deferred_progress_writes'],1)
            finally: kernel.CloseHandle(handle)
            self.assertTrue(publish_progress(stage, report))
            self.assertEqual(json.loads(path.read_text()),report)

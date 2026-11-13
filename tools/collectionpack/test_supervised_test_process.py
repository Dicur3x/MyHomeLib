"""Contain only owned test children; preserve output, exit code and timeout."""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from pack_collection import temporary_work_directory
from supervised_test_process import run_owned


@unittest.skipUnless(os.name == 'nt', 'Windows Job Object regression')
class SupervisedTestProcessTests(unittest.TestCase):
    def test_output_and_nonzero_exit_are_preserved(self):
        result = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', '-c',
            "import sys; print('Текст ё'); print('Ошибка',file=sys.stderr); sys.exit(73)"],
            capture_output=True, encoding='utf-8', timeout=15)
        self.assertEqual((result.returncode, result.stdout.strip(), result.stderr.strip()),
                         (73, 'Текст ё', 'Ошибка'))

    def test_timeout_reaps_a_grandchild_before_its_locked_file_is_removed(self):
        with temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-owned-process-') as root:
            pid_file, held = root / 'child.pid', root / 'held.bin'
            child = "import time; f=open(" + repr(str(held)) + ", 'wb'); f.write(b'owned'); f.flush(); time.sleep(60)"
            parent = ('import subprocess,sys,time; from pathlib import Path; '
                      'p=subprocess.Popen([sys.executable,"-I","-B","-c",' + repr(child) + ']); '
                      'Path(' + repr(str(pid_file)) + ').write_text(str(p.pid)); time.sleep(60)')
            with self.assertRaises(subprocess.TimeoutExpired):
                run_owned([sys.executable, '-I', '-B', '-c', parent],
                          capture_output=True, encoding='utf-8', timeout=5)
            self.assertTrue(pid_file.is_file(), 'The child must really have started')
            self.assertEqual(held.read_bytes(), b'owned')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
            kernel.OpenProcess.restype = ctypes.c_void_p
            kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = kernel.OpenProcess(0x100000, False, int(pid_file.read_text()))
            if handle:
                try:
                    self.assertEqual(kernel.WaitForSingleObject(handle, 0), 0)
                finally:
                    kernel.CloseHandle(handle)
            held.unlink()  # The process must no longer keep this file open.

    def test_unsigned_windows_failure_code_is_not_replaced_by_the_launcher(self):
        result = run_owned([sys.executable, '-I', '-B', '-c',
                           'import ctypes; ctypes.windll.kernel32.ExitProcess(0xC0000005)'],
                          capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0xC0000005)

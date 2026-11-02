"""Actual CLI/helper observations, without changing conversion results."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'convert_book.py'


class ComponentUsageReportTests(unittest.TestCase):
    def test_plain_cli_report_does_not_claim_unused_image_or_format_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target, report = root/'book.fb2', root/'book.epub', root/'report.json'
            source.write_text('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
                              '<description><title-info><genre>prose</genre><book-title>Usage</book-title>'
                              '<lang>en</lang></title-info></description><body><section>'
                              '<p>Readable original text.</p></section></body></FictionBook>', encoding='utf-8')
            original = source.read_bytes()
            completed = subprocess.run([sys.executable, '-I', '-B', str(MODULE), str(source), str(target),
                                        '--report', str(report), '--tools-root', str(root/'tools')],
                                       capture_output=True, text=True, encoding='utf-8', timeout=30)
            self.assertEqual(completed.returncode, 0, completed.stderr+completed.stdout)
            self.assertTrue(target.is_file())
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(json.loads(report.read_text('utf-8'))['used_tools'], [])

    @unittest.skipUnless(sys.platform == 'win32', 'Windows component packages contain EXE/DLL files')
    def test_real_child_process_and_loaded_dll_are_observed_but_external_paths_are_excluded(self):
        program = '''import ctypes, importlib.util, json, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location('conversion', sys.argv[1])
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
root = pathlib.Path(sys.executable).resolve().parent
used = c.observe_component_tools(root)
subprocess.run([sys.executable, '-I', '-B', '-c', 'pass'], check=True)
dll = next(root.glob('python3*.dll')).resolve()
ctypes.CDLL(str(dll))
ctypes.WinDLL('kernel32.dll')
sys.audit('ctypes.dlopen', None)
print(json.dumps({'used': sorted(used), 'expected': sorted({str(pathlib.Path(sys.executable).resolve()), str(dll)})}))
'''
        completed = subprocess.run([sys.executable, '-I', '-B', '-c', program, str(MODULE)],
                                   capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result['used'], result['expected'])


if __name__ == '__main__':
    unittest.main()

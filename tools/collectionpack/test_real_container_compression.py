"""Read-only-selected real books through isolated native and copy operations."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
import zipfile

from PIL import Image, ImageChops

from supervised_test_process import run_owned
import test_native_compression_operation as operations
import test_native_mislabeled_compression as mislabeled
import test_pack_collection as packing
from prepare_book_compression import verify_non_image_content

INPUTS = Path(os.environ['HL_REAL_CONTAINER_INPUTS']) if os.environ.get('HL_REAL_CONTAINER_INPUTS') else None
EVIDENCE = Path(os.environ['HL_REAL_CONTAINER_EVIDENCE']) if os.environ.get('HL_REAL_CONTAINER_EVIDENCE') else None


def selected(extension):
    inventory = json.loads(INPUTS.read_text(encoding='utf-8'))
    row = inventory['inputs'][extension]
    path = Path(row['path'])
    if (path.resolve().parent != INPUTS.resolve().parent or path.is_symlink() or
            path.name != 'input'+extension or not 0 < path.stat().st_size <= 16*1024**2):
        raise AssertionError('Use only the positively identified isolated input copy')
    body = path.read_bytes()
    assert len(body) == row['bytes']
    assert hashlib.sha256(body).hexdigest() == row['sha256']
    return path, body, row


def source_stamps_unchanged():
    inventory = json.loads(INPUTS.read_text(encoding='utf-8'))
    for row in inventory['inputs'].values():
        s = Path(row['source']).stat()
        assert dict(size=s.st_size, mtime_ns=s.st_mtime_ns, ino=s.st_ino) == row['source_stamp']


def evidence(key, value):
    previous = json.loads(EVIDENCE.read_text(encoding='utf-8')) if EVIDENCE.exists() else {}
    previous[key] = value
    EVIDENCE.write_text(json.dumps(previous, ensure_ascii=False, indent=2), encoding='utf-8')


def verify_grayscale(test, path, extension):
    spec = importlib.util.spec_from_file_location('real_grayscale_verifier',
        Path(__file__).resolve().parents[1]/'bookconvert/convert_book.py')
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    names = api.packing_image_members(path, extension)
    test.assertTrue(names)
    with zipfile.ZipFile(path) as archive:
        for name in names:
            with Image.open(io.BytesIO(archive.read(name))) as image:
                channels = image.convert('RGB').split()
                test.assertIsNone(ImageChops.difference(channels[0], channels[1]).getbbox(), name)
                test.assertIsNone(ImageChops.difference(channels[1], channels[2]).getbbox(), name)


@unittest.skipUnless(os.name == 'nt' and INPUTS and EVIDENCE and operations.OPERATOR
                     and operations.OPERATOR.is_file() and operations.RUNTIME,
                     'Explicit isolated real inputs and packaged native runtime required')
class NativeRealContainers(unittest.TestCase):
    def setUp(self):
        self.harness = mislabeled.MislabeledCompressionTests()
        self.harness.setUp()
        self.addCleanup(self.harness.doCleanups)
        source_stamps_unchanged()
        self.addCleanup(source_stamps_unchanged)

    def check_real(self, extension):
        path, original, row = selected(extension)
        op = self.harness.seed(original, extension)
        body = self.harness.finish(op, original, extension, True)
        result = op.root/('verified'+extension)
        result.write_bytes(body)
        verify_non_image_content(path, result, extension)
        verify_grayscale(self, result, extension)
        self.assertEqual(path.read_bytes(), original)
        evidence('native'+extension, dict(book_id=row['book_id'], input_bytes=len(original),
            output_bytes=len(body), input_sha256=row['sha256'],
            output_sha256=hashlib.sha256(body).hexdigest(), full_original_backup=True,
            native_readback=True, repeat_and_new_engine_reused=True,
            non_image_content_verified=True, grayscale_pixels_verified=True,
            original_archives_opened_for_writing=False))

    def test_real_docx(self):
        self.check_real('.docx')

    def test_real_odt(self):
        self.check_real('.odt')

    def test_real_cbz(self):
        self.check_real('.cbz')


@unittest.skipUnless(os.name == 'nt' and INPUTS and EVIDENCE and operations.RUNTIME,
                     'Explicit isolated real inputs and packaged runtime required')
class CopyRealContainers(unittest.TestCase):
    def setUp(self):
        self.fixture = packing.PackingTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        source_stamps_unchanged()
        self.addCleanup(source_stamps_unchanged)
        self.tools = operations.RUNTIME/'tools'
        self.fixture.job.update(engine='illustrations-gray-ppmd', images='economy', tools_root=str(self.tools))
        self.job = self.fixture.root/'copy-job.json'
        self.audit = self.fixture.root/'codec-calls.json'
        self.observer = self.fixture.root/'copy-observer.py'
        script = str(self.tools/'bookconvert/pack_collection.py')
        self.observer.write_text(
            'import ctypes, json, pathlib, runpy, sys, zipfile\n'
            'split = ctypes.windll.shell32.CommandLineToArgvW\n'
            'split.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]\n'
            'split.restype = ctypes.POINTER(ctypes.c_wchar_p)\n'
            'free = ctypes.windll.kernel32.LocalFree\n'
            'free.argtypes = [ctypes.c_void_p]\n'
            'free.restype = ctypes.c_void_p\n'
            'calls = []\n'
            'def observe(event, args):\n'
            ' if event == "subprocess.Popen":\n'
            '  command = args[1]\n'
            '  if isinstance(command, str) and "--export-images" in command:\n'
            '   count = ctypes.c_int()\n'
            '   words = split(command, ctypes.byref(count))\n'
            '   if not words: raise OSError("Cannot inspect Windows command arguments")\n'
            '   try: command = [words[i] for i in range(count.value)]\n'
            '   finally: free(ctypes.cast(words, ctypes.c_void_p))\n'
            '  if isinstance(command, (list, tuple)) and "--export-images" in command:\n'
            '   with zipfile.ZipFile(command[2]) as images:\n'
            '    calls.append(len(images.infolist()))\n'
            'sys.addaudithook(observe)\n'
            'try:\n'
            f' runpy.run_path({script!r}, run_name="__main__")\n'
            'finally:\n'
            f' pathlib.Path({str(self.audit)!r}).write_text(json.dumps(calls), encoding="utf-8")\n',
            encoding='utf-8')

    def run_copy(self):
        self.job.write_text(json.dumps(self.fixture.job), encoding='utf-8')
        process = run_owned([str(self.tools/'python/python.exe'), '-I', '-X', 'utf8',
            str(self.observer), '--job', str(self.job)], capture_output=True,
            encoding='utf-8', errors='strict', timeout=120)
        self.assertEqual(process.returncode, 0, process.stdout+process.stderr)
        events = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(events[-1]['stage'], 'prepared', events)
        calls = json.loads(self.audit.read_text(encoding='utf-8'))
        return SimpleNamespace(**events[-1]), sum(calls)

    def test_real_mixed_copy_reuses_images_after_new_archives_and_member_updates(self):
        originals = {}
        images = 0
        for number, extension in enumerate(('.docx', '.odt', '.cbz'), 1):
            path, body, row = selected(extension)
            originals[number] = (extension, path, body)
            images += row['images']
        entries = {'same'+extension: body for extension, _, body in originals.values()}
        neighbor = b'Keep neighboring text exactly.\n'*300
        entries['neighbor.txt'] = neighbor
        source = self.fixture.archive('mixed.zip', entries)
        before = packing.sha(source)
        for number, (extension, _, _) in originals.items():
            self.fixture.add(number, source, 'same'+extension)
        self.fixture.add(4, source, 'neighbor.txt')
        one, first_encoded = self.run_copy()
        evidence('copy-first-attempt', dict(stats=vars(one), encoded=first_encoded))
        self.assertGreater(first_encoded, 0)
        self.assertLessEqual(first_encoded, images)
        bodies = {}
        rows = []
        for number, (extension, path, original) in originals.items():
            body = self.fixture.packed_book(one, number)
            self.assertLess(len(body), len(original), extension)
            self.assertEqual(self.fixture.mapped_size(one, number), len(body))
            candidate = self.fixture.root/('verify'+extension)
            candidate.write_bytes(body)
            verify_non_image_content(path, candidate, extension)
            verify_grayscale(self, candidate, extension)
            self.assertEqual(path.read_bytes(), original)
            bodies[number] = body
            rows.append(dict(format=extension, input_bytes=len(original), output_bytes=len(body)))
        self.assertEqual(self.fixture.packed_book(one, 4), neighbor)
        self.assertEqual(packing.sha(source), before)
        two, repeated_encoded = self.run_copy()
        self.assertEqual((two.reused, repeated_encoded), (1, 0))
        for number, body in bodies.items():
            self.assertEqual(self.fixture.packed_book(two, number), body)
        new_source = self.fixture.archive('new.zip', {'new.docx': originals[1][2]})
        new_hash = packing.sha(new_source)
        self.fixture.add(5, new_source, 'new.docx')
        three, new_encoded = self.run_copy()
        self.assertEqual(three.reused, 1)
        self.assertLessEqual(new_encoded, json.loads(INPUTS.read_text(encoding='utf-8'))['inputs']['.docx']['images'])
        for number, body in bodies.items():
            self.assertEqual(self.fixture.packed_book(three, number), body)
        new_body = self.fixture.packed_book(three, 5)
        check = self.fixture.root/'new-result.docx'
        check.write_bytes(new_body)
        verify_non_image_content(originals[1][1], check, '.docx')
        self.assertLess(len(new_body), len(originals[1][2]))
        verify_grayscale(self, check, '.docx')
        self.assertEqual(self.fixture.mapped_size(three, 5), len(new_body))
        four, final_encoded = self.run_copy()
        self.assertEqual((four.reused, final_encoded), (2, 0))
        self.assertEqual(self.fixture.packed_book(four, 5), new_body)
        self.assertEqual((packing.sha(source), packing.sha(new_source)), (before, new_hash))
        # A new INPX may also add a book to a changed archive that retains all
        # previous members. Those old image payloads must survive byte-exact.
        with zipfile.ZipFile(source, 'a', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('added.cbz', originals[3][2])
        updated_hash = packing.sha(source)
        self.fixture.add(6, source, 'added.cbz')
        five, appended_encoded = self.run_copy()
        self.assertEqual(five.reused, 1)
        self.assertLessEqual(appended_encoded, json.loads(INPUTS.read_text(encoding='utf-8'))['inputs']['.cbz']['images'])
        for number, body in bodies.items():
            self.assertEqual(self.fixture.packed_book(five, number), body)
        self.assertEqual(self.fixture.packed_book(five, 4), neighbor)
        self.assertEqual(self.fixture.packed_book(five, 5), new_body)
        appended_body = self.fixture.packed_book(five, 6)
        check = self.fixture.root/'added-result.cbz'
        check.write_bytes(appended_body)
        verify_non_image_content(originals[3][1], check, '.cbz')
        verify_grayscale(self, check, '.cbz')
        self.assertLess(len(appended_body), len(originals[3][2]))
        self.assertEqual(self.fixture.mapped_size(five, 6), len(appended_body))
        six, appended_repeat = self.run_copy()
        self.assertEqual((six.reused, appended_repeat), (2, 0))
        self.assertEqual(self.fixture.packed_book(six, 6), appended_body)
        self.assertEqual((packing.sha(source), packing.sha(new_source)), (updated_hash, new_hash))
        self.assertFalse(list(self.fixture.output.glob('.packing-*')))
        self.assertFalse((self.fixture.output/'current.json').exists())
        evidence('copy', dict(books=rows, first_encoded=first_encoded,
            repeat_encoded=repeated_encoded, new_archive_encoded=new_encoded,
            final_repeat_encoded=final_encoded, added_member_encoded=appended_encoded,
            added_member_repeat_encoded=appended_repeat, inputs_preserved_between_updates=True,
            same_names_preserved=True, non_image_content_verified=True,
            grayscale_pixels_verified=True,
            embedded_python=str(self.tools/'python/python.exe'), catalogue_registration_tested=False))

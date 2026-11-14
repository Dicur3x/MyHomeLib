import copy
import hashlib
import json
from pathlib import Path
import random
import tempfile
import unittest
import zipfile

from pack_collection import Canceled, PackingError, temporary_work_directory
from restored_book_validation import validate_restored_books
from test_native_compression_receipt import book, png


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RestoredBookValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-full-book-validation-')
        self.root = self.temp.__enter__()
        self.source = self.root/'source.7z'
        self.source.write_bytes(b'Owned archive witness, never modified')
        self.work = self.root/'work'
        self.snapshots = self.work/'full-books'
        self.snapshots.mkdir(parents=True)
        pixels = random.Random(71).randbytes(128*128)
        self.old, self.new = book(png(False, pixels)), book(png(True, pixels))
        self.before, self.after = self.snapshots/'0-before.bin', self.snapshots/'0-after.bin'
        self.before.write_bytes(self.old); self.after.write_bytes(self.new)
        self.request = dict(version=1, kind='HomeLibre restored book validation', source=str(self.source),
            source_sha256=sha(self.source.read_bytes()), workspace=str(self.work),
            backup_originals=True, preview_images=True, books=[dict(member='one.fb2', format='.fb2',
            before=str(self.before), before_sha256=sha(self.old), after=str(self.after),
            after_sha256=sha(self.new), raw_changed=False)])

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def no_outputs(self):
        self.assertFalse((self.work/'original-books.zip').exists())
        self.assertFalse((self.work/'comparison.zip').exists())
        self.assertEqual(sha(self.source.read_bytes()), self.request['source_sha256'])

    def test_measures_complete_book_and_keeps_self_contained_original_and_exact_image_pairs(self):
        result = validate_restored_books(self.request)
        self.assertEqual(result['restored_payloads'], [dict(member='one.fb2', input_sha256=sha(self.old),
            output_sha256=sha(self.new), input_size=len(self.old), size=len(self.new))])
        with zipfile.ZipFile(result['originals']['path']) as backup:
            self.assertEqual(backup.read('books/one.fb2'), self.old)
            manifest = json.loads(backup.read('HomeLibre-originals.json'))
            self.assertEqual(manifest['books'][0]['sha256'], sha(self.old))
        self.assertIsNotNone(result['preview'])
        self.assertEqual(self.before.read_bytes(), self.old)
        self.assertEqual(self.after.read_bytes(), self.new)

    def test_changed_text_is_rejected_and_prepared_outputs_are_removed(self):
        self.after.write_bytes(self.new.replace(b'Same book text', b'Different text'))
        self.request['books'][0]['after_sha256'] = sha(self.after.read_bytes())
        with self.assertRaises(PackingError):
            validate_restored_books(self.request)
        self.no_outputs()

    def test_changed_snapshot_and_outside_paths_are_rejected(self):
        self.after.write_bytes(self.new+b'changed')
        with self.assertRaises(PackingError):
            validate_restored_books(self.request)
        self.no_outputs()
        self.request['books'][0]['before'] = str(self.source)
        with self.assertRaises(PackingError):
            validate_restored_books(self.request)
        self.no_outputs()

    def test_cancel_after_first_book_removes_original_and_comparison(self):
        stopped = False
        def notify(value):
            nonlocal stopped
            stopped = True
        with self.assertRaises(Canceled):
            validate_restored_books(self.request, canceled=lambda: stopped, notify=notify)
        self.no_outputs()

    def test_backup_and_preview_are_optional_and_wrong_source_never_prepares_either(self):
        self.request.update(backup_originals=False, preview_images=False)
        result = validate_restored_books(self.request)
        self.assertIsNone(result['originals']); self.assertIsNone(result['preview'])
        self.no_outputs()
        self.request['source_sha256'] = '0'*64
        with self.assertRaises(PackingError):
            validate_restored_books(self.request)
        self.assertFalse((self.work/'original-books.zip').exists())

    def test_unknown_unchanged_raw_format_cannot_change_during_external_restoration(self):
        self.request['books'][0]['format'] = '.pdf'
        with self.assertRaises(PackingError):
            validate_restored_books(self.request)
        self.no_outputs()

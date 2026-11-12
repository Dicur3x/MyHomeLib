"""Whole collection uses one normal, durable compression job per archive."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import zipfile

import test_native_compression_operation as operations
from test_native_compression_receipt import database, sha


@unittest.skipUnless(os.name == 'nt' and operations.OPERATOR and operations.OPERATOR.is_file()
                     and operations.RUNTIME and operations.RUNTIME.is_dir(),
                     'Native operator and packaged codecs required')
class NativeCollectionOperationTests(unittest.TestCase):
    tearDown = operations.NativeCompressionOperationTests.tearDown
    run_operation = operations.NativeCompressionOperationTests.run_operation
    unchanged = operations.NativeCompressionOperationTests.unchanged
    enable_backup = operations.NativeCompressionOperationTests.enable_backup

    def setUp(self):
        operations.NativeCompressionOperationTests.setUp(self)
        self.config['whole'] = True

    def check_clean(self):
        self.assertFalse(list(Path(self.config['work_root']).glob('collection-plan-*')))

    def assert_applied(self, result):
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['changed_files'], 1)
        self.assertEqual((result['pending_before_ack'], result['pending_after_ack']), (1, 0))
        self.assertEqual(self.fixture.snapshot(self.fixture.catalogue, sizes=False), self.catalogue)
        self.assertEqual(self.fixture.snapshot(self.fixture.personal, sizes=False), self.personal)
        for member in ('one.fb2', 'neighbor.fb2'):
            decoded = subprocess.run([self.config['seven_zip'], 'x', '-so', '-y', '-spd', '-ssc', '--',
                                      str(self.fixture.source), member], capture_output=True, timeout=15,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(decoded.returncode, 0, decoded.stderr)
            if member == 'neighbor.fb2':
                self.assertEqual(decoded.stdout, self.fixture.neighbor)
            else:
                self.assertIn(b'Same book text; only its grayscale PNG representation changes.', decoded.stdout)
            with database(self.fixture.catalogue) as db:
                identity = 101 if member == 'one.fb2' else 102
                self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=?', (identity,)).fetchone()[0],
                                 len(decoded.stdout))

    def test_all_archive_books_committed_together_with_optional_originals(self):
        folder = self.enable_backup()
        before = self.fixture.source.stat().st_size
        result = self.run_operation()
        self.assert_applied(result)
        self.assertEqual((result['files_done'], result['files_total']), (1, 1))
        self.assertEqual((result['books_done'], result['books_total']), (2, 2))
        self.assertEqual(result['saved_bytes'], before - self.fixture.source.stat().st_size)
        with zipfile.ZipFile(next(folder.glob('*.zip'))) as backup:
            manifest = json.loads(backup.read('HomeLibre-originals.json'))
            originals = {r['member']: backup.read(r['file']) for r in manifest['books']}
            self.assertEqual(originals, {'one.fb2': self.fixture.original_book, 'neighbor.fb2': self.fixture.neighbor})
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM HomeLibreBookCompression').fetchone()[0], 2)
        self.check_clean()

    def test_estimate_only_is_read_only_for_whole_collection(self):
        self.config.update(estimate_first=True, operation_mode='estimate-only')
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertTrue(result['estimate_only'])
        self.assertEqual(result['books_total'], 2)
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_before_ack'], 0)
        self.unchanged()
        self.check_clean()

    def test_skip_review_preserves_whole_archive_and_both_stores(self):
        self.config['operation_mode'] = 'review-skip'
        result = self.run_operation()
        self.assertTrue(result['review_seen'])
        self.assertEqual(result['skipped_files'], 1)
        self.assertEqual(result['books_total'], 2)
        self.unchanged()
        self.check_clean()


if __name__ == '__main__':
    unittest.main()

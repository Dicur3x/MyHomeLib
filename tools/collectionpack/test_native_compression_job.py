"""Durable compression jobs: native processes and synthetic books/catalogues."""
import json
import os
from pathlib import Path
import random
import subprocess
import time
import unittest
import zipfile

import test_native_compression_receipt as fixture


@unittest.skipUnless(os.name == 'nt' and fixture.NATIVE and fixture.NATIVE.is_file(),
                     'Built native compression job worker required')
class NativeCompressionJobTests(unittest.TestCase):
    setUp = fixture.NativeCompressionReceiptTests.setUp
    tearDown = fixture.NativeCompressionReceiptTests.tearDown
    write_template = fixture.NativeCompressionReceiptTests.write_template
    snapshot = fixture.NativeCompressionReceiptTests.snapshot
    require_success = fixture.NativeCompressionReceiptTests.require_success
    require_finished = fixture.NativeCompressionReceiptTests.require_finished

    def run_worker(self, mode='job-apply', fault='-'):
        return subprocess.run([str(fixture.NATIVE), str(self.root), mode, fault],
                              capture_output=True, text=True, encoding='utf-8',
                              errors='replace', timeout=30)

    def pending(self):
        self.require_success(self.run_worker('job-list'))
        return [Path(p) for p in json.loads((self.root / 'pending.json').read_text('utf-8-sig'))]

    def job(self):
        jobs = self.pending()
        self.assertEqual(len(jobs), 1)
        return jobs[0]

    def finished(self, before_c, before_p):
        self.require_finished(before_c, before_p)
        self.assertEqual(self.pending(), [])
        self.assertFalse(list((self.root / 'queue').iterdir()))

    def test_one_job_applies_and_forgets_only_its_owned_recovery_data(self):
        before_c, before_p = self.snapshot(self.catalogue, False), self.snapshot(self.personal, False)
        self.require_success(self.run_worker())
        self.finished(before_c, before_p)

    def test_prepared_job_is_discovered_without_a_book_write(self):
        before_c, before_p = self.snapshot(self.catalogue, False), self.snapshot(self.personal, False)
        self.assertEqual(self.run_worker(fault='job-prepared').returncode, 73)
        self.assertEqual(fixture.sha(self.source.read_bytes()), self.original_hash)
        self.assertTrue((self.job() / 'receipt.json').is_file())
        self.require_success(self.run_worker('job-recover'))
        self.finished(before_c, before_p)

    def test_process_crashes_recover_from_each_file_database_and_cleanup_boundary(self):
        # Keep a nontrivial result payload so the half-written block boundary
        # is actually reached; this is a real native process termination.
        self.neighbor = random.Random(113).randbytes(128 * 1024)
        for path, selected in [(self.source, self.original_book), (self.candidate, self.new_book)]:
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('one.fb2', selected)
                archive.writestr('neighbor.fb2', self.neighbor)
        original, candidate = self.source.read_bytes(), self.candidate.read_bytes()
        self.original_hash, self.output_hash = fixture.sha(original), fixture.sha(candidate)
        self.template.update(source_sha256=self.original_hash, result_sha256=self.output_hash)
        with fixture.database(self.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=102', (len(self.neighbor),))
        self.write_template()
        for stage in ['journal-published', 'half-written', 'half-metadata', 'truncated',
                      'file-committed', 'catalogue-committed', 'personal-committed',
                      'completed-published', 'file-journal-forgotten']:
            with self.subTest(stage=stage):
                # Reset only this fixture's databases after a fully verified
                # previous iteration, never a live user catalogue.
                self.source.write_bytes(original)
                self.candidate.write_bytes(candidate)
                for path in [self.catalogue, self.personal]:
                    with fixture.database(path) as db:
                        if path == self.catalogue:
                            db.execute('UPDATE Books SET BookSize=? WHERE BookID=101', (len(self.original_book),))
                            db.execute('UPDATE CatalogBookCopies SET BookSize=?', (len(self.original_book),))
                            db.execute('DROP TABLE IF EXISTS HomeLibreBookCompression')
                        else:
                            db.execute('UPDATE Books SET BookSize=? WHERE DatabaseID=7', (len(self.original_book),))
                before_c, before_p = self.snapshot(self.catalogue, False), self.snapshot(self.personal, False)
                failed = self.run_worker(fault=stage)
                self.assertEqual(failed.returncode, 73, failed.stdout + failed.stderr)
                self.assertEqual(len(self.pending()), 1)
                self.require_success(self.run_worker('job-recover'))
                self.finished(before_c, before_p)

    def test_changed_catalogue_before_start_keeps_original_and_recovery_receipt(self):
        self.assertEqual(self.run_worker(fault='job-prepared').returncode, 73)
        with fixture.database(self.catalogue) as db:
            db.execute("UPDATE Books SET FileName='other' WHERE BookID=101")
        self.assertNotEqual(self.run_worker('job-recover').returncode, 0)
        self.assertEqual(fixture.sha(self.source.read_bytes()), self.original_hash)
        self.assertTrue((self.job() / 'receipt.json').is_file())
        with fixture.database(self.catalogue) as db:
            db.execute("UPDATE Books SET FileName='one' WHERE BookID=101")
        self.require_success(self.run_worker('job-recover'))

    def test_cancel_before_file_changes_retains_original_and_can_resume(self):
        self.assertNotEqual(self.run_worker('job-cancel').returncode, 0)
        self.assertEqual(fixture.sha(self.source.read_bytes()), self.original_hash)
        self.assertEqual(len(self.pending()), 1)
        self.require_success(self.run_worker('job-recover'))
        self.assertEqual(self.pending(), [])

    def test_changed_receipt_is_refused_and_original_receipt_recovers(self):
        self.assertEqual(self.run_worker(fault='half-metadata').returncode, 73)
        receipt = self.job() / 'receipt.json'
        saved = receipt.read_bytes()
        altered = json.loads(saved)
        altered['profile_sha256'] = '1' * 64
        receipt.write_text(json.dumps(altered), encoding='utf-8')
        failed = self.run_worker('job-recover')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('Задание сжатия не соответствует', failed.stdout)
        self.assertTrue(receipt.is_file())
        receipt.write_bytes(saved)
        self.require_success(self.run_worker('job-recover'))

    def test_premature_completion_marker_does_not_skip_database_commit(self):
        self.assertEqual(self.run_worker(fault='file-committed').returncode, 73)
        job = self.job()
        receipt_hash = json.loads((job / 'job.json').read_text('utf-8-sig'))['receipt_sha256']
        (job / 'completed.json').write_text(receipt_hash)
        self.assertNotEqual(self.run_worker('job-recover').returncode, 0)
        with fixture.database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0], len(self.original_book))
        (job / 'completed.json').unlink()
        self.require_success(self.run_worker('job-recover'))

    def test_notes_added_after_completion_remain_when_consuming_receipt(self):
        self.assertEqual(self.run_worker(fault='completed-published').returncode, 73)
        with fixture.database(self.personal) as db:
            db.execute("UPDATE Books SET ExtraInfo=? WHERE BookID=101 AND DatabaseID=7", (b'new notes after completion',))
        self.require_success(self.run_worker('job-recover'))
        with fixture.database(self.personal) as db:
            self.assertEqual(db.execute('SELECT ExtraInfo FROM Books WHERE DatabaseID=7').fetchone()[0], b'new notes after completion')

    def test_unknown_file_is_preserved_and_completed_job_is_no_longer_pending(self):
        self.assertEqual(self.run_worker(fault='file-journal-forgotten').returncode, 73)
        job = self.job()
        (job / 'unknown.txt').write_bytes(b'preserve unknown file')
        self.assertNotEqual(self.run_worker('job-recover').returncode, 0)
        self.assertEqual(self.pending(), [])
        remaining = list((self.root / 'queue').glob('done-compress-*'))
        self.assertEqual(len(remaining), 1)
        self.assertEqual((remaining[0] / 'unknown.txt').read_bytes(), b'preserve unknown file')

    def test_second_process_cannot_open_a_live_job(self):
        process = subprocess.Popen([str(fixture.NATIVE), str(self.root), 'job-hold', '-'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'hold-ready').exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.025)
            self.assertTrue((self.root / 'hold-ready').exists())
            self.assertNotEqual(self.run_worker('job-recover').returncode, 0)
            self.assertEqual(fixture.sha(self.source.read_bytes()), self.original_hash)
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)
        self.require_success(self.run_worker('job-recover'))

    def test_other_queues_and_non_job_folders_are_not_discovered(self):
        foreign = self.root / 'queue' / 'zip-delete-{17B17230-B8C0-47B3-85A4-FAC5FAAFD4DD}'
        foreign.mkdir(parents=True)
        (foreign / 'plan.json').write_bytes(b'not our compression job')
        self.assertEqual(self.pending(), [])
        self.assertEqual((foreign / 'plan.json').read_bytes(), b'not our compression job')


if __name__ == '__main__':
    unittest.main(verbosity=2)

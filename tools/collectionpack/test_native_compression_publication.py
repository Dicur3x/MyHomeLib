"""Crash/lease boundaries before any source bytes are written."""
import json
import os
from pathlib import Path
import subprocess
import time
import unittest

import test_native_compression_receipt as fixtures
from test_native_compression_receipt import database, sha


@unittest.skipUnless(os.name == 'nt' and fixtures.NATIVE and fixtures.NATIVE.is_file(),
                     'Built native publication fixture required')
class NativeCompressionPublicationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.NativeCompressionReceiptTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.before = {path: sha(path.read_bytes()) for path in
                       (self.fixture.source, self.fixture.catalogue, self.fixture.personal)}

    def tearDown(self):
        self.fixture.tearDown()

    def pending(self):
        self.fixture.require_success(self.fixture.run_worker('job-list'))
        return json.loads((self.root / 'pending.json').read_text(encoding='utf-8-sig'))

    def unchanged(self):
        self.assertEqual({path: sha(path.read_bytes()) for path in self.before}, self.before)

    def applied(self):
        self.assertEqual(sha(self.fixture.source.read_bytes()), self.fixture.output_hash)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0],
                             len(self.fixture.new_book))
        self.assertFalse(self.pending())

    def test_crashes_while_saving_metadata_do_not_advertise_a_half_job(self):
        for stage in ['receipt-prepared', 'binding-prepared']:
            with self.subTest(stage=stage):
                crashed = self.fixture.run_worker('job-prepare-crash', stage)
                self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
                self.assertEqual((self.root / 'preparation-stage.txt').read_text(encoding='utf-8-sig'), stage)
                self.assertFalse(self.pending())
                self.unchanged()
        unpublished = list((self.root / 'queue').glob('compress-*'))
        self.assertEqual(len(unpublished), 2)
        self.assertTrue(all(not (path / 'job.json').exists() for path in unpublished))
        self.fixture.require_success(self.fixture.run_worker('job-apply'))
        self.applied()

    def test_published_job_is_complete_and_can_recover_before_constructor_returns(self):
        crashed = self.fixture.run_worker('job-prepare-crash', 'job-published')
        self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
        self.assertEqual(len(self.pending()), 1)
        self.assertTrue(all((path / 'job.json').exists() for path in (self.root / 'queue').glob('compress-*')))
        self.unchanged()
        self.fixture.require_success(self.fixture.run_worker('job-recover'))
        self.applied()

    def test_file_journal_can_be_published_without_writes_and_recovered_in_a_new_process(self):
        before_c = self.fixture.snapshot(self.fixture.catalogue, False)
        before_p = self.fixture.snapshot(self.fixture.personal, False)
        self.fixture.require_success(self.fixture.run_worker('publish-only'))
        self.unchanged()
        journal = Path((self.root/'job.txt').read_text(encoding='utf-8-sig'))
        self.assertTrue((journal/'plan.json').is_file())
        self.assertTrue((journal/'checkpoint.json').is_file())
        self.fixture.require_success(self.fixture.run_worker('recover'))
        self.fixture.require_finished(before_c, before_p)
        self.assertFalse(journal.exists())

    def test_atomic_publication_keeps_exclusive_lease_held(self):
        process = subprocess.Popen([str(fixtures.NATIVE), str(self.root), 'job-prepare-hold', '-'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while not (self.root / 'publication-ready').exists():
                self.assertIsNone(process.poll(), 'Publishing worker exited before the observed live hold')
                self.assertLess(time.monotonic(), deadline, 'Publication fixture did not reach its hold')
                time.sleep(.02)
            self.assertIsNone(process.poll())
            self.assertEqual(len(self.pending()), 1)
            competing = self.fixture.run_worker('job-recover')
            self.assertNotEqual(competing.returncode, 0, competing.stdout + competing.stderr)
            self.unchanged()
        finally:
            (self.root / 'release-publication').write_text('release', encoding='ascii')
            output, errors = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, output + errors)
        self.applied()

    def check_lost_binding(self, stage, completed_only=False):
        crashed = self.fixture.run_worker('job-apply', stage)
        self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
        jobs = self.pending()
        self.assertEqual(len(jobs), 1)
        job = self.root / 'queue' / Path(jobs[0]).name
        binding = job / 'job.json'
        original = binding.read_bytes()
        binding.unlink()
        if completed_only:
            self.assertTrue((job / 'completed.json').is_file())
            (job / 'file').rmdir()
        at_crash = {path: sha(path.read_bytes()) for path in self.before}
        self.assertEqual(len(self.pending()), 1, 'A started job must remain discoverable even without job.json')
        rejected = self.fixture.run_worker('job-recover')
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual({path: sha(path.read_bytes()) for path in self.before}, at_crash)
        binding.write_bytes(original)
        self.fixture.require_success(self.fixture.run_worker('job-recover'))
        self.applied()

    def test_missing_binding_does_not_hide_started_file_journal(self):
        self.check_lost_binding('file-committed')

    def test_missing_binding_does_not_hide_completed_job(self):
        self.check_lost_binding('file-journal-forgotten', completed_only=True)


if __name__ == '__main__':
    unittest.main()

"""Completed shared-catalogue snapshot reclamation uses sealed ownership proofs."""
import copy
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cleanup as cleanup
import test_native_collection_transfer_locations as locations

MARKER = 'HomeLibreTransferForkCleanup'
RECEIPTS = 'HomeLibreTransferForkReceipts'
locations.MARKERS.add(MARKER)


class TransferForkCleanupTests(cleanup.TransferCleanupTests):
    def setUp(self):
        super().setUp()
        with fixture.connect(self.personal) as db:
            fixture.insert(db, 'Bases', dict(DatabaseID=8, BaseName='Shared retained catalogue',
                           DBFileName=str(self.catalogue), RootFolder=str(self.b)))

    def check_metadata(self, before):
        expected = copy.deepcopy(before)
        # A newly published retained-root catalogue starts from the original
        # snapshot, before the selected catalogue's cache/settings cutover.
        with fixture.connect(self.personal) as db:
            if db.execute('SELECT count(*) FROM sqlite_master WHERE name=?', (RECEIPTS,)).fetchone()[0]:
                for target, sha in db.execute('SELECT Target,SnapshotSHA256 FROM '+RECEIPTS):
                    path = Path(target)
                    if path.is_file() and path not in expected:
                        self.assertIn((target,sha), self.read_review('SELECT f.Destination,s.SHA256 '
                            'FROM CatalogueForks f JOIN ForkSources s ON s.ID=f.SourceID'))
                        expected[path] = copy.deepcopy(before[self.catalogue])
        super().check_metadata(expected)

    def seed(self):
        self.run_case()
        self.completed = self.finish()
        self.assert_completed(self.completed)
        self.directories = [Path(row[1]) for row in self.stage_rows()]
        self.cache_count = len(self.intent()['jobs'])
        self.assertEqual(len(self.directories), self.cache_count)
        self.assertGreater(self.cache_count, 0)
        self.work_files = self.files(self.directories)
        self.receipt_before = self.receipt()
        installed = self.install_rows()
        self.assertEqual(len(installed), self.cache_count)
        self.installed = self.files([Path(r['Destination']) for r in installed])
        self.assertTrue(self.installed)
        self.fork_directory = self.journal() / 'catalogue-snapshots'
        self.assertTrue(self.fork_directory.is_dir())
        sources = self.read_review('SELECT Snapshot,Identity,Bytes,SHA256 FROM ForkSources')
        self.assertTrue(sources)
        self.fork_files = {p: digest for p, _, _, digest in sources}
        self.assertEqual(self.files([self.fork_directory]), self.fork_files)
        keys = self.read_review("SELECT Value FROM Context WHERE Name='fork_snapshots_key'")
        if getattr(self, 'legacy', False): self.assertEqual(keys, [])
        else: self.assertEqual(len(keys[0][0]), 25)
        self.directories.append(self.fork_directory)
        self.work_files.update(self.fork_files)
        self.work_bytes = sum(Path(p).stat().st_size for p in self.work_files)
        self.fork_receipts = self.registry_rows(RECEIPTS)
        with fixture.connect(self.personal) as db:
            self.fork_targets = [Path(r[0]) for r in db.execute('SELECT Target FROM ' + RECEIPTS)]
        self.target_tables = {p: locations.tables(p) for p in self.fork_targets}

    def clean(self, *args, **options):
        result = super().clean(*args, **options)
        if hasattr(self, 'fork_receipts'):
            self.assertEqual(self.registry_rows(RECEIPTS), self.fork_receipts)
            self.assertEqual({p: locations.tables(p) for p in self.fork_targets}, self.target_tables)
        return result

    def test_completed_fork_and_cache_snapshots_removed_with_read_only_replay(self):
        self.seed()
        result = self.clean()
        self.assertEqual(result['files_removed'], len(self.work_files))
        self.assertEqual(result['bytes_removed'], self.work_bytes)
        self.assertEqual((result['directories_removed'], result['directories_retained']), (self.cache_count+1, 0))
        self.assertEqual((result['queued_before'], result['queued_after']), (1, 0))
        self.assertFalse(result['warning'])
        self.assertTrue(all(not p.exists() for p in self.directories))
        before = self.database_bytes()
        self.assertEqual(self.clean()['files_removed'], 0)
        self.assertEqual(self.database_bytes(), before)
        self.assertEqual(self.finish(), self.completed)
        self.assertEqual(self.database_bytes(), before)

    def test_same_identity_changed_bytes_preserve_entire_snapshot_folder_then_retry(self):
        self.seed()
        target = Path(next(iter(self.fork_files)))
        original = target.read_bytes()
        for payload, message in ((original[:-1], 'Размер'), (original[:-1] + bytes([original[-1] ^ 1]), 'Содержимое')):
            with self.subTest(message=message):
                target.write_bytes(payload)
                before = self.files([self.fork_directory])
                result = self.clean()
                self.assertEqual(result['directories_retained'], 1)
                self.assertIn(message, result['warning'])
                self.assertEqual(self.files([self.fork_directory]), before)
                self.assertEqual(result['queued_after'], 1)
        target.write_bytes(original)
        self.assertEqual(self.clean(mode='cleanup-queue')['queued_after'], 0)

    def test_foreign_file_directory_link_stream_busy_and_replacement_preserve_folder(self):
        self.seed()
        target = Path(next(iter(self.fork_files)))
        before = self.files([self.fork_directory])
        def retained():
            result = self.clean()
            self.assertEqual(result['directories_retained'], 1)
            self.assertEqual(result['queued_after'], 1)
            self.assertEqual({p: fixture.digest(p) for p in before}, before)
        foreign = self.fork_directory/'foreign.txt'; foreign.write_bytes(b'unrelated')
        retained(); self.assertEqual(foreign.read_bytes(), b'unrelated'); foreign.unlink()
        subdir = self.fork_directory/'foreign-folder'; subdir.mkdir(); retained(); subdir.rmdir()
        alias = self.home/'foreign-hardlink'; os.link(target, alias)
        retained(); self.assertEqual(fixture.digest(alias), before[str(target)]); alias.unlink()
        for owner in (target, self.fork_directory):
            stream = Path(str(owner)+':foreign-stream'); stream.write_bytes(b'private stream')
            retained(); self.assertEqual(stream.read_bytes(), b'private stream'); stream.unlink()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.CreateFileW(str(target), 0x80000000, 1, None, 3, 128, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try: retained()
        finally: self.assertTrue(kernel.CloseHandle(handle))
        saved = self.home/'saved-snapshot'; target.rename(saved); target.write_bytes(b'foreign replacement')
        result = self.clean()
        self.assertEqual(result['directories_retained'], 1)
        self.assertEqual(target.read_bytes(), b'foreign replacement')
        self.assertEqual(fixture.digest(saved), before[str(target)])
        target.unlink(); saved.rename(target)
        saved_dir = self.home/'saved-directory'; self.fork_directory.rename(saved_dir); self.fork_directory.mkdir()
        result = self.clean()
        self.assertEqual(result['directories_retained'], 1)
        self.assertTrue(self.fork_directory.exists())
        self.fork_directory.rmdir(); saved_dir.rename(self.fork_directory)
        self.assertEqual(self.clean(mode='cleanup-queue')['queued_after'], 0)

    def test_fork_queue_is_independent_of_old_cache_done_marker_and_claims_table(self):
        self.seed()
        foreign = self.fork_directory/'hold.txt'; foreign.write_bytes(b'hold fork cleanup')
        self.assertEqual(self.clean()['directories_retained'], 1)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('SELECT Done FROM ' + cleanup.MARKER).fetchall(), [(1,)])
            db.execute('DROP TABLE HomeLibreTransferCacheClaims')
        foreign.unlink()
        result = self.clean(mode='cleanup-queue', cleanup_worker=True)
        self.assertEqual((result['directories_removed'], result['queued_before'], result['queued_after']), (1, 1, 0))

    def test_missing_or_changed_publication_receipt_refuses_before_any_deletion(self):
        self.seed()
        for sql in ('DELETE FROM '+RECEIPTS, "UPDATE "+RECEIPTS+" SET SnapshotSHA256='changed'",
                    "UPDATE "+RECEIPTS+" SET Target='G:\\not-this-operation.hlc2'"):
            with self.subTest(sql=sql):
                with fixture.connect(self.personal) as db:
                    db.execute('CREATE TEMP TABLE Saved AS SELECT * FROM '+RECEIPTS)
                    saved = db.execute('SELECT * FROM '+RECEIPTS).fetchall()
                    db.execute(sql)
                self.fork_receipts = self.registry_rows(RECEIPTS)
                before = self.files(self.directories)
                self.assertIn('подтвержден', self.clean('fail').replace('ё','е'))
                self.assertEqual(self.files(self.directories), before)
                with fixture.connect(self.personal) as db:
                    db.execute('DELETE FROM '+RECEIPTS)
                    db.executemany('INSERT INTO '+RECEIPTS+' VALUES('+','.join('?' for _ in saved[0])+')', saved)
                self.fork_receipts = saved
        self.assertEqual(self.clean()['queued_after'], 0)

    def test_legacy_review_without_sealed_directory_key_preserves_snapshot(self):
        self.legacy = True
        current = fixture.BINARY
        old = Path(os.environ['HL_TRANSFER_LEGACY'])
        self.assertTrue(old.is_file())
        shutil.copy2(old, self.binary)
        try: self.seed()
        finally: shutil.copy2(current, self.binary)
        result = self.clean()
        self.assertEqual((result['directories_removed'], result['directories_retained']), (self.cache_count, 1))
        self.assertEqual(result['queued_after'], 1)
        self.assertEqual(self.files([self.fork_directory]), self.fork_files)
        self.assertEqual(self.clean(mode='cleanup-queue')['directories_retained'], 1)
        self.assertEqual(self.files([self.fork_directory]), self.fork_files)

    def test_pending_fork_snapshots_cannot_be_cleaned(self):
        self.run_case()
        directories = [Path(r[1]) for r in self.stage_rows()] + [self.journal()/'catalogue-snapshots']
        before = self.files(directories)
        databases = self.database_bytes()
        self.assertIn('подтверждённого завершения', self.clean('fail'))
        self.assertEqual(self.files(directories), before)
        self.assertEqual(self.database_bytes(), databases)

    def test_kill_after_unlink_and_before_marker_resumes_without_recopy(self):
        self.seed()
        foreign = self.fork_directory/'hold.txt'; foreign.write_bytes(b'hold fork cleanup')
        self.assertEqual(self.clean()['directories_retained'], 1)
        foreign.unlink()
        result = self.clean(cancel_cleanup_stage='cleanup-after-file')
        self.assertTrue(result['stopped'])
        self.assertEqual((result['files_removed'],result['queued_after']), (len(self.fork_files),1))
        self.assertTrue(self.fork_directory.exists())
        self.assertEqual(self.files([self.fork_directory]), {})
        self.clean(97, crash='cleanup-before-record')
        self.assertTrue(all(not p.exists() for p in self.directories))
        result = self.clean(mode='cleanup-queue')
        self.assertEqual((result['files_removed'], result['directories_missing'], result['queued_after']), (0, self.cache_count+1, 0))

    def test_cleanup_succeeds_when_live_destination_is_offline(self):
        self.seed()
        offline = self.home/'offline-destination'; self.destination.rename(offline)
        try:
            self.config.update(mode='cleanup-queue', complete_only=False, crash='', cleanup_cancel_immediately=False,
                               cancel_cleanup_stage='')
            result = self.run_case()
            self.assertEqual((result['directories_removed'], result['queued_after']), (self.cache_count+1, 0))
        finally:
            offline.rename(self.destination)
        self.assertEqual({p: locations.tables(p) for p in self.fork_targets}, self.target_tables)
        self.assertEqual(self.files([Path(r['Destination']) for r in self.install_rows()]), self.installed)
        self.assertEqual(self.finish(), self.completed)

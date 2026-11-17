"""Completed transfer work snapshots: bounded ownership, retry and live locks."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_completion as completion
import test_native_collection_transfer_locations as locations

MARKER = 'HomeLibreTransferCacheCleanup'
locations.MARKERS.add(MARKER)


class TransferCleanupTests(completion.TransferCompletionTests):
    def seed(self):
        self.run_case()
        self.completed = self.finish()
        self.assert_completed(self.completed)
        self.directories = [Path(row[1]) for row in self.stage_rows()]
        self.assertEqual(len(self.directories), 2)
        self.work_files = self.files(self.directories)
        self.work_bytes = sum(Path(p).stat().st_size for p in self.work_files)
        self.assertTrue(self.work_files)
        self.receipt_before = self.receipt()
        installed_rows = self.install_rows()
        self.assertEqual(len(installed_rows), 2)
        self.installed = self.files([Path(r['Destination']) for r in installed_rows])
        self.assertTrue(self.installed, 'fixture has no published cache files to protect')

    @staticmethod
    def files(roots):
        return {str(p): fixture.digest(p) for root in roots for p in root.rglob('*') if p.is_file()}

    def clean(self, expected=0, mode='cleanup-only', **options):
        self.config.update(mode=mode, complete_only=False, register_operation=False,
                           crash='', cancel_cleanup_stage='', cleanup_cancel_immediately=False)
        self.config.update(options)
        result = self.run_case(expected)
        if hasattr(self, 'completed'):
            self.assertEqual(self.receipt(), self.receipt_before)
            self.assertEqual(self.files([Path(r['Destination']) for r in self.install_rows()]), self.installed)
            for intent in self.intents().values():
                self.assertEqual(fixture.digest(intent['Destination']), intent['SHA256'])
        return result

    def test_completed_snapshots_removed_receipt_replay_and_installed_caches_survive(self):
        self.seed()
        result = self.clean()
        self.assertEqual(result['files_removed'], len(self.work_files))
        self.assertEqual(result['bytes_removed'], self.work_bytes)
        self.assertEqual((result['directories_removed'], result['directories_retained']), (2, 0))
        self.assertFalse(result['warning'])
        self.assertEqual((result['queued_before'], result['queued_after']), (1, 0))
        self.assertTrue(all(not p.exists() for p in self.directories))
        before = self.database_bytes()
        self.assertEqual(self.clean()['files_removed'], 0)
        self.assertEqual(self.database_bytes(), before, 'idempotent cleanup rewrote databases')
        self.assertEqual(self.finish(), self.completed)
        self.assertEqual(self.database_bytes(), before)

    def test_pending_transfer_cannot_be_cleaned(self):
        self.run_case()
        before = self.database_bytes()
        files = self.files([Path(row[1]) for row in self.stage_rows()])
        self.assertIn('подтверждённого завершения', self.clean('fail'))
        self.assertEqual(self.database_bytes(), before)
        self.assertEqual({p: fixture.digest(p) for p in files}, files)

    def test_foreign_entry_retains_entire_directory_then_queue_retries(self):
        self.seed()
        directory = self.directories[0]
        foreign = directory / 'my-unrelated-file.txt'
        foreign.write_bytes(b'private foreign data')
        before = self.files([directory])
        result = self.clean()
        self.assertEqual(result['directories_retained'], 1)
        self.assertIn('неизвестный файл', result['warning'])
        self.assertEqual(self.files([directory]), before)
        self.assertEqual(result['queued_after'], 1)
        foreign.unlink()
        result = self.clean(mode='cleanup-queue')
        self.assertEqual((result['directories_removed'], result['queued_after']), (1, 0))

    def test_replaced_file_is_retained_and_original_identity_can_resume(self):
        self.seed()
        directory = self.directories[0]
        original = directory / 'catalog.hlc2'
        saved = self.home / 'original-work-file.hlc2'
        original.rename(saved)
        original.write_bytes(b'same name, foreign file identity')
        before = self.files([directory])
        result = self.clean()
        self.assertEqual(result['directories_retained'], 1)
        self.assertEqual(self.files([directory]), before)
        original.unlink()
        saved.rename(original)
        self.assertEqual(self.clean(mode='cleanup-queue')['queued_after'], 0)

    def test_busy_hardlinked_and_extra_stream_files_are_preserved(self):
        self.seed()
        directory = self.directories[0]
        target = directory / 'catalog.hlc2'
        before = self.files([directory])
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.CreateFileW(str(target), 0x80000000, 1, None, 3, 128, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            result = self.clean()
            self.assertEqual(result['directories_retained'], 1)
            self.assertEqual(self.files([directory]), before)
        finally:
            self.assertTrue(kernel.CloseHandle(handle))
        alias = self.home / 'external-hardlink.hlc2'
        os.link(target, alias)
        try:
            self.assertEqual(self.clean()['directories_retained'], 1)
            self.assertEqual(self.files([directory]), before)
            self.assertEqual(fixture.digest(alias), before[str(target)])
        finally:
            alias.unlink()
        directory_stream = Path(str(directory) + ':private-directory-stream')
        directory_stream.write_bytes(b'preserve directory stream')
        try:
            self.assertEqual(self.clean()['directories_retained'], 1)
            self.assertEqual(self.files([directory]), before)
            self.assertEqual(directory_stream.read_bytes(), b'preserve directory stream')
        finally:
            directory_stream.unlink()
        stream = Path(str(target) + ':private-stream')
        stream.write_bytes(b'private stream data')
        try:
            self.assertEqual(self.clean()['directories_retained'], 1)
            self.assertEqual(self.files([directory]), before)
            self.assertEqual(stream.read_bytes(), b'private stream data')
        finally:
            stream.unlink()
        self.assertEqual(self.clean(mode='cleanup-queue')['queued_after'], 0)

    def test_cancel_and_process_exit_after_unlink_resume_without_recopy(self):
        self.seed()
        result = self.clean(cancel_cleanup_stage='cleanup-after-file')
        self.assertTrue(result['stopped'])
        self.assertEqual(result['files_removed'], 1)
        self.assertEqual(result['queued_after'], 1)
        self.clean(97, mode='cleanup-queue', crash='cleanup-after-file')
        result = self.clean(mode='cleanup-queue')
        self.assertFalse(result['warning'])
        self.assertEqual(result['queued_after'], 0)
        self.assertTrue(all(not p.exists() for p in self.directories))

    def test_process_exit_after_directory_removal_before_marker_is_retryable(self):
        self.seed()
        self.clean(97, crash='cleanup-before-record')
        self.assertTrue(all(not p.exists() for p in self.directories))
        result = self.clean(mode='cleanup-queue', cleanup_worker=True)
        self.assertEqual((result['files_removed'], result['directories_missing'], result['queued_after']), (0, 2, 0))

    def test_cleanup_does_not_require_live_destination_and_open_can_be_cancelled(self):
        self.seed()
        before = self.database_bytes()
        self.assertIn('остановлена', self.clean('fail', cleanup_cancel_immediately=True))
        self.assertEqual(self.database_bytes(), before)
        self.assertEqual(self.files(self.directories), self.work_files)
        offline = self.home / 'offline-destination'
        self.destination.rename(offline)
        try:
            # This test deliberately makes published payload paths inaccessible.
            # Cleanup still only removes work data, preserving the offline files.
            self.config.update(mode='cleanup-queue', complete_only=False, crash='',
                               cleanup_cancel_immediately=False, cancel_cleanup_stage='')
            result = self.run_case()
            self.assertEqual((result['directories_removed'], result['queued_after']), (2, 0))
        finally:
            offline.rename(self.destination)
        self.assertEqual(self.finish(), self.completed)

    def test_foreign_directory_claim_refuses_before_deleting_any_snapshot(self):
        self.seed()
        with fixture.connect(self.personal) as db:
            db.execute("UPDATE HomeLibreTransferCacheClaims SET Directory=?,Path=? WHERE Stage='cache-directory-created' AND Directory=?",
                       (str(self.cache_a), str(self.cache_a), str(self.directories[0])))
        before = self.database_bytes()
        self.assertIn('папка рабочих данных', self.clean('fail'))
        self.assertEqual(self.database_bytes(), before)
        self.assertEqual(self.files(self.directories), self.work_files)

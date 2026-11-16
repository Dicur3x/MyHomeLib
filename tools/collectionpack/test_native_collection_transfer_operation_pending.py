"""Do not finalize roots while an external reader defers original unlink."""
import ctypes
from ctypes import wintypes

import test_native_collection_transfer_cache_metadata as metadata


class TransferOperationPendingTests(metadata.TransferCacheMetadataTests):
    def test_deferred_original_delays_roots_then_resumes_without_recopy(self):
        self.check_pending_reader(7, True)

    def test_reader_without_delete_sharing_retains_original_on_continuation(self):
        self.check_pending_reader(3, True)

    def test_roots_only_request_also_waits_for_deferred_original(self):
        self.check_pending_reader(7, False)

    def check_pending_reader(self, sharing, publish):
        self.config['publish_cache_settings'] = publish
        source = self.a / 'same.zip'
        before_sha = metadata.fixture.digest(source)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.CreateFileW(str(source), 0x80000000, sharing, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)

        def release_reader():
            nonlocal handle
            kernel.CloseHandle(handle)
            handle = None

        self.after_native = release_reader
        try:
            first = self.run_case()
            if sharing == 3:
                # An original that cannot be held for deletion is retained,
                # not an already-authorized deletion waiting for its reader.
                self.assertEqual((first['pending_sources'], first['retained_sources']), (0, 1))
                self.assertTrue(first['roots_applied'])
                self.assert_published()
                self.assertTrue(source.exists())
                self.assertEqual(metadata.fixture.digest(source), before_sha)
            else:
                self.assertEqual(first['pending_sources'], 1)
                self.assertFalse(first['roots_applied'], 'Pending unlink must not enter the roots-only resume branch')
                self.assertEqual(first['published_cache_databases'], 0)
                self.assertIsNone(self.publication())
        finally:
            if handle:
                release_reader()

        result = self.continue_metadata(finalize_roots=True)
        self.assertEqual((result['copy_streams'], result['pending_sources']), (0, 0))
        self.assertTrue(result['roots_applied'])
        if publish:
            self.assert_published()
        else:
            self.assertEqual(result['published_cache_databases'], 0)
            self.assertIsNone(self.publication())
        self.assertTrue(all(row['State'] in ('removed', 'missing', 'retained') for row in self.intents().values()))
        if sharing == 3:
            self.assertTrue(source.exists())
            self.assertEqual(metadata.fixture.digest(source), before_sha)
            self.assertEqual(sum(row['State'] == 'retained' for row in self.intents().values()), 1)

"""Disk-backed whole-collection planning through the normal native resolver."""
import copy
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

import test_native_compression_plan as plans
from test_native_compression_receipt import database, sha


@unittest.skipUnless(os.name == 'nt' and plans.PLANNER and plans.PLANNER.is_file(),
                     'Built native application planner required')
class NativeCompressionCollectionTests(unittest.TestCase):
    setUp = plans.NativeCompressionPlanTests.setUp
    tearDown = plans.NativeCompressionPlanTests.tearDown
    unchanged = plans.NativeCompressionPlanTests.unchanged

    def capture(self, success=True):
        self.config.update(whole=True, work_root=str(self.root / 'plan-work'))
        result = plans.NativeCompressionPlanTests.capture(self, success)
        self.assertFalse(list((self.root / 'plan-work').glob('collection-plan-*')))
        return result

    def test_all_members_grouped_once_and_personal_fields_preserved(self):
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count']), (1, 2))
        self.assertEqual(set(result['files'][0]['members']), {'one.fb2', 'neighbor.fb2'})
        rows = result['files'][0]['receipt_template']['rows']
        self.assertEqual(len(rows), 5)
        self.assertEqual({r['id'] for r in rows if r['kind'] == 1}, {101, 102})
        self.assertEqual(result['warning'], '')
        self.unchanged()

    def test_three_sources_and_personal_only_stale_source_is_not_selected(self):
        for name in ('second', 'third', 'personal-only'):
            (self.root / name).mkdir()
            shutil.copyfile(self.fixture.source, self.root / name / 'books.zip')
        with database(self.catalogue) as db:
            for name in ('second', 'third'):
                db.execute('INSERT INTO CatalogBookCopies SELECT ?,BookID,?,LibID,Folder,FileName,Ext,InsideNo,BookSize '
                           'FROM CatalogBookCopies WHERE SourceKey=?', (name + '#101', str(self.root / name), 'source#101'))
            # A stale copy of a deleted catalogue card must not select its file.
            db.execute('INSERT INTO CatalogBookCopies SELECT ?,999,?,LibID,Folder,FileName,Ext,InsideNo,BookSize '
                       'FROM CatalogBookCopies WHERE SourceKey=?', ('orphan', str(self.root / 'personal-only'), 'source#101'))
        with database(self.personal) as db:
            db.execute("UPDATE Books SET Folder='personal-only\\books.zip' WHERE DatabaseID=7")
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count']), (3, 4))
        sources = {Path(j['source']).parent.name for j in result['files']}
        self.assertNotIn('personal-only', sources)
        self.assertEqual({Path(j['source']).parent.name for j in result['files'] if len(j['members']) == 1}, {'second', 'third'})

    def test_hardlinked_archive_paths_share_one_physical_work_item(self):
        os.link(self.fixture.source, self.root / 'alias.zip')
        with database(self.catalogue) as db:
            db.execute("UPDATE CatalogBookCopies SET Folder='alias.zip'")
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count']), (1, 2))
        self.assertEqual(len(result['files'][0]['receipt_template']['rows']), 5)

    def test_missing_member_does_not_hide_other_members_in_same_archive(self):
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET FileName='missing',InsideNo=999 WHERE BookID=102")
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count'], result['skipped_rows']), (1, 1, 1))
        self.assertEqual(set(result['files'][0]['members']), {'one.fb2'})
        self.assertIn('missing', result['warning'])

    def test_source_changed_after_planning_is_rejected_before_iteration(self):
        self.config.update(mode='change-source', change_path=str(self.fixture.source))
        self.assertIn('Файл изменился после подготовки плана', self.capture(False))
        self.assertEqual(sha(self.catalogue.read_bytes()), self.before[self.catalogue])
        self.assertEqual(sha(self.personal.read_bytes()), self.before[self.personal])

    def test_missing_archive_and_invalid_catalogue_row_reported_without_selecting_personal_file(self):
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET Folder='missing.zip' WHERE BookID=102")
            db.execute('INSERT INTO Books SELECT -5,LibID,Folder,FileName,Ext,InsideNo,BookSize,'
                       'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101')
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count'], result['skipped_rows']), (1, 1, 2))
        self.assertIn('missing.zip', result['warning'])

    def test_all_unavailable_books_leave_an_empty_plan_with_reasons(self):
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET Folder='missing.zip'")
            db.execute('DELETE FROM CatalogBookCopies')
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count'], result['skipped_rows']), (0, 0, 2))
        self.assertEqual(result['files'], [])
        self.assertIn('missing.zip', result['warning'])

    def test_more_than_one_commit_chunk_and_no_main_read_lock_while_visiting(self):
        with database(self.catalogue) as db:
            db.executemany('INSERT INTO Books SELECT ?,LibID,Folder,FileName,Ext,InsideNo,BookSize,'
                           'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101',
                           [(1000 + i,) for i in range(6001)])
        self.config['mode'] = 'write-during-visit'
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count']), (1, 2))
        self.assertEqual(len(result['files'][0]['receipt_template']['rows']), 12007)

    def test_bounded_path_cache_can_roll_over_and_report_all_missing_sources(self):
        with database(self.catalogue) as db:
            db.executemany('INSERT INTO Books SELECT ?,LibID,?,FileName,Ext,InsideNo,BookSize,'
                           'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101',
                           [(1000 + i, 'missing-%d.zip' % i) for i in range(4100)])
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count'], result['skipped_rows']), (1, 2, 4100))
        self.assertLess(len(result['warning']), 4000)

    def test_cancel_during_spool_removes_only_owned_work(self):
        with database(self.catalogue) as db:
            db.executemany('INSERT INTO Books SELECT ?,LibID,Folder,FileName,Ext,InsideNo,BookSize,'
                           'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101',
                           [(1000 + i,) for i in range(2048)])
        self.config['mode'] = 'cancel-scan'
        self.assertIn('остановлено', self.capture(False))
        self.assertTrue(self.fixture.source.is_file())

    def test_case_sensitive_archives_remain_distinct(self):
        folder = self.root / 'case-sensitive'
        folder.mkdir()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = (ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                       ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p)
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.SetFileInformationByHandle.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
        kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
        handle = kernel.CreateFileW(str(folder), 0x180, 7, None, 3, 0x02000000, None)
        if handle == ctypes.c_void_p(-1).value:
            self.skipTest('Case sensitivity unavailable')
        try:
            flags = ctypes.c_uint32(1)
            if not kernel.SetFileInformationByHandle(handle, 23, ctypes.byref(flags), ctypes.sizeof(flags)):
                self.skipTest('Case sensitivity unavailable')
        finally:
            kernel.CloseHandle(handle)
        for name in ('Books.zip', 'books.zip'):
            shutil.copyfile(self.fixture.source, folder / name)
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET Folder='case-sensitive\\Books.zip' WHERE BookID=101")
            db.execute("UPDATE Books SET Folder='case-sensitive\\books.zip',FileName='one',InsideNo=0 WHERE BookID=102")
            db.execute('DELETE FROM CatalogBookCopies')
        result = self.capture()
        self.assertEqual((result['file_count'], result['book_count']), (2, 2))
        self.assertEqual({Path(j['source']).name for j in result['files']}, {'Books.zip', 'books.zip'})

    def store(self, mode):
        self.config.update(mode=mode, work_root=str(self.root / 'plan-work'))
        return plans.NativeCompressionPlanTests.capture(self)

    def test_live_scratch_is_leased_and_normal_destruction_cleans_it(self):
        result = self.store('store-live')
        self.assertEqual(result['removed_live'], 0)
        self.assertFalse(Path(result['folder']).exists())

    def test_crash_scratch_can_be_cleaned_but_foreign_files_remain(self):
        result = self.store('store-leave')
        self.assertTrue(Path(result['folder']).is_dir())
        self.assertEqual(self.store('store-clean')['removed'], 1)
        result = self.store('store-leave')
        foreign = Path(result['folder']) / 'my-book.fb2'
        foreign.write_bytes(self.fixture.original_book)
        self.assertEqual(self.store('store-clean')['removed'], 0)
        self.assertEqual(foreign.read_bytes(), self.fixture.original_book)
        foreign.unlink()
        self.assertEqual(self.store('store-clean')['removed'], 1)

    def test_arbitrary_guid_folder_without_owner_is_not_deleted(self):
        folder = self.root / 'plan-work' / ('collection-plan-{' + str(uuid.uuid4()).upper() + '}')
        folder.mkdir(parents=True)
        (folder / 'plan.sqlite').write_bytes(b'Foreign data')
        self.assertEqual(self.store('store-clean')['removed'], 0)
        self.assertEqual((folder / 'plan.sqlite').read_bytes(), b'Foreign data')


if __name__ == '__main__':
    unittest.main()

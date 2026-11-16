"""Live reference validation and simultaneous writer exclusion before publication."""
import os
import sqlite3
import subprocess
import time

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture


class TransferPublicationFenceTests(location_fixture.TransferLocationTests):
    def review_only(self):
        self.config.update(prepare=False,apply_locations=False)
        self.run_case()
        self.config.update(mode='resume',prepare=True,apply_locations=True)

    def add_book(self,db,book_id=991):
        fixture.insert(db,'Books',dict(BookID=book_id,LibID=str(book_id),Title='Added during copy',
            Folder='same.zip',FileName='101',Ext='.fb2',BookSize=801))

    def test_new_main_reference_is_rejected_before_any_locator_commit(self):
        self.review_only()
        with fixture.connect(self.catalogue) as db:self.add_book(db)
        self.assertIn('Нужен новый план',self.run_case('fail'))

    def test_new_copy_reference_is_rejected_before_any_locator_commit(self):
        self.review_only()
        with fixture.connect(self.catalogue) as db:
            fixture.insert(db,'CatalogBookCopies',dict(SourceKey='new-copy',BookID=2,Root=str(self.a),Folder='same.zip',
                FileName='102',Ext='.fb2',InsideNo=0,BookSize=802,LibID='102'))
        self.assertIn('Нужен новый план',self.run_case('fail'))

    def test_new_personal_archive_reference_without_reviewed_main_book_is_rejected(self):
        self.review_only()
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=991,DatabaseID=7,LibID='991',Folder='same.zip',FileName='101',Ext='.fb2'))
        self.assertIn('Нужен новый план',self.run_case('fail'))

    def test_new_registration_is_detected_before_publishing(self):
        self.review_only()
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=9,BaseName='New registration',DBFileName=str(self.catalogue),RootFolder=str(self.a)))
        self.assertIn('Нужен новый план',self.run_case('fail'))

    def test_new_wal_reference_is_detected(self):
        self.review_only()
        with fixture.connect(self.catalogue) as db:
            self.assertEqual(db.execute('pragma journal_mode=wal').fetchone()[0],'wal')
            self.add_book(db);db.commit()
            self.assertTrue(self.catalogue.with_name(self.catalogue.name+'-wal').is_file())
            self.assertIn('Нужен новый план',self.run_case('fail'))

    def test_unrelated_new_book_does_not_invalidate_prepared_group(self):
        self.review_only()
        with fixture.connect(self.catalogue) as db:
            fixture.insert(db,'Books',dict(BookID=991,LibID='991',Title='Unrelated missing book',
                Folder='unrelated-missing.zip',FileName='991',Ext='.fb2',BookSize=801))
        self.run_case()

    def test_detached_images_publish_and_replay_as_one_group(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        result=self.run_case()
        self.assertEqual(result['prepared_files'],6)
        self.assertEqual(self.resume()['copy_streams'],0)

    def test_cancel_after_fresh_scan_rolls_back_every_database(self):
        self.config['cancel_publication_fence']=True
        self.assertIn('остановлена',self.run_case('fail'))
        self.config.update(mode='resume',cancel_publication_fence=False)
        self.run_case()

    def test_fence_holds_catalogue_and_personal_writer_locks(self):
        release=self.home/'fence-release';self.config['wait_publication_fence']=str(release)
        before=self.snapshots();payloads=self.payloads()
        with subprocess.Popen(self.command(),cwd=self.home,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)}) as process:
            try:
                deadline=time.monotonic()+30
                while not (self.home/'fence-release.waiting').exists():
                    self.assertIsNone(process.poll(),'native fence ended before lock observation')
                    self.assertLess(time.monotonic(),deadline,'native fence marker timed out')
                    time.sleep(.05)
                for path in (self.catalogue,self.personal):
                    db=sqlite3.connect(path,timeout=.1)
                    try:
                        with self.assertRaisesRegex(sqlite3.OperationalError,'locked'):
                            db.execute('BEGIN IMMEDIATE')
                    finally:db.close()
            finally:
                release.write_text('release',encoding='utf-8')
            out,err=process.communicate(timeout=90)
            self.assertEqual(process.returncode,0,(out+err).decode('utf-8',errors='replace'))
        self.check_metadata(before);self.assertEqual(self.payloads(),payloads)


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

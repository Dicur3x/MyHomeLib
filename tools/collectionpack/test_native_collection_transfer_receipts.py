"""Source-free receipt/locator validation under coordinated writer locks."""
from pathlib import Path

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture
import test_native_collection_transfer_registry as registry_fixture
from test_native_collection_transfer_forks import tables


class TransferReceiptTests(location_fixture.TransferLocationTests):
    registry_rows=registry_fixture.TransferRegistryTests.registry_rows
    operation=registry_fixture.TransferRegistryTests.operation
    edit_registry=registry_fixture.TransferRegistryTests.edit_registry
    remove_originals=registry_fixture.TransferRegistryTests.remove_originals

    def setUp(self):
        super().setUp();self.read_only_verification=False
        self.config.update(register_operation=True,register_groups=True,verify_published=True)

    def snapshots(self):
        result=super().snapshots()
        with fixture.connect(self.personal) as db:
            paths=[Path(row[0]) for row in db.execute('select DBFileName from Bases')]
        for path in paths:
            if path.is_file() and path not in result:result[path]=tables(path)
        return result

    def check_metadata(self,before):
        if self.read_only_verification:self.assertEqual(self.snapshots(),before,'receipt verification changed user data')
        else:super().check_metadata(before)

    def verify(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),register_operation=False,
                           register_groups=False,recover_registered_groups=True,apply_locations=False,crash='')
        self.config.update(options);self.read_only_verification=True
        try:return self.run_case(expected)
        finally:self.read_only_verification=False

    def byte_snapshot(self):
        return {str(path):fixture.digest(path) for path in self.snapshots()} | {'state':fixture.digest(self.journal()/'state.sqlite')}

    def test_current_receipts_and_all_writer_locks_are_checked(self):
        self.config['probe_verification_locks']=True
        self.run_case();before=self.byte_snapshot()
        self.assertEqual(self.verify()['copy_streams'],0)
        self.assertEqual(self.byte_snapshot(),before)

    def test_missing_originals_do_not_prevent_read_only_receipt_verification(self):
        self.run_case();self.remove_originals();before=self.byte_snapshot()
        self.assertEqual(self.verify()['copy_streams'],0)
        self.assertEqual(self.byte_snapshot(),before)

    def test_shared_native_picture_groups_verify_without_originals(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        self.run_case();self.remove_originals();before=self.byte_snapshot()
        self.assertEqual(self.verify()['copy_streams'],0);self.assertEqual(self.byte_snapshot(),before)

    def test_fbd_and_linked_locators_verify_without_originals(self):
        location_fixture.TransferLocationTests.test_fbd_and_legacy_linked_format_are_preserved(self)
        self.remove_originals();self.assertEqual(self.verify()['copy_streams'],0)

    def test_catalogue_and_personal_missing_receipts_are_not_recreated(self):
        for i,path in enumerate((self.catalogue,self.personal)):
            with self.subTest(personal=i==1):
                if i:
                    self.tearDown();self.setUp();path=self.personal
                self.run_case()
                with fixture.connect(path) as db:db.execute('delete from HomeLibreTransferLocations where GroupID=1')
                before=self.byte_snapshot()
                self.assertIn('Нет квитанции',self.verify('fail'))
                self.assertEqual(self.byte_snapshot(),before)

    def test_changed_receipt_binding_is_rejected_without_repair(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:db.execute("update HomeLibreTransferLocations set BindingSHA256=? where GroupID=1",('0'*64,))
        before=self.byte_snapshot();self.assertIn('Квитанция расположений',self.verify('fail'))
        self.assertEqual(self.byte_snapshot(),before)

    def test_old_locator_with_an_unchanged_receipt_is_rejected(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:db.execute("update Books set Folder='same.zip' where BookID=1")
        before=self.byte_snapshot();self.assertIn('ещё не сохранён',self.verify('fail'))
        self.assertEqual(self.byte_snapshot(),before)

    def test_new_personal_card_needs_publication_before_verification(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=2,DatabaseID=7,LibID='102',Title='Поздняя карточка',Folder='same.zip',
                FileName='102',Ext='.fb2',InsideNo=0,BookSize=802,Rate=4,Progress=22,Annotation='Поздняя заметка'))
        before=self.byte_snapshot();self.assertIn('Новая личная запись',self.verify('fail'))
        self.assertEqual(self.byte_snapshot(),before)
        self.new_card=True
        self.config.update(mode='resume',apply_locations=True,register_operation=True,register_groups=True,recover_registered_groups=False)
        self.run_case();self.assertEqual(self.verify()['copy_streams'],0)

    def test_deleted_optional_personal_card_is_not_restored(self):
        self.run_case();self.remove_originals()
        with fixture.connect(self.personal) as db:db.execute('delete from Books where DatabaseID=7 and BookID=1')
        before=self.byte_snapshot();self.verify();self.assertEqual(self.byte_snapshot(),before)

    def test_new_notes_and_progress_survive_source_free_verification(self):
        self.run_case();self.remove_originals()
        with fixture.connect(self.personal) as db:
            db.execute("update Books set Annotation='Новая заметка',Progress=93,Rate=3 where DatabaseID=7 and BookID=1")
        before=self.byte_snapshot();self.verify();self.assertEqual(self.byte_snapshot(),before)

    def test_cancelled_verification_rolls_back_locks_without_writes(self):
        self.run_case();before=self.byte_snapshot()
        self.assertIn('остановлен',self.verify('fail',cancel_verification=True))
        self.assertEqual(self.byte_snapshot(),before)
        self.verify(cancel_verification=False,probe_verification_locks=True)

    def test_second_verification_crash_keeps_receipts_and_metadata(self):
        self.run_case();self.remove_originals();before=self.byte_snapshot()
        self.verify(97,crash='locations-after-catalogue-verification')
        self.verify(97,crash='locations-after-catalogue-verification')
        self.assertEqual(self.verify()['copy_streams'],0);self.assertEqual(self.byte_snapshot(),before)

    def test_forked_catalogue_receipts_verify_without_originals(self):
        self.config['probe_verification_locks']=True
        location_fixture.TransferLocationTests.test_same_catalogue_under_different_roots_uses_forks(self)
        self.remove_originals();before=self.byte_snapshot()
        self.assertEqual(self.verify()['copy_streams'],0);self.assertEqual(self.byte_snapshot(),before)

    def test_prepared_proof_alone_does_not_prove_location_commit(self):
        self.config['apply_locations']=False
        self.assertIn('ещё не сохранён',self.run_case('fail'))
        self.assertEqual(self.registry_rows('HomeLibreTransferLocations'),[])
        self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),1)
        self.config.update(mode='resume',apply_locations=True)
        self.assertEqual(self.run_case()['copy_streams'],1)

    def test_removed_old_roots_and_reused_source_name_do_not_change_the_check(self):
        self.run_case();self.remove_originals();before=self.byte_snapshot()
        for root in (self.a,self.b):
            self.assertTrue(root.resolve().is_relative_to(self.home.resolve()));root.rmdir()
        self.verify();self.assertEqual(self.byte_snapshot(),before)
        self.a.mkdir();foreign=self.a/'same.zip';foreign.write_bytes(b'unrelated file after the original move')
        self.verify();self.assertEqual(foreign.read_bytes(),b'unrelated file after the original move')
        self.assertEqual(self.byte_snapshot(),before)


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

"""Independent personal-store registration and recovery without fixture control."""
import hashlib
import shutil
import sqlite3
from contextlib import closing

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture
import test_native_collection_transfer_group_recovery as recovery_fixture
import test_native_collection_transfer_publication_session as publication_fixture


class TransferRegistryTests(location_fixture.TransferLocationTests):
    remove_originals=recovery_fixture.TransferGroupRecoveryTests.remove_originals
    test_one_scan_for_registered_archive_groups=publication_fixture.TransferPublicationSessionTests.test_one_scan_for_many_independent_archive_groups

    def setUp(self):
        super().setUp()
        self.config.update(register_operation=True,register_groups=True)

    def registry_rows(self,table):
        with fixture.connect(self.personal) as db:
            if not db.execute('select count(*) from sqlite_master where name=?',(table,)).fetchone()[0]:return []
            return db.execute('select * from '+table+' order by 1,2').fetchall()

    def operation(self):
        return self.registry_rows('HomeLibreTransferOperations')[0][0]

    def recover(self,expected=0):
        self.config.update(mode='registered',operation=self.operation(),register_operation=False,
                           register_groups=False,recover_registered_groups=True,apply_locations=False,crash='')
        return self.run_case(expected)

    def edit_registry(self,sql):
        with fixture.connect(self.personal) as db:db.execute(sql)

    def read_review(self,sql,params=()):
        if not getattr(self,'offline_review',None):
            return super().read_review(sql,params)
        with closing(sqlite3.connect(self.offline_review.as_uri()+'?mode=ro',uri=True)) as db:
            return db.execute(sql,params).fetchall()

    def test_registered_proofs_are_independent_and_discovery_is_read_only(self):
        result=self.run_case();op=self.registry_rows('HomeLibreTransferOperations')
        self.assertEqual(result['publication_scans'],1)
        self.assertEqual(len(op),1);self.assertEqual(op[0][1:3],(result['directory'],result['review_sha256']))
        self.assertEqual(op[0][-2:],(7,'pending'))
        proofs=self.registry_rows('HomeLibreTransferGroupProofs');self.assertEqual(len(proofs),2)
        self.assertNotIn('group_proofs',self.anchor())
        for operation,group,sha in proofs:
            self.assertEqual(operation,self.operation())
            self.assertEqual(hashlib.sha256((self.journal()/f'prepared-group-{group}.json').read_bytes()).hexdigest(),sha)
        before=fixture.digest(self.personal);self.config['mode']='discover'
        found=self.run_case()['operations'];self.assertEqual(len(found),1)
        self.assertEqual(found[0]['directory'],result['directory']);self.assertEqual(fixture.digest(self.personal),before)

    def test_control_and_originals_can_be_absent_after_repeated_recovery_crashes(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        self.run_case();self.remove_originals();operation=self.operation()
        directory=self.journal();state=fixture.digest(directory/'state.sqlite')
        before=self.registry_rows('HomeLibreTransferGroupProofs');self.control.unlink()
        self.config.update(mode='registered',operation=operation,register_operation=False,register_groups=False,
                           recover_registered_groups=True,apply_locations=False,crash='group-destination-verified')
        self.run_case(97);self.run_case(97)
        self.assertEqual(self.recover()['copy_streams'],0)
        self.assertFalse(self.control.exists());self.assertEqual(fixture.digest(directory/'state.sqlite'),state)
        self.assertEqual(self.registry_rows('HomeLibreTransferGroupProofs'),before)

    def test_changed_independent_proof_is_rejected_and_preserved(self):
        self.run_case();self.remove_originals()
        self.edit_registry("update HomeLibreTransferGroupProofs set ProofSHA256='"+'0'*64+"' where GroupID=1")
        before=self.registry_rows('HomeLibreTransferGroupProofs')
        self.assertIn('независимым подтверждением',self.recover('fail'))
        self.assertEqual(self.registry_rows('HomeLibreTransferGroupProofs'),before)

    def test_changed_operation_binding_is_not_overwritten(self):
        self.run_case();self.edit_registry("update HomeLibreTransferOperations set ReviewSHA256='"+'0'*64+"'")
        before=self.registry_rows('HomeLibreTransferOperations');self.config['mode']='resume'
        self.assertIn('Регистрация переноса изменилась',self.run_case('fail'))
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations'),before)

    def test_unregistered_group_is_refused_before_sealing(self):
        self.config.update(register_operation=False,apply_locations=False)
        self.assertIn('не зарегистрирован',self.run_case('fail'))
        self.assertFalse(list(self.journal().glob('prepared-group-*.json')))
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations'),[])

    def test_cancelled_group_registration_can_resume_without_recopy(self):
        self.config['cancel_registry_commit']=True
        self.assertIn('остановлено',self.run_case('fail'))
        self.assertEqual(self.registry_rows('HomeLibreTransferGroupProofs'),[])
        self.assertEqual(self.registry_rows('HomeLibreTransferLocations'),[])
        self.config.update(mode='resume',cancel_registry_commit=False)
        self.assertEqual(self.run_case()['copy_streams'],1)
        self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),2)

    def test_registration_commit_boundaries_are_idempotent(self):
        for i,point in enumerate(('registry-before-operation-commit','registry-after-operation-commit')):
            with self.subTest(point=point):
                if i:self.tearDown();self.setUp()
                self.config['crash']=point;self.run_case(97)
                self.config.update(mode='resume',crash='');self.run_case()
                self.assertEqual(len(self.registry_rows('HomeLibreTransferOperations')),1)
                self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),2)

    def test_group_registration_commit_boundaries_are_idempotent(self):
        for i,point in enumerate(('registry-before-group-commit','registry-after-group-commit')):
            with self.subTest(point=point):
                if i:self.tearDown();self.setUp()
                self.config['crash']=point;self.run_case(97)
                count=0 if point=='registry-before-group-commit' else 1
                self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),count)
                self.assertEqual(len(self.registry_rows('HomeLibreTransferLocations')),count)
                self.config.update(mode='resume',crash='')
                self.assertEqual(self.run_case()['copy_streams'],1)
                self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),2)

    def test_unavailable_work_directory_remains_discoverable(self):
        self.run_case();before=self.registry_rows('HomeLibreTransferOperations')
        renamed=self.home/'temporarily-unavailable-work'
        self.assertTrue(self.work.resolve().is_relative_to(self.home.resolve()))
        self.assertTrue(renamed.resolve().is_relative_to(self.home.resolve()))
        self.assertFalse(renamed.exists());self.offline_review=renamed/self.journal().name/'review.sqlite'
        self.work.rename(renamed)
        try:
            self.config['mode']='discover';self.assertEqual(len(self.run_case()['operations']),1)
            self.recover('fail');self.assertEqual(self.registry_rows('HomeLibreTransferOperations'),before)
        finally:renamed.rename(self.work);self.offline_review=None
        self.assertEqual(self.recover()['copy_streams'],0)

    def test_empty_registry_discovery_does_not_create_tables(self):
        before=fixture.digest(self.personal);self.config['mode']='discover'
        self.assertEqual(self.run_case()['operations'],[]);self.assertEqual(fixture.digest(self.personal),before)
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations'),[])

    def test_copied_personal_store_cannot_adopt_original_operations(self):
        self.run_case();copied=self.home/'copied-personal.hlc2';shutil.copy2(self.personal,copied)
        before=fixture.digest(copied);self.config.update(mode='discover',personal=str(copied))
        self.assertIn('другой личной базе',self.run_case('fail'))
        self.assertEqual(fixture.digest(copied),before)

    def test_missing_independent_proof_does_not_fall_back_to_mutable_state(self):
        self.run_case();self.remove_originals()
        self.edit_registry('delete from HomeLibreTransferGroupProofs where GroupID=1')
        before=self.registry_rows('HomeLibreTransferGroupProofs')
        self.assertIn('ещё не зарегистрирована',self.recover('fail'))
        self.assertEqual(self.registry_rows('HomeLibreTransferGroupProofs'),before)

    def test_preparation_proof_can_be_registered_without_publishing_locators(self):
        self.config['apply_locations']=False;self.run_case()
        self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),2)
        self.assertEqual(self.registry_rows('HomeLibreTransferLocations'),[])
        with fixture.connect(self.catalogue) as db:
            self.assertEqual(db.execute('select Folder from Books where BookID=1').fetchone()[0],'same.zip')
        before=fixture.digest(self.personal)
        self.assertEqual(self.recover()['copy_streams'],0)
        self.assertEqual(fixture.digest(self.personal),before)


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

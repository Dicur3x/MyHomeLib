"""Production sequential transfer phase and source-free personal reconciliation."""
from pathlib import Path
import os
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture
import test_native_collection_transfer_removal as removal_fixture


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer operation and private stage')
class TransferOperationTests(unittest.TestCase):
    attempts=crashes=0
    write_zip=staticmethod(removal_fixture.TransferRemovalTests.write_zip)
    make_legacy=removal_fixture.TransferRemovalTests.make_legacy
    anchor=removal_fixture.TransferRemovalTests.anchor
    journal=removal_fixture.TransferRemovalTests.journal
    command=removal_fixture.TransferRemovalTests.command
    read_review=removal_fixture.TransferRemovalTests.read_review
    payloads=removal_fixture.TransferRemovalTests.payloads
    snapshots=removal_fixture.TransferRemovalTests.snapshots
    check_metadata=removal_fixture.TransferRemovalTests.check_metadata
    registry_rows=removal_fixture.TransferRemovalTests.registry_rows
    operation=removal_fixture.TransferRemovalTests.operation
    intents=removal_fixture.TransferRemovalTests.intents
    run_case=removal_fixture.TransferRemovalTests.run_case
    assert_targets=removal_fixture.TransferRemovalTests.assert_targets
    tearDown=removal_fixture.TransferRemovalTests.tearDown

    def setUp(self):
        removal_fixture.TransferRemovalTests.setUp(self)
        self.config.update(run_operation=True,remove_sources=True,register_operation=False,register_groups=False)

    def continue_operation(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),crash='',cancel_after_group=False)
        self.config.update(options);return self.run_case(expected)

    def new_personal(self,**values):
        row=dict(BookID=2,DatabaseID=7,LibID='102',Title='Поздняя карточка',Folder='same.zip',
                 FileName='102',Ext='.fb2',InsideNo=0,BookSize=802,Rate=3,Progress=71,Annotation='Свежая заметка')
        row.update(values)
        with fixture.connect(self.personal) as db:fixture.insert(db,'Books',row)
        self.new_card=True

    def test_operation_registers_and_processes_all_groups_sequentially(self):
        result=self.run_case()
        self.assertEqual((result['removed_sources'],result['prepared_files'],result['copy_streams']),(2,2,2))
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1],'pending','root finalization is separate')
        self.assertEqual(self.continue_operation()['copy_streams'],0)
        self.assert_targets()

    def test_operation_stop_keeps_completed_group_and_resumes_the_rest(self):
        self.config['cancel_after_group']=True
        self.assertIn('останов',self.run_case('fail'))
        self.assertEqual(len(self.intents()),1)
        result=self.continue_operation()
        self.assertEqual((result['removed_sources'],result['copy_streams']),(2,1))

    def test_operation_recovers_after_completed_group_process_exit(self):
        self.config['crash']='operation-group-handled';self.run_case(97)
        result=self.continue_operation()
        self.assertEqual((result['removed_sources'],result['copy_streams']),(2,1));self.assert_targets()

    def test_operation_recovers_partial_catalogue_publication_before_personal_proof(self):
        self.config['crash']='locations-after-catalogue-commit';self.run_case(97)
        self.assertEqual(self.registry_rows('HomeLibreTransferGroupProofs'),[])
        result=self.continue_operation()
        self.assertEqual((result['removed_sources'],result['copy_streams']),(2,1))

    def test_operation_recovers_protected_source_and_continues_next_group(self):
        self.config['crash']='file:source-protected';self.run_case(97)
        result=self.continue_operation()
        self.assertEqual((result['removed_sources'],result['copy_streams']),(2,1));self.assert_targets()

    def test_new_personal_card_is_reconciled_after_originals_are_gone(self):
        self.run_case();self.new_personal();result=self.continue_operation()
        self.assertEqual(result['copy_streams'],0)
        with fixture.connect(self.personal) as db:
            row=db.execute('select Folder,FileName,Rate,Progress,Annotation from Books where BookID=2 and DatabaseID=7').fetchone()
        self.assertTrue(Path(row[0]).is_file());self.assertEqual(row[1:],('102',3,71,'Свежая заметка'))

    def test_existing_personal_card_old_path_is_reconciled_without_reverting_notes(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("update Books set Folder='same.zip',FileName='101',Progress=94,Annotation='После переноса' where BookID=1 and DatabaseID=7")
        self.continue_operation()
        with fixture.connect(self.personal) as db:
            folder,progress,note=db.execute('select Folder,Progress,Annotation from Books where BookID=1 and DatabaseID=7').fetchone()
        self.assertTrue(Path(folder).is_file());self.assertEqual((progress,note),(94,'После переноса'))

    def test_source_free_reconciliation_keeps_shared_native_images_readable(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        self.run_case();before={r['Destination']:fixture.digest(r['Destination']) for r in self.intents().values()}
        self.assertEqual(self.continue_operation()['copy_streams'],0)
        self.assertEqual({p:fixture.digest(p) for p in before},before)

    def test_missing_personal_receipt_cannot_be_recreated_after_source_removal(self):
        self.run_case()
        with fixture.connect(self.personal) as db:db.execute('delete from HomeLibreTransferLocations where GroupID=1')
        before=self.registry_rows('HomeLibreTransferLocations')
        self.continue_operation('fail')
        self.assertEqual(self.registry_rows('HomeLibreTransferLocations'),before);self.assert_targets()

    def test_foreign_old_name_is_not_used_to_rebind_a_new_personal_card(self):
        self.run_case();foreign=self.a/'same.zip';self.write_zip(foreign,b'foreign replacement archive')
        before=fixture.digest(foreign);self.new_personal();self.new_card=False
        self.continue_operation()
        self.assertEqual(fixture.digest(foreign),before)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select Folder,Rate,Progress,Annotation from Books where BookID=2 and DatabaseID=7').fetchone(),
                             ('same.zip',3,71,'Свежая заметка'))

    def test_two_reconciliation_crashes_keep_the_new_personal_note(self):
        self.run_case();self.new_personal()
        for _ in range(2):
            self.continue_operation(97,crash='locations-before-personal-commit')
            with fixture.connect(self.personal) as db:
                self.assertEqual(db.execute('select Folder,Progress,Annotation from Books where BookID=2 and DatabaseID=7').fetchone(),
                                 ('same.zip',71,'Свежая заметка'))
        self.assertEqual(self.continue_operation()['copy_streams'],0)

    def test_registered_preparation_without_locations_is_published_before_removal(self):
        self.config.update(run_operation=False,remove_sources=False,register_operation=True,register_groups=True,apply_locations=False)
        self.run_case()
        self.assertEqual(len(self.registry_rows('HomeLibreTransferGroupProofs')),2)
        self.assertEqual(self.registry_rows('HomeLibreTransferLocations'),[])
        self.config.update(run_operation=True,remove_sources=True,register_operation=False,register_groups=False)
        result=self.continue_operation()
        self.assertEqual((result['copy_streams'],result['removed_sources']),(0,2))

    def test_shared_catalogue_fork_is_coordinated_and_keeps_later_metadata(self):
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=8,BaseName='Другой корень',DBFileName=str(self.catalogue),RootFolder=str(self.b)))
        result=self.run_case();self.assertEqual((result['forks'],result['removed_sources']),(1,2))
        with fixture.connect(self.personal) as db:
            fork=Path(db.execute('select DBFileName from Bases where DatabaseID=8').fetchone()[0])
        self.assertNotEqual(fork,self.catalogue)
        with fixture.connect(fork) as db:db.execute("update Books set Title='Поздняя правка' where BookID=1")
        self.assertEqual(self.continue_operation()['copy_streams'],0)
        with fixture.connect(fork) as db:self.assertEqual(db.execute('select Title from Books where BookID=1').fetchone()[0],'Поздняя правка')

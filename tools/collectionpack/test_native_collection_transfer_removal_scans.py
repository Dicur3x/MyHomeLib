"""Reuse reference bindings across removal, with fresh writer-gap validation."""
import copy

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_operation as operation_fixture
import test_native_collection_transfer_publication_session as publication
import test_native_collection_transfer_removal as removal


class TransferRemovalScanTests(publication.TransferPublicationSessionTests):
    run_case = removal.TransferRemovalTests.run_case
    tearDown = removal.TransferRemovalTests.tearDown
    registry_rows = removal.TransferRemovalTests.registry_rows
    operation = removal.TransferRemovalTests.operation
    intents = removal.TransferRemovalTests.intents
    assert_targets = removal.TransferRemovalTests.assert_targets
    continue_operation = operation_fixture.TransferOperationTests.continue_operation

    def setUp(self):
        operation_fixture.TransferOperationTests.setUp(self)
        self.config['probe_removal_gap_locks'] = True

    def check_metadata(self, before):
        if self.config.get('between_group_edit') == 'personal-reference':
            before = copy.deepcopy(before)
            cols = before[self.personal][2]['Books']
            with fixture.connect(self.personal) as db:
                row = db.execute('SELECT * FROM Books WHERE BookID=991 AND DatabaseID=7').fetchone()
            self.assertIsNotNone(row)
            data = dict(zip(cols, row))
            self.assertEqual(data['Folder'], str(self.a/'same.zip'))
            self.assertEqual(data['Annotation'], 'Личная заметка ё')
            before[self.personal][1]['Books'].append(tuple(row))
        super().check_metadata(before)

    def test_many_groups_copy_publish_and_remove_with_one_reference_capture(self):
        for i in range(24):
            name = f'part-{i}.zip'; self.write_zip(self.a/name, b'additional private carrier')
            with fixture.connect(self.catalogue) as db:
                fixture.insert(db, 'Books', dict(BookID=1000+i, LibID=str(1000+i), Title='Extra carrier',
                    Folder=name, FileName='101', Ext='.fb2', BookSize=500))
        result = self.run_case()
        self.assertEqual(result['publication_scans'], getattr(self, 'expected_captures', 1))
        self.assertEqual((result['prepared_files'],result['removed_sources'],result['retained_sources']), (26,26,0))
        self.assertEqual(len(self.intents()),26)
        self.assert_targets()

    def test_external_note_in_intent_commit_gap_refreshes_and_preserves_notes(self):
        self.config.update(between_group_edit='personal-note', edit_stage='removal-intent-committed')
        result = self.run_case()
        self.assertEqual(result['publication_scans'], 2)
        self.assertEqual(result['removed_sources'], 2)
        self.assert_targets()

    def test_external_wal_note_in_gap_is_not_hidden_by_own_intent_commit(self):
        for path in (self.personal,self.catalogue):
            with fixture.connect(path) as db:
                self.assertEqual(db.execute('PRAGMA journal_mode=wal').fetchone()[0], 'wal')
        self.test_external_note_in_intent_commit_gap_refreshes_and_preserves_notes()

    def test_new_personal_reference_in_gap_refuses_before_first_unlink_then_resumes(self):
        self.config.update(between_group_edit='personal-reference', edit_stage='removal-intent-committed',
                           new_reference_container=str(self.a/'same.zip'))
        before = self.payloads()
        self.assertIn('Нужен новый план', self.run_case('fail'))
        self.assertTrue(self.intents(), 'test never reached the durable intent gap')
        self.assertEqual(self.payloads(), before)
        with fixture.connect(self.personal) as db:
            db.execute('DELETE FROM Books WHERE BookID=991 AND DatabaseID=7')
        self.config['between_group_edit'] = ''
        result = self.continue_operation()
        self.assertEqual(result['removed_sources'],2)
        self.assert_targets()

    def test_external_catalogue_commit_before_removal_refreshes_binding_view(self):
        self.config.update(between_group_edit='title', edit_stage='locations-after-catalogue-commit')
        result = self.run_case()
        self.assertEqual(result['publication_scans'],2)
        self.assertEqual(result['removed_sources'],2)
        self.assert_targets()

    def test_external_new_catalogue_reference_before_removal_keeps_originals(self):
        self.config.update(between_group_edit='new-reference', edit_stage='locations-after-catalogue-commit',
                           new_reference_container=str(self.a/'same.zip'))
        before = self.payloads()
        self.assertIn('Нужен новый план', self.run_case('fail'))
        self.assertEqual(self.payloads(), before)

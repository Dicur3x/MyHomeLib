"""One live reference snapshot across groups; external commits invalidate it."""
import copy

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture


class TransferPublicationSessionTests(location_fixture.TransferLocationTests):
    def check_metadata(self,before):
        before=copy.deepcopy(before)
        edit=self.config.get('between_group_edit')
        path=self.personal if edit=='personal-note' else self.catalogue
        if edit in ('personal-note','title','new-reference'):
            cols=before[path][2]['Books'];rows=before[path][1]['Books']
            if edit=='new-reference':
                # The fixture writer deliberately added this one row. Existing
                # rows still undergo the complete locator-only comparison.
                with fixture.connect(path) as db:row=db.execute('select * from Books where BookID=991').fetchone()
                self.assertIsNotNone(row);data=dict(zip(cols,row))
                self.assertEqual(data['Folder'],str(self.b/'same.zip'))
                rows.append(tuple(row))
                sequences=before[path][1].get('sqlite_sequence',[])
                for i,(name,value) in enumerate(sequences):
                    if name=='Books':sequences[i]=(name,max(value,991))
            else:
                for i,row in enumerate(rows):
                    data=dict(zip(cols,row))
                    if data['BookID']==1 and (edit!='personal-note' or data['DatabaseID']==7):
                        if edit=='personal-note':data.update(Annotation='between archives',Progress=92)
                        else:data.update(Title='between archives',SearchTitle='BETWEEN ARCHIVES')
                        rows[i]=tuple(data[c] for c in cols)
        super().check_metadata(before)

    def test_one_scan_for_many_independent_archive_groups(self):
        # This case flushes 26 complete journals; allow bounded disk contention
        # without weakening the one-capture, content or ownership assertions.
        self.native_timeout=180
        with fixture.connect(self.catalogue) as db:
            for i in range(24):
                name=f'part-{i}.zip';self.write_zip(self.a/name,b'additional private carrier')
                fixture.insert(db,'Books',dict(BookID=1000+i,LibID=str(1000+i),Title='Extra carrier',
                    Folder=name,FileName='101',Ext='.fb2',BookSize=500))
        result=self.run_case()
        self.assertEqual(result['publication_scans'],1)
        self.assertEqual((len(result['groups']),result['prepared_files']),(26,26))

    def test_external_title_commit_after_catalogue_commit_invalidates_snapshot(self):
        self.config.update(between_group_edit='title',edit_stage='locations-after-catalogue-commit')
        self.assertEqual(self.run_case()['publication_scans'],2)

    def test_external_personal_note_invalidates_snapshot_and_is_preserved(self):
        self.config['between_group_edit']='personal-note'
        self.assertEqual(self.run_case()['publication_scans'],2)

    def test_external_wal_commit_invalidates_snapshot(self):
        for path in (self.catalogue,self.personal):
            with fixture.connect(path) as db:self.assertEqual(db.execute('pragma journal_mode=wal').fetchone()[0],'wal')
        self.config['between_group_edit']='personal-note'
        self.assertEqual(self.run_case()['publication_scans'],2)

    def test_new_reference_between_groups_is_not_hidden_by_own_commit(self):
        self.config.update(between_group_edit='new-reference',new_reference_container=str(self.b/'same.zip'),
                           edit_stage='locations-after-catalogue-commit')
        self.assertIn('Нужен новый план',self.run_case('fail'))
        # Remove only the deliberate fixture row, then resume the same journal.
        with fixture.connect(self.catalogue) as db:db.execute('delete from Books where BookID=991')
        self.config.update(mode='resume',between_group_edit='')
        self.assertEqual(self.run_case()['copy_streams'],0)

    def test_formerly_missing_catalogue_arrival_invalidates_snapshot(self):
        self.config['between_group_edit']='unknown-arrives'
        self.assertIn('Нужен новый план',self.run_case('fail'))


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

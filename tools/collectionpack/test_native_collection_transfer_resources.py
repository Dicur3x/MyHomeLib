"""Leased file/stream witnesses, native picture mapping and durable validation."""
import json
import sqlite3

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture


class TransferResourceTests(location_fixture.TransferLocationTests):
    def state_rows(self,sql):
        db=sqlite3.connect(self.journal()/'state.sqlite')
        try:return db.execute(sql).fetchall()
        finally:db.close()

    def test_plain_archive_validation_receipts_are_replayable(self):
        result=self.run_case()
        self.assertEqual(result['resource_validations'],2)
        rows=self.state_rows('select GroupID,Kind,ReviewSHA256,ResourcesSHA256,Files,ImageSets,Resources from ResourceValidation order by GroupID')
        self.assertEqual(len(rows),2)
        for row in rows:
            self.assertEqual(row[1],'resources v1');self.assertEqual(row[2],self.anchor()['review_sha256'])
            self.assertEqual(len(row[3]),64);self.assertEqual(row[4:],(1,0,0))
        self.assertEqual(self.resume()['copy_streams'],0)
        self.assertEqual(self.state_rows('select GroupID,Kind,ReviewSHA256,ResourcesSHA256,Files,ImageSets,Resources from ResourceValidation order by GroupID'),rows)

    def test_in_place_files_are_validated_without_copying(self):
        parent=self.home/'in-place';parent.mkdir()
        old_a,old_b=str(self.a),str(self.b)
        for source in (self.a,self.b):
            target=parent/source.name
            self.assertTrue(source.resolve().is_relative_to(self.home.resolve()))
            self.assertTrue(target.resolve().is_relative_to(self.home.resolve()))
            self.assertFalse(target.exists());source.rename(target)
        self.a,self.b=parent/self.a.name,parent/self.b.name
        sources=json.loads(self.sources)
        for source in sources:
            if source['root']==old_a:source['root']=str(self.a)
            elif source['root']==old_b:source['root']=str(self.b)
        self.sources=json.dumps(sources,ensure_ascii=False)
        with fixture.connect(self.catalogue) as db:
            db.execute('update CatalogBookCopies set Root=? where Root=?',(str(self.b),old_b))
            db.execute('update Settings set SettingValue=? where SettingID=?',(self.sources,fixture.SOURCE_PROPERTY))
        with fixture.connect(self.personal) as db:
            db.execute('update Bases set RootFolder=? where DatabaseID=7',(str(self.a),))
            db.execute('update Bases set RootFolder=? where DatabaseID=8',(str(self.b),))
        self.destination=parent;self.config.update(root=str(self.a),destination=str(parent))
        result=self.run_case()
        self.assertEqual((result['copy_streams'],result['resource_validations']),(0,2))

    def test_shared_detached_images_are_selected_from_the_mapped_paths(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        result=self.run_case()
        self.assertEqual(result['resource_validations'],3)
        self.assertEqual(self.state_rows('select Files,ImageSets,Resources from ResourceValidation where ImageSets>0'),[(4,2,4)])

    def test_new_target_cover_is_not_accepted_as_an_original_resource(self):
        self.make_legacy();self.config['foreign_target_cover']=True
        self.assertIn('посторонние картинки',self.run_case('fail'))
        self.assertEqual(self.state_rows('select count(*) from sqlite_master where name="ResourceValidation"'),[(0,)])

    def test_named_streams_stay_pinned_through_resource_validation(self):
        for root in (self.a,self.b):
            with open(str(root/'same.zip')+':HomeLibreNote','wb') as stream:stream.write(b'private stream witness')
        self.config['probe_stream_leases']=True
        result=self.run_case();self.assertEqual(result['resource_validations'],2)
        for (path,) in self.read_review('select Destination from Files'):
            with open(path+':HomeLibreNote','rb') as stream:self.assertEqual(stream.read(),b'private stream witness')
        for root in (self.a,self.b):
            with open(str(root/'same.zip')+':HomeLibreNote','rb') as stream:self.assertEqual(stream.read(),b'private stream witness')

    def test_cancelled_validation_has_no_durable_receipt_or_locator_change(self):
        self.config['cancel_resources']=True
        self.assertIn('остановлена',self.run_case('fail'))
        self.assertEqual(self.state_rows('select count(*) from ResourceValidation'),[(0,)])
        self.config.update(mode='resume',cancel_resources=False)
        self.assertEqual(self.run_case()['resource_validations'],2)

    def test_changed_resource_receipt_is_not_silently_overwritten(self):
        self.config.update(apply_locations=False,verify_resources=True);self.run_case()
        journal_fixture.TransferJournalTests.state_edit(self,"update ResourceValidation set ResourcesSHA256='"+'0'*64+"'")
        self.config['mode']='resume'
        self.assertIn('Квитанция проверки ресурсов',self.run_case('fail'))

    def test_resource_receipt_commit_boundaries_resume_without_recopy(self):
        for i,point in enumerate(('resources-before-commit','resources-after-commit')):
            with self.subTest(point=point):
                if i:self.tearDown();self.setUp()
                self.config['crash']=point;self.run_case(97)
                result=self.resume()
                self.assertEqual(result['copy_streams'],1)
                self.assertEqual(result['resource_validations'],2)


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

"""Catalogue partitioning when final default roots diverge from equal old roots."""
from pathlib import Path
import json
import os
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_operation as operation_fixture


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native final-root fork planning and private stage')
class TransferFinalForkTests(operation_fixture.TransferOperationTests):
    # Use explicit selectors in the focused run; inherited coordinator methods
    # remain valid general regressions when the complete class is requested.
    def alias(self,cid,root):
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=cid,BaseName='Другое подключение '+str(cid),
                DBFileName=str(self.catalogue),RootFolder=str(root)))

    def preview(self):
        self.config.update(run_operation=False,remove_sources=False,prepare=False,apply_locations=False)
        return self.run_case()

    def test_equal_old_roots_fork_before_selected_default_root_changes(self):
        self.alias(8,self.a);result=self.preview()
        self.assertEqual(result['forks'],1)
        self.assertEqual(self.read_review('select RegistrationID from ForkMembers'),[(8,)])
        self.assertTrue(self.read_review('select RootToken from CatalogueForks')[0][0].startswith('retained:'))
        self.assertFalse(self.read_review('select RootToken from ForkMembers')[0][0].startswith('retained:'))

    def test_kept_default_root_does_not_split_equivalent_aliases(self):
        self.alias(8,self.a);self.alias(9,self.a);self.config['destination']=str(self.a)
        self.assertEqual(self.preview()['forks'],0)

    def test_future_split_preserves_other_alias_personal_only_file_and_replay(self):
        self.alias(8,self.a);self.alias(9,self.a)
        unlisted=self.a/'personal-only.fb2';unlisted.write_bytes(b'private other-registration book')
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=89,DatabaseID=8,LibID='89',Title='Личная книга другого подключения',
                Folder='',FileName='personal-only',Ext='.fb2',BookSize=31,Rate=4,Progress=53,Annotation='Не переносить по умолчанию'))
        result=self.run_case();self.assertEqual((result['forks'],result['removed_sources']),(1,2))
        with fixture.connect(self.personal) as db:
            aliases=db.execute('select DBFileName,RootFolder from Bases where DatabaseID in (8,9) order by DatabaseID').fetchall()
        self.assertEqual(aliases[0],aliases[1]);self.assertEqual(Path(aliases[0][1]),self.a)
        self.assertNotEqual(Path(aliases[0][0]),self.catalogue)
        self.assertEqual(unlisted.read_bytes(),b'private other-registration book')
        self.assertEqual(self.continue_operation()['copy_streams'],0)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select Folder,FileName,Progress,Annotation from Books where BookID=89 and DatabaseID=8').fetchone(),
                             ('','personal-only',53,'Не переносить по умолчанию'))

    def test_retained_equal_root_aliases_do_not_share_a_different_root_fork(self):
        self.alias(8,self.b);self.alias(9,self.a)
        self.assertEqual(self.preview()['forks'],2)
        members=dict(self.read_review('select RegistrationID,ForkID from ForkMembers'))
        self.assertNotEqual(members[8],members[9])
        self.assertEqual(self.read_review('select count(*) from ForkSources'),[(1,)])

    def external_source(self,**overrides):
        source=dict(id='alias-source',name='Подключённый каталог',root=str(self.a),inpx='',
                    collection=8,file=str(self.catalogue),custom={'keep':'source metadata'})
        source.update(overrides)
        self.sources=json.dumps([source],ensure_ascii=False)
        with fixture.connect(self.catalogue) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?',(self.sources,fixture.SOURCE_PROPERTY))
        self.config['final_layout']=True
        return source

    def projected_source(self,result):
        return json.loads(result['final_layout']['sources_json'])[0]

    def test_external_source_catalogue_file_follows_the_planned_registration_fork(self):
        self.alias(8,self.a);source=self.external_source();result=self.preview()
        fork=self.read_review('select Destination from CatalogueForks')[0][0]
        roots={r['id']:r['destination'] for r in result['final_layout']['roots']}
        self.assertEqual(self.projected_source(result),dict(source,file=fork,root=roots['source:alias-source']))
        self.assertFalse(Path(fork).exists(),'read-only projection must not publish the fork')

    def test_external_source_file_matches_published_fork_and_source_free_replay(self):
        self.alias(8,self.a);self.external_source();result=self.run_case()
        projected=self.projected_source(result)
        with fixture.connect(self.personal) as db:
            registered=db.execute('select DBFileName from Bases where DatabaseID=8').fetchone()[0]
        self.assertEqual(projected['file'],registered)
        self.assertEqual(self.projected_source(self.continue_operation()),projected)

    def test_inpx_source_file_field_is_not_replaced_by_a_registration_fork(self):
        self.alias(8,self.a);source=self.external_source(inpx=str(self.home/'new.inpx'))
        self.assertEqual(self.projected_source(self.preview())['file'],source['file'])

    def test_mismatched_external_source_file_is_refused_without_metadata_changes(self):
        self.alias(8,self.a);self.external_source(file=str(self.home/'wrong.hlc2'))
        self.config.update(run_operation=False,remove_sources=False,prepare=False,apply_locations=False)
        self.assertIn('Файл исходной коллекции',self.run_case('fail'))
        self.assertFalse(list(self.destination.iterdir()))

    def test_kept_equivalent_alias_preserves_external_source_catalogue_file(self):
        self.alias(8,self.a);source=self.external_source();self.config['destination']=str(self.a)
        result=self.preview();self.assertEqual(result['forks'],0)
        self.assertEqual(self.projected_source(result)['file'],source['file'])

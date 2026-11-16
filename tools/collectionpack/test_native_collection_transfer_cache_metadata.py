"""Atomic source/history cutover, per-database receipts and roots replay."""
import copy
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cache_installation as installation
import test_native_collection_transfer_cache_preparation as preparation
import test_native_collection_transfer_locations as locations

PUBLICATION='HomeLibreTransferCachePublication'
RECEIPT='HomeLibreTransferCacheMetadata'
locations.MARKERS.update((PUBLICATION,RECEIPT))


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache metadata publication and private stage')
class TransferCacheMetadataTests(installation.TransferCacheInstallationTests):
    def setUp(self):
        super().setUp()
        self.config.update(install_cache_versions=False,publish_cache_settings=True,probe_prepared_cache_guards=False)

    def check_metadata(self,before):
        expected=copy.deepcopy(before)
        plan=self.intent()
        if plan:
            for path,(_,tables,columns) in expected.items():
                if path==self.personal:continue
                with fixture.connect(path) as db:
                    marked=bool(db.execute('select count(*) from sqlite_master where name=?',(RECEIPT,)).fetchone()[0])
                    if marked:marked=bool(db.execute('select count(*) from '+RECEIPT).fetchone()[0])
                had=bool(tables.get(RECEIPT))
                if marked and not had:
                    row=next(r for r in plan['databases'] if Path(r['path'])==path)
                    cols=columns['Settings'];updated=[]
                    for values in tables['Settings']:
                        data=dict(zip(cols,values))
                        if data['SettingID']==fixture.SOURCE_PROPERTY:data['SettingValue']=row['sources_after']
                        if data['SettingID']==preparation.HISTORY_PROPERTY:data['SettingValue']=row['history_after']
                        updated.append(tuple(data[c] for c in cols))
                    tables['Settings']=updated
                if path==self.catalogue and getattr(self,'expect_cache_gap_title',False):
                    cols=columns['Books'];rows=[]
                    for values in tables['Books']:
                        data=dict(zip(cols,values))
                        if data['BookID']==1:data['Title']='late cache metadata title'
                        rows.append(tuple(data[c] for c in cols))
                    tables['Books']=rows
        super().check_metadata(expected)

    def publication(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('select count(*) from sqlite_master where name=?',(PUBLICATION,)).fetchone()[0]:return None
            cols=[r[1] for r in db.execute('pragma table_info('+PUBLICATION+')')]
            rows=db.execute('select * from '+PUBLICATION).fetchall()
        self.assertEqual(len(rows),1);return dict(zip(cols,rows[0]))

    def metadata_rows(self):
        result={}
        for row in self.intent()['databases']:
            path=Path(row['path'])
            with fixture.connect(path) as db:
                if not db.execute('select count(*) from sqlite_master where name=?',(RECEIPT,)).fetchone()[0]:continue
                cols=[r[1] for r in db.execute('pragma table_info('+RECEIPT+')')]
                receipts=db.execute('select * from '+RECEIPT).fetchall()
                if receipts:self.assertEqual(len(receipts),1);result[path]=dict(zip(cols,receipts[0]))
        return result

    def assert_published(self,count=1):
        intent=self.publication();self.assertEqual(intent['State'],'published')
        plan=self.intent();receipts=self.metadata_rows();self.assertEqual(len(receipts),count)
        self.assertEqual(len(plan['databases']),count)
        for row in plan['databases']:
            path=Path(row['path']);receipt=receipts[path]
            for key in ('ReviewSHA256','CacheSHA256','RootSHA256','InstallSetSHA256'):
                self.assertEqual(receipt[key],intent[key])
            self.assertEqual(receipt['DatabaseKey'],row['key'])
            with fixture.connect(path) as db:
                actual=dict(db.execute('select SettingID,SettingValue from Settings'))
            self.assertEqual(actual.get(fixture.SOURCE_PROPERTY,''),row['sources_after'])
            self.assertEqual(actual.get(preparation.HISTORY_PROPERTY,''),row['history_after'])
            self.assertEqual(receipt['SourceSHA256'],hashlib.sha256(row['sources_after'].encode()).hexdigest())
            self.assertEqual(receipt['HistorySHA256'],hashlib.sha256(row['history_after'].encode()).hexdigest())
        for row in self.install_rows():self.assertEqual(row['State'],'published')
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1],'pending','whole-operation completion remains separate')

    def continue_metadata(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),crash='',cancel_cache_preparation_stage='',
                           edit_cache_metadata_gap=False,finalize_roots=False)
        self.config.update(options);return self.run_case(expected)

    def test_coordinator_cuts_over_sources_and_history_then_replays_without_database_writes(self):
        self.config['read_installed_caches']=True
        result=self.run_case();self.assertEqual(result['published_cache_databases'],1);self.assert_published()
        self.assertEqual(len(result['installed_book_hashes']),2)
        hashes={r['source']:r['sha256'].lower() for r in result['installed_book_hashes']}
        self.assertEqual(set(hashes.values()),{hashlib.sha256(b'first').hexdigest(),hashlib.sha256(b'second').hexdigest()})
        before={p:fixture.digest(p) for p in (self.catalogue,self.personal)}
        result=self.continue_metadata(publish_cache_settings=False)
        self.assertEqual((result['published_cache_databases'],result['copy_streams']),(1,0));self.assert_published()
        self.assertEqual({p:fixture.digest(p) for p in before},before)

    def test_all_six_publication_commit_boundaries_resume_the_same_versions(self):
        for point in ('cache-metadata-before-intent-commit','cache-metadata-intent-committed',
                      'cache-metadata-before-catalogue-commit','cache-metadata-after-catalogue-commit',
                      'cache-metadata-before-complete-commit','cache-metadata-complete'):
            with self.subTest(point=point):
                self.config['crash']=point;self.run_case(97)
                self.config.update(mode='registered',operation=self.operation())
        self.continue_metadata(publish_cache_settings=False);self.assert_published()

    def add_other_catalogue(self):
        self.other=self.home/'other-ready-catalogue.hlc2'
        with fixture.connect(self.catalogue) as source,fixture.connect(self.other) as target:source.backup(target)
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=8,BaseName='Other participating catalogue',
                DBFileName=str(self.other),RootFolder=str(self.a)))
            fixture.insert(db,'Books',dict(BookID=1,DatabaseID=8,LibID='101',Title='Other personal card',
                Folder='same.zip',FileName='101',Ext='.fb2',BookSize=801,Rate=2,Progress=62,Annotation='Other personal data'))

    def test_partial_two_database_commit_recovers_without_old_caches_or_work_snapshots(self):
        self.add_other_catalogue();self.config['crash']='cache-metadata-after-catalogue-commit';self.run_case(97)
        self.assertEqual(len(self.metadata_rows()),1);self.assertEqual(self.publication()['State'],'intent')
        for i,(_,directory,_,_) in enumerate(self.stage_rows()):
            path=Path(directory);self.assertTrue(path.resolve().is_relative_to(self.journal().resolve()))
            path.rename(self.home/('offline-work-snapshot-'+str(i)))
        self.cache_a.rename(self.home/'offline-baseline-a');self.cache_b.rename(self.home/'offline-baseline-b')
        result=self.continue_metadata(publish_cache_settings=False)
        self.assertEqual(result['published_cache_databases'],2);self.assert_published(2)

    def test_cancel_before_catalogue_commit_rolls_back_both_properties_and_resumes(self):
        self.config['cancel_cache_preparation_stage']='cache-metadata-before-catalogue-commit'
        self.assertIn('останов',self.run_case('fail'))
        self.assertEqual(self.publication()['State'],'intent');self.assertFalse(self.metadata_rows())
        self.continue_metadata();self.assert_published()

    def test_foreign_writer_in_commit_gap_preserves_its_title_and_requires_revalidation(self):
        self.config.update(publish_cache_settings=False,install_cache_versions=True)
        self.run_case();self.config.update(publish_cache_settings=True,install_cache_versions=False)
        self.expect_cache_gap_title=True
        self.assertIn('между этапами',self.continue_metadata('fail',edit_cache_metadata_gap=True))
        self.continue_metadata();self.assert_published()
        with fixture.connect(self.catalogue) as db:self.assertEqual(db.execute('select Title from Books where BookID=1').fetchone()[0],'late cache metadata title')

    def test_personal_notes_ratings_and_progress_after_publication_survive_continuation(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("update Books set Annotation='New personal note',Progress=87,Rate=3 where BookID=1 and DatabaseID=7")
        self.continue_metadata(publish_cache_settings=False);self.assert_published()
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select Annotation,Progress,Rate from Books where BookID=1 and DatabaseID=7').fetchone(),('New personal note',87,3))

    def test_missing_published_receipt_is_refused_without_resetting_sources(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:db.execute('delete from '+RECEIPT)
        self.assertIn('Потеряна квитанция',self.continue_metadata('fail'))
        with fixture.connect(self.catalogue) as db:self.assertFalse(db.execute('select * from '+RECEIPT).fetchall())

    def test_changed_source_setting_after_publication_is_not_restored(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            text=db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0]
            value=json.loads(text);value[0]['custom']['foreign']='keep user edit';text=json.dumps(value)
            db.execute('update Settings set SettingValue=? where SettingID=?',(text,fixture.SOURCE_PROPERTY))
        self.assertIn('Источники изменились',self.continue_metadata('fail'))
        with fixture.connect(self.catalogue) as db:self.assertEqual(db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0],text)

    def test_changed_history_after_publication_is_not_restored(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            text=db.execute('select SettingValue from Settings where SettingID=?',(preparation.HISTORY_PROPERTY,)).fetchone()[0]
            value=json.loads(text);value['custom']['foreign']='keep user history';text=json.dumps(value)
            db.execute('update Settings set SettingValue=? where SettingID=?',(text,preparation.HISTORY_PROPERTY))
        self.assertIn('История обновлений изменилась',self.continue_metadata('fail'))
        with fixture.connect(self.catalogue) as db:self.assertEqual(db.execute('select SettingValue from Settings where SettingID=?',(preparation.HISTORY_PROPERTY,)).fetchone()[0],text)

    def test_changed_installation_record_refuses_partial_cutover_without_repair(self):
        self.add_other_catalogue();self.config['crash']='cache-metadata-after-catalogue-commit';self.run_case(97)
        with fixture.connect(self.personal) as db:db.execute('update '+installation.INSTALL+' set DirectoryKey=?',('0'*25,))
        self.assertIn('Независимая запись установки',self.continue_metadata('fail',publish_cache_settings=False))
        self.assertEqual(len(self.metadata_rows()),1);self.assertEqual(self.publication()['State'],'intent')

    def test_changed_publication_context_is_refused_without_resetting_settings(self):
        self.run_case()
        with fixture.connect(self.personal) as db:db.execute('update '+PUBLICATION+' set InstallSetSHA256=?',('0'*64,))
        self.assertIn('Независимое намерение публикации',self.continue_metadata('fail'))

    def test_missing_installed_proof_is_not_rebuilt_after_sources_use_it(self):
        self.run_case()
        with fixture.connect(self.personal) as db:db.execute('update '+installation.INSTALL+" set ProofSHA=''")
        self.assertIn('Не все постоянные версии',self.continue_metadata('fail'))

    def test_rehashed_manifest_members_are_validated_before_opening_any_foreign_path(self):
        self.run_case();row=self.install_rows()[0]
        outside=Path(row['Destination']).parent/'outside-proof.dat';outside.write_bytes(b'do not open this file')
        proof=json.loads(row['ProofJSON']);proof['files'][0]['name']='../outside-proof.dat'
        raw=json.dumps(proof,ensure_ascii=False,separators=(',',':'))
        with fixture.connect(self.personal) as db:
            db.execute('update '+installation.INSTALL+' set ProofJSON=?,ProofSHA=? where Job=?',
                       (raw,hashlib.sha256(raw.encode()).hexdigest(),row['Job']))
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        kernel.CreateFileW.restype=wintypes.HANDLE;kernel.CloseHandle.argtypes=[wintypes.HANDLE]
        handle=kernel.CreateFileW('\\\\?\\'+str(outside.resolve()),0x80000000,0,None,3,0x80,None)
        self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
        try:self.assertIn('Неверный состав установленного кэша',self.continue_metadata('fail'))
        finally:kernel.CloseHandle(handle)
        self.assertEqual(outside.read_bytes(),b'do not open this file')

"""Consistent cache snapshots and raw inputs on an owned work volume."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cache_settings as settings
import test_native_collection_transfer_locations as locations


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache snapshot and private stage')
class TransferCacheSnapshotTests(settings.TransferCacheSettingsTests):
    def setUp(self):
        super().setUp()
        # Replace only this private cache's sentinel with a real SQLite schema.
        (self.cache_a/'catalog.hlc2').unlink()
        with fixture.connect(self.catalogue) as source,fixture.connect(self.cache_a/'catalog.hlc2') as target:
            source.backup(target)
        with fixture.connect(self.cache_a/'catalog.hlc2') as db:
            db.execute("update Books set UpdateDate='2026-11-16'")
        data=self.planned()
        self.job=next(row for row in data['cache_jobs'] if row['source']==settings.A and Path(row['after_root'])==self.mapped(self.a))
        self.inputs=[row for row in data['cache_inputs'] if row['job']==self.job['job']]
        self.parent=self.home/'cache-snapshot-parent.sqlite'
        self.config.update(mode='resume',cache_settings=False,cache_other_alias=False,prepare=True,
                           cache_snapshot_parent=str(self.parent),probe_cache_snapshot_writer=True,read_cache_snapshot=True)
        self.set_request(self.job,self.inputs)

    def set_request(self,job,inputs):
        job_json=json.dumps(job,ensure_ascii=False,separators=(',',':'))
        inputs_json=json.dumps(inputs,ensure_ascii=False,separators=(',',':'))
        binding=hashlib.sha256(('HomeLibre cache snapshot v1\0'+self.anchor()['review_sha256']+'\0'+job_json+'\0'+inputs_json).encode()).hexdigest()
        self.config.update(cache_snapshot_job=job_json,cache_snapshot_inputs=inputs_json,cache_snapshot_binding=binding)

    def protected_inputs(self):
        # WAL/SHM are connection state. Logical data and main/index bytes are
        # independently compared while the fixture keeps its WAL writer alive.
        paths=[self.cache_a/'catalog.hlc2',self.cache_a/'retained.inpx',self.external_index]
        return {str(p):fixture.digest(p) for p in paths if p.is_file()}

    def parent_state(self):
        with fixture.connect(self.parent) as db:
            return db.execute('select Directory,DirectoryKey,ReadySHA from CacheSnapshotState where Context=?',
                              (self.config['cache_snapshot_binding'],)).fetchone()

    def run_snapshot(self,expected=0):
        before=self.protected_inputs();result=self.run_case(expected)
        self.assertEqual(self.protected_inputs(),before)
        self.assertFalse(Path(self.job['after_file']).parent.exists(),'snapshot published a persistent cache version')
        if expected==0:
            proof=json.loads(result['snapshot_proof']);directory=Path(result['snapshot_directory'])
            self.assertTrue(directory.is_relative_to(self.journal()))
            self.assertEqual(hashlib.sha256(result['snapshot_proof'].encode()).hexdigest(),result['snapshot_ready_sha256'].lower())
            self.assertEqual(proof['binding'].lower(),self.config['cache_snapshot_binding'])
            self.assertEqual(len(proof['files']),len(self.inputs)+1)
            for row in proof['files']:
                path=directory/row['name'];self.assertEqual(fixture.digest(path),row['sha256'].lower())
                self.assertEqual(path.stat().st_size,row['bytes'])
            self.assertEqual(result['snapshot_book_hash'].lower(),hashlib.sha256(b'first').hexdigest())
            for row in self.inputs:
                self.assertEqual((directory/Path(row['target_file']).name).read_bytes(),Path(row['source_file']).read_bytes())
            with fixture.connect(self.cache_a/'catalog.hlc2') as db:
                # Snapshot object's writer transaction ended with its process.
                db.execute('BEGIN IMMEDIATE');db.rollback()
        return result

    def recover(self,expected=0,**options):
        self.config.update(prepare=False,recover_cache_snapshot=True,crash='',cancel_cache_snapshot_stage='')
        self.config.update(options);return self.run_snapshot(expected)

    def test_snapshot_keeps_source_locked_and_preserves_streams_and_raw_indices(self):
        first=self.run_snapshot();self.assertTrue(first['snapshot_source_held'])
        second=self.recover();self.assertFalse(second['snapshot_source_held'])
        self.assertEqual(first['snapshot_proof'],second['snapshot_proof'])
        with fixture.connect(self.parent) as db:
            claims=db.execute('select Stage,Path,Data from CacheSnapshotOwnership').fetchall()
        self.assertTrue(any(row[0]=='cache-file-reserved' and Path(row[1]).name=='catalog.hlc2' for row in claims))

    def test_snapshot_includes_committed_wal_rows_without_changing_source_data(self):
        with fixture.connect(self.cache_a/'catalog.hlc2') as db:
            db.execute('pragma journal_mode=wal');db.execute('pragma wal_autocheckpoint=0')
            db.execute("update Books set Title='committed WAL title' where BookID=1");db.commit()
            self.assertGreater((self.cache_a/'catalog.hlc2-wal').stat().st_size,0)
            before=db.execute('select BookID,Title,Folder,FileName,Ext from Books order by BookID').fetchall()
            result=self.run_snapshot()
            with fixture.connect(Path(result['snapshot_directory'])/'catalog.hlc2') as cloned:
                self.assertEqual(cloned.execute('select Title from Books where BookID=1').fetchone()[0],'committed WAL title')
            self.assertEqual(db.execute('select BookID,Title,Folder,FileName,Ext from Books order by BookID').fetchall(),before)

    def test_ready_snapshot_recovers_when_original_cache_and_indices_are_offline(self):
        first=self.run_snapshot();self.cache_a.rename(self.home/'offline-cache-a')
        self.config.update(prepare=False,recover_cache_snapshot=True,probe_cache_snapshot_writer=False)
        result=self.run_case();self.assertEqual(result['snapshot_proof'],first['snapshot_proof'])
        self.assertFalse(result['snapshot_source_held'])
        self.assertEqual(result['snapshot_book_hash'].lower(),hashlib.sha256(b'first').hexdigest())

    def test_crash_after_ready_record_recovers_from_independent_parent_proof(self):
        self.config['crash']='cache-ready';self.run_snapshot(97)
        state=self.parent_state();self.assertEqual(len(state[2]),64)
        result=self.recover();self.assertEqual(result['snapshot_directory'],state[0])

    def test_unready_crash_cannot_be_recovered_as_complete_and_a_new_stage_can_be_built(self):
        self.config['crash']='cache-before-projection-commit';self.run_snapshot(97)
        old=self.parent_state();self.assertEqual(old[2],'')
        self.assertIn('Нет независимого подтверждения',self.recover('fail'))
        self.config.update(recover_cache_snapshot=False,crash='');result=self.run_snapshot()
        self.assertNotEqual(result['snapshot_directory'],old[0])
        self.assertTrue(Path(old[0]).exists(),'unready stage was deleted without its cleanup controller')

    def test_cancellation_before_projection_commit_releases_source_and_preserves_original(self):
        self.config['cancel_cache_snapshot_stage']='cache-before-projection-commit'
        self.assertIn('Fixture snapshot stop',self.run_snapshot('fail'))
        self.assertEqual(self.parent_state()[2],'')
        self.config['cancel_cache_snapshot_stage']='';self.run_snapshot()

    def test_wrong_expected_raw_index_digest_refuses_a_ready_snapshot(self):
        inputs=copy.deepcopy(self.inputs);inputs[0]['sha256']='a'*64;self.set_request(self.job,inputs)
        self.assertIn('контрольная сумма',self.run_snapshot('fail'))
        self.assertEqual(self.parent_state()[2],'')

    def test_recovery_refuses_changed_cache_bytes_even_with_the_original_ready_manifest(self):
        first=self.run_snapshot();path=Path(first['snapshot_directory'])/'catalog.hlc2'
        with fixture.connect(path) as db:db.execute("update Books set Title='foreign changed cache' where BookID=1")
        self.assertIn('Изменён файл',self.recover('fail'))

    def test_recovery_refuses_changed_independent_ready_digest(self):
        self.run_snapshot()
        with fixture.connect(self.parent) as db:db.execute('update CacheSnapshotState set ReadySHA=?',('0'*64,))
        self.assertIn('Изменено подтверждение',self.recover('fail'))

    def test_changed_request_without_its_independent_binding_is_refused_before_stage_creation(self):
        job=copy.deepcopy(self.job);job['library']='different';self.config['cache_snapshot_job']=json.dumps(job)
        before=list(self.journal().glob('cache-snapshot-*'))
        self.assertIn('Нет независимой привязки',self.run_snapshot('fail'))
        self.assertEqual(list(self.journal().glob('cache-snapshot-*')),before)

    def test_reserved_backup_api_refuses_an_existing_catalogue_as_destination(self):
        self.config['backup_to_nonempty_target']=str(self.catalogue)
        before=list(self.journal().glob('cache-snapshot-*'))
        self.assertIn('уже содержит данные',self.run_snapshot('fail'))
        self.assertEqual(list(self.journal().glob('cache-snapshot-*')),before)

    def test_unicode_raw_index_name_is_copied_and_recovers_with_the_same_digest(self):
        source=self.cache_a/'сырой индекс №1.inpx';source.write_bytes(b'private Unicode raw index')
        inputs=copy.deepcopy(self.inputs);inputs[0]['source_file']=str(source);inputs[0]['sha256']=fixture.digest(source)
        inputs[0]['target_file']=str(Path(self.job['after_file']).parent/('index-'+hashlib.sha256(str(source).lower().encode()).hexdigest()+'.inpx'))
        self.inputs=inputs;self.set_request(self.job,inputs)
        first=self.run_snapshot();second=self.recover();self.assertEqual(first['snapshot_proof'],second['snapshot_proof'])
        self.assertEqual(source.read_bytes(),b'private Unicode raw index')

    def test_recovery_refuses_a_replaced_stage_directory_and_preserves_both_trees(self):
        first=self.run_snapshot();stage=Path(first['snapshot_directory']);saved=self.home/'saved-original-snapshot'
        stage.rename(saved);shutil.copytree(saved,stage)
        before={str(p):fixture.digest(p) for folder in (stage,saved) for p in folder.rglob('*') if p.is_file()}
        self.assertIn('Папка готового кэша заменена',self.recover('fail'))
        self.assertEqual({str(p):fixture.digest(p) for folder in (stage,saved) for p in folder.rglob('*') if p.is_file()},before)

    def test_recovery_refuses_changed_copied_index_without_touching_its_original(self):
        first=self.run_snapshot();stage=Path(first['snapshot_directory'])
        target=stage/Path(self.inputs[0]['target_file']).name;target.write_bytes(b'foreign changed raw index')
        self.assertIn('Изменён файл',self.recover('fail'))

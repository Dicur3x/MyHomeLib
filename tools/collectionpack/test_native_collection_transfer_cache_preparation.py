"""Independent cache preparation before the production transfer removes files."""
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
import test_native_collection_transfer_removal as removal

INTENT='HomeLibreTransferCacheIntent'
STAGES='HomeLibreTransferCacheStages'
CLAIMS='HomeLibreTransferCacheClaims'
HISTORY_PROPERTY=0x20040023
locations.MARKERS.update((INTENT,STAGES,CLAIMS))


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache preparation and private stage')
class TransferCachePreparationTests(settings.TransferCacheSettingsTests):
    payloads=removal.TransferRemovalTests.payloads
    snapshots=removal.TransferRemovalTests.snapshots
    check_metadata=removal.TransferRemovalTests.check_metadata
    registry_rows=removal.TransferRemovalTests.registry_rows
    operation=removal.TransferRemovalTests.operation
    intents=removal.TransferRemovalTests.intents
    tearDown=removal.TransferRemovalTests.tearDown

    def setUp(self):
        super().setUp()
        with fixture.connect(self.personal) as db:
            db.execute('delete from Books where DatabaseID=8 or BookID=88')
            db.execute('delete from Bases where DatabaseID=8')
        self.write_history()
        for folder in (self.cache_a,self.cache_b):
            (folder/'catalog.hlc2').unlink()
            with fixture.connect(self.catalogue) as source,fixture.connect(folder/'catalog.hlc2') as target:
                source.backup(target)
            with fixture.connect(folder/'catalog.hlc2') as db:
                db.execute("update Books set UpdateDate='2026-11-16'")
        self.neighbor=self.a/'not-in-catalogue.bin'
        self.neighbor.write_bytes(b'unrelated original must survive')
        self.pending=None
        self.config.update(cache_settings=False,cache_other_alias=False,cache_prepare_only=True,prepare=False,
                           probe_prepared_cache_guards=True)

    def write_history(self):
        with fixture.connect(self.catalogue) as db:
            db.execute('insert or replace into Settings values(?,?)',
                       (HISTORY_PROPERTY,json.dumps(self.history,ensure_ascii=False)))

    def run_case(self,expected=0):
        before=self.protected()
        result=removal.TransferRemovalTests.run_case(self,expected)
        self.assertEqual(self.protected(),before,'preparation changed original cache/index bytes')
        plan=self.intent()
        if plan:
            for job in plan['jobs']:
                self.assertFalse(Path(job['after_file']).parent.exists(),'preparation published a persistent cache')
        # A killed process can leave its owned live-reference scratch store.
        # Whole-operation ownership-aware cleanup is separate; this fixture's
        # exact private runtime is reaped and independently checked in tearDown.
        return result

    def intent(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('select count(*) from sqlite_master where name=?',(INTENT,)).fetchone()[0]:return None
            raw,digest=db.execute('select IntentJSON,IntentSHA256 from '+INTENT).fetchone()
        self.assertEqual(hashlib.sha256(raw.encode()).hexdigest(),digest.lower())
        return json.loads(raw)

    def stage_rows(self):
        with fixture.connect(self.personal) as db:
            return db.execute('select Job,Directory,DirectoryKey,ReadySHA from '+STAGES+' order by Job').fetchall()

    def resume_preparation(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),crash='',cancel_cache_snapshot_stage='',
                           cancel_cache_preparation_stage='',probe_prepared_cache_guards=False)
        self.config.update(options)
        return self.run_case(expected)

    def assert_prepared(self,count=2):
        plan=self.intent();self.assertEqual(len(plan['jobs']),count)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select State from '+INTENT).fetchone()[0],'prepared')
            self.assertEqual(db.execute('select State from HomeLibreTransferOperations').fetchone()[0],'pending')
        rows=self.stage_rows();self.assertEqual(len(rows),count)
        for job,directory,key,digest in rows:
            directory=Path(directory);self.assertTrue(directory.is_relative_to(self.journal()))
            self.assertEqual(len(key),25)
            raw=(directory/'ready.json').read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(),digest.lower())
            proof=json.loads(raw.decode('utf-8-sig'))
            for item in proof['files']:
                self.assertEqual(fixture.digest(directory/item['name']),item['sha256'].lower())
        return plan,rows

    def test_independent_intent_claims_and_prepared_caches_preserve_all_original_data(self):
        result=self.run_case();self.assertEqual(result['caches_prepared'],2)
        self.assertEqual(result['held_prepared_cache_checks'],3)
        plan,rows=self.assert_prepared()
        self.assertEqual(len(plan['databases']),1)
        with fixture.connect(self.personal) as db:
            claims=db.execute('select Directory,Stage,Path,FileKey from '+CLAIMS).fetchall()
        for _,directory,_,digest in rows:
            self.assertTrue(any(row[0]==directory and row[1]=='cache-ready' and row[3]==digest for row in claims))
        self.assertEqual(result['copy_streams'],0)
        self.assertFalse(list(self.destination.rglob('*')))
        self.assertEqual(self.resume_preparation()['caches_prepared'],2)
        self.assertEqual(self.stage_rows(),rows)

    def test_crash_after_intent_commit_replays_the_same_versions(self):
        self.config['crash']='cache-preparation-intent-committed';self.run_case(97)
        before=copy.deepcopy(self.intent())
        self.resume_preparation();self.assert_prepared()
        self.assertEqual(self.intent(),before)

    def test_unready_projection_exit_uses_new_stage_and_keeps_old_ownership(self):
        self.config['crash']='cache-before-projection-commit';self.run_case(97)
        old=self.stage_rows()[0];self.assertEqual(old[3],'')
        self.resume_preparation();_,rows=self.assert_prepared()
        self.assertNotIn(old[1],[r[1] for r in rows]);self.assertTrue(Path(old[1]).exists())
        with fixture.connect(self.personal) as db:
            self.assertGreater(db.execute('select count(*) from '+CLAIMS+' where Directory=?',(old[1],)).fetchone()[0],0)

    def test_ready_commit_exit_reuses_stage_with_original_cache_and_index_offline(self):
        self.config['crash']='cache-ready';self.run_case(97)
        ready=next(r for r in self.stage_rows() if r[3])
        job=next(j for j in self.intent()['jobs'] if j['job']==ready[0])
        Path(job['before_file']).parent.rename(self.home/'offline-ready-cache')
        self.resume_preparation();_,rows=self.assert_prepared()
        self.assertIn(ready,rows)

    def test_cancellation_during_projection_preserves_sources_and_resumes(self):
        self.config['cancel_cache_snapshot_stage']='cache-before-projection-commit'
        self.assertIn('останов',self.run_case('fail'))
        self.assertFalse(self.stage_rows()[0][3])
        self.resume_preparation();self.assert_prepared()

    def test_changed_history_refuses_replay_before_any_archive_copy(self):
        self.config['crash']='cache-preparation-intent-committed';self.run_case(97)
        self.history['sources'][0]['custom']['keep']='changed after intent';self.write_history()
        self.pending=None  # The fixture deliberately made this external write.
        self.assertIn('История обновлений изменилась',self.resume_preparation('fail'))
        self.assertFalse(list(self.destination.rglob('*')))

    def test_replaced_unready_original_cache_is_refused(self):
        self.config['crash']='cache-preparation-intent-committed';self.run_case(97)
        source=self.cache_a/'catalog.hlc2';old=self.home/'saved-original-cache.hlc2'
        source.rename(old);shutil.copy2(old,source)
        self.assertIn('кэш заменён',self.resume_preparation('fail'))
        self.assertTrue(old.exists());self.assertFalse(list(self.destination.rglob('*')))

    def test_missing_independent_ready_proof_is_not_rebuilt_after_prepared(self):
        self.run_case()
        with fixture.connect(self.personal) as db:db.execute('update '+STAGES+" set ReadySHA=''")
        before=list(self.journal().glob('cache-snapshot-*'))
        self.assertIn('Потеряно независимое подтверждение',self.resume_preparation('fail'))
        self.assertEqual(list(self.journal().glob('cache-snapshot-*')),before)

    def test_changed_prepared_cache_bytes_are_refused(self):
        self.run_case();cache=Path(self.stage_rows()[0][1])/'catalog.hlc2'
        with fixture.connect(cache) as db:db.execute("update Books set Title='foreign edited prepared cache' where BookID=1")
        self.assertIn('Изменён файл',self.resume_preparation('fail'))

    def test_rehashed_intent_cannot_redirect_metadata_away_from_frozen_roots(self):
        self.config['crash']='cache-preparation-intent-committed';self.run_case(97)
        plan=self.intent();sources=json.loads(plan['databases'][0]['sources_after'])
        sources[0]['root']=str(self.home/'foreign-root');plan['databases'][0]['sources_after']=json.dumps(sources)
        raw=json.dumps(plan,ensure_ascii=False)
        with fixture.connect(self.personal) as db:
            db.execute('update '+INTENT+' set IntentJSON=?,IntentSHA256=?',(raw,hashlib.sha256(raw.encode()).hexdigest()))
        self.assertIn('Настройки кэша не совпали',self.resume_preparation('fail'))
        self.assertFalse(list(self.destination.rglob('*')))

    def test_cache_also_registered_as_catalogue_uses_its_existing_writer(self):
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=8,BaseName='Registered retained cache',
                DBFileName=str(self.cache_a/'catalog.hlc2'),RootFolder=str(self.a)))
        result=self.run_case();self.assertEqual(result['caches_prepared'],4)
        plan,_=self.assert_prepared(4);self.assertEqual(len(plan['databases']),2)

    def test_no_sources_and_no_history_needs_no_invented_cache(self):
        with fixture.connect(self.catalogue) as db:
            db.execute('delete from Settings where SettingID in (?,?)',(fixture.SOURCE_PROPERTY,HISTORY_PROPERTY))
        result=self.run_case();self.assertEqual(result['caches_prepared'],0)
        plan,_=self.assert_prepared(0)
        self.assertFalse(plan['databases'][0]['history_present'])
        self.assertFalse(plan['databases'][0]['sources_present'])

    def test_independent_commit_boundaries_resume_without_source_mutation(self):
        for point in ('cache-preparation-before-intent-commit','cache-preparation-intent-committed',
                      'cache-preparation-before-claim-commit','cache-preparation-claim-committed',
                      'cache-preparation-before-complete-commit','cache-preparation-complete'):
            with self.subTest(point=point):
                self.config['crash']=point;self.run_case(97)
                self.assertEqual(self.intents(),{});self.assertFalse(list(self.destination.rglob('*')))
                self.config.update(mode='registered',operation=self.operation(),probe_prepared_cache_guards=False)
        self.resume_preparation();self.assert_prepared()


class TransferCachePreparationOperationTests(TransferCachePreparationTests):
    def setUp(self):
        super().setUp()
        self.config.update(run_operation=True,cache_prepare_only=False,prepare_source_caches=True,remove_sources=True,
                           register_operation=False,register_groups=False,probe_source_protection=True,
                           probe_verification_locks=True)

    def test_coordinator_prepares_dependencies_before_removing_original_archives(self):
        result=self.run_case();self.assert_prepared()
        self.assertEqual((result['caches_prepared'],result['removed_sources'],result['copy_streams']),(2,2,2))
        result=self.resume_preparation(prepare_source_caches=False)
        self.assertEqual((result['caches_prepared'],result['copy_streams']),(2,0))

    def test_invalid_raw_index_digest_stops_coordinator_before_source_removal(self):
        self.history['sources'][0]['sha256']='a'*64;self.write_history()
        self.assertIn('контрольная сумма',self.run_case('fail'))
        self.assertEqual(self.intents(),{})
        self.assertFalse(list(self.destination.rglob('*')))

    def test_failed_second_dependency_keeps_all_archives_after_first_cache_is_ready(self):
        # Semantic jobs sort by hashes containing this runtime's paths. Freeze
        # the review and inspect its plan rather than assuming source B is last.
        self.config.update(run_operation=False,cache_settings=True)
        plan=self.run_case()
        second_source=plan['cache_jobs'][-1]['source']
        next(row for row in self.history['sources'] if row['source']==second_source)['sha256']='a'*64
        self.write_history()
        self.config.update(mode='resume',run_operation=True,cache_settings=False)
        self.assertIn('контрольная сумма',self.run_case('fail'))
        self.assertTrue(any(row[3] for row in self.stage_rows()),'first dependency was not exercised')
        self.assertEqual(self.intents(),{});self.assertFalse(list(self.destination.rglob('*')))

    def test_existing_preparation_intent_is_enforced_when_resume_option_is_off(self):
        self.config['crash']='cache-preparation-intent-committed';self.run_case(97)
        self.assertEqual(self.intents(),{});self.assertFalse(list(self.destination.rglob('*')))
        result=self.resume_preparation(prepare_source_caches=False)
        self.assert_prepared();self.assertEqual((result['caches_prepared'],result['removed_sources']),(2,2))

    def test_changed_ready_snapshot_blocks_source_free_continuation(self):
        self.run_case();cache=Path(self.stage_rows()[0][1])/'catalog.hlc2'
        with fixture.connect(cache) as db:db.execute("update Books set Title='changed after groups were handled' where BookID=1")
        self.assertIn('Изменён файл',self.resume_preparation('fail',prepare_source_caches=False))


class TransferCachePreparationRootsTests(TransferCachePreparationOperationTests):
    """Observe the independently specified root phase plus cache preparation."""
    def setUp(self):
        super().setUp()
        self.config['finalize_roots']=True
        locations.MARKERS.update(('HomeLibreTransferFinalization','HomeLibreTransferFinalSettings'))

    def check_metadata(self,before):
        expected=copy.deepcopy(before)
        with fixture.connect(self.personal) as db:
            root_saved=bool(db.execute("select count(*) from sqlite_master where name='HomeLibreTransferFinalization'").fetchone()[0])
            if root_saved:
                root_saved=db.execute('select State from HomeLibreTransferFinalization').fetchone()[0]=='roots-applied'
        for path,(_,tables,columns) in expected.items():
            with fixture.connect(path) as db:
                marked=bool(db.execute("select count(*) from sqlite_master where name='HomeLibreTransferFinalSettings'").fetchone()[0])
                if marked:marked=bool(db.execute('select count(*) from HomeLibreTransferFinalSettings').fetchone()[0])
            for name in ('Settings','Bases','Books','CatalogBookCopies'):
                if name not in tables:continue
                rows=[];cols=columns[name]
                for row in tables[name]:
                    data=dict(zip(cols,row))
                    if marked and path==self.catalogue:
                        if name=='Settings' and data['SettingID']==fixture.SOURCE_PROPERTY:
                            sources=json.loads(data['SettingValue'])
                            for source in sources:
                                if source.get('root'):source['root']=str(self.mapped(source['root']))+os.sep
                            data['SettingValue']=json.dumps(sources)
                        if name=='Books' and data['BookID']==3:
                            data['Folder']=str(self.mapped(self.a)/'notdownloaded.zip')
                            for col in cols:
                                if col.startswith('Search') and col[6:] in data:
                                    value=data[col[6:]];data[col]=value.upper() if value else ''
                        if name=='CatalogBookCopies' and data['Root']:
                            data['Root']=str(self.mapped(data['Root']))+os.sep
                    if name=='Bases' and path==self.personal and root_saved and data['DatabaseID']==7:
                        root=self.read_review("select Destination from Roots where ID='collection'")[0][0]
                        data['RootFolder']=str(Path(root))+os.sep
                    rows.append(tuple(data[c] for c in cols))
                tables[name]=rows
        # Compare complete rows; only JSON property order/spacing is immaterial.
        original=locations.tables
        def canonical(snapshot):
            _,tables,columns=snapshot
            if 'Settings' in tables:
                cols=columns['Settings'];rows=[]
                for row in tables['Settings']:
                    data=dict(zip(cols,row))
                    if data['SettingID']==fixture.SOURCE_PROPERTY and data['SettingValue']:
                        data['SettingValue']=json.dumps(json.loads(data['SettingValue']),sort_keys=True)
                    rows.append(tuple(data[c] for c in cols))
                tables['Settings']=rows
            return snapshot
        for snapshot in expected.values():canonical(snapshot)
        locations.tables=lambda path:canonical(original(path))
        try:super().check_metadata(expected)
        finally:locations.tables=original

    def test_prepared_cache_intent_replays_after_authorized_root_publication(self):
        result=self.run_case();self.assertTrue(result['roots_applied']);self.assert_prepared()
        before=self.stage_rows()
        result=self.resume_preparation(finalize_roots=False,prepare_source_caches=False)
        self.assertTrue(result['roots_applied']);self.assertEqual(result['caches_prepared'],2)
        self.assertEqual(self.stage_rows(),before)

    def test_interrupted_root_commit_recovers_then_validates_prepared_caches(self):
        self.config['crash']='finalization-after-catalogue-commit';self.run_case(97)
        result=self.resume_preparation(finalize_roots=False,prepare_source_caches=False)
        self.assertTrue(result['roots_applied']);self.assert_prepared()

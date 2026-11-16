"""Plan cache/source/history versions without touching caches or settings."""
import copy
import hashlib
import json
import os
from pathlib import Path
import unittest
import uuid

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal

A='{10000000-0000-4000-8000-000000000001}'
B='{10000000-0000-4000-8000-000000000002}'
PROFILE_A='{20000000-0000-4000-8000-000000000001}'
PROFILE_B='{20000000-0000-4000-8000-000000000002}'
VERSION_A='{30000000-0000-4000-8000-000000000001}'
VERSION_B='{30000000-0000-4000-8000-000000000002}'


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache settings plan and private stage')
class TransferCacheSettingsTests(journal.TransferJournalTests):
    def setUp(self):
        super().setUp()
        self.cache_a=self.home/'Data'/'CatalogSources'/A/VERSION_A
        self.cache_b=self.home/'Data'/'CatalogSources'/PROFILE_B/VERSION_B
        for folder in (self.cache_a,self.cache_b):
            folder.mkdir(parents=True)
            (folder/'catalog.hlc2').write_bytes(b'original cache sentinel; planner must not open it')
            (folder/'retained.inpx').write_bytes(b'original raw index sentinel')
        self.external_index=self.home/'external-library.inpx';self.external_index.write_bytes(b'external refresh source')
        self.source_rows=[dict(id=A,name='One retained source',root=str(self.a),inpx=str(self.external_index),
            library='flibusta',cache_version=VERSION_A,update_profile=PROFILE_A,custom={'keep':['source',37]}),
            dict(id=B,name='External catalogue',root=str(self.b),file='old-external.hlc2',custom={'keep':'external'})]
        self.history=dict(version=1,custom={'keep':'history'},sources=[
            dict(profile=PROFILE_A,binding=A,source=A,cache=VERSION_A,name='Bound history',root=str(self.a),
                 library='flibusta',index=str(self.cache_a/'retained.inpx'),sha256=fixture.digest(self.cache_a/'retained.inpx'),custom={'keep':1}),
            dict(profile=PROFILE_B,binding='',source=PROFILE_B,cache=VERSION_B,name='Unbound history',root=str(self.b),
                 library='',index=str(self.cache_b/'retained.inpx'),sha256=fixture.digest(self.cache_b/'retained.inpx'),custom={'keep':2})])
        self.store=self.home/'cache-setting-plan.sqlite'
        self.write_sources()
        self.config.update(cache_settings=True,cache_settings_store=str(self.store),cache_history=json.dumps(self.history),cache_other_alias=True)

    def write_sources(self):
        self.sources=json.dumps(self.source_rows,ensure_ascii=False)
        with fixture.connect(self.catalogue) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?',(self.sources,fixture.SOURCE_PROPERTY))

    def protected(self):
        return {str(p):fixture.digest(p) for p in [*self.cache_a.rglob('*'),*self.cache_b.rglob('*'),self.external_index] if p.is_file()}

    def planned(self,expected=0):
        before=self.protected();result=self.run_case(expected)
        self.assertEqual(self.protected(),before)
        if expected==0:
            for job in result['cache_jobs']:
                self.assertFalse(Path(job['after_file']).parent.exists(),'planning created a cache-version directory')
                self.assertNotEqual(job['before_file'],job['after_file'])
                uuid.UUID(job['after_version'])
            for row in result['cache_inputs']:self.assertFalse(Path(row['target_file']).exists())
        else:
            with fixture.connect(self.store) as db:
                self.assertFalse(db.execute("select name from sqlite_master where name like 'TransferCacheSetting%'").fetchall())
        return result

    def mapped(self,path):
        original=Path(path);best=None
        for old,new in self.read_review('select InputPath,Destination from Roots where Destination is not null'):
            if original.is_relative_to(old) and (best is None or len(Path(old).parts)>len(best[0].parts)):best=Path(old),Path(new)
        return best[1]/original.relative_to(best[0]) if best else original

    def test_sources_and_bound_unbound_histories_share_compatible_versions_and_fork_other_roots(self):
        data=self.planned();self.assertEqual(len(data['cache_jobs']),4)
        sources=json.loads(data['cache_sources']);other=json.loads(data['cache_other_sources'])
        history=json.loads(data['cache_history']);other_history=json.loads(data['cache_other_history'])
        self.assertEqual(sources[0]['cache_version'],history['sources'][0]['cache'])
        self.assertEqual(other[0]['cache_version'],other_history['sources'][0]['cache'])
        self.assertNotEqual(sources[0]['cache_version'],other[0]['cache_version'])
        self.assertEqual(Path(sources[0]['root']),self.mapped(self.a))
        self.assertEqual(Path(history['sources'][1]['root']),self.mapped(self.b))
        self.assertEqual(other[0]['root'],str(self.a));self.assertEqual(other_history['sources'][1]['root'],str(self.b))
        self.assertEqual(sources[0]['inpx'],str(self.external_index))
        self.assertEqual(sources[0]['custom'],self.source_rows[0]['custom'])
        self.assertEqual(sources[0]['update_profile'],PROFILE_A)
        self.assertEqual(history['custom'],self.history['custom'])
        self.assertEqual(sources[1]['custom'],self.source_rows[1]['custom'])
        self.assertNotIn('cache_version',sources[1],'external catalogue was treated as an INPX cache')
        for index,row in enumerate(history['sources']):
            old=self.history['sources'][index]
            for field,value in old.items():
                if field not in ('cache','root','index'):self.assertEqual(row[field],value,field)
            job=next(j for j in data['cache_jobs'] if j['source']==row['source'] and j['after_version']==row['cache'])
            self.assertEqual(Path(row['index']).parent,Path(job['after_file']).parent)
        self.assertEqual(len(data['cache_inputs']),4)

    def test_retained_source_index_and_history_input_share_one_copy_and_add_known_digest(self):
        self.source_rows[0]['inpx']=str(self.cache_a/'retained.inpx');self.write_sources()
        data=self.planned();sources=json.loads(data['cache_sources']);history=json.loads(data['cache_history'])
        self.assertEqual(sources[0]['inpx'],history['sources'][0]['index'])
        self.assertEqual(len(data['cache_inputs']),4)
        for row in data['cache_inputs']:self.assertEqual(row['sha256'],self.history['sources'][0]['sha256'])

    def test_different_library_namespace_needs_a_separate_projection(self):
        self.history['sources'].append({**self.history['sources'][0],'library':'librusec'})
        self.config['cache_history']=json.dumps(self.history)
        data=self.planned();self.assertEqual(len(data['cache_jobs']),6)
        rows=json.loads(data['cache_history'])['sources'];self.assertNotEqual(rows[0]['cache'],rows[2]['cache'])

    def test_same_raw_index_with_conflicting_digest_is_refused_and_plan_rolls_back(self):
        self.history['sources'].append({**self.history['sources'][0],'sha256':'a'*64})
        self.config['cache_history']=json.dumps(self.history)
        self.assertIn('разные контрольные суммы',self.planned('fail'))

    def test_cancel_after_source_job_is_created_rolls_back_whole_plan(self):
        self.config['cancel_cache_settings_after']=6
        self.assertIn('Fixture cache settings stop',self.planned('fail'))

    def test_invalid_cache_version_cannot_become_a_writable_path(self):
        self.source_rows[0]['cache_version']='../foreign';self.write_sources()
        self.assertIn('Неверная версия',self.planned('fail'))

    def test_history_binding_to_another_source_is_refused(self):
        self.history['sources'][0]['binding']=B;self.config['cache_history']=json.dumps(self.history)
        self.assertIn('Не совпала привязка',self.planned('fail'))

    def test_absent_history_does_not_invent_a_baseline(self):
        self.config.update(cache_history='',cache_other_alias=False)
        data=self.planned();self.assertEqual(data['cache_history'],'');self.assertEqual(len(data['cache_jobs']),1)
        self.assertFalse(data['cache_inputs'])

    def test_legacy_unversioned_cache_receives_a_distinct_version_without_history_reset(self):
        self.source_rows[0].pop('cache_version');self.write_sources()
        self.config.update(cache_history='',cache_other_alias=False)
        data=self.planned();job=data['cache_jobs'][0]
        self.assertEqual(job['before_version'],'')
        self.assertEqual(Path(job['before_file']),self.cache_a.parent/'catalog.hlc2')
        self.assertTrue(job['after_version']);self.assertEqual(data['cache_history'],'')

    def test_history_without_a_source_list_retains_its_independent_profile(self):
        self.source_rows=[];self.write_sources()
        self.history['sources']=[self.history['sources'][1]]
        self.config.update(cache_history=json.dumps(self.history),cache_other_alias=False)
        data=self.planned();self.assertEqual(json.loads(data['cache_sources']),[])
        self.assertEqual(len(data['cache_jobs']),1)
        row=json.loads(data['cache_history'])['sources'][0]
        self.assertEqual((row['source'],row['profile'],row['binding']),(PROFILE_B,PROFILE_B,''))
        self.assertEqual(Path(row['root']),self.mapped(self.b))

    def replay(self,jobs,expected=0):
        self.config.update(mode='resume',cache_settings_store=str(self.home/'replay-cache-settings.sqlite'),
                           replay_cache_jobs=json.dumps(jobs))
        self.store=Path(self.config['cache_settings_store'])
        return self.planned(expected)

    def test_replay_keeps_the_exact_versions_settings_and_raw_input_targets(self):
        first=self.planned();original_store=self.store;digest=fixture.digest(original_store)
        second=self.replay(first['cache_jobs'])
        for field in ('cache_sources','cache_history','cache_other_sources','cache_other_history','cache_jobs','cache_inputs'):
            self.assertEqual(first[field],second[field],field)
        self.assertEqual(fixture.digest(original_store),digest)

    def test_replay_cannot_select_the_original_cache_as_its_target(self):
        first=self.planned();jobs=copy.deepcopy(first['cache_jobs']);jobs[0]['after_version']=jobs[0]['before_version']
        self.assertIn('совпала с исходной',self.replay(jobs,'fail'))

    def test_replay_with_a_missing_job_is_refused_without_a_new_random_version(self):
        first=self.planned()
        self.assertIn('Missing replay cache job',self.replay(first['cache_jobs'][1:],'fail'))

    def test_replay_with_duplicate_jobs_is_refused_before_metadata_planning(self):
        first=self.planned()
        self.replay(first['cache_jobs']+[first['cache_jobs'][0]],'fail')

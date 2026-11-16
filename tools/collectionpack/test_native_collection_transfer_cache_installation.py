"""Owned persistent versions; source/history publication remains a later phase."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cache_preparation as preparation
import test_native_collection_transfer_cache_settings as settings
import test_native_collection_transfer_locations as locations
import test_native_collection_transfer_removal as removal

INSTALL='HomeLibreTransferCacheInstallations'
CLAIMS='HomeLibreTransferCacheInstallClaims'
locations.MARKERS.update((INSTALL,CLAIMS))


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache installation and private stage')
class TransferCacheInstallationTests(preparation.TransferCachePreparationRootsTests):
    def setUp(self):
        super().setUp()
        self.config.update(install_cache_versions=True,probe_prepared_cache_guards=False)

    def run_case(self,expected=0):
        before=self.protected();result=removal.TransferRemovalTests.run_case(self,expected)
        self.assertEqual(self.protected(),before,'installation changed original baseline/index bytes')
        return result

    def install_rows(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('select count(*) from sqlite_master where name=?',(INSTALL,)).fetchone()[0]:return []
            db.row_factory=lambda cur,row:dict(zip((c[0] for c in cur.description),row))
            return db.execute('select * from '+INSTALL+' order by Job').fetchall()

    def resume_installation(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),crash='',cancel_cache_installation_stage='',
                           cancel_cache_snapshot_stage='',cancel_cache_preparation_stage='',finalize_roots=False)
        self.config.update(options);return self.run_case(expected)

    def assert_installed(self):
        plan,_=self.assert_prepared();rows=self.install_rows();self.assertEqual(len(rows),2)
        snapshots={job:Path(directory) for job,directory,_,_ in self.stage_rows()}
        for row in rows:
            self.assertEqual(row['State'],'published')
            self.assertEqual(hashlib.sha256(row['ProofJSON'].encode()).hexdigest(),row['ProofSHA'].lower())
            proof=json.loads(row['ProofJSON']);job=next(j for j in plan['jobs'] if j['job']==row['Job'])
            target=Path(job['after_file']).parent
            self.assertEqual(target,Path(row['Destination']));self.assertTrue(target.is_dir())
            self.assertFalse(Path(row['Directory']).exists(),'renamed stage remained at its old name')
            self.assertEqual(proof['directory_key'],row['DirectoryKey'])
            self.assertEqual(proof['binding'],row['BindingSHA'])
            self.assertEqual(set(p.name for p in target.iterdir()),set(r['name'] for r in proof['files']))
            for item in proof['files']:
                self.assertEqual(fixture.digest(target/item['name']),item['sha256'].lower())
                self.assertEqual(fixture.digest(target/item['name']),fixture.digest(snapshots[row['Job']]/item['name']))
                self.assertEqual((target/item['name']).stat().st_size,item['bytes'])
        # This checkpoint materializes versions without switching user settings.
        with fixture.connect(self.catalogue) as db:
            sources=json.loads(db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0])
            history=json.loads(db.execute('select SettingValue from Settings where SettingID=?',(preparation.HISTORY_PROPERTY,)).fetchone()[0])
        self.assertEqual(sources[0]['cache_version'],settings.VERSION_A)
        self.assertEqual([h['cache'] for h in history['sources']],[settings.VERSION_A,settings.VERSION_B])
        return rows

    def installed_state(self):
        return {str(p):(p.stat().st_ino,p.stat().st_mtime_ns,fixture.digest(p))
                for row in self.install_rows() if Path(row['Destination']).is_dir()
                for p in Path(row['Destination']).iterdir() if p.is_file()}

    def test_versions_publish_as_whole_directories_and_recover_without_original_caches(self):
        self.config['read_installed_caches']=True
        result=self.run_case();self.assertEqual(result['installed_caches'],2);self.assert_installed()
        self.assertEqual({r['source']:r['sha256'].lower() for r in result['installed_book_hashes']},
                         {settings.A:hashlib.sha256(b'first').hexdigest(),settings.PROFILE_B:hashlib.sha256(b'second').hexdigest()})
        before=self.installed_state()
        self.cache_a.rename(self.home/'offline-original-cache-a');self.cache_b.rename(self.home/'offline-original-cache-b')
        result=self.resume_installation();self.assertEqual(result['installed_caches'],2);self.assert_installed()
        self.assertEqual(len(result['installed_book_hashes']),2)
        self.assertEqual(self.installed_state(),before)

    def test_ready_commit_exit_recovers_and_renames_the_same_owned_directory(self):
        self.config['crash']='install-ready';self.run_case(97)
        row=self.install_rows()[0];self.assertEqual(row['State'],'ready')
        self.assertTrue(Path(row['Directory']).is_dir());self.assertFalse(Path(row['Destination']).exists())
        self.resume_installation();rows=self.assert_installed()
        self.assertTrue(any(r['DirectoryKey']==row['DirectoryKey'] and r['Directory']==row['Directory'] for r in rows))

    def test_exit_after_rename_recovers_without_copying_or_replacing_files(self):
        self.config['crash']='install-after-rename';self.run_case(97)
        row=self.install_rows()[0];self.assertEqual(row['State'],'ready')
        self.assertTrue(Path(row['Destination']).is_dir());before=self.installed_state()
        self.resume_installation();self.assert_installed()
        after=self.installed_state()
        self.assertEqual({p:after[p] for p in before},before)

    def test_unready_exit_uses_fresh_attempt_and_retains_prior_claims(self):
        self.config['crash']='install-file-reserved';self.run_case(97)
        old=self.install_rows()[0];self.assertEqual(old['State'],'copying');self.assertFalse(old['ProofSHA'])
        self.resume_installation();self.assert_installed();self.assertTrue(Path(old['Directory']).exists())
        self.assertNotIn(old['Directory'],[r['Directory'] for r in self.install_rows()])
        with fixture.connect(self.personal) as db:
            self.assertGreater(db.execute('select count(*) from '+CLAIMS+' where Directory=?',(old['Directory'],)).fetchone()[0],0)

    def test_cancel_before_rename_preserves_ready_proof_and_continues(self):
        self.config['cancel_cache_installation_stage']='install-before-rename'
        self.assertIn('останов',self.run_case('fail'))
        self.assertEqual(self.install_rows()[0]['State'],'ready')
        self.resume_installation();self.assert_installed()

    def test_existing_foreign_version_directory_is_never_adopted_or_overwritten(self):
        self.config['install_cache_versions']=False;self.run_case()
        target=Path(self.intent()['jobs'][0]['after_file']).parent;target.mkdir()
        foreign=target/'unrelated.txt';foreign.write_bytes(b'foreign existing destination')
        self.config['install_cache_versions']=True
        self.assertIn('уже занят',self.resume_installation('fail'))
        self.assertEqual(foreign.read_bytes(),b'foreign existing destination')

    def test_changed_published_cache_is_refused_without_repairing_it(self):
        self.run_case();row=self.install_rows()[0];cache=Path(row['Destination'])/'catalog.hlc2'
        with fixture.connect(cache) as db:db.execute("update Books set Title='foreign published change' where BookID=1")
        before=self.installed_state()
        self.assertIn('Изменён файл',self.resume_installation('fail'))
        self.assertEqual(self.installed_state(),before)

    def test_missing_independent_installed_proof_is_not_recreated(self):
        self.run_case();before=self.installed_state()
        with fixture.connect(self.personal) as db:db.execute('update '+INSTALL+" set ProofSHA=''")
        self.assertIn('Потеряно независимое подтверждение',self.resume_installation('fail'))
        self.assertEqual(self.installed_state(),before)

    def test_replaced_version_directory_preserves_both_trees_and_is_refused(self):
        self.run_case();row=self.install_rows()[0];target=Path(row['Destination']);saved=self.home/'saved-installed-version'
        target.rename(saved);shutil.copytree(saved,target)
        before={str(p):fixture.digest(p) for folder in (saved,target) for p in folder.iterdir() if p.is_file()}
        self.assertIn('Папка постоянного кэша заменена',self.resume_installation('fail'))
        self.assertEqual({str(p):fixture.digest(p) for folder in (saved,target) for p in folder.iterdir() if p.is_file()},before)

    def test_disappeared_published_version_is_not_silently_recreated(self):
        self.run_case();target=Path(self.install_rows()[0]['Destination'])
        resolved=target.resolve(strict=True)
        self.assertTrue(resolved.is_relative_to(self.home.resolve(strict=True)))
        self.assertFalse(target.is_symlink())
        shutil.rmtree(resolved)  # This exact private version was created above.
        before=self.installed_state()
        self.assertIn('Опубликованная версия кэша исчезла',self.resume_installation('fail'))
        self.assertFalse(target.exists());self.assertEqual(self.installed_state(),before)

    def test_rehashed_install_proof_cannot_redirect_the_fixed_version_destination(self):
        self.run_case();row=self.install_rows()[0];proof=json.loads(row['ProofJSON'])
        proof['destination']=str(self.home/'foreign-version')
        raw=json.dumps(proof,ensure_ascii=False,separators=(',',':'))
        with fixture.connect(self.personal) as db:
            db.execute('update '+INSTALL+' set ProofJSON=?,ProofSHA=? where Job=?',
                       (raw,hashlib.sha256(raw.encode()).hexdigest(),row['Job']))
        before=self.installed_state()
        self.assertIn('Подтверждение относится к другой версии',self.resume_installation('fail'))
        self.assertEqual(self.installed_state(),before)
        self.assertFalse((self.home/'foreign-version').exists())

    def test_foreign_file_in_ready_stage_is_refused_before_directory_rename(self):
        self.config['crash']='install-ready';self.run_case(97)
        row=self.install_rows()[0];foreign=Path(row['Directory'])/'foreign.txt';foreign.write_bytes(b'keep foreign stage data')
        self.assertIn('посторонние файлы',self.resume_installation('fail'))
        self.assertTrue(foreign.is_file());self.assertFalse(Path(row['Destination']).exists())

    def test_data_root_replacement_is_refused_before_any_archive_removal(self):
        self.config.update(run_operation=False,cache_prepare_only=True,install_cache_versions=False)
        self.run_case();self.assertEqual(self.intents(),{})
        data=self.home/'Data';saved=self.home/'saved-data-root';data.rename(saved);shutil.copytree(saved,data)
        self.config.update(run_operation=True,cache_prepare_only=False,install_cache_versions=True)
        self.assertIn('Папка данных заменена',self.resume_installation('fail'))
        self.assertTrue((self.a/'same.zip').is_file());self.assertTrue((self.b/'same.zip').is_file())
        self.assertFalse(list(self.destination.rglob('*')))

    def test_installation_requires_prior_roots_and_cache_intent(self):
        self.config.update(run_operation=False,cache_prepare_only=True)
        self.assertIn('Нет подготовленного завершения',self.run_case('fail'))
        self.assertFalse(self.install_rows());self.assertTrue((self.a/'same.zip').is_file())
        self.config.update(run_operation=True,cache_prepare_only=False,finalize_roots=True)
        self.resume_installation(finalize_roots=True);self.assert_installed()


class TransferCacheVersionTargetTests(settings.TransferCacheSettingsTests):
    def test_distinct_jobs_cannot_replay_the_same_physical_version_target(self):
        data=self.planned();jobs=copy.deepcopy(data['cache_jobs'])
        same_source=[j for j in jobs if j['source']==settings.A]
        self.assertEqual(len(same_source),2)
        same_source[1]['after_version']=same_source[0]['after_version']
        self.assertIn('один путь новой версии',self.replay(jobs,'fail'))

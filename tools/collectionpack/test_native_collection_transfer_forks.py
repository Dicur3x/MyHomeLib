"""Native shared-catalogue forks: real registration commits and interrupted recovery."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture

RECEIPTS = 'HomeLibreTransferForkReceipts'


def tables(path):
    with fixture.connect(path) as db:
        schema = list(db.execute('select type,name,sql from sqlite_master order by type,name'))
        data = {name:sorted(db.execute('select * from "'+name+'"'),key=repr)
                for name, in db.execute("select name from sqlite_master where type='table'")}
        columns = {name:[r[1] for r in db.execute('pragma table_info("'+name+'")')] for name in data}
    return schema,data,columns


@unittest.skipUnless(os.name == 'nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native journal, SQLite, 7-Zip and private stage')
class TransferForkTests(unittest.TestCase):
    attempts = crashes = 0
    write_zip = staticmethod(fixture.TransferCatalogueTests.write_zip)
    tearDown = journal_fixture.TransferJournalTests.tearDown
    anchor = journal_fixture.TransferJournalTests.anchor
    journal = journal_fixture.TransferJournalTests.journal
    command = journal_fixture.TransferJournalTests.command
    read_review = journal_fixture.TransferJournalTests.read_review
    state_edit = journal_fixture.TransferJournalTests.state_edit

    def setUp(self):
        journal_fixture.TransferJournalTests.setUp(self)
        with fixture.connect(self.personal) as db:
            db.execute('update Bases set DBFileName=?,RootFolder=? where DatabaseID=8', (str(self.catalogue),str(self.b)))
        self.pending_personal = None
        self.config['publish_forks'] = False

    def personal_unchanged_except_receipts(self, before):
        old_schema,old,columns = before
        new_schema,new,new_columns = tables(self.personal)
        self.assertEqual([s for s in new_schema if s[1]!=RECEIPTS], [s for s in old_schema if s[1]!=RECEIPTS])
        self.assertEqual(set(new)-{RECEIPTS},set(old)-{RECEIPTS})
        markers = [dict(zip(new_columns[RECEIPTS],r)) for r in new.get(RECEIPTS,[])]
        prior = set(old.get(RECEIPTS,[]))
        self.assertTrue(prior.issubset(set(new.get(RECEIPTS,[]))))
        updates = {}
        current = [m for m in markers if self.control.exists() and m['Operation']==self.journal().name]
        if current:
            expected = self.read_review('select m.ForkID,m.RegistrationID,r.RawCatalogue,r.RawRoot,f.Destination,s.SHA256 '+
                'from ForkMembers m join ReferenceRegistrations r on r.RegistrationID=m.RegistrationID '+
                'join CatalogueForks f on f.ID=m.ForkID join ForkSources s on s.ID=f.SourceID')
            mapping = {r[1]:r for r in expected}
            for marker in current:
                fork,cid,source,root,destination,sha = mapping[marker['RegistrationID']]
                self.assertEqual((marker['ForkID'],marker['OldCatalogue'],marker['OldRoot'],marker['Target'],marker['SnapshotSHA256']),
                                 (fork,source,root,destination,sha))
                self.assertEqual(marker['ReviewSHA256'],self.anchor()['review_sha256'])
                self.assertTrue(Path(destination).is_file())
                self.assertEqual(len(marker['TargetKey']),25)
                updates[cid] = destination
            for fork in {m['ForkID'] for m in current}:
                self.assertEqual({m['RegistrationID'] for m in current if m['ForkID']==fork},
                                 {r[1] for r in expected if r[0]==fork},'partial registration-group commit')
        for name,rows in old.items():
            if name==RECEIPTS:
                continue
            expected = list(rows)
            if name=='Bases':
                ix_id,ix_file = columns[name].index('DatabaseID'),columns[name].index('DBFileName')
                for index,row in enumerate(expected):
                    if row[ix_id] in updates:
                        changed=list(row);changed[ix_file]=updates[row[ix_id]];expected[index]=tuple(changed)
            self.assertEqual(sorted(new[name],key=repr),sorted(expected,key=repr),name+' lost or changed unrelated personal data')

    def originals(self):
        original = fixture.TransferCatalogueTests.snapshot(self)
        del original[str(self.personal)]
        for name in ('third','previous-source-b'):
            outside=self.home/name
            if outside.is_dir(): original.update({str(p):fixture.digest(p) for p in outside.rglob('*') if p.is_file()})
        return original

    def run_case(self, expected=0):
        original = self.originals()
        before = self.pending_personal or tables(self.personal)
        process = subprocess.run(self.command(),cwd=self.home,capture_output=True,timeout=90,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)})
        entry = dict(test=self.id(),request=dict(self.config),expected=expected,returncode=process.returncode,
                     output=(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        if self.control.exists(): entry['control']=self.anchor()
        if self.result.exists(): entry['result']=json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (fixture.STAGE/'invocations.jsonl').open('a',encoding='utf-8') as out:
            out.write(json.dumps(entry,ensure_ascii=False)+'\n')
        after = self.originals()
        self.assertEqual(after,original,'fork changed original catalogue or book payloads')
        if expected==97:
            self.assertEqual(process.returncode,97,entry['output']);type(self).crashes+=1
            # No SQLite observer opens personal/state databases between forced
            # exit and native recovery; that observer could recover a hot WAL.
            self.pending_personal=before
            self.assertFalse(self.result.exists())
            return entry
        self.personal_unchanged_except_receipts(before)
        self.pending_personal=None
        if expected=='fail':
            self.assertNotEqual(process.returncode,0,entry['output']);self.assertFalse(self.result.exists())
            return entry['output']
        self.assertEqual(process.returncode,expected,entry['output'])
        self.assertEqual(entry['result']['status'],'PASS')
        return entry['result']

    def resume(self, **options):
        self.config.update(mode='resume',crash='',cancel_fork_commit=False)
        self.config.update(options)
        return self.run_case()

    def target(self):
        return Path(self.read_review('select Destination from CatalogueForks order by ID')[0][0])

    def test_review_creates_one_private_snapshot_without_switching_registration(self):
        result=self.run_case()
        self.assertEqual(result['forks'],1)
        self.assertFalse(list(self.destination.iterdir()))
        snapshot=Path(self.read_review('select Snapshot from ForkSources')[0][0])
        self.assertTrue(snapshot.is_relative_to(self.journal()))
        self.assertEqual(tables(snapshot)[:2],tables(self.catalogue)[:2])
        self.assertEqual(self.read_review('select RegistrationID from ForkMembers'),[(8,)])

    def test_registration_switch_preserves_book_ids_and_native_root_meaning(self):
        self.config.update(publish_forks=True,read_fork_members=True)
        result=self.run_case()
        reads={r['registration']:r['sha256'] for r in result['native_fork_reads']}
        self.assertEqual(reads,{7:hashlib.sha256(b'first').hexdigest(),8:hashlib.sha256(b'second').hexdigest()})
        self.assertEqual(tables(self.target())[:2],tables(self.catalogue)[:2])
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select DBFileName from Bases where DatabaseID=7').fetchone(),(str(self.catalogue),))

    def test_same_alternate_root_registrations_share_one_fork(self):
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=9,BaseName='Третья',DBFileName=str(self.catalogue),RootFolder=str(self.b)))
        self.config.update(publish_forks=True,read_fork_members=True)
        self.assertEqual(self.run_case()['forks'],1)
        self.assertEqual(self.read_review('select RegistrationID,ForkID from ForkMembers order by RegistrationID'),[(8,1),(9,1)])

    def test_different_alternate_roots_get_distinct_forks_from_one_snapshot(self):
        c=self.home/'third';c.mkdir();self.write_zip(c/'same.zip',b'third')
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=9,BaseName='Третья',DBFileName=str(self.catalogue),RootFolder=str(c)))
        self.config.update(publish_forks=True,read_fork_members=True)
        result=self.run_case()
        self.assertEqual(result['forks'],2)
        self.assertEqual(self.read_review('select count(*) from ForkSources'),[(1,)])
        self.assertEqual(next(r['sha256'] for r in result['native_fork_reads'] if r['registration']==9),hashlib.sha256(b'third').hexdigest())

    def test_equal_roots_need_no_snapshot_or_registration_write(self):
        with fixture.connect(self.personal) as db: db.execute('update Bases set RootFolder=? where DatabaseID=8',(str(self.a),))
        self.config['publish_forks']=True
        self.assertEqual(self.run_case()['forks'],0)
        self.assertEqual(self.read_review('select count(*) from ForkSources'),[(0,)])
        self.assertFalse((self.journal()/'catalogue-snapshots').exists())

    def test_published_fork_reuses_receipt_and_keeps_new_notes_and_metadata(self):
        self.config['publish_forks']=True;self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("update Books set Rate=3,Progress=81,Annotation='Новая личная заметка' where DatabaseID=8 and BookID=1")
        with fixture.connect(self.target()) as db: db.execute("update Books set Title='Новое название' where BookID=1")
        before=fixture.digest(self.target())
        self.assertEqual(self.resume(publish_forks=True)['copy_streams'],0)
        self.assertEqual(fixture.digest(self.target()),before)

    def test_replaced_published_catalogue_is_reported_and_not_overwritten(self):
        self.config['publish_forks']=True;self.run_case();target=self.target()
        target.rename(target.with_suffix('.saved'));target.write_bytes(b'foreign replacement catalogue')
        self.config['mode']='resume';self.assertIn('изменились',self.run_case('fail'))
        self.assertEqual(target.read_bytes(),b'foreign replacement catalogue')

    def test_deleted_personal_receipt_is_not_reconstructed_from_mutable_state(self):
        self.config['publish_forks']=True;self.run_case()
        with fixture.connect(self.personal) as db: db.execute('delete from '+RECEIPTS)
        self.config['mode']='resume';self.assertIn('квитанция',self.run_case('fail'))

    def test_source_metadata_changed_before_switch_requires_new_review(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db: db.execute("update Books set Title='Изменено после плана' where BookID=1")
        self.config.update(mode='resume',publish_forks=True)
        self.assertIn('каталог изменился',self.run_case('fail'))

    def test_committed_wal_pages_are_included_in_the_snapshot(self):
        # Preserve a genuine committed WAL pair, as left by a process that
        # ended before checkpoint. No writer remains open during the native run.
        with fixture.connect(self.catalogue) as db:
            db.execute('pragma journal_mode=wal');db.execute('pragma wal_autocheckpoint=0')
            db.execute("update Books set Title='Данные из WAL' where BookID=1");db.commit()
            main=self.catalogue.read_bytes();wal=Path(str(self.catalogue)+'-wal').read_bytes()
        self.catalogue.write_bytes(main)
        wal_file=Path(str(self.catalogue)+'-wal');wal_file.write_bytes(wal)
        self.assertGreater(len(wal),32)
        before=fixture.digest(wal_file)
        self.config.update(publish_forks=True,read_fork_members=True)
        self.run_case()
        self.assertEqual(fixture.digest(wal_file),before)
        with fixture.connect(self.target()) as db:
            self.assertEqual(db.execute('select Title from Books where BookID=1').fetchone(),('Данные из WAL',))

    def test_changed_registration_is_preserved(self):
        self.run_case()
        with fixture.connect(self.personal) as db: db.execute('update Bases set RootFolder=? where DatabaseID=8',(str(self.a),))
        self.config.update(mode='resume',publish_forks=True)
        self.assertIn('Подключение общего каталога изменилось',self.run_case('fail'))

    def test_replaced_root_directory_requires_a_new_review_even_with_same_path(self):
        self.run_case()
        self.b.rename(self.home/'previous-source-b')
        self.b.mkdir();self.write_zip(self.b/'same.zip',b'replacement directory book')
        self.config.update(mode='resume',publish_forks=True)
        self.assertIn('Подключение общего каталога изменилось',self.run_case('fail'))

    def test_foreign_destination_is_never_overwritten(self):
        self.run_case();target=self.target();target.parent.mkdir(parents=True);target.write_bytes(b'foreign metadata')
        self.config.update(mode='resume',publish_forks=True);self.run_case('fail')
        self.assertEqual(target.read_bytes(),b'foreign metadata')

    def test_changed_private_snapshot_cannot_be_published(self):
        self.run_case();snapshot=Path(self.read_review('select Snapshot from ForkSources')[0][0])
        with snapshot.open('r+b') as out: out.write(b'forged snapshot')
        self.config.update(mode='resume',publish_forks=True);self.run_case('fail')

    def test_forged_published_state_does_not_grant_a_registration_write(self):
        self.run_case();self.state_edit("update ForkState set State='published'")
        self.config.update(mode='resume',publish_forks=True)
        self.assertIn('квитанции',self.run_case('fail'))

    def test_missing_fork_state_cannot_silently_skip_publication(self):
        self.run_case();self.state_edit('delete from ForkState')
        self.config.update(mode='resume',publish_forks=True)
        self.assertIn('Состав копий общих каталогов',self.run_case('fail'))

    def test_child_path_cannot_escape_owned_copy_directory(self):
        self.run_case();foreign=self.home/'foreign';foreign.mkdir();(foreign/'keep').write_bytes(b'keep')
        self.state_edit("update ForkState set Child='../foreign'")
        self.config.update(mode='resume',publish_forks=True);self.assertIn('ссылка',self.run_case('fail'))
        self.assertEqual((foreign/'keep').read_bytes(),b'keep')

    def test_cancel_before_commit_rolls_back_and_reuses_prepared_copy(self):
        self.config.update(publish_forks=True,cancel_fork_commit=True)
        self.assertIn('остановлена',self.run_case('fail'))
        self.assertEqual(self.resume(publish_forks=True,read_fork_members=True)['copy_streams'],0)

    def test_crashes_before_and_after_registration_commit_resume(self):
        for index,point in enumerate(('fork-child-created','fork-child-linked','fork-copy-prepared','fork-before-personal-commit',
                                      'fork-after-personal-commit','fork-published','file:after-publish')):
            with self.subTest(point=point):
                with fixture.connect(self.personal) as db:
                    db.execute('update Bases set DBFileName=? where DatabaseID=8',(str(self.catalogue),))
                case=self.home/f'case-{index}';case.mkdir()
                self.work=case/'work';self.destination=case/'destination';self.work.mkdir();self.destination.mkdir()
                self.control=case/'operation.json'
                self.config.update(mode='create',control=str(self.control),work=str(self.work),destination=str(self.destination),
                                   publish_forks=True,crash=point)
                self.run_case(97)
                result=self.resume(publish_forks=True,read_fork_members=True)
                self.assertEqual(result['forks'],1)
                if point not in ('fork-child-created','fork-child-linked'):
                    self.assertEqual(result['copy_streams'],0)

    def test_second_crash_in_recovery_keeps_committed_registration(self):
        self.config.update(publish_forks=True,crash='fork-after-personal-commit');self.run_case(97)
        self.config.update(mode='resume',crash='fork-recovered');self.run_case(97)
        self.assertEqual(self.resume(publish_forks=True,read_fork_members=True)['copy_streams'],0)

    def test_open_writable_catalogue_blocks_snapshot_without_mutating_it(self):
        with fixture.connect(self.catalogue) as db:
            db.execute('begin immediate')
            self.assertIn('защитить общий каталог',self.run_case('fail'))
        self.assertFalse(self.control.exists())


if __name__=='__main__': unittest.main(verbosity=2)

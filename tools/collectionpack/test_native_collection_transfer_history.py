"""History/cache rebind for byte-identical prepared archive groups."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture
from test_native_collection_transfer_forks import tables

HISTORY={'HomeLibreBookCompression','HomeLibreCompressionOutcomes','HomeLibreRestoredBookSizes',
         'HomeLibreCompressionChecks','HomeLibreCompressionDependencies','HomeLibreCompressionImageSets'}
SCHEMA='''
create table HomeLibreBookCompression(FileKey text,Member text,ProfileSHA256 text,InputSHA256 text,OutputSHA256 text,BookSize integer,primary key(FileKey,Member));
create table HomeLibreCompressionOutcomes(FileKey text,Member text,ProfileSHA256 text,OutputSHA256 text,RetryOriginal integer,primary key(FileKey,Member)) without rowid;
create table HomeLibreRestoredBookSizes(FileKey text,Member text,PayloadSHA256 text,BookSize integer,FullInputSHA256 text,FullOutputSHA256 text,ImageStamp text,SourceIdentity text,SourceSHA256 text,primary key(FileKey,Member)) without rowid;
create table HomeLibreCompressionChecks(FileKey text,Member text,Profile text,Grayscale integer,EngineSHA256 text,SourceIdentity text,SourceSHA256 text,PayloadSHA256 text,primary key(FileKey,Member,Profile,Grayscale,EngineSHA256)) without rowid;
create table HomeLibreCompressionDependencies(FileKey text,Member text,Profile text,Grayscale integer,EngineSHA256 text,Stamp text,primary key(FileKey,Member,Profile,Grayscale,EngineSHA256)) without rowid;
create table HomeLibreCompressionImageSets(FileKey text,Stamp text,SourcesJSON text,primary key(FileKey,Stamp)) without rowid;
'''


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer journal, SQLite, 7-Zip and private stage')
class TransferHistoryTests(unittest.TestCase):
    attempts=crashes=0
    setUp=journal_fixture.TransferJournalTests.setUp
    tearDown=journal_fixture.TransferJournalTests.tearDown
    write_zip=staticmethod(fixture.TransferCatalogueTests.write_zip)
    make_legacy=journal_fixture.TransferJournalTests.make_legacy
    command=journal_fixture.TransferJournalTests.command
    anchor=journal_fixture.TransferJournalTests.anchor
    journal=journal_fixture.TransferJournalTests.journal
    read_review=journal_fixture.TransferJournalTests.read_review

    def run_case(self,expected=0):
        before=getattr(self,'pending',None) or (tables(self.catalogue),tables(self.personal))
        payloads={str(p):fixture.digest(p) for root in (self.a,self.b) for p in root.rglob('*') if p.is_file()}
        process=subprocess.run(self.command(),cwd=self.home,capture_output=True,timeout=90,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)})
        entry=dict(test=self.id(),request=dict(self.config),expected=expected,returncode=process.returncode,
                   output=(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        if self.result.exists():entry['result']=json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (fixture.STAGE/'invocations.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(entry,ensure_ascii=False)+'\n')
        self.assertEqual(payloads,{str(p):fixture.digest(p) for root in (self.a,self.b) for p in root.rglob('*') if p.is_file()})
        if expected==97:
            self.assertEqual(process.returncode,97,entry['output']);self.pending=before;type(self).crashes+=1;return entry
        after=tables(self.catalogue)
        self.assertEqual(after[0],before[0][0])
        for name,rows in before[0][1].items():
            if name in HISTORY:self.assertTrue(set(rows).issubset(set(after[1][name])),name+' original history was lost')
            else:self.assertEqual(after[1][name],rows,name+' unrelated catalogue data changed')
        self.assertEqual(tables(self.personal),before[1]);self.pending=None
        if expected=='fail':self.assertNotEqual(process.returncode,0,entry['output']);return entry['output']
        self.assertEqual(process.returncode,expected,entry['output']);return entry['result']

    def seed(self,images=False,sevenzip=False):
        source=self.a/'same.zip'
        if images or sevenzip:
            source=self.make_legacy()
            if images:
                for folder in ('covers','images'):self.write_zip(self.a/folder/'legacy.zip',b'picture archive bytes')
        self.config.update(prepare=False,history_witnesses=True)
        data=self.run_case()
        w=next(row for row in data['history_witnesses'] if Path(row['source'])==source)
        key=w['identity'][:25].upper()
        with fixture.connect(self.catalogue) as db:
            db.executescript(SCHEMA)
            db.execute('insert into HomeLibreBookCompression values(?,?,?,?,?,?)',(key,'101.fb2','1'*64,'2'*64,'3'*64,9999))
            db.execute('insert into HomeLibreCompressionOutcomes values(?,?,?,?,?)',(key,'101.fb2','1'*64,'3'*64,1))
            db.execute('insert into HomeLibreRestoredBookSizes values(?,?,?,?,?,?,?,?,?)',
                       (key,'101.fb2','3'*64,9999,'2'*64,'3'*64,w['stamp'],w['identity'],w['sha256']))
            db.execute('insert into HomeLibreCompressionChecks values(?,?,?,?,?,?,?,?)',
                       (key,'101.fb2','balanced',0,'a'*64,w['identity'],w['sha256'],'3'*64))
            db.execute('insert into HomeLibreCompressionDependencies values(?,?,?,?,?,?)',
                       (key,'101.fb2','balanced',0,'a'*64,w['stamp']))
            if w['images']:db.execute('insert into HomeLibreCompressionImageSets values(?,?,?)',(key,w['stamp'],w['images']))
        self.w=w
        self.config.update(mode='resume',prepare=True,rebind_history=True,group_source=str(source),history_witnesses=False)
        return w

    def check_hit(self,result,expected=True):
        self.assertEqual(next(r['hit'] for r in result['history_hits'] if r['file_id']==self.w['file_id']),expected)

    def test_plain_archive_keeps_native_skip_proof(self):
        self.seed();result=self.run_case();self.check_hit(result)
        self.assertGreater(result['history_rows'],0)
        self.assertEqual(self.run_case()['history_rows'],0)

    def test_detached_images_get_new_identity_paths_and_native_skip_proof(self):
        self.seed(images=True);result=self.run_case();self.check_hit(result)
        with fixture.connect(self.catalogue) as db:
            rows=list(db.execute('select SourcesJSON from HomeLibreCompressionImageSets where FileKey<>?',(self.w['identity'][:25],)))
        self.assertEqual(len(rows),1)
        for image in json.loads(rows[0][0]):
            if image['path']:
                self.assertTrue(Path(image['path']).is_relative_to(self.destination))
                self.assertEqual(image['source_sha256'],fixture.digest(Path(image['path'])))

    def test_7z_without_images_still_has_native_image_set_witness(self):
        self.seed(sevenzip=True);self.check_hit(self.run_case())

    def test_timestamp_only_old_check_is_rebound_using_full_container_hash(self):
        self.seed()
        with fixture.connect(self.catalogue) as db:
            db.execute('update HomeLibreCompressionChecks set SourceIdentity=?',(self.w['identity'][:43]+'0'*16,))
        self.check_hit(self.run_case())

    def test_stale_container_hash_does_not_become_a_cache_hit(self):
        self.seed()
        with fixture.connect(self.catalogue) as db:db.execute('update HomeLibreCompressionChecks set SourceSHA256=?',('0'*64,))
        self.check_hit(self.run_case(),False)

    def test_stale_external_image_hash_does_not_become_a_cache_hit(self):
        self.seed(images=True)
        images=json.loads(self.w['images'])
        for image in images:
            if image['path']:image['source_sha256']=image['result_sha256']='0'*64
        with fixture.connect(self.catalogue) as db:db.execute('update HomeLibreCompressionImageSets set SourcesJSON=?',(json.dumps(images),))
        self.check_hit(self.run_case(),False)

    def test_conflicting_destination_history_is_not_overwritten(self):
        self.seed();self.config['rebind_history']=False;self.run_case()
        with fixture.connect(self.journal()/'state.sqlite') as state:
            identity=state.execute('select Identity from FileState where FileID=?',(self.w['file_id'],)).fetchone()[0]
        with fixture.connect(self.catalogue) as db:
            db.execute('insert into HomeLibreBookCompression values(?,?,?,?,?,?)',
                       (identity[:25],'101.fb2','9'*64,'8'*64,'7'*64,42))
        self.config['rebind_history']=True
        self.assertIn('противоречит',self.run_case('fail'))

    def test_rollback_preserves_all_old_history_and_no_partial_new_rows(self):
        self.seed(images=True);before=tables(self.catalogue)
        self.config['rollback_history']=True;self.assertIn('rollback',self.run_case('fail'))
        self.assertEqual(tables(self.catalogue),before)
        self.config['rollback_history']=False;self.check_hit(self.run_case())

    def test_location_and_history_changes_roll_back_in_the_same_transaction(self):
        self.seed(images=True);before=tables(self.catalogue)
        self.config.update(apply_locations=True,cancel_location_commit=True)
        self.assertIn('остановлена',self.run_case('fail'))
        self.assertEqual(tables(self.catalogue),before)
        self.config.update(apply_locations=False,cancel_location_commit=False)
        self.check_hit(self.run_case())

    def test_interruption_on_both_sides_of_history_commit_is_idempotent(self):
        for index,point in enumerate(('history-before-commit','history-after-commit')):
            with self.subTest(point=point):
                if index:self.tearDown();self.setUp()
                self.seed(images=True);self.config['crash']=point;self.run_case(97)
                self.config['crash']='';result=self.run_case();self.check_hit(result)
                self.assertEqual(result['copy_streams'],0)


if __name__=='__main__':unittest.main(verbosity=2)

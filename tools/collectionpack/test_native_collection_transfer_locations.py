"""Actual locator transactions on private catalogue/personal databases."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture
from test_native_collection_transfer_forks import tables

MARKERS={'HomeLibreTransferLocations','HomeLibreTransferForkReceipts',
         'HomeLibreTransferOperations','HomeLibreTransferGroupProofs'}


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer journal, SQLite, 7-Zip and private stage')
class TransferLocationTests(unittest.TestCase):
    attempts=crashes=0
    write_zip=staticmethod(fixture.TransferCatalogueTests.write_zip)
    tearDown=journal_fixture.TransferJournalTests.tearDown
    anchor=journal_fixture.TransferJournalTests.anchor
    journal=journal_fixture.TransferJournalTests.journal
    command=journal_fixture.TransferJournalTests.command
    read_review=journal_fixture.TransferJournalTests.read_review
    make_legacy=journal_fixture.TransferJournalTests.make_legacy

    def setUp(self):
        journal_fixture.TransferJournalTests.setUp(self)
        self.config.update(prepare=True,apply_locations=True)
        self.pending=None

    def payloads(self):
        return {str(p):fixture.digest(p) for root in (self.a,self.b) for p in root.rglob('*') if p.is_file()}

    def snapshots(self):
        paths=[self.catalogue,self.personal]
        if getattr(self,'other',None): paths.append(self.other)
        return {p:tables(p) for p in paths}

    def check_metadata(self,before):
        with fixture.connect(self.personal) as db:
            registrations={r[0]:(Path(r[1]),r[2]) for r in db.execute('select DatabaseID,DBFileName,RootFolder from Bases')}
        targets={}
        refs=[]
        if self.control.exists():
            targets={r[0]:(r[1],r[2]) for r in self.read_review('select ID,Destination,GroupID from Files')}
            refs=self.read_review('select RegistrationID,Kind,BookID,SourceKey,Folder,FileName,Ext,LibID,FileID,RetainReason '+
                                  'from RegisteredReferences where Resource=0')
            if getattr(self,'new_card',False):
                refs += [(cid,1,bid,'',folder,name,ext,libid,file_id,retained)
                         for cid,kind,bid,key,folder,name,ext,libid,file_id,retained in list(refs) if cid==7 and kind==0 and bid==2]
        all_paths=set(before)|{p for p,_ in registrations.values() if p.is_file()}
        for path in all_paths:
            old=before.get(path,before[self.catalogue]);after=tables(path)
            self.assertEqual([s for s in after[0] if s[1] not in MARKERS],[s for s in old[0] if s[1] not in MARKERS])
            committed=set()
            if 'HomeLibreTransferLocations' in after[1] and self.control.exists():
                cols=after[2]['HomeLibreTransferLocations']
                for row in after[1]['HomeLibreTransferLocations']:
                    m=dict(zip(cols,row))
                    if m['Operation']==self.journal().name:
                        self.assertEqual(m['ReviewSHA256'],self.anchor()['review_sha256'])
                        self.assertEqual(len(m['BindingSHA256']),64);committed.add(m['GroupID'])
            changes={}
            for cid,kind,bid,key,folder,name,ext,libid,file_id,retained in refs:
                if file_id not in targets or targets[file_id][1] not in committed or retained: continue
                if kind==1 and path!=self.personal: continue
                if kind!=1 and registrations[cid][0]!=path: continue
                table='CatalogBookCopies' if kind==2 else 'Books'
                rowkey=(key,) if kind==2 else (bid,cid) if kind==1 else (bid,)
                dest=Path(targets[file_id][0])
                if folder.rstrip('/\\').lower().endswith(('.zip','.7z')) and not folder.endswith(('/','\\')):
                    newfolder,newname=str(dest),name
                else:
                    linked=libid.startswith('local:link:')
                    fbd=name.lower().endswith('.zip') and not (linked and Path(folder).is_absolute())
                    newfolder=str(dest.parent)+os.sep;newname=dest.name if fbd else dest.name[:-len(ext)] if ext else dest.name
                    if fbd and linked and not Path(folder).is_absolute(): newfolder,newname='',str(dest)
                changes[(table,rowkey)]=(newfolder,newname)
            for name,rows in old[1].items():
                if name in MARKERS: continue
                expected=[];cols=old[2][name]
                for row in rows:
                    data=dict(zip(cols,row))
                    if name in ('Books','CatalogBookCopies'):
                        key=(data['SourceKey'],) if name=='CatalogBookCopies' else \
                            (data['BookID'],data['DatabaseID']) if path==self.personal else (data['BookID'],)
                        change=changes.get((name,key))
                        if change:
                            data['Folder'],data['FileName']=change
                            for column in cols:
                                if column.startswith('Search') and column[6:] in data:
                                    value=data[column[6:]];data[column]=value.upper() if value else ''
                    if name=='Bases' and path==self.personal:
                        cid=data['DatabaseID']
                        if cid in registrations:data['DBFileName']=str(registrations[cid][0])
                    expected.append(tuple(data[c] for c in cols))
                self.assertEqual(sorted(after[1][name],key=repr),sorted(expected,key=repr),str(path)+' / '+name)

    def run_case(self,expected=0):
        payloads=self.payloads();before=self.pending or self.snapshots()
        process=subprocess.run(self.command(),cwd=self.home,capture_output=True,timeout=getattr(self,'native_timeout',90),
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)})
        entry=dict(test=self.id(),request=dict(self.config),expected=expected,returncode=process.returncode,
                   output=(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        if self.result.exists():entry['result']=json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (fixture.STAGE/'invocations.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(entry,ensure_ascii=False)+'\n')
        self.assertEqual(self.payloads(),payloads,'locator publication changed original payload bytes')
        if expected==97:
            self.assertEqual(process.returncode,97,entry['output']);self.pending=before;type(self).crashes+=1
            return entry
        self.check_metadata(before);self.pending=None
        if expected=='fail':
            self.assertNotEqual(process.returncode,0,entry['output']);self.assertFalse(self.result.exists());return entry['output']
        self.assertEqual(process.returncode,expected,entry['output']);return entry['result']

    def resume(self,**options):
        self.config.update(mode='resume',crash='');self.config.update(options);return self.run_case()

    def test_main_copy_and_personal_paths_are_committed(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            self.assertTrue(Path(db.execute('select Folder from Books where BookID=1').fetchone()[0]).is_file())
            self.assertEqual(db.execute('select SourceKey from CatalogBookCopies').fetchone(),('b:file:stable-copy',))

    def test_replay_keeps_new_notes_without_recopying(self):
        self.run_case()
        with fixture.connect(self.personal) as db:db.execute("update Books set Annotation='После переноса',Progress=92 where BookID=1 and DatabaseID=7")
        self.assertEqual(self.resume()['copy_streams'],0)

    def test_personal_card_created_after_review_gets_its_new_locator(self):
        self.config.update(prepare=False,apply_locations=False);self.run_case()
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=2,DatabaseID=7,LibID='102',Title='Новая карточка',Folder='same.zip',
                FileName='102',Ext='.fb2',BookSize=802,Rate=4,Progress=22,Annotation='Новая заметка'))
        self.config.update(mode='resume',prepare=True,apply_locations=True)
        # Add the newly created optional card to the observer's expected path
        # map; the immutable application review itself remains unchanged.
        self.new_card=True;self.run_case()
        with fixture.connect(self.personal) as db:
            row=db.execute('select Folder,Rate,Progress,Annotation from Books where BookID=2 and DatabaseID=7').fetchone()
            self.assertTrue(Path(row[0]).is_file());self.assertEqual(row[1:],(4,22,'Новая заметка'))

    def test_same_catalogue_under_different_roots_uses_forks(self):
        with fixture.connect(self.personal) as db:db.execute('update Bases set DBFileName=? where DatabaseID=8',(str(self.catalogue),))
        self.config['read_fork_members']=True
        result=self.run_case();self.assertEqual(result['forks'],1)
        self.assertNotEqual(result['native_fork_reads'][0]['sha256'],result['native_fork_reads'][1]['sha256'])

    def test_separate_registered_catalogue_is_updated_too(self):
        self.other=self.home/'other.hlc2';shutil.copy2(self.catalogue,self.other)
        with fixture.connect(self.personal) as db:db.execute('update Bases set DBFileName=? where DatabaseID=8',(str(self.other),))
        self.run_case()

    def test_raw_filename_with_subdirectory_projects_to_same_file(self):
        raw=self.a/'sub'/'book.fb2';raw.parent.mkdir();raw.write_bytes(b'raw native fixture')
        with fixture.connect(self.catalogue) as db:db.execute("update Books set Folder='',FileName='sub/book' where BookID=1")
        self.run_case()

    def test_fbd_and_legacy_linked_format_are_preserved(self):
        self.write_zip(self.a/'pair.zip',b'FBD bytes')
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='pair.zip',Ext='.txt',LibID='local:link:62019fe5-c4ef-446a-b29a-563525be5d04' where BookID=1")
        self.run_case()

    def test_crash_between_database_commits_is_recovered(self):
        for index,point in enumerate(('locations-before-catalogue-commit','locations-after-catalogue-commit',
                                      'locations-before-personal-commit','locations-after-personal-commit')):
            with self.subTest(point=point):
                # Each independent fixture has its original locators restored.
                if index:
                    self.tearDown();self.setUp()
                self.config['crash']=point;self.run_case(97)
                self.assertEqual(self.resume()['copy_streams'],1) # Only the unrelated second carrier remains uncopied.


if __name__=='__main__':unittest.main(verbosity=2)

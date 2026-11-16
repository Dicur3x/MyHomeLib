"""Project an unpublished cache copy without rewriting the shared baseline."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal
import test_native_collection_transfer_locations as locations


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native cache projection and private stage')
class TransferCacheTests(journal.TransferJournalTests):
    def setUp(self):
        super().setUp()
        self.shared=self.home/'shared-cache.hlc2'
        self.clone=self.home/'unpublished-cache.hlc2'
        shutil.copy2(self.catalogue,self.shared)
        with fixture.connect(self.shared) as db:
            db.execute("update Books set LibID='' where BookID=2")
            fixture.insert(db,'Books',dict(BookID=4,LibID='',Title='Not selected / keep old address',
                Folder='unlisted.zip',FileName='104',Ext='.fb2',BookSize=44,Rate=3,Progress=29,Annotation='keep'))
            fixture.insert(db,'Books',dict(BookID=5,LibID='',Title='Other transferred source',
                Folder=str(self.b/'same.zip'),FileName='101',Ext='.fb2',BookSize=55))
            db.executescript('create table LibraryUpdateSourceKeys(BookID integer primary key,SourceKey text not null);'
                            'create table LibraryUpdateReviewKeys(BookID integer primary key,Key text not null);'
                            'create table LibraryUpdatePublisherLocations(BookID integer primary key,Location text not null);'
                            'create table LibraryUpdateExclusions(Key text primary key) without rowid;')
            db.execute('insert into LibraryUpdateSourceKeys values(1,?)',('a:file:'+('c'*64),))
            db.execute('insert into LibraryUpdateReviewKeys values(1,?)',('d'*64,))
            db.execute('insert into LibraryUpdatePublisherLocations values(1,?)',('publisher/original.zip',))
            db.execute("insert into LibraryUpdateExclusions values('keep-exclusion')")
            db.execute("update Books set UpdateDate='2026-11-16'")
        self.original=locations.tables(self.shared)
        self.shared_hash=fixture.digest(self.shared)
        shutil.copy2(self.shared,self.clone)
        self.cache_personal=self.home/'cache-reader-system.hlc2'
        shutil.copy2(self.personal,self.cache_personal)
        self.run_case()
        self.after_root=Path(self.read_review("select Destination from Roots where ID='collection'")[0][0])
        self.config.update(mode='resume',project_cache=str(self.clone),cache_source_id='a',
                           cache_before_root=str(self.a),cache_after_root=str(self.after_root))
        self.config['cache_personal']=str(self.cache_personal)

    def mapped(self,old):
        for source,dest in self.read_review('select Source,Destination from Files'):
            if Path(source)==Path(old):return Path(dest)
        for source,root in self.read_review('select Source,RootID from Bindings where FileID is null and Source is not null'):
            if Path(source)==Path(old):
                before,after=self.read_review('select InputPath,Destination from Roots where ID=?',(root,))[0]
                return Path(after)/Path(source).relative_to(before)
        return Path(old)

    def fresh_review(self):
        self.config.update(mode='create',project_cache='')
        self.run_case()
        self.after_root=Path(self.read_review("select Destination from Roots where ID='collection'")[0][0])
        self.config.update(mode='resume',project_cache=str(self.clone),cache_after_root=str(self.after_root))

    def freeze_cache(self):
        self.original=locations.tables(self.shared);self.shared_hash=fixture.digest(self.shared)
        shutil.copy2(self.shared,self.clone)

    @staticmethod
    def merge_key(folder,name,ext,root):
        path=Path(folder)
        member=name if name.lower().endswith(ext.lower()) else name+ext
        value=os.path.relpath(path,root)+'\x01'+member
        return 'a:file:'+hashlib.sha256(value.lower().encode()).hexdigest()

    def assert_preserved(self,result):
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)
        self.assertEqual(result['cache_examined'],5)
        after=locations.tables(self.clone)
        old_tables,old_cols=self.original[1:]
        for table,rows in old_tables.items():
            if table in ('LibraryUpdateSourceKeys','LibraryUpdateReviewKeys','LibraryUpdatePublisherLocations'):continue
            expected=[];cols=old_cols[table]
            for row in rows:
                data=dict(zip(cols,row))
                if table=='Books':
                    old=Path(data['Folder'])
                    if not old.is_absolute():old=self.a/old
                    new=self.mapped(old)
                    # All five ordinary cache rows are archive locators. Even
                    # unlisted rows retain their old absolute native address.
                    resolved_after=Path(data['Folder'])
                    if not resolved_after.is_absolute():resolved_after=self.after_root/resolved_after
                    if resolved_after!=new:data['Folder']=str(new)
                    if data['Folder']!=dict(zip(cols,row))['Folder']:
                        for column in cols:
                            if column.startswith('Search') and column[6:] in data:
                                value=data[column[6:]];data[column]=value.upper() if value else ''
                expected.append(tuple(data[c] for c in cols))
            self.assertEqual(sorted(after[1][table],key=repr),sorted(expected,key=repr),table)
        by_id={row['id']:row['key'].lower() for row in result['cache_readback']}
        self.assertEqual(by_id[1],'a:file:'+('c'*64))
        with fixture.connect(self.clone) as db:
            self.assertEqual(db.execute('select Location from LibraryUpdatePublisherLocations where BookID=1').fetchone()[0],
                             'publisher/original.zip')
            self.assertEqual(db.execute('select Key from LibraryUpdateReviewKeys where BookID=1').fetchone()[0],'d'*64)
            for book_id in (2,3,4,5):
                row=next(dict(zip(old_cols['Books'],r)) for r in old_tables['Books'] if r[0]==book_id)
                old=Path(row['Folder'])
                if not old.is_absolute():old=self.a/old
                self.assertEqual(by_id[book_id],self.merge_key(old,row['FileName'],row['Ext'],self.a))
            # Empty LIBID outside the new root retains its original review key.
            old=hashlib.sha256(('file:unlisted.zip\x01\x01'+'104\x01.fb2').encode()).hexdigest()
            self.assertEqual(db.execute('select Key from LibraryUpdateReviewKeys where BookID=4').fetchone()[0].lower(),old)

    def test_clone_follows_transferred_and_missing_files_but_unlisted_rows_keep_old_address(self):
        self.assert_preserved(self.run_case())

    def test_projection_does_not_probe_reused_original_names(self):
        # Deliberate private fixture mutation, made before the preservation
        # snapshot. The cache projection must use the frozen review only.
        (self.a/'same.zip').write_bytes(b'foreign replacement at old name')
        self.assert_preserved(self.run_case())

    def test_source_free_projection_uses_only_frozen_metadata(self):
        self.a.rename(self.home/'offline-a');self.b.rename(self.home/'offline-b')
        self.assert_preserved(self.run_case())

    def test_crash_before_clone_commit_rolls_back_and_fresh_copy_can_be_projected(self):
        self.config['crash']='cache-before-commit';self.run_case(97)
        self.assertEqual(locations.tables(self.clone)[1:],self.original[1:])
        self.config['crash']='';self.assert_preserved(self.run_case())

    def test_cancellation_rolls_back_unpublished_clone(self):
        self.config['cancel_cache_after']=16;self.run_case('fail')
        self.assertEqual(locations.tables(self.clone)[1:],self.original[1:])
        self.config['cancel_cache_after']=0;self.assert_preserved(self.run_case())

    def test_saved_key_for_another_source_is_refused_by_normal_snapshot_reader(self):
        with fixture.connect(self.clone) as db:db.execute("update LibraryUpdateSourceKeys set SourceKey='other:file:foreign' where BookID=1")
        output=self.run_case('fail')
        self.assertIn('другому источнику',output)
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)

    def test_successful_clone_is_not_projected_twice_with_the_old_root(self):
        self.assert_preserved(self.run_case());before=locations.tables(self.clone)
        self.assertIn('новая копия',self.run_case('fail'))
        self.assertEqual(locations.tables(self.clone)[1:],before[1:])
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)

    def test_zip_alias_uses_reviewed_7z_key_even_when_original_names_are_gone(self):
        fixture.TransferCatalogueTests.make_legacy(self)
        with fixture.connect(self.shared) as db:
            db.execute("update Books set Folder='legacy.zip' where BookID=1")
            db.execute('delete from LibraryUpdateSourceKeys where BookID=1')
        self.freeze_cache();self.fresh_review()
        self.a.rename(self.home/'offline-a');self.b.rename(self.home/'offline-b')
        result=self.run_case();row=next(r for r in result['cache_readback'] if r['id']==1)
        self.assertEqual(row['key'].lower(),self.merge_key(self.a/'legacy.7z','101','.fb2',self.a))
        self.assertEqual(Path(row['path']),self.mapped(self.a/'legacy.7z'))
        self.assertEqual(row['format'],1)
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)

    def test_raw_subdirectory_fbd_and_linked_archive_keep_their_native_kinds(self):
        self.write_zip(self.a/'pair.zip',b'whole native FBD carrier')
        raw=self.a/'sub/book.fb2';raw.parent.mkdir();raw.write_bytes(b'raw native book')
        linked=self.home/'linked';linked.mkdir();(linked/'opaque.zip').write_bytes(b'linked opaque archive')
        for path in (self.catalogue,self.shared):
            with fixture.connect(path) as db:
                db.execute("update Books set Folder='',FileName='pair.zip',Ext='.txt' where BookID=1")
                db.execute("update Books set Folder='',FileName='sub/book' where BookID=2")
                fixture.insert(db,'Books',dict(BookID=6,LibID='local:link:62019fe5-c4ef-446a-b29a-563525be5d04',
                    Title='Linked opaque archive',Folder=str(linked)+os.sep,FileName='opaque.zip',Ext='',UpdateDate='2026-11-16'))
        self.freeze_cache();self.fresh_review()
        # Force projection to absolute locators outside this cache's own root.
        # A second source may keep that root while sharing moved physical files.
        self.config['cache_after_root']=str(self.home/'other-reader-root')
        self.a.rename(self.home/'offline-a');self.b.rename(self.home/'offline-b');linked.rename(self.home/'offline-linked')
        result=self.run_case();rows={r['id']:r for r in result['cache_readback']}
        for book_id,path,kind in ((1,self.a/'pair.zip',2),(2,raw,0),(6,linked/'opaque.zip',3)):
            self.assertEqual(rows[book_id]['format'],kind)
            self.assertEqual(Path(rows[book_id]['path']),self.mapped(path))
        before=self.original[1]['Books'];cols=self.original[2]['Books']
        after=locations.tables(self.clone)[1]['Books']
        for old,new in zip(sorted(before),sorted(after)):
            for column,a,b in zip(cols,old,new):
                if column not in ('Folder','FileName') and not column.startswith('Search'):
                    self.assertEqual(a,b,column)
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)

    def test_normal_snapshot_reads_verified_copies_after_original_roots_go_offline(self):
        with fixture.connect(self.shared) as db:db.execute('delete from Books where BookID in (3,4)')
        self.freeze_cache()
        self.config.update(project_cache='',prepare=True)
        prepared=self.run_case();self.assertGreater(prepared['prepared_files'],0)
        self.config.update(project_cache=str(self.clone),prepare=False,cache_read_streams=True)
        self.a.rename(self.home/'offline-a');self.b.rename(self.home/'offline-b')
        result=self.run_case();rows={r['id']:r for r in result['cache_readback']}
        for book_id,body in ((1,b'first'),(2,b'firstother'),(5,b'second')):
            self.assertEqual(rows[book_id]['sha256'].lower(),hashlib.sha256(body).hexdigest())
            self.assertEqual(rows[book_id]['format'],1)
        self.assertEqual(rows[1]['key'].lower(),'a:file:'+('c'*64))
        self.assertEqual(fixture.digest(self.shared),self.shared_hash)

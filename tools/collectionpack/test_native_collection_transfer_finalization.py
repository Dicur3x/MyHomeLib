"""Durable roots/settings phase through the real coordinator; move stays pending."""
import copy
import hashlib
import json
import os
from pathlib import Path
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_final_rows as row_fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture

PROFILE_PROPERTY=0x20040022
INTENT='HomeLibreTransferFinalization'
SETTINGS_RECEIPT='HomeLibreTransferFinalSettings'
location_fixture.MARKERS.update((INTENT,SETTINGS_RECEIPT))


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native roots finalization and private stage')
class TransferFinalizationTests(row_fixture.TransferFinalRowsTests):
    # Explicit selectors avoid repeating all inherited component scenarios.
    def setUp(self):
        super().setUp()
        self.config.update(final_rows=False,finalize_roots=True)
        self.incoming=self.home/'incoming';self.incoming.mkdir()
        self.profiles=dict(version=1,custom={'keep':'profile metadata'},sources=[dict(
            id='{00000000-0000-4000-8000-%012d}'%(i+1),name='Обновление '+str(i),
            location=str(self.incoming),index='library.inpx',source_id='',books_root=root,
            enabled=True,full=True,custom={'keep':i}) for i,root in enumerate((str(self.a),str(self.incoming),''))])
        with fixture.connect(self.catalogue) as db:
            db.execute('insert into Settings values(?,?)',(PROFILE_PROPERTY,json.dumps(self.profiles,ensure_ascii=False)))

    def intent(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('select count(*) from sqlite_master where name=?',(INTENT,)).fetchone()[0]:return None
            return db.execute('select Operation,ReviewSHA256,IntentJSON,IntentSHA256,State from '+INTENT).fetchone()

    def root_destination(self):
        return Path(self.read_review("select Destination from Roots where ID='collection'")[0][0])

    def mapped_path(self,path):
        original=Path(path);best=None
        for source,dest in self.read_review('select InputPath,Destination from Roots where Destination is not null'):
            root=Path(source)
            if original.is_relative_to(root) and (best is None or len(root.parts)>len(best[0].parts)):best=(root,Path(dest))
        return best[1]/original.relative_to(best[0]) if best else original

    def expected_source_settings(self,text,selected,registered):
        sources=json.loads(text) if text else []
        for source in sources:
            if selected and source.get('root'):source['root']=str(self.mapped_path(source['root']))+os.sep
            cid=source.get('collection',-1)
            if not source.get('inpx') and cid in registered:
                file=registered[cid][0]
                if Path(source.get('file',''))==self.catalogue and file!=self.catalogue:source['file']=str(file)
        return sources

    def check_metadata(self,before):
        expected=copy.deepcopy(before)
        with fixture.connect(self.personal) as db:
            registered={r[0]:(Path(r[1]),r[2]) for r in db.execute('select DatabaseID,DBFileName,RootFolder from Bases')}
        for path,_ in registered.values():
            if path.is_file() and path not in expected:expected[path]=copy.deepcopy(before[self.catalogue])
        intent=self.intent()
        for path,(_,tables,columns) in expected.items():
            marked=False
            with fixture.connect(path) as db:
                if db.execute('select count(*) from sqlite_master where name=?',(SETTINGS_RECEIPT,)).fetchone()[0]:
                    marked=bool(db.execute('select count(*) from '+SETTINGS_RECEIPT).fetchone()[0])
            if marked and 'Settings' in tables:
                rows=[];cols=columns['Settings']
                for row in tables['Settings']:
                    data=dict(zip(cols,row));sid=data['SettingID'];text=data['SettingValue']
                    if sid==fixture.SOURCE_PROPERTY and text:
                        cid=next(cid for cid,(file,_) in registered.items() if file==path)
                        frozen=self.read_review('select SourcesJSON from ReferenceRegistrations where RegistrationID=?',(cid,))[0][0]
                        data['SettingValue']=self.expected_source_settings(frozen,path==self.catalogue,registered)
                    if sid==PROFILE_PROPERTY and path==self.catalogue and text:
                        profiles=copy.deepcopy(self.profiles)
                        for source in profiles['sources']:
                            old=source.get('books_root','')
                            if old and self.mapped_path(old)!=Path(old):source['books_root']=str(self.mapped_path(old))+os.sep
                        data['SettingValue']=profiles
                    rows.append(tuple(data[c] for c in cols))
                # JSON object equality deliberately retains every unknown field;
                # serialization order is not user data.
                tables['Settings']=rows
            if path==self.personal and intent and intent[-1]=='roots-applied':
                rows=[];cols=columns['Bases']
                for row in tables['Bases']:
                    data=dict(zip(cols,row))
                    if data['DatabaseID']==7:data['RootFolder']=str(self.root_destination())+os.sep
                    rows.append(tuple(data[c] for c in cols))
                tables['Bases']=rows
            if path==self.catalogue and getattr(self,'expect_gap_title',False):
                cols=columns['Books'];rows=[]
                for row in tables['Books']:
                    data=dict(zip(cols,row))
                    if data['BookID']==1:data['Title']='late finalization title'
                    rows.append(tuple(data[c] for c in cols))
                tables['Books']=rows
            if path==self.personal and intent and intent[-1]=='roots-applied' and getattr(self,'late_private',False):
                cols=columns['Books'];rows=[]
                for row in tables['Books']:
                    data=dict(zip(cols,row))
                    if data['BookID']==444:data['Folder']=str(self.a)+os.sep
                    rows.append(tuple(data[c] for c in cols))
                tables['Books']=rows
        # The existing all-table verifier uses strings for Settings. Canonicalize
        # only the two known JSON properties in both observations, without writes.
        original=location_fixture.tables
        def canonical(snapshot):
            _,tables,columns=snapshot
            if 'Settings' not in tables:return snapshot
            cols=columns['Settings'];rows=[]
            for row in tables['Settings']:
                item=dict(zip(cols,row));value=item['SettingValue']
                if item['SettingID'] in (fixture.SOURCE_PROPERTY,PROFILE_PROPERTY) and isinstance(value,str) and value:
                    item['SettingValue']=json.loads(value)
                rows.append(tuple(item[c] for c in cols))
            tables['Settings']=rows;return snapshot
        for snapshot in expected.values():canonical(snapshot)
        location_fixture.tables=lambda path:canonical(original(path))
        try:super().check_metadata(expected)
        finally:location_fixture.tables=original

    def resume_roots(self,expected=0,**options):
        defaults=dict(finalize_roots=False,cancel_finalization_stage='',edit_finalization_gap=False)
        defaults.update(options);return self.continue_operation(expected,**defaults)

    def assert_applied(self,result):
        self.assertTrue(result['roots_applied']);intent=self.intent()
        self.assertEqual(intent[0],self.journal().name);self.assertEqual(intent[1],self.anchor()['review_sha256'])
        self.assertEqual(hashlib.sha256(intent[2].encode()).hexdigest(),intent[3]);self.assertEqual(intent[4],'roots-applied')
        self.assertTrue(self.root_destination().is_dir())
        with fixture.connect(self.personal) as db:
            self.assertEqual(Path(db.execute('select RootFolder from Bases where DatabaseID=7').fetchone()[0]),self.root_destination())
        with fixture.connect(self.catalogue) as db:
            profiles=json.loads(db.execute('select SettingValue from Settings where SettingID=?',(PROFILE_PROPERTY,)).fetchone()[0])
        self.assertEqual(profiles['sources'][1]['books_root'],str(self.incoming));self.assertEqual(profiles['sources'][2]['books_root'],'')
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1],'pending','cache/full-move completion remains separate')

    def test_coordinator_applies_sources_profiles_roots_and_missing_rows_then_replays(self):
        self.assert_applied(self.run_case())
        self.assert_applied(self.resume_roots())

    def crash_and_resume(self,stage):
        self.config['crash']=stage;self.run_case(97)
        self.assertIsNotNone(self.intent());self.assert_applied(self.resume_roots())

    def test_crash_after_independent_intent_routes_resume_away_from_source_phase(self):
        self.crash_and_resume('finalization-intent-committed')

    def test_crash_after_catalogue_commit_recovers_source_settings_and_copy_roots(self):
        self.crash_and_resume('finalization-after-catalogue-commit')

    def test_crash_before_personal_commit_rolls_back_root_and_late_rows(self):
        self.crash_and_resume('finalization-before-personal-commit')

    def test_crash_after_personal_commit_recognizes_already_applied_roots(self):
        self.crash_and_resume('finalization-after-personal-commit')

    def test_cancel_before_personal_commit_preserves_notes_and_resumes(self):
        self.config['cancel_finalization_stage']='finalization-before-personal-commit'
        self.assertIn('останов',self.run_case('fail'));self.assertEqual(self.intent()[-1],'intent')
        self.assert_applied(self.resume_roots())

    def test_external_catalogue_writer_in_commit_gap_forces_revalidation_and_keeps_title(self):
        self.config['finalize_roots']=False;self.run_case()
        self.expect_gap_title=True
        self.assertIn('между этапами',self.resume_roots('fail',finalize_roots=True,edit_finalization_gap=True))
        self.assert_applied(self.resume_roots())

    def test_kept_first_source_allows_unprotected_retained_originals(self):
        self.config['destination']=str(self.a);self.assert_applied(self.run_case())
        self.assertTrue((self.a/'same.zip').is_file())

    def test_late_personal_only_file_keeps_original_address_after_default_root_moves(self):
        self.config['crash']='finalization-intent-committed';self.run_case(97)
        private=self.a/'personal-late.fb2';private.write_bytes(b'late private file must remain readable')
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=444,DatabaseID=7,LibID='444',Title='Поздняя личная книга',
                Folder='',FileName='personal-late',Ext='.fb2',BookSize=37,Rate=5,Progress=67,Annotation='Самая новая заметка'))
        self.pending=None;self.late_private=True;self.assert_applied(self.resume_roots())
        self.assertEqual(private.read_bytes(),b'late private file must remain readable')

    def test_appearing_missing_archive_stops_finalization_without_deleting_it(self):
        self.config['crash']='finalization-intent-committed';self.run_case(97)
        archive=self.a/'notdownloaded.zip';self.write_zip(archive,b'newly arrived archive')
        before=fixture.digest(archive);self.pending=None
        self.assertIn('Появился отсутствовавший',self.resume_roots('fail'))
        self.assertEqual(fixture.digest(archive),before);self.assertEqual(self.intent()[-1],'intent')

    def test_other_aliases_keep_default_root_and_rebind_their_source_catalogue_file(self):
        private=self.a/'other-personal.fb2';private.write_bytes(b'private retained alias book')
        with fixture.connect(self.personal) as db:
            for cid in (8,9):fixture.insert(db,'Bases',dict(DatabaseID=cid,BaseName='Другое подключение '+str(cid),
                DBFileName=str(self.catalogue),RootFolder=str(self.a)))
            fixture.insert(db,'Books',dict(BookID=444,DatabaseID=8,LibID='444',Title='Личная книга другого подключения',
                Folder='',FileName='other-personal',Ext='.fb2',BookSize=27,Progress=73,Annotation='Не менять путь'))
        sources=json.loads(self.sources)
        sources.append(dict(id='external',name='Подключённый каталог',inpx='',root=str(self.a),collection=8,
                            file=str(self.catalogue),custom={'keep':'external source'}))
        self.sources=json.dumps(sources,ensure_ascii=False)
        with fixture.connect(self.catalogue) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?',(self.sources,fixture.SOURCE_PROPERTY))
        self.assert_applied(self.run_case())
        with fixture.connect(self.personal) as db:
            aliases=db.execute('select DBFileName,RootFolder from Bases where DatabaseID in (8,9) order by DatabaseID').fetchall()
        self.assertEqual(aliases[0],aliases[1]);self.assertEqual(Path(aliases[0][1]),self.a)
        for path in (self.catalogue,Path(aliases[0][0])):
            with fixture.connect(path) as db:
                values=json.loads(db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0])
            source=next(s for s in values if s['id']=='external');self.assertEqual(Path(source['file']),Path(aliases[0][0]))
        self.assertEqual(private.read_bytes(),b'private retained alias book')

    def test_unused_original_default_root_gets_a_real_guarded_final_directory(self):
        unused=self.home/'unused-default';unused.mkdir();self.config['root']=str(unused)
        with fixture.connect(self.personal) as db:
            db.execute('update Bases set RootFolder=? where DatabaseID=7',(str(unused),))
            db.execute('update Books set Folder=? where BookID=1 and DatabaseID=7',(str(self.a/'same.zip'),))
            db.execute('update Books set Folder=? where BookID=3 and DatabaseID=7',(str(self.a/'notdownloaded.zip'),))
        with fixture.connect(self.catalogue) as db:
            db.execute('update Books set Folder=? where BookID in (1,2)',(str(self.a/'same.zip'),))
            db.execute('update Books set Folder=? where BookID=3',(str(self.a/'notdownloaded.zip'),))
        self.assert_applied(self.run_case())
        self.assertNotEqual(self.root_destination(),self.mapped_path(self.a))

    def test_late_missing_personal_card_follows_its_reviewed_main_future_locator(self):
        with fixture.connect(self.personal) as db:db.execute('delete from Books where BookID=3 and DatabaseID=7')
        self.config['crash']='finalization-intent-committed';self.run_case(97)
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=3,DatabaseID=7,LibID='103',Title='Новая заметка отсутствующей книги',
                Folder='notdownloaded.zip',FileName='103',Ext='.fb2',BookSize=803,Rate=4,Progress=56,Annotation='Свежий текст'))
        self.pending=None;self.assert_applied(self.resume_roots())
        with fixture.connect(self.personal) as db:
            self.assertEqual(Path(db.execute('select Folder from Books where BookID=3 and DatabaseID=7').fetchone()[0]),self.missing_archive())

    def test_rehashed_intent_cannot_redirect_the_reviewed_final_root(self):
        self.config['crash']='finalization-intent-committed';self.run_case(97)
        plan=json.loads(self.intent()[2]);outside=self.home/'unreviewed-root';plan['root']=str(outside)
        raw=json.dumps(plan,ensure_ascii=False)
        with fixture.connect(self.personal) as db:
            db.execute('update '+INTENT+' set IntentJSON=?,IntentSHA256=?',(raw,hashlib.sha256(raw.encode()).hexdigest()))
        self.pending=None;self.assertIn('Намерение относится',self.resume_roots('fail'));self.assertFalse(outside.exists())

    def test_raw_subdirectory_and_legacy_linked_fbd_keep_native_addresses_after_root_commit(self):
        self.write_zip(self.a/'pair.zip',b'whole FBD carrier')
        raw=self.a/'sub/book.fb2';raw.parent.mkdir();raw.write_bytes(b'raw retained book content')
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='pair.zip',Ext='.txt',LibID='local:link:62019fe5-c4ef-446a-b29a-563525be5d04' where BookID=1")
            db.execute("update Books set Folder='',FileName='sub/book' where BookID=2")
        self.assert_applied(self.run_case());self.assert_applied(self.resume_roots())

    def test_flibrary_sidecar_groups_survive_root_settings_commit_and_source_free_replay(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        result=self.run_case();self.assert_applied(result)
        self.assertTrue(any(group['files']>=3 for group in result['groups']))
        self.assert_applied(self.resume_roots());self.assert_targets()

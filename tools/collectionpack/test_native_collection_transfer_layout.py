"""Read-only final-root/source/profile/future-locator projection on private data."""
import json
import os
from pathlib import Path
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_removal as removal_fixture
import test_native_collection_transfer_operation as operation_fixture


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer layout and private stage')
class TransferLayoutTests(unittest.TestCase):
    attempts=crashes=0
    write_zip=staticmethod(removal_fixture.TransferRemovalTests.write_zip)
    make_legacy=removal_fixture.TransferRemovalTests.make_legacy
    anchor=removal_fixture.TransferRemovalTests.anchor
    journal=removal_fixture.TransferRemovalTests.journal
    command=removal_fixture.TransferRemovalTests.command
    read_review=removal_fixture.TransferRemovalTests.read_review
    payloads=removal_fixture.TransferRemovalTests.payloads
    snapshots=removal_fixture.TransferRemovalTests.snapshots
    check_metadata=removal_fixture.TransferRemovalTests.check_metadata
    registry_rows=removal_fixture.TransferRemovalTests.registry_rows
    operation=removal_fixture.TransferRemovalTests.operation
    intents=removal_fixture.TransferRemovalTests.intents
    run_case=removal_fixture.TransferRemovalTests.run_case
    assert_targets=removal_fixture.TransferRemovalTests.assert_targets
    tearDown=removal_fixture.TransferRemovalTests.tearDown
    continue_operation=operation_fixture.TransferOperationTests.continue_operation

    def setUp(self):
        removal_fixture.TransferRemovalTests.setUp(self)
        self.config.update(prepare=False,apply_locations=False,register_operation=False,register_groups=False,final_layout=True)

    def change_sources(self,sources):
        self.sources=json.dumps(sources,ensure_ascii=False)
        with fixture.connect(self.catalogue) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?',(self.sources,fixture.SOURCE_PROPERTY))

    def layout(self):
        return self.run_case()['final_layout']

    def roots(self,data):
        roots={r['id']:r for r in data['roots']}
        for r in roots.values():
            self.assertTrue(Path(r['destination']).resolve().is_relative_to(Path(self.config['destination']).resolve()))
        return roots

    def test_sources_keep_unknown_fields_and_preview_writes_no_books_or_roots(self):
        before=json.loads(self.sources);data=self.layout();roots=self.roots(data)
        actual=json.loads(data['sources_json'])
        for old,new in zip(before,actual):
            expected=dict(old,root=roots['source:'+old['id']]['destination'])
            self.assertEqual(new,expected)
        self.assertFalse(list(self.destination.iterdir()))
        future=data['future'];self.assertEqual(len(future),1)
        self.assertEqual((future[0]['kind'],future[0]['book'],future[0]['filename']),(0,3,'103'))
        self.assertEqual(Path(future[0]['source']),Path(roots['collection']['destination'])/'notdownloaded.zip')
        self.assertFalse(Path(future[0]['source']).exists())

    def test_profiles_move_only_books_roots_inside_transferred_sources(self):
        incoming=self.home/'incoming';incoming.mkdir()
        paths=[str(self.a),str(self.a/'subfolder'),str(incoming),'']
        profiles=dict(version=1,custom={'keep':'root metadata'},sources=[dict(
            id='{00000000-0000-4000-8000-%012d}'%(i+1),name='Профиль '+str(i),location=str(self.home/'updates'),
            index='library.inpx',source_id='',books_root=path,enabled=i!=1,full=True,custom={'keep':i})
            for i,path in enumerate(paths)])
        self.config['layout_profiles']=json.dumps(profiles,ensure_ascii=False)
        data=self.layout();roots=self.roots(data);actual=json.loads(data['profiles_json'])
        expected=json.loads(json.dumps(profiles))
        expected['sources'][0]['books_root']=roots['collection']['destination']
        expected['sources'][1]['books_root']=str(Path(roots['collection']['destination'])/'subfolder')+os.sep
        self.assertEqual(actual,expected)
        self.assertEqual(actual['sources'][2]['books_root'],str(incoming))
        self.assertEqual(actual['sources'][3]['books_root'],'')

    def test_missing_loose_book_preserves_format_and_relative_subdirectory(self):
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='missing/book' where BookID=3")
        data=self.layout();future=data['future'][0];roots=self.roots(data)
        expected=Path(roots['collection']['destination'])/'missing/book.fb2'
        self.assertEqual(Path(future['source']),expected)
        self.assertEqual(Path(future['folder']),expected.parent);self.assertEqual(future['filename'],'book')

    def test_legacy_linked_fbd_future_locator_keeps_its_native_kind(self):
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='absent.zip',Ext='.txt',LibID='local:link:62019fe5-c4ef-446a-b29a-563525be5d04' where BookID=3")
        future=self.layout()['future'][0]
        self.assertEqual(future['folder'],'');self.assertEqual(future['filename'],future['source'])
        self.assertTrue(future['source'].endswith('absent.zip'))

    def test_unavailable_root_gets_a_deterministic_future_folder(self):
        offline=self.home/'not-mounted';sources=json.loads(self.sources)
        sources.append(dict(id='offline',name='Недоступный',root=str(offline),custom='keep missing'))
        self.change_sources(sources)
        with fixture.connect(self.catalogue) as db:
            db.execute('update Books set Folder=? where BookID=3',(str(offline/'missing.zip'),))
        data=self.layout();roots=self.roots(data);root=roots['source:offline']
        self.assertFalse(root['observed']);self.assertIn('future-',root['destination'])
        self.assertEqual(Path(data['future'][0]['source']),Path(root['destination'])/'missing.zip')
        self.assertFalse(offline.exists());self.assertFalse(Path(root['destination']).exists())

    def test_existing_parent_without_direct_books_keeps_child_root_layout(self):
        sources=json.loads(self.sources);sources.append(dict(id='parent',name='Общая папка',root=str(self.home)))
        self.change_sources(sources);data=self.layout();roots=self.roots(data)
        parent=Path(roots['source:parent']['destination'])
        self.assertTrue(roots['source:parent']['observed'])
        self.assertEqual(Path(roots['collection']['destination']),parent/'source-a')
        self.assertEqual(Path(roots['source:b']['destination']),parent/'source-b')
        self.assertFalse(list(self.destination.iterdir()))

    def test_kept_first_source_and_its_logical_alias_do_not_get_future_folders(self):
        self.config['destination']=str(self.a);data=self.layout();roots=self.roots(data)
        self.assertEqual(Path(roots['collection']['destination']),self.a)
        self.assertEqual(Path(roots['source:a']['destination']),self.a)
        self.assertTrue(roots['source:a']['observed'])

    def test_projection_stays_identical_after_originals_have_been_removed(self):
        first=self.layout()
        self.config.update(mode='resume',run_operation=True,remove_sources=True)
        result=self.run_case()
        self.assertEqual(result['removed_sources'],2)
        self.assertEqual(result['final_layout'],first)
        self.assertEqual(self.continue_operation()['final_layout'],first)
        with fixture.connect(self.catalogue) as db:
            self.assertEqual(db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0],self.sources)

    def test_unknown_profile_version_fails_without_writing_settings(self):
        self.config['layout_profiles']=json.dumps(dict(version=2,sources=[]))
        self.assertIn('Неизвестная версия',self.run_case('fail'))
        self.assertFalse(list(self.destination.iterdir()))

    def test_parent_layout_is_used_by_actual_transfer_without_moving_unlisted_files(self):
        sources=json.loads(self.sources);sources.append(dict(id='parent',name='Общая папка',root=str(self.home)))
        self.change_sources(sources);self.config.update(run_operation=True,remove_sources=True)
        result=self.run_case();data=result['final_layout'];roots=self.roots(data)
        parent=Path(roots['source:parent']['destination'])
        self.assertEqual(result['removed_sources'],2)
        for row in self.intents().values():
            self.assertEqual(Path(row['Destination']),parent/Path(row['Source']).relative_to(self.home))
        self.assertTrue(self.catalogue.is_file());self.assertTrue(self.personal.is_file());self.assertTrue(self.binary.is_file())

    def test_nested_unavailable_roots_share_one_future_tree(self):
        offline=self.home/'not-mounted';child=offline/'child';sources=json.loads(self.sources)
        sources.extend([dict(id='z-parent',name='Недоступный родитель',root=str(offline)),
                        dict(id='a-child',name='Недоступный потомок',root=str(child))])
        self.change_sources(sources)
        with fixture.connect(self.catalogue) as db:db.execute('update Books set Folder=? where BookID=3',(str(child/'missing.zip'),))
        data=self.layout();roots=self.roots(data)
        parent=Path(roots['source:z-parent']['destination']);mapped_child=Path(roots['source:a-child']['destination'])
        self.assertEqual(mapped_child,parent/'child')
        self.assertEqual(Path(data['future'][0]['source']),mapped_child/'missing.zip')
        self.assertFalse(offline.exists());self.assertFalse(parent.exists())

    def test_missing_alternate_copy_keeps_its_source_key_and_projected_copy_root(self):
        with fixture.connect(self.catalogue) as db:
            fixture.insert(db,'CatalogBookCopies',dict(SourceKey='b:file:missing-copy',BookID=2,Root=str(self.b),
                Folder='notdownloaded-copy.zip',FileName='102',Ext='.fb2',InsideNo=0,BookSize=123,
                LibID='b:102',SourceName='Второй'))
        data=self.layout();roots=self.roots(data)
        future=next(row for row in data['future'] if row['kind']==2)
        self.assertEqual((future['book'],future['key'],future['filename']),(2,'b:file:missing-copy','102'))
        self.assertEqual(Path(future['root']),Path(roots['source:b']['destination']))
        self.assertEqual(Path(future['source']),Path(future['root'])/'notdownloaded-copy.zip')

    def test_unavailable_child_inside_kept_destination_does_not_get_a_second_tree(self):
        child=self.a/'missing-child';sources=json.loads(self.sources)
        sources.append(dict(id='missing-child',name='Будущая подпапка',root=str(child)))
        self.change_sources(sources);self.config['destination']=str(self.a)
        with fixture.connect(self.catalogue) as db:db.execute('update Books set Folder=? where BookID=3',(str(child/'missing.zip'),))
        data=self.layout();root=self.roots(data)['source:missing-child']
        self.assertFalse(root['observed']);self.assertEqual(Path(root['destination']),child)
        self.assertEqual(Path(data['future'][0]['source']),child/'missing.zip');self.assertFalse(child.exists())

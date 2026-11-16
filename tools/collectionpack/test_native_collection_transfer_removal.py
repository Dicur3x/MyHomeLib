"""Handle-bound original removal after independent receipts on private data only."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_registry as registry_fixture


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer removal, SQLite, 7-Zip and private stage')
class TransferRemovalTests(unittest.TestCase):
    attempts=crashes=0
    write_zip=staticmethod(fixture.TransferCatalogueTests.write_zip)
    make_legacy=fixture.TransferCatalogueTests.make_legacy
    anchor=journal_fixture.TransferJournalTests.anchor
    journal=journal_fixture.TransferJournalTests.journal
    command=journal_fixture.TransferJournalTests.command
    read_review=journal_fixture.TransferJournalTests.read_review
    payloads=location_fixture.TransferLocationTests.payloads
    snapshots=location_fixture.TransferLocationTests.snapshots
    check_metadata=location_fixture.TransferLocationTests.check_metadata
    registry_rows=registry_fixture.TransferRegistryTests.registry_rows
    operation=registry_fixture.TransferRegistryTests.operation

    def setUp(self):
        location_fixture.TransferLocationTests.setUp(self)
        # Positive fixture has no unavailable catalogue and no malformed card.
        # Explicit negative cases reintroduce those references before review.
        with fixture.connect(self.personal) as db:
            db.execute('delete from Books where DatabaseID=8 or BookID=88')
            db.execute('delete from Bases where DatabaseID=8')
        self.neighbor=self.a/'not-in-catalogue.bin'
        self.neighbor.write_bytes(b'unrelated original must survive')
        self.config.update(register_operation=True,register_groups=True,probe_source_protection=True,
                           probe_verification_locks=True)

    def tearDown(self):
        # Only this test's exact private root; remove an owned temporary readonly
        # guard left by a deliberately killed native process before fixture reaping.
        root=self.home.resolve(strict=True)
        self.assertTrue(root.is_relative_to(fixture.STAGE.resolve(strict=True)))
        for p in root.rglob('*'):
            if p.is_file() and not p.is_symlink():
                attrs=ctypes.windll.kernel32.GetFileAttributesW(str(p))
                if attrs!=0xffffffff and attrs&1:
                    self.assertTrue(ctypes.windll.kernel32.SetFileAttributesW(str(p),attrs&~1 or 128))
        fixture.TransferCatalogueTests.tearDown(self)

    def intents(self):
        with fixture.connect(self.personal) as db:
            if not db.execute("select count(*) from sqlite_master where name='HomeLibreTransferRemovalIntent'").fetchone()[0]:return {}
            db.row_factory=lambda cursor,row:dict(zip((c[0] for c in cursor.description),row))
            return {r['FileID']:r for r in db.execute('select * from HomeLibreTransferRemovalIntent')}

    def run_case(self,expected=0):
        payloads=self.payloads();before=self.pending or self.snapshots()
        process=subprocess.run(self.command(),cwd=self.home,capture_output=True,timeout=120,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)})
        entry=dict(test=self.id(),request=dict(self.config),expected=expected,returncode=process.returncode,
                   output=(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        if self.result.exists():entry['result']=json.loads(self.result.read_text(encoding='utf-8-sig'))
        entry['removal_intents']=self.intents()
        with (fixture.STAGE/'invocations.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(entry,ensure_ascii=False)+'\n')
        after_native=getattr(self,'after_native',None)
        if after_native:self.after_native=None;after_native()
        after=self.payloads()
        removed=set(payloads)-set(after)
        self.assertEqual({p:h for p,h in payloads.items() if p in after},
                         {p:h for p,h in after.items() if p in payloads},'nonremoved original changed')
        added=set(after)-set(payloads)
        if added:
            reviewed={dest:source for source,dest in self.read_review('select Source,Destination from Files')}
            for path in added:
                self.assertIn(path,reviewed,'unreviewed file created under an original root')
                self.assertEqual(after[path],payloads[reviewed[path]])
        if removed:
            self.assertTrue(self.config.get('remove_sources'),'source removed without removal request')
            reviewed={source:(fid,dest) for fid,source,dest in self.read_review('select ID,Source,Destination from Files')}
            intents=self.intents()
            for source in removed:
                self.assertIn(source,reviewed)
                fid,destination=reviewed[source];intent=intents[fid]
                self.assertEqual(intent['Source'],source);self.assertEqual(intent['Destination'],destination)
                self.assertEqual(intent['SHA256'],payloads[source])
                self.assertEqual(fixture.digest(destination),payloads[source])
                self.assertEqual(intent['ProtectionBound'],1)
        self.assertEqual(fixture.digest(self.neighbor),hashlib.sha256(b'unrelated original must survive').hexdigest())
        if expected==97:
            self.assertEqual(process.returncode,97,entry['output']);self.pending=before;type(self).crashes+=1
            return entry
        self.check_metadata(before);self.pending=None
        if expected=='fail':
            self.assertNotEqual(process.returncode,0,entry['output']);self.assertFalse(self.result.exists());return entry['output']
        self.assertEqual(process.returncode,expected,entry['output']);return entry['result']

    def remove(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),register_operation=False,register_groups=False,
                           recover_registered_groups=True,apply_locations=False,remove_sources=True,crash='',cancel_source_stage='')
        self.config.update(options);return self.run_case(expected)

    def assert_targets(self):
        for row in self.intents().values():
            self.assertEqual(fixture.digest(row['Destination']),row['SHA256'])

    def test_live_publication_can_remove_only_verified_originals(self):
        self.config['remove_sources']=True
        result=self.run_case()
        self.assertEqual((result['removed_sources'],result['retained_sources'],result['pending_sources']),(2,0,0),self.intents())
        self.assertTrue(all(r['State']=='removed' for r in self.intents().values()))
        self.assert_targets()

    def test_recovered_group_removal_and_idempotent_foreign_name_reuse(self):
        self.run_case();result=self.remove()
        self.assertEqual((result['removed_sources'],result['copy_streams']),(2,0))
        old=self.a/'same.zip';old.write_bytes(b'foreign replacement at a completed old name')
        foreign=fixture.digest(old)
        result=self.remove();self.assertEqual(result['removed_sources'],2)
        self.assertEqual(fixture.digest(old),foreign);self.assert_targets()

    def test_missing_original_is_acknowledged_without_recopy(self):
        self.run_case();(self.a/'same.zip').unlink()
        result=self.remove()
        self.assertEqual((result['removed_sources'],result['missing_sources'],result['copy_streams']),(1,1,0))

    def test_replaced_original_is_retained(self):
        self.run_case();source=self.a/'same.zip';source.unlink();source.write_bytes(b'foreign archive')
        result=self.remove()
        self.assertEqual((result['removed_sources'],result['retained_sources']),(1,1))
        self.assertEqual(source.read_bytes(),b'foreign archive')

    def test_unknown_catalogue_retains_all_originals(self):
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=8,BaseName='Unavailable',DBFileName='missing.hlc2',RootFolder=str(self.b)))
        self.run_case();before=self.payloads();result=self.remove()
        self.assertEqual((result['removed_sources'],result['retained_sources']),(0,2))
        self.assertEqual(self.payloads(),before)

    def test_cancel_after_protection_restores_original_attributes(self):
        self.run_case();before=self.payloads()
        self.assertIn('останов',self.remove('fail',cancel_source_stage='source-protected'))
        self.assertEqual(self.payloads(),before)
        self.assertFalse(ctypes.windll.kernel32.GetFileAttributesW(str(self.a/'same.zip'))&1)
        self.assertEqual(self.remove()['removed_sources'],2)

    def test_crash_with_protected_source_recovers_original_attributes_and_removes(self):
        self.run_case()
        self.remove(97,crash='file:source-protected')
        self.assertTrue(any(ctypes.windll.kernel32.GetFileAttributesW(r['Source'])&1 for r in self.intents().values()))
        self.assertEqual(self.remove()['removed_sources'],2);self.assert_targets()

    def test_crash_after_unlink_recovers_without_recopy(self):
        self.run_case();self.remove(97,crash='file:source-unlinked')
        result=self.remove()
        self.assertEqual(result['removed_sources']+result['missing_sources'],2)
        self.assertEqual(result['copy_streams'],0);self.assert_targets()

    def test_missing_receipt_prevents_any_removal(self):
        self.run_case();before=self.payloads()
        with fixture.connect(self.catalogue) as db:db.execute('delete from HomeLibreTransferLocations')
        self.assertIn('квитанц',self.remove('fail').lower())
        self.assertEqual(self.payloads(),before);self.assertEqual(self.intents(),{})

    def test_changed_intent_binding_prevents_any_removal(self):
        self.run_case();self.remove(97,crash='removal-intent-committed');before=self.payloads()
        with fixture.connect(self.personal) as db:db.execute("update HomeLibreTransferRemovalIntent set Source=Source||'.foreign'")
        self.assertIn('Намерение удаления изменилось',self.remove('fail'))
        self.assertEqual(self.payloads(),before)

    def test_changed_owner_retains_its_original_picture_dependencies(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        self.run_case();owner=self.a/'legacy.7z';stamp=owner.stat()
        data=bytearray(owner.read_bytes());data[-1]^=1;owner.write_bytes(data)
        os.utime(owner,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
        result=self.remove()
        self.assertGreaterEqual(result['retained_sources'],3)
        rows=self.intents();own_id=next(fid for fid,r in rows.items() if Path(r['Source'])==owner)
        self.assertEqual(rows[own_id]['State'],'retained')
        for p in (self.a/'covers/legacy.zip',self.a/'images/legacy.zip'):
            self.assertTrue(p.is_file());self.assertEqual(next(r['State'] for r in rows.values() if Path(r['Source'])==p),'retained')

    def test_readonly_original_and_named_stream_are_verified_and_removed(self):
        source=self.a/'same.zip';stream=Path(str(source)+':HomeLibreNote')
        stream.write_bytes(b'private alternate stream')
        attrs=ctypes.windll.kernel32.GetFileAttributesW(str(source))
        self.assertTrue(ctypes.windll.kernel32.SetFileAttributesW(str(source),attrs|1))
        self.run_case();result=self.remove()
        self.assertEqual(result['removed_sources'],2)
        row=next(r for r in self.intents().values() if Path(r['Source'])==source)
        self.assertTrue(row['OriginalAttributes']&1)
        self.assertEqual(Path(row['Destination']+':HomeLibreNote').read_bytes(),b'private alternate stream')

    def test_external_reader_can_defer_unlink_without_recopy(self):
        self.run_case();source=self.a/'same.zip'
        api=ctypes.WinDLL('kernel32',use_last_error=True)
        api.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,
                                 ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
        api.CreateFileW.restype=ctypes.c_void_p
        api.CloseHandle.argtypes=[ctypes.c_void_p]
        handle=api.CreateFileW(str(source),0x80000000,7,None,3,128,None)
        self.assertNotEqual(handle,ctypes.c_void_p(-1).value,ctypes.get_last_error())
        def release_reader():
            nonlocal handle
            api.CloseHandle(handle);handle=None
        self.after_native=release_reader
        try:
            result=self.remove()
            self.assertEqual((result['removed_sources'],result['pending_sources']),(1,1))
        finally:
            if handle:api.CloseHandle(handle)
        self.assertFalse(source.exists())
        self.assertEqual(self.remove()['missing_sources'],1)

    def test_intent_and_final_commit_crashes_are_restartable(self):
        for i,point in enumerate(('removal-before-intent-commit','removal-intent-committed',
                                  'removal-before-state-commit','removal-state-committed')):
            with self.subTest(point=point):
                if i:self.tearDown();self.setUp()
                self.run_case();self.remove(97,crash=point)
                result=self.remove()
                self.assertEqual(result['removed_sources']+result['missing_sources'],2)
                self.assertEqual(result['copy_streams'],0);self.assert_targets()

    def test_first_source_already_inside_destination_is_never_removed(self):
        self.config.update(destination=str(self.a),remove_sources=True)
        before=fixture.digest(self.a/'same.zip');result=self.run_case()
        self.assertEqual((result['removed_sources'],result['retained_sources']),(1,1))
        self.assertEqual(fixture.digest(self.a/'same.zip'),before)
        self.assertEqual(next(r['State'] for r in self.intents().values() if r['Source']==r['Destination']),'retained')

    def test_new_source_stream_is_retained_even_with_original_timestamp(self):
        self.run_case();source=self.a/'same.zip';stamp=source.stat()
        note=Path(str(source)+':HomeLibreLateNote');note.write_bytes(b'late alternate data')
        os.utime(source,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
        result=self.remove()
        self.assertEqual((result['removed_sources'],result['retained_sources']),(1,1))
        self.assertEqual(note.read_bytes(),b'late alternate data')
        self.assertFalse(ctypes.windll.kernel32.GetFileAttributesW(str(source))&1)

    def test_cancellation_after_one_unlink_can_finish_remaining_sources(self):
        self.run_case();self.assertIn('останов',self.remove('fail',cancel_source_stage='source-unlinked'))
        result=self.remove()
        self.assertEqual(result['removed_sources']+result['missing_sources'],2)
        self.assertEqual(result['copy_streams'],0)

    def test_repeated_crashes_keep_original_protection_binding(self):
        self.run_case();self.remove(97,crash='file:source-protected')
        first=self.intents();self.remove(97,crash='file:source-protected')
        self.assertEqual({i:r['OriginalAttributes'] for i,r in self.intents().items()},
                         {i:r['OriginalAttributes'] for i,r in first.items()})
        self.assertEqual(self.remove()['removed_sources'],2)


if __name__=='__main__':unittest.main(verbosity=2)

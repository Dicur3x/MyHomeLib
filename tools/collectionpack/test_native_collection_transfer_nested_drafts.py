"""Claimed shared-catalogue snapshots survive stops and reclaim after hard exits."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_drafts as drafts


class NestedDraftTests(drafts.TransferDraftTests):
    def setUp(self):
        super().setUp()
        self.extra_sources = []
        with fixture.connect(self.personal) as db:
            db.execute('UPDATE Bases SET DBFileName=?,RootFolder=? WHERE DatabaseID=8',
                       (str(self.catalogue),str(self.b)))
        self.config['publish_forks'] = False

    def snapshot(self):
        result = super().snapshot()
        result.update({str(p):fixture.digest(p) for p in self.extra_sources})
        return result

    def seed_bulk(self):
        with fixture.connect(self.catalogue) as db:
            db.execute('CREATE TABLE DraftBulk(N INTEGER PRIMARY KEY,P BLOB)')
            db.executemany('INSERT INTO DraftBulk VALUES(?,zeroblob(4096))',((i,) for i in range(2200)))

    def second_shared_catalogue(self):
        third = self.home/'third.hlc2'; folder = self.home/'source-c'; folder.mkdir()
        self.write_zip(folder/'same.zip',b'third source')
        with fixture.connect(self.catalogue) as source, fixture.connect(third) as target:
            source.backup(target)
        with fixture.connect(self.personal) as db:
            for cid,root in ((9,self.b),(10,folder)):
                fixture.insert(db,'Bases',dict(DatabaseID=cid,BaseName='Shared '+str(cid),
                               DBFileName=str(third),RootFolder=str(root)))
        self.extra_sources.extend((third,folder/'same.zip'))

    def test_partial_backup_with_written_pages_is_reclaimed_without_opening_its_database(self):
        self.seed_bulk()
        draft = self.crash('fork-draft-copying',only_partial_snapshot=True,draft_min_bytes=1024*1024)
        events = [json.loads(s.lstrip('\ufeff')) for s in
                  (self.home/'fork-draft-events.jsonl').read_text(encoding='utf-8-sig').splitlines()]
        event = events[-1]
        self.assertTrue(0 < event['done'] < event['total'])
        self.assertGreaterEqual(event['bytes'],1024*1024)
        self.assertEqual(len(list((draft/'catalogue-snapshots').glob('*.hlc2'))),1)
        self.assertFalse([p for p in draft.rglob('*') if p.name.endswith(('-journal','-wal','-shm'))])
        self.assertEqual(self.clean()['drafts_removed'],1)
        self.assertFalse(draft.exists())
        with (fixture.STAGE/'partial-backups.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps(dict(test=self.id(),event=event,reclaimed=True))+'\n')

    def test_two_snapshots_resume_cleanup_after_the_first_snapshot_is_unlinked(self):
        self.second_shared_catalogue()
        draft = self.crash('preparation-after-review')
        folder = draft/'catalogue-snapshots'
        self.assertEqual(len(list(folder.glob('*.hlc2'))),2)
        self.config.update(mode='clean-drafts',crash='draft-snapshot-unlinked')
        self.call(97)
        self.assertEqual(len(list(folder.glob('*.hlc2'))),1)
        self.assertTrue((draft/'lease').exists())
        self.assertEqual(self.clean()['drafts_removed'],1)
        self.assertFalse(draft.exists())
        self.assertEqual(self.clean()['drafts_removed'],0)

    def test_normal_cancellation_reclaims_the_nested_constructor(self):
        self.config.update(mode='create',crash='',cancel_draft_snapshot_stage='fork-draft-ready')
        self.assertIn('EAbort',self.call(1))
        self.assertFalse(list(self.work.glob('collection-transfer-*')))
        self.assertFalse(list(self.work.glob('collection-plan-*')))
        self.assertFalse(list(self.destination.iterdir()))

    def test_ready_nested_review_is_retained_with_all_snapshot_bytes(self):
        self.call()
        draft = self.journal(); before = self.files(draft)
        self.assertEqual(len(list((draft/'catalogue-snapshots').glob('*.hlc2'))),1)
        self.assertEqual(self.clean()['drafts_removed'],0)
        self.assertEqual(self.files(draft),before)

    def test_foreign_nested_files_links_streams_busy_or_replaced_objects_retain_the_whole_draft(self):
        kernel = ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,
                                    ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
        kernel.CreateFileW.restype=ctypes.c_void_p; kernel.CloseHandle.argtypes=[ctypes.c_void_p]
        for kind in ('foreign','journal','directory','replacement','hardlink','stream','busy'):
            with self.subTest(kind=kind):
                draft=self.crash('fork-draft-ready'); folder=draft/'catalogue-snapshots'
                snapshot=next(folder.glob('*.hlc2')); handle=None
                if kind=='foreign': (folder/'unrelated.txt').write_bytes(b'foreign nested file')
                elif kind=='journal': Path(str(snapshot)+'-journal').write_bytes(b'unknown SQLite sidefile')
                elif kind=='directory': (folder/'unrelated').mkdir()
                elif kind=='replacement':
                    snapshot.rename(self.home/('moved-'+draft.name)); snapshot.write_bytes(b'foreign snapshot replacement')
                elif kind=='hardlink': os.link(snapshot,self.home/('link-'+draft.name))
                elif kind=='stream': Path(str(snapshot)+':Foreign').write_bytes(b'foreign stream')
                elif kind=='busy':
                    handle=kernel.CreateFileW(str(snapshot),0x80000000,1,None,3,0x80,None)
                    self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
                before=self.files(draft)
                try:
                    self.assertEqual(self.clean()['drafts_removed'],0)
                    self.assertEqual(self.files(draft),before)
                    if kind=='stream': self.assertEqual(Path(str(snapshot)+':Foreign').read_bytes(),b'foreign stream')
                finally:
                    if handle is not None: kernel.CloseHandle(handle)

    def test_torn_or_escaping_ownership_frames_never_authorize_cleanup(self):
        for kind in ('truncated','hash','escape','duplicate-directory'):
            with self.subTest(kind=kind):
                draft=self.crash('fork-draft-reserved'); lease=draft/'lease'
                if kind=='truncated':
                    with lease.open('ab') as stream: stream.write(b'\x10\x00')
                elif kind=='hash':
                    data=bytearray(lease.read_bytes()); data[-1]^=1; lease.write_bytes(data)
                else:
                    name='catalogue-snapshots/../../unrelated.txt' if kind=='escape' else 'catalogue-snapshots'
                    raw=json.dumps(dict(kind='HomeLibre transfer draft entry v1',name=name,key='0'*25,
                                        directory=kind=='duplicate-directory'),separators=(',',':')).encode()
                    with lease.open('ab') as stream:
                        stream.write(struct.pack('<I',len(raw))+raw+hashlib.sha256(raw).hexdigest().encode())
                before=self.files(draft)
                self.assertEqual(self.clean()['drafts_removed'],0)
                self.assertEqual(self.files(draft),before)

    def test_work_container_metadata_is_preserved_while_its_owned_child_is_reclaimed(self):
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.GetFileAttributesW.argtypes=[ctypes.c_wchar_p]; kernel.GetFileAttributesW.restype=ctypes.c_uint32
        kernel.SetFileAttributesW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32]
        stream=Path(str(self.work)+':UserMetadata'); stream.write_bytes(b'keep container metadata')
        original=kernel.GetFileAttributesW(str(self.work)); self.assertNotEqual(original,0xffffffff)
        self.assertTrue(kernel.SetFileAttributesW(str(self.work),original|1))
        try:
            draft=self.crash('fork-draft-ready')
            self.assertEqual(self.clean()['drafts_removed'],1)
            self.assertFalse(draft.exists())
            self.assertEqual(stream.read_bytes(),b'keep container metadata')
        finally: kernel.SetFileAttributesW(str(self.work),original)

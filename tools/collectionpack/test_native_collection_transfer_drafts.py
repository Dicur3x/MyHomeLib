"""Hard-exit draft ownership, immutable ready protection and conservative cleanup."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal


class TransferDraftTests(journal.TransferJournalTests):
    def call(self, expected=0):
        before = self.snapshot()
        process = subprocess.run(self.command(), cwd=self.home, capture_output=True, timeout=90,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ, 'TEMP':str(self.home), 'TMP':str(self.home)})
        entry = dict(test=self.id(), request=dict(self.config), expected=expected,
                     returncode=process.returncode,
                     output=(process.stdout+process.stderr).decode('utf-8', errors='replace'))
        if self.result.exists():
            entry['result'] = json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (fixture.STAGE/'invocations.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(entry, ensure_ascii=False)+'\n')
        self.assertEqual(self.snapshot(), before, 'draft maintenance changed source data')
        self.assertEqual(process.returncode, expected, entry['output'])
        if expected == 97:
            self.assertIn('CRASH '+self.config['crash'], entry['output'])
            self.assertFalse(self.result.exists())
        elif expected:
            self.assertFalse(self.result.exists())
            return entry['output']
        else:
            self.assertEqual(entry['result']['status'], 'PASS')
            return entry['result']

    def crash(self, stage, **options):
        self.config.update(mode='create', crash=stage, space_preview=False)
        self.config.update(options)
        before = set(self.work.glob('collection-transfer-*'))
        self.call(97)
        created = set(self.work.glob('collection-transfer-*')) - before
        self.assertEqual(len(created), 1)
        return created.pop()

    def clean(self, **options):
        self.config.update(mode='clean-drafts', crash='', cancel_draft_cleanup=False)
        self.config.update(options)
        return self.call()

    @staticmethod
    def files(directory):
        return {str(p):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in directory.rglob('*') if p.is_file()}

    def test_crashes_before_during_and_after_review_reclaim_only_owned_drafts(self):
        for stage in ('preparation-before-review', 'preparation-review-building',
                      'preparation-after-review', 'preparation-before-ready'):
            with self.subTest(stage=stage):
                draft = self.crash(stage)
                self.assertFalse(list(draft.glob('*-journal')))
                self.assertFalse(list(draft.glob('*-wal')))
                self.assertEqual(self.clean()['drafts_removed'], 1)
                self.assertFalse(draft.exists())
                self.assertFalse(list(self.work.glob('collection-plan-*')))
                self.assertFalse(list(self.destination.iterdir()))
                self.assertEqual(self.clean()['drafts_removed'], 0)

    def test_preview_and_next_ordinary_preparation_reap_old_drafts(self):
        draft = self.crash('preparation-ready-durable', space_preview=True)
        self.config.update(mode='create', crash='', space_preview=False, probe_active_draft_cleanup=True)
        result = self.call()
        self.assertEqual(result['status'], 'PASS')
        self.assertFalse(draft.exists())
        ready = self.journal(); before = self.files(ready)
        self.assertEqual(self.clean()['drafts_removed'], 0)
        self.assertEqual(self.files(ready), before)

    def test_durable_ready_and_old_empty_leases_are_never_disposable(self):
        draft = self.crash('preparation-ready-durable')
        before = self.files(draft)
        self.assertEqual(self.clean()['drafts_removed'], 0)
        self.assertEqual(self.files(draft), before)

        (draft/'lease').write_bytes(b'')
        before = self.files(draft)
        self.assertEqual(self.clean()['drafts_removed'], 0)
        self.assertEqual(self.files(draft), before)

    def test_cancelled_cleanup_preserves_the_complete_owned_set(self):
        draft = self.crash('preparation-before-review'); before = self.files(draft)
        self.config.update(mode='clean-drafts', crash='', cancel_draft_cleanup=True)
        self.assertIn('EAbort', self.call(1))
        self.assertEqual(self.files(draft), before)
        self.assertEqual(self.clean()['drafts_removed'], 1)
        self.assertFalse(draft.exists())

    def test_killed_uncommitted_review_with_physical_dirty_pages_is_reclaimed(self):
        with fixture.connect(self.catalogue) as db:
            db.executemany('INSERT INTO Books(BookID,LibID,Title,Folder,FileName,Ext,BookSize,UpdateDate,InsideNo) '
                           'VALUES(?,?,?,?,?,?,?,?,?)',
                           ((1000+i,str(1000+i),'Draft scale '+str(i),'same.zip','101','.fb2',800+i,'',0)
                            for i in range(20000)))
        draft = self.crash('preparation-review-building')
        size = (draft/'review.sqlite').stat().st_size
        self.assertGreaterEqual(size,1024*1024, 'The uncommitted review never spilled dirty pages')
        with (draft/'review.sqlite').open('rb') as review: header = review.read(100)
        self.assertEqual(header[:16],b'SQLite format 3\0')
        self.assertFalse(list(draft.glob('*-journal')))
        self.assertEqual(self.clean()['drafts_removed'], 1)
        self.assertFalse(draft.exists())
        with (fixture.STAGE/'draft-dirty-pages.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps(dict(test=self.id(),books=20003,review_bytes=size,reclaimed=True))+'\n')

    def test_unknown_replaced_linked_stream_busy_and_invalid_claim_keep_entire_draft(self):
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,
                                      ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        for kind in ('file', 'copies-file', 'replacement', 'hardlink', 'stream',
                     'busy', 'claim-tail', 'claim-hash', 'sqlite-sidefile', 'copies-replacement'):
            with self.subTest(kind=kind):
                draft = self.crash('preparation-before-review'); handle = None
                review = draft/'review.sqlite'
                if kind == 'file': (draft/'unrelated.txt').write_bytes(b'foreign')
                elif kind == 'copies-file': (draft/'copies'/'unrelated.txt').write_bytes(b'foreign')
                elif kind == 'replacement':
                    review.rename(self.home/f'moved-{draft.name}')
                    review.write_bytes(b'foreign replacement')
                elif kind == 'hardlink': os.link(review, self.home/f'link-{draft.name}')
                elif kind == 'stream': Path(str(review)+':HomeLibreForeign').write_bytes(b'foreign stream')
                elif kind == 'busy':
                    handle = kernel.CreateFileW(str(review),0x80000000,1,None,3,0x80,None)
                    self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
                elif kind == 'claim-tail':
                    with (draft/'lease').open('ab') as lease: lease.write(b'x')
                elif kind == 'claim-hash':
                    data=bytearray((draft/'lease').read_bytes()); data[-1] ^= 1
                    (draft/'lease').write_bytes(data)
                elif kind == 'sqlite-sidefile': (draft/'review.sqlite-journal').write_bytes(b'unknown journal')
                elif kind == 'copies-replacement':
                    (draft/'copies').rename(self.home/f'copies-{draft.name}')
                    (draft/'copies').mkdir()
                before = self.files(draft)
                try:
                    self.assertEqual(self.clean()['drafts_removed'], 0)
                    self.assertEqual(self.files(draft), before)
                    if kind == 'stream': self.assertEqual(Path(str(review)+':HomeLibreForeign').read_bytes(),b'foreign stream')
                finally:
                    if handle is not None: kernel.CloseHandle(handle)

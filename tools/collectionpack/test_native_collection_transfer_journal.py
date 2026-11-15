"""Frozen review and restartable connected-group preparation on private data."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time
import unittest

import test_native_collection_transfer_catalogue as fixture

BINARY, SQLITE, SEVENZIP, STAGE = fixture.BINARY, fixture.SQLITE, fixture.SEVENZIP, fixture.STAGE


@unittest.skipUnless(os.name == 'nt' and all(p and p.is_file() for p in (BINARY, SQLITE, SEVENZIP)) and STAGE,
                     'requires native group journal, SQLite, 7-Zip and owned stage')
class TransferJournalTests(unittest.TestCase):
    attempts = crashes = 0
    write_zip = staticmethod(fixture.TransferCatalogueTests.write_zip)
    snapshot = fixture.TransferCatalogueTests.snapshot
    make_legacy = fixture.TransferCatalogueTests.make_legacy
    tearDown = fixture.TransferCatalogueTests.tearDown

    def setUp(self):
        fixture.TransferCatalogueTests.setUp(self)
        self.control = self.home/'operation.json'
        self.config.update(mode='create', control=str(self.control), prepare=False)

    def command(self):
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        self.result.unlink(missing_ok=True)
        type(self).attempts += 1
        return [str(self.binary), str(self.request), str(self.result)]

    def run_case(self, expected=0):
        before = self.snapshot()
        process = subprocess.run(self.command(), cwd=self.home, capture_output=True, timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ, 'TEMP':str(self.home), 'TMP':str(self.home)})
        entry = dict(test=self.id(), request=dict(self.config), expected=expected, returncode=process.returncode,
                     output=(process.stdout+process.stderr).decode('utf-8', errors='replace'))
        if self.control.exists():
            entry['control'] = self.anchor()
        if self.result.exists():
            entry['result'] = json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (STAGE/'invocations.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(entry, ensure_ascii=False)+'\n')
        self.assertEqual(self.snapshot(), before, 'group preparation changed original stores or payloads')
        self.assertFalse(list(self.work.glob('collection-plan-*')), 'disposable native plan remained')
        if expected == 'fail':
            self.assertNotEqual(process.returncode, 0, entry['output'])
            self.assertFalse(self.result.exists())
            return entry['output']
        self.assertEqual(process.returncode, expected, entry['output'])
        if expected == 97:
            self.assertIn('CRASH ', entry['output'])
            type(self).crashes += 1
            self.assertFalse(self.result.exists())
            return entry
        self.assertEqual(entry['result']['status'], 'PASS')
        return entry['result']

    def anchor(self):
        return json.loads(self.control.read_text(encoding='utf-8-sig'))

    def journal(self):
        directory = Path(self.anchor()['directory']).resolve()
        self.assertTrue(directory.is_relative_to(self.home.resolve()))
        return directory

    def resume(self, **options):
        self.config.update(mode='resume', crash='', cancel_after_file=False)
        self.config.update(options)
        return self.run_case()

    def read_review(self, sql, params=()):
        db = sqlite3.connect((self.journal()/'review.sqlite').as_uri()+'?mode=ro', uri=True)
        try:
            return db.execute(sql, params).fetchall()
        finally:
            db.close()

    def state_edit(self, sql):
        # All native processes/leases have ended; only the private mutable state.
        db = sqlite3.connect(self.journal()/'state.sqlite')
        try:
            db.execute(sql)
            db.commit()
        finally:
            db.close()

    def connected_images(self):
        archive = self.make_legacy()
        shutil.copy2(archive, self.a/'legacy.zip')
        for subdir in ('covers','images'):
            self.write_zip(self.a/subdir/'legacy.zip', b'whole private picture archive')
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='legacy.7z' where BookID=1")
            db.execute("update Books set Folder='legacy.zip' where BookID=2")
        return archive

    def test_frozen_review_keeps_all_locators_without_copying(self):
        data = self.run_case()
        self.assertEqual((data['files'], data['bindings'], len(data['groups'])), (2, 6, 2))
        self.assertTrue(all(g['state']=='planned' for g in data['groups']))
        self.assertFalse(list(self.destination.iterdir()))
        self.assertEqual(fixture.digest(self.journal()/'review.sqlite'), data['review_sha256'])
        self.assertEqual(self.read_review('select Value from Context where Name=?', ('sources_json',))[0][0], self.sources)
        self.assertEqual(self.read_review('select count(*) from Bindings where State=2'), [(1,)])

    def test_prepare_all_and_resume_without_recopy(self):
        self.config['prepare'] = True
        data = self.run_case()
        self.assertEqual((data['prepared_files'], data['copy_streams']), (2, 2))
        self.assertTrue(all(g['state']=='prepared' for g in data['groups']))
        self.assertGreater(data['pending_group'], 0, 'prepared copies are not a completed move')
        before = {p:(p.stat().st_ino, p.stat().st_mtime_ns, fixture.digest(p)) for p in self.destination.rglob('*') if p.is_file()}
        data = self.resume(prepare=True)
        self.assertEqual(data['copy_streams'], 0)
        self.assertEqual(before, {p:(p.stat().st_ino, p.stat().st_mtime_ns, fixture.digest(p)) for p in self.destination.rglob('*') if p.is_file()})

    def test_shared_sidecars_form_one_connected_group(self):
        self.connected_images()
        data = self.run_case()
        self.assertEqual((data['files'], sorted(g['files'] for g in data['groups'])), (6, [1, 1, 4]))
        rows = self.read_review("select GroupID from Files where Source like '%legacy.%'")
        self.assertEqual(len(rows), 4)
        self.assertEqual(len({row[0] for row in rows}), 1)

    def test_connected_group_is_prepared_as_a_whole(self):
        archive = self.connected_images()
        self.config.update(prepare=True, group_source=str(archive))
        data = self.run_case()
        self.assertEqual((data['prepared_files'], data['copy_streams']), (4, 4))
        self.assertEqual(sum(g['state']=='prepared' for g in data['groups']), 1)
        self.assertEqual(sum(g['state']=='planned' for g in data['groups']), 2)

    def test_process_crashes_resume_at_parent_and_child_boundaries(self):
        for point in ('group-copying','child-created','child-linked','child-prepared','file-receipt-uncommitted','file-receipt','group-prepared',
                      'file:after-publish'):
            with self.subTest(point=point):
                # Each independent operation owns a fresh reviewed destination.
                directory = self.home/('case-'+point.replace(':','-'))
                directory.mkdir()
                work, destination = directory/'work', directory/'destination'
                work.mkdir(); destination.mkdir()
                self.work, self.destination = work, destination
                self.control = directory/'operation.json'
                self.config.update(mode='create',control=str(self.control),work=str(work),destination=str(destination),prepare=True,crash=point)
                self.run_case(97)
                data = self.resume(prepare=True)
                self.assertTrue(all(g['state']=='prepared' for g in data['groups']))
                if point in ('child-prepared','file-receipt-uncommitted','file-receipt','group-prepared','file:after-publish'):
                    self.assertEqual(data['copy_streams'], 1)  # Second group only.
                self.assertEqual(data['prepared_files'], 2)

    def test_missing_archive_arrival_is_detected_after_restart(self):
        self.run_case()
        (self.a/'notdownloaded.7z').write_bytes(b'new arrival')
        self.config.update(mode='resume',prepare=True)
        self.assertIn('отсутствовавший архив', self.run_case('fail'))

    def test_new_zip_cannot_replace_reviewed_7z_choice(self):
        self.make_legacy()
        self.run_case()
        (self.a/'legacy.zip').write_bytes(b'new ZIP alternative')
        self.config.update(mode='resume',prepare=True)
        self.assertIn('отсутствовавший архив', self.run_case('fail'))

    def test_cancelled_group_retains_journal_and_reuses_ready_file(self):
        self.config.update(prepare=True,cancel_after_file=True)
        self.assertIn('остановлена', self.run_case('fail'))
        data = self.resume(prepare=True)
        self.assertEqual((data['prepared_files'], data['copy_streams']), (2, 1))

    def test_wrong_external_digest_cannot_resume(self):
        self.run_case()
        self.config.update(mode='resume',prepare=True,override_review_sha256='0'*64)
        self.assertIn('План переноса', self.run_case('fail'))
        self.assertFalse(list(self.destination.iterdir()))

    def test_changed_review_cannot_grant_new_paths(self):
        self.run_case()
        db = sqlite3.connect(self.journal()/'review.sqlite')
        try:
            db.execute("update Files set Destination=Destination||'.foreign'")
            db.commit()
        finally:
            db.close()
        self.config.update(mode='resume',prepare=True)
        self.assertIn('План переноса', self.run_case('fail'))
        self.assertFalse(list(self.destination.iterdir()))

    def test_foreign_state_replacement_is_preserved(self):
        self.run_case()
        state = self.journal()/'state.sqlite'
        state.rename(self.journal()/'original-state.saved')
        state.write_bytes(b'foreign state replacement')
        self.config.update(mode='resume',prepare=True)
        self.run_case('fail')
        self.assertEqual(state.read_bytes(), b'foreign state replacement')

    def test_untrusted_child_path_cannot_escape_operation(self):
        self.run_case()
        foreign = self.home/'foreign'
        foreign.mkdir(); (foreign/'keep.txt').write_bytes(b'never touch')
        self.state_edit("update FileState set Child='../foreign' where FileID=(select min(FileID) from FileState)")
        self.config.update(mode='resume',prepare=True)
        self.assertIn('ссылка', self.run_case('fail'))
        self.assertEqual((foreign/'keep.txt').read_bytes(), b'never touch')

    def test_ready_receipt_tampering_is_not_accepted(self):
        self.config['prepare'] = True
        self.run_case()
        self.state_edit("update FileState set SHA256='forged' where FileID=(select min(FileID) from FileState)")
        self.config['mode'] = 'resume'
        self.assertIn('Проверочная запись', self.run_case('fail'))

    def test_changed_live_locator_blocks_preparation(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set LibID='different-book' where BookID=1")
        self.config.update(mode='resume',prepare=True)
        self.assertIn('изменились', self.run_case('fail'))

    def test_concurrent_notes_and_progress_are_preserved(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("update Books set Rate=4,Progress=62,Annotation='Новая заметка' where BookID=1 and DatabaseID=7")
        data = self.resume(prepare=True)
        self.assertTrue(all(g['state']=='prepared' for g in data['groups']))
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select Rate,Progress,Annotation from Books where BookID=1 and DatabaseID=7').fetchone(),
                             (4,62,'Новая заметка'))

    def test_foreign_destination_is_retained_after_restart(self):
        self.run_case()
        target = Path(self.read_review('select Destination from Files order by ID limit 1')[0][0])
        target.parent.mkdir(parents=True)
        target.write_bytes(b'foreign destination')
        self.config.update(mode='resume',prepare=True)
        self.run_case('fail')
        self.assertEqual(target.read_bytes(), b'foreign destination')

    def test_journal_has_one_active_owner(self):
        self.run_case()
        release = self.home/'release'
        self.config.update(mode='resume',wait_for_release=str(release))
        command = self.command()
        first = subprocess.Popen(command,cwd=self.home,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.home),'TMP':str(self.home)})
        try:
            deadline = time.monotonic()+15
            while not Path(str(release)+'.waiting').exists():
                self.assertIsNone(first.poll())
                self.assertLess(time.monotonic(),deadline)
                time.sleep(.05)
            self.config.pop('wait_for_release')
            self.run_case('fail')
        finally:
            release.touch()
            stdout,stderr = first.communicate(timeout=20)
        self.assertEqual(first.returncode,0,stdout+stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

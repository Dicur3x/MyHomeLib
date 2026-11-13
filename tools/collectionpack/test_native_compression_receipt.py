"""Catalogue/personal-store replay for compression; synthetic books and DBs only."""
import base64
import copy
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import random
import sqlite3
import struct
import subprocess
from supervised_test_process import run_owned
import tempfile
import unittest
import zlib

from pack_collection import temporary_work_directory

NATIVE = Path(os.environ['HL_NATIVE_COMPRESSION_RECEIPT']) if os.environ.get('HL_NATIVE_COMPRESSION_RECEIPT') else None


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def png(gray, pixels):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + (row if gray else b''.join(bytes([v]) * 3 for v in row))
                    for row in [pixels[i:i + 128] for i in range(0, len(pixels), 128)])
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 128, 128, 8, 0 if gray else 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def book(image):
    return (b'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section>'
            b'<p>Same book text; only its grayscale PNG representation changes.</p></section></body>'
            b'<binary id="picture" content-type="image/png">' + base64.b64encode(image) + b'</binary></FictionBook>')


@unittest.skipUnless(os.name == 'nt' and NATIVE and NATIVE.is_file(), 'Built native receipt worker required')
class NativeCompressionReceiptTests(unittest.TestCase):
    def setUp(self):
        import zipfile
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-compression-receipt-')
        self.root = self.temp.__enter__()
        (self.root / 'fixture-owner.txt').write_text('HomeLibre compression catalogue regression')
        self.catalogue, self.personal = self.root / 'catalog.hlc2', self.root / 'user.dbs2'
        self.source, self.candidate = self.root / 'books.zip', self.root / 'candidate.bin'
        pixels = random.Random(13).randbytes(128 * 128)
        self.original_book, self.new_book = book(png(False, pixels)), book(png(True, pixels))
        self.neighbor = b'Neighbor book content, preserved exactly.' * 100
        for path, selected in [(self.source, self.original_book), (self.candidate, self.new_book)]:
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.comment = b'Keep collection metadata'
                archive.writestr('one.fb2', selected)
                archive.writestr('neighbor.fb2', self.neighbor)
        self.assertLess(self.candidate.stat().st_size, self.source.stat().st_size)
        self.original_hash, self.output_hash = sha(self.source.read_bytes()), sha(self.candidate.read_bytes())
        columns = ('BookID INTEGER,LibID TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,'
                   'BookSize INTEGER,Title TEXT,Annotation BLOB,Review BLOB,Rate INTEGER,Progress INTEGER,KeyWords TEXT')
        self.main_row = (101, 'flibusta:101', 'books.zip', 'one', '.fb2', 0, len(self.original_book),
                         'Название ё', b'Annotation\0\xff', b'Review\0\xfe', 4, 37, 'слова ё')
        with database(self.catalogue) as db:
            db.execute('CREATE TABLE Books(' + columns + ',PRIMARY KEY(BookID))')
            db.execute('INSERT INTO Books VALUES(' + ','.join('?' * len(self.main_row)) + ')', self.main_row)
            neighbor = (102, 'flibusta:102', 'books.zip', 'neighbor', '.fb2', 1, len(self.neighbor),
                        'Сосед', b'Neighbor annotation', b'Neighbor review', 5, 72, 'other')
            db.execute('INSERT INTO Books VALUES(' + ','.join('?' * len(neighbor)) + ')', neighbor)
            db.execute('CREATE TABLE CatalogBookCopies(SourceKey TEXT PRIMARY KEY,BookID INTEGER,Root TEXT,LibID TEXT,'
                       'Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER)')
            db.execute('INSERT INTO CatalogBookCopies VALUES(?,?,?,?,?,?,?,?,?)',
                       ('source#101', 101, str(self.root), 'flibusta:101', 'books.zip', 'one', '.fb2', 0, len(self.original_book)))
            db.execute('CREATE TABLE CatalogSourceBooks(SourceKey TEXT PRIMARY KEY,BookID INTEGER)')
            db.execute("INSERT INTO CatalogSourceBooks VALUES('source#101',101)")
            for name in ['Author_List', 'Series_List', 'Genre_List']:
                db.execute('CREATE TABLE ' + name + '(BookID INTEGER,RelatedID INTEGER)')
                db.executemany('INSERT INTO ' + name + ' VALUES(?,?)', [(101, 7), (102, 9)])
        with database(self.personal) as db:
            db.execute('CREATE TABLE Books(' + columns + ',DatabaseID INTEGER,ExtraInfo BLOB,PRIMARY KEY(BookID,DatabaseID))')
            db.executemany('INSERT INTO Books VALUES(' + ','.join('?' * (len(self.main_row) + 2)) + ')',
                           [(*self.main_row, 7, b'Personal notes\0\xff'), (*self.main_row, 8, b'Other collection\0')])
            db.execute('CREATE TABLE Bases(DatabaseID INTEGER PRIMARY KEY,RootFolder TEXT,DBFileName TEXT)')
            db.execute('INSERT INTO Bases VALUES(?,?,?)', (7, str(self.root), str(self.catalogue)))
            db.execute('CREATE TABLE BookGroups(DatabaseID INTEGER,BookID INTEGER,GroupID INTEGER)')
            db.executemany('INSERT INTO BookGroups VALUES(?,?,?)', [(7, 101, 3), (8, 101, 4)])
            db.execute('CREATE TABLE ReadingHistory(DatabaseID INTEGER,BookID INTEGER,Position INTEGER,Opened TEXT)')
            db.execute("INSERT INTO ReadingHistory VALUES(7,101,37,'2026-11-11 10:20:30')")
        row = dict(kind=0, id=101, lib_id='flibusta:101', folder='books.zip', file_name='one', ext='.fb2',
                   inside_no=0, old_size=len(self.original_book), root='', source_key='', member='one.fb2', required=True)
        personal_row = dict(row, kind=1, required=False)
        copy_row = dict(row, kind=2, root=str(self.root), source_key='source#101')
        self.template = dict(schema=1, kind='HomeLibre book compression', collection_id=7,
                             catalogue=str(self.catalogue), personal=str(self.personal), source=str(self.source),
                             catalogue_key='', personal_key='', source_file_key='', base_root=str(self.root),
                             base_catalogue=str(self.catalogue), source_sha256=self.original_hash,
                             result_sha256=self.output_hash, profile_sha256=sha(b'lossless grayscale PNG'),
                             payloads=[dict(member='one.fb2', input_sha256=sha(self.original_book),
                                            output_sha256=sha(self.new_book), size=len(self.new_book))],
                             rows=[row, personal_row, copy_row])
        self.write_template()

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def write_template(self):
        (self.root / 'receipt-template.json').write_text(json.dumps(self.template, ensure_ascii=False), encoding='utf-8')

    def run_worker(self, mode='apply', fault='-'):
        result = run_owned([str(NATIVE), str(self.root), mode, fault], capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=30)
        if result.returncode not in (0, 73):
            result.stderr += '\nRemaining fixture files: ' + repr([
                (str(p.relative_to(self.root)), p.stat().st_size) for p in self.root.rglob('*') if p.is_file()])
        return result

    def require_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def snapshot(self, path, sizes=True):
        with database(path) as db:
            names = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('HomeLibreBookCompression','HomeLibreCompressedImages','HomeLibreCompressionChecks','HomeLibreCompressionOutcomes') ORDER BY name")]
            result = {}
            for name in names:
                fields = [row[1] for row in db.execute('PRAGMA table_info(' + name + ')')]
                if not sizes: fields = [v for v in fields if v != 'BookSize']
                result[name] = list(db.execute('SELECT ' + ','.join(fields) + ' FROM ' + name + ' ORDER BY rowid'))
            return result

    def require_finished(self, before_catalogue, before_personal):
        import zipfile
        self.assertEqual(self.snapshot(self.catalogue, sizes=False), before_catalogue)
        self.assertEqual(self.snapshot(self.personal, sizes=False), before_personal)
        self.assertEqual(sha(self.source.read_bytes()), self.output_hash)
        with zipfile.ZipFile(self.source) as archive:
            self.assertEqual(archive.read('one.fb2'), self.new_book)
            self.assertEqual(archive.read('neighbor.fb2'), self.neighbor)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0], len(self.new_book))
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=102').fetchone()[0], len(self.neighbor))
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], len(self.new_book))
            self.assertEqual(db.execute('SELECT InputSHA256,OutputSHA256,BookSize FROM HomeLibreBookCompression').fetchall(),
                             [(sha(self.original_book), sha(self.new_book), len(self.new_book))])
        with database(self.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101 AND DatabaseID=7').fetchone()[0], len(self.new_book))
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101 AND DatabaseID=8').fetchone()[0], len(self.original_book))
        self.assertFalse(list((self.root / 'journal').rglob('*')))

    def test_updates_only_sizes_and_preserves_personal_and_related_data(self):
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker())
        self.require_finished(before_c, before_p)

    def inspection_template(self):
        self.template.update(result_sha256=self.original_hash, compression_options=dict(
            version=1, profile='economy', grayscale=False, source_identity='@source', engine_sha256=sha(b'fixture engine')))
        self.template['payloads'][0].update(output_sha256=sha(self.original_book),
                                           size=len(self.original_book), image_outputs=[], retry_original=True)
        self.write_template()

    def test_inspection_records_original_bytes_without_changing_books_or_personal_store(self):
        self.inspection_template()
        before = self.snapshot(self.catalogue)
        personal = sha(self.personal.read_bytes())
        self.require_success(self.run_worker('inspection'))
        self.assertEqual(self.snapshot(self.catalogue), before)
        self.assertEqual(sha(self.personal.read_bytes()), personal)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT InputSHA256,OutputSHA256,BookSize FROM HomeLibreBookCompression').fetchall(),
                             [(sha(self.original_book), sha(self.original_book), len(self.original_book))])
            checks = db.execute('SELECT Member,Profile,Grayscale,PayloadSHA256 FROM HomeLibreCompressionChecks').fetchall()
            self.assertEqual(checks, [('one.fb2', 'economy', 0, sha(self.original_book))])
            self.assertEqual(db.execute('SELECT Member,ProfileSHA256,OutputSHA256,RetryOriginal '
                                        'FROM HomeLibreCompressionOutcomes').fetchall(),
                             [('one.fb2', self.template['profile_sha256'], sha(self.original_book), 1)])
            self.assertEqual(db.execute("SELECT name FROM sqlite_master WHERE name='HomeLibreCompressedImages'").fetchall(), [])
        with database(self.personal) as db:
            self.assertEqual(db.execute("SELECT name FROM sqlite_master WHERE name='HomeLibreCompressionOutcomes'").fetchall(), [])
        self.require_success(self.run_worker('inspection'))
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM HomeLibreCompressionChecks').fetchone()[0], 1)

    def test_inspection_rejects_discarded_output_and_does_not_write_any_store(self):
        self.inspection_template()
        for value in [dict(output_sha256=sha(self.new_book)), dict(image_outputs=[sha(self.new_book)])]:
            saved = copy.deepcopy(self.template)
            self.template['payloads'][0].update(value)
            self.write_template()
            before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.source)}
            self.assertNotEqual(self.run_worker('inspection').returncode, 0)
            self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)
            self.template = saved

    def test_engine_revisions_do_not_accumulate_a_check_per_revision_and_book(self):
        self.inspection_template()
        self.template['compression_options']['profile'] = 'balanced'
        self.write_template()
        self.require_success(self.run_worker('inspection'))
        self.template['compression_options']['profile'] = 'economy'
        for version in range(3):
            engine = sha(('fixture engine ' + str(version)).encode())
            self.template['compression_options']['engine_sha256'] = engine
            self.write_template()
            self.require_success(self.run_worker('inspection'))
            with database(self.catalogue) as db:
                rows = db.execute('SELECT Profile,EngineSHA256 FROM HomeLibreCompressionChecks ORDER BY Profile').fetchall()
                self.assertEqual(rows, [('balanced', sha(b'fixture engine')), ('economy', engine)])
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_incomplete_inspection_removes_only_its_choice_checks_and_can_be_retried(self):
        self.inspection_template()
        personal_before = sha(self.personal.read_bytes())
        for profile in ('balanced', 'economy'):
            self.template['compression_options']['profile'] = profile
            self.write_template()
            self.require_success(self.run_worker('inspection'))
        self.template['payloads'][0]['checked'] = False
        self.write_template()
        self.require_success(self.run_worker('inspection'))
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT Profile FROM HomeLibreCompressionChecks').fetchall(), [('balanced',)])
            self.assertEqual(db.execute('SELECT RetryOriginal FROM HomeLibreCompressionOutcomes').fetchall(), [(1,)])
        self.template['payloads'][0]['checked'] = True
        self.write_template()
        self.require_success(self.run_worker('inspection'))
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT Profile FROM HomeLibreCompressionChecks ORDER BY Profile').fetchall(),
                             [('balanced',), ('economy',)])
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)
        self.assertEqual(sha(self.personal.read_bytes()), personal_before)

    def test_physical_replacement_does_not_cache_an_incomplete_selected_neighbor(self):
        self.template['compression_options'] = dict(version=1, profile='economy', grayscale=False,
            source_identity='@source', engine_sha256=sha(b'fixture engine'))
        self.template['payloads'].append(dict(member='neighbor.fb2', input_sha256=sha(self.neighbor),
            output_sha256=sha(self.neighbor), size=len(self.neighbor), image_outputs=[], retry_original=True, checked=False))
        self.template['rows'].append(dict(self.template['rows'][0], id=102, lib_id='flibusta:102',
            file_name='neighbor', member='neighbor.fb2', inside_no=1, old_size=len(self.neighbor)))
        self.write_template()
        before_c = self.snapshot(self.catalogue, sizes=False)
        before_p = self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker())
        self.assertEqual(sha(self.source.read_bytes()), self.output_hash)
        self.assertEqual(self.snapshot(self.catalogue, sizes=False), before_c)
        self.assertEqual(self.snapshot(self.personal, sizes=False), before_p)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT Member FROM HomeLibreCompressionChecks').fetchall(), [('one.fb2',)])
            self.assertEqual(db.execute('SELECT Member,RetryOriginal FROM HomeLibreCompressionOutcomes').fetchall(),
                             [('neighbor.fb2', 1)])

    def test_inspection_cancel_or_changed_source_has_no_ledger_or_personal_write(self):
        self.inspection_template()
        before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.source)}
        self.assertNotEqual(self.run_worker('inspection-cancel').returncode, 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)
        # Capture the original identity and checksum without writing a store.
        self.require_success(self.run_worker('preflight'))
        self.source.write_bytes(self.source.read_bytes() + b'changed source')
        before[self.source] = sha(self.source.read_bytes())
        self.assertNotEqual(self.run_worker('captured-inspection').returncode, 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_invalid_inspection_choices_are_rejected_without_database_writes(self):
        self.inspection_template()
        original = copy.deepcopy(self.template['compression_options'])
        for field, value in [('version', 2), ('grayscale', 'false'), ('profile', 'unknown'),
                             ('source_identity', 'broken'), ('engine_sha256', 'not-a-digest')]:
            self.template['compression_options'] = dict(original, **{field: value})
            self.write_template()
            before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.source)}
            self.assertNotEqual(self.run_worker('inspection').returncode, 0)
            self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_replacement_advances_only_verified_neighbor_witnesses_and_replaces_selected_profiles(self):
        engine = sha(b'fixture engine')
        self.template['compression_options'] = dict(version=1, profile='economy', grayscale=False, source_identity='@source', engine_sha256=engine)
        self.write_template()
        self.require_success(self.run_worker('preflight'))
        receipt = json.loads((self.root / 'receipt.json').read_text(encoding='utf-8-sig'))
        key = receipt['source_file_key']
        identity = receipt['compression_options']['source_identity']
        with database(self.catalogue) as db:
            db.execute('CREATE TABLE HomeLibreCompressionChecks(FileKey TEXT,Member TEXT,Profile TEXT,Grayscale INTEGER,'
                       'EngineSHA256 TEXT,SourceIdentity TEXT,SourceSHA256 TEXT,PayloadSHA256 TEXT,'
                       'PRIMARY KEY(FileKey,Member,Profile,Grayscale,EngineSHA256)) WITHOUT ROWID')
            db.executemany('INSERT INTO HomeLibreCompressionChecks VALUES(?,?,?,?,?,?,?,?)', [
                (key, 'one.fb2', 'balanced', 0, engine, identity, self.original_hash, sha(self.original_book)),
                (key, 'neighbor.fb2', 'balanced', 0, engine, identity, self.original_hash, sha(self.neighbor)),
                # Same path/stamp is insufficient: this witness belongs to old content.
                (key, 'stale.fb2', 'balanced', 0, engine, identity, 'f' * 64, 'e' * 64),
            ])
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker())
        self.require_finished(before_c, before_p)
        with database(self.catalogue) as db:
            rows = {r[0]: r[1:] for r in db.execute('SELECT Member,Profile,SourceIdentity,SourceSHA256,PayloadSHA256 '
                                                  'FROM HomeLibreCompressionChecks')}
        self.assertEqual(rows['one.fb2'][0], 'economy')
        self.assertEqual(rows['one.fb2'][2:], (self.output_hash, sha(self.new_book)))
        self.assertEqual(rows['neighbor.fb2'][1:3], (rows['one.fb2'][1], self.output_hash))
        self.assertEqual(rows['stale.fb2'][1:3], (identity, 'f' * 64))

    def test_invalid_retry_original_is_rejected_before_any_database_write(self):
        self.inspection_template()
        for invalid in ('true', 1, None, [], {}):
            with self.subTest(value=invalid):
                self.template['payloads'][0]['retry_original'] = invalid
                self.write_template()
                before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.source)}
                self.assertNotEqual(self.run_worker('inspection').returncode, 0)
                self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_invalid_checked_flag_is_rejected_before_any_database_write(self):
        self.inspection_template()
        template = copy.deepcopy(self.template)
        for invalid in ('false', 0, None, [], {}):
            with self.subTest(value=invalid):
                self.template = copy.deepcopy(template)
                self.template['payloads'][0]['checked'] = invalid
                self.write_template()
                before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.source)}
                self.assertNotEqual(self.run_worker('inspection').returncode, 0)
                self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_inspection_does_not_forget_the_original_input_of_a_previously_compressed_book(self):
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker())
        self.template.update(source_sha256=self.output_hash, result_sha256=self.output_hash,
            compression_options=dict(version=1, profile='economy', grayscale=False, source_identity='@source',
                                     engine_sha256=sha(b'fixture engine')))
        self.template['payloads'][0].update(input_sha256=sha(self.new_book), output_sha256=sha(self.new_book),
                                           size=len(self.new_book), image_outputs=[], retry_original=False)
        self.write_template()
        self.require_success(self.run_worker('inspection'))
        self.require_finished(before_c, before_p)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT Member,OutputSHA256,RetryOriginal FROM HomeLibreCompressionOutcomes').fetchall(),
                             [('one.fb2', sha(self.new_book), 0)])

    def test_image_history_commits_and_replays_without_touching_personal_data(self):
        image_hash = sha(self.new_book)
        self.template['payloads'][0]['image_outputs'] = [image_hash, image_hash]
        self.write_template()
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.assertEqual(self.run_worker(fault='catalogue-committed').returncode, 73)
        self.require_success(self.run_worker('recover'))
        self.require_finished(before_c, before_p)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT ProfileSHA256,ImageSHA256 FROM HomeLibreCompressedImages').fetchall(),
                             [(self.template['profile_sha256'], image_hash)])
        with database(self.personal) as db:
            self.assertEqual(db.execute("SELECT name FROM sqlite_master WHERE name='HomeLibreCompressedImages'").fetchall(), [])

    def test_invalid_image_history_is_rejected_before_mutation(self):
        before_c, before_p = self.snapshot(self.catalogue), self.snapshot(self.personal)
        for hashes in ([None], [123], ['g'*64], ['f'*63], ['f'*64]*5001, 'f'*64):
            with self.subTest(hashes=str(hashes)[:70]):
                self.template['payloads'][0]['image_outputs'] = hashes
                self.write_template()
                self.assertNotEqual(self.run_worker('preflight').returncode, 0)
                self.assertEqual(self.snapshot(self.catalogue), before_c)
                self.assertEqual(self.snapshot(self.personal), before_p)
                self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_read_only_preflight_preserves_databases_and_book(self):
        before_c, before_p = self.snapshot(self.catalogue), self.snapshot(self.personal)
        self.require_success(self.run_worker('preflight'))
        self.assertEqual(self.snapshot(self.catalogue), before_c)
        self.assertEqual(self.snapshot(self.personal), before_p)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_real_crash_before_and_between_database_commits_replays(self):
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.assertEqual(self.run_worker(fault='catalogue-committed').returncode, 73)
        with database(self.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], len(self.original_book))
        self.require_success(self.run_worker('recover'))
        self.require_finished(before_c, before_p)

    def test_crash_after_personal_commit_replays_without_new_rows(self):
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.assertEqual(self.run_worker(fault='personal-committed').returncode, 73)
        self.require_success(self.run_worker('recover'))
        self.require_finished(before_c, before_p)

    def test_wal_database_commits_replay(self):
        for path in [self.catalogue, self.personal]:
            with database(path) as db: self.assertEqual(db.execute('PRAGMA journal_mode=WAL').fetchone()[0], 'wal')
        self.test_real_crash_before_and_between_database_commits_replays()

    def test_changed_record_after_capture_stops_before_file_write(self):
        self.require_success(self.run_worker('preflight'))
        with database(self.catalogue) as db: db.execute("UPDATE Books SET LibID='different' WHERE BookID=101")
        before_c, before_p = self.snapshot(self.catalogue), self.snapshot(self.personal)
        self.assertNotEqual(self.run_worker('captured-apply').returncode, 0)
        self.assertEqual(self.snapshot(self.catalogue), before_c)
        self.assertEqual(self.snapshot(self.personal), before_p)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_changed_collection_root_stops_before_file_write(self):
        self.require_success(self.run_worker('preflight'))
        with database(self.personal) as db: db.execute("UPDATE Bases SET RootFolder='elsewhere'")
        self.assertNotEqual(self.run_worker('captured-apply').returncode, 0)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_missing_database_is_not_created(self):
        self.require_success(self.run_worker('preflight'))
        self.catalogue.rename(self.root / 'moved.hlc2')
        self.assertNotEqual(self.run_worker('captured-apply').returncode, 0)
        self.assertFalse(self.catalogue.exists())
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_replaced_database_with_identical_rows_is_rejected(self):
        self.require_success(self.run_worker('preflight'))
        with database(self.catalogue) as source, database(self.root / 'copy.hlc2') as destination: source.backup(destination)
        self.catalogue.rename(self.root / 'old.hlc2')
        (self.root / 'copy.hlc2').rename(self.catalogue)
        self.assertNotEqual(self.run_worker('captured-apply').returncode, 0)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_changed_receipt_cannot_update_databases(self):
        before_c, before_p = self.snapshot(self.catalogue), self.snapshot(self.personal)
        self.assertEqual(self.run_worker(fault='file-committed').returncode, 73)
        receipt_path = self.root / 'receipt.json'
        correct = receipt_path.read_bytes()
        data = json.loads(correct.decode('utf-8-sig'))
        data['result_sha256'] = 'f' * 64
        receipt_path.write_text(json.dumps(data), encoding='utf-8')
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(self.snapshot(self.catalogue), before_c)
        self.assertEqual(self.snapshot(self.personal), before_p)
        receipt_path.write_bytes(correct)
        self.require_success(self.run_worker('recover'))

    def test_personal_write_failure_rolls_back_catalogue_phase(self):
        before_c, before_p = self.snapshot(self.catalogue), self.snapshot(self.personal)
        self.assertEqual(self.run_worker(fault='file-committed').returncode, 73)
        with database(self.personal) as db:
            db.execute("CREATE TRIGGER RejectSize BEFORE UPDATE OF BookSize ON Books BEGIN SELECT RAISE(ABORT,'fixture write failure'); END")
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(self.snapshot(self.catalogue), before_c)
        self.assertEqual(self.snapshot(self.personal), before_p)
        with database(self.personal) as db: db.execute('DROP TRIGGER RejectSize')
        self.require_success(self.run_worker('recover'))

    def test_unrelated_historical_personal_card_is_preserved(self):
        with database(self.personal) as db:
            db.execute("UPDATE Books SET Folder='historical.zip',BookSize=999 WHERE DatabaseID=7")
        before = self.snapshot(self.personal)
        self.require_success(self.run_worker())
        self.assertEqual(self.snapshot(self.personal), before)

    def test_duplicate_target_is_rejected_before_mutation(self):
        self.template['rows'].append(copy.deepcopy(self.template['rows'][0]))
        self.write_template()
        self.assertNotEqual(self.run_worker().returncode, 0)
        self.assertEqual(sha(self.source.read_bytes()), self.original_hash)

    def test_personal_card_added_after_capture_keeps_its_new_notes(self):
        with database(self.personal) as db: db.execute('DELETE FROM Books WHERE DatabaseID=7')
        self.require_success(self.run_worker('preflight'))
        with database(self.personal) as db:
            row = (*self.main_row, 7, b'New notes added while compression was preparing')
            db.execute('INSERT INTO Books VALUES(' + ','.join('?' * len(row)) + ')', row)
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker('captured-apply'))
        self.require_finished(before_c, before_p)

    def test_many_catalogue_rows_for_the_same_book_are_all_updated(self):
        with database(self.catalogue) as db:
            for identity in range(1000, 2000):
                row = (identity, *self.main_row[1:])
                db.execute('INSERT INTO Books VALUES(' + ','.join('?' * len(row)) + ')', row)
                self.template['rows'].append(dict(self.template['rows'][0], id=identity))
        self.write_template()
        before_c, before_p = self.snapshot(self.catalogue, sizes=False), self.snapshot(self.personal, sizes=False)
        self.require_success(self.run_worker())
        self.require_finished(before_c, before_p)
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM Books WHERE BookSize=?', (len(self.new_book),)).fetchone()[0], 1001)


if __name__ == '__main__': unittest.main()

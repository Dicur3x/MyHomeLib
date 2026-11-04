"""Real 7-Zip integration; synthetic books only, all inputs remain untouched."""
import base64
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import random
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import zipfile
import zlib
from xml.etree import ElementTree

from pack_collection import API_VERSION, Canceled, Packer, PackingError

SEVEN = Path(os.environ.get('HLRU_PACK_7ZIP', '../../Program/Out/Bin64/tools/7zip/7za.exe')).absolute()
IMAGE_TOOLS = os.environ.get('HLRU_PACK_IMAGE_TOOLS')


def image_fixture():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    width, height = 480, 640
    rng = random.Random(534)
    pixels = b''.join(b'\0' + rng.randbytes(width * 3) for _ in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextmanager
def database(path):
    db = sqlite3.connect(path)
    try:
        with db:
            yield db
    finally:
        db.close()


class PackingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-packing-test-')
        self.root = Path(self.temporary.name)
        self.source = self.root / 'inputs'; self.source.mkdir()
        self.output = self.root / 'copy'
        self.plan = self.root / 'plan.sqlite'
        with database(self.plan) as db:
            db.executescript('''CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
                CREATE TABLE books(book_id INTEGER PRIMARY KEY,source TEXT,member TEXT,locator TEXT,filename TEXT,ext TEXT,inside_no INTEGER);
                CREATE INDEX source_books ON books(source);''')
            db.execute('INSERT INTO metadata VALUES(?,?)', ('api', str(API_VERSION)))
            db.execute('INSERT INTO metadata VALUES(?,?)', ('dataset', 'synthetic-collection'))
        self.job = dict(version=API_VERSION, dataset='synthetic-collection', engine='reversible-ppmd',
                        plan=str(self.plan), output=str(self.output), seven_zip=str(SEVEN))

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, name, entries):
        path = self.source / name
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for member, body in entries.items():
                archive.writestr(member, body)
        return path

    def add(self, identity, source, member, extension=None):
        extension = extension or Path(member or source.name).suffix
        with database(self.plan) as db:
            db.execute('INSERT OR REPLACE INTO books VALUES(?,?,?,?,?,?,?)',
                       (identity, str(source), member, member or source.name,
                        str(Path(member or source.name).with_suffix('')), extension, 0))

    def packed_book(self, result, identity):
        locations = self.output / 'generations' / result.generation / 'locations.sqlite'
        with database(locations) as db:
            row = db.execute('SELECT folder,filename,ext,inside_no FROM locations WHERE book_id=?', (identity,)).fetchone()
        path = self.output / row[0]
        if path.is_dir():
            return (path / (row[1] + row[2])).read_bytes()
        result = subprocess.run([str(SEVEN), 'x', '-so', '-spd', str(path), row[1] + row[2]],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        return result.stdout

    def retain(self, result, identities):
        with database(self.output / 'generations' / result.generation / 'locations.sqlite') as locations:
            rows = [locations.execute('SELECT * FROM locations WHERE book_id=?', (identity,)).fetchone() for identity in identities]
        with database(self.plan) as plan:
            plan.execute('CREATE TABLE IF NOT EXISTS retained(book_id INTEGER PRIMARY KEY,folder TEXT,filename TEXT,ext TEXT,inside_no INTEGER)')
            plan.executemany('INSERT OR REPLACE INTO retained VALUES(?,?,?,?,?)', rows)
            plan.executemany('DELETE FROM books WHERE book_id=?', [(identity,) for identity in identities])

    def test_incremental_download_in_copy_requires_opt_in_and_cannot_read_managed_payload_as_source(self):
        source = self.source / 'original.txt'
        source.write_bytes(b'Original')
        self.add(1, source, '')
        original = Packer(self.job).execute()
        self.retain(original, [1])

        download = self.output / 'Author' / 'New book.txt'
        download.parent.mkdir()
        download.write_bytes(b'Downloaded book')
        self.add(2, download, '')
        with self.assertRaises(PackingError):
            Packer(self.job).execute()
        self.job['allow_copy_inputs'] = True
        result = Packer(self.job).execute()
        self.assertEqual((result.books, result.reused), (2, 1))
        self.assertEqual(self.packed_book(result, 2), download.read_bytes())
        self.assertEqual(download.read_bytes(), b'Downloaded book')

        managed = next(self.output.glob('archives/*/*/books.zip'))
        self.add(2, managed, 'book.txt')
        with self.assertRaises(PackingError):
            Packer(self.job).execute()
        self.assertEqual(self.packed_book(result, 1), b'Original')

    def test_retained_registered_generation_survives_newer_unapplied_cache_and_missing_original(self):
        source = self.source / 'book.txt'; source.write_bytes(b'Original edition ' * 4000)
        self.add(1, source, '')
        old = Packer(self.job).execute()
        old_files = {p: sha(p) for p in self.output.glob('archives/**/*') if p.is_file()}
        source.write_bytes(b'New unapplied edition ' * 5000)
        unapplied = Packer(self.job).execute()
        self.assertEqual(self.packed_book(unapplied, 1), b'New unapplied edition ' * 5000)
        self.retain(old, [1]); source.unlink()
        new = self.source / 'new.txt'; new.write_bytes(b'New monthly book ' * 6000); self.add(2, new, '')
        events = []; result = Packer(self.job, events.append).execute()
        self.assertEqual((result.books, result.sources, result.reused), (2, 2, 1))
        self.assertEqual(self.packed_book(result, 1), b'Original edition ' * 4000)
        self.assertEqual(self.packed_book(result, 2), b'New monthly book ' * 6000)
        self.assertTrue(any(e['stage'] == 'retained' for e in events))
        for file, digest in old_files.items(): self.assertEqual(sha(file), digest)
        with database(self.output / 'packing.sqlite') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM payloads').fetchone()[0], 3)

    def test_retained_flibrary_companions_are_verified_without_originals(self):
        source = self.archive('library.7z', {'9.fb2': b'<FictionBook>External images</FictionBook>'})
        (source.parent / 'images').mkdir(); pictures = source.parent / 'images' / 'library.zip'
        with zipfile.ZipFile(pictures, 'w') as archive: archive.writestr('9/1', b'original illustration')
        self.add(9, source, '9.fb2')
        old = Packer(self.job).execute(); self.retain(old, [9]); source.unlink(); pictures.unlink()
        self.assertEqual(Packer(self.job).execute().reused, 1)
        packed_pictures = next(self.output.glob('archives/*/*/images/library.zip'))
        packed_pictures.write_bytes(b'damaged')
        generations = set(self.output.glob('generations/*/prepared.json'))
        with self.assertRaisesRegex(PackingError, 'иллюстрации'):
            Packer(self.job).execute()
        self.assertEqual(set(self.output.glob('generations/*/prepared.json')), generations)

    def test_fbd_and_regular_rows_can_share_one_unchanged_container(self):
        book = b'%PDF-1.0\nSource document'
        metadata = '<FictionBook><description>Описание ё</description></FictionBook>'.encode()
        source = self.archive('Пара.zip', {'chapter.pdf': book, 'chapter.fbd': metadata})
        original_hash = sha(source)
        self.add(1, source, 'chapter.pdf')
        self.add(2, source, 'chapter.pdf')
        with database(self.plan) as db:
            db.execute('ALTER TABLE books ADD COLUMN fbd INTEGER NOT NULL DEFAULT 0')
            db.execute('UPDATE books SET filename=?,locator=?,fbd=1 WHERE book_id=1',
                       (source.name, 'fbd:0:chapter.pdf'))
        result = Packer(self.job).execute()
        self.assertEqual((result.sources, result.books, result.opaque_sources), (1, 2, 1))
        with database(self.output / 'generations' / result.generation / 'locations.sqlite') as db:
            rows = db.execute('SELECT * FROM locations ORDER BY book_id').fetchall()
        self.assertEqual(rows[0][2:], (source.name, '.pdf', 0))
        self.assertTrue(rows[0][1].endswith(os.sep))
        payload = rows[0][1] + rows[0][2]
        self.assertEqual(rows[1][1], payload)
        self.assertEqual(sha(self.output / payload), original_hash)
        with zipfile.ZipFile(self.output / payload) as archive:
            self.assertEqual(archive.read('chapter.fbd'), metadata)
            self.assertEqual(archive.read('chapter.pdf'), book)
        with database(self.plan) as db:
            db.execute('DELETE FROM books')
            db.execute('CREATE TABLE retained(book_id INTEGER PRIMARY KEY,folder TEXT NOT NULL,filename TEXT NOT NULL,'
                       'ext TEXT NOT NULL,inside_no INTEGER NOT NULL,payload TEXT NOT NULL)')
            db.executemany('INSERT INTO retained VALUES(?,?,?,?,?,?)', [(*row, payload) for row in rows])
        source.unlink()
        retained = Packer(self.job).execute()
        self.assertEqual((retained.sources, retained.books, retained.reused), (1, 2, 1))
        self.assertEqual(retained.output_bytes, result.output_bytes)
        with database(self.output / 'generations' / retained.generation / 'locations.sqlite') as db:
            self.assertEqual(db.execute('SELECT * FROM locations ORDER BY book_id').fetchall(), rows)
        with database(self.plan) as db:
            db.execute('UPDATE retained SET folder=? WHERE book_id=1', (payload,))
        with self.assertRaisesRegex(PackingError, 'Расположение книги не совпадает'):
            Packer(self.job).execute()

    def test_retained_unknown_member_and_overlapping_plan_ids_are_rejected(self):
        source = self.source / 'book.txt'; source.write_bytes(b'Book ' * 5000); self.add(1, source, '')
        old = Packer(self.job).execute(); self.retain(old, [1])
        with database(self.plan) as plan: plan.execute("UPDATE retained SET filename='another-book'")
        with self.assertRaisesRegex(PackingError, 'Расположение'):
            Packer(self.job).execute()
        self.retain(old, [1]); self.add(1, source, '')
        with self.assertRaisesRegex(PackingError, 'одновременно'):
            Packer(self.job).execute()
        self.assertEqual(self.packed_book(old, 1), b'Book ' * 5000)

    def test_missing_payload_after_write_ahead_does_not_reuse_its_immutable_path(self):
        source = self.source / 'book.txt'; source.write_bytes(b'Book ' * 5000); self.add(1, source, '')
        Packer(self.job).open()
        with patch('pack_collection.os.rename', side_effect=OSError('Controlled failure before payload rename')):
            with self.assertRaises(OSError): Packer(self.job).execute()
        with database(self.output / 'packing.sqlite') as db:
            old_folder = db.execute('SELECT folder FROM payloads').fetchone()[0]
        result = Packer(self.job).execute()
        with database(self.output / 'packing.sqlite') as db:
            new_folder = db.execute('SELECT folder FROM sources').fetchone()[0]
            self.assertEqual(db.execute('SELECT count(*) FROM payloads').fetchone()[0], 2)
        self.assertNotEqual(old_folder, new_folder)
        self.assertFalse((self.output / old_folder).exists())
        self.assertEqual(self.packed_book(result, 1), b'Book ' * 5000)

    def test_current_legacy_cache_migrates_to_immutable_ledger(self):
        source = self.source / 'book.txt'; source.write_bytes(b'Book ' * 5000); self.add(1, source, '')
        old = Packer(self.job).execute()
        with database(self.output / 'packing.sqlite') as db: db.execute('DROP TABLE payloads')
        result = Packer(self.job).execute()
        self.assertEqual(result.reused, 1)
        self.retain(old, [1]); source.unlink()
        self.assertEqual(Packer(self.job).execute().reused, 1)

    def test_mixed_books_keep_exact_bytes_and_originals(self):
        text = ('<FictionBook><body><section><p>Читаемая книга, ё, ї, 中文.</p></section></body></FictionBook>' * 300).encode()
        epub = b'PK\x03\x04' + os.urandom(20000)
        pdf = b'%PDF-1.7\n' + os.urandom(16000)
        djvu = b'AT&TFORM\x00\x00\x00\x18DJVU' + os.urandom(12000)
        paths = []
        for identity, (extension, body) in enumerate([('.fb2', text), ('.epub', epub), ('.pdf', pdf), ('.djvu', djvu)], 1):
            file = self.source / ('same' + extension); file.write_bytes(body)
            self.add(identity, file, '', extension); paths.append((file, sha(file), body))
        events = []
        result = Packer(self.job, events.append).execute()
        self.assertEqual(result.books, 4)
        for identity, (path, digest, body) in enumerate(paths, 1):
            self.assertEqual(sha(path), digest)
            self.assertEqual(self.packed_book(result, identity), body)
        self.assertEqual(events[-1]['stage'], 'prepared')
        self.assertFalse((self.output / 'current.json').exists(), 'Backend must not publish an unvalidated catalogue')
        self.assertFalse(list(self.output.glob('.packing-*')))

    def test_resume_reuses_done_sources_and_updates_changed_and_new(self):
        first = self.archive('first.zip', {'1.fb2': b'first ' * 2000})
        second = self.archive('second.zip', {'2.txt': b'second ' * 2000})
        self.add(1, first, '1.fb2'); self.add(2, second, '2.txt')
        before = {p: sha(p) for p in (first, second)}
        one = Packer(self.job).execute()
        two = Packer(self.job).execute()
        self.assertEqual(two.reused, 2)
        self.archive('second.zip', {'2.txt': b'changed text ' * 2000})
        third = self.archive('new.zip', {'3.pdf': b'%PDF-' + os.urandom(3000)})
        self.add(3, third, '3.pdf')
        three = Packer(self.job).execute()
        self.assertEqual(three.reused, 1)
        self.assertEqual(self.packed_book(one, 2), b'second ' * 2000, 'Old generation must remain readable')
        self.assertEqual(self.packed_book(three, 2), b'changed text ' * 2000)
        self.assertEqual(sha(first), before[first])
        self.assertNotEqual(sha(second), before[second])
        # Removing a catalogue record never removes the original book/archive.
        with database(self.plan) as db: db.execute('DELETE FROM books WHERE book_id=2')
        four = Packer(self.job).execute()
        self.assertEqual(four.books, 2)
        self.assertTrue(second.exists())

    def test_progress_counts_completed_payloads_and_resume(self):
        first = self.archive('first.zip', {f'{i}.fb2': (str(i) * 20000).encode() for i in range(1, 5)})
        second = self.source / 'scan.pdf'; second.write_bytes(b'%PDF-' + os.urandom(2000))
        for identity in range(1, 5): self.add(identity, first, f'{identity}.fb2')
        self.add(5, second, '')
        for resumed in (False, True):
            events = []
            result = Packer(self.job, events.append).execute()
            self.assertEqual(result.books, 5)
            self.assertEqual(events[-1]['stage'], 'prepared')
            for event in events:
                self.assertEqual(event['sources_total'], 2)
                self.assertEqual(event['books_total'], 5)
                self.assertGreaterEqual(event['elapsed_seconds'], 0)
            for field in ('sources_done', 'books_done', 'input_bytes', 'output_bytes', 'elapsed_seconds'):
                values = [event[field] for event in events]
                self.assertEqual(values, sorted(values), field)
            final = events[-1]
            self.assertEqual((final['sources_done'], final['books_done']), (2, 5))
            self.assertEqual((final['input_bytes'], final['output_bytes']), (result.input_bytes, result.output_bytes))
            self.assertEqual(final['reused'], 2 if resumed else 0)
            if resumed: self.assertFalse(any(e['stage'] == 'compressing' for e in events))

    def test_progress_is_throttled_with_final_update_and_long_operation_heartbeat(self):
        events, state = [], {'cancel': False}
        packer = Packer(self.job, events.append, lambda: state['cancel'])
        clock = [100.0]
        with patch('pack_collection.time.monotonic', side_effect=lambda: clock[0]):
            packer.started = clock[0]
            packer.event('books', source='books.zip', current=1, total=100)
            for current in range(2, 100):
                clock[0] += .001
                packer.event('books', source='books.zip', current=current, total=100)
            self.assertEqual(len(events), 1, 'Fast books must not flood the native output pipe')
            packer.event('books', source='books.zip', current=100, total=100)
            self.assertEqual(events[-1]['current'], 100)
            packer.event('compressing', source='books.zip')
            clock[0] += 2
            packer.check()
            self.assertEqual(events[-1]['stage'], 'compressing')
            self.assertGreaterEqual(events[-1]['elapsed_seconds'], 2)
            self.assertNotIn('current', events[-1], 'Compression must not invent a percent')
            count = len(events); state['cancel'] = True; clock[0] += 2
            with self.assertRaises(Canceled): packer.check()
            self.assertEqual(len(events), count, 'Cancellation takes priority over heartbeat')

    def test_cancel_keeps_completed_sources_resumable(self):
        for identity in (1, 2):
            path = self.archive(f'{identity}.zip', {f'{identity}.fb2': (str(identity) * 30000).encode()})
            self.add(identity, path, f'{identity}.fb2')
        state = {'cancel': False}
        def notify(event):
            if event['stage'] == 'source' and event['current'] == 1:
                state['cancel'] = True
        with self.assertRaises(Canceled):
            Packer(self.job, notify, lambda: state['cancel']).execute()
        self.assertFalse((self.output / 'current.json').exists())
        state['cancel'] = False
        result = Packer(self.job).execute()
        self.assertEqual(result.reused, 1)
        self.assertEqual(result.books, 2)
        self.assertFalse(list(self.output.glob('.packing-*')))

    def test_existing_flibrary_companions_remain_byte_exact(self):
        source = self.archive('library.7z', {'9.fb2': b'<FictionBook>no pictures inline</FictionBook>'})
        (source.parent / 'covers').mkdir(); (source.parent / 'images').mkdir()
        companions = []
        for kind in ('covers', 'images'):
            path = source.parent / kind / 'library.zip'
            with zipfile.ZipFile(path, 'w') as archive: archive.writestr('9', b'picture-' + kind.encode())
            companions.append((path, sha(path)))
        self.add(9, source, '9.fb2')
        result = Packer(self.job).execute()
        self.assertEqual(result.opaque_sources, 1)
        with database(self.output / 'generations' / result.generation / 'locations.sqlite') as db:
            path = self.output / db.execute('SELECT folder FROM locations').fetchone()[0]
        self.assertEqual(sha(path), sha(source))
        for original, digest in companions:
            self.assertEqual(sha(path.parent / original.parent.name / original.name), digest)
            self.assertEqual(sha(original), digest)

    def test_foreign_destination_and_mismatched_profile_are_rejected(self):
        self.output.mkdir(); (self.output / 'foreign.txt').write_text('Keep me')
        with self.assertRaises(PackingError): Packer(self.job).execute()
        self.assertEqual((self.output / 'foreign.txt').read_text(), 'Keep me')
        other = self.root / 'other'; self.job['output'] = str(other)
        source = self.source / 'book.txt'; source.write_bytes(b'text ' * 5000)
        self.add(1, source, '')
        Packer(self.job).execute()
        self.job['dataset'] = 'different'
        with self.assertRaises(PackingError): Packer(self.job).execute()

    def test_missing_member_never_creates_a_prepared_generation(self):
        source = self.archive('books.zip', {'1.fb2': b'<FictionBook/>'})
        self.add(1, source, 'absent.fb2')
        with self.assertRaises(PackingError): Packer(self.job).execute()
        self.assertFalse(list(self.output.glob('generations/*/prepared.json')))
        self.assertFalse(list(self.output.glob('generations/*')))
        with zipfile.ZipFile(source) as archive: self.assertEqual(archive.namelist(), ['1.fb2'])

    def test_same_numeric_names_from_different_sources_do_not_merge(self):
        (self.source / 'other').mkdir()
        one = self.archive('one.zip', {'9.fb2': b'First library ' * 3000})
        two = self.source / 'other' / 'one.zip'
        with zipfile.ZipFile(two, 'w') as archive: archive.writestr('9.fb2', b'Second library ' * 3000)
        self.add(1, one, '9.fb2'); self.add(2, two, '9.fb2')
        result = Packer(self.job).execute()
        self.assertEqual(self.packed_book(result, 1), b'First library ' * 3000)
        self.assertEqual(self.packed_book(result, 2), b'Second library ' * 3000)

    def test_new_locator_in_unchanged_archive_is_not_lost_in_cache(self):
        source = self.archive('books.zip', {'1.fb2': b'First ' * 3000, '2.fb2': b'Second ' * 3000})
        self.add(1, source, '1.fb2')
        old = Packer(self.job).execute()
        self.add(2, source, '2.fb2')
        new = Packer(self.job).execute()
        self.assertEqual(new.reused, 0)
        self.assertEqual(self.packed_book(new, 2), b'Second ' * 3000)
        self.assertEqual(self.packed_book(old, 1), b'First ' * 3000)

    def test_archive_changed_during_run_is_not_prepared(self):
        source = self.archive('books.zip', {'1.fb2': b'First ' * 3000})
        self.add(1, source, '1.fb2')
        def notify(event):
            if event['stage'] == 'compressing':
                self.archive('books.zip', {'1.fb2': b'Changed ' * 3000})
        with self.assertRaisesRegex(PackingError, 'изменился'):
            Packer(self.job, notify).execute()
        self.assertFalse(list(self.output.glob('generations/*')))

    def test_already_compressed_archive_does_not_grow(self):
        body = b'%PDF-' + os.urandom(32000)
        source = self.archive('pdf.zip', {'1.pdf': body})
        self.add(1, source, '1.pdf')
        result = Packer(self.job).execute()
        self.assertLessEqual(result.output_bytes, source.stat().st_size)
        self.assertEqual(self.packed_book(result, 1), body)

    def test_same_destination_cannot_be_packed_concurrently(self):
        source = self.source / 'book.txt'; source.write_bytes(b'First ' * 3000)
        self.add(1, source, '')
        holder = Packer(self.job); holder.open()
        with holder.lock():
            with self.assertRaisesRegex(PackingError, 'другим процессом'):
                Packer(self.job).execute()

    def test_valid_zip_with_wrong_book_payload_is_rejected(self):
        source = self.source / 'book.txt'; source.write_bytes(b'First ' * 3000)
        self.add(1, source, '')
        packer = Packer(self.job)
        def wrong_pack(stage, target, text, stored):
            with zipfile.ZipFile(target, 'w') as archive:
                for name in text + stored: archive.writestr(name, b'Wrong book content')
        packer.seven.pack = wrong_pack
        with self.assertRaisesRegex(PackingError, 'отличается'):
            packer.execute()
        self.assertFalse(list(self.output.glob('generations/*')))

    def test_matching_size_and_crc_do_not_hide_different_packed_bytes(self):
        original = bytes.fromhex('7e85583cd7753c326993a2a8')
        other = bytes.fromhex('c7ee3e28b3f6fdf1772bdc24')
        self.assertEqual((len(original), zlib.crc32(original)), (len(other), zlib.crc32(other)))
        self.assertNotEqual(hashlib.sha256(original).digest(), hashlib.sha256(other).digest())
        source = self.source / 'book.txt'
        source.write_bytes(original)
        self.add(1, source, '')
        packer = Packer(self.job)

        def wrong_pack(stage, target, text, stored):
            with zipfile.ZipFile(target, 'w') as archive:
                archive.writestr(text[0], other)

        packer.seven.pack = wrong_pack
        with self.assertRaisesRegex(PackingError, 'отличается'):
            packer.execute()
        self.assertFalse(list(self.output.glob('generations/*')))
        self.assertEqual(source.read_bytes(), original)

    def test_corrupted_companion_copy_is_not_published(self):
        source = self.archive('library.7z', {'9.fb2': b'<FictionBook>External images</FictionBook>'})
        (self.source / 'images').mkdir()
        companion = self.source / 'images' / 'library.zip'
        companion.write_bytes(b'original image container')
        self.add(9, source, '9.fb2')
        from pack_collection import copy_exact

        def corrupt_companion(input_file, target, check):
            copied_hash = copy_exact(input_file, target, check)
            if input_file == companion:
                target.write_bytes(b'corrupt! image container')
            return copied_hash

        with patch('pack_collection.copy_exact', side_effect=corrupt_companion):
            with self.assertRaisesRegex(PackingError, 'не совпала'):
                Packer(self.job).execute()
        self.assertFalse(list(self.output.glob('generations/*')))
        self.assertEqual(companion.read_bytes(), b'original image container')

    def test_mixed_members_use_ppmd_only_for_text(self):
        source = self.source / 'mixed.zip'
        body = b'%PDF-' + os.urandom(16000)
        with zipfile.ZipFile(source, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('1.fb2', b'<FictionBook><body>Readable text.</body></FictionBook>' * 1000)
            archive.writestr('2.pdf', body)
        self.add(1, source, '1.fb2'); self.add(2, source, '2.pdf')
        result = Packer(self.job).execute()
        with database(self.output / 'generations' / result.generation / 'locations.sqlite') as db:
            rows = db.execute('SELECT folder,filename,ext FROM locations ORDER BY book_id').fetchall()
        self.assertEqual(rows[0][0], rows[1][0])
        with zipfile.ZipFile(self.output / rows[0][0]) as archive:
            self.assertEqual(archive.getinfo(rows[0][1] + rows[0][2]).compress_type, 98)
            self.assertEqual(archive.getinfo(rows[1][1] + rows[1][2]).compress_type, 0)
        self.assertEqual(self.packed_book(result, 2), body)

    def test_full_verification_detects_same_size_and_time_source_change(self):
        self.job['verify_sources'] = True
        source = self.source / 'book.txt'; source.write_bytes(b'A ' * 40000)
        self.add(1, source, '')
        Packer(self.job).execute(); stamp = source.stat()
        source.write_bytes(b'B ' * 40000); os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        result = Packer(self.job).execute()
        self.assertEqual(result.reused, 0)
        self.assertEqual(self.packed_book(result, 1), b'B ' * 40000)

    def test_turning_on_full_verification_does_not_recompress_unchanged_sources(self):
        source = self.source / 'book.txt'; source.write_bytes(b'A ' * 40000)
        self.add(1, source, '')
        Packer(self.job).execute()
        self.job.update(verify_sources=True, verify_outputs=True)
        result = Packer(self.job).execute()
        self.assertEqual(result.reused, 1)
        self.assertEqual(self.packed_book(result, 1), b'A ' * 40000)

    def test_hard_interruption_cleans_owned_scratch_and_reuses_finished_source(self):
        originals = {}
        for identity in (1, 2):
            path = self.archive(f'{identity}.zip', {f'{identity}.fb2': (str(identity) * 30000).encode()})
            self.add(identity, path, f'{identity}.fb2'); originals[path] = sha(path)
        job = self.root / 'job.json'; job.write_text(json.dumps(self.job), encoding='utf-8')
        script = '''import sys,os,json
sys.path.insert(0,sys.argv[1])
from pack_collection import Packer
state={'finished':False}
def notify(event):
 if event['stage']=='source' and event['current']==1:state['finished']=True
 if event['stage']=='books' and state['finished']:os._exit(42)
Packer(json.loads(open(sys.argv[2],encoding='utf-8').read()),notify).execute()
'''
        child = subprocess.run([sys.executable, '-I', '-B', '-X', 'utf8', '-c', script,
                                str(Path(__file__).parent), str(job)], check=False,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.assertEqual(child.returncode, 42)
        self.assertTrue(list(self.output.glob('.packing-*')))
        result = Packer(self.job).execute()
        self.assertEqual(result.reused, 1)
        self.assertEqual(result.books, 2)
        self.assertFalse(list(self.output.glob('.packing-*')))
        self.assertEqual(len(list(self.output.glob('generations/*'))), 1)
        for path, digest in originals.items(): self.assertEqual(sha(path), digest)

    def test_low_destination_space_does_not_change_originals(self):
        source = self.source / 'book.txt'; source.write_bytes(b'First ' * 3000)
        self.add(1, source, ''); original = sha(source)
        with patch('pack_collection.shutil.disk_usage', return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(PackingError, 'свободного места'):
                Packer(self.job).execute()
        self.assertEqual(sha(source), original)
        self.assertFalse(list(self.output.glob('generations/*')))
        self.assertFalse(list(self.output.glob('.packing-*')))

    def test_image_quality_request_cannot_be_silently_ignored(self):
        self.job['images'] = 'economy'
        with self.assertRaisesRegex(PackingError, 'качества'):
            Packer(self.job).execute()
        self.assertFalse(self.output.exists())

    def test_missing_image_component_leaves_destination_uncreated(self):
        self.job.update(engine='illustrations-ppmd', images='balanced', tools_root=str(self.root))
        with self.assertRaisesRegex(PackingError, 'BookProcessing'):
            Packer(self.job).execute()
        self.assertFalse(self.output.exists())

    @unittest.skipUnless(IMAGE_TOOLS, 'Native HomeLibre Images runtime not supplied')
    def test_illustration_profile_retains_text_and_reuses_optimized_payloads(self):
        self.job.update(engine='illustrations-ppmd', images='economy', tools_root=IMAGE_TOOLS)
        picture = image_fixture()
        fb2 = self.source / 'book.fb2'
        fb2.write_bytes(b'''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>sf</genre><author><nickname>A</nickname></author><book-title>Title</book-title><lang>en</lang></title-info>
<document-info><author><nickname>A</nickname></author><date>2026</date><id>fixture</id><version>1.0</version></document-info></description>
<body><section><p>Keep <emphasis>this text</emphasis>.</p><image l:href="#picture"/></section></body>
<binary id="picture" content-type="image/png">''' + base64.b64encode(picture) + b'</binary></FictionBook>')
        epub = self.source / 'book.epub'
        chapter = b'<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Keep <em>this text</em>.</p><img src="picture.png" alt="Fixture"/></body></html>'
        style = b'p { line-height: 1.25; }'
        with zipfile.ZipFile(epub, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            archive.writestr('META-INF/container.xml',
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
            archive.writestr('book.opf', '''<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
<manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/>
<item id="pic" href="picture.png" media-type="image/png"/><item id="style" href="book.css" media-type="text/css"/></manifest>
<spine><itemref idref="ch"/></spine></package>''')
            archive.writestr('chapter.xhtml', chapter)
            archive.writestr('book.css', style)
            archive.writestr('picture.png', picture)
        pdf, djvu = self.source / 'book.pdf', self.source / 'book.djvu'
        pdf.write_bytes(b'%PDF-1.4\n' + picture)
        djvu.write_bytes(b'AT&TFORM' + picture)
        damaged = self.source / 'broken.epub'
        damaged.write_bytes(b'PK broken')
        books = [fb2, epub, pdf, djvu, damaged]
        original_hashes = [sha(book) for book in books]
        for identity, book in enumerate(books, 1):
            self.add(identity, book, '')

        result = Packer(self.job).execute()
        self.assertEqual((result.image_books_optimized, result.image_books_skipped), (2, 1))
        fb2_copy = self.packed_book(result, 1)
        xml = ElementTree.fromstring(fb2_copy)
        self.assertEqual(''.join(xml.find('.//{*}p').itertext()), 'Keep this text.')
        self.assertEqual(xml.find('.//{*}image').get('{http://www.w3.org/1999/xlink}href'), '#picture')
        self.assertEqual(xml.find('.//{*}binary').get('id'), 'picture')
        self.assertLess(len(base64.b64decode(xml.find('.//{*}binary').text)), len(picture))
        epub_copy = self.root / 'copy.epub'
        epub_copy.write_bytes(self.packed_book(result, 2))
        with zipfile.ZipFile(epub_copy) as archive:
            self.assertEqual(archive.read('chapter.xhtml'), chapter)
            self.assertEqual(archive.read('book.css'), style)
            self.assertLess(len(archive.read('picture.png')), len(picture))
        self.assertLess(result.output_bytes, result.input_bytes)
        for identity, book in enumerate(books[2:], 3):
            self.assertEqual(self.packed_book(result, identity), book.read_bytes())
        self.assertEqual([sha(book) for book in books], original_hashes)

        balanced_output = self.root / 'balanced'
        balanced = Packer(dict(self.job, output=str(balanced_output), images='balanced')).execute()
        self.assertEqual((balanced.image_books_optimized, balanced.image_books_skipped), (2, 1))
        self.assertEqual(json.loads((balanced_output / 'HomeLibRu-compressed.json').read_text())['images'],
                         'balanced')

        self.retain(result, range(1, 6))
        new_book = self.source / 'new.fb2'
        new_book.write_bytes(fb2.read_bytes().replace(b'Keep ', b'New '))
        self.add(6, new_book, '')
        resumed = Packer(self.job).execute()
        self.assertEqual((resumed.reused, resumed.image_books_optimized, resumed.image_books_skipped), (5, 3, 1))
        self.assertEqual(self.packed_book(resumed, 1), fb2_copy)
        self.assertIn(b'New ', self.packed_book(resumed, 6))
        with self.assertRaisesRegex(PackingError, 'другие настройки'):
            Packer(dict(self.job, images='balanced')).execute()

    def test_large_zip_member_is_preserved_without_decoding_or_size_inflation(self):
        source = self.archive('large.zip', {'1.fb2': b'Large original text ' * 3000})
        self.add(1, source, '1.fb2')
        with patch('pack_collection.MAX_BOOK', 1024):
            result = Packer(self.job).execute()
        self.assertEqual(result.opaque_sources, 1)
        self.assertEqual(result.output_bytes, source.stat().st_size)
        self.assertEqual(self.packed_book(result, 1), b'Large original text ' * 3000)


if __name__ == '__main__':
    unittest.main()

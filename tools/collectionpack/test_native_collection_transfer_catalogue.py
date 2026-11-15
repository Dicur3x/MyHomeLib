"""Native catalogue-to-transfer inventory using the application's SQL schemas."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import unittest
import zipfile

from pack_collection import temporary_work_directory

BINARY = Path(os.environ['HL_TRANSFER_CATALOGUE']) if os.environ.get('HL_TRANSFER_CATALOGUE') else None
SQLITE = Path(os.environ['HL_TRANSFER_SQLITE']) if os.environ.get('HL_TRANSFER_SQLITE') else None
SEVENZIP = Path(os.environ['HL_TRANSFER_7ZIP']) if os.environ.get('HL_TRANSFER_7ZIP') else None
STAGE = Path(os.environ['HL_TRANSFER_STAGE']) if os.environ.get('HL_TRANSFER_STAGE') else None
REPO = Path(__file__).resolve().parents[2]
SOURCE_PROPERTY = 0x20000000 | 0x00040000 | 0x001f


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@contextmanager
def connect(path):
    db = sqlite3.connect(path)
    db.create_collation('MHL_SYSTEM_NOCASE', lambda a, b: (a.casefold() > b.casefold()) - (a.casefold() < b.casefold()))
    db.create_function('MHL_TRIGGERS_ON', 0, lambda: 0)
    db.create_function('MHL_UPPER', 1, lambda s: s.upper() if s else s)
    try:
        with db:
            yield db
    finally:
        db.close()


def insert(db, table, values):
    values = dict(values)
    for _, name, kind, required, default, _ in db.execute(f'pragma table_info({table})'):
        if required and default is None and name not in values:
            values[name] = 0 if 'INT' in kind.upper() else ''
    names = list(values)
    db.execute(f"insert into {table}({','.join(names)}) values({','.join('?' for _ in names)})", list(values.values()))


@unittest.skipUnless(os.name == 'nt' and all(p and p.is_file() for p in (BINARY, SQLITE, SEVENZIP)) and STAGE,
                     'requires native catalogue adapter, SQLite, 7-Zip and owned stage')
class TransferCatalogueTests(unittest.TestCase):
    attempts = 0

    def setUp(self):
        self.owned = temporary_work_directory(STAGE, 'HomeLibRu-native-')
        self.home = Path(self.owned.__enter__())
        self.binary = self.home / 'CollectionTransferCatalogueTest.exe'
        shutil.copy2(BINARY, self.binary)
        shutil.copy2(SQLITE, self.home / 'sqlite3.dll')
        for name in ('uselocaldata', 'uselocaltemp'):
            (self.home / name).touch()
        (self.home / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        self.a, self.b, self.destination, self.work = [self.home / name for name in ('source-a', 'source-b', 'destination', 'work')]
        for path in (self.a, self.b, self.destination, self.work):
            path.mkdir()
        self.write_zip(self.a / 'same.zip', b'first')
        self.write_zip(self.b / 'same.zip', b'second')
        self.catalogue, self.personal = self.home / 'catalogue.hlc2', self.home / 'system.hlc2'
        self.sources = json.dumps([dict(id='a', root=str(self.a), name='Первый', inpx='old-a.inpx', update_profile='keep-profile', custom='keep'),
                                   dict(id='b', root=str(self.b), name='Второй', file='old-b.hlc2', cache_version='keep-cache')], ensure_ascii=False)
        with connect(self.catalogue) as db:
            db.executescript((REPO / 'Program/DAO/SQLite/Resources/CreateCollectionDB_SQLite.sql').read_text(encoding='utf-8-sig'))
            db.executescript('create table CatalogBookCopies(SourceKey text primary key,BookID integer,SourceName text,Root text,Folder text,FileName text,Ext text,InsideNo integer,BookSize integer,LibID text);'
                             'create table CatalogSourceBooks(SourceKey text primary key,BookID integer);')
            db.execute('insert into Settings values(?,?)', (SOURCE_PROPERTY, self.sources))
            for book_id in (1, 2, 3):
                insert(db, 'Books', dict(BookID=book_id, LibID=str(100+book_id), Title=f'Книга {book_id}',
                    Folder='same.zip' if book_id != 3 else 'notdownloaded.zip', FileName=str(100+book_id), Ext='.fb2', BookSize=800+book_id))
                db.execute('insert into CatalogSourceBooks values(?,?)', (f'a:file:stable-{book_id}', book_id))
            insert(db, 'CatalogBookCopies', dict(SourceKey='b:file:stable-copy', BookID=1, Root=str(self.b), Folder='same.zip',
                FileName='101', Ext='.fb2', InsideNo=0, BookSize=777, LibID='b:101', SourceName='Второй'))
        with connect(self.personal) as db:
            db.executescript((REPO / 'Program/DAO/SQLite/Resources/CreateSystemDB_SQLite.sql').read_text(encoding='utf-8-sig'))
            insert(db, 'Bases', dict(DatabaseID=7, BaseName='Три источника', DBFileName=str(self.catalogue), RootFolder=str(self.a)))
            insert(db, 'Bases', dict(DatabaseID=8, BaseName='Другая коллекция', DBFileName='other.hlc2', RootFolder=str(self.b)))
            for book_id, collection_id, filename in ((1, 7, '101'), (88, 7, ''), (1, 8, 'not-ours')):
                insert(db, 'Books', dict(BookID=book_id, DatabaseID=collection_id, LibID=str(book_id), Title='Личные данные',
                    Folder='same.zip', FileName=filename, Ext='.fb2', BookSize=801, Rate=5, Progress=37, Annotation='Личная заметка ё', Review=b'kept review'))
            insert(db, 'Groups', dict(GroupID=4, GroupName='Избранное', AllowDelete=1, Notes=b'group note'))
            insert(db, 'BookGroups', dict(BookID=1, DatabaseID=7, GroupID=4))
        for path in (self.catalogue, self.personal):
            with connect(path) as db:
                db.execute('pragma journal_mode=delete')
        self.request, self.result = self.home / 'request.json', self.home / 'result.json'
        self.config = dict(catalogue=str(self.catalogue), personal=str(self.personal), root=str(self.a),
                           destination=str(self.destination), work=str(self.work))

    def tearDown(self):
        root = self.home
        self.owned.__exit__(None, None, None)
        self.assertFalse(root.exists(), 'private catalogue runtime remained')

    @staticmethod
    def write_zip(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('101.fb2', body)
            archive.writestr('102.fb2', body+b'other')

    def snapshot(self):
        return {str(p): digest(p) for p in [self.catalogue, self.personal, *self.a.rglob('*'), *self.b.rglob('*')] if p.is_file()}

    def run_case(self, success=True, preserve=True):
        before = self.snapshot()
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        type(self).attempts += 1
        result = subprocess.run([str(self.binary), str(self.request), str(self.result)], cwd=self.home, capture_output=True, timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ, 'TEMP': str(self.home), 'TMP': str(self.home)})
        evidence = dict(test=self.id(), request=self.config, returncode=result.returncode, output=(result.stdout+result.stderr).decode('utf-8', errors='replace'))
        if self.result.exists():
            evidence['result'] = json.loads(self.result.read_text(encoding='utf-8-sig'))
        with (STAGE / 'invocations.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(evidence, ensure_ascii=False)+'\n')
        self.assertFalse(list(self.work.glob('collection-plan-*')), 'owned scratch store remained')
        if not self.config.get('prepare_copies'):
            self.assertFalse(list(self.destination.iterdir()), 'read-only preview created payload output')
        if preserve:
            self.assertEqual(self.snapshot(), before)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual(evidence['result']['status'], 'PASS')
            return evidence['result']
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse(self.result.exists())
        return evidence['output']

    def make_legacy(self):
        seed = self.home / '101.fb2'
        seed.write_bytes(b'<FictionBook>101</FictionBook>')
        archive = self.a / 'legacy.7z'
        result = subprocess.run([str(SEVENZIP), 'a', '-t7z', '-mx=0', str(archive), str(seed)], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        with connect(self.catalogue) as db:
            db.execute("update Books set Folder='legacy.zip' where BookID=1")
        return archive

    def test_primary_copy_personal_and_metadata_only_bindings(self):
        result = self.run_case()
        self.assertEqual((result['rows'], result['available'], result['missing'], result['metadata_only'], result['candidates']), (6, 4, 1, 1, 3))
        self.assertEqual(len(result['files']), 2)
        self.assertEqual(result['sources_json'], self.sources)
        self.assertEqual({row['kind'] for row in result['bindings']}, {0, 1, 2})
        self.assertEqual([row['source_key'] for row in result['bindings'] if row['kind']==2], ['b:file:stable-copy'])
        self.assertNotEqual(result['files'][0]['destination'], result['files'][1]['destination'])

    def test_prepared_archives_are_readable_through_native_books(self):
        self.config['prepare_copies'] = True
        result = self.run_case()
        self.assertEqual((result['native_read_pairs'], result['prepared_files']), (4, 2))
        for item in result['files']:
            self.assertEqual(digest(item['source']), digest(item['destination']))

    def test_prepared_native_7z_and_zip_books_keep_payloads(self):
        self.make_legacy()
        self.config['prepare_copies'] = True
        result = self.run_case()
        self.assertEqual((result['native_read_pairs'], result['prepared_files']), (4, 3))
        for item in result['files']:
            self.assertEqual(digest(item['source']), digest(item['destination']))

    def test_sidecar_arriving_after_copy_is_detected(self):
        self.make_legacy()
        before = self.snapshot()
        self.config.update(prepare_copies=True, change_after_copy=str(self.a/'images/legacy.zip'))
        self.assertIn('внешних картинок', self.run_case(False, False))
        after = self.snapshot()
        del after[str(self.a/'images/legacy.zip')]
        self.assertEqual(before, after)

    def test_native_zip_fallback_and_flibrary_sidecars(self):
        archive = self.make_legacy()
        for name in ('covers', 'images'):
            self.write_zip(self.a / name / 'legacy.zip', b'picture')
        result = self.run_case()
        self.assertEqual(len(result['files']), 5)
        self.assertEqual(sum(row['images'] for row in result['files']), 2)
        row = next(row for row in result['bindings'] if row['kind']==0 and row['id']==1)
        self.assertEqual(Path(row['source']), archive)
        self.assertEqual(row['folder'], 'legacy.zip')  # Original logical locator remains captured.

    def test_native_fbd_and_linked_loose_archive(self):
        self.write_zip(self.a / 'pair.zip', b'FBD pair')
        linked = self.home / 'linked'
        linked.mkdir()
        (linked / 'book.zip').write_bytes(b'linked opaque book')
        with connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='pair.zip',Ext='.txt' where BookID=1")
            db.execute('update Books set Folder=?,FileName=?,Ext=?,LibID=? where BookID=2',
                       (str(linked)+os.sep, 'book.zip', '', 'local:link:62019fe5-c4ef-446a-b29a-563525be5d04'))
        result = self.run_case()
        by_id = {row['id']: row for row in result['bindings'] if row['kind']==0}
        self.assertEqual(Path(by_id[1]['source']), self.a/'pair.zip')
        self.assertEqual(Path(by_id[2]['source']), linked/'book.zip')
        self.assertEqual(by_id[2]['state'], 0)

    def test_long_unicode_native_fallback(self):
        archive = self.make_legacy()
        directory = self.a.joinpath(*(['Длинная папка книг ё']*12))
        directory.mkdir(parents=True)
        target = directory/'legacy.7z'
        archive.rename(target)
        self.assertGreater(len(str(target)), 300)
        with connect(self.catalogue) as db:
            db.execute('update Books set Folder=? where BookID=1', (str(target.relative_to(self.a).with_suffix('.zip')),))
        result = self.run_case()
        row = next(row for row in result['bindings'] if row['kind']==0 and row['id']==1)
        self.assertEqual(Path(row['source']), target)
        self.assertEqual(row['state'], 0)

    def test_legacy_catalogue_without_source_properties(self):
        with connect(self.catalogue) as db:
            db.execute('drop table Settings')
        result = self.run_case()
        self.assertEqual((result['rows'], len(result['files']), result['sources_json']), (6, 2, ''))

    def test_absolute_merged_locator_uses_declared_source(self):
        with connect(self.catalogue) as db:
            db.execute('update Books set Folder=? where BookID=2', (str(self.b/'same.zip'),))
        result = self.run_case()
        row = next(row for row in result['bindings'] if row['kind']==0 and row['id']==2)
        self.assertEqual((Path(row['source']), row['root_id']), (self.b/'same.zip', 'source:b'))

    def test_catalogue_cannot_also_be_personal_store(self):
        self.config['personal'] = str(self.catalogue)
        self.assertIn('разными базами', self.run_case(False))

    def test_extensionless_orphan_copy_is_preserved(self):
        (self.b / 'extensionless').write_bytes(b'private extensionless copy')
        with connect(self.catalogue) as db:
            insert(db, 'CatalogBookCopies', dict(SourceKey='orphan:file:stable', BookID=999, Root=str(self.b), Folder='',
                FileName='extensionless', Ext='', InsideNo=0, BookSize=26, LibID='orphan:999'))
        result = self.run_case()
        row = next(row for row in result['bindings'] if row['source_key']=='orphan:file:stable')
        self.assertEqual(Path(row['source']), self.b/'extensionless')
        self.assertEqual((row['id'], row['state']), (999, 0))

    def test_offline_source_retains_missing_locators(self):
        (self.b / 'same.zip').unlink()
        self.b.rmdir()
        result = self.run_case()
        self.assertEqual((result['available'], result['missing'], result['metadata_only']), (3, 2, 1))
        self.assertEqual(len(result['files']), 1)
        missing = next(row for row in result['bindings'] if row['kind']==2)
        self.assertEqual((missing['root_id'], missing['state']), ('source:b', 1))
        self.assertEqual(result['sources_json'], self.sources)

    def test_all_missing_is_reported_without_inventing_files(self):
        (self.a/'same.zip').unlink()
        (self.b/'same.zip').unlink()
        self.config['plan'] = False
        result = self.run_case()
        self.assertEqual((result['available'], result['missing'], result['metadata_only']), (0, 5, 1))

    def test_catalogue_change_rejects_stale_capture(self):
        self.config['change'] = 'catalogue'
        self.assertIn('изменились', self.run_case(False, False))

    def test_personal_change_rejects_stale_capture(self):
        self.config['change'] = 'personal'
        self.assertIn('изменились', self.run_case(False, False))

    def test_registration_change_rejects_stale_capture(self):
        self.config['change'] = 'registration'
        self.assertIn('изменились', self.run_case(False, False))

    def test_missing_archive_arrival_rejects_capture(self):
        self.config.update(change='arrived', change_path=str(self.a/'notdownloaded.zip'))
        self.assertIn('отсутствовавший файл', self.run_case(False, False))

    def test_new_7z_fallback_rejects_missing_capture(self):
        self.config.update(change='arrived', change_path=str(self.a/'notdownloaded.7z'))
        self.assertIn('ZIP/7z', self.run_case(False, False))

    def test_zip_arrival_rejects_previous_7z_choice(self):
        self.make_legacy()
        self.config.update(change='arrived', change_path=str(self.a/'legacy.zip'))
        self.assertIn('ZIP/7z', self.run_case(False, False))

    def test_changed_payload_rejects_capture(self):
        self.config.update(change='payload', change_path=str(self.a/'same.zip'))
        self.assertIn('Файл изменился', self.run_case(False, False))

    def test_relative_path_escape_is_rejected(self):
        with connect(self.catalogue) as db:
            db.execute("update Books set Folder='..\\source-b\\same.zip' where BookID=1")
        self.assertIn('за пределы', self.run_case(False))

    def test_wrong_registration_is_rejected(self):
        with connect(self.personal) as db:
            db.execute('update Bases set RootFolder=? where DatabaseID=7', (str(self.b),))
        self.assertIn('Подключение коллекции изменилось', self.run_case(False))

    def test_duplicate_source_ids_are_rejected(self):
        with connect(self.catalogue) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?', (json.dumps([dict(id='a',root=str(self.a)),dict(id='a',root=str(self.b))]), SOURCE_PROPERTY))
        self.assertIn('Повторный', self.run_case(False))

    def add_repeated_rows(self):
        with connect(self.catalogue) as db:
            for book_id in range(10, 6010):
                insert(db, 'Books', dict(BookID=book_id, LibID=str(book_id), Title='Shared archive', Folder='same.zip', FileName=str(book_id), Ext='.fb2', BookSize=123))

    def test_repeated_rows_use_bounded_candidates(self):
        self.add_repeated_rows()
        self.config['limit_bindings'] = 0
        result = self.run_case()
        self.assertEqual((result['rows'], result['candidates'], len(result['files'])), (6006, 3, 2))
        self.assertFalse(result['bindings'])

    def test_cancelled_scan_cleans_owned_scratch(self):
        self.add_repeated_rows()
        self.config['cancel'] = True
        self.assertIn('остановлена', self.run_case(False))

    def test_personal_writes_are_released_before_large_catalogue_scan(self):
        self.add_repeated_rows()
        self.config['personal_during_scan'] = True
        self.assertIn('изменились', self.run_case(False, False))
        with connect(self.personal) as db:
            self.assertEqual(db.execute('select Rate,Progress,Annotation from Books where DatabaseID=7 and BookID=1').fetchone(),
                             (4, 37, 'Личная заметка ё'))


if __name__ == '__main__':
    unittest.main(verbosity=2)

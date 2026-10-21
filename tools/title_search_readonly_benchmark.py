"""Compare the changed title-search SQL using the shipped x86/x64 SQLite DLL.

This measures matching and metadata reads, not VCL rendering or cold OS caches.
Real-catalogue timings require --vm-work-complete, a confirmed workload gate.
The separate --plan-only check prepares queries without running searches.
The source is held with a Windows deny-write lease, has no journal companions,
and is opened READONLY + immutable. Only the in-memory match table is writable.
"""
import argparse
import ctypes
import hashlib
import json
import pathlib
import sqlite3
import struct
import sys
import tempfile
import time
from contextlib import closing, contextmanager

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from database_benchmark import SQLiteDLL, digest, scalar


ROOT = pathlib.Path(__file__).resolve().parents[1]
MATCH_TABLE = ('CREATE TEMP TABLE MHLGenreMatches(ViewID TEXT NOT NULL,'
               'BookID INTEGER NOT NULL,PRIMARY KEY(ViewID,BookID)) WITHOUT ROWID')
MATCHED = "SELECT BookID FROM temp.MHLGenreMatches WHERE ViewID='probe'"
FIELDS = ('b.BookID,b.Title,b.Folder,b.FileName,b.Ext,b.InsideNo,'
          'b.SeriesID,b.SeqNumber,b.BookSize,b.LibID,b.IsDeleted,b.IsLocal,'
          'b.UpdateDate,b.Lang,b.LibRate,b.KeyWords,b.Rate,b.Progress,'
          'CASE WHEN b.Review IS NULL THEN NULL ELSE 1 END,NULL,'
          'b.Translators,b.Publisher,b.City,b.PubYear,b.ISBN,'
          'primaryseries.SeriesTitle,preferred.SourceName')
STREAMS = {
    'books': 'SELECT ' + FIELDS + ' FROM Books b LEFT JOIN CatalogPreferredSource '
             'preferred ON preferred.BookID=b.BookID LEFT JOIN Series primaryseries '
             'ON primaryseries.SeriesID=b.SeriesID WHERE b.BookID IN (' + MATCHED +
             ') ORDER BY b.BookID',
    'authors': 'SELECT al.BookID,a.AuthorID,a.LastName,a.FirstName,a.MiddleName '
               'FROM Author_List al JOIN Authors a ON a.AuthorID=al.AuthorID '
               'WHERE al.BookID IN (' + MATCHED +
               ') ORDER BY al.BookID,a.LastName,a.FirstName,a.MiddleName',
    'genres': 'SELECT gl.BookID,gl.GenreCode FROM Genre_List gl WHERE gl.BookID IN (' +
              MATCHED + ') ORDER BY gl.BookID,gl.GenreCode',
}


def system_collations(db):
    """Match SQLite3UDF.pas: aligned UTF-16 and Windows user-locale comparison."""
    pointer, integer = ctypes.c_void_p, ctypes.c_int
    compare = ctypes.WinDLL('kernel32', use_last_error=True).CompareStringW
    compare.argtypes = [ctypes.c_uint32, ctypes.c_uint32, pointer, integer, pointer, integer]
    compare.restype = integer
    callback_type = ctypes.CFUNCTYPE(integer, pointer, integer, pointer, integer, pointer)
    db.api.sqlite3_create_collation.argtypes = [pointer, ctypes.c_char_p, integer, pointer, callback_type]
    db.api.sqlite3_create_collation.restype = integer
    callbacks, errors = [], []
    for name, flags in ((b'MHL_SYSTEM', 0), (b'MHL_SYSTEM_NOCASE', 1)):
        def collate(context, size_a, a, size_b, b, flags=flags):
            result = compare(0x400, flags, a, size_a // 2, b, size_b // 2)
            if not result:
                errors.append(ctypes.get_last_error())
                return 0
            return result - 2
        callback = callback_type(collate)
        db.check(db.api.sqlite3_create_collation(db.handle, name, 8, None, callback))
        callbacks.append(callback)
    return callbacks, errors


@contextmanager
def stable_source(file):
    """Fail rather than benchmark a live writer or ignore uncheckpointed data."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32,
                                   ctypes.c_uint32, ctypes.c_void_p,
                                   ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    handle = kernel.CreateFileW(str(file), 0x80000000, 1, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        for suffix in ('-wal', '-shm', '-journal'):
            if pathlib.Path(str(file) + suffix).exists():
                raise RuntimeError('Source has a journal companion; close the app normally first.')
        before = file.stat()
        yield
        after = file.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError('Source metadata changed during read-only benchmark.')
    finally:
        kernel.CloseHandle(handle)


@contextmanager
def readonly(file, library):
    # The shared wrapper otherwise opens writable catalogues. Its initial handle
    # points only to memory, and is closed before the real source is considered.
    db = SQLiteDLL(':memory:', library)
    db.close()
    pointer = ctypes.c_void_p
    db.api.sqlite3_open_v2.argtypes = [ctypes.c_char_p, ctypes.POINTER(pointer),
                                      ctypes.c_int, ctypes.c_char_p]
    db.api.sqlite3_open_v2.restype = ctypes.c_int
    db.api.sqlite3_db_readonly.argtypes = [pointer, ctypes.c_char_p]
    db.api.sqlite3_db_readonly.restype = ctypes.c_int
    db.handle = pointer()
    try:
        uri = (file.as_uri() + '?mode=ro&immutable=1').encode('utf-8')
        db.check(db.api.sqlite3_open_v2(uri, ctypes.byref(db.handle), 1 | 0x40, None))
        if db.api.sqlite3_db_readonly(db.handle, b'main') != 1:
            raise RuntimeError('Main database is not read-only.')
        # Keep callbacks alive through sqlite3_close, including failed queries.
        callbacks, collation_errors = system_collations(db)
        db.execute('PRAGMA temp_store=MEMORY').close()
        bits = struct.calcsize('P') * 8
        db.execute('PRAGMA cache_size=' + ('-65536' if bits == 64 else '-32768')).close()
        db.execute('PRAGMA mmap_size=' + ('268435456' if bits == 64 else '67108864')).close()
        yield db
        if collation_errors:
            raise RuntimeError('Windows collation failed: ' + str(collation_errors))
    finally:
        db.close()


def match_sql(after, hide_deleted):
    predicate = "b.SearchTitle LIKE '%ПРИВЕТ%'"
    if after:
        predicate = ("b.BookID IN (SELECT titlematch.BookID FROM Books titlematch "
                     "WHERE titlematch.SearchTitle LIKE '%ПРИВЕТ%')")
    if hide_deleted:
        predicate += ' AND b.IsDeleted=0'
    return 'SELECT DISTINCT b.BookID FROM Books b WHERE ' + predicate


def run_one(file, library, after, hide_deleted):
    with readonly(file, library) as db:
        db.execute(MATCH_TABLE).close()
        sql = match_sql(after, hide_deleted)
        plan = list(db.execute('EXPLAIN QUERY PLAN ' + sql))
        start = time.perf_counter()
        db.execute("INSERT INTO temp.MHLGenreMatches SELECT 'probe',BookID FROM (" + sql + ')').close()
        match_seconds = time.perf_counter() - start
        start = time.perf_counter()
        matched = digest(db.execute(MATCHED + ' ORDER BY BookID'))
        streams = {name: digest(db.execute(query)) for name, query in STREAMS.items()}
        metadata_seconds = time.perf_counter() - start
        return {'variant': 'after' if after else 'before', 'hide_deleted': hide_deleted,
                'match_seconds': match_seconds, 'metadata_seconds': metadata_seconds,
                'total_seconds': match_seconds + metadata_seconds,
                'matched': matched, 'streams': streams, 'plan': plan,
                'sqlite': scalar(db, 'SELECT sqlite_version()')}


def self_test(library):
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-title-readonly-') as folder:
        file = pathlib.Path(folder) / 'fixture.hlc2'
        with closing(sqlite3.connect(file)) as db:
            # Fields mirror the production stream; unused fixture fields are NULL.
            names = ('BookID INTEGER PRIMARY KEY,Title,Folder,FileName,Ext,InsideNo,'
                     'SeriesID,SeqNumber,BookSize,LibID,IsDeleted,IsLocal,UpdateDate,'
                     'Lang,LibRate,KeyWords,Rate,Progress,Review,Annotation,Translators,'
                     'Publisher,City,PubYear,ISBN,SearchTitle')
            db.execute('CREATE TABLE Books(' + names + ')')
            db.execute('CREATE INDEX IXBooks_SearchTitle ON Books(SearchTitle,BookID)')
            db.execute('CREATE INDEX IXBooks_IsDeleted ON Books(IsDeleted)')
            db.execute('CREATE INDEX IXBooks_BookID_IsDeleted_IsLocal ON Books(BookID,IsDeleted,IsLocal)')
            db.create_collation('MHL_SYSTEM_NOCASE', lambda a, b: (a.casefold() > b.casefold()) - (a.casefold() < b.casefold()))
            for table, columns in {
                'CatalogPreferredSource': 'BookID,SourceName', 'Series': 'SeriesID,SeriesTitle',
                'Author_List': 'BookID,AuthorID',
                'Authors': 'AuthorID,LastName COLLATE MHL_SYSTEM_NOCASE,FirstName,MiddleName',
                'Genre_List': 'BookID,GenreCode',
            }.items():
                db.execute('CREATE TABLE ' + table + '(' + columns + ')')
            db.executemany('INSERT INTO Books(BookID,Title,SearchTitle,IsDeleted) VALUES(?,?,?,?)',
                           [(1, 'Привет', 'ПРИВЕТ', 0), (2, 'С приветом', 'С ПРИВЕТОМ', 1),
                            (3, 'Другое', 'ДРУГОЕ', 0)])
            db.execute("INSERT INTO CatalogPreferredSource VALUES(1,'source')")
            db.execute("INSERT INTO Authors VALUES(1,'Автор','','')")
            db.execute('INSERT INTO Author_List VALUES(1,1)')
            db.execute("INSERT INTO Genre_List VALUES(1,'prose')")
            db.commit()
        original = hashlib.sha256(file.read_bytes()).hexdigest()
        with stable_source(file):
            for hide in (False, True):
                before = run_one(file, library, False, hide)
                after = run_one(file, library, True, hide)
                assert before['matched'] == after['matched']
                assert before['streams'] == after['streams']
                assert after['matched']['rows'] == (1 if hide else 2)
            with readonly(file, library) as db:
                assert scalar(db, "SELECT 'Автор'='автор' COLLATE MHL_SYSTEM_NOCASE") == 1
                assert scalar(db, "SELECT 'Автор'='автор' COLLATE MHL_SYSTEM") == 0
                try:
                    db.execute('DELETE FROM main.Books').close()
                except RuntimeError as error:
                    assert 'readonly' in str(error).lower(), str(error)
                else:
                    raise AssertionError('Write to source was accepted.')
        assert hashlib.sha256(file.read_bytes()).hexdigest() == original
    return {'self_test': 'passed', 'bits': struct.calcsize('P') * 8,
            'source_write_rejected': True, 'source_hash_unchanged': True,
            'fixture_removed': not file.exists()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--catalogue', type=pathlib.Path)
    parser.add_argument('--vm-work-complete', action='store_true')
    parser.add_argument('--plan-only', action='store_true', help='Check real schema without running or timing searches.')
    parser.add_argument('--repeats', type=int, default=2, choices=range(1, 5))
    args = parser.parse_args()
    bits = struct.calcsize('P') * 8
    library = ROOT / 'Program/Out' / ('Bin64' if bits == 64 else 'Bin') / 'sqlite3.dll'
    if args.self_test:
        print(json.dumps(self_test(library), ensure_ascii=False))
        return
    if not args.catalogue or not (args.plan_only or args.vm_work_complete):
        parser.error('Use --self-test, or --catalogue with --plan-only; timings require --vm-work-complete.')
    file = args.catalogue.resolve(strict=True)
    if args.plan_only:
        with stable_source(file), readonly(file, library) as db:
            db.execute(MATCH_TABLE).close()
            queries = dict(STREAMS)
            for after in (False, True):
                for hide in (False, True):
                    queries[f'match_after_{after}_hide_{hide}'] = match_sql(after, hide)
            plans = {name: list(db.execute('EXPLAIN QUERY PLAN ' + sql)) for name, sql in queries.items()}
        print(json.dumps({'bits': bits, 'plan_only': True, 'catalogue_search_executed': False,
                          'source': str(file), 'plans': plans}, ensure_ascii=False))
        return
    results = []
    with stable_source(file):
        expected = {}
        for repeat in range(args.repeats):
            for hide in (True, False):
                for after in ((False, True) if repeat % 2 == 0 else (True, False)):
                    result = run_one(file, library, after, hide)
                    signature = result['matched'], result['streams']
                    if hide in expected and expected[hide] != signature:
                        raise RuntimeError('Result differs between old/new query or repeated run.')
                    expected[hide] = signature
                    result['repeat'] = repeat + 1
                    results.append(result)
                    print(json.dumps({'progress': result}, ensure_ascii=False), flush=True)
    print(json.dumps({'bits': bits, 'source': str(file), 'source_open_mode': 'readonly immutable with deny-write lease',
                      'dll_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                      'limitation': 'Fresh SQLite connections, shared OS cache; includes Python metadata hashing/collation callbacks; not UI timing.',
                      'results': results}, ensure_ascii=False))


if __name__ == '__main__':
    main()

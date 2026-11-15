"""Native publication against redirected full copies of the user's SQLite stores."""
from contextlib import closing
import ctypes
import hashlib
import json
import os
from pathlib import Path
import pickle
import sqlite3
import time
import unittest
import zipfile

from pack_collection import reserve_space, temporary_work_directory
from supervised_test_process import run_owned
import test_native_compression_operation as operations
from test_real_container_compression import selected, source_stamps_unchanged, verify_grayscale
from validate_catalogue_compression import archive_body
from prepare_book_compression import verify_non_image_content

CATALOGUE = os.environ.get('HL_FULL_CATALOGUE_SOURCE')
PERSONAL = os.environ.get('HL_FULL_PERSONAL_SOURCE')
EVIDENCE = os.environ.get('HL_FULL_CATALOGUE_EVIDENCE')
HISTORY = {'HomeLibreBookCompression', 'HomeLibreRestoredBookSizes',
           'HomeLibreCompressionOutcomes', 'HomeLibreCompressedImages',
           'HomeLibreCompressionImageSets', 'HomeLibreCompressionDependencies',
           'HomeLibreCompressionChecks'}


def stamp(path):
    s = path.stat()
    return s.st_size, s.st_mtime_ns, s.st_dev, s.st_ino


def wal_empty(path):
    wal = Path(str(path)+'-wal')
    return not wal.exists() or wal.stat().st_size == 0


def file_hash(path, check):
    result = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(1024*1024):
            check()
            result.update(block)
    return result.hexdigest()


def clone_connection(path, root):
    """Register the application's exact Windows collation on owned copies only."""
    if path.resolve().parent != root.resolve() or path.is_symlink():
        raise AssertionError('SQLite mutations are limited to the owned clone root')
    db = sqlite3.connect(path)
    db.execute('PRAGMA temp_store=MEMORY')
    compare = ctypes.windll.kernel32.CompareStringW
    compare.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_wchar_p, ctypes.c_int,
                        ctypes.c_wchar_p, ctypes.c_int]
    compare.restype = ctypes.c_int
    def collate(flags, left, right):
        result = compare(0x400, flags, left, len(left.encode('utf-16-le'))//2,
                         right, len(right.encode('utf-16-le'))//2)
        if not result:
            raise ctypes.WinError()
        return result-2
    db.create_collation('MHL_SYSTEM', lambda a,b: collate(0,a,b))
    db.create_collation('MHL_SYSTEM_NOCASE', lambda a,b: collate(1,a,b))
    # Retarget only paths and their ASCII search keys. Never recompute actual
    # titles/annotations with an approximation of Delphi's Unicode functions.
    db.create_function('MHL_TRIGGERS_ON', 0, lambda: 0)
    db.create_function('MHL_SERIES_TRIGGERS_ON', 0, lambda: 0)
    def unexpected_upper(value):
        raise AssertionError('The disabled clone-setup trigger unexpectedly ran')
    db.create_function('MHL_UPPER', 1, unexpected_upper)
    return db


def logical_snapshot(path, selected_ids, check):
    """Hash every old row, excluding only permitted selected BookSize values."""
    with closing(sqlite3.connect(path.as_uri()+'?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        db.execute('PRAGMA temp_store=MEMORY')
        db.text_factory = bytes
        tables = [r[0].decode() for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")]
        output = {}
        for name in tables:
            if name in HISTORY:
                continue
            quoted = '"'+name.replace('"','""')+'"'
            cursor = db.execute('SELECT * FROM '+quoted+' ORDER BY rowid')
            columns = [c[0] for c in cursor.description]
            identity = columns.index('BookID') if 'BookID' in columns else None
            size = columns.index('BookSize') if 'BookSize' in columns else None
            collection = columns.index('DatabaseID') if 'DatabaseID' in columns else None
            digest = hashlib.sha256()
            count = 0
            for row in cursor:
                if count % 4096 == 0:
                    check()
                values = list(row)
                if (name in {'Books','CatalogBookCopies'} and identity is not None and
                        row[identity] in selected_ids and (collection is None or row[collection] == 14)):
                    values[size] = None
                data = pickle.dumps(tuple(values), protocol=4)
                digest.update(len(data).to_bytes(8,'little')); digest.update(data)
                count += 1
            output[name] = dict(rows=count, sha256=digest.hexdigest())
        return output


@unittest.skipUnless(os.name == 'nt' and CATALOGUE and PERSONAL and EVIDENCE and operations.OPERATOR,
                     'Explicit real-store sources, isolated inputs and guarded native worker required')
class FullCatalogueCopyTests(unittest.TestCase):
    def test_full_merged_catalogue_preserves_all_other_rows_and_updates_selected_sizes(self):
        started = time.monotonic()
        source_catalogue, source_personal = Path(CATALOGUE).resolve(), Path(PERSONAL).resolve()
        source_stamps_unchanged()
        source_before = {p: stamp(p) for p in (source_catalogue, source_personal)}
        for p in source_before:
            self.assertTrue(wal_empty(p), 'Close writes to the working stores before the immutable backup')
        phase = {}
        with temporary_work_directory(os.environ['TEMP'], 'HomeLibre-full-catalogue-') as root:
            def progress_file(stage, **extra):
                Path(EVIDENCE).with_suffix('.progress.json').write_text(json.dumps(
                    dict(stage=stage,elapsed_seconds=round(time.monotonic()-started,3),**extra)),encoding='utf-8')
            def check():
                reserve_space(root, 0)
                for p, identity in source_before.items():
                    if stamp(p) != identity or not wal_empty(p):
                        raise AssertionError('A working store changed externally during the isolated trial')
            progress_file('hashing-original-stores')
            hashes = {str(p): file_hash(p, check) for p in source_before}
            reserve_space(root, source_catalogue.stat().st_size+64*1024*1024)
            catalogue, personal = root/'catalogue.hlc2', root/'personal.dbs2'
            for source, target in ((source_catalogue,catalogue),(source_personal,personal)):
                progress_file('copying-store',store=source.name)
                deadline = time.monotonic()+180
                def progress(status, remaining, total):
                    check()
                    if time.monotonic()>deadline:
                        raise TimeoutError('Bounded store-copy deadline exceeded')
                with closing(sqlite3.connect(source.as_uri()+'?mode=ro&immutable=1',uri=True)) as original, \
                        closing(sqlite3.connect(target)) as clone:
                    original.execute('PRAGMA query_only=ON')
                    original.backup(clone, pages=4096, progress=progress)
            phase['copy_seconds'] = round(time.monotonic()-started,3)
            books = root/'books'; books.mkdir()
            source = books/('__HomeLibre-private-'+root.name+'.zip')
            selections, originals = [], {}
            with zipfile.ZipFile(source,'x',zipfile.ZIP_STORED) as archive, \
                    closing(clone_connection(catalogue,root)) as db:
                for inside, extension in enumerate(('.cbz','.docx','.odt')):
                    path, body, info = selected(extension)
                    book_id = info['book_id']; filename = 'private_'+str(book_id)
                    row = db.execute('SELECT LibID FROM Books WHERE BookID=?',(book_id,)).fetchone()
                    self.assertIsNotNone(row)
                    archive.writestr(filename+extension,body)
                    db.execute('UPDATE Books SET Folder=?,FileName=?,InsideNo=?,BookSize=?,SearchFolder=?,SearchFileName=?,SearchExt=? WHERE BookID=?',
                        (source.name,filename,inside,len(body),source.name.upper(),filename.upper(),extension.upper(),book_id))
                    db.execute('UPDATE CatalogBookCopies SET Root=?,Folder=?,FileName=?,InsideNo=?,BookSize=? WHERE BookID=?',
                        (str(books),source.name,filename,inside,len(body),book_id))
                    selections.append(dict(id=book_id, lib_id=row[0], folder=source.name,
                                           file_name=filename, ext=extension, inside_no=inside))
                    originals[book_id] = (extension,path,body,filename+extension)
                db.commit()
            with closing(clone_connection(personal,root)) as db:
                db.execute('UPDATE Bases SET RootFolder=?,DBFileName=? WHERE DatabaseID=14',(str(books),str(catalogue)))
                for row in selections:
                    db.execute('UPDATE Books SET Folder=?,FileName=?,InsideNo=?,BookSize=? WHERE DatabaseID=14 AND BookID=?',
                        (source.name,row['file_name'],row['inside_no'],len(originals[row['id']][2]),row['id']))
                db.commit()
            ids = set(originals)
            progress_file('hashing-every-original-clone-row')
            baseline = {'catalogue':logical_snapshot(catalogue,ids,check),
                        'personal':logical_snapshot(personal,ids,check)}
            phase['baseline_seconds'] = round(time.monotonic()-started-phase['copy_seconds'],3)
            tools = operations.RUNTIME/'tools'
            backup = root/'originals'; backup.mkdir()
            request, result = root/'operation.json', root/'result.json'
            config = dict(options=dict(collection_id=14,catalogue=str(catalogue),personal=str(personal),
                root=str(books),base_root=str(books),base_catalogue=str(catalogue)), selected=selections,
                work_root=str(root/'work'),python=str(tools/'python/python.exe'),
                script=str(tools/'bookconvert/prepare_book_compression.py'),seven_zip=str(tools/'7zip/7za.exe'),
                tools_root=str(tools),profile='economy',grayscale=True,operation_mode='review-apply',
                allowed_source=str(source),backup_originals=True,backup_folder=str(backup),timeout_ms=300000)
            request.write_text(json.dumps(config,ensure_ascii=False),encoding='utf-8')
            progress_file('guarded-native-publication')
            run_started = time.monotonic()
            process = run_owned([str(operations.OPERATOR),str(request),str(result)],capture_output=True,
                encoding='utf-8',errors='strict',timeout=330)
            phase['native_seconds'] = round(time.monotonic()-run_started,3)
            self.assertEqual(process.returncode,0,process.stdout+process.stderr)
            applied = json.loads(result.read_text(encoding='utf-8-sig'))
            self.assertEqual(applied['error'],'',applied)
            self.assertEqual(applied['warning'],'',applied)
            self.assertTrue(applied['allowed_source_verified'],applied)
            self.assertEqual(applied['changed_files'],1,applied)
            self.assertEqual(applied['pending_after_ack'],0,applied)
            progress_file('checking-every-clone-row-after-publication')
            after = {'catalogue':logical_snapshot(catalogue,ids,check),
                     'personal':logical_snapshot(personal,ids,check)}
            self.assertEqual(after,baseline)
            saved, = backup.glob('*.zip')
            sizes = {}
            with zipfile.ZipFile(saved) as archive, closing(sqlite3.connect(catalogue)) as db:
                for book_id,(extension,path,body,member) in originals.items():
                    self.assertEqual(archive.read('books/'+member),body)
                    packed = archive_body(source,member,config['seven_zip'])
                    self.assertLess(len(packed),len(body))
                    candidate = root/('checked'+extension); candidate.write_bytes(packed)
                    verify_non_image_content(path,candidate,extension)
                    verify_grayscale(self,candidate,extension)
                    self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=?',(book_id,)).fetchone()[0],len(packed))
                    self.assertTrue(all(r[0]==len(packed) for r in db.execute('SELECT BookSize FROM CatalogBookCopies WHERE BookID=?',(book_id,))))
                    sizes[str(book_id)] = dict(format=extension,input_bytes=len(body),output_bytes=len(packed))
            for p in source_before:
                progress_file('verifying-original-store-hashes',store=p.name)
                self.assertEqual(file_hash(p,check),hashes[str(p)])
            source_stamps_unchanged()
            evidence = dict(status='PASS',scope='Native reviewed write on redirected full working catalogue/personal copies',
                source_hashes=hashes,source_bytes={str(p):s[0] for p,s in source_before.items()},
                snapshots=baseline,selected_sizes=sizes,allowed_source_verified=True,
                source_stores_unchanged=True,phases=phase,total_seconds=round(time.monotonic()-started,3))
        evidence['full_copy_workspace_removed'] = not root.exists()
        self.assertTrue(evidence['full_copy_workspace_removed'])
        Path(EVIDENCE).write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
        progress_file('complete')

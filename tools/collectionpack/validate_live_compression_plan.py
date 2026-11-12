"""Read-only selection probe against a real merged catalogue.

Uses the normal native path/member resolver. Only a small personal database
snapshot and the captured plan are written, inside a guarded temporary folder.
The plan is never passed to a writer or compressor.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

from pack_collection import temporary_work_directory


def stamp(path):
    info = path.stat()
    return info.st_ino, info.st_size, info.st_mtime_ns


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe(catalogue, personal, collection_id, book_id, planner, sqlite, runtime, stage):
    catalogue, personal = catalogue.resolve(strict=True), personal.resolve(strict=True)
    initial = {catalogue: stamp(catalogue), personal: stamp(personal)}
    personal_sha = digest(personal)
    with temporary_work_directory(stage, 'HomeLibRu-native-') as folder:
        folder = Path(folder)
        shutil.copy2(planner, folder / 'BookCompressionApplicationTest.exe')
        shutil.copy2(sqlite, folder / 'sqlite3.dll')
        (folder / 'tools/7zip').mkdir(parents=True)
        shutil.copy2(runtime / 'tools/7zip/7za.exe', folder / 'tools/7zip/7za.exe')
        copied_personal = folder / 'user-snapshot.dbs2'
        with closing(sqlite3.connect(personal.as_uri() + '?mode=ro', uri=True)) as original, closing(sqlite3.connect(copied_personal)) as snapshot:
            original.backup(snapshot)
            root = snapshot.execute('SELECT RootFolder FROM Bases WHERE DatabaseID=?', (collection_id,)).fetchone()[0]
            # Expand only the snapshot's registration for the isolated profile.
            snapshot.execute('UPDATE Bases SET DBFileName=? WHERE DatabaseID=?', (str(catalogue), collection_id))
            snapshot.commit()
        with closing(sqlite3.connect(catalogue.as_uri() + '?mode=ro', uri=True)) as db:
            selected = []
            for identity in book_id:
                row = db.execute('SELECT BookID,LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?', (identity,)).fetchone()
                assert row, identity
                selected.append(dict(zip(('id', 'lib_id', 'folder', 'file_name', 'ext', 'inside_no'), row)))
        sources = set()
        for row in selected:
            container = Path(row['folder'])
            if not container.is_absolute():
                container = Path(root) / container
            if not container.exists() and container.suffix.lower() == '.zip':
                container = container.with_suffix('.7z')
            sources.add(container.resolve(strict=True))
        initial.update({path: stamp(path) for path in sources})
        private_sha = digest(copied_personal)
        request = dict(mode='capture', options=dict(collection_id=collection_id, catalogue=str(catalogue),
            personal=str(copied_personal), root=root, base_root=root, base_catalogue=str(catalogue)),
            selected=selected, workspace=str(folder / 'never-prepared'), report=str(folder / 'never-prepared.json'),
            seven_zip=str(folder / 'tools/7zip/7za.exe'), tools_root=str(folder / 'tools'), profile='original', grayscale=False)
        request_file, result_file = folder / 'request.json', folder / 'result.json'
        request_file.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        started = time.monotonic()
        process = subprocess.run([str(folder / 'BookCompressionApplicationTest.exe'), str(request_file), str(result_file)],
            capture_output=True, timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
        if process.returncode:
            raise AssertionError(process.stdout.decode('utf-8', errors='replace') + process.stderr.decode('utf-8', errors='replace'))
        seconds = time.monotonic() - started
        result = json.loads(result_file.read_text(encoding='utf-8-sig'))
        assert {Path(item['source']).resolve() for item in result['files']} == sources
        assert digest(copied_personal) == private_sha
        assert not (folder / 'never-prepared').exists()
        assert not (folder / 'never-prepared.json').exists()
        rows = []
        for item in result['files']:
            assert item['members']
            receipts = item['receipt_template']['rows']
            assert any(row['kind'] == 0 and row['id'] in book_id for row in receipts)
            rows.append(dict(source=item['source'], members=item['members'], matching_catalogue_rows=len(receipts)))
        report = dict(status='PASS', examined=result['examined'], selection_seconds=round(seconds, 3),
            planner_sha256=digest(planner), book_ids=book_id, files=rows,
            scope='Read-only real merged catalogue and archives; personal registration expanded only in a private snapshot',
            originals_unchanged=True, compressor_or_writer_started=False)
    assert digest(personal) == personal_sha
    assert {path: stamp(path) for path in initial} == initial
    (stage / 'live-selection-plan.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('catalogue', 'personal', 'planner', 'sqlite', 'runtime', 'stage'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--collection-id', type=int, required=True)
    parser.add_argument('--book-id', type=int, action='append', required=True)
    probe(**vars(parser.parse_args()))

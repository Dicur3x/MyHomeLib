"""Private catalogue-scale transfer, cache/root publication and durable completion.

The carriers stay tiny. This measures catalogue work, not archive throughput or
the final ordinary application. All fixtures, SQLite temp files and outputs use G:.
"""
import argparse
import hashlib
import json
import ntpath
import os
from pathlib import Path
import pickle
import subprocess
import time

from benchmark_native_collection_transfer import MemoryJob, footprint, process_memory
from pack_collection import reserve_space

DERIVED = ('LibraryUpdateSourceKeys', 'LibraryUpdateReviewKeys', 'LibraryUpdatePublisherLocations')


def publish_progress(stage, report):
    """Status readers/scanners must not abort a real monitored native job."""
    try:
        temporary = stage/'progress.new'
        temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
        temporary.replace(stage/'progress.json')
        return True
    except OSError as error:
        report['deferred_progress_writes'] = report.get('deferred_progress_writes', 0)+1
        report['last_progress_write_error'] = repr(error)
        return False


def file_sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def path_key(path):
    return str(Path(path).resolve()).casefold()


def data_guard(path, cache=False):
    """Stream all non-locator user columns; never load a million-row table."""
    import test_native_collection_transfer_catalogue as fixture
    result = {}
    with fixture.connect(path) as db:
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        for table in tables:
            if table.startswith(('sqlite_', 'HomeLibreTransfer', 'HomeLibreReaderHistory')):
                continue
            if cache and (table == 'Settings' or table in DERIVED):
                continue  # Cache metadata has its own projection/installation receipts.
            quoted = '"' + table.replace('"', '""') + '"'
            info = list(db.execute('PRAGMA table_info('+quoted+')'))
            ignored = {'Folder'} if table == 'Books' else {'Folder', 'Root'} if table == 'CatalogBookCopies' else {'RootFolder'} if table == 'Bases' else set()
            columns = [r[1] for r in info if r[1] not in ignored and not r[1].startswith('Search')]
            names = ','.join('"'+c.replace('"', '""')+'"' for c in columns)
            keys = [r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]] or columns
            order = ','.join('"'+c.replace('"', '""')+'"' for c in keys)
            where, params = '', ()
            if table == 'Settings':
                where, params = ' WHERE SettingID NOT IN (?,?,?)', (fixture.SOURCE_PROPERTY, 0x20040023, 0x20040022)
            digest, count = hashlib.sha256(), 0
            for row in db.execute('SELECT '+names+' FROM '+quoted+where+' ORDER BY '+order, params):
                raw = pickle.dumps(row, protocol=4)
                digest.update(len(raw).to_bytes(8, 'little')); digest.update(raw); count += 1
            result[table] = dict(columns=columns, rows=count, sha256=digest.hexdigest())
    return result


def cache_identity_guard(job):
    """Independently compare effective update identities at old/new locators."""
    import test_native_collection_transfer_catalogue as fixture
    def source_key(row, root):
        folder, name, ext = str(row[2]), str(row[3]), str(row[4])
        assert folder.lower().endswith(('.zip', '.7z')), 'Synthetic fixture requires archive locators'
        if not name.lower().endswith(ext.lower()): name += ext
        relative = ntpath.relpath(ntpath.normpath(ntpath.join(root, folder)), root)
        raw = (relative+'\x01'+name).replace('/', '\\').lower().encode('utf-8')
        return job['source']+':file:'+hashlib.sha256(raw).hexdigest()
    def review_key(row):
        identity, namespace = str(row[1]), job['library'].lower()
        assert identity.isdigit(), 'Synthetic fixture requires numeric library IDs'
        key = 'id:'+namespace+'\x01'+identity if namespace in ('flibusta', 'librusec') else 'source-id:'+identity
        return hashlib.sha256((key+'\x01'+row[3].lower()+'\x01'+row[4].lower()).encode('utf-8')).hexdigest()
    digest, count, source_overrides, review_overrides = hashlib.sha256(), 0, 0, 0
    with fixture.connect(job['before_file']) as old, fixture.connect(job['after_file']) as new:
        assert not old.execute('SELECT count(*) FROM sqlite_master WHERE name IN (?,?,?)', DERIVED).fetchone()[0]
        assert new.execute('SELECT count(*) FROM sqlite_master WHERE name IN (?,?,?)', DERIVED).fetchone()[0] == 3
        originals = old.execute('SELECT BookID,LibID,Folder,FileName,Ext FROM Books ORDER BY BookID')
        projected = new.execute('SELECT b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,k.SourceKey,r.Key,p.Location FROM Books b '
            'LEFT JOIN LibraryUpdateSourceKeys k ON k.BookID=b.BookID '
            'LEFT JOIN LibraryUpdateReviewKeys r ON r.BookID=b.BookID '
            'LEFT JOIN LibraryUpdatePublisherLocations p ON p.BookID=b.BookID ORDER BY b.BookID')
        for before in originals:
            after = projected.fetchone()
            assert after is not None and before[:2] == after[:2]
            expected_source, expected_review = source_key(before, job['before_root']), review_key(before)
            effective_source = after[5] if after[5] is not None else source_key(after, job['after_root'])
            effective_review = after[6] if after[6] is not None else review_key(after)
            assert effective_source == expected_source and effective_review == expected_review
            publisher = before[2].replace('/', '\\').lower()
            assert not ntpath.isabs(publisher)
            if publisher.endswith('.7z'): publisher = publisher[:-3]+'.zip'
            assert after[7] == publisher
            source_overrides += after[5] is not None; review_overrides += after[6] is not None
            digest.update(json.dumps([before[0], effective_source, effective_review, publisher], separators=(',', ':')).encode('utf-8'))
            count += 1
        assert projected.fetchone() is None
        for table in DERIVED:
            assert not new.execute('SELECT count(*) FROM '+table+' k LEFT JOIN Books b ON b.BookID=k.BookID WHERE b.BookID IS NULL').fetchone()[0]
    return dict(rows=count, sha256=digest.hexdigest(), source_overrides=source_overrides, review_overrides=review_overrides)


def run(args):
    if os.name != 'nt' or args.rows < 1 or args.memory_limit_mib < 1:
        raise ValueError('Windows and positive row/memory limits are required')
    stage = Path(args.stage).resolve()
    for name, value in vars(args).items():
        if name in ('stage', 'binary', 'sqlite', 'sevenzip', 'inputs') and Path(value).resolve().drive.casefold() != 'g:':
            raise ValueError(name+' must be on G:')
    reserve_space(stage.parent, 0)
    stage.mkdir(exist_ok=False)
    os.environ.update(HL_TRANSFER_STAGE=str(stage), HL_TRANSFER_CATALOGUE=args.binary,
                      HL_TRANSFER_SQLITE=args.sqlite, HL_TRANSFER_7ZIP=args.sevenzip,
                      TEMP=str(stage), TMP=str(stage))
    import test_native_collection_transfer_catalogue as fixture
    import test_native_collection_transfer_completion as completion
    inputs = json.loads(Path(args.inputs).read_text(encoding='utf-8'))
    for name, digest in inputs.items():
        path = (fixture.REPO/name).resolve()
        assert path.is_relative_to(fixture.REPO.resolve())
        assert file_sha(path) == digest, name
    inputs[str(Path(__file__).resolve().relative_to(fixture.REPO)).replace('\\', '/')] = file_sha(__file__)
    (stage/'inputs.json').write_text(json.dumps(inputs, indent=2), encoding='utf-8')
    case = completion.TransferCompletionTests('runTest')
    case.setUp()
    report = dict(status='INCOMPLETE', scope=__doc__, native_sha256=file_sha(args.binary),
                  script_sha256=file_sha(__file__), source_input_count=len(inputs),
                  private_runtime=str(case.home), extra_rows=args.rows, phases=[],
                  memory_limit_bytes=args.memory_limit_mib*1024**2)
    started = time.monotonic()

    def native(phase):
        evidence = dict(phase=phase, samples=0, job_peak_commit=0,
                        peak=dict(logical=0, allocated=0), memory_peak={})
        report['phases'].append(evidence)
        tick, process, job = time.monotonic(), None, None
        try:
            job = MemoryJob(report['memory_limit_bytes'])
            with (stage/(phase+'.log')).open('wb') as log, (stage/(phase+'-samples.jsonl')).open('w', encoding='utf-8') as samples:
                process = subprocess.Popen(case.command(), cwd=case.home, stdout=log, stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
                    env={**os.environ, 'TEMP':str(case.home), 'TMP':str(case.home)})
                job.attach(process)
                evidence['pid'] = process.pid
                while True:
                    terminal = process.poll()
                    reserve_space(stage, 0)
                    current, memory = footprint(case.home), process_memory(process)
                    for key, value in current.items(): evidence['peak'][key] = max(evidence['peak'][key], value)
                    for key, value in (memory or {}).items():
                        evidence['memory_peak'][key] = max(evidence['memory_peak'].get(key, 0), value)
                    evidence.update(seconds=round(time.monotonic()-tick, 3), job_peak_commit=job.peak())
                    evidence['samples'] += 1
                    samples.write(json.dumps(dict(seconds=evidence['seconds'], runtime=current, memory=memory))+'\n')
                    samples.flush(); publish_progress(stage, report)
                    if terminal is not None: break
                    if evidence['seconds'] > args.timeout: raise TimeoutError('Native '+phase+' timed out')
                    time.sleep(.5)
            evidence['returncode'] = process.returncode
            if process.returncode:
                raise RuntimeError((stage/(phase+'.log')).read_text(encoding='utf-8', errors='replace')[-4000:])
            evidence['result'] = json.loads(case.result.read_text(encoding='utf-8-sig'))
            return evidence['result']
        finally:
            if process is not None and process.poll() is None:
                process.kill(); process.wait(timeout=15)
            if job:
                evidence['job_peak_commit'] = job.peak(); job.close()

    try:
        def seed_rows():
            for i in range(args.rows):
                if i % 5000 == 0: reserve_space(stage, 0)
                yield (1000+i, str(1000+i), 'Scale row '+str(i), 'same.zip', '101', '.fb2', 800+i, '', 0)
        with fixture.connect(case.catalogue) as db:
            db.executemany('INSERT INTO Books(BookID,LibID,Title,Folder,FileName,Ext,BookSize,UpdateDate,InsideNo) VALUES(?,?,?,?,?,?,?,?,?)', seed_rows())
        # Source A retains the large baseline; source B remains a separate small
        # history. They must both get independent installed cache versions.
        with fixture.connect(case.catalogue) as source, fixture.connect(case.cache_a/'catalog.hlc2') as target:
            source.backup(target)
        protected_paths = [p for root in (case.cache_a, case.cache_b) for p in root.rglob('*') if p.is_file()]+[case.external_index, case.neighbor]
        protected = {str(p):file_sha(p) for p in protected_paths}
        before = dict(catalogue=data_guard(case.catalogue), personal=data_guard(case.personal),
                      caches={path_key(p):data_guard(p, cache=True) for p in (case.cache_a/'catalog.hlc2', case.cache_b/'catalog.hlc2')})
        report['before'] = before
        assert before['catalogue']['Books']['rows'] == args.rows+3
        carriers = {str(p):file_sha(p) for p in (case.a/'same.zip', case.b/'same.zip')}
        report['carriers_before'] = carriers
        report['baseline'] = footprint(case.home)
        case.config.update(run_operation=True, cache_prepare_only=False, prepare_source_caches=True,
            finalize_roots=True, publish_cache_settings=True, read_installed_caches=True,
            register_operation=False, register_groups=False, prepare=False, apply_locations=False)
        moved = native('move')
        assert moved['roots_applied'] and moved['published_cache_databases'] == 1
        assert moved['caches_prepared'] == 2 and moved['removed_sources'] == 2 and moved['copy_streams'] == 2
        case.assert_published()
        expected_books = {case.source_rows[0]['id']:hashlib.sha256(b'first').hexdigest(),
                          case.history['sources'][1]['source']:hashlib.sha256(b'second').hexdigest()}
        assert {r['source']:r['sha256'].lower() for r in moved['installed_book_hashes']} == expected_books
        moved_files = []
        for row in case.intents().values():
            assert Path(row['Destination']).resolve().is_relative_to(case.destination.resolve())
            after_sha = file_sha(row['Destination'])
            assert after_sha == carriers[row['Source']] and not Path(row['Source']).exists()
            moved_files.append(dict(source=row['Source'], destination=row['Destination'], sha256=after_sha))
        assert len(moved_files) == 2
        report['moved_files'] = moved_files
        after = dict(catalogue=data_guard(case.catalogue), personal=data_guard(case.personal), caches={})
        report['cache_intent'] = case.intent()
        for job in report['cache_intent']['jobs']:
            assert Path(job['after_root']).resolve().is_relative_to(case.destination.resolve())
            after['caches'][path_key(job['before_file'])] = data_guard(job['after_file'], cache=True)
        report['cache_update_identities'] = {job['source']:cache_identity_guard(job) for job in report['cache_intent']['jobs']}
        report['after'] = after
        assert before == after, 'Non-locator user data or cached books changed'
        assert {str(p):file_sha(p) for p in protected_paths} == protected, 'An original cache/index/neighbor changed'
        with fixture.connect(case.personal) as db:
            root = db.execute('SELECT RootFolder FROM Bases WHERE DatabaseID=7').fetchone()[0]
        report['final_root'] = root
        planned_root = case.read_review("SELECT Destination FROM Roots WHERE ID='collection'")[0][0]
        report['planned_root'] = planned_root
        assert Path(root).resolve() == Path(planned_root).resolve()
        assert Path(root).resolve().is_relative_to(case.destination.resolve())
        case.config.update(mode='resume', complete_only=True, register_operation=False, crash='')
        done = native('complete')
        case.assert_completed(done)
        database_files = [p for p in case.home.rglob('*') if p.is_file() and p.suffix.casefold() in ('.hlc2', '.sqlite')]
        completed_bytes = {str(p):file_sha(p) for p in database_files}
        replay = native('replay')
        assert done == replay and {str(p):file_sha(p) for p in database_files} == completed_bytes
        assert data_guard(case.catalogue) == before['catalogue'] and data_guard(case.personal) == before['personal']
        assert {str(p):file_sha(p) for p in protected_paths} == protected
        report.update(status='PASS', completed=done, replay_byte_exact=True,
                      originals_unchanged=protected, total_seconds=round(time.monotonic()-started, 3))
    except BaseException as error:
        report.update(status='FAIL', error=repr(error))
        raise
    finally:
        (stage/'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
        case.tearDown()
        report['private_runtime_removed'] = not case.home.exists()
        (stage/'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
    return dict(status=report['status'], rows=args.rows+3, phases=len(report['phases']),
                total_seconds=report['total_seconds'], private_runtime_removed=report['private_runtime_removed'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('stage', 'binary', 'sqlite', 'sevenzip', 'inputs'): parser.add_argument('--'+key, required=True)
    parser.add_argument('--rows', type=int, default=1000000)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--memory-limit-mib', type=int, default=2048)
    print(json.dumps(run(parser.parse_args())))

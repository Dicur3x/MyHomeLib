"""Profile the actual transfer on large, wholly private synthetic catalogues.

All payloads, locators, SQLite temp files and logs are on G:. The two carrier
archives stay tiny so catalogue/reference cost is distinguishable from copying
large books. This is not a full-user-library or archive-throughput measurement.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import pickle
import subprocess
import time

from pack_collection import reserve_space
from supervised_test_process import ExtendedLimits


class MemoryCounters(ctypes.Structure):
    _fields_ = [('cb', ctypes.c_uint32), ('faults', ctypes.c_uint32)] + [
        (name, ctypes.c_size_t) for name in ('peak_working_set', 'working_set',
        'peak_paged_pool', 'paged_pool', 'peak_nonpaged_pool', 'nonpaged_pool',
        'commit', 'peak_commit', 'private')]


def process_memory(process):
    info = MemoryCounters()
    info.cb = ctypes.sizeof(info)
    query = ctypes.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
    query.argtypes = [ctypes.c_void_p, ctypes.POINTER(MemoryCounters), ctypes.c_uint32]
    query.restype = ctypes.c_int
    if not query(int(process._handle), ctypes.byref(info), info.cb):
        if process.poll() is not None:
            return None
        raise ctypes.WinError(ctypes.get_last_error())
    return dict(working_set=info.working_set, peak_working_set=info.peak_working_set,
                private=info.private, peak_commit=info.peak_commit)


class MemoryJob:
    """An unnamed job bounds only this private native process, not other apps."""
    def __init__(self, limit):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
        self.kernel.CreateJobObjectW.restype = ctypes.c_void_p
        self.kernel.SetInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.kernel.QueryInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
        self.kernel.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000 | 0x100  # Kill owned process on close; private commit limit.
        limits.process_memory = limit
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def attach(self, process):
        # The tiny request is followed by a catalogue scan. Assign immediately
        # after creation, before that scan can allocate catalogue-sized objects.
        if not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def peak(self):
        limits = ExtendedLimits()
        if not self.kernel.QueryInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return limits.peak_process_memory

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def rows_hash(path):
    import test_native_collection_transfer_catalogue as fixture
    with fixture.connect(path) as db:
        # Locator triggers legitimately refresh derived Search* fields. Compare
        # primary identities/title/sizes, not the fixture's initially empty keys.
        query = db.execute('SELECT BookID,LibID,Title,FileName,Ext,InsideNo,BookSize,IsDeleted FROM Books ORDER BY BookID')
        digest = hashlib.sha256()
        count = 0
        for row in query:
            raw = pickle.dumps(row, protocol=4)
            digest.update(len(raw).to_bytes(8, 'little'))
            digest.update(raw)
            count += 1
        return dict(rows=count, sha256=digest.hexdigest())


def footprint(root):
    logical = allocated = 0
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                  ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    for path in root.rglob('*'):
        try:
            if not path.is_file():
                continue
            logical += path.stat().st_size
            handle = kernel.CreateFileW('\\\\?\\'+str(path), 0x80, 7, None, 3, 0x00200000, None)
            if handle == ctypes.c_void_p(-1).value:
                continue
            try:
                standard = (ctypes.c_int64 * 3)()
                if kernel.GetFileInformationByHandleEx(handle, 1, ctypes.byref(standard), ctypes.sizeof(standard)):
                    allocated += standard[0]
            finally:
                kernel.CloseHandle(handle)
        except FileNotFoundError:
            pass  # A completed private scratch store can disappear mid-sample.
    return dict(logical=logical, allocated=allocated)


def run(args):
    if os.name != 'nt' or args.rows < 1 or args.memory_limit_mib < 1:
        raise ValueError('Windows and positive row/memory limits are required')
    stage = Path(args.stage).resolve()
    for name, path in [('stage', stage), ('binary', Path(args.binary)), ('sqlite', Path(args.sqlite)),
                       ('sevenzip', Path(args.sevenzip))]:
        if path.resolve().drive.casefold() != 'g:':
            raise ValueError(name + ' must be on the owned G: test volume')
    stage.mkdir(exist_ok=False)
    os.environ.update(HL_TRANSFER_STAGE=str(stage), HL_TRANSFER_CATALOGUE=args.binary,
                      HL_TRANSFER_SQLITE=args.sqlite, HL_TRANSFER_7ZIP=args.sevenzip,
                      TEMP=str(stage), TMP=str(stage))
    import test_native_collection_transfer_catalogue as fixture
    import test_native_collection_transfer_removal as removal
    case = removal.TransferRemovalTests('runTest')
    started = time.monotonic()
    case.setUp()
    evidence = dict(status='INCOMPLETE', scope=__doc__, requested_extra_rows=args.rows,
                    script_sha256=fixture.digest(__file__),
                    native_sha256=fixture.digest(args.binary), samples=0)
    process = None
    job = None
    memory_peak = dict(working_set=0, peak_working_set=0, private=0, peak_commit=0)
    evidence['memory_limit_bytes'] = args.memory_limit_mib * 1024**2
    try:
        reserve_space(stage, 0)
        with fixture.connect(case.catalogue) as db:
            db.executemany('INSERT INTO Books(BookID,LibID,Title,Folder,FileName,Ext,BookSize,UpdateDate,InsideNo) VALUES(?,?,?,?,?,?,?,?,?)',
                           ((1000+i, str(1000+i), 'Scale row '+str(i), 'same.zip', '101', '.fb2', 800+i, '', 0)
                            for i in range(args.rows)))
        before = rows_hash(case.catalogue)
        payloads = {str(p): fixture.digest(p) for p in (case.a/'same.zip', case.b/'same.zip')}
        case.config.update(run_operation=True, prepare=False, apply_locations=False,
                           register_operation=False, register_groups=False,
                           prepare_source_caches=False, finalize_roots=False,
                           publish_cache_settings=False)
        baseline = footprint(case.home)
        peak = dict(baseline)
        work_peak = dict(logical=0, allocated=0)
        samples = stage/'samples.jsonl'
        tick = time.monotonic()
        job = MemoryJob(evidence['memory_limit_bytes'])
        with (stage/'native.log').open('wb') as log, samples.open('w', encoding='utf-8') as sample_log:
            process = subprocess.Popen(case.command(), cwd=case.home, stdout=log, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
                                       env={**os.environ, 'TEMP':str(case.home), 'TMP':str(case.home)})
            job.attach(process)
            evidence.update(native_pid=process.pid, private_runtime=str(case.home))
            while True:
                terminal = process.poll()
                reserve_space(stage, 0)
                current = footprint(case.home)
                work = footprint(case.work)
                memory = process_memory(process)
                if memory:
                    for key, value in memory.items():
                        memory_peak[key] = max(memory_peak[key], value)
                for key in peak:
                    peak[key] = max(peak[key], current[key])
                    work_peak[key] = max(work_peak[key], work[key])
                sample_log.write(json.dumps(dict(seconds=round(time.monotonic()-tick, 3),
                                                 runtime=current, working=work, memory=memory))+'\n')
                sample_log.flush()
                evidence['samples'] += 1
                # Persist evidence while a long million-row process is live.
                evidence.update(elapsed_native_seconds=round(time.monotonic()-tick, 3),
                                memory_peak=memory_peak, job_peak_commit=job.peak(),
                                baseline=baseline, peak=peak, working_peak=work_peak)
                (stage/'progress.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
                if terminal is not None:
                    break
                if time.monotonic()-tick > args.timeout:
                    raise TimeoutError('Bounded synthetic transfer measurement timed out')
                time.sleep(.5)
        evidence['native_seconds'] = round(time.monotonic()-tick, 3)
        evidence['native_returncode'] = process.returncode
        if process.returncode:
            # Preserve useful failure evidence before the private root is reaped.
            try:
                evidence.update(before_book_rows=before, after_book_rows=rows_hash(case.catalogue),
                                source_carriers_after={p:fixture.digest(p) if Path(p).exists() else None for p in payloads},
                                source_carriers_before=payloads, removal_intents=case.intents())
            except Exception as diagnostic:
                evidence['failure_diagnostic_error'] = repr(diagnostic)
            raise RuntimeError((stage/'native.log').read_text(encoding='utf-8', errors='replace')[-4000:])
        result = json.loads(case.result.read_text(encoding='utf-8-sig'))
        after = rows_hash(case.catalogue)
        evidence.update(result=result, before_book_rows=before, after_book_rows=after,
                        baseline=baseline, peak=peak, working_peak=work_peak)
        if before != after or before['rows'] != args.rows+3:
            raise AssertionError('Book identities, text or sizes changed during the physical move')
        intents = case.intents()
        if len(intents) != 2 or result['removed_sources'] != 2:
            raise AssertionError('The actual two-carrier removal path was not measured')
        for row in intents.values():
            if fixture.digest(row['Destination']) != payloads[row['Source']] or Path(row['Source']).exists():
                raise AssertionError('Private carrier was not moved byte-exactly')
        evidence.update(status='PASS', result=result, book_rows=before, baseline=baseline,
                        peak=peak, peak_additional={k:peak[k]-baseline[k] for k in peak},
                        working_peak=work_peak, total_seconds=round(time.monotonic()-started, 3))
    except BaseException as error:
        evidence.update(status='FAIL', error=repr(error))
        raise
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=15)
        if job:
            evidence['job_peak_commit'] = job.peak()
            job.close()
        evidence['memory_peak'] = memory_peak
        (stage/'report.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
        case.tearDown()
        evidence['private_runtime_removed'] = not case.home.exists()
        (stage/'report.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
    return {k:v for k,v in evidence.items() if k not in ('result', 'scope')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', required=True)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--sqlite', required=True)
    parser.add_argument('--sevenzip', required=True)
    parser.add_argument('--rows', type=int, default=100000)
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--memory-limit-mib', type=int, default=2048)
    print(json.dumps(run(parser.parse_args()), ensure_ascii=False))

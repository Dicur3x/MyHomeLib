"""Measure planning only on a private synthetic multi-archive catalogue."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

from test_native_compression_collection import NativeCompressionCollectionTests
from test_native_compression_receipt import database, sha


def run(planner, count, group_size):
    if not 1 <= count <= 1000000 or not 1 <= group_size <= 10000:
        raise ValueError('Bounded synthetic row and archive counts required')
    case = NativeCompressionCollectionTests()
    case.setUp()
    try:
        archives = (count + group_size - 1) // group_size
        for i in range(archives):
            shutil.copyfile(case.fixture.source, case.root / ('archive-%d.zip' % i))
        with database(case.catalogue) as db:
            db.executemany('INSERT INTO Books SELECT ?,LibID,?,FileName,Ext,InsideNo,BookSize,'
                           'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101',
                           ((1000 + i, 'archive-%d.zip' % (i // group_size)) for i in range(count)))
        files = [case.catalogue, case.personal, *case.root.glob('*.zip')]
        before = {p: sha(p.read_bytes()) for p in files}
        work = case.root / 'plan-work'
        case.config.update(whole=True, summary_only=True, work_root=str(work))
        case.request.write_text(json.dumps(case.config), encoding='utf-8')
        started = time.monotonic()
        process = subprocess.Popen([str(planner), str(case.request), str(case.output)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
        class Counters(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_uint32), ('faults', ctypes.c_uint32)] + [
                (name, ctypes.c_size_t) for name in ('peak', 'working', 'paged_peak', 'paged',
                                                    'nonpaged_peak', 'nonpaged', 'pagefile', 'pagefile_peak')]
        api = ctypes.WinDLL('psapi', use_last_error=True)
        api.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_uint32]
        peak, scratch = 0, 0
        try:
            while process.poll() is None:
                info = Counters()
                info.cb = ctypes.sizeof(info)
                if not api.GetProcessMemoryInfo(int(process._handle), ctypes.byref(info), info.cb):
                    if process.poll() is None:
                        raise ctypes.WinError(ctypes.get_last_error())
                else:
                    peak = max(peak, info.peak)
                current = 0
                for path in work.glob('collection-plan-*/*'):
                    try:
                        current += path.stat().st_size
                    except FileNotFoundError:
                        pass  # Normal teardown can race the observer.
                scratch = max(scratch, current)
                if time.monotonic() - started > 180:
                    raise TimeoutError('Synthetic planning exceeded the observation deadline')
                time.sleep(.05)
            out, error = process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        if process.returncode:
            raise AssertionError((out + error).decode('utf-8', errors='replace'))
        result = json.loads(case.output.read_text(encoding='utf-8-sig'))
        assert (result['file_count'], result['book_count'], result['skipped_rows']) == (archives + 1, archives + 2, 0), result
        assert {p: sha(p.read_bytes()) for p in files} == before
        assert not list(work.glob('collection-plan-*'))
        return dict(status='PASS', catalogue_rows=count + 2, physical_archives=archives + 1,
                    seconds=round(time.monotonic() - started, 3), peak_native_working_bytes=peak,
                    peak_scratch_bytes=scratch, planner_sha256=hashlib.sha256(planner.read_bytes()).hexdigest(),
                    originals_unchanged=True, scratch_removed=True,
                    scope='Private synthetic catalogue; plan construction only, not compression or real-library latency')
    finally:
        case.tearDown()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--planner', type=Path, required=True)
    parser.add_argument('--count', type=int, default=100000)
    parser.add_argument('--group-size', type=int, default=400)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = run(args.planner, args.count, args.group_size)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result))

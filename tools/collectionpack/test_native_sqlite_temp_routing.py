"""Real anonymous SQLite spills in per-connection owned folders on G:."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest

from pack_collection import temporary_work_directory, reserve_space

BINARY = Path(os.environ['HL_SQLITE_TEMP_BINARY']) if os.environ.get('HL_SQLITE_TEMP_BINARY') else None
SQLITE = Path(os.environ['HL_SQLITE_TEMP_LIBRARY']) if os.environ.get('HL_SQLITE_TEMP_LIBRARY') else None
STAGE = Path(os.environ['HL_SQLITE_TEMP_STAGE']) if os.environ.get('HL_SQLITE_TEMP_STAGE') else None


@unittest.skipUnless(os.name == 'nt' and BINARY and SQLITE and STAGE and BINARY.is_file() and SQLITE.is_file(),
                     'requires the private native SQLite temp-routing fixture')
class SQLiteTempRoutingTests(unittest.TestCase):
    def check_mode(self, mode):
        for path in (BINARY, SQLITE, STAGE):
            self.assertEqual(path.resolve().drive.casefold(), 'g:')
        reserve_space(STAGE, 0)
        with temporary_work_directory(STAGE, 'HomeLibre-sqlite-temp-') as directory:
            home = Path(directory)
            (home/'sqlite-temp-regression.marker').write_text('HomeLibre SQLite temporary routing regression v1', encoding='utf-8')
            for name in ('uselocaldata', 'uselocaltemp'): (home/name).touch()
            shutil.copy2(BINARY, home/'SQLiteTempRoutingTest.exe')
            shutil.copy2(SQLITE, home/'sqlite3.dll')
            os_temp = home/'os-temp'; os_temp.mkdir()
            process = subprocess.run([str(home/'SQLiteTempRoutingTest.exe'), str(home), mode],
                cwd=home, env={**os.environ, 'TEMP':str(os_temp), 'TMP':str(os_temp)},
                capture_output=True, timeout=90,
                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
            record = dict(test=self.id(), mode=mode, returncode=process.returncode,
                          output=(process.stdout+process.stderr).decode('utf-8', errors='replace'),
                          native_sha256=hashlib.sha256(BINARY.read_bytes()).hexdigest())
            if (home/'result.json').exists():
                record['result'] = json.loads((home/'result.json').read_text(encoding='utf-8-sig'))
            with (STAGE/'invocations.jsonl').open('a', encoding='utf-8') as log:
                log.write(json.dumps(record, ensure_ascii=False)+'\n')
            self.assertEqual(process.returncode, 0, record['output'])
            self.assertEqual(record['result']['status'], 'PASS')
            self.assertEqual(list(os_temp.iterdir()), [])
        self.assertFalse(home.exists(), 'Private SQLite routing runtime remained')

    def test_connections_route_real_temp_databases_to_their_own_folders(self):
        self.check_mode('two-roots')

    def test_plan_seal_edit_and_readonly_sort_keep_the_work_root(self):
        self.check_mode('plan-store')

    def test_default_and_custom_connections_keep_writer_locks(self):
        self.check_mode('locks')

    def test_long_unicode_temp_path_has_no_system_fallback(self):
        self.check_mode('long-path')

    def test_failed_reserve_query_refuses_temp_creation_without_fallback(self):
        self.check_mode('no-fallback')

    def test_hard_exit_releases_a_live_anonymous_temp_file(self):
        for path in (BINARY, SQLITE, STAGE):
            self.assertEqual(path.resolve().drive.casefold(), 'g:')
        reserve_space(STAGE, 0)
        with temporary_work_directory(STAGE, 'HomeLibre-sqlite-temp-') as directory:
            home = Path(directory)
            (home/'sqlite-temp-regression.marker').write_text('HomeLibre SQLite temporary routing regression v1', encoding='utf-8')
            for name in ('uselocaldata', 'uselocaltemp'): (home/name).touch()
            shutil.copy2(BINARY, home/'SQLiteTempRoutingTest.exe')
            shutil.copy2(SQLITE, home/'sqlite3.dll')
            os_temp = home/'os-temp'; os_temp.mkdir()
            process = subprocess.Popen([str(home/'SQLiteTempRoutingTest.exe'), str(home), 'two-roots'],
                cwd=home, env={**os.environ, 'TEMP':str(os_temp), 'TMP':str(os_temp)},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
            observed = []
            try:
                started = time.monotonic()
                while process.poll() is None and time.monotonic()-started < 20:
                    for path in (home/'Первая папка # %').glob('sqlite-temp-*'):
                        try:
                            if path.stat().st_size >= 1024*1024: observed.append(path)
                        except FileNotFoundError: pass
                    if observed: break
                    time.sleep(.002)
                self.assertTrue(observed, 'No live on-disk spill was observed before process exit')
                self.assertIsNone(process.poll(), 'Process already exited before interruption')
                process.kill()
                output = process.communicate(timeout=15)[0].decode('utf-8', errors='replace')
                self.assertNotEqual(process.returncode, 0)
                self.assertTrue(all(not path.exists() for path in observed), 'A live anonymous spill survived process termination')
                self.assertEqual(list(os_temp.iterdir()), [])
                with (STAGE/'hard-exit.jsonl').open('a', encoding='utf-8') as log:
                    log.write(json.dumps(dict(test=self.id(), observed=[str(p) for p in observed],
                        returncode=process.returncode, output=output, spills_removed=True,
                        native_sha256=hashlib.sha256(BINARY.read_bytes()).hexdigest()))+'\n')
            finally:
                if process.poll() is None: process.kill()
                process.communicate(timeout=15)
        self.assertFalse(home.exists())

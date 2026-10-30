"""Verify a published updater using a private old catalogue and exact ZIPs.

The current native validator prepares the new ZIP. In helper mode, the unchanged
published helper installs it and starts the new catalogue. With --frontend, the
unchanged published Main restores an owned ready package and requests installation
through its normal UI, including its original PID and restart arguments. Neither
mode exercises the old network/download worker. Inspect and normally close the
production catalogue with Computer Use before the preservation checks finish.
"""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import zipfile

from verify_update_archive import version


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract(archive, target):
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None
        for name in package.namelist():
            assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
            assert '..' not in Path(name).parts
        package.extractall(target)


def books(path):
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
    try:
        columns = [row[1] for row in db.execute('PRAGMA table_info(Books)')]
        rows = db.execute('SELECT * FROM Books ORDER BY BookID').fetchall()
    finally:
        db.close()
    return dict(columns=columns, rows=rows)


def own_processes(target, environment, stop=False):
    command = ("$ErrorActionPreference='Stop'; "
               "$owned=@(Get-Process HomeLibRu,HomeLibRuUpdater -ErrorAction SilentlyContinue | "
               "Where-Object {$_.Path -eq $env:HOMELIBRE_TEST_MAIN -or $_.Path -eq $env:HOMELIBRE_TEST_HELPER}); ")
    if stop:
        command += ("foreach($item in $owned){Stop-Process -InputObject $item -Force -ErrorAction Stop; "
                    "if(-not $item.WaitForExit(15000)){throw 'Owned process did not stop'}}")
    else:
        command += "ConvertTo-Json -Compress -InputObject @($owned | Select-Object Id,Path)"
    result = subprocess.run(['powershell', '-NoProfile', '-Command', command],
        env=environment, capture_output=True, text=True, timeout=30,
        creationflags=subprocess.CREATE_NO_WINDOW)
    assert result.returncode == 0, result.stderr
    return None if stop else json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('old_archive', type=Path)
    parser.add_argument('new_archive', type=Path)
    parser.add_argument('native', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--old-sha256', required=True)
    parser.add_argument('--new-sha256', required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=1800)
    parser.add_argument('--frontend', action='store_true',
                        help='Use the published Main ready-package install/restart UI instead of its old helper')
    args = parser.parse_args()
    assert sha(args.old_archive) == args.old_sha256
    assert sha(args.new_archive) == args.new_sha256
    assert not args.report.exists()
    report = dict(status='RUNNING', scope=__doc__, old_archive_sha256=args.old_sha256,
                  new_archive_sha256=args.new_sha256, published=False)
    if args.frontend:
        report['scope'] = ('Original published Main restores an owned prepared package, validates its helper, '
            'writes the restart request and launches installation through its normal UI. '
            'The network/download frontend is not exercised.')
    temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-old37-')
    root = Path(temporary.name).resolve()
    target = root / 'HomeLibRu-native-target'
    cache = root
    if args.frontend:
        # Frozen pre5.37 ProgramUpdateCache hashes the lowercase full AppPath,
        # including its trailing directory delimiter, using SHA-256 over UTF-8.
        identity = hashlib.sha256((str(target) + '\\').lower().encode('utf-8')).hexdigest()[:20]
        cache = root / 'LocalAppData/HomeLibRu/Updates' / identity
    job = cache / 'HomeLibRu-update-job'
    helper = job / 'HomeLibRuUpdater.exe'
    environment = dict(os.environ, LOCALAPPDATA=str(root / 'LocalAppData'),
                       HOMELIBRE_TEST_MAIN=str(target / 'HomeLibRu.exe'),
                       HOMELIBRE_TEST_HELPER=str(helper))
    process = None
    try:
        target.mkdir()
        extract(args.old_archive, target)
        old_main = version(target / 'HomeLibRu.exe')
        assert old_main['product'] == '2.7.0_pre5.37', old_main
        report['old_main_version'] = old_main
        old_helper = (target / 'HomeLibRuUpdater.exe').read_bytes()
        report['old_helper_sha256'] = hashlib.sha256(old_helper).hexdigest()
        report['old_helper_version'] = version(target / 'HomeLibRuUpdater.exe')
        for name in ('uselocaldata', 'uselocaltemp'):
            (target / name).touch()
        (target / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        ini = target / 'myhomelib2.ini'
        ini.write_text('[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[INTERFACE]\nLocale=ru\nWindowsDarkThemeOfferDismissed=1\n'
            '[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\nAutoLoadReview=0\nIgnoreAbsentArchives=1\n'
            '[UpdateProbe]\nProtectedValue=Preserve personal settings ё\n', encoding='utf-8')
        fixture = target / 'CollectionViewsTest.exe'
        shutil.copyfile(args.fixture, fixture)
        genres = target / 'genres_fb2.glst'
        shim = not genres.exists()
        if shim:
            shutil.copyfile(target / 'tools/genres/genres_fb2.glst', genres)
        try:
            setup = subprocess.run([str(fixture), 'publisher-selection'], cwd=target,
                env=environment, capture_output=True, timeout=90,
                creationflags=subprocess.CREATE_NO_WINDOW)
            assert setup.returncode == 0, setup.stdout[-3000:]
        finally:
            if shim:
                genres.unlink()
        protected = target / 'Data/protected-update-probe.txt'
        protected.write_text('Personal data must survive the old updater ё', encoding='utf-8')
        protected_hash = sha(protected)
        before_books = books(target / 'Data/one.hlc2')
        archive = root / 'release.zip'
        shutil.copyfile(args.new_archive, archive)
        with zipfile.ZipFile(archive) as package:
            manifest = json.loads(package.read('HomeLibRu.update.json'))
        native = subprocess.run([str(args.native.resolve()), '--prepare', str(archive),
            args.new_sha256, manifest['release'], str(job)], cwd=root, env=environment,
            capture_output=True, text=True, encoding='utf-8', timeout=180,
            creationflags=subprocess.CREATE_NO_WINDOW)
        assert native.returncode == 0, native.stdout + native.stderr
        shutil.copyfile(archive, job / 'release.zip')
        report.update(platform=manifest['platform'], tag=manifest['release'], root=str(root))
        if args.frontend:
            ready = dict(job=str(job), tag=manifest['release'], sha256=args.new_sha256,
                url='https://github.com/Dicur3x/MyHomeLib/releases/tag/' + manifest['release'],
                notes='Проверка готового обновления HomeLibre на отдельной копии.',
                component='', version='', size=archive.stat().st_size)
            (cache / 'ready.json').write_text(json.dumps(ready, ensure_ascii=False), encoding='utf-8')
            process = subprocess.Popen([str(target / 'HomeLibRu.exe')], cwd=target,
                env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            old_pid, request = process.pid, None
            report['published_main_pid'] = old_pid
            print(json.dumps(dict(report, stage='inspect-published-main-ready')), flush=True)
            started = time.monotonic()
            while process.poll() is None:
                assert time.monotonic() - started < args.timeout, 'Install the ready update from the old Main UI'
                path = job / 'request.json'
                if path.exists():
                    try:
                        request = json.loads(path.read_text('utf-8-sig'))
                    except (OSError, json.JSONDecodeError):
                        pass
                if helper.exists() and 'launched_helper_sha256' not in report:
                    report['launched_helper_sha256'] = sha(helper)
                time.sleep(.1)
            assert process.returncode == 0 and request is not None, 'Old Main closed without requesting installation'
            assert request['pid'] == old_pid and request['application'] == 'HomeLibRu.exe'
            assert request['tag'] == manifest['release'] and request['sha256'] == args.new_sha256
            assert Path(request['target']).resolve() == target
            expected_helper = next(x['sha256'] for x in manifest['files'] if x['path'] == 'HomeLibRuUpdater.exe')
            assert report.get('launched_helper_sha256') == expected_helper
            report.update(published_main_exit=0, original_frontend_request_verified=True)
            deadline = time.monotonic() + 180
            while not (cache / 'result.txt').is_file():
                assert time.monotonic() < deadline, 'Prepared helper has not reported installation'
                time.sleep(.1)
        else:
            helper.write_bytes(old_helper)
            assert sha(helper) == report['old_helper_sha256']
            request = dict(target=str(target), pid=0, tag=manifest['release'],
                           sha256=args.new_sha256, args=[], application='HomeLibRu.exe')
            (job / 'request.json').write_text(json.dumps(request), encoding='utf-8')
            process = subprocess.Popen([str(helper), '--job', str(job)], cwd=job,
                env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(json.dumps(dict(report, stage='published-helper-running', pid=process.pid)), flush=True)
            assert process.wait(timeout=180) == 0, 'Published helper rejected the update'
            assert json.loads((job / 'journal.json').read_text('utf-8-sig'))['state'] == 'installed'
            report['helper_exit'] = 0
        report['helper_result'] = (cache / 'result.txt').read_text('utf-8-sig')
        assert manifest['release'] in report['helper_result']
        running = own_processes(target, environment)
        assert len(running) == 1 and running[0]['Path'].lower() == str(target / 'HomeLibRu.exe').lower(), running
        report['restarted_main_pid'] = running[0]['Id']
        print(json.dumps(dict(stage='inspect-restarted-catalogue', **report)), flush=True)
        started = time.monotonic()
        while own_processes(target, environment):
            assert time.monotonic() - started < args.timeout, 'Close the restarted test catalogue normally'
            time.sleep(1)
        for entry in manifest['files']:
            path = target / entry['path']
            assert path.stat().st_size == entry['size'] and sha(path) == entry['sha256'], entry['path']
        assert sha(protected) == protected_hash
        assert books(target / 'Data/one.hlc2') == before_books
        options = configparser.ConfigParser(interpolation=None, strict=False)
        options.read_string(ini.read_text('utf-8-sig'))
        assert options['UpdateProbe']['ProtectedValue'] == 'Preserve personal settings ё'
        report.update(status='PASS', managed_files_verified=len(manifest['files']),
            catalogue_books_preserved=len(before_books['rows']), personal_sentinel_preserved=True,
            personal_settings_preserved=True, new_main_version=version(target / 'HomeLibRu.exe'))
    except BaseException as error:
        report.update(status='FAIL', error=repr(error))
        raise
    finally:
        try:
            own_processes(target, environment, stop=True)
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=15)
            assert root.parent == Path(tempfile.gettempdir()).resolve()
            assert root.name.startswith('HomeLibRu-update-test-old37-')
            temporary.cleanup()
        finally:
            report['temporary_payloads_removed'] = not root.exists()
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2,
                default=lambda value: value.hex() if isinstance(value, bytes) else str(value)) + '\n', encoding='utf-8')
    print('PASS published updater, restarted production catalogue and preserved personal data:', report['platform'])


if __name__ == '__main__':
    main()

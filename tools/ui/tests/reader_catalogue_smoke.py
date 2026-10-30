"""Manually drive ordinary Main/Reader EXEs in a disposable tiny catalogue.

Computer Use operates the windows. This script only creates owned files and
observes replies. Package download/helper installation is covered separately;
here the verified reader payload is installed between two ordinary Main runs.
"""
from pathlib import Path
import argparse
import configparser
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'tools/ui/tests/Out'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_ini(path):
    value = configparser.ConfigParser(interpolation=None, strict=False)
    value.optionxform = str
    value.read_string(path.read_text('utf-8-sig'))
    return value


def save_ini(path, value):
    with path.open('w', encoding='utf-8') as stream:
        value.write(stream, space_around_delimiters=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('architecture', choices=['x86', 'x64'])
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--catalogue-archive', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--timeout', type=float, default=600,
                        help='Maximum seconds for each Computer Use phase')
    args = parser.parse_args()
    platform = 'Win64' if args.architecture == 'x64' else 'Win32'
    runtime = ROOT / 'Program/Out' / ('Bin64' if platform == 'Win64' else 'Bin')
    fixture = args.fixture or OUT / platform / 'CollectionViewsTest.exe'
    report = args.report.resolve()
    assert not report.exists(), report
    package_info = next(x for x in json.loads((args.packages / 'reader-component-report.json').read_text())
                        if x['platform'] == platform and x['component'] == 'HomeLibReader')
    package = Path(package_info['archive'])
    assert digest(package) == package_info['sha256']
    with zipfile.ZipFile(package) as archive:
        package_info['exe_sha256'] = hashlib.sha256(archive.read('HomeLibReader.exe')).hexdigest()
    info = {'architecture': args.architecture, 'scope': 'Ordinary production EXEs, owned tiny catalogue. '
            'Missing-core offer and saved-session resume after verified payload installation. '
            'Does not exercise a GitHub download or the updater restart helper.'}
    processes = []
    temp = tempfile.TemporaryDirectory(prefix='HomeLibRu-native-reader-main-')
    folder = Path(temp.name).resolve()
    assert folder.parent == Path(tempfile.gettempdir()).resolve()
    environment = dict(os.environ, LOCALAPPDATA=str(folder / 'LocalAppData'))
    try:
        if args.catalogue_archive:
            with zipfile.ZipFile(args.catalogue_archive) as archive:
                assert archive.testzip() is None
                for name in archive.namelist():
                    assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
                    assert '..' not in Path(name).parts, name
                archive.extractall(folder)
            assert digest(folder / 'HomeLibRu.exe') == digest(runtime / 'HomeLibRu.exe')
            info['catalogue_archive_sha256'] = digest(args.catalogue_archive)
        else:
            for file in runtime.iterdir():
                if file.is_file() and (file.suffix.lower() in ('.dll', '.glst') or file.name == 'HomeLibRu.exe'):
                    shutil.copyfile(file, folder / file.name)
            shutil.copytree(runtime / 'Icons', folder / 'Icons')
        shutil.copyfile(fixture, folder / 'CollectionViewsTest.exe')
        for name in ('uselocaldata', 'uselocaltemp'):
            (folder / name).write_text('')
        (folder / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf8')
        ini = folder / 'myhomelib2.ini'
        ini.write_text('[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
                       '[INTERFACE]\nLocale=ru\nWindowsDarkThemeOfferDismissed=1\n'
                       '[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\nAutoLoadReview=0\n'
                       'IgnoreAbsentArchives=1\nUseBuiltinReaderByDefault=1\n', encoding='utf8')
        # The reusable catalogue fixture still imports a root genre file. Its
        # one-off input must not change the packaged application's layout.
        fixture_genres = folder / 'genres_fb2.glst'
        genre_shim = not fixture_genres.exists()
        if genre_shim:
            shutil.copyfile(folder / 'tools/genres/genres_fb2.glst', fixture_genres)
        try:
            setup = subprocess.run([str(folder / 'CollectionViewsTest.exe'), 'publisher-selection'],
                                   cwd=folder, env=environment, capture_output=True, timeout=60,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        finally:
            if genre_shim:
                fixture_genres.unlink()
        info['fixture_genre_shim_removed'] = genre_shim and not fixture_genres.exists()
        assert setup.returncode == 0, setup.stdout[-3000:]
        options = read_ini(ini)
        options['BEHAVIOR']['UseBuiltinReaderByDefault'] = '1'
        save_ini(ini, options)
        if not args.catalogue_archive:
            shutil.copyfile(ROOT / 'Installer/Components.json', folder / 'COMPONENTS.json')
        source = folder / 'Alpha ru.fb2'
        body = ''.join('<p>Проверка отдельной читалки. Абзац ' + str(i) +
                       '. Книга открывается из каталога, позиция возвращается в карточку.</p>' for i in range(500))
        source.write_text('<?xml version="1.0" encoding="utf-8"?>'
                          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
                          '<description><title-info><book-title>Alpha ru</book-title><lang>ru</lang>'
                          '</title-info></description><body><section><title><p>Проверка читалки</p>'
                          '</title>' + body + '</section></body></FictionBook>', encoding='utf8')
        source_hash = digest(source)
        info.update(profile=str(folder), main_sha256=digest(folder / 'HomeLibRu.exe'),
                    reader_sha256=package_info['exe_sha256'], source_sha256=source_hash)

        def book_progress():
            database = folder / 'Data/one.hlc2'
            assert database.is_file() and database.stat().st_size > 0, database
            db = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
            try:
                # The catalogue's locale-aware collation belongs to Delphi.
                # This fixture has one exact ASCII title, so compare its bytes.
                rows = db.execute('SELECT BookID,Title,Progress FROM Books '
                                  'WHERE Title COLLATE BINARY=?', ('Alpha ru',)).fetchall()
            finally:
                db.close()
            assert len(rows) == 1, rows
            return rows[0][2]

        assert book_progress() == 0, 'Fixture already has a reading position'

        def launch():
            app = subprocess.Popen([str(folder / 'HomeLibRu.exe')], cwd=folder, env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(app)
            return app

        app = launch()
        print(json.dumps(dict(info, stage='missing-reader-offer', pid=app.pid)), flush=True)
        started = time.monotonic()
        saved = None
        request_path = None
        while app.poll() is None and time.monotonic() - started < args.timeout:
            for path in folder.rglob('request.json'):
                if path.parent.name.startswith('HomeLibReader-session-'):
                    value = json.loads(path.read_text('utf-8-sig'))
                    if value.get('kind') == 'HomeLibReader-session':
                        saved, request_path = value, path
            time.sleep(.1)
        assert app.poll() == 0 and saved is not None, 'Close the missing-reader offer and Main after opening Alpha ru'
        assert saved['book']['title'] == 'Alpha ru' and saved['source'] == str(source)
        info['missing_core_session_created'] = True
        assert digest(source) == source_hash
        # Main correctly removes an uninstalled, unsaved pending request.
        assert not request_path.exists()
        with zipfile.ZipFile(package) as archive:
            for entry in archive.infolist():
                if entry.filename == 'HomeLibRu.update.json':
                    continue
                target = (folder / entry.filename).resolve()
                assert target.is_relative_to(folder) and not entry.is_dir()
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
        assert digest(folder / 'HomeLibReader.exe') == info['reader_sha256']
        request_path.parent.mkdir(parents=True)
        request_path.write_text(json.dumps(saved, ensure_ascii=False), encoding='utf8')
        options = read_ini(ini)
        if not options.has_section('ReaderSession'):
            options.add_section('ReaderSession')
        options['ReaderSession']['PendingCatalogueRequest'] = str(request_path)
        save_ini(ini, options)
        app = launch()
        print(json.dumps(dict(info, stage='resume-installed-reader', pid=app.pid,
                              request=str(request_path))), flush=True)
        started = time.monotonic()
        displaying = False
        while app.poll() is None and time.monotonic() - started < args.timeout:
            response = request_path.with_name('response.json')
            if response.exists():
                try:
                    reply = json.loads(response.read_text('utf-8-sig'))
                    if reply.get('state') == 'displaying':
                        displaying = True
                    if reply.get('state') == 'failed':
                        raise AssertionError(reply)
                except (OSError, json.JSONDecodeError):
                    pass  # Atomic replacement can occur between existence and read.
            time.sleep(.1)
        assert app.poll() == 0 and displaying, 'Turn pages, close the reader, then close Main normally'
        assert digest(source) == source_hash
        assert not request_path.exists(), 'Completed session JSON was retained'
        options = read_ini(ini)
        assert not options.has_option('ReaderSession', 'PendingCatalogueRequest')
        progress = book_progress()
        assert progress > 0, progress
        info.update(status='PASS', resumed_book_progress=progress, source_preserved=True,
                    completed_session_removed=True, pending_key_consumed=True)
    except BaseException as error:
        info.update(status='FAIL', error=repr(error))
        raise
    finally:
        # Only the exact processes and directory created by this invocation.
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
        assert folder.resolve().parent == Path(tempfile.gettempdir()).resolve()
        assert folder.name.startswith('HomeLibRu-native-reader-main-')
        # Reader may still be open when Main times out. Never select another
        # installation: this path belongs to this invocation's private root.
        cleanup_environment = dict(environment, HOMELIBRE_TEST_READER=str(folder / 'HomeLibReader.exe'))
        try:
            stopped = subprocess.run(['powershell', '-NoProfile', '-Command',
                "$ErrorActionPreference='Stop'; "
                "$ownedReaders=@(Get-Process HomeLibReader -ErrorAction SilentlyContinue | "
                "Where-Object {$_.Path -eq $env:HOMELIBRE_TEST_READER}); "
                "foreach($ownedReader in $ownedReaders){"
                "Stop-Process -InputObject $ownedReader -Force -ErrorAction Stop; "
                "if(-not $ownedReader.WaitForExit(15000)){throw 'Owned reader did not exit'}}"],
                env=cleanup_environment, capture_output=True, timeout=30,
                creationflags=subprocess.CREATE_NO_WINDOW)
            assert stopped.returncode == 0, stopped.stderr.decode(errors='replace')
            temp.cleanup()
        finally:
            info['own_profile_removed'] = not folder.exists()
            report.write_text(json.dumps(info, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    assert not folder.exists()
    info['own_profile_removed'] = True
    report.write_text(json.dumps(info, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    print(json.dumps(info, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()

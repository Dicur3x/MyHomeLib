"""Inspect real Main/Reader windows after the owned FLibrary compression fixture.

Computer Use opens, pages and reopens the books; this module observes sessions
and persisted positions. It never supplies synthetic reader replies or input.
"""
from contextlib import closing
import configparser
import ctypes
from ctypes import wintypes
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ini(path):
    value = configparser.ConfigParser(interpolation=None, strict=False)
    value.optionxform = str
    value.read(path, encoding='utf-8-sig')
    return value


def positions(path):
    value = ini(path)
    return {value.get(section, 'Title'): value.getint(section, 'Position')
            for section in value.sections() if section.startswith('Book.')
            and value.has_option(section, 'Title') and value.has_option(section, 'Position')}


def inspect(root, runtime, platform, report_path, environment, timeout=600):
    root, runtime = root.resolve(strict=True), runtime.resolve(strict=True)
    assert root.name.startswith('HomeLibRu-native-')
    assert (root / 'native-regression.marker').read_text() == 'HomeLib Ru isolated native regression v1'
    assert all((root / name).is_file() for name in ('uselocaldata', 'uselocaltemp'))
    expected_machine = 0x8664 if platform == 'Win64' else 0x14c
    binaries = {}
    for name in ('HomeLibre.exe', 'HomeLibreReader.exe'):
        source = runtime / name
        body = source.read_bytes()
        offset, = struct.unpack_from('<I', body, 0x3c)
        assert body[:2] == b'MZ' and body[offset:offset+4] == b'PE\0\0'
        assert struct.unpack_from('<H', body, offset+4)[0] == expected_machine
        if (root / name).exists():
            # The encoder-install fixture temporarily uses the native test EXE
            # as its catalogue identity. Replace only that exact owned payload.
            assert name == 'HomeLibre.exe' and not (root / name).is_symlink()
            assert sha(root / name) == sha(root / 'CollectionViewsTest.exe')
        shutil.copy2(source, root / name)
        binaries[name] = sha(source)
    for name in ('HomeLibRuUpdater.exe', 'HomeLibReader-LICENSE.txt', 'NOTICE',
                 'tools/fonts/manifest.json'):
        source, target = runtime / name, root / name
        if target.exists():
            assert not target.is_symlink() and sha(target) == sha(source), name
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        binaries[name] = sha(source)
    personal = root / 'Data/user.dbs2'
    collection_name = ('Bound FLibrary compression' if (root / 'reviewed-flibrary-bound.marker').exists()
                       else 'Original FLibrary EPUB')
    with closing(sqlite3.connect(personal.as_uri() + '?mode=ro', uri=True)) as db:
        rows = db.execute('SELECT DatabaseID, DBFileName FROM Bases WHERE BaseName COLLATE BINARY=?',
                          (collection_name,)).fetchall()
    assert len(rows) == 1, rows
    collection_id, database_name = rows[0]
    candidates = [Path(database_name)] if Path(database_name).is_absolute() else [
        root / 'Data' / database_name, root / database_name]
    catalogues = [path.resolve() for path in candidates if path.is_file()]
    assert len(catalogues) == 1, candidates
    catalogue = catalogues[0]
    assert catalogue.is_relative_to(root)
    titles = ['FLibrary 101 corrected', 'FLibrary 301 corrected']
    with closing(sqlite3.connect(catalogue.as_uri() + '?mode=ro', uri=True)) as db:
        cards = {title: db.execute('SELECT BookID, BookSize, Review, Progress FROM Books '
                    'WHERE Title COLLATE BINARY=?', (title,)).fetchall() for title in titles}
    assert all(len(rows) == 1 for rows in cards.values()), cards
    protected = {path: sha(path) for base in (root / 'packing-flibrary-epub/source',
                  root / 'reviewed-sidecars-downloads') for path in base.rglob('*') if path.is_file()}
    settings = root / 'myhomelib2.ini'
    options = ini(settings)
    for section, values in {
        'SYSTEM': {'ActiveCollection': str(collection_id), 'CheckUpdates': '0',
                   'CheckLibrusecUpdates': '0', 'ProgramCheckMinutes': '0'},
        'INTERFACE': {'ActivePage': '0', 'WindowsDarkThemeOfferDismissed': '1'},
        'BEHAVIOR': {'UseBuiltinReaderByDefault': '1', 'CoverPanel': '1',
                     'ShowCover': '1', 'ShowAnnotation': '0', 'AutoLoadReview': '0'},
    }.items():
        if not options.has_section(section):
            options.add_section(section)
        for key, value in values.items():
            options.set(section, key, value)
    with settings.open('w', encoding='utf-8') as output:
        options.write(output, space_around_delimiters=False)

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                                wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    reader_handles, sessions = {}, {}
    result = dict(status='INSPECTING', platform=platform, root=str(root), binaries=binaries,
                  catalogue=str(catalogue), expected_titles=titles, sessions=sessions)
    report_path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    app = subprocess.Popen([str(root / 'HomeLibre.exe')], cwd=root, env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps(dict(stage='reader-inspection', root=str(root), pid=app.pid,
                         instructions='Open/page/close 101 EPUB, then 301 FB2; reopen and close both without navigation; finally close Main.')), flush=True)
    started = time.monotonic()
    try:
        while app.poll() is None and time.monotonic() - started < timeout:
            for request_file in root.glob('**/HomeLibReader-session-*/request.json'):
                try:
                    request = json.loads(request_file.read_text('utf-8-sig'))
                    reply = json.loads(request_file.with_name('response.json').read_text('utf-8-sig'))
                except (OSError, json.JSONDecodeError):
                    continue
                if request.get('kind') != 'HomeLibReader-session':
                    continue
                title = request['book']['title']
                assert title in titles, ('Unexpected inspected book', title)
                assert reply['state'] not in ('failed', 'component_required'), reply
                if reply['state'] != 'displaying' or not reply.get('opened'):
                    continue
                session = sessions.get(request['id'])
                if session is None:
                    pid = reply['pid']
                    handle = kernel.OpenProcess(0x100000 | 0x1000 | 1, False, pid)
                    assert handle, ctypes.get_last_error()
                    name, length = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
                    try:
                        assert kernel.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(length))
                        assert Path(name.value).resolve() == root / 'HomeLibreReader.exe'
                    except BaseException:
                        kernel.CloseHandle(handle)
                        raise
                    reader_handles[request['id']] = handle
                    session = sessions[request['id']] = dict(title=title, pid=pid, request=str(request_file),
                        settings=request['settings'], initial_progress=reply.get('progress'),
                        initial_positions=positions(request['settings']))
                    print(json.dumps(dict(stage='reader-displaying', **session)), flush=True)
                session['last_progress'] = reply.get('progress')
            for identity, session in sessions.items():
                if 'closed_position' not in session and (not Path(session['request']).exists()
                        or kernel.WaitForSingleObject(reader_handles[identity], 0) == 0):
                    session['closed_position'] = positions(session['settings']).get(session['title'])
                    print(json.dumps(dict(stage='reader-closed', **session)), flush=True)
            report_path.write_text(json.dumps(result, indent=2), encoding='utf-8')
            time.sleep(.1)
        assert app.poll() == 0, 'Close the inspected Main normally within the inspection deadline'
        for title in titles:
            entries = [entry for entry in sessions.values() if entry['title'] == title]
            assert len(entries) == 2, (title, entries)
            first, second = entries
            assert first['closed_position'] > 0, first
            assert second['initial_positions'].get(title) == first['closed_position'], (first, second)
            assert second['closed_position'] == first['closed_position'], (first, second)
            # A displaying reply can omit progress until navigation occurs.
            # Persisted position above and the catalogue progress below are the
            # authoritative checks for a reopen without further page changes.
            if second['initial_progress'] is not None:
                assert isinstance(second['initial_progress'], int) and second['initial_progress'] > 0, second
            with closing(sqlite3.connect(catalogue.as_uri() + '?mode=ro', uri=True)) as db:
                after = db.execute('SELECT BookSize, Review, Progress FROM Books WHERE BookID=?',
                                   (cards[title][0][0],)).fetchone()
            assert after[:2] == cards[title][0][1:3] and after[2] > 0, after
        assert all(sha(path) == before for path, before in protected.items())
        assert all(not Path(session['request']).exists() for session in sessions.values())
        result.update(status='PASS', actual_main_exit=app.returncode, archives_preserved=True,
                      exact_reopened_positions=True)
        return result
    except BaseException as error:
        result.update(status='FAIL', error=repr(error))
        raise
    finally:
        if app.poll() is None:
            app.terminate()
            app.wait(timeout=15)
        for handle in reader_handles.values():
            if kernel.WaitForSingleObject(handle, 0) != 0:
                assert kernel.TerminateProcess(handle, 1)
                assert kernel.WaitForSingleObject(handle, 15000) == 0
            kernel.CloseHandle(handle)
        report_path.write_text(json.dumps(result, indent=2), encoding='utf-8')

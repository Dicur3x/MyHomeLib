"""Inspect real Main/Reader windows after the owned FLibrary compression fixture.

Computer Use opens, pages and reopens the books; this module observes sessions
and persisted positions. It never supplies synthetic reader replies or input.
"""
from contextlib import closing
import configparser
import ctypes
from ctypes import wintypes
import base64
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import time
from xml.etree import ElementTree
import zipfile


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


def prepared_content(path, extension):
    """Independent content witness of the complete file actually opened by Reader."""
    images, content = {}, {}
    if extension == '.epub':
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            assert len(names) == len(set(names)) and names[0] == 'mimetype'
            assert archive.getinfo('mimetype').compress_type == zipfile.ZIP_STORED
            for name in names:
                digest = hashlib.sha256(archive.read(name)).hexdigest()
                (images if name.startswith('OPS/Images/') else content)[name] = digest
    else:
        assert extension == '.fb2'
        document = ElementTree.parse(path).getroot()
        for node in list(document):
            if node.tag.rsplit('}', 1)[-1] == 'binary':
                identity = node.attrib['id']
                assert identity not in images
                images[identity] = hashlib.sha256(base64.b64decode(node.text or '')).hexdigest()
                document.remove(node)
        content['xml'] = hashlib.sha256(ElementTree.tostring(document)).hexdigest()
    assert images and content
    return dict(content=content, images=images, bytes=path.stat().st_size)


def compression_history(catalogue):
    with closing(sqlite3.connect(catalogue.as_uri() + '?mode=ro', uri=True)) as db:
        return db.execute('SELECT * FROM HomeLibreBookCompression ORDER BY FileKey,Member').fetchall()


def reader_payload(root, request):
    # The session source is the physical shared archive. The production Reader
    # reconstructs its selected complete book in the profile's managed cache.
    # These fixtures use non-placeholder library IDs and the default cache.
    book = request['book']
    identity = book['lib_id']
    assert identity and identity != '0'
    name = 'homelib-{}-{}{}'.format(book['collection_id'],
        hashlib.sha256(identity.encode('utf-8')).hexdigest()[:32], book['extension'])
    source = (root / 'Data/ReaderProfile/Data/BookCache' / name).resolve(strict=True)
    assert source.is_relative_to(root)
    origin = Path(Path(str(source) + '.origin').read_text(encoding='utf-8-sig')).resolve(strict=True)
    assert origin == Path(request['source']).resolve(strict=True), 'Prepared book belongs to another physical copy'
    assert Path(str(source) + '.source').is_file()
    return source


def inspect(root, runtime, platform, report_path, environment, timeout=600, recompress=False):
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
    source_roots = [root / 'packing-flibrary-epub/source', root / 'reviewed-sidecars-downloads']
    if (root / 'reviewed-flibrary-bound.marker').exists():
        source_roots.append(root / 'second-flibrary-source')
    assert all(base.is_dir() and base.resolve().is_relative_to(root) for base in source_roots)
    protected = {path: sha(path) for base in source_roots for path in base.rglob('*') if path.is_file()}
    recompression_ready = False
    recompression_files = None
    before_history = None
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
                  source_roots=[str(base.relative_to(root)) for base in source_roots],
                  recompression_requested=recompress,
                  catalogue=str(catalogue), expected_titles=titles, sessions=sessions)
    report_path.write_text(json.dumps(result, indent=2), encoding='utf-8')
    app = subprocess.Popen([str(root / 'HomeLibre.exe')], cwd=root, env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps(dict(stage='reader-inspection', root=str(root), pid=app.pid,
                         instructions=('Open/page/close 101 EPUB, then 301 FB2; '
                            + ('compress the first three books (101, 201, 301) with maximum quality reduction, wait for completion; '
                               if recompress else '')
                            + 'reopen and close both without navigation; finally close Main.'))), flush=True)
    started = time.monotonic()
    try:
        while app.poll() is None and time.monotonic() - started < timeout:
            if shutil.disk_usage('C:/').free < 8 * 1024**3:
                raise OSError('Inspection stopped: keep at least 8 GiB free on the system drive')
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
                    if recompress and any(entry['title'] == title for entry in sessions.values()):
                        assert recompression_ready, 'Both initial reading sessions must close before compression'
                        if recompression_files is None:
                            recompression_files = {path: sha(path) for path in protected}
                            changed = [path for path in protected if protected[path] != recompression_files[path]]
                            assert changed, 'No physical archive changed before Reader was reopened'
                            allowed_names = {'zip-epub.7z', 'zip-epub.zip', 'nested-epub.7z', 'nested-epub.zip'}
                            assert all(path.name in allowed_names and
                                not path.is_relative_to(root / 'reviewed-sidecars-downloads') for path in changed), changed
                            assert compression_history(catalogue) != before_history, 'Compression history did not change'
                            result['recompression_changed_files'] = [str(path.relative_to(root)) for path in changed]
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
                    if recompress:
                        session['request_source'] = request['source']
                        source = reader_payload(root, request)
                        session['prepared_file'] = str(source)
                        session['prepared'] = prepared_content(source, request['book']['extension'].lower())
                        assert session['prepared']['bytes'] == request['book']['size'], 'Reader opened a stale or wrongly sized cache'
                    print(json.dumps(dict(stage='reader-displaying', **session)), flush=True)
                session['last_progress'] = reply.get('progress')
            for identity, session in sessions.items():
                if 'closed_position' not in session and (not Path(session['request']).exists()
                        or kernel.WaitForSingleObject(reader_handles[identity], 0) == 0):
                    session['closed_position'] = positions(session['settings']).get(session['title'])
                    print(json.dumps(dict(stage='reader-closed', **session)), flush=True)
            if recompress and not recompression_ready and len(sessions) == 2 and all(
                    entry.get('closed_position', 0) > 0 for entry in sessions.values()):
                assert {entry['title'] for entry in sessions.values()} == set(titles)
                assert all(sha(path) == before for path, before in protected.items()), 'Sources changed during initial reading'
                before_history = compression_history(catalogue)
                recompression_ready = True
                print(json.dumps(dict(stage='ready-for-recompression', titles=titles)), flush=True)
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
            assert after[1] == cards[title][0][2] and after[2] > 0, after
            if recompress:
                assert second['prepared']['content'] == first['prepared']['content'], 'Compression changed non-image content'
                assert second['prepared']['images'].keys() == first['prepared']['images'].keys(), 'Compression lost images'
                assert after[0] == second['prepared']['bytes'] <= first['prepared']['bytes'], after
            else:
                assert after[0] == cards[title][0][1], after
        if recompress:
            assert recompression_files is not None
            assert any([entry for entry in sessions.values() if entry['title'] == title][0]['prepared']['images'] !=
                       [entry for entry in sessions.values() if entry['title'] == title][1]['prepared']['images'] for title in titles), \
                'The new compression did not change any image payload'
            assert all(sha(path) == before for path, before in recompression_files.items())
            result.update(preexisting_positions_survived_compression=True, non_image_content_preserved=True,
                          archives_preserved_after_recompression=True)
        else:
            assert all(sha(path) == before for path, before in protected.items())
            result['archives_preserved'] = True
        assert all(not Path(session['request']).exists() for session in sessions.values())
        result.update(status='PASS', actual_main_exit=app.returncode,
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

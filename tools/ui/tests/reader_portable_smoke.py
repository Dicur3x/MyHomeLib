"""Stage/validate actual reader EXEs; open/close the windows with Computer Use."""
import argparse
import configparser
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import zipfile

REPO = Path(__file__).resolve().parents[3]
STATE = REPO / 'tools/ui/tests/Out/pre535-reader-portable-smoke-state.json'
OWNER = 'HomeLibRu portable reader actual EXE smoke v1'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(state):
    STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def owned(state):
    root = Path(state['root'])
    if (root.parent.resolve() != Path(tempfile.gettempdir()).resolve() or
            not root.name.startswith('HomeLibRu-reader-portable-') or root.is_symlink() or root.is_junction()):
        raise ValueError('Unexpected test root')
    if json.loads((root / 'owned-test.marker').read_text(encoding='utf-8')) != dict(owner=OWNER, token=state['token']):
        raise ValueError('Test ownership marker mismatch')
    return root


def alive(pid):
    dll = ctypes.WinDLL('kernel32', use_last_error=True)
    dll.OpenProcess.restype = ctypes.c_void_p
    handle = dll.OpenProcess(0x100000, False, pid)
    if not handle:
        return False
    try:
        dll.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        return dll.WaitForSingleObject(handle, 0) == 258
    finally:
        dll.CloseHandle.argtypes = [ctypes.c_void_p]
        dll.CloseHandle(handle)


def snapshot(directory):
    return {str(path.relative_to(directory)): sha(path) for path in directory.rglob('*') if path.is_file()}


def load_or_create():
    if STATE.exists():
        state = json.loads(STATE.read_text(encoding='utf-8'))
        owned(state)
        return state
    root = Path(tempfile.mkdtemp(prefix='HomeLibRu-reader-portable-'))
    state = dict(root=str(root), token=uuid.uuid4().hex, runs=[])
    (root / 'owned-test.marker').write_text(json.dumps(dict(owner=OWNER, token=state['token'])), encoding='utf-8')
    old = root / 'old-appdata/HomeLibReader/Data'
    old.mkdir(parents=True)
    (old.parent / 'HomeLibReader.ini').write_text('[Reader]\nPreviousProfile=Keep original ё\n', encoding='utf-8-sig')
    (old / 'reader.ini').write_text('[Bookmarks.old]\nCount=1\nTitle0=Старая закладка\n', encoding='utf-8-sig')
    (old / 'reader-notes.json').write_text('{"previous":"Старая заметка"}', encoding='utf-8')
    state['old_sha256'] = snapshot(root / 'old-appdata')
    (root / 'cwd').mkdir()
    source = root / 'Книга для проверки ё.fb2'
    source.write_text('<?xml version="1.0" encoding="UTF-8"?>'
                      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
                      '<description><title-info><book-title>Portable path test</book-title><lang>ru</lang></title-info></description>'
                      '<body><section><title><p>Проверка портативного запуска</p></title>' +
                      ''.join('<p>Настройки и история этой книги должны оставаться рядом с читалкой. Абзац %d.</p>' % i for i in range(40)) +
                      '</section></body></FictionBook>', encoding='utf-8')
    state['source'] = str(source)
    state['source_sha256'] = sha(source)
    save(state)
    return state


def launch(state, arch, mode, packed, package=None, save_copy=False):
    root = owned(state)
    if any(alive(run['pid']) for run in state['runs']):
        raise ValueError('Close the previous test reader normally before the next case')
    runtime = REPO / 'Program/Out' / ('Bin' if arch == 'Win32' else 'Bin64')
    app = root / arch
    if not app.exists():
        app.mkdir()
        if package:
            with zipfile.ZipFile(package) as archive:
                manifest = json.loads(archive.read('HomeLibRu.update.json'))
                assert manifest['component'] == 'HomeLibReader' and manifest['platform'] == arch
                assert len(archive.namelist()) == len(set(archive.namelist()))
                assert set(archive.namelist()) == {item['path'] for item in manifest['files']} | {'HomeLibRu.update.json'}
                for item in manifest['files']:
                    relative = Path(item['path'])
                    assert not relative.is_absolute() and not any(p in ('.','..') for p in relative.parts)
                    assert not item['path'].startswith(('tools/doc/','tools/djvu/','tools/bookconvert/','tools/kindle/','Readers/'))
                    data = archive.read(item['path'])
                    assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
                    target = app / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
            state.setdefault('packages', {})[arch] = {'archive':str(package.resolve()),'sha256':sha(package)}
        else:
            shutil.copy2(REPO / f'Utils/HomeLibReader/Out/{arch}/HomeLibReader.exe', app / 'HomeLibReader.exe')
            shutil.copy2(REPO / 'LICENSE', app / 'HomeLibReader-LICENSE.txt')
            for name in ('sqlite3.dll', 'libzstd.dll', 'NOTICE', 'HomeLibRuUpdater.exe'):
                shutil.copy2(runtime / name, app / name)
            (app / 'tools/fonts').mkdir(parents=True)
            shutil.copy2(runtime / 'tools/fonts/manifest.json', app / 'tools/fonts/manifest.json')
    if (app / 'uselocaldata').exists():
        raise ValueError('Actual smoke must not depend on the portable marker')
    profile = app if mode == 'default' else root / (arch + '-explicit')
    destination = None
    if save_copy:
        assert not packed, 'This source-copy check requires a direct FB2 input'
        profile.mkdir(parents=True, exist_ok=True)
        destination = root / ('saved-' + arch + '-' + mode)
        destination.mkdir(exist_ok=False)
        settings = configparser.ConfigParser(interpolation=None, strict=False)
        settings.optionxform = str
        ini = profile / 'HomeLibReader.ini'
        if ini.exists():
            settings.read_string(ini.read_text('utf-8-sig'))
        for section in ('SYSTEM', 'PATH'):
            if not settings.has_section(section):
                settings.add_section(section)
        settings['SYSTEM'].update(CheckUpdates='0', FileNameTemplate='Copy - %t', SaveAsUseSubfolders='0')
        settings['PATH']['SyncExport'] = str(destination)
        with ini.open('w', encoding='utf-8') as stream:
            settings.write(stream, space_around_delimiters=False)
    source = Path(state['source'])
    if packed:
        archive = source.with_suffix('.zip')
        if not archive.exists():
            with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as output:
                output.write(source, source.name)
        source = archive
    command = [str(app / 'HomeLibReader.exe'), '--open=' + str(source)]
    if mode == 'explicit':
        command.append('--profile=' + str(profile))
    local_before = snapshot(app / 'Data') if mode == 'explicit' else None
    env = dict(os.environ, APPDATA=str(root / 'old-appdata'))
    process = subprocess.Popen(command, cwd=root / 'cwd', env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    record = dict(arch=arch, mode=mode, pid=process.pid, app=str(app), profile=str(profile),
                  exe_sha256=sha(app / 'HomeLibReader.exe'), checked=False, packed=packed)
    if save_copy:
        record.update(save_copy_destination=str(destination), destination_prefilled_in_owned_profile=True)
    if mode == 'explicit':
        record['local_before'] = local_before
    state['runs'].append(record)
    save(state)
    print(json.dumps(record, ensure_ascii=False))


def check(state):
    root = owned(state)
    run = state['runs'][-1]
    if alive(run['pid']):
        raise ValueError('Reader is still running; close it normally with Computer Use')
    profile = Path(run['profile'])
    for relative in ('HomeLibReader.ini', 'Data/reader-user.dbs2', 'Data/reader.ini'):
        if not (profile / relative).is_file():
            raise ValueError('Missing actual portable profile file: ' + relative)
    text = (profile / 'Data/reader.ini').read_text(encoding='utf-8-sig')
    if '[Book.' not in text or Path(state['source']).stem not in text:
        raise ValueError('Reader did not save the actual opened book history')
    cache_created = (profile / 'Data/BookCache').is_dir()
    if run.get('packed', False) and not cache_created:
        raise ValueError('Default book cache is not under the selected profile')
    if snapshot(root / 'old-appdata') != state['old_sha256'] or sha(state['source']) != state['source_sha256']:
        raise ValueError('Original AppData history/notes or source book changed')
    if run['mode'] == 'explicit' and snapshot(Path(run['app']) / 'Data') != run['local_before']:
        raise ValueError('Explicit profile changed the default portable profile')
    if run.get('save_copy_destination'):
        files = list(Path(run['save_copy_destination']).rglob('*'))
        files = [p for p in files if p.is_file()]
        assert len(files)==1 and files[0].suffix=='.fb2' and sha(files[0])==state['source_sha256'], 'Expected one unchanged FB2 copy'
        assert all(not (Path(run['app'])/'tools'/name).exists() for name in ('bookconvert','images','kindle','office','xps','pdfium','djvu','doc'))
        run.update(unchanged_fb2_copy_verified=True, optional_format_modules_absent=True,
                   copy_name=files[0].name, copy_sha256=sha(files[0]))
    run['checked'] = True
    save(state)
    run['cache_created'] = cache_created
    save(state)
    print('PASS actual reader', run['arch'], run['mode'], 'local settings/history, cache_created=', cache_created,
          '; previous AppData and source unchanged')


def cleanup(state):
    root = owned(state)
    if not state['runs'] or any(not run['checked'] or alive(run['pid']) for run in state['runs']):
        raise ValueError('All started actual EXE cases must finish before cleanup')
    if any(p.is_symlink() or p.is_junction() for p in root.rglob('*')):
        raise ValueError('Unexpected linked path in owned test root')
    state['removed_bytes'] = sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
    shutil.rmtree(root)
    state['temporary_root_removed'] = True
    save(state)
    print('PASS removed only owned actual-reader smoke runtime, bytes=', state['removed_bytes'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('launch', 'check', 'cleanup'))
    parser.add_argument('--arch', choices=('Win32', 'Win64'))
    parser.add_argument('--mode', choices=('default', 'explicit'))
    parser.add_argument('--packed', action='store_true')
    parser.add_argument('--state', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--save-copy', action='store_true', help='Prefill own folder, require one real GUI-created unchanged FB2 copy')
    options = parser.parse_args()
    if options.state:
        STATE = options.state.resolve()
    state = load_or_create()
    if options.action == 'launch':
        launch(state, options.arch, options.mode, options.packed, options.archive, options.save_copy)
    elif options.action == 'check':
        check(state)
    else:
        cleanup(state)

"""Own real-Reader fixtures; all interactive actions are performed by Computer Use.

The helper's ordinary --job interface exercises production update coordination.
No window input or forced process termination is implemented by this harness.
Development binaries retain their current version: these are not release packages.
"""
import argparse
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
WORK = Path('G:/HomeLibRu-build-cache')
OWNER = 'HomeLibre real Reader coordinated update v1'
PACKAGES = WORK / 'HomeLibre-3beta1-release-20261030-r1/reader-r4'
PACKAGE_HASH = {
    'Win32': '18a44806373e49c3cd40fd16713c4ed8df4d9b7aed540322e8a35b83ac71ea87',
    'Win64': '6dfafddfc3eeb38da8271ba8de1d9589c61288e89d71a47c9f71ebbf74ad9ea0',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def processes(root):
    query = "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); Get-CimInstance Win32_Process -Filter \"Name='HomeLibReader.exe' OR Name='HomeLibRuUpdater.exe'\" | Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress"
    raw = subprocess.check_output(['powershell', '-NoProfile', '-NonInteractive', '-Command', query],
                                 encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW)
    entries = json.loads(raw) if raw.strip() else []
    entries = [entries] if isinstance(entries, dict) else entries
    return [p for p in entries if p.get('ExecutablePath') and Path(p['ExecutablePath']).is_relative_to(root)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'launch', 'inspect', 'record-selection', 'install', 'check', 'check-saved-copy', 'cleanup', 'cleanup-incomplete'))
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--platform', choices=PACKAGE_HASH)
    parser.add_argument('--label', choices=('peer', 'caller'))
    parser.add_argument('--seed-recent', action='store_true', help='Seed own public recent-file settings for a File-menu change test')
    parser.add_argument('--seed-save-folder', action='store_true', help='Seed the own output folder through ordinary public settings')
    parser.add_argument('--archive-session', action='store_true', help='Use a catalogue locator for the second archive member')
    args = parser.parse_args()
    state = json.loads(args.state.read_bytes()) if args.state.exists() else None
    if state is None:
        assert args.action == 'prepare' and args.platform
        root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-real-readers-', dir=WORK)).resolve()
        state = dict(root=str(root), owner=OWNER, token=uuid.uuid4().hex, platform=args.platform,
                     status='INCOMPLETE', launches=[], temporary_root_removed=False)
        dump(root / 'owned-test.marker', {'owner': OWNER, 'token': state['token']})
        dump(args.state, state)
    root = Path(state['root']).resolve(strict=True)
    assert root.parent == WORK.resolve(strict=True) and root.name.startswith('HomeLibRu-update-test-real-readers-')
    assert not root.is_symlink() and not root.is_junction()
    assert json.loads((root / 'owned-test.marker').read_bytes()) == {'owner': OWNER, 'token': state['token']}
    env = {**os.environ, 'TEMP': str(root), 'TMP': str(root), 'LOCALAPPDATA': str(root / 'Local'),
           'APPDATA': str(root / 'Roaming')}
    platform = state['platform']
    app, job = root / 'installation', root / state.get('job_name', 'HomeLibRu-update-' + state['token'])
    if args.action == 'prepare':
        assert not state['launches'] and not processes(root)
        package = PACKAGES / f'HomeLibRu-HomeLibReader-3.0.0.1-{platform}.zip'
        assert sha(package) == PACKAGE_HASH[platform]
        candidate = root / 'candidate'
        with zipfile.ZipFile(package) as archive:
            for name in archive.namelist():
                assert not name.startswith('/') and ':' not in name and '..' not in name.replace('\\', '/').split('/')
            archive.extractall(candidate)
        reader = REPO / f'Utils/HomeLibReader/Out/{platform}/HomeLibReader.exe'
        helper = REPO / ('Program/Out/Bin64' if platform == 'Win64' else 'Program/Out/Bin') / 'HomeLibRuUpdater.exe'
        shutil.copyfile(reader, candidate / reader.name)
        shutil.copyfile(helper, candidate / helper.name)
        manifest_path = candidate / 'HomeLibRu.update.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
        for entry in manifest['files']:
            file = candidate / entry['path']
            entry.update(size=file.stat().st_size, sha256=sha(file))
        dump(manifest_path, manifest)
        archive_path = root / 'candidate.zip'
        with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(candidate.rglob('*')):
                if file.is_file():
                    archive.write(file, file.relative_to(candidate).as_posix())
        if not app.exists():
            shutil.copytree(candidate, app)
            with (app / 'HomeLibReader.exe').open('ab') as file:
                file.write(b'\nOwned running development EXE overlay to require replacement\n')
        for folder in ('books', 'Local', 'Roaming'):
            (root / folder).mkdir(exist_ok=True)
        def book(title):
            paragraphs = ''.join(f'<p>{title}. Абзац {i}. Текст для проверки сохранения позиции чтения и восстановления книги.</p>' for i in range(180))
            return ('<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><author><first-name>Тест</first-name></author><book-title>' + title + '</book-title><lang>ru</lang></title-info></description><body><section><title><p>' + title + '</p></title>' + paragraphs + '</section></body></FictionBook>').encode('utf-8')
        for name, title in [('Первоначальная книга.fb2', 'Первоначальная книга'), ('Текущая книга.fb2', 'Текущая книга'), ('Книга инициатора.fb2', 'Книга инициатора')]:
            (root / 'books' / name).write_bytes(book(title))
        with zipfile.ZipFile(root / 'books/Сборник.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('01 Первая.fb2', book('Первая книга сборника'))
            archive.writestr('02 Вторая.fb2', book('Вторая книга сборника'))
        tester = REPO / f'Program/Tests/Out/{platform}/ProgramUpdateInstallerTest.exe'
        result = subprocess.run([str(tester), '--prepare-component', str(archive_path), sha(archive_path), manifest['release'], str(job), 'HomeLibReader', manifest['version']],
                                env=env, capture_output=True, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)
        assert result.returncode == 0, (result.stdout + result.stderr).decode('utf-8', errors='replace')
        shutil.copyfile(archive_path, job / 'release.zip')
        shutil.copyfile(helper, job / helper.name)
        state.update(archive=str(archive_path), archive_sha256=sha(archive_path), release=manifest['release'],
                     reader_sha256=sha(reader), helper_sha256=sha(helper), running_exe_sha256=sha(app / reader.name),
                     source_hashes={str(p.relative_to(root)): sha(p) for p in (root / 'books').iterdir()})
    elif args.action == 'launch':
        assert args.label and not any(x['label'] == args.label for x in state['launches'])
        profile = app / 'Data' / args.label
        profile.mkdir(parents=True)
        if args.seed_recent:
            (profile / 'HomeLibReader.ini').write_text('[ReaderRecent]\nFile0=' + str(root / 'books/Текущая книга.fb2') + '\nFile1=' + str(root / 'books/Сборник.zip') + '\n', encoding='utf-8-sig')
        if args.seed_save_folder:
            output = root / 'saved-copies'
            output.mkdir(exist_ok=True)
            ini = profile / 'HomeLibReader.ini'
            text = ini.read_text(encoding='utf-8-sig') if ini.exists() else ''
            ini.write_text(text + '\n[PATH]\nSyncExport=' + str(output) + '\n[SYSTEM]\nSaveAsUseSubfolders=0\nFileNameTemplate=%t\n', encoding='utf-8-sig')
        source = root / 'books' / ('Первоначальная книга.fb2' if args.label == 'peer' else 'Книга инициатора.fb2')
        command = [str(app / 'HomeLibReader.exe'), '--profile=' + str(profile), '--open=' + str(source)]
        if args.archive_session:
            source = root / 'books/Сборник.zip'
            session = root / 'catalogue-session/request.json'
            session.parent.mkdir()
            with zipfile.ZipFile(source) as archive:
                size = archive.getinfo('02 Вторая.fb2').file_size
            dump(session, dict(format=1, kind='HomeLibReader-session', id=uuid.uuid4().hex,
                 source=str(source), identity='owned-catalogue-archive:' + platform,
                 settings=str(profile / 'Data/reader.ini'), personal_progress=False,
                 book=dict(collection_id=1, book_id=2, root=str(root / 'books') + os.sep,
                      folder='Сборник.zip', file='02 Вторая', extension='.fb2', inside=1,
                      size=size, lib_id='owned-2', title='Вторая книга сборника', language='ru')))
            command[-1] = '--session=' + str(session)
        process = subprocess.Popen(command, cwd=app, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        state['launches'].append(dict(label=args.label, original_pid=process.pid, command=command, profile=str(profile)))
    elif args.action == 'inspect':
        receipts = []
        for file in (app / 'Data').rglob('ReaderInstances/*.json'):
            value = json.loads(file.read_text(encoding='utf-8-sig'))
            request = json.loads(Path(value['request']).read_text(encoding='utf-8-sig'))
            receipts.append(dict(pid=value['pid'], request=value['request'], source=request['source'],
                                 original_source=request.get('original_source'), identity=request['identity']))
        print(json.dumps(dict(active=processes(root), receipts=receipts), ensure_ascii=False))
    elif args.action == 'record-selection':
        peer, = [x for x in state['launches'] if x['label'] == 'peer']
        receipt, = list((Path(peer['profile']) / 'Data/ReaderInstances').glob('*.json'))
        request = json.loads(Path(json.loads(receipt.read_bytes())['request']).read_bytes())
        with zipfile.ZipFile(root / 'books/Сборник.zip') as archive:
            digest = hashlib.sha256(archive.read('02 Вторая.fb2')).hexdigest()
        assert sha(Path(request['source'])) == digest, 'The actual second member must be open'
        assert request['original_source'] == str(root / 'books/Сборник.zip')
        state['selected_archive_member'] = dict(source=request['source'], sha256=digest,
            original_source=request['original_source'], identity=request['identity'])
    elif args.action == 'install':
        caller, = [x for x in state['launches'] if x['label'] == 'caller']
        assert caller['original_pid'] not in {p['ProcessId'] for p in processes(root)}, 'Close own caller normally through Computer Use first'
        assert sha(Path(state['archive'])) == state['archive_sha256']
        dump(job / 'request.json', dict(target=str(app), pid=caller['original_pid'], tag=state['release'],
             sha256=state['archive_sha256'], application='HomeLibReader.exe', args=caller['command'][1:],
             commandLine=subprocess.list2cmdline(caller['command'])))
        process = subprocess.Popen([str(job / 'HomeLibRuUpdater.exe'), '--job', str(job)], cwd=job, env=env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        state['helper_pid'] = process.pid
    elif args.action == 'check':
        active = processes(root)
        assert state['helper_pid'] not in {p['ProcessId'] for p in active}, 'Update still running'
        assert json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state'] == 'installed'
        assert sha(app / 'HomeLibReader.exe') == state['reader_sha256'] != state['running_exe_sha256']
        assert sha(app / 'HomeLibRuUpdater.exe') == state['helper_sha256']
        assert len(active) == len(state['launches']) and not ({x['original_pid'] for x in state['launches']} & {p['ProcessId'] for p in active})
        related = json.loads((job / 'restart-instances.json').read_text(encoding='utf-8-sig'))
        assert related['phase'] == 'restored', related
        for path, digest in state['source_hashes'].items():
            assert sha(root / path) == digest
        if selected := state.get('selected_archive_member'):
            peer, = [x for x in state['launches'] if x['label'] == 'peer']
            receipt, = list((Path(peer['profile']) / 'Data/ReaderInstances').glob('*.json'))
            request = json.loads(Path(json.loads(receipt.read_bytes())['request']).read_bytes())
            assert sha(Path(request['source'])) == selected['sha256']
            assert request['original_source'] == selected['original_source']
            assert request['identity'] == selected['identity']
            state['selected_archive_member_restored'] = True
        state.update(helper_installation_checked=True, related_state=related, restarted=active)
    elif args.action == 'check-saved-copy':
        assert state.get('selected_archive_member_restored')
        saved, = list((root / 'saved-copies').rglob('*.fb2'))
        assert sha(saved) == state['selected_archive_member']['sha256']
        state['saved_selected_member'] = dict(path=str(saved), sha256=sha(saved), size=saved.stat().st_size)
    elif args.action in ('cleanup', 'cleanup-incomplete'):
        assert not processes(root), 'Close owned Readers normally through Computer Use first'
        if args.action == 'cleanup':
            assert state.get('helper_installation_checked'), 'Use explicit incomplete teardown for an interrupted fixture'
        else:
            assert state['status'] == 'INCOMPLETE' and not state.get('helper_installation_checked')
            assert not state.get('selected_archive_member'), 'Preserve unfinished selected-book evidence'
            assert json.loads((job / 'journal.json').read_bytes())['state'] == 'installed'
            for path, digest in state['source_hashes'].items():
                assert sha(root / path) == digest
            state['incomplete_teardown'] = dict(reason='Initial archive chooser was not targetable; no member selected',
                normal_close='Production updater sent WM_CLOSE; final caller closed with Alt+F4',
                related_state=json.loads((job / 'restart-instances.json').read_bytes()))
        assert not any(p.is_symlink() or p.is_junction() for p in root.rglob('*'))
        shutil.rmtree(root)
        state['temporary_root_removed'] = not root.exists()
    dump(args.state, state)
    print(json.dumps({k: state.get(k) for k in ('root', 'platform', 'helper_pid', 'helper_installation_checked', 'temporary_root_removed')}, ensure_ascii=False))


if __name__ == '__main__':
    main()

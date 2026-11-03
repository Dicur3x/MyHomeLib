"""Own an exact packaged Reader for graphical long-running Save As cancellation.

Controls are operated only through Computer Use. Packages install locally via
the native production installer before launch; no network/restart is claimed.
The large source is read in place and its hash must remain unchanged.
"""
import argparse
import configparser
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import psutil

from reader_save_first_use_smoke import stage_package

CACHE = Path('G:/HomeLibRu-build-cache')
REPO = Path(__file__).resolve().parents[3]
OWNER = 'HomeLibre exact Reader Save As cancellation v1'
EVENT_ORDER = ('baseline', 'estimate-active', 'estimate-stopped', 'estimate-close-active',
               'estimate-closed', 'export-active', 'export-cancelled')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def active(root):
    rows = []
    for process in psutil.process_iter(('pid','exe')):
        try:
            path = process.info['exe']
            if path and Path(path).is_relative_to(root):
                rows.append(dict(ProcessId=process.pid,ExecutablePath=path))
        except (psutil.NoSuchProcess,psutil.AccessDenied):
            continue
    return rows


def own(state):
    root = Path(state['root']).resolve(strict=True)
    assert root.parent == CACHE.resolve(strict=True) and root.name.startswith('HomeLibRu-update-test-save-cancel-')
    assert not root.is_symlink() and not root.is_junction()
    assert json.loads((root/'owned-test.marker').read_bytes()) == dict(owner=OWNER, token=state['token'])
    return root


def snapshot(root):
    scratch = [str(p.relative_to(root)) for p in root.rglob('*')
               if p.is_dir() and p.name.startswith(('homelib-convert-', 'homelib-save-estimate-'))]
    stages = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and '.homelib-new-' in p.name]
    progress = []
    for directory in scratch:
        file = root/directory/'progress.json'
        try:
            if file.is_file() and file.stat().st_size <= 8192:
                progress.append(dict(file=str(file.relative_to(root)), value=json.loads(file.read_bytes())))
        except (OSError, ValueError):
            # A producer can be replacing its progress file. This does not
            # establish worker completion and must not restart the operation.
            pass
    return dict(processes=active(root), scratch=scratch, atomic_stages=stages, progress=progress)


def record_event(state, run, current, event, actor):
    assert state.get('workflow_version') == 2, 'Use a fresh fixture for observed active/cancel pairs'
    previous = [item['event'] for item in run['events']]
    assert len(previous) < len(EVENT_ORDER) and event == EVENT_ORDER[len(previous)], (
        'Observe the active operation before recording its cancellation', previous, event)
    reader = dict(ProcessId=run['pid'], ExecutablePath=str(Path(run['app'])/'HomeLibReader.exe'))
    assert reader in current['processes'], current
    running = event.endswith('-active')
    if running:
        workers = [row for row in current['processes'] if row['ProcessId'] != run['pid']
                   and Path(row['ExecutablePath']).name.lower() in ('python.exe', 'pythonw.exe')]
        assert workers and current['scratch'], 'No live converter and operation work were observed'
    else:
        assert current['processes'] == [reader], current
        assert not current['scratch'] and not current['atomic_stages'], current
    assert not list(Path(run.get('output', str(Path(run['app'])/'saved'))).iterdir()), 'An output was published'
    assert sha(Path(state['source'])) == state['source_sha256']
    if run.get('export_source'):
        assert sha(Path(run['export_source']['path'])) == run['export_source']['sha256']
    observation = dict(event=event, actor=actor, observed_at_utc=datetime.now(timezone.utc).isoformat(),
                       reader_pid=run['pid'], source_unchanged=True, no_output=True)
    if running:
        observation.update(active_workers=workers, scratch=current['scratch'], progress=current['progress'])
    else:
        observation['no_worker_or_scratch'] = True
    run['events'].append(observation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'launch', 'retry-export', 'inspect', 'record', 'check', 'cleanup', 'cleanup-incomplete'))
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'))
    parser.add_argument('--source', type=Path)
    parser.add_argument('--export-source', type=Path, help='Owned large-picture fixture for confirmed active conversion cancellation')
    parser.add_argument('--reader-packages', type=Path)
    parser.add_argument('--format-packages', type=Path)
    parser.add_argument('--event', choices=EVENT_ORDER)
    parser.add_argument('--actor', choices=('computer-use','user'), default='computer-use')
    args = parser.parse_args()
    if args.action == 'prepare':
        assert not args.state.exists() and args.source and args.reader_packages and args.format_packages
        source = args.source.resolve(strict=True)
        assert source.is_file() and source.suffix.lower() == '.fb2'
        root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-save-cancel-', dir=CACHE))
        state = dict(status='INCOMPLETE', workflow_version=2, root=str(root), token=uuid.uuid4().hex,
                     source=str(source), source_sha256=sha(source), source_bytes=source.stat().st_size,
                     reader_packages=str(args.reader_packages.resolve(strict=True)),
                     format_packages=str(args.format_packages.resolve(strict=True)), runs=[],
                     scope='Exact packaged Reader GUI cancellation with locally preinstalled two required modules; no download or restart claim')
        (root/'owned-test.marker').write_text(json.dumps(dict(owner=OWNER, token=state['token'])), encoding='utf-8')
    else:
        state = json.loads(args.state.read_bytes())
        root = own(state)
    if args.action == 'launch':
        assert args.platform and not active(root)
        assert not any(run['platform'] == args.platform for run in state['runs'])
        app = root/args.platform
        app.mkdir()
        package = Path(state['reader_packages'])/f'HomeLibRu-HomeLibReader-3.0.0.3-{args.platform}.zip'
        stage_package(package, app, args.platform)
        native = REPO/'Program/Tests/Out'/args.platform/'ProgramUpdateInstallerTest.exe'
        feed = json.loads((Path(state['format_packages'])/'HomeLibRu.components.json').read_bytes())
        installed = []
        for component in ('BookProcessing', 'ImageProcessing'):
            entry, = [row for row in feed['components'] if row['id'] == component and row['platform'] == args.platform]
            source = Path(state['format_packages'])/entry['archive']
            archive = root/source.name
            shutil.copyfile(source, archive)
            job = root/(args.platform+'-'+component)
            for command in (('--prepare-component',archive,sha(archive),'optional-alreader-2.5.1009.25',job,component,entry['version']),
                            ('--install',job,app)):
                result = subprocess.run([str(native),*map(str,command)],cwd=root,capture_output=True,
                                        timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
                assert result.returncode == 0, (command,result.stdout,result.stderr)
            manifest = json.loads((job/'manifest.json').read_bytes())
            assert all(sha(app/item['path']) == item['sha256'] for item in manifest['files'])
            installed.append(dict(component=component,archive_sha256=sha(archive),version=entry['version']))
        assert not any((app/'tools'/folder).exists() for folder in ('kindle','office','xps','pdfium','djvu','doc'))
        output = app/'saved'
        output.mkdir()
        (app/'HomeLibReader.ini').write_text('[SYSTEM]\nCheckUpdates=0\nSaveAsUseSubfolders=0\n'
            'FileNameTemplate=cancel-%t\n[PATH]\nSyncExport='+str(output)+'\n',encoding='utf-8')
        environment = dict(os.environ,APPDATA=str(root/'Roaming'),LOCALAPPDATA=str(root/'Local'),
                           TEMP=str(root/'temp'),TMP=str(root/'temp'),PYTHONDONTWRITEBYTECODE='1')
        (root/'temp').mkdir(exist_ok=True)
        process = subprocess.Popen([str(app/'HomeLibReader.exe'),'--open='+state['source']],cwd=app,
                                   env=environment,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        state['runs'].append(dict(platform=args.platform,app=str(app),output=str(output),pid=process.pid,
            package_sha256=sha(package),reader_sha256=sha(app/'HomeLibReader.exe'),modules=installed,events=[],checked=False))
    elif args.action == 'retry-export':
        assert not active(root)
        run = state['runs'][-1]
        assert 'export-cancelled' not in [event['event'] for event in run['events']]
        previous = Path(run.get('output',str(Path(run['app'])/'saved')))
        files = [p for p in previous.iterdir() if p.is_file()]
        assert len(files) == 1 and files[0].suffix.lower() == '.fb2'
        run.setdefault('completed_before_cancel_attempts',[]).append(
            dict(output=str(files[0]),sha256=sha(files[0]),bytes=files[0].stat().st_size,
                 reason='Output completed before confirmed cancellation; not a cancellation PASS',
                 observed_export_activity=[event for event in run['events'] if event['event']=='export-active']))
        # Preserve failed-attempt evidence above; the next attempt must prove
        # its own live worker before it may be recorded as canceled.
        run['events'] = [event for event in run['events'] if event['event'] != 'export-active']
        app = Path(run['app'])
        output = app/('retry-cancel-'+str(len(run['completed_before_cancel_attempts'])))
        output.mkdir()
        ini = configparser.ConfigParser(interpolation=None,strict=False);ini.optionxform=str
        ini.read(app/'HomeLibReader.ini',encoding='utf-8-sig');ini['PATH']['SyncExport']=str(output)
        with (app/'HomeLibReader.ini').open('w',encoding='utf-8') as stream:ini.write(stream,space_around_delimiters=False)
        environment = dict(os.environ,APPDATA=str(root/'Roaming'),LOCALAPPDATA=str(root/'Local'),
                           TEMP=str(root/'temp'),TMP=str(root/'temp'),PYTHONDONTWRITEBYTECODE='1')
        source = Path(state['source'])
        if args.export_source:
            source = args.export_source.resolve(strict=True)
            assert source.is_relative_to(root) and source.suffix.lower() == '.fb2'
            run['export_source'] = dict(path=str(source),sha256=sha(source),bytes=source.stat().st_size)
        process = subprocess.Popen([str(app/'HomeLibReader.exe'),'--open='+str(source)],cwd=app,
                                   env=environment,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        run.update(pid=process.pid,output=str(output))
    elif args.action in ('inspect','record'):
        current = snapshot(root)
        if args.action == 'record':
            run = state['runs'][-1]
            assert args.event
            record_event(state, run, current, args.event, args.actor)
        print(json.dumps(current,ensure_ascii=False))
    elif args.action == 'check':
        assert not active(root),'Close only this test Reader normally first'
        run = state['runs'][-1]
        assert [event['event'] for event in run['events']] == list(EVENT_ORDER)
        assert not list(Path(run.get('output',str(Path(run['app'])/'saved'))).iterdir())
        for previous in run.get('completed_before_cancel_attempts',[]):
            assert sha(Path(previous['output'])) == previous['sha256']
        assert sha(Path(state['source'])) == state['source_sha256']
        if run.get('export_source'):
            assert sha(Path(run['export_source']['path'])) == run['export_source']['sha256']
        assert sha(Path(run['app'])/'HomeLibReader.exe') == run['reader_sha256']
        current = snapshot(root)
        assert not current['scratch'] and not current['atomic_stages'],current
        run['checked'] = True
    elif args.action in ('cleanup','cleanup-incomplete'):
        assert not active(root)
        if args.action == 'cleanup':
            assert {r['platform'] for r in state['runs']} == {'Win32','Win64'} and all(r['checked'] for r in state['runs'])
        else:
            assert state['status'] == 'INCOMPLETE'
            state['incomplete_reason'] = 'The complete active/cancel GUI sequence is unverified; completed copies are not cancellation success.'
            state['unchecked_platforms'] = [arch for arch in ('Win32', 'Win64')
                                            if not any(run['platform']==arch and run['checked'] for run in state['runs'])]
            state['retained_output_evidence'] = [dict(path=str(p.relative_to(root)),bytes=p.stat().st_size,sha256=sha(p))
                for p in root.rglob('cancel-*.fb2') if p.is_file()]
            for run in state['runs']:
                if run.get('export_source'):
                    assert sha(Path(run['export_source']['path'])) == run['export_source']['sha256']
        assert sha(Path(state['source'])) == state['source_sha256']
        assert not any(p.is_symlink() or p.is_junction() for p in root.rglob('*'))
        shutil.rmtree(root)
        assert not root.exists()
        state.update(status='PASS' if args.action=='cleanup' else 'PARTIAL',temporary_profile_removed=True)
    args.state.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status=state['status'],root=state['root'],runs=[dict(platform=r['platform'],pid=r['pid'],checked=r['checked']) for r in state['runs']]),ensure_ascii=False))


if __name__ == '__main__':
    main()

"""Own isolated actual-Reader first-use profiles; GUI actions use Computer Use.

No package installation or simulated continuation here: the ordinary app must
download, install, restart and open its original PDF through its own UI.
"""
import argparse
import configparser
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import zipfile

REPO = Path(__file__).resolve().parents[3]
OWNER = 'HomeLibre actual Reader first-use PDF v1'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def processes(root):
    query = "Get-CimInstance Win32_Process -Filter \"Name='HomeLibReader.exe' OR Name='HomeLibRuUpdater.exe'\" | Select-Object ProcessId,ExecutablePath | ConvertTo-Json -Compress"
    output = subprocess.check_output(['powershell', '-NoProfile', '-NonInteractive', '-Command', query],
        encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW)
    entries = json.loads(output) if output.strip() else []
    if isinstance(entries, dict):
        entries = [entries]
    return [entry for entry in entries if entry.get('ExecutablePath') and
            Path(entry['ExecutablePath']).is_relative_to(root)]


def own(state):
    root = Path(state['root']).resolve(strict=True)
    cache = Path('G:/HomeLibRu-build-cache').resolve(strict=True)
    assert root.parent == cache and root.name.startswith('HomeLibRu-update-test-first-use-reader-')
    assert not root.is_symlink() and not root.is_junction()
    assert json.loads((root / 'owned-test.marker').read_bytes()) == {'owner': OWNER, 'token': state['token']}
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('launch', 'inspect', 'record-download', 'record-open', 'check', 'abort-unavailable-window', 'cleanup'))
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'))
    parser.add_argument('--package', type=Path)
    parser.add_argument('--candidate-exe', type=Path, help='Explicit development EXE override; not a published-archive claim')
    args = parser.parse_args()
    state = json.loads(args.state.read_bytes()) if args.state.exists() else None
    if state is None:
        assert args.action == 'launch'
        root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-first-use-reader-',
                                    dir='G:/HomeLibRu-build-cache'))
        state = dict(root=str(root), token=uuid.uuid4().hex, runs=[])
        (root / 'owned-test.marker').write_text(json.dumps({'owner': OWNER, 'token': state['token']}))
        spec = importlib.util.spec_from_file_location('first_use_fixture',
            REPO / 'tools/bookconvert/tests/test_legacy_fixed.py')
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        source = root / 'PDF первая установка ё.pdf'
        source.write_bytes(fixture.pdf_fixture(pages=2))
        state.update(source=str(source), source_sha256=sha(source))
    root = own(state)
    active = processes(root)
    if args.action == 'launch':
        assert not active and args.package and args.platform
        assert not any(run['platform'] == args.platform for run in state['runs'])
        app = root / args.platform
        app.mkdir()
        with zipfile.ZipFile(args.package) as archive:
            manifest = json.loads(archive.read('HomeLibRu.update.json'))
            assert manifest['component'] == 'HomeLibReader' and manifest['platform'] == args.platform
            assert len(archive.namelist()) == len(set(archive.namelist()))
            assert set(archive.namelist()) == {item['path'] for item in manifest['files']} | {'HomeLibRu.update.json'}
            for item in manifest['files']:
                relative = Path(item['path'])
                assert not relative.is_absolute() and '..' not in relative.parts and ':' not in item['path']
                data = archive.read(item['path'])
                assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
                target = app / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        assert not (app / 'tools/pdfium').exists()
        candidate = None
        if args.candidate_exe:
            candidate = args.candidate_exe.resolve(strict=True)
            shutil.copyfile(candidate, app / 'HomeLibReader.exe')
        (app / 'HomeLibReader.ini').write_text('[SYSTEM]\nCheckUpdates=0\n', encoding='utf-8')
        before = {str(file.relative_to(app)): sha(file) for file in app.rglob('*') if file.is_file()}
        environment = dict(os.environ, APPDATA=str(root / 'Roaming'), LOCALAPPDATA=str(root / 'Local'),
                           TEMP=str(root), TMP=str(root))
        process = subprocess.Popen([str(app / 'HomeLibReader.exe'), '--open=' + state['source']],
            cwd=app, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        state['runs'].append(dict(platform=args.platform, app=str(app), original_pid=process.pid,
            package_sha256=sha(args.package), before=before, checked=False,
            candidate_exe=str(candidate) if candidate else None, reader_exe_sha256=sha(app / 'HomeLibReader.exe')))
        state['stage'] = 'waiting-for-real-GUI-installation'
    elif args.action == 'inspect':
        print(json.dumps({'active': active, 'runtime_files': [str(file.relative_to(root))
            for file in root.rglob('*') if file.is_file() and
            (file.suffix.lower() == '.json' or file.name.lower() == 'pdfium.dll')]}, ensure_ascii=False))
    elif args.action == 'record-download':
        run = state['runs'][-1]
        assert len(active) == 1 and active[0]['ProcessId'] == run['original_pid']
        candidates = []
        for file in (root / 'Local').rglob('ready.json'):
            value = json.loads(file.read_text(encoding='utf-8-sig'))
            prepared = Path(value['job']) / 'manifest.json'
            if prepared.is_file() and json.loads(prepared.read_text(encoding='utf-8-sig'))['platform'] == run['platform']:
                candidates.append(value)
        assert len(candidates) == 1
        ready = candidates[0]
        job = Path(ready['job']).resolve(strict=True)
        assert job.is_relative_to(root)
        manifest = json.loads((job / 'manifest.json').read_text(encoding='utf-8-sig'))
        assert ready['component'] == manifest['component'] == 'PDFium'
        assert sha(job / 'release.zip') == ready['sha256']
        assert not (Path(run['app']) / 'tools/pdfium').exists(), 'Download must not install before consent'
        run.update(downloaded_ready=ready, prepared_manifest=manifest, ready_job=str(job),
                   only_pdfium_downloaded=True, installed_before_second_click=False)
        state['stage'] = 'real-download-prepared-awaiting-install-click'
    elif args.action == 'record-open':
        run = state['runs'][-1]
        assert len(active) == 1 and active[0]['ProcessId'] != run['original_pid']
        assert Path(active[0]['ExecutablePath']) == Path(run['app']) / 'HomeLibReader.exe'
        run['restarted_pid'] = active[0]['ProcessId']
        state['stage'] = 'restarted-reader-running'
    elif args.action == 'check':
        assert not active, 'Close the test Reader normally before verification'
        run = state['runs'][-1]
        app = Path(run['app'])
        assert sha(Path(state['source'])) == state['source_sha256']
        assert (app / 'tools/pdfium/pdfium.dll').is_file()
        unexpected = ['bookconvert', 'images', 'kindle', 'office', 'xps', 'doc', 'djvu']
        assert all(not (app / 'tools' / name).exists() for name in unexpected)
        assert run['only_pdfium_downloaded'] and not run['installed_before_second_click']
        job = Path(run['ready_job'])
        journal = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))
        assert journal['state'] == 'installed'
        for item in run['prepared_manifest']['files']:
            assert sha(app / item['path']) == item['sha256'], item['path']
        for relative, digest in run['before'].items():
            if relative != 'HomeLibReader.ini':
                assert sha(app / relative) == digest, 'Unrelated file changed: ' + relative
        native = REPO / f"Program/Tests/Out/{run['platform']}/ProgramUpdateInstallerTest.exe"
        result = subprocess.run([str(native), '--component-needs-repair', str(app), 'PDFium'],
            env=dict(os.environ, TEMP=str(root.parent), TMP=str(root.parent)),
            capture_output=True, encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW, timeout=60)
        assert result.returncode == 0 and result.stdout.strip().splitlines() == ['0', 'PASS'], result
        ini = (app / 'HomeLibReader.ini').read_text(encoding='utf-8-sig')
        assert 'PendingFile=' not in ini and 'PendingSession=' not in ini
        settings = configparser.ConfigParser(interpolation=None)
        settings.read_string(ini)
        assert Path(settings['ReaderRecent']['File0']).resolve(strict=True) == Path(state['source']).resolve(strict=True)
        run.update(checked=True, source_preserved=True, unrelated_modules_absent=True,
                   native_repair_needed=False, transaction_installed=True,
                   installed_payload_hashes_verified=len(run['prepared_manifest']['files']),
                   preexisting_payload_preserved=True, pdfium_sha256=sha(app / 'tools/pdfium/pdfium.dll'))
        state['stage'] = 'runtime-verified-GUI-observation-recorded-separately'
    elif args.action == 'abort-unavailable-window':
        # End only this verified owned fixture process after UI inventory failed.
        # This deliberately records an incomplete GUI test, not a product failure.
        assert len(active) == 1
        process = active[0]
        run = state['runs'][-1]
        assert process['ProcessId'] == run['original_pid']
        assert Path(process['ExecutablePath']) == Path(run['app']) / 'HomeLibReader.exe'
        import signal
        os.kill(process['ProcessId'], signal.SIGTERM)
        state.update(stage='aborted-unavailable-window', status='INCOMPLETE',
            limitation='Reader alive; real mirror metadata/feed fetched, but neither sky list_windows nor list_apps returned its prompt. IDE screenshot capture remained available. No installation/read success claimed.')
    elif args.action == 'cleanup':
        assert not active
        assert state['stage'] == 'aborted-unavailable-window' or (len(state['runs']) == 2 and all(run['checked'] for run in state['runs']))
        # Revalidate the absolute owned root immediately before recursive removal.
        assert own(state) == root
        shutil.rmtree(root)
        state.update(temporary_profile_removed=not root.exists(), stage='cleaned')
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'stage': state['stage'], 'root': state['root'],
                      'runs': [{k: v for k, v in run.items() if k not in
                                ('before', 'prepared_manifest', 'downloaded_ready', 'ready_job')}
                               for run in state['runs']]}, ensure_ascii=False))


if __name__ == '__main__':
    main()

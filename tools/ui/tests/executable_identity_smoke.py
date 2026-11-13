"""Exercise the executable-name transition only in owned, temporary fixtures.

The production launcher and helper are real. The catalogue payload is a native
fixture with the matching version/architecture, so argv, identity, installation,
rollback and preservation can be checked without opening a user's collection.
This does not replace a production catalogue GUI / published-client update run.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native', type=Path)
    parser.add_argument('launcher', type=Path)
    parser.add_argument('helper', type=Path)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--legacy-validator', type=Path)
    parser.add_argument('--tag', default='3.0.0_pre1.13')
    args = parser.parse_args()
    stage = args.stage.resolve()
    stage.mkdir(parents=True, exist_ok=True)
    report = dict(platform=args.platform, tag=args.tag, cases=[],
                  native_sha256=sha(args.native), launcher_sha256=sha(args.launcher),
                  helper_sha256=sha(args.helper), runner_sha256=sha(Path(__file__)))
    if args.legacy_validator:
        report['legacy_validator_sha256'] = sha(args.legacy_validator)
    flags = subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-identity-', dir=stage) as name:
        root = Path(name).resolve()
        assert root.parent == stage and root.name.startswith('HomeLibRu-update-test-')
        environment = dict(os.environ, TMP=str(stage), TEMP=str(stage), LOCALAPPDATA=str(root / 'local'))

        def run(*command, expected=0, binary=None, cwd=None):
            result = subprocess.run([str(binary or args.native), *map(str, command)],
                cwd=cwd or root, env=environment, creationflags=flags,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8', timeout=45)
            assert result.returncode == expected, result.stdout
            return result.stdout.strip()

        def passed(text):
            report['cases'].append(text)
            print('PASS ' + text, flush=True)

        def probe(target):
            result = target / 'identity-result.json'
            deadline = time.monotonic() + 15
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            actual = json.loads(result.read_text(encoding='utf-8-sig'))
            assert Path(actual['image']).resolve() == target / 'HomeLibre.exe'
            # A launcher exits before its child. Wait for this exact native
            # fixture before releasing/removing its mapped executable.
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x100000, False, actual['pid'])
            if handle:
                try:
                    assert kernel.WaitForSingleObject(handle, 15000) == 0
                finally:
                    kernel.CloseHandle(handle)
            else:
                assert ctypes.get_last_error() == 87  # exited before OpenProcess
            return actual

        run('--metadata')
        passed('native application allowlist, old request default and command-line rewriting')
        suffix = '_x64' if args.platform == 'Win64' else ''
        portable, bridge = f'HomeLibre{suffix}_portable.zip', f'HomeLibre{suffix}.zip'
        legacy = f'HomeLibRu{suffix}.zip'
        opposite = 'HomeLibre_portable.zip' if suffix else 'HomeLibre_x64_portable.zip'
        for index, (names, expected) in enumerate([
                ([legacy], legacy), ([bridge, legacy], bridge),
                ([legacy, portable, bridge], portable), ([portable, bridge, legacy], portable),
                ([opposite, bridge], bridge), ([opposite, portable], portable)]):
            feed = [dict(draft=False, tag_name=args.tag, body='Fixture notes',
                         published_at='2026-11-13T00:00:00Z', assets=[dict(
                             name=n, browser_download_url=f'https://github.com/Dicur3x/MyHomeLib/releases/download/{args.tag}/{n}',
                             digest='sha256:' + 'a' * 64, size=100) for n in names])]
            source = root / f'feed-{index}.json'
            source.write_text(json.dumps(feed), encoding='utf-8')
            assert run('--parse', source).endswith('/' + expected)
        passed('portable, bridge and old asset preference independent of listing order and architecture')

        arguments = ['--open=G:\\Книги и архивы\\тест.fb2', 'user', 'Мой профиль', '', 'tail\\', 'quote"inside', '%literal%']
        baseline = root / 'baseline'
        baseline.mkdir()
        shutil.copy2(args.native, baseline / 'HomeLibre.exe')
        run('--probe', *arguments, binary=baseline / 'HomeLibre.exe')
        baseline_args = probe(baseline)['args']
        assert baseline_args[:3] == arguments[:3]
        # Delphi ParamStr differs from the C runtime for empty/embedded-quote
        # arguments. Forwarding must preserve its native interpretation too.
        content = {'HomeLibre.exe': args.native.read_bytes(), 'HomeLibRu.exe': args.launcher.read_bytes(),
                   'HomeLibRuUpdater.exe': args.helper.read_bytes(), 'LICENSE': b'Fixture license\n', 'NOTICE': b'Fixture notice\n'}
        transport = 'tools/updates/catalogue/HomeLibre.exe'

        def archive(path, compatibility):
            payload = dict(content)
            if compatibility:
                payload[transport] = payload.pop('HomeLibre.exe')
            manifest = dict(format=1, release=args.tag, platform=args.platform, files=[
                dict(path=n, size=len(b), sha256=hashlib.sha256(b).hexdigest()) for n, b in payload.items()])
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as package:
                for n, b in payload.items():
                    package.writestr(n, b)
                package.writestr('HomeLibRu.update.json', json.dumps(manifest).encode('utf-8'))

        archives = [root / portable, root / bridge]
        for path, compatibility in zip(archives, [False, True]):
            archive(path, compatibility)
            target = root / ('manual-bridge' if compatibility else 'manual-portable')
            with zipfile.ZipFile(path) as package:
                package.extractall(target)
            run('--probe', *arguments, binary=target / 'HomeLibRu.exe', cwd=root)
            actual = probe(target)
            assert actual['args'] == baseline_args and Path(actual['cwd']).resolve() == root
            assert sha(target / 'HomeLibre.exe') == sha(args.native)
            assert not (target / transport).exists()
            passed('manual bridge migration and old shortcut forwarding' if compatibility else 'portable old shortcut forwarding')

        for index, path in enumerate(archives):
            job = root / f'HomeLibRu-update-install-{index}'
            target = root / f'installed-{index}'
            target.mkdir()
            shutil.copy2(args.native, target / 'HomeLibRu.exe')
            (target / 'Data').mkdir()
            (target / 'Data/user.dbs2').write_bytes(b'Private user data must not change')
            (target / 'myhomelib2.ini').write_text('[User]\nname=private\n', encoding='utf-8')
            preserved = {p: sha(target / p) for p in ['Data/user.dbs2', 'myhomelib2.ini']}
            run('--prepare', path, sha(path), args.tag, job)
            run('--verify', job, args.tag)
            if index == 0:
                run('--install', job, target, '1', expected=1)
                assert not (target / 'HomeLibre.exe').exists()
                assert sha(target / 'HomeLibRu.exe') == sha(args.native)
                assert json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state'] == 'rolled-back'
                passed('injected install failure restores the old executable before retry')
                job = root / 'HomeLibRu-update-retry'
                run('--prepare', path, sha(path), args.tag, job)
            # Interrupt after the canonical EXE itself was replaced, before
            # committing success. A completed installation is deliberately
            # immune to rollback; only incomplete transactions are restored.
            run('--install', job, target, str(len(content)), expected=1)
            assert not (target / 'HomeLibre.exe').exists()
            assert sha(target / 'HomeLibRu.exe') == sha(args.native)
            assert run('--resolve', target, 'HomeLibre.exe') == 'HomeLibRu.exe'
            assert {p: sha(target / p) for p in preserved} == preserved
            passed(('bridge' if index else 'portable') + ' late failure restores the legacy executable and restart route')
            job = root / f'HomeLibRu-update-success-{index}'
            run('--prepare', path, sha(path), args.tag, job)
            run('--install', job, target)
            assert sha(target / 'HomeLibre.exe') == sha(args.native)
            assert sha(target / 'HomeLibRu.exe') == sha(args.launcher)
            assert not (target / transport).exists()
            assert {p: sha(target / p) for p in preserved} == preserved
            assert run('--resolve', target, 'HomeLibRu.exe') == 'HomeLibre.exe'
            journal = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))
            assert 'HomeLibre.exe' in [f['path'] for f in journal['files']]
            assert transport not in [f['path'] for f in journal['files']]
            run('--rollback', job, target)
            assert sha(target / 'HomeLibre.exe') == sha(args.native)
            assert sha(target / 'HomeLibRu.exe') == sha(args.launcher)
            assert {p: sha(target / p) for p in preserved} == preserved
            passed(('bridge' if index else 'portable') + ' installation, canonical journal, profile preservation and committed-state protection')

        target = root / 'canonical-only'
        target.mkdir()
        shutil.copy2(args.native, target / 'HomeLibre.exe')
        job = root / 'HomeLibRu-update-canonical-only'
        run('--prepare', archives[0], sha(archives[0]), args.tag, job)
        run('--install', job, target)
        assert sha(target / 'HomeLibre.exe') == sha(args.native)
        assert sha(target / 'HomeLibRu.exe') == sha(args.launcher)
        run('--resolve', target, '../HomeLibre.exe', expected=1)
        passed('an installation containing only HomeLibre.exe updates normally; arbitrary restart names are rejected')

        ambiguous = root / 'ambiguous.zip'
        with zipfile.ZipFile(archives[0]) as original, zipfile.ZipFile(ambiguous, 'w') as package:
            manifest = json.loads(original.read('HomeLibRu.update.json'))
            for name in original.namelist():
                if name != 'HomeLibRu.update.json':
                    package.writestr(name, original.read(name))
            package.writestr(transport, content['HomeLibre.exe'])
            manifest['files'].append(dict(path=transport, size=len(content['HomeLibre.exe']),
                sha256=hashlib.sha256(content['HomeLibre.exe']).hexdigest()))
            package.writestr('HomeLibRu.update.json', json.dumps(manifest).encode('utf-8'))
        rejection = run('--prepare', ambiguous, sha(ambiguous), args.tag,
                        root / 'HomeLibRu-update-ambiguous', expected=1)
        assert 'два пути' in rejection, rejection
        passed('two source paths cannot overwrite the same canonical executable')

        # The production helper must switch a real caller process to the new
        # application name, keeping the exact requested restart arguments.
        target = root / 'helper-target'
        target.mkdir()
        shutil.copy2(args.native, target / 'HomeLibRu.exe')
        job = root / 'HomeLibRu-update-helper'
        run('--prepare', archives[1], sha(archives[1]), args.tag, job)
        shutil.copy2(archives[1], job / 'release.zip')
        shutil.copy2(args.helper, job / 'HomeLibRuUpdater.exe')
        parent = subprocess.Popen([str(target / 'HomeLibRu.exe'), '--parent', '1500'],
            cwd=root, env=environment, creationflags=flags)
        command = [str(target / 'HomeLibRu.exe'), '--probe', *arguments]
        request = dict(target=str(target), application='HomeLibRu.exe', pid=parent.pid,
                       tag=args.tag, sha256=sha(archives[1]), args=command[1:],
                       commandLine=subprocess.list2cmdline(command), recover=False)
        (job / 'request.json').write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
        try:
            run('--job', job, binary=job / 'HomeLibRuUpdater.exe')
        finally:
            parent.wait(timeout=10)
        actual = probe(target)
        assert actual['args'] == baseline_args
        passed('production helper waits for the old caller, installs the bridge and restarts HomeLibre with unchanged arguments')
        if args.legacy_validator:
            run('--prepare', archives[1], sha(archives[1]), args.tag,
                root / 'HomeLibRu-update-old-parser', binary=args.legacy_validator)
            run('--prepare', archives[0], sha(archives[0]), args.tag,
                root / 'HomeLibRu-update-old-refusal', binary=args.legacy_validator, expected=1)
            passed('frozen beta 13 installer accepts the bridge and rejects the canonical root name as expected')
    report['private_runtime_removed'] = not root.exists()
    assert report['private_runtime_removed']
    result = stage / ('identity-' + args.platform + '.json')
    result.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()

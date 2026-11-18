"""Check the Reader filename migration using native updater code and owned data.

The payload is a native test executable, not a production Reader GUI. One copy's
version resource is changed to beta 14 to reproduce an old client's batch which
retains version metadata but drops the optional reader_application field.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile


OLD, NEW = 'HomeLibReader.exe', 'HomeLibreReader.exe'


def sha(value):
    return hashlib.sha256(value).hexdigest()


def change_fixture_version(source, target, version):
    """Edit only the owned fixture's VERSIONINFO using the Windows resource API."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
    kernel.LoadLibraryExW.restype = wintypes.HMODULE
    kernel.FindResourceW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p]
    kernel.FindResourceW.restype = wintypes.HANDLE
    kernel.LoadResource.argtypes = [wintypes.HMODULE, wintypes.HANDLE]
    kernel.LoadResource.restype = wintypes.HANDLE
    kernel.LockResource.argtypes = [wintypes.HANDLE]
    kernel.LockResource.restype = ctypes.c_void_p
    kernel.SizeofResource.argtypes = [wintypes.HMODULE, wintypes.HANDLE]
    kernel.SizeofResource.restype = wintypes.DWORD
    kernel.FreeLibrary.argtypes = [wintypes.HMODULE]
    languages = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p,
                                       ctypes.c_void_p, wintypes.WORD, ctypes.c_ssize_t)
    callback = callback_type(lambda module, kind, name, language, context:
                             languages.append(language) or True)
    kernel.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p,
                                               ctypes.c_void_p, callback_type, ctypes.c_ssize_t]
    module = kernel.LoadLibraryExW(str(source), None, 2)
    assert module, ctypes.get_last_error()
    try:
        resource = kernel.FindResourceW(module, 1, 16)
        assert resource
        assert kernel.EnumResourceLanguagesW(module, 16, 1, callback, 0)
        assert languages
        data = bytearray(ctypes.string_at(kernel.LockResource(kernel.LoadResource(module, resource)),
                                         kernel.SizeofResource(module, resource)))
    finally:
        kernel.FreeLibrary(module)
    signature = struct.pack('<II', 0xfeef04bd, 0x10000)
    assert data.count(signature) == 1
    offset = data.index(signature)
    a, b, c, d = map(int, version.split('.'))
    struct.pack_into('<IIII', data, offset + 8, (a << 16) | b, (c << 16) | d,
                     (a << 16) | b, (c << 16) | d)
    shutil.copy2(source, target)
    kernel.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
    kernel.BeginUpdateResourceW.restype = wintypes.HANDLE
    kernel.UpdateResourceW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                      wintypes.WORD, ctypes.c_void_p, wintypes.DWORD]
    kernel.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
    update = kernel.BeginUpdateResourceW(str(target), False)
    assert update
    buffer = ctypes.create_string_buffer(bytes(data))
    for language in languages:
        if not kernel.UpdateResourceW(update, 16, 1, language, buffer, len(data)):
            kernel.EndUpdateResourceW(update, True)
            raise ctypes.WinError(ctypes.get_last_error())
    assert kernel.EndUpdateResourceW(update, False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native', type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--platform', required=True, choices=['Win32', 'Win64'])
    args = parser.parse_args()
    stage = args.stage.resolve()
    stage.mkdir(parents=True, exist_ok=True)
    report = dict(platform=args.platform, cases=[], native_sha256=sha(args.native.read_bytes()),
                  runner_sha256=sha(Path(__file__).read_bytes()))
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-reader-', dir=stage) as name:
        root = Path(name)
        environment = dict(os.environ, TEMP=str(stage), TMP=str(stage), LOCALAPPDATA=str(root / 'local'))

        def run(*command, expected=0):
            result = subprocess.run([str(args.native.resolve()), *map(str, command)], cwd=root,
                env=environment, creationflags=subprocess.CREATE_NO_WINDOW,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8', timeout=45)
            assert result.returncode == expected, (command, result.stdout)
            return result.stdout.strip()

        def passed(text):
            report['cases'].append(text)
            print('PASS ' + text, flush=True)

        run('--metadata')
        base = args.native.read_bytes()
        next_fixture = root / 'version14-fixture.exe'
        newer_fixture = root / 'version15-fixture.exe'
        change_fixture_version(args.native, next_fixture, '3.0.0.14')
        change_fixture_version(args.native, newer_fixture, '3.0.0.15')
        shared = {'HomeLibRuUpdater.exe': base, 'sqlite3.dll': base,
                  'HomeLibReader-LICENSE.txt': b'fixture license', 'NOTICE': b'fixture notices',
                  'tools/fonts/manifest.json': b'{}'}

        def package(label, *, canonical=False, marker=True, version='3.0.0.13', batch=False,
                    duplicate=False, invalid=False):
            payload = dict(shared)
            payload[NEW if canonical else OLD] = next_fixture.read_bytes() if version.endswith('.14') else base
            if duplicate:
                payload[OLD] = payload[NEW]
            part = dict(component='HomeLibReader', version=version)
            if marker:
                part['reader_application'] = 'unrelated.exe' if invalid else NEW
            manifest = dict(format=1, release='3.0.0_pre1.13', platform=args.platform)
            if batch:
                manifest.update(component='batch', version=version, bundle=[part])
            else:
                manifest.update(part)
            manifest['files'] = [dict(path=n, size=len(b), sha256=sha(b)) for n, b in payload.items()]
            archive = root / (label + '.zip')
            with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as output:
                for n, b in payload.items():
                    output.writestr(n, b)
                output.writestr('HomeLibRu.update.json', json.dumps(manifest).encode())
            job = root / ('job-' + label)
            job.mkdir()
            shutil.copy2(archive, job / 'release.zip')
            run('--prepare', archive, sha(archive.read_bytes()), manifest['release'], job,
                manifest['component'], version)
            if batch:
                # CombinePreparedProgramUpdates writes its own saved JSON into
                # release.zip. Match that representation and byte binding.
                with zipfile.ZipFile(job / 'release.zip', 'w', zipfile.ZIP_DEFLATED) as combined:
                    for n, b in payload.items():
                        combined.writestr(n, b)
                    combined.writestr('HomeLibRu.update.json', (job / 'manifest.json').read_bytes())
            run('--verify', job, manifest['release'])
            return job, payload

        def target(label, old=False, canonical=False):
            destination = root / ('target-' + label)
            destination.mkdir()
            (destination / 'HomeLibre.exe').write_bytes(base + b'catalogue fixture')
            (destination / 'Data').mkdir()
            (destination / 'Data/reader-user.dbs2').write_bytes(b'private reading history')
            (destination / 'HomeLibReader.ini').write_bytes(b'[Book.1]\nPosition=875\n')
            (destination / 'foreign.txt').write_bytes(b'foreign file')
            if old:
                (destination / OLD).write_bytes(base + b'previous old payload')
            if canonical:
                (destination / NEW).write_bytes(base + b'previous canonical payload')
            return destination

        def snapshot(directory):
            return {p.relative_to(directory).as_posix(): sha(p.read_bytes())
                    for p in directory.rglob('*') if p.is_file()}

        def state(directory):
            return json.loads(run('--reader-state', directory))

        for label, options in [
                ('compat-fresh', {}), ('compat-old', dict(old=True)),
                ('compat-both', dict(old=True, canonical=True)),
                ('portable-fresh', dict(portable=True)),
                ('portable-old', dict(portable=True, old=True)),
                ('portable-no-marker', dict(portable=True, no_marker=True)),
                ('old-client-batch', dict(batch=True)),
                ('old-client-single', dict(no_marker=True, next_version=True))]:
            job, payload = package(label, canonical=options.get('portable', False),
                marker=not (options.get('batch') or options.get('no_marker')),
                version='3.0.0.14' if options.get('batch') or options.get('next_version') else '3.0.0.13',
                batch=options.get('batch', False))
            destination = target(label, old=options.get('old', False), canonical=options.get('canonical', False))
            before = snapshot(destination)
            run('--install', job, destination)
            expected = payload[NEW if options.get('portable') else OLD]
            assert (destination / NEW).read_bytes() == expected
            assert (destination / OLD).exists() == options.get('old', False)
            if options.get('old'):
                assert (destination / OLD).read_bytes() == expected
            for n, h in before.items():
                if n not in (NEW, OLD):
                    assert sha((destination / n).read_bytes()) == h
            for requested in (OLD, NEW):
                assert run('--resolve', destination, requested) == NEW
            info = state(destination)
            assert info['file'] == NEW and not info['repair'], info
            receipt = json.loads((destination / 'tools/component-state/homelibreader.json').read_text('utf-8-sig'))
            files = {p['path']: p for p in receipt['files']}
            assert NEW in files and (OLD in files) == options.get('old', False)
            for n, p in files.items():
                assert sha((destination / n).read_bytes()) == p['sha256']
            removal = json.loads(run('--reader-removal', destination))
            assert removal['blocked'] == 0, removal
            assert NEW in removal['files'] and (OLD in removal['files']) == options.get('old', False), removal
            assert not set(removal['files']) & {'HomeLibre.exe', 'sqlite3.dll', 'HomeLibRuUpdater.exe',
                                               'Data/reader-user.dbs2', 'HomeLibReader.ini'}
            installed = snapshot(destination)
            run('--rollback', job, destination)
            assert snapshot(destination) == installed  # completed updates cannot be rolled back
            passed(label + ': canonical install, restart, inventory and private data')

        # Fail at every copy boundary, including either executable and receipt.
        for boundary in range(1, 9):
            job, _ = package('rollback-' + str(boundary))
            destination = target('rollback-' + str(boundary), old=True, canonical=True)
            before = snapshot(destination)
            run('--install', job, destination, boundary, expected=1)
            assert snapshot(destination) == before
            assert json.loads((job / 'journal.json').read_text('utf-8-sig'))['state'] == 'rolled-back'
        passed('all eight interrupted-copy boundaries restore both filenames, receipt and private data')

        job, _ = package('legacy13', marker=False)
        destination = target('legacy13')
        run('--install', job, destination)
        assert (destination / OLD).exists() and not (destination / NEW).exists()
        assert state(destination)['file'] == OLD and not state(destination)['repair']
        assert run('--resolve', destination, NEW) == OLD
        removal = json.loads(run('--reader-removal', destination))
        assert removal['blocked'] == 0 and OLD in removal['files'], removal
        passed('unmarked beta 13 payload retains its old self-update identity')

        for label, options in [('duplicate', dict(canonical=True, duplicate=True)),
                               ('invalid-marker', dict(invalid=True))]:
            job, _ = package(label, **options)
            destination = target(label, old=True)
            before = snapshot(destination)
            run('--install', job, destination, expected=1)
            assert snapshot(destination) == before
            passed(label + ': rejected without changing target')

        job, _ = package('newer-preserved')
        destination = target('newer-preserved', old=True, canonical=True)
        for n, b in shared.items():
            path = destination / n
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b)
        for n in (NEW, OLD):
            shutil.copy2(newer_fixture, destination / n)
        before = snapshot(destination)
        run('--install', job, destination)
        assert snapshot(destination) == before
        assert state(destination)['version'] == '3.0.0.15'
        passed('newer installed Reader preserves both executable names and existing inventory')

        # The published beta 13 helper installs the real component under OLD
        # and leaves a receipt listing only that spelling.
        for scenario in ('normal', 'partial', 'modified', 'occupied', 'no-receipt'):
            directory = target('legacy-start-' + scenario)
            reader = next_fixture.read_bytes()
            payload = {**shared, OLD: reader}
            for name, content in payload.items():
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            entries = [dict(path=name, size=len(content), sha256=sha(content))
                       for name, content in payload.items()]
            receipt = dict(format=1, component='HomeLibReader', version='3.0.0.14',
                           platform=args.platform, files=entries)
            inventory = directory / 'tools/component-state/homelibreader.json'
            inventory.parent.mkdir()
            if scenario == 'partial':
                token = '{9B0C4D0A-25D4-4457-A21E-AF9681E82CEC}'
                receipt['reader_name_stage'] = token
                entries.append(dict(path=NEW, size=len(reader), sha256=sha(reader)))
                (directory / ('.homelibre-update-' + token + '.tmp')).write_bytes(b'partial')
            if scenario == 'modified':
                (directory / OLD).write_bytes(reader + b'changed')
            if scenario == 'occupied':
                (directory / NEW).write_bytes(b'unrelated existing executable')
            if scenario != 'no-receipt':
                inventory.write_text(json.dumps(receipt), encoding='utf-8')
            before = snapshot(directory)
            run('--legacy-reader-start', directory)
            if scenario in ('normal', 'partial'):
                assert (directory / NEW).read_bytes() == (directory / OLD).read_bytes() == reader
                updated = json.loads(inventory.read_bytes())
                assert 'reader_name_stage' not in updated
                assert not list(directory.glob('.homelibre-update-*.tmp'))
                owned = {entry['path']: entry['sha256'] for entry in updated['files']}
                assert owned[NEW] == owned[OLD] == sha(reader)
                after = snapshot(directory)
                for name, digest in before.items():
                    if name != inventory.relative_to(directory).as_posix() and not name.endswith('.tmp'):
                        assert after[name] == digest
                run('--legacy-reader-start', directory)
                assert snapshot(directory) == after
            else:
                assert snapshot(directory) == before
            passed('standalone beta 13 helper receipt on Reader startup: ' + scenario)

        report['status'] = 'PASS'
    report['owned_profile_removed'] = not root.exists()
    (stage / 'reader-identity-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

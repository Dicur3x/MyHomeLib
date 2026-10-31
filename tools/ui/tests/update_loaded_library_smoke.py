"""Exercise the real installer with a DLL mapped by another native process.

All files belong to a fresh, bounded test root on the selected work drive.
The release fixture is independently SHA-256 pinned; user installations are
neither opened nor changed. Successful runs remove their temporary root.
"""
import argparse
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
    parser.add_argument('tester', type=Path)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    assert sha(args.archive) == args.sha256, 'Release fixture hash differs'
    work = args.work_dir.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-loaded-dll-', dir=work)).resolve()
    assert root.parent == work and root.name.startswith('HomeLibRu-update-test-loaded-dll-')
    env = {**os.environ, 'TEMP': str(work), 'TMP': str(work)}
    report = dict(status='INCOMPLETE', root=str(root), temporary_root_removed=False,
                  tester_sha256=sha(args.tester), archive_sha256=args.sha256, cases=[])
    owned_archive = root / 'release.zip'
    shutil.copyfile(args.archive, owned_archive)

    def run(arguments, expected=0):
        result = subprocess.run([str(args.tester.resolve()), *map(str, arguments)],
                                env=env, capture_output=True, timeout=90,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        text = (result.stdout + result.stderr).decode('utf-8', errors='replace')
        assert result.returncode == expected, text
        return text

    try:
        with zipfile.ZipFile(owned_archive) as archive:
            manifest = json.loads(archive.read('HomeLibRu.update.json').decode('utf-8-sig'))
            for member in archive.namelist():
                name = member.replace('\\', '/')
                assert not name.startswith('/') and ':' not in name and '..' not in name.split('/')
            for scenario in ['identical', 'different', 'rollback']:
                case = root / scenario
                target, job = case / 'installation', case / 'job'
                target.mkdir(parents=True)
                archive.extractall(target)
                license_path = target / 'LICENSE'
                license_path.write_text('Owned older license fixture', encoding='utf-8')
                personal = target / 'Data' / 'personal-test.json'
                personal.parent.mkdir(parents=True, exist_ok=True)
                personal.write_text('{"notes":"Сохранить заметки"}', encoding='utf-8')
                library = target / 'sqlite3.dll'
                if scenario == 'different':
                    with library.open('ab') as stream:
                        stream.write(b'\nOwned older DLL overlay fixture\n')
                original = {str(p.relative_to(target)): sha(p)
                            for p in target.rglob('*') if p.is_file()}
                original_mtime = library.stat().st_mtime_ns
                run(['--prepare', owned_archive, args.sha256, manifest['release'], job])
                holder = subprocess.Popen([str(args.tester.resolve()), '--holdlibrary', str(library)],
                                          env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          creationflags=subprocess.CREATE_NO_WINDOW)
                try:
                    deadline = time.monotonic() + 15
                    while not Path(str(library) + '.locked').exists():
                        if holder.poll() is not None:
                            raise AssertionError(holder.communicate())
                        assert time.monotonic() < deadline, 'Native DLL mapping did not become ready'
                        time.sleep(0.05)
                    install_args = ['--install', job, target]
                    if scenario == 'rollback':
                        install_args += ['1']
                    output = run(install_args, 0 if scenario == 'identical' else 1)
                    assert holder.poll() is None, 'DLL holder exited before verification'
                    assert sha(personal) == original[str(personal.relative_to(target))]
                    assert sha(library) == original['sqlite3.dll']
                    assert library.stat().st_mtime_ns == original_mtime
                    if scenario == 'identical':
                        assert sha(license_path) == next(f['sha256'] for f in manifest['files']
                                                         if f['path'] == 'LICENSE')
                        assert not (job / 'backup' / 'sqlite3.dll').exists()
                        state = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state']
                        assert state == 'installed'
                    else:
                        for name, digest in original.items():
                            assert sha(target / name) == digest, name
                        if scenario == 'different':
                            assert 'sqlite3.dll' in output and not (job / 'journal.json').exists()
                            state = 'preflight-rejected'
                        else:
                            state = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state']
                            assert state == 'rolled-back', state
                    report['cases'].append(dict(scenario=scenario, status='PASS', state=state,
                                                dll_sha256=sha(library), native_output=output))
                finally:
                    Path(str(library) + '.release').write_text('release', encoding='ascii')
                    holder.communicate(timeout=15)
                    assert holder.returncode == 0
        report['status'] = 'PASS'
        assert root.parent == work and not root.is_symlink()
        shutil.rmtree(root)
        report['temporary_root_removed'] = not root.exists()
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()

"""Fetch the pinned complete Microsoft installers and verify them without installing.

The destination is an explicit release-input directory. Existing matching files
are reused; unknown or changed files are never silently overwritten. Large data
and isolated native-verifier profiles stay on the selected non-system volume.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def guard(destination, incoming=0):
    if shutil.disk_usage(os.environ.get('SystemDrive', 'C:') + '\\').free < 8 * 1024**3:
        raise OSError('Keep at least 8 GiB free on the system drive.')
    if shutil.disk_usage(destination).free < incoming + 512 * 1024**2:
        raise OSError('The input volume needs space for the download and a 512 MiB reserve.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.drive.casefold() == os.environ.get('SystemDrive', 'C:').casefold():
        raise ValueError('Use the non-system release-input volume for these large installers.')
    destination.mkdir(parents=True, exist_ok=True)
    definition = json.loads((ROOT / 'Installer/OfflinePrerequisites.json').read_bytes())
    for row in definition['files']:
        target = destination / row['path']
        guard(destination, row['size'])
        if not target.exists():
            # Sources are immutable vendor URLs recorded after checking the
            # official download endpoints; live "latest" links are not inputs.
            with urllib.request.urlopen(row['source'], timeout=30) as response, target.open('xb') as output:
                if response.url != row['source'] or int(response.headers['Content-Length']) != row['size']:
                    raise ValueError('Unexpected Microsoft download response: ' + row['path'])
                total = 0
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    guard(destination)
                    total += len(block)
                    if total > row['size']:
                        raise ValueError('Oversized prerequisite: ' + row['path'])
                    output.write(block)
        if target.is_symlink() or target.is_junction() or target.stat().st_size != row['size'] or sha(target) != row['sha256']:
            raise ValueError('Existing or downloaded installer checksum mismatch: ' + row['path'])
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-prerequisite-inputs-', dir=destination) as name:
        work = Path(name)
        folder = work / 'tools/prerequisites'
        folder.mkdir(parents=True)
        for row in definition['files']:
            os.link(destination / row['path'], folder / row['path'])
        (folder / 'PREREQUISITES.json').write_text(json.dumps(definition), encoding='utf-8')
        environment = dict(os.environ, TEMP=str(destination), TMP=str(destination),
                           LOCALAPPDATA=str(work / 'local-appdata'), APPDATA=str(work / 'appdata'))
        for row in definition['files']:
            guard(destination)
            result = subprocess.run([str(args.native.resolve()), '--offline-prerequisite', str(work),
                                     row['id'], row['architecture']], env=environment, cwd=work,
                                    capture_output=True, timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode:
                raise ValueError(result.stdout.decode('utf-8', errors='replace') +
                                 result.stderr.decode('utf-8', errors='replace'))
            print('Verified complete offline installer: ' + row['path'], flush=True)
    report = dict(status='PASS', definition_sha256=sha(ROOT / 'Installer/OfflinePrerequisites.json'),
                  native_sha256=sha(args.native.resolve()), installers_executed=False,
                  files=[dict(path=row['path'], size=row['size'], sha256=row['sha256']) for row in definition['files']])
    (destination / 'verification-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

"""Include the pinned complete Windows installers in an owned full-package stage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {'webview2-x86.exe', 'webview2-x64.exe', 'dotnet-framework-4.8.exe'}


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def guard(folder, incoming=0):
    if shutil.disk_usage(os.environ.get('SystemDrive', 'C:') + '\\').free < 8 * 1024**3:
        raise OSError('Keep at least 8 GiB free on the system drive.')
    if shutil.disk_usage(folder).free < incoming + 512 * 1024**2:
        raise OSError('Insufficient prerequisite staging space.')


def stage(payload, inputs, native):
    payload = payload.resolve(strict=True)
    parent = payload.parent
    if payload.name != 'payload' or not parent.name.startswith('homelibru-package-') or \
            (parent / '.package-stage').read_text(encoding='utf-8') != 'HomeLibre release packaging v1' or \
            payload.is_symlink() or payload.is_junction() or parent.is_symlink() or parent.is_junction():
        raise ValueError('Owned release packaging stage required.')
    definition = json.loads((ROOT / 'Installer/OfflinePrerequisites.json').read_bytes())
    if definition.get('format') != 1 or len(definition['files']) != 3 or \
            {row['path'] for row in definition['files']} != EXPECTED:
        raise ValueError('Every pinned offline prerequisite is required exactly once.')
    inputs, native = inputs.resolve(strict=True), native.resolve(strict=True)
    folder = payload / 'tools/prerequisites'
    folder.mkdir(parents=True, exist_ok=False)
    for row in definition['files']:
        source = inputs / row['path']
        guard(parent, row['size'])
        if source.is_symlink() or source.is_junction() or source.stat().st_size != row['size'] or sha(source) != row['sha256']:
            raise ValueError('Pinned offline prerequisite checksum mismatch: ' + row['path'])
        shutil.copy2(source, folder / row['path'])
    (folder / 'PREREQUISITES.json').write_text(json.dumps(definition, indent=2), encoding='utf-8')
    (folder / 'README.txt').write_text(
        'Компоненты Windows для работы без интернета\n\n'
        'WebView2 нужен для сохранения EPUB в PDF. Если его нет, HomeLibre предложит '
        'установить подходящий вариант из полного комплекта. Повторное скачивание не требуется.\n\n'
        'Если Windows сообщает об отсутствии .NET Framework при запуске модуля, '
        'запустите dotnet-framework-4.8.exe из этой папки и следуйте указаниям Microsoft. '
        'Подходящую уже установленную среду переустанавливать не нужно.\n\n'
        'Это оригинальные установщики Microsoft без изменений. Применяются условия, '
        'включённые в установщики, и требования Microsoft к версии Windows.\n'
        'https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution\n'
        'https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48\n', encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-prerequisite-stage-', dir=parent) as name:
        work = Path(name)
        check = work / 'app/tools/prerequisites'
        check.mkdir(parents=True)
        for source in folder.iterdir():
            os.link(source, check / source.name)
        environment = dict(os.environ, TEMP=str(parent), TMP=str(parent),
                           LOCALAPPDATA=str(work / 'local-appdata'), APPDATA=str(work / 'appdata'))
        for row in definition['files']:
            guard(parent)
            result = subprocess.run([str(native), '--offline-prerequisite', str(work / 'app'),
                                     row['id'], row['architecture']], env=environment, cwd=work,
                                    capture_output=True, timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode:
                raise ValueError('Native prerequisite verification failed: ' +
                                 result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace'))
            print('Verified offline prerequisite: ' + row['path'], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', required=True, type=Path)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    args = parser.parse_args()
    stage(args.payload, args.inputs, args.native)

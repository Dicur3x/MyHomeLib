"""Prepare the pinned portable legacy office readers; build-time only (MIT)."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import urllib.request
from urllib.parse import urlsplit

p = argparse.ArgumentParser()
p.add_argument('--runtime', type=Path, required=True)
p.add_argument('--cache', type=Path, required=True)
p.add_argument('--seven', type=Path, required=True)
p.add_argument('--copy', action='store_true')
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
pin_path = repo / 'Installer/OFFICE_LEGACY_RUNTIME.json'
pin = json.loads(pin_path.read_text(encoding='utf-8-sig'))
for path in [a.runtime, a.cache, a.seven]:
    if str(path.resolve()).upper().startswith('E:'): raise ValueError('Drive E is prohibited.')


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def download(package, target):
    url = package['url']; parsed = urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname != 'mirror.msys2.org':
        raise ValueError('Unexpected official package source.')
    size = package['bytes']
    if not 0 < size < 16 * 1024 * 1024: raise ValueError('Package exceeds build limit.')
    # Small ranges also work with mirrors which stall large transfers. The
    # complete package is verified before any of its contents are used.
    def part(start):
        end = min(size - 1, start + 16383)
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'Range': f'bytes={start}-{end}'})
                with urllib.request.urlopen(request, timeout=12) as response:
                    data = response.read(16385)
                    if response.status != 206 or response.headers.get('Content-Range') != f'bytes {start}-{end}/{size}' or len(data) != end - start + 1:
                        raise ValueError('Incomplete package range.')
                return data
            except (OSError, ValueError):
                if attempt == 2: raise
    with ThreadPoolExecutor(max_workers=6) as workers:
        data = b''.join(workers.map(part, range(0, size, 16384)))
    if hashlib.sha256(data).hexdigest() != package['sha256']: raise ValueError('Package hash mismatch.')
    temporary = target.with_name(target.name + '.new')
    temporary.write_bytes(data); temporary.replace(target)


if a.copy:
    a.runtime.mkdir(parents=True, exist_ok=True); a.cache.mkdir(parents=True, exist_ok=True)
    for index, package in enumerate(pin['packages']):
        source = a.cache / package['name']
        if not source.is_file() or sha(source) != package['sha256']: download(package, source)
        if sha(source) != package['sha256']: raise ValueError('Invalid cached package.')
        selected = [row for row in pin['files'] if row['package'] == index]
        archive = None
        try:
            for row in selected:
                relative = PurePosixPath(row['path'])
                if relative.is_absolute() or '..' in relative.parts or ':' in row['path'] or '\\' in row['path']:
                    raise ValueError('Invalid runtime path.')
                destination = a.runtime.joinpath(*relative.parts); destination.parent.mkdir(parents=True, exist_ok=True)
                if row['entry'] is None: data = source.read_bytes()
                else:
                    if archive is None:
                        result = subprocess.run([str(a.seven.resolve()), 'x', '-so', str(source.resolve())],
                                                capture_output=True, timeout=30, creationflags=0x08000000)
                        if result.returncode or len(result.stdout) > 128 * 1024 * 1024: raise ValueError('Invalid package archive.')
                        archive = tarfile.open(fileobj=io.BytesIO(result.stdout))
                    member = archive.getmember(row['entry'])
                    if not member.isfile() or member.size != row['bytes']: raise ValueError('Invalid package member.')
                    data = archive.extractfile(member).read()
                if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
                    raise ValueError('Pinned runtime member differs: ' + row['path'])
                destination.write_bytes(data)
        finally:
            if archive is not None: archive.close()
    shutil.copyfile(pin_path, a.runtime / 'RUNTIME.json')
    shutil.copyfile(repo / 'Installer/OfficeLegacy-NOTICE.txt', a.runtime / 'NOTICE.txt')
for row in pin['files']:
    path = a.runtime / row['path']
    if not path.is_file() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
        raise ValueError('Portable office runtime differs: ' + row['path'] + '; use -Copy.')
for source, name in [(pin_path, 'RUNTIME.json'), (repo / 'Installer/OfficeLegacy-NOTICE.txt', 'NOTICE.txt')]:
    if not (a.runtime / name).is_file() or sha(source) != sha(a.runtime / name): raise ValueError('Office runtime metadata differs.')
print('Pinned portable WPS/WPD reader verified; no installed office is used.')

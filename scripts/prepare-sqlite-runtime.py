"""Verify the pinned official Windows SQLite ZIP; optionally copy its DLL."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import struct
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['Win32', 'Win64'])
    parser.add_argument('--cache', type=Path, help='Directory for verified official ZIPs')
    parser.add_argument('--copy', action='store_true', help='Replace the repository runtime DLL after verification')
    args = parser.parse_args()
    pin = json.loads((ROOT / 'Installer/SQLITE_RUNTIME.json').read_text(encoding='utf-8-sig'))
    target = pin[args.platform]
    cache = args.cache or Path(tempfile.gettempdir()) / ('HomeLibRu-SQLite-' + pin['version'])
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / target['url'].rsplit('/', 1)[1]
    if archive.exists():
        data = archive.read_bytes()
    else:
        if not target['url'].startswith(('https://sqlite.org/', 'https://www.sqlite.org/')):
            raise ValueError('The pinned URL must use the official SQLite HTTPS origin')
        with urllib.request.urlopen(target['url'], timeout=60) as response:
            data = response.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024 or hashlib.sha3_256(data).hexdigest() != target['sha3_256']:
        raise ValueError('Official SQLite ZIP SHA3-256 verification failed')
    with zipfile.ZipFile(io.BytesIO(data)) as package:
        dll = package.read('sqlite3.dll')
    pe = struct.unpack_from('<I', dll, 60)[0]
    if dll[:2] != b'MZ' or dll[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', dll, pe+4)[0] != target['machine']:
        raise ValueError('SQLite PE architecture differs from the requested platform')
    if hashlib.sha256(dll).hexdigest() != target['dll_sha256']:
        raise ValueError('SQLite DLL SHA-256 differs from the pinned runtime')
    if not archive.exists():
        archive.write_bytes(data)
    if args.copy:
        folder = 'Bin64' if args.platform == 'Win64' else 'Bin'
        destination = ROOT / 'Program/Out' / folder / 'sqlite3.dll'
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Replace only a completely verified file, on the same filesystem.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix='sqlite3-', suffix='.verified.tmp',
                                             dir=destination.parent, delete=False) as output:
                temporary = Path(output.name)
                output.write(dll)
            os.replace(temporary, destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    print(f"PASS official SQLite {pin['version']} {args.platform}: ZIP SHA3-256, DLL SHA-256, PE architecture; copy={args.copy}")


if __name__ == '__main__':
    main()

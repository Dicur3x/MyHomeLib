"""Package and verify the corresponding source for the optional KFX writer."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import runpy
import shutil
import tarfile
from tempfile import TemporaryDirectory
import tomllib
import zipfile


SCRIPTS = Path(__file__).resolve().parent
BUILDER = 'build-kfx-export.py'
PATCH = 'boko-epub-navigation.patch'
BUILD = runpy.run_path(str(SCRIPTS / BUILDER))
ARCHIVE = BUILD['SOURCE_ARCHIVE']
BOKO = 'source.tar.gz'
RESVG = 'resvg-0.49.0.tar.xz'
README = b'''Corresponding source for HomeLibre KfxExport (Boko 0.6.0 and resvg 0.49.0).
The two pinned upstream source archives retain their original licences.
The accompanying patch modifies Boko's EPUB navigation handling.
The vendor directory contains the dependency sources pinned by Boko's Cargo.lock.
resvg includes its own vendor directory in its upstream source archive.

Extract this ZIP into a folder with a short path. With Python 3.12, Git,
Rust 1.99.1 for x86_64-pc-windows-gnu, the Windows GNU target libraries
and LLVM dlltool available, run:

python build-kfx-export.py --boko source.tar.gz --resvg resvg-0.49.0.tar.xz --boko-vendor vendor --platform Win32 --output components --dlltool path-to-llvm-dlltool.exe

Repeat with --platform Win64. The build uses the bundled dependency sources
offline. See the runtime package's RUNTIME.json for binary hashes.
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(path):
    with zipfile.ZipFile(path) as source:
        names = set(source.namelist())
        if len(names) != len(source.namelist()):
            raise ValueError('Duplicate member in KFX source ZIP')
        boko = source.read(BOKO)
        for file, data, (_, _, expected) in zip((BOKO, RESVG), (boko, source.read(RESVG)), BUILD['SOURCES']):
            if digest(data) != expected:
                raise ValueError('Unexpected upstream source archive: ' + file)
        for file in (BUILDER, PATCH):
            if source.read(file) != (SCRIPTS / file).read_bytes():
                raise ValueError('Source ZIP must contain the exact runtime build files: ' + file)
        if source.read('README.txt') != README:
            raise ValueError('Missing offline KFX build instructions')
        expected_files = {BOKO, RESVG, BUILDER, PATCH, 'README.txt'}
        with tarfile.open(fileobj=io.BytesIO(boko)) as upstream:
            lock = tomllib.loads(upstream.extractfile('boko-0.6.0/Cargo.lock').read().decode('utf-8'))
        for crate in lock['package']:
            if 'source' not in crate:
                continue
            root = 'vendor/' + crate['name'] + '-' + crate['version'] + '/'
            manifest = root + '.cargo-checksum.json'
            expected_files.add(manifest)
            checksums = json.loads(source.read(manifest))
            if checksums['package'] != crate['checksum'] or not checksums['files']:
                raise ValueError('Vendor crate does not match Cargo.lock: ' + root)
            for file, expected in checksums['files'].items():
                member = PurePosixPath(file)
                if member.is_absolute() or '..' in member.parts or '\\' in file or ':' in file:
                    raise ValueError('Unsafe vendor member: ' + file)
                full_name = root + file
                expected_files.add(full_name)
                if digest(source.read(full_name)) != expected:
                    raise ValueError('Unexpected vendor file: ' + full_name)
        if names != expected_files:
            raise ValueError('Unexpected or missing files in KFX source ZIP')


def package(boko, resvg, vendor, output):
    def write(source, name, data):
        member = zipfile.ZipInfo(name, (2026, 11, 7, 0, 0, 0))
        member.compress_type = zipfile.ZIP_DEFLATED
        member.external_attr = 0o644 << 16
        source.writestr(member, data)

    with TemporaryDirectory(prefix='kfx-source-', dir=output.parent) as folder:
        temporary = Path(folder) / output.name
        with zipfile.ZipFile(temporary, 'w') as source:
            write(source, BOKO, boko.read_bytes())
            write(source, RESVG, resvg.read_bytes())
            for file in (BUILDER, PATCH):
                write(source, file, (SCRIPTS / file).read_bytes())
            write(source, 'README.txt', README)
            for file in sorted(vendor.rglob('*')):
                if file.is_file():
                    write(source, 'vendor/' + file.relative_to(vendor).as_posix(), file.read_bytes())
        verify(temporary)
        with temporary.open('rb') as source, output.open('xb') as result:
            shutil.copyfileobj(source, result)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boko', type=Path, required=True)
    parser.add_argument('--resvg', type=Path, required=True)
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Directory for the verified source ZIP')
    args = parser.parse_args()
    package(args.boko, args.resvg, args.vendor, args.output / ARCHIVE)
    print('PASS verified KFX corresponding source: ' + str(args.output / ARCHIVE))

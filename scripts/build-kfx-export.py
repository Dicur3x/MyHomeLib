"""Reproduce the optional Windows KfxExport runtime from pinned source archives."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
from tempfile import TemporaryDirectory


BOKO_COMMIT = '9ac23f67a51e6911125a78fc0f876c8367388f3d'
RUST_VERSION = '1.99.1'
SOURCES = (
    ('boko', '0.6.0', 'cedbd44d81447cbf04bbbf9e8df096e5eb5f6fdcb32d040088e51aa903f662da'),
    ('resvg', '0.49.0', 'a1b167d575d0be44e303c76b46fe0aefc5c5748a46979ebae6a7dc3276c2ce8c'),
)
TARGETS = {'Win32': ('i686-pc-windows-gnu', 0x14c), 'Win64': ('x86_64-pc-windows-gnu', 0x8664)}
SOURCE_ARCHIVE = 'Boko-0.6.0-HomeLibre-source.zip'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(*args, cwd, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, encoding='utf-8').strip()


def collect_notices(cargo, source, target, destination, env):
    metadata = json.loads(command(cargo, 'metadata', '--locked', '--format-version', '1',
                                  '--filter-platform', target, cwd=source, env=env))
    for package in metadata['packages']:
        directory = Path(package['manifest_path']).parent
        files = [p for p in directory.iterdir() if p.is_file() and
                 p.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'PATENTS'))]
        if package.get('license_file'):
            license_file = directory / package['license_file']
            if license_file.is_file() and license_file not in files:
                files.append(license_file)
        if files:
            folder = destination / (package['name'] + '-' + package['version'])
            folder.mkdir(parents=True, exist_ok=True)
            for path in files:
                shutil.copyfile(path, folder / path.name)


def configure_vendor(source, vendor):
    if not vendor.is_dir():
        raise FileNotFoundError(vendor)
    config = source / '.cargo/config.toml'
    config.parent.mkdir(exist_ok=True)
    with config.open('x', encoding='utf-8') as stream:
        stream.write('[source.crates-io]\nreplace-with = "vendored-sources"\n\n'
                     '[source.vendored-sources]\ndirectory = ' + json.dumps(str(vendor)) + '\n')


def build(boko, resvg, platform, output, dlltool, boko_vendor=None):
    cargo, rustc = 'cargo', 'rustc'
    if command(rustc, '--version', cwd=output.parent).split()[1] != RUST_VERSION:
        raise ValueError('Use Rust ' + RUST_VERSION)
    sysroot = Path(command(rustc, '--print', 'sysroot', cwd=output.parent))
    lld = sysroot / 'lib/rustlib/x86_64-pc-windows-gnu/bin/rust-lld.exe'
    if not lld.is_file() or not dlltool.is_file():
        raise ValueError('Use the Windows GNU Rust toolchain and LLVM dlltool')
    target, machine = TARGETS[platform]
    component = output / ('KfxExport-' + platform)
    if component.exists():
        raise FileExistsError(component)
    patch = Path(__file__).with_name('boko-epub-navigation.patch')
    with TemporaryDirectory(prefix='homelibre-kfx-build-', dir=output.parent) as folder:
        work = Path(folder)
        artifacts = work / 'artifacts'
        artifacts.mkdir()
        env = dict(os.environ, CARGO_TARGET_DIR=str(work / 'target'), CARGO_PROFILE_RELEASE_OPT_LEVEL='2',
                   CARGO_PROFILE_RELEASE_LTO='false', CARGO_PROFILE_RELEASE_STRIP='symbols',
                   CARGO_ENCODED_RUSTFLAGS='\x1f'.join(('-Clink-self-contained=yes', '-Clinker-flavor=ld.lld',
                                                       '-Ctarget-feature=+crt-static', '-Cdlltool=' + str(dlltool))))
        env['CARGO_TARGET_' + target.upper().replace('-', '_') + '_LINKER'] = str(lld)
        if boko_vendor is not None:
            env['CARGO_NET_OFFLINE'] = 'true'
        records = []
        for (name, version, expected), source_file in zip(SOURCES, (boko, resvg)):
            if digest(source_file.read_bytes()) != expected:
                raise ValueError('Upstream source digest differs for ' + name)
            with tarfile.open(source_file, 'r:*') as archive:
                archive.extractall(work, filter='data')
            source = work / (name + '-' + version)
            if name == 'boko':
                if boko_vendor is not None:
                    configure_vendor(source, boko_vendor)
                subprocess.run(['git', 'apply', '--check', str(patch)], cwd=source, check=True)
                subprocess.run(['git', 'apply', str(patch)], cwd=source, check=True)
            args = [cargo, 'build', '--locked', '--release', '--target', target, '--bin', name]
            if name == 'resvg':
                args += ['-p', 'resvg']
            subprocess.run(args, cwd=source, env=env, check=True)
            executable = Path(env['CARGO_TARGET_DIR']) / target / 'release' / (name + '.exe')
            data = executable.read_bytes()
            pe = struct.unpack_from('<I', data, 0x3c)[0]
            if (data[:2] != b'MZ' or data[pe:pe + 4] != b'PE\0\0'
                    or struct.unpack_from('<H', data, pe + 4)[0] != machine
                    or command(executable, '--version', cwd=source, env=env).split()[-1] != version):
                raise ValueError('Unexpected KfxExport executable ' + name)
            shutil.copyfile(executable, artifacts / executable.name)
            records.append(dict(name=name, version=version, sha256=digest(data), bytes=len(data)))
            for path in source.glob('LICENSE*'):
                if path.is_file():
                    shutil.copyfile(path, artifacts / (name + '-' + path.name))
            collect_notices(cargo, source, target, artifacts / 'ThirdPartyLicenses' / name, env)
        shutil.copyfile(patch, artifacts / patch.name)
        metadata = dict(format=1, platform=platform, target=target, tools=records, rustc=RUST_VERSION,
                        boko_commit=BOKO_COMMIT)
        (artifacts / 'RUNTIME.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        shutil.copytree(artifacts, component)
        print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boko', type=Path, required=True)
    parser.add_argument('--resvg', type=Path, required=True)
    parser.add_argument('--platform', choices=TARGETS, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--dlltool', type=Path, required=True)
    parser.add_argument('--boko-vendor', type=Path, help='Use the vendor folder from the corresponding-source ZIP offline')
    args = parser.parse_args()
    build(args.boko.resolve(), args.resvg.resolve(), args.platform, args.output.resolve(), args.dlltool.resolve(),
          args.boko_vendor.resolve() if args.boko_vendor else None)

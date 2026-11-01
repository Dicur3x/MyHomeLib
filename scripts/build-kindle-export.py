"""Build the optional Kindle writer from a pinned upstream source checkout.

This is a developer/CI tool, not code run on a reader user's computer. Cargo
keeps its locked dependencies; the resulting component includes their notices.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess

UPSTREAM = 'https://github.com/ciscoriordan/kindling'
COMMIT = '3b91b1ea21f892779be09149f21fe4053b1b3569'
VERSION = '0.46.0'
TARGETS = {'Win32': ('i686-pc-windows-msvc', 0x14c),
           'Win64': ('x86_64-pc-windows-msvc', 0x8664)}


def checked(*args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True, encoding='utf-8').strip()


def build(source, output, platform):
    source, output = source.resolve(), output.resolve()
    if checked('git', 'rev-parse', 'HEAD', cwd=source) != COMMIT:
        raise ValueError('Kindling source does not match the pinned release commit')
    if checked('git', 'status', '--porcelain', cwd=source):
        raise ValueError('Refusing a modified upstream source checkout')
    target, machine = TARGETS[platform]
    # Do not silently merge an old compiler output or overwrite a component.
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(['cargo', 'build', '--release', '--locked', '--target', target],
                   cwd=source, check=True)
    binary = source / 'target' / target / 'release/kindling-cli.exe'
    data = binary.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if (data[:2] != b'MZ' or data[pe:pe+4] != b'PE\0\0'
            or struct.unpack_from('<H', data, pe+4)[0] != machine):
        raise ValueError('Unexpected Kindle writer architecture')
    reported = checked(str(binary), '--version', cwd=source)
    if reported.split()[-1] != VERSION:
        raise ValueError('Unexpected Kindle writer version: ' + reported)
    shutil.copyfile(binary, output / 'kindling-cli.exe')
    shutil.copyfile(source / 'LICENSE', output / 'Kindling-LICENSE.txt')
    metadata = json.loads(checked('cargo', 'metadata', '--locked', '--format-version',
                                  '1', '--filter-platform', target, cwd=source))
    notices, packages = output / 'ThirdPartyLicenses', []
    for package in metadata['packages']:
        if package['name'] == 'kindling-mobi':
            continue
        folder = Path(package['manifest_path']).parent
        files = [p for p in folder.iterdir() if p.is_file() and
                 p.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE'))]
        if package.get('license_file'):
            declared = folder / package['license_file']
            if declared.is_file() and declared not in files:
                files.append(declared)
        identity = package['name'] + '-' + package['version']
        for path in files:
            destination = notices / identity / path.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        packages.append(dict(name=package['name'], version=package['version'],
                             license=package.get('license'),
                             repository=package.get('repository'),
                             notices=[p.name for p in files]))
    (output / 'DEPENDENCIES.json').write_text(
        json.dumps(packages, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    runtime = dict(format=1, upstream=UPSTREAM, commit=COMMIT, version=VERSION,
                   platform=platform, target=target,
                   rustc=checked('rustc', '--version', cwd=source),
                   rustflags=os.environ.get('RUSTFLAGS', ''),
                   sha256=hashlib.sha256(data).hexdigest(), bytes=len(data),
                   formats=['mobi-dual-mobi7-kf8', 'azw3-kf8'])
    (output / 'RUNTIME.json').write_text(
        json.dumps(runtime, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(runtime, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--platform', choices=TARGETS, required=True)
    args = parser.parse_args()
    build(args.source, args.output, args.platform)

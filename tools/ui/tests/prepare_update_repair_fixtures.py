"""Build offline repair fixtures from a pinned release and distribution runtime.

The component packages are controlled repacks of existing binaries, not upstream
download samples. The native scenario exercises the real preparation code with
only its transport redirected to an owned loopback server.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version(path):
    data = path.read_bytes()
    offset = data.index(bytes.fromhex('bd04effe'))
    first, second = struct.unpack_from('<II', data, offset + 8)
    return '.'.join(map(str, [first >> 16, first & 65535,
                              second >> 16, second & 65535]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--sha256', required=True)
    args = parser.parse_args()
    if sha(args.archive).lower() != args.sha256.lower():
        parser.error('Release ZIP differs from its independently supplied SHA-256')
    with zipfile.ZipFile(args.archive) as source:
        if source.testzip() is not None:
            parser.error('Release ZIP has invalid member data')
        manifest = json.loads(source.read('HomeLibRu.update.json').decode('utf-8-sig'))
    platform = manifest['platform']
    if platform not in ['Win32', 'Win64']:
        parser.error('Unsupported release platform')
    args.output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(args.archive, args.output / 'application.zip')
    with zipfile.ZipFile(args.output / 'sevenzip.zip', 'w', zipfile.ZIP_DEFLATED) as package:
        for name in ['7z.exe', '7z.dll', 'License.txt']:
            package.write(args.runtime / 'tools/7zip' / name, name)
    digits = version(args.runtime / 'tools/7zip/7z.exe').split('.')
    seven = digits[0] + '.' + digits[1].zfill(2)
    doc = '.'.join(version(args.runtime / 'tools/doc/DocSharp.Binary.Doc.dll').split('.')[:3])
    info = dict(platform=platform, tag=manifest['release'],
                application_name=args.archive.name, application_sha256=sha(args.archive),
                sevenzip_version=seven, doc_version=doc,
                sevenzip_url='https://github.com/ip7z/7zip/releases/download/' + seven +
                '/7z' + seven.replace('.', '') + ('-x64' if platform == 'Win64' else '') + '.exe')
    for kind in ['doc', 'common', 'ppt', 'xls']:
        assembly = 'DocSharp.Binary.' + kind.capitalize()
        with zipfile.ZipFile(args.output / (kind + '.nupkg'), 'w', zipfile.ZIP_DEFLATED) as package:
            package.writestr(assembly + '.nuspec', '<package><metadata><id>' + assembly +
                             '</id><version>' + doc + '</version></metadata></package>')
            package.write(args.runtime / 'tools/doc' / (assembly + '.dll'),
                          'lib/net462/' + assembly + '.dll')
        info[kind + '_url'] = ('https://api.nuget.org/v3-flatcontainer/' + assembly.lower() +
                              '/' + doc + '/' + assembly.lower() + '.' + doc + '.nupkg')
    info['files'] = {path.name: sha(path) for path in args.output.iterdir() if path.is_file()}
    (args.output / 'fixtures.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
    print('PASS prepared offline repair fixtures:', platform, manifest['release'])


if __name__ == '__main__':
    main()

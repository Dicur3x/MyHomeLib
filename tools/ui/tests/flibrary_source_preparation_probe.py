"""Verify native FLibrary restoration/metadata writes on an isolated real book.

Reads only selected members from the supplied collection. A small reconstructed
layout and native profiles live under one auto-cleaned owned temporary root.
No production profile or catalogue is opened and no network is used.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE_SHA = 'efc28dc668f1d9971833a501baba6480e5a0775996652f6f921e6798118b3019'


def run(args, **kwargs):
    value = subprocess.run(list(map(str, args)), capture_output=True,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), timeout=90, **kwargs)
    if value.returncode:
        raise RuntimeError(value.stdout.decode('utf-8', 'replace')[-6000:] + value.stderr.decode('utf-8', 'replace')[-2000:])
    return value.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--sevenzip', type=Path, required=True)
    p.add_argument('--node', type=Path, required=True)
    p.add_argument('--temporary-root', type=Path, required=True)
    p.add_argument('--report', type=Path, required=True)
    args = p.parse_args()
    if args.report.exists():
        raise ValueError('Never overwrite a previous report')
    base = 'f.fb2-556318-558302'
    archives = [args.source_root/(base+'.7z'), args.source_root/'covers'/(base+'.zip'), args.source_root/'images'/(base+'.zip')]
    before = [(f.stat().st_size, f.stat().st_mtime_ns) for f in archives]
    report = {'source_writes':False, 'network':False, 'source_fb2_sha256':SOURCE_SHA, 'platforms':{}}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-flibrary-source-', dir=args.temporary_root) as name:
        temporary = Path(name); fixture = temporary/'fixture'; fixture.mkdir()
        data = run([args.sevenzip, 'e', '-so', archives[0], '557950.fb2'])
        if hashlib.sha256(data).hexdigest()!=SOURCE_SHA:
            raise ValueError('The selected real compressed source differs')
        (fixture/'557950.fb2').write_bytes(data)
        run([args.sevenzip, 'a', '-t7z', '-mx=0', fixture/'source.7z', '557950.fb2'], cwd=fixture)
        for kind, archive, members in [('covers', archives[1], ['557950']), ('images', archives[2], ['557950\\1', '557950\\2'])]:
            (fixture/kind).mkdir()
            with zipfile.ZipFile(fixture/kind/'source.zip', 'x', zipfile.ZIP_STORED) as z:
                for member in members:
                    payload = run([args.sevenzip, 'e', '-so', archive, member])
                    if not 0<len(payload)<2*1024*1024:
                        raise ValueError('Unexpected image fixture size')
                    z.writestr(member, payload)
        for platform, binary in [('Win32','Bin'), ('Win64','Bin64')]:
            env = dict(os.environ, TEMP=str(args.temporary_root), TMP=str(args.temporary_root))
            stdout = run([args.node, ROOT/'tools/ui/tests/native_collection_tests.js',
                ROOT/'Program/Out'/binary, '-', '-', ROOT/f'tools/ui/tests/Out/{platform}/CollectionViewsTest.exe',
                '--views-mode=flibrary-source-preparation', '--flibrary-source-fixtures='+str(fixture)], cwd=ROOT, env=env).decode('utf-8', 'replace')
            passes = [line for line in stdout.splitlines() if 'PASS ' in line]
            report['platforms'][platform] = {'native_passes':passes, 'passed':True}
            print(platform+': '+ '\n'.join(passes), flush=True)
        assert hashlib.sha256((fixture/'557950.fb2').read_bytes()).hexdigest()==SOURCE_SHA
    assert before==[(f.stat().st_size, f.stat().st_mtime_ns) for f in archives]
    report['temporary_payloads_removed'] = not temporary.exists()
    assert report['temporary_payloads_removed']
    with args.report.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print('PASS source members read only; all owned temporary payloads removed', flush=True)


if __name__=='__main__':
    main()

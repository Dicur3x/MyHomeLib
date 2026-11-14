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
    p.add_argument('--binary-root', type=Path, default=ROOT/'tools/ui/tests/Out')
    p.add_argument('--book-id', default='557950')
    p.add_argument('--image-id', action='append')
    p.add_argument('--processing-package', type=Path)
    p.add_argument('--images-root', type=Path)
    p.add_argument('--jpeg-xl-decoder', type=Path)
    args = p.parse_args()
    if not args.book_id.isascii() or not args.book_id.isdecimal():
        raise ValueError('A numeric book identity is required')
    image_ids = args.image_id or ['1','2']
    if any(not value.isascii() or not value.isdecimal() for value in image_ids) or len(image_ids)!=len(set(image_ids)):
        raise ValueError('Exact distinct numeric illustration IDs are required')
    if args.report.exists():
        raise ValueError('Never overwrite a previous report')
    base = 'f.fb2-556318-558302'
    archives = [args.source_root/(base+'.7z'), args.source_root/'covers'/(base+'.zip'), args.source_root/'images'/(base+'.zip')]
    before = [(f.stat().st_size, f.stat().st_mtime_ns) for f in archives]
    entry = args.book_id+'.fb2'
    report = {'source_writes':False, 'network':False, 'source_book':entry, 'platforms':{}}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-flibrary-source-', dir=args.temporary_root) as name:
        temporary = Path(name); fixture = temporary/'fixture'; fixture.mkdir()
        data = run([args.sevenzip, 'e', '-so', '-spd', archives[0], entry])
        if not data:
            raise ValueError('The selected book is no longer in this archive; select an existing real book')
        source_sha = hashlib.sha256(data).hexdigest()
        report['source_fb2_sha256'] = source_sha
        (fixture/entry).write_bytes(data)
        (fixture/'entry-name.txt').write_text(entry, encoding='utf-8')
        (fixture/'source.sha256').write_text(source_sha, encoding='utf-8')
        (fixture/'expected-images.json').write_text(json.dumps(['cover',*image_ids]), encoding='utf-8')
        run([args.sevenzip, 'a', '-t7z', '-mx=0', fixture/'source.7z', entry], cwd=fixture)
        for kind, archive, members in [('covers', archives[1], [args.book_id]),
                ('images', archives[2], [args.book_id+'\\'+value for value in image_ids])]:
            (fixture/kind).mkdir()
            with zipfile.ZipFile(fixture/kind/'source.zip', 'x', zipfile.ZIP_STORED) as z:
                for member in members:
                    payload = run([args.sevenzip, 'e', '-so', archive, member])
                    if not 0<len(payload)<2*1024*1024:
                        raise ValueError('Unexpected image fixture size')
                    z.writestr(member, payload)
        if args.processing_package:
            import shutil
            import sys
            sys.path.insert(0, str(ROOT/'tools/collectionpack'))
            from validate_catalogue_compression import install_processing_package
            runtime = temporary/'processing'
            install_processing_package(args.processing_package, runtime, 'Win64')
            shutil.copytree(args.images_root, runtime/'tools/images')
            work = fixture/'prepared'
            work.mkdir()
            request = temporary/'request.json'
            external_report = fixture/'prepared-external-images.json'
            request.write_text(json.dumps(dict(version=1,kind='HomeLibre external image preparation',
                source=str(fixture/'source.7z'),members={entry:'.fb2'},workspace=str(work),
                seven_zip=str(args.sevenzip),tools_root=str(runtime/'tools'),
                jpeg_xl_decoder=str(args.jpeg_xl_decoder),profile='maximum',grayscale=True,
                report=str(external_report))),encoding='utf-8')
            run([runtime/'tools/python/python.exe','-I','-B','-X','utf8',
                runtime/'tools/bookconvert/external_image_preparation.py','--job',request])
            prepared = json.loads(external_report.read_text('utf-8'))
            report['external_images'] = {kind:sum(image['changed'] for image in group['images'])
                for group in prepared['archives'] for kind in [group['kind']]}
        for platform, binary in [('Win32','Bin'), ('Win64','Bin64')]:
            env = dict(os.environ, TEMP=str(args.temporary_root), TMP=str(args.temporary_root))
            stdout = run([args.node, ROOT/'tools/ui/tests/native_collection_tests.js',
                ROOT/'Program/Out'/binary, '-', '-', args.binary_root/platform/'CollectionViewsTest.exe',
                '--views-mode=flibrary-source-preparation', '--flibrary-source-fixtures='+str(fixture)], cwd=ROOT, env=env).decode('utf-8', 'replace')
            passes = [line for line in stdout.splitlines() if 'PASS ' in line]
            if args.processing_package and not any('processed external images restore a complete book' in line for line in passes):
                raise ValueError('Native test did not validate the actual prepared images')
            report['platforms'][platform] = {'native_passes':passes, 'passed':True}
            if args.processing_package:
                measurement = fixture/('measured-'+platform)
                run([runtime/'tools/python/python.exe','-I','-B','-X','utf8',
                    runtime/'tools/bookconvert/restored_book_validation.py','--job',measurement/'request.json'])
                measured = json.loads((measurement/'report.json').read_text('utf-8'))
                payload = measured['restored_payloads'][0]
                assert payload['member']==entry and payload['input_size']>len(data)
                assert payload['input_sha256']!=payload['output_sha256']
                assert measured['originals'] and measured['preview']
                with zipfile.ZipFile(measured['originals']['path']) as backup:
                    full = backup.read('books/'+entry)
                    assert hashlib.sha256(full).hexdigest()==payload['input_sha256']
                report['platforms'][platform]['complete_book'] = payload
                report['platforms'][platform]['self_contained_original_verified'] = True
            print(platform+': '+ '\n'.join(passes), flush=True)
        assert hashlib.sha256((fixture/entry).read_bytes()).hexdigest()==source_sha
    assert before==[(f.stat().st_size, f.stat().st_mtime_ns) for f in archives]
    report['temporary_payloads_removed'] = not temporary.exists()
    assert report['temporary_payloads_removed']
    with args.report.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print('PASS source members read only; all owned temporary payloads removed', flush=True)


if __name__=='__main__':
    main()

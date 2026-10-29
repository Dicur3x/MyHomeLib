"""Read-only real-source regression through freshly packaged x86/x64 modules.

The configured local books are not copied into the repository. All extracted
books, packages and generated results live in one auto-cleaned owned directory.
Only a small metadata report survives. No network or production profile writes.
"""
from pathlib import Path
import argparse
import base64
from collections import Counter
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[3]
CASES = (
    ('562221', 'f.fb2-560514-564403.zip', 'a3d69992203a68335f2c5caef68b9351296da42d57a89e78f10bdeb24c528afd'),
    ('792655', 'f.fb2-791176-794180.zip', 'c3ea6a3ed26240d56d1d55dd80a701f953dc991a8e7bdc9868d21d99b7a45e5c'),
    ('755727', 'f.fb2-754754-759835.zip', '6136c160a4beefafc3ba671d94f3a92c939209dd3285f557001c528330c0d04a'),
    ('875779', 'f.fb2-875653-879581.zip', '5ece2b200790aad4c2eb0ac008abd17c98e0f0501dd2fd7a9dbac5ffe0eb02c5'),
    ('533994', 'f.fb2-532452-534919.zip', 'ac1d770fd4527ef9f41af3c7e0ddc8468ef43195948f7f92adf16102cb79abea'),
)


def run(arguments, **kwargs):
    completed = subprocess.run(list(map(str, arguments)), cwd=ROOT,
        capture_output=True, encoding='utf-8', errors='replace', timeout=180,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), **kwargs)
    if completed.returncode:
        raise RuntimeError('Regression process failed: '+completed.stdout[-6000:]+completed.stderr[-2000:])
    return completed.stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def text(node):
    return ''.join(''.join(node.itertext()).split())


def cli(runtime, source, output, *options):
    return [runtime/'tools/python/python.exe', '-I', '-B', '-X', 'utf8',
        runtime/'tools/bookconvert/convert_book.py', source, output,
        '--tools-root', runtime/'tools', *options]


def estimate(runtime, source, output):
    options, choice = Path(str(output)+'.options.json'), Path(str(output)+'.choice.txt')
    process = subprocess.Popen(list(map(str, cli(runtime, source, output,
        '--image-quality', 'ask', '--image-options', options, '--image-choice', choice))),
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    try:
        deadline = time.monotonic()+90
        while not options.exists() and process.poll() is None:
            if time.monotonic()>deadline: raise TimeoutError('Size estimation did not finish')
            time.sleep(.05)
        if not options.exists():
            stdout, stderr = process.communicate(timeout=5)
            raise RuntimeError('No estimate channel: '+stdout.decode('utf-8', 'replace')+stderr.decode('utf-8', 'replace'))
        result = json.loads(options.read_text(encoding='utf-8'))
        for profile in ('original', 'balanced', 'economy', 'none'):
            assert result['sizes'][profile]>0 and result['zip_sizes'][profile]>0, result
        choice.write_text('cancel', encoding='utf-8')
        stdout, stderr = process.communicate(timeout=10)
        reply = json.loads(stdout.decode('utf-8'))
        assert process.returncode==1 and reply.get('error')=='Экспорт отменён.', (reply, stderr)
        assert not output.exists(), 'Cancelled estimate published a book'
        return result
    finally:
        if process.poll() is None: process.kill()
        process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--temporary-root', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--conversion-fixtures', type=Path, required=True)
    parser.add_argument('--extra-source-zip', type=Path)
    parser.add_argument('--extra-source-sha256')
    args = parser.parse_args()
    if args.report.exists(): raise ValueError('Never overwrite a previous report')
    api = load('source_compat_api', ROOT/'tools/bookconvert/convert_book.py')
    installer = load('source_compat_fixture', ROOT/'tools/ui/tests/prepare_format_runtime_fixture.py')
    converter_bytes = (ROOT/'tools/bookconvert/convert_book.py').read_bytes()
    report = {'source_writes':False, 'network':False,
        'converter_sha256':digest(converter_bytes), 'platforms':{}}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-fb2-packaged-', dir=args.temporary_root) as name:
        temporary = Path(name).resolve(); packages = temporary/'packages'
        print('Preparing current independent modules', flush=True)
        run([sys.executable, '-B', '-X', 'utf8', ROOT/'scripts/package-format-components.py',
             packages, '--version', '2.7.0.1106', '--component', 'BookProcessing', '--component', 'ImageProcessing'])
        sources = temporary/'sources'; sources.mkdir()
        source_data = {}; selected_cases = list(CASES)
        for identity, archive_name, expected in CASES:
            with zipfile.ZipFile(args.source_root/archive_name) as archive:
                data = archive.read(identity+'.fb2')
            assert digest(data)==expected, 'Real source changed: '+identity
            source = sources/(identity+'.fb2'); source.write_bytes(data)
            source_data[identity] = data
        if args.extra_source_zip:
            original_zip = args.extra_source_zip.read_bytes()
            if not args.extra_source_sha256 or digest(original_zip)!=args.extra_source_sha256:
                raise ValueError('The exact tester ZIP must match its expected SHA-256')
            with zipfile.ZipFile(args.extra_source_zip) as archive:
                entries = archive.infolist()
                if len(entries)!=1 or entries[0].file_size>api.MAX_FILE or not entries[0].filename.lower().endswith('.fb2'):
                    raise ValueError('Expected one bounded FB2 in the tester ZIP')
                data = archive.read(entries[0])
            identity = 'tester-exact'; source_data[identity] = data
            (sources/(identity+'.fb2')).write_bytes(data)
            selected_cases.append((identity, None, digest(data)))
            report['tester_zip_sha256'] = digest(original_zip)
        for platform in ('Win32', 'Win64'):
            print('Testing packaged '+platform+' real sources, estimates and native exports', flush=True)
            runtime = temporary/platform; runtime.mkdir(); (runtime/'native-regression.marker').touch()
            installer.prepare(packages, runtime, platform, ['BookProcessing', 'ImageProcessing'])
            packaged = runtime/'tools/bookconvert/convert_book.py'
            assert packaged.read_bytes()==converter_bytes
            cases = []
            for identity, _, expected in selected_cases:
                source = sources/(identity+'.fb2'); data = source_data[identity]
                output, back, unchanged = (runtime/(identity+suffix) for suffix in ('.epub', '-back.fb2', '-unchanged.fb2'))
                reply = json.loads(run(cli(runtime, source, output)))
                book = api.xml(data, api.MAX_TOTAL)
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None
                    actual_text = ''.join(text(api.first(api.xml(archive.read(f'OEBPS/body-{i+1}.xhtml'), api.MAX_TOTAL), 'body'))
                        for i in range(len(api.children(book, 'body'))))
                    assert actual_text==''.join(text(b) for b in api.children(book, 'body')), 'Text changed: '+identity
                    expected_images = Counter(base64.b64decode(''.join(api.plain(n).split())) for n in api.children(book, 'binary'))
                    actual_images = Counter(archive.read(n) for n in archive.namelist() if n.startswith('OEBPS/images/'))
                    assert actual_images==expected_images, 'Image bytes changed: '+identity
                run(cli(runtime, output, back)); api.validate_fb2_output(api.xml(back.read_bytes(), api.MAX_TOTAL))
                run(cli(runtime, source, unchanged)); assert unchanged.read_bytes()==data
                item = {'id':identity, 'sha256':expected, 'epub_size':output.stat().st_size,
                    'roundtrip_fb2_size':back.stat().st_size, 'warnings':reply['warnings'],
                    'text_and_images_preserved':True, 'unchanged_copy_identical':True}
                if identity in ('562221', '792655', 'tester-exact'):
                    item['estimates'] = {}
                    for extension in ('fb2', 'epub'):
                        item['estimates'][extension] = estimate(runtime, source, runtime/(identity+'-estimate.'+extension))
                    balanced = runtime/(identity+'-balanced.epub')
                    run(cli(runtime, source, balanced, '--image-quality', 'balanced'))
                    item['balanced_epub_size'] = balanced.stat().st_size
                assert digest(source.read_bytes())==expected
                assert not list(runtime.glob('.homelib-convert-*'))
                assert not list(runtime.glob('homelib-text-source-*'))
                assert not list(runtime.glob('homelib-image-quality-*'))
                cases.append(item)
                print('PASS '+platform+' '+identity+' source/copy/text/images/roundtrip'+(' and estimates/cancel/balanced' if 'estimates' in item else ''), flush=True)
            runtime_bin = ROOT/('Program/Out/Bin' if platform=='Win32' else 'Program/Out/Bin64')
            environment = dict(os.environ, TEMP=str(args.temporary_root), TMP=str(args.temporary_root),
                HLRU_PYTHON=sys.executable, HOMELIB_FORMAT_COMPONENT_PACKAGES=str(packages))
            native = run([args.node, ROOT/'tools/ui/tests/native_collection_tests.js', runtime_bin, '-', '-',
                ROOT/f'tools/ui/tests/Out/{platform}/CollectionViewsTest.exe', '--views-mode=builtin-export',
                '--conversion-fixtures='+str(args.conversion_fixtures)], env=environment)
            report['platforms'][platform] = {'cases':cases, 'native_export_passed':True,
                'native_passes':[line for line in native.splitlines() if 'PASS ' in line]}
            print('PASS '+platform+' native export regression with current packaged module', flush=True)
        if args.extra_source_zip:
            assert args.extra_source_zip.read_bytes()==original_zip, 'Tester ZIP changed'
    report['temporary_payloads_removed'] = not temporary.exists()
    assert report['temporary_payloads_removed']
    with args.report.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print('PASS all owned temporary payloads removed; report '+str(args.report), flush=True)


if __name__ == '__main__':
    main()

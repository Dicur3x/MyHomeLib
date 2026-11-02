"""Compare actual packaged image profiles in raw FB2, FB2.ZIP and EPUB.

No source books are read: the illustrated fixture is deterministic and owned.
The embedded Python and native image helper come from verified release ZIPs.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

from reader_save_first_use_smoke import image_fixture

REPO = Path(__file__).resolve().parents[3]
CACHE = Path('G:/HomeLibRu-build-cache')
PACKAGES = CACHE / 'HomeLibre-3beta1-release-20261030-r1/formats'
OWNER = 'HomeLibre container-aware image profile probe v1'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def owned(state):
    root = Path(state['root']).resolve(strict=True)
    assert root.parent == CACHE.resolve(strict=True)
    assert root.name.startswith('HomeLibRu-image-container-profile-')
    assert not root.is_symlink() and not root.is_junction()
    assert json.loads((root / 'owned-test.marker').read_bytes()) == dict(owner=OWNER, token=state['token'])
    return root


def image_in(output):
    if output.suffix == '.fb2':
        document = ET.fromstring(output.read_bytes())
        images = [base64.b64decode(n.text) for n in document if n.tag.endswith('}binary')]
    else:
        with zipfile.ZipFile(output) as book:
            assert book.testzip() is None
            images = [book.read(name) for name in book.namelist() if '/images/' in name and not name.endswith('/')]
    assert len(images) == 1
    return images[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('stage', 'compare', 'cleanup'))
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--label', choices=('published', 'candidate'))
    args = parser.parse_args()
    state = json.loads(args.state.read_bytes()) if args.state.exists() else None
    if args.action == 'stage':
        assert state is None
        root = Path(tempfile.mkdtemp(prefix='HomeLibRu-image-container-profile-', dir=CACHE))
        state = dict(root=str(root), token=uuid.uuid4().hex, stages={}, scope='Actual embedded runtimes, native image helper and converter; deterministic illustrated FB2 fixture. No GUI or performance-benchmark claim.')
        (root / 'owned-test.marker').write_text(json.dumps(dict(owner=OWNER, token=state['token'])))
        picture = image_fixture()
        source = root / 'illustrated-gradient.fb2'
        source.write_text('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'
            '<description><title-info><genre>science</genre><author><nickname>HomeLibre fixture</nickname></author>'
            '<book-title>Проверка размера ё</book-title><lang>ru</lang></title-info>'
            '<document-info><author><nickname>HomeLibre</nickname></author><date>2026-10-31</date>'
            '<id>container-profile-gradient-fixture</id><version>1.0</version></document-info></description>'
            '<body><section><title><p>Иллюстрация</p></title><p>Текст перед иллюстрацией.</p>'
            '<image l:href="#picture"/><p>Текст после иллюстрации.</p></section></body>'
            '<binary id="picture" content-type="image/png">' + base64.b64encode(picture).decode()
            + '</binary></FictionBook>', encoding='utf-8')
        state.update(source=str(source), source_sha256=sha(source), packages=[])
        for platform in ('Win32', 'Win64'):
            app = root / platform
            app.mkdir()
            for component in ('BookProcessing', 'ImageProcessing'):
                package = PACKAGES / f'HomeLibRu-{component}-3.0.0.1-{platform}.zip'
                with zipfile.ZipFile(package) as archive:
                    manifest = json.loads(archive.read('HomeLibRu.update.json'))
                    assert manifest['component'] == component and manifest['platform'] == platform
                    assert set(archive.namelist()) == {'HomeLibRu.update.json'} | {f['path'] for f in manifest['files']}
                    assert len(archive.namelist()) == len(set(archive.namelist()))
                    for item in manifest['files']:
                        relative = Path(item['path'])
                        assert not relative.is_absolute() and '..' not in relative.parts and ':' not in item['path']
                        data = archive.read(item['path'])
                        assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
                        path = app / relative
                        assert not path.exists()
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(data)
                state['packages'].append(dict(platform=platform, component=component, sha256=sha(package)))
    elif args.action == 'compare':
        assert state and args.label and args.label not in state['stages']
        root = owned(state)
        source = Path(state['source'])
        assert sha(source) == state['source_sha256']
        results = []
        for platform in ('Win32', 'Win64'):
            app = root / platform
            tools = app / 'tools'
            if args.label == 'candidate':
                # Record every explicit development override; release ZIPs stay unchanged.
                for name in ('image_quality.py', 'convert_book.py'):
                    shutil.copyfile(REPO / 'tools/bookconvert' / name, tools / 'bookconvert' / name)
            folder = root / (args.label + '-' + platform)
            folder.mkdir()
            for extension in ('fb2', 'epub'):
                outputs = []
                for profile in ('balanced', 'economy'):
                    output = folder / (profile + '.' + extension)
                    command = [str(tools / 'python/python.exe'), '-B', '-X', 'utf8', str(tools / 'bookconvert/convert_book.py'),
                               str(source), str(output), '--tools-root', str(tools), '--image-quality', profile]
                    started = time.monotonic()
                    result = subprocess.run(command, cwd=app, env=dict(os.environ, TEMP=str(root), TMP=str(root)),
                        capture_output=True, encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW, timeout=120)
                    assert result.returncode == 0, result.stdout + result.stderr
                    report = json.loads(result.stdout.strip())
                    image = image_in(output)
                    row = dict(platform=platform, format=extension, profile=profile, output_bytes=output.stat().st_size,
                        image_bytes=len(image), image_sha256=hashlib.sha256(image).hexdigest(), output_sha256=sha(output),
                        elapsed_seconds=round(time.monotonic() - started, 3), conversion_report=report)
                    if extension == 'fb2':
                        zip_source = output
                        if args.label == 'candidate':
                            # Final FB2.ZIP has its own optimal image candidate;
                            # do not measure a ZIP of the raw-FB2 choice instead.
                            zip_source = folder / (profile + '-forzip.fb2')
                            zip_command = list(command)
                            zip_command[6] = str(zip_source)
                            zip_command += ['--image-container','fb2-zip']
                            packed_result = subprocess.run(zip_command,cwd=app,
                                env=dict(os.environ,TEMP=str(root),TMP=str(root)),capture_output=True,
                                encoding='utf-8-sig',creationflags=subprocess.CREATE_NO_WINDOW,timeout=120)
                            assert packed_result.returncode == 0,packed_result.stdout+packed_result.stderr
                            row['fb2_zip_image_bytes'] = len(image_in(zip_source))
                        zipped = output.with_suffix('.fb2.zip')
                        with zipfile.ZipFile(zipped, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                            archive.writestr('book.fb2', zip_source.read_bytes())
                        row['fb2_zip_bytes'] = zipped.stat().st_size
                    outputs.append(row)
                balanced, economy = outputs
                comparison = dict(platform=platform, format=extension, results=outputs,
                    economy_larger=economy['output_bytes'] > balanced['output_bytes'] + 256)
                if extension == 'fb2':
                    comparison['economy_zip_larger'] = economy['fb2_zip_bytes'] > balanced['fb2_zip_bytes'] + 256
                results.append(comparison)
            assert sha(source) == state['source_sha256']
        if args.label == 'candidate':
            assert all(not row['economy_larger'] and not row.get('economy_zip_larger',False) for row in results),results
        state['stages'][args.label] = dict(results=results, converter_hashes={platform: {
            name: sha(root / platform / 'tools/bookconvert' / name) for name in ('convert_book.py', 'image_quality.py')}
            for platform in ('Win32', 'Win64')}, source_preserved=True)
    elif args.action == 'cleanup':
        root = owned(state)
        assert 'published' in state['stages']
        if 'candidate' not in state['stages']:
            # A verified baseline can be checkpointed before an urgent bugfix;
            # its large runtimes need not occupy disk while that work proceeds.
            assert len(state['stages']['published']['results']) == 4
            assert all(row['economy_larger'] if row['format']=='epub' else row['economy_zip_larger']
                       for row in state['stages']['published']['results'])
            state['status'] = 'BASELINE REPRODUCED; candidate fix not yet tested'
        assert not state.get('cleanup_denied')
        assert owned(state) == root
        shutil.rmtree(root)
        state['temporary_profile_removed'] = not root.exists()
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(root=state['root'], stages={name:[{k:v for k,v in row.items() if k!='results'} | {
        'sizes':[{k:result[k] for k in ('profile','output_bytes','image_bytes','fb2_zip_bytes') if k in result}
                 for result in row['results']]} for row in stage['results']] for name,stage in state['stages'].items()},
        cleaned=state.get('temporary_profile_removed',False)), ensure_ascii=False))


if __name__ == '__main__':
    main()

"""Drive the ordinary catalogue command in an isolated portable installation.

The native fixture operates its actual controls. This wrapper verifies the
physical shared ZIP and original-book backups independently after the UI exits.
Never points the catalogue at a user's source folder or personal database.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from supervised_test_process import run_owned
import time
import zipfile
from xml.etree import ElementTree as ET

from pack_collection import temporary_work_directory
from test_pack_collection import illustrated_fb2, image_fixture
from prepare_book_compression import verify_non_image_content


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive_body(archive, member, seven_zip):
    try:
        with zipfile.ZipFile(archive) as source:
            return source.read(member)
    except NotImplementedError:  # PPMd ZIP: use the shipped independent decoder.
        result = run_owned([str(seven_zip), 'e', '-so', '-bd', '-y', '--', str(archive), member],
                                capture_output=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
        return result.stdout


def descriptor(root, platform, component, version, name, files):
    data = dict(format=1, component=component, platform=platform, version=version,
                identities={f: digest(root / f) for f in files})
    (root / name).write_text(json.dumps(data), encoding='utf-8')


def install_processing_package(package, root, platform):
    """Validate the exact package before writing into the private fixture."""
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        assert (manifest['component'], manifest['platform'], manifest['version']) == ('BookProcessing', platform, '3.0.0.14')
        entries = manifest['files']
        names = [item['path'] for item in entries]
        assert len(set(names)) == len(names)
        assert len(archive.namelist()) == len(names) + 1
        assert set(archive.namelist()) == set(names) | {'HomeLibRu.update.json'}
        for item in entries:
            name = item['path']
            assert name.startswith(('tools/python/', 'tools/bookconvert/'))
            assert '\\' not in name and ':' not in name and '..' not in Path(name).parts
            body = archive.read(name)
            assert len(body) == item['size'] and hashlib.sha256(body).hexdigest() == item['sha256']
        component = json.loads(archive.read('tools/bookconvert/MODULAR_RUNTIME.json'))
        assert 'tools/bookconvert/compression_preview.py' in component['required']
        for name, expected in component['identities'].items():
            assert name in names and hashlib.sha256(archive.read(name)).hexdigest() == expected
        for name in names:
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(name))


def run(binary, runtime, sqlite, icons, genres, stage, platform, mode, real_books=None, inspect_comparison=False,
        processing_package=None, estimate_first=False, whole=False, repeat_new=False, images=None):
    with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
        root = Path(root)
        shutil.copy2(binary, root / 'CollectionViewsTest.exe')
        shutil.copy2(sqlite, root / 'sqlite3.dll')
        (root / 'Icons').mkdir()
        shutil.copy2(icons, root / 'Icons' / 'MHLIcons.dll')
        shutil.copy2(genres, root / 'genres_fb2.glst')
        shutil.copytree(runtime / 'tools', root / 'tools')
        repo = Path(__file__).resolve().parents[2]
        if images:
            info = json.loads((images / 'RUNTIME.json').read_text(encoding='utf-8-sig'))
            assert info['platform'] == platform
            assert info['source_sha256'] == digest(repo / 'Utils/HomeLibXps/HomeLibXps.cs')
            assert info['sha256'] == digest(images / 'HomeLibImages.exe')
            assert not (root / 'tools/images/HomeLibImages.exe.config').exists()
            shutil.copytree(images, root / 'tools/images', dirs_exist_ok=True)
        if processing_package:
            install_processing_package(processing_package, root, platform)
        else:
            for file in ('prepare_book_compression.py', 'archive_replacement.py', 'pack_collection.py', 'compression_preview.py',
                         'estimate_book_compression.py'):
                shutil.copy2(repo / 'tools/collectionpack' / file, root / 'tools/bookconvert' / file)
        for marker in ('uselocaldata', 'uselocaltemp'):
            (root / marker).touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        # This fixture tests compression, not public update checks or metadata
        # downloads. Keep unrelated network work out of timing and UI focus.
        (root / 'myhomelib2.ini').write_text(
            '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
            '[INTERFACE]\nWindowsDarkThemeOfferDismissed=1\n', encoding='utf-8')
        if not processing_package:
            descriptor(root, platform, 'BookProcessing', '3.0.0.14', 'tools/bookconvert/MODULAR_RUNTIME.json', [
            'tools/python/python.exe', 'tools/python/python313.dll', 'tools/python/python313.zip',
            'tools/python/python313._pth', 'tools/bookconvert/convert_book.py', 'tools/bookconvert/MODULAR_API.txt',
            'tools/bookconvert/pack_collection.py', 'tools/bookconvert/image_quality.py',
            'tools/bookconvert/catalogdump/build_index.py', 'tools/bookconvert/catalogdump/mysql_dump.py',
            'tools/bookconvert/prepare_book_compression.py', 'tools/bookconvert/archive_replacement.py',
                'tools/bookconvert/compression_preview.py', 'tools/bookconvert/estimate_book_compression.py'])
        descriptor(root, platform, 'ImageProcessing', '3.0.0.14', 'tools/images/COMPONENT.json', [
            'tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt'])
        originals = {'one.fb2': illustrated_fb2(image_fixture(True)),
                     'two.fb2': illustrated_fb2(image_fixture(False)).replace(b'this text', b'the second text'),
                     'neighbor.fb2': b'Unselected neighbor must remain byte-exact.\x00\xff'}
        real_stamps = {}
        if real_books:
            manifest = json.loads(real_books.read_text(encoding='utf-8-sig'))
            assert set(manifest) == {'one.fb2', 'two.epub', 'neighbor.fb2'}
            originals = {}
            for name, spec in manifest.items():
                path = Path(spec['archive']).resolve(strict=True)
                info = path.stat()
                real_stamps[path] = (info.st_ino, info.st_size, info.st_mtime_ns)
                with zipfile.ZipFile(path) as archive:
                    assert archive.getinfo(spec['member']).file_size <= 128 * 1024 * 1024
                    originals[name] = archive.read(spec['member'])
            (root / 'compression-fixture.json').write_text(json.dumps(dict(
                first='one.fb2', second='two.epub', grayscale=False, timeout_ms=300000,
                inspect_comparison=inspect_comparison)), encoding='utf-8')
        selected = [name for name in originals if name != 'neighbor.fb2']
        if inspect_comparison and not real_books:
            (root / 'compression-fixture.json').write_text(json.dumps(dict(
                first='one.fb2', second='two.fb2', grayscale=True, timeout_ms=90000,
                inspect_comparison=True)), encoding='utf-8')
        if estimate_first or whole or repeat_new:
            fixture_file = root / 'compression-fixture.json'
            config = json.loads(fixture_file.read_text(encoding='utf-8')) if fixture_file.exists() else {}
            config['estimate_first'] = estimate_first
            config['whole'] = whole
            config['repeat_new'] = repeat_new
            fixture_file.write_text(json.dumps(config), encoding='utf-8')
        (root / 'books').mkdir()
        source = root / 'books/shared.zip'
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, body in originals.items():
                archive.writestr(name, body)
        before, size = digest(source), source.stat().st_size
        started = time.monotonic()
        startup = None
        if inspect_comparison:
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 5
        # Keep the native log while it runs. A hard outer deadline must not
        # discard the only evidence explaining where the private GUI stopped.
        # The real-book fixture itself allows 300 s *after* its application
        # bootstrap; leave separate room for bootstrap and orderly teardown.
        deadline = 420 if real_books else 150
        attempt = dict(status='INCOMPLETE', platform=platform, mode=mode,
            native_binary_sha256=digest(binary), outer_timeout_seconds=deadline,
            private_runtime=str(root),
            real_source_stamps={str(path): stamp for path, stamp in real_stamps.items()})
        attempt_file = stage / f'catalogue-{platform}-{mode}-attempt.json'
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        log_path = stage / f'catalogue-{platform}-{mode}.log'
        env = {**os.environ, 'TEMP': str(root), 'TMP': str(root),
               'LOCALAPPDATA': str(root / 'Local'), 'APPDATA': str(root / 'Roaming')}
        try:
            with log_path.open('wb') as log:
                process = run_owned([str(root / 'CollectionViewsTest.exe'), 'selected-compression-ui', mode],
                    cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, startupinfo=startup, timeout=deadline,
                    creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS |
                        (0 if inspect_comparison else subprocess.CREATE_NO_WINDOW))
        except subprocess.TimeoutExpired:
            notes = []
            for p in root.rglob('*.json'):
                if 'tools' not in p.relative_to(root).parts and p.stat().st_size < 32768:
                    notes.append(str(p.relative_to(root)) + '\n' + p.read_text(encoding='utf-8-sig', errors='replace'))
            (stage / f'catalogue-{platform}-{mode}-diagnostics.txt').write_text('\n'.join(notes), encoding='utf-8')
            attempt.update(status='TIMEOUT', seconds=round(time.monotonic()-started, 3),
                originals_unchanged=all((path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) == stamp
                    for path, stamp in real_stamps.items()))
            attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
            raise
        output = log_path.read_text(encoding='utf-8', errors='replace')
        if process.returncode or f'PASS selected compression normal catalogue {mode}' not in output:
            # Keep only bounded text diagnostics; do not retain the runtime or books.
            notes = []
            for p in root.rglob('*.json'):
                if 'tools' not in p.relative_to(root).parts and p.stat().st_size < 32768:
                    notes.append(str(p.relative_to(root)) + '\n' + p.read_text(encoding='utf-8-sig', errors='replace'))
            (stage / f'catalogue-{platform}-{mode}-diagnostics.txt').write_text('\n'.join(notes), encoding='utf-8')
            attempt.update(status='FAIL', returncode=process.returncode,
                seconds=round(time.monotonic()-started, 3),
                originals_unchanged=all((path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) == stamp
                    for path, stamp in real_stamps.items()))
            attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
            raise AssertionError(f'Catalogue {platform} {mode}: exit {process.returncode}\n{output}')
        attempt.update(status='VERIFYING_CONTENT', native_returncode=process.returncode)
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        with zipfile.ZipFile(source) as archive:
            assert set(archive.namelist()) == set(originals)
            assert archive_body(source, 'neighbor.fb2', root / 'tools/7zip/7za.exe') == originals['neighbor.fb2']
            if mode == 'apply':
                assert source.stat().st_size < size
                for name in selected:
                    body = archive_body(source, name, root / 'tools/7zip/7za.exe')
                    if name.endswith('.epub'):
                        before_file, after_file = root / 'original.epub', root / 'result.epub'
                        before_file.write_bytes(originals[name]); after_file.write_bytes(body)
                        verify_non_image_content(before_file, after_file, '.epub')
                        # Independently assert every textual/style/font member.
                        with zipfile.ZipFile(before_file) as old, zipfile.ZipFile(after_file) as new:
                            assert old.namelist() == new.namelist()
                            for member in old.namelist():
                                if Path(member).suffix.lower() in {'.xhtml', '.html', '.htm', '.css', '.ttf', '.otf', '.woff', '.woff2', '.ncx'}:
                                    assert old.read(member) == new.read(member), member
                        continue
                    original = ET.fromstring(originals[name])
                    result = ET.fromstring(body)
                    # Full semantic text/formatting except deliberate image bytes.
                    for tree in (original, result):
                        for node in tree.iter('{http://www.gribuser.ru/xml/fictionbook/2.0}binary'):
                            node.text = ''
                            # PNG may deliberately become JPEG in the economy
                            # profile; identifiers/references must stay intact.
                            node.attrib.pop('content-type', None)
                    assert ET.tostring(original) == ET.tostring(result), name
            else:
                assert digest(source) == before
        backups = list((root / 'originals').glob('*.zip'))
        if mode == 'apply':
            assert len(backups) == 1
            with zipfile.ZipFile(backups[0]) as backup:
                assert set(backup.namelist()) == {'HomeLibre-originals.json'} | {'books/' + name for name in selected}
                for name in selected:
                    assert backup.read('books/' + name) == originals[name]
        else:
            assert not backups
        for path, stamp in real_stamps.items():
            info = path.stat()
            assert (info.st_ino, info.st_size, info.st_mtime_ns) == stamp, 'Real source archive changed'
        attempt.update(status='PASS', returncode=process.returncode,
            seconds=round(time.monotonic()-started, 3), originals_unchanged=True)
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        return dict(status='PASS', platform=platform, mode=mode, seconds=round(time.monotonic()-started, 3),
                    before_bytes=size, after_bytes=source.stat().st_size, native_binary_sha256=digest(binary),
                    processing_package_sha256=digest(processing_package) if processing_package else None,
                    input_sha256={name: hashlib.sha256(body).hexdigest() for name, body in originals.items()},
                    real_source_stamps={str(path): stamp for path, stamp in real_stamps.items()},
                    whole=whole,
                    repeat_new=repeat_new,
                    private_runtime=str(root),
                    image_helper_sha256=digest(root / 'tools/images/HomeLibImages.exe'),
                    scope='Ordinary catalogue command; real payloads in a private shared ZIP, original archives read only'
                        if real_books else 'Ordinary menu action and controls; isolated synthetic shared ZIP only')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'runtime', 'sqlite', 'icons', 'genres', 'stage'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--mode', choices=['apply', 'skip', 'stop', 'estimate'], required=True)
    parser.add_argument('--real-books', type=Path)
    parser.add_argument('--inspect-comparison', action='store_true')
    parser.add_argument('--processing-package', type=Path)
    parser.add_argument('--estimate-first', action='store_true')
    parser.add_argument('--whole', action='store_true')
    parser.add_argument('--repeat-new', action='store_true', help='After applying, invoke the normal new-books menu and verify no preparation')
    parser.add_argument('--images', type=Path, help='Fresh image helper verified against the current C# source')
    args = parser.parse_args()
    report = args.stage / f'catalogue-{args.platform}-{args.mode}.json'
    try:
        result = run(**vars(args))
        result['private_runtime_removed'] = not Path(result['private_runtime']).exists()
        assert result['private_runtime_removed'], 'Owned catalogue fixture runtime was not removed'
    except BaseException as error:
        attempt_file = args.stage / f'catalogue-{args.platform}-{args.mode}-attempt.json'
        attempt = json.loads(attempt_file.read_text(encoding='utf-8')) if attempt_file.exists() else {}
        unchanged = all((Path(path).stat().st_ino, Path(path).stat().st_size, Path(path).stat().st_mtime_ns) == tuple(stamp)
                        for path, stamp in attempt.get('real_source_stamps', {}).items())
        result = dict(status='FAIL', platform=args.platform, mode=args.mode,
                      error=type(error).__name__ + ': ' + str(error),
                      last_phase=attempt.get('status'), originals_unchanged=unchanged)
        report.write_text(json.dumps(result, indent=2), encoding='utf-8')
        raise
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))

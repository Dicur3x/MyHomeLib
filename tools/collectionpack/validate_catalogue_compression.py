"""Drive the ordinary catalogue command in an isolated portable installation.

The native fixture operates its actual controls. This wrapper verifies the
physical shared ZIP and original-book backups independently after the UI exits.
Never points the catalogue at a user's source folder or personal database.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import zipfile
from xml.etree import ElementTree as ET

from pack_collection import temporary_work_directory
from test_pack_collection import illustrated_fb2, image_fixture


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive_body(archive, member, seven_zip):
    try:
        with zipfile.ZipFile(archive) as source:
            return source.read(member)
    except NotImplementedError:  # PPMd ZIP: use the shipped independent decoder.
        result = subprocess.run([str(seven_zip), 'e', '-so', '-bd', '-y', '--', str(archive), member],
                                capture_output=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
        return result.stdout


def descriptor(root, platform, component, version, name, files):
    data = dict(format=1, component=component, platform=platform, version=version,
                identities={f: digest(root / f) for f in files})
    (root / name).write_text(json.dumps(data), encoding='utf-8')


def run(binary, runtime, sqlite, icons, genres, stage, platform, mode):
    with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
        root = Path(root)
        shutil.copy2(binary, root / 'CollectionViewsTest.exe')
        shutil.copy2(sqlite, root / 'sqlite3.dll')
        (root / 'Icons').mkdir()
        shutil.copy2(icons, root / 'Icons' / 'MHLIcons.dll')
        shutil.copy2(genres, root / 'genres_fb2.glst')
        shutil.copytree(runtime / 'tools', root / 'tools')
        repo = Path(__file__).resolve().parents[2]
        for file in ('prepare_book_compression.py', 'archive_replacement.py', 'pack_collection.py'):
            shutil.copy2(repo / 'tools/collectionpack' / file, root / 'tools/bookconvert' / file)
        for marker in ('uselocaldata', 'uselocaltemp'):
            (root / marker).touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        descriptor(root, platform, 'BookProcessing', '3.0.0.14', 'tools/bookconvert/MODULAR_RUNTIME.json', [
            'tools/python/python.exe', 'tools/python/python313.dll', 'tools/python/python313.zip',
            'tools/python/python313._pth', 'tools/bookconvert/convert_book.py', 'tools/bookconvert/MODULAR_API.txt',
            'tools/bookconvert/pack_collection.py', 'tools/bookconvert/image_quality.py',
            'tools/bookconvert/catalogdump/build_index.py', 'tools/bookconvert/catalogdump/mysql_dump.py',
            'tools/bookconvert/prepare_book_compression.py', 'tools/bookconvert/archive_replacement.py'])
        descriptor(root, platform, 'ImageProcessing', '3.0.0.8', 'tools/images/COMPONENT.json', [
            'tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt'])
        originals = {'one.fb2': illustrated_fb2(image_fixture(True)),
                     'two.fb2': illustrated_fb2(image_fixture(False)).replace(b'this text', b'the second text'),
                     'neighbor.fb2': b'Unselected neighbor must remain byte-exact.\x00\xff'}
        (root / 'books').mkdir()
        source = root / 'books/shared.zip'
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, body in originals.items():
                archive.writestr(name, body)
        before, size = digest(source), source.stat().st_size
        started = time.monotonic()
        process = subprocess.run([str(root / 'CollectionViewsTest.exe'), 'selected-compression-ui', mode],
                                 cwd=root, capture_output=True, timeout=100)
        output = (process.stdout + process.stderr).decode('utf-8', errors='replace')
        (stage / f'catalogue-{platform}-{mode}.log').write_text(output, encoding='utf-8')
        if process.returncode or f'PASS selected compression normal catalogue {mode}' not in output:
            # Keep only bounded text diagnostics; do not retain the runtime or books.
            notes = []
            for p in root.rglob('*.json'):
                if 'tools' not in p.relative_to(root).parts and p.stat().st_size < 32768:
                    notes.append(str(p.relative_to(root)) + '\n' + p.read_text(encoding='utf-8-sig', errors='replace'))
            (stage / f'catalogue-{platform}-{mode}-diagnostics.txt').write_text('\n'.join(notes), encoding='utf-8')
            raise AssertionError(f'Catalogue {platform} {mode}: exit {process.returncode}\n{output}')
        with zipfile.ZipFile(source) as archive:
            assert set(archive.namelist()) == set(originals)
            assert archive.read('neighbor.fb2') == originals['neighbor.fb2']
            if mode == 'apply':
                assert source.stat().st_size < size
                for name in ('one.fb2', 'two.fb2'):
                    original = ET.fromstring(originals[name])
                    result = ET.fromstring(archive_body(source, name, root / 'tools/7zip/7za.exe'))
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
                assert set(backup.namelist()) == {'HomeLibre-originals.json', 'books/one.fb2', 'books/two.fb2'}
                for name in ('one.fb2', 'two.fb2'):
                    assert backup.read('books/' + name) == originals[name]
        else:
            assert not backups
        return dict(status='PASS', platform=platform, mode=mode, seconds=round(time.monotonic()-started, 3),
                    before_bytes=size, after_bytes=source.stat().st_size, native_binary_sha256=digest(binary),
                    scope='Ordinary menu action and controls; isolated synthetic shared ZIP only')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'runtime', 'sqlite', 'icons', 'genres', 'stage'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--mode', choices=['apply', 'skip', 'stop'], required=True)
    args = parser.parse_args()
    result = run(**vars(args))
    (args.stage / f'catalogue-{args.platform}-{args.mode}.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))

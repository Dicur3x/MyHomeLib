"""Ordinary copy/register/update menus; interact with owned dialogs via Computer Use."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest
import zipfile

from pack_collection import temporary_work_directory
from prepare_book_compression import verify_non_image_content
from supervised_test_process import run_owned
from test_real_container_compression import verify_grayscale
from validate_catalogue_compression import descriptor, digest, install_processing_package


def run(args):
    assert os.name == 'nt'
    assert shutil.disk_usage('C:/').free >= 8 * 1024**3
    assert args.stage.resolve().drive.lower() != 'c:'
    inventory = json.loads(args.inputs.read_text(encoding='utf-8'))
    assert inventory['status'] == 'PASS' and set(inventory['inputs']) == {'.cbz', '.docx', '.odt'}
    stamps, bodies = {}, {}
    for extension, row in inventory['inputs'].items():
        raw = Path(row['path'])
        assert not raw.is_symlink()
        path = raw.resolve(strict=True)
        assert path.parent == args.inputs.resolve().parent and path.name == 'input' + extension
        assert 0 < path.stat().st_size == row['bytes'] <= 16 * 1024**2
        assert digest(path) == row['sha256']
        bodies[extension] = path.read_bytes()
        for item in (path, Path(row['source']).resolve(strict=True)):
            info = item.stat()
            stamps[item] = (info.st_ino, info.st_size, info.st_mtime_ns)
        assert stamps[Path(row['source']).resolve()] == tuple(row['source_stamp'][k] for k in ('ino', 'size', 'mtime_ns'))
    started = time.monotonic()
    log = args.stage / 'copy-ui.log'
    attempt = args.stage / 'copy-ui-attempt.json'
    with temporary_work_directory(args.stage, 'HomeLibRu-native-') as root:
        root = Path(root)
        shutil.copy2(args.binary, root / 'CollectionViewsTest.exe')
        shutil.copy2(args.sqlite, root / 'sqlite3.dll')
        (root / 'Icons').mkdir()
        shutil.copy2(args.icons, root / 'Icons/MHLIcons.dll')
        shutil.copy2(args.genres, root / 'genres_fb2.glst')
        shutil.copytree(args.runtime / 'tools', root / 'tools')
        install_processing_package(args.package, root, args.platform)
        image = json.loads((args.images / 'RUNTIME.json').read_text(encoding='utf-8-sig'))
        assert image['platform'] == args.platform and image['sha256'] == digest(args.images / 'HomeLibImages.exe')
        assert image['source_sha256'] == digest(Path(__file__).resolve().parents[2] / 'Utils/HomeLibXps/HomeLibXps.cs')
        shutil.copytree(args.images, root / 'tools/images', dirs_exist_ok=True)
        descriptor(root, args.platform, 'ImageProcessing', '3.0.0.14', 'tools/images/COMPONENT.json', [
            'tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt'])
        for name in ('uselocaldata', 'uselocaltemp'):
            (root / name).touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        (root / 'myhomelib2.ini').write_text(
            '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
            '[INTERFACE]\nWindowsDarkThemeOfferDismissed=1\n', encoding='utf-8')
        for name in ('copy-originals', 'packed-copy', 'copy-incoming', 'known-inputs'):
            (root / name).mkdir()
        selected = [('101', '.cbz'), ('102', '.docx'), ('103', '.odt'), ('104', '.docx')]
        originals = {identity + extension: bodies[extension] for identity, extension in selected}
        for name, body in originals.items():
            (root / 'known-inputs' / name).write_bytes(body)
        with zipfile.ZipFile(root / 'copy-originals/shared.zip', 'w', zipfile.ZIP_STORED) as archive:
            for name, body in originals.items():
                if name != '104.docx':
                    archive.writestr(name, body)
        with zipfile.ZipFile(root / 'copy-incoming/new.zip', 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('104.docx', originals['104.docx'])
        def row(identity, extension):
            return '\x04'.join(('CopyAuthor:', 'prose_contemporary:', 'Copy UI ' + identity, '', '',
                identity, str(len(originals[identity + extension])), identity, '0', extension[1:], '2026-11-15', 'ru'))
        with zipfile.ZipFile(root / 'copy-incoming/update.inpx', 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('structure.info', 'AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG')
            archive.writestr('version.info', '20261115')
            archive.writestr('shared.inp', '\n'.join(row(i, e) for i, e in selected[:3]) + '\n')
            archive.writestr('new.inp', row(*selected[3]) + '\n')
        protected = {p: digest(p) for p in (root / 'copy-originals/shared.zip', root / 'copy-incoming/new.zip', root / 'copy-incoming/update.inpx')}
        state = dict(status='RUNNING', private_runtime=str(root), binary_sha256=digest(args.binary),
            package_sha256=digest(args.package), output=str(root / 'packed-copy'),
            inpx=str(root / 'copy-incoming/update.inpx'), incoming=str(root / 'copy-incoming'))
        attempt.write_text(json.dumps(state, indent=2), encoding='utf-8')
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 5
        env = {**os.environ, 'TEMP': str(root), 'TMP': str(root),
            'LOCALAPPDATA': str(root / 'Local'), 'APPDATA': str(root / 'Roaming')}
        with log.open('wb') as stream:
            process = run_owned([str(root / 'CollectionViewsTest.exe'), 'packing-copy-ui'], cwd=root,
                env=env, stdout=stream, stderr=subprocess.STDOUT, startupinfo=startup,
                creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS, timeout=900)
        assert process.returncode == 0, log.read_text(encoding='utf-8', errors='replace')[-6000:]
        result = json.loads((root / 'copy-ui-results.json').read_text(encoding='utf-8-sig'))
        assert len({result['source'], result['first'], result['updated']}) == 3
        assert result['reviews'] == 2 and result['reused'] >= 1
        evidence = {}
        for identity, extension in selected:
            name = identity + extension
            after = root / 'decoded-updated' / name
            before = root / 'known-inputs' / name
            verify_non_image_content(before, after, extension)
            verify_grayscale(unittest.TestCase(), after, extension)
            assert after.stat().st_size < len(originals[name])
            if identity != '104':
                assert after.read_bytes() == (root / 'decoded-first' / name).read_bytes()
            evidence[name] = dict(before_bytes=len(originals[name]), after_bytes=after.stat().st_size,
                sha256=digest(after))
        assert all(digest(path) == sha for path, sha in protected.items())
        for path, stamp in stamps.items():
            info = path.stat()
            assert (info.st_ino, info.st_size, info.st_mtime_ns) == stamp
        assert not list((root / 'packed-copy').glob('.job-*'))
        assert shutil.disk_usage('C:/').free >= 8 * 1024**3
        state.update(status='PASS', evidence=evidence, registration=result,
            seconds=round(time.monotonic()-started, 3))
        attempt.write_text(json.dumps(state, indent=2), encoding='utf-8')
    state['private_runtime_removed'] = not root.exists()
    assert state['private_runtime_removed']
    return state


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'runtime', 'sqlite', 'icons', 'genres', 'stage', 'package', 'images', 'inputs'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    args = parser.parse_args()
    report = args.stage / 'report.json'
    try:
        result = run(args)
    except BaseException as error:
        result = dict(status='FAIL', error=type(error).__name__ + ': ' + str(error))
        report.write_text(json.dumps(result, indent=2), encoding='utf-8')
        raise
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))

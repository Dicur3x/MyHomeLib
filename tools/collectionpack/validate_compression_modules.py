"""Actual compact module download/cancel/install/restart and selected compression.

The generated fixture owns its entire portable profile. Network transport is
redirected by the native diagnostic to loopback; manifest/hash checks, the real
installation helper, successor and catalogue compression remain unchanged.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time
import traceback
import zipfile

from pack_collection import temporary_work_directory
from prepare_book_compression import verify_non_image_content
from supervised_test_process import run_owned
from validate_catalogue_compression import archive_body
from validate_compression_inspection import check_pe


def signature(path):
    return dict(bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def candidate(folder, component, platform, fixture):
    feed = json.loads((folder / 'format-components.json').read_text(encoding='utf-8'))
    entry, = (entry for entry in feed['components'] if (entry['id'], entry['platform']) == (component, platform))
    assert entry['version'] == '3.0.0.14'
    name = entry['archive']
    assert Path(name).name == name and '/' not in name and '\\' not in name
    path = folder / name
    assets = json.loads((folder / 'format-component-assets.json').read_text(encoding='utf-8'))
    asset, = (asset for asset in assets if asset['name'] == name)
    identity = signature(path)
    assert asset['digest'] == 'sha256:' + identity['sha256'] and asset['size'] == identity['bytes']
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        assert (manifest['component'], manifest['platform'], manifest['version']) == (component, platform, entry['version'])
        assert len(archive.namelist()) == len(manifest['files']) + 1
        for item in manifest['files']:
            body = archive.read(item['path'])
            assert len(body) == item['size'] and hashlib.sha256(body).hexdigest() == item['sha256']
    shutil.copy2(path, fixture / name)
    return dict(id=component, version=entry['version'], name=name, sha256=identity['sha256'],
                size=identity['bytes'], url=asset['browser_download_url'])


def run(args):
    stage = args.stage.resolve(strict=True)
    started = time.monotonic()
    result = dict(status='INCOMPLETE', platform=args.platform,
                  binary=signature(args.binary), installer=signature(args.helper))
    report = stage / 'report.json'
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    try:
        with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
            result['private_runtime'] = str(root)
            for path in (args.binary, args.helper, args.sqlite, args.icons):
                check_pe(path, args.platform)
            shutil.copy2(args.binary, root / args.binary.name)
            shutil.copy2(args.helper, root / 'HomeLibRuUpdater.exe')
            shutil.copy2(args.sqlite, root / 'sqlite3.dll')
            (root / 'Icons').mkdir()
            shutil.copy2(args.icons, root / 'Icons/MHLIcons.dll')
            shutil.copy2(args.genres, root / 'genres_fb2.glst')
            shutil.copytree(args.runtime / 'tools/7zip', root / 'tools/7zip')
            for flag in ('uselocaldata', 'uselocaltemp'):
                (root / flag).touch()
            (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
            (root / 'myhomelib2.ini').write_text(
                '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
                '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
                '[INTERFACE]\nWindowsDarkThemeOfferDismissed=1\n', encoding='utf-8')
            fixture = root / 'save-module-fixture'
            fixture.mkdir()
            entries = [candidate(args.processing_packages, 'BookProcessing', args.platform, fixture),
                       candidate(args.image_packages, 'ImageProcessing', args.platform, fixture)]
            (fixture / 'fixture.json').write_text(json.dumps(dict(components=entries)), encoding='utf-8')
            result['candidates'] = entries
            # The module runtimes are deliberately absent until the actual installer runs.
            assert not (root / 'tools/python').exists() and not (root / 'tools/images').exists()
            previous_seven = os.environ.get('HLRU_PACK_7ZIP')
            try:
                os.environ['HLRU_PACK_7ZIP'] = str(root / 'tools/7zip/7za.exe')
                from test_pack_collection import illustrated_fb2, image_fixture
                original = illustrated_fb2(image_fixture(True))
            finally:
                if previous_seven is None:
                    os.environ.pop('HLRU_PACK_7ZIP', None)
                else:
                    os.environ['HLRU_PACK_7ZIP'] = previous_seven
            source_book = root / 'module-source.fb2'
            source_book.write_bytes(original)
            original_sha = hashlib.sha256(original).hexdigest()
            for folder in ('profile/local', 'profile/roaming', 'temp'):
                (root / folder).mkdir(parents=True)
            env = dict(os.environ, LOCALAPPDATA=str(root / 'profile/local'), APPDATA=str(root / 'profile/roaming'),
                       TEMP=str(root / 'temp'), TMP=str(root / 'temp'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
            log = stage / 'native.log'
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            with log.open('wb') as output:
                process = run_owned([str(root / args.binary.name), 'save-module-restart', 'compression'],
                    cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT, startupinfo=startup,
                    creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS, timeout=240)
            text = log.read_text(encoding='utf-8', errors='replace')
            expected = 'PASS compact compression download cancel retry actual installer HomeLibre restart exact selected settings approved compression backup and retained personal data'
            for path in root.glob('*module*.json'):
                if path.stat().st_size < 65536:
                    (stage / path.name).write_bytes(path.read_bytes())
            native_report = root / 'save-module-result.txt'
            if native_report.exists():
                shutil.copy2(native_report, stage / native_report.name)
            assert process.returncode == 0 and expected in text, text
            assert signature(source_book)['sha256'] == original_sha, 'Installer changed the comparison original'
            assert not list(root.rglob('*.pending-compression.jsonl'))
            assert signature(root / 'HomeLibre.exe') == signature(args.binary), 'Installer changed the running application unexpectedly'
            state = json.loads((root / 'compression-module-state.json').read_text(encoding='utf-8-sig'))
            source = root / 'compression-module-source/shared.zip'
            after = archive_body(source, 'sample.fb2', root / 'tools/7zip/7za.exe')
            assert len(after) < len(original)
            prepared = root / 'verified-result.fb2'
            prepared.write_bytes(after)
            verify_non_image_content(source_book, prepared, '.fb2')
            assert archive_body(source, 'neighbor.bin', root / 'tools/7zip/7za.exe') == b'Unselected neighboring bytes must remain exact.'
            backup, = (root / 'compression-module-backup').glob('*.zip')
            with zipfile.ZipFile(backup) as archive:
                assert archive.read('books/sample.fb2') == original
            catalog = Path(state['catalog'])
            assert catalog.is_relative_to(root) and catalog.is_file()
            with closing(sqlite3.connect(catalog.as_uri() + '?mode=ro', uri=True)) as db:
                row, = db.execute('SELECT BookSize FROM Books WHERE LibID COLLATE BINARY=?', ('Compression restart book',)).fetchall()
                assert row[0] == len(after)
            for entry in entries:
                descriptor = root / ('tools/bookconvert/MODULAR_RUNTIME.json' if entry['id'] == 'BookProcessing' else 'tools/images/COMPONENT.json')
                info = json.loads(descriptor.read_text(encoding='utf-8-sig'))
                assert info['version'] == entry['version'] and info['platform'] == args.platform
                for name, digest in info['identities'].items():
                    assert signature(root / name)['sha256'] == digest
            result.update(status='PASS', native_log=str(log), original_sha256=original_sha,
                result_sha256=hashlib.sha256(after).hexdigest(), original_book_bytes=len(original), result_book_bytes=len(after),
                backup_original_exact=True, neighbor_exact=True, catalog_size_exact=True,
                actual_cancel_install_restart_approved_compression=True)
            result['application_filename'] = 'HomeLibre.exe'
            result['successor_pid'] = int(native_report.read_text(encoding='utf-8-sig').splitlines()[1])
        result['private_runtime_removed'] = not root.exists()
        assert result['private_runtime_removed']
    except BaseException:
        result.update(status='FAIL', error=traceback.format_exc())
        raise
    finally:
        if 'private_runtime' in result:
            result['private_runtime_removed'] = not Path(result['private_runtime']).exists()
        result['seconds'] = round(time.monotonic() - started, 3)
        report.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
        print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('stage', 'binary', 'helper', 'runtime', 'sqlite', 'icons', 'genres', 'processing-packages', 'image-packages'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    run(parser.parse_args())

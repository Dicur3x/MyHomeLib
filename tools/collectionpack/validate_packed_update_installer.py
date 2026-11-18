"""Exercise a reviewed packed update through module installation and startup."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import zipfile

from pack_collection import temporary_work_directory
from supervised_test_process import run_owned
from validate_compression_inspection import check_pe
from validate_compression_modules import candidate, signature


SUCCESS = ('PASS real packed update installer starts a successor that restores '
           'the checked review and publishes only after approval')


def stage_runtime(args, root):
    binary_dir = args.binaries
    helper = binary_dir / 'HomeLibRuUpdater.exe'
    for source in (args.test, helper, binary_dir / 'sqlite3.dll',
                   binary_dir / 'Icons/MHLIcons.dll'):
        check_pe(source, args.platform)
    shutil.copy2(args.test, root / 'CollectionViewsTest.exe')
    shutil.copy2(helper, root / helper.name)
    for name in ('sqlite3.dll', '7z.dll', 'libzstd.dll', 'libeay32.dll',
                 'ssleay32.dll', 'homelib_webp.dll', 'genres_fb2.glst',
                 'Icons/MHLIcons.dll'):
        source = binary_dir / name
        if source.is_file():
            target = root / name
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(source, target)
    shutil.copytree(args.runtime / 'tools/7zip', root / 'tools/7zip')
    if not (root / 'tools/7zip/7za.exe').is_file():
        shutil.copy2(root / 'tools/7zip/7z.exe', root / 'tools/7zip/7za.exe')
    (root / 'native-regression.marker').write_text(
        'HomeLib Ru isolated native regression v1', encoding='utf-8')
    shutil.copy2(Path(__file__).resolve().parents[2] / 'Installer/Components.json',
                 root / 'COMPONENTS.json')
    for flag in ('uselocaldata', 'uselocaltemp'):
        (root / flag).touch()
    (root / 'myhomelib2.ini').write_text(
        '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
        '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
        '[INTERFACE]\nLocale=ru\nWindowsDarkThemeOfferDismissed=1\n'
        '[OPDS]\nEnabled=0\n', encoding='utf-8')
    fixture = root / 'save-module-fixture'
    fixture.mkdir()
    entry = candidate(args.processing_packages, 'BookProcessing', args.platform, fixture)
    (fixture / 'fixture.json').write_text(json.dumps(entry), encoding='utf-8')
    with zipfile.ZipFile(fixture / entry['name']) as package:
        manifest = json.loads(package.read('HomeLibRu.update.json'))
        for item in manifest['files']:
            name = item['path']
            target = (root / name).resolve()
            assert target.is_relative_to(root) and not target.exists(), name
            package.extract(name, root)
    return entry, manifest['files']


def copy_diagnostics(root, stage):
    names = ('save-module-result.txt', 'packed-update-module-state.json',
             'update-error.log')
    for index, source in enumerate(path for name in names for path in root.rglob(name)):
        if source.resolve().is_relative_to(root) and source.stat().st_size <= 65536:
            target = stage / source.name
            if target.exists():
                target = stage / f'{index}-{source.name}'
            shutil.copy2(source, target)


def run(args):
    stage = args.stage.resolve()
    assert stage.drive.upper() == 'G:', stage
    assert shutil.disk_usage('C:/').free >= 8 * 1024**3
    assert shutil.disk_usage('G:/').free >= 4 * 1024**3
    stage.mkdir()
    started = time.monotonic()
    result = dict(status='INCOMPLETE', platform=args.platform, test=signature(args.test),
                  installer=signature(args.binaries / 'HomeLibRuUpdater.exe'))
    root = None
    try:
        with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
            result['candidate'], files = stage_runtime(args, root)
            for name in ('profile/local', 'profile/roaming', 'temp'):
                (root / name).mkdir(parents=True)
            env = dict(os.environ, LOCALAPPDATA=str(root / 'profile/local'),
                       APPDATA=str(root / 'profile/roaming'), TEMP=str(root / 'temp'),
                       TMP=str(root / 'temp'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8',
                       PYTHONDONTWRITEBYTECODE='1')
            log = stage / 'native.log'
            try:
                with log.open('wb') as output:
                    process = run_owned(
                        [str(root / 'CollectionViewsTest.exe'), 'save-module-restart', 'packed-update'],
                        cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT,
                        creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
                        timeout=240)
            finally:
                copy_diagnostics(root, stage)
            text = log.read_text(encoding='utf-8', errors='replace')
            result['exit_code'] = process.returncode
            assert process.returncode == 0 and SUCCESS in text, text[-6000:]
            state = json.loads((root / 'packed-update-module-state.json').read_text(encoding='utf-8-sig'))
            outcome, pid = (root / 'save-module-result.txt').read_text(encoding='utf-8-sig').splitlines()
            assert outcome == SUCCESS and int(pid) != state['producer']
            assert signature(root / 'HomeLibre.exe') == result['test']
            for item in files:
                assert signature(root / item['path']) == dict(bytes=item['size'], sha256=item['sha256']), item['path']
            result.update(status='PASS', producer_pid=state['producer'],
                          successor_pid=int(pid), verified_installed_files=len(files))
    except Exception as error:
        result.update(status='FAIL', error=str(error))
        raise
    finally:
        result.update(private_runtime_removed=root is not None and not root.exists(),
                      seconds=round(time.monotonic() - started, 3))
        (stage / 'report.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    if not result['private_runtime_removed']:
        raise RuntimeError('The isolated runtime was retained')
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('stage', 'test', 'binaries', 'runtime', 'processing-packages'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    run(parser.parse_args())

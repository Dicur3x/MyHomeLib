"""Run collection-preference integration only in an owned portable fixture.

The actual catalogue/SQLite implementation tests two separate collections,
reopening, relocation and the full index-import table reset. No user's books
or installed settings are opened. Keep bounded evidence, remove runtime data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import zipfile

from pack_collection import temporary_work_directory


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary, package, package_sha256, platform, stage):
    stage.mkdir(parents=True, exist_ok=True)
    assert digest(package) == package_sha256
    result = dict(status='INCOMPLETE', platform=platform, binary_sha256=digest(binary),
                  package_sha256=package_sha256, temporary_root_removed=False)
    report = stage / ('preferences-' + platform + '.json')
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
        with zipfile.ZipFile(package) as archive:
            manifest = json.loads(archive.read('HomeLibRu.update.json'))
            assert manifest['platform'] == platform and not manifest.get('component')
            entries = {entry['path']: entry for entry in manifest['files']}
            required = {'sqlite3.dll', 'Icons/MHLIcons.dll', 'tools/genres/genres_fb2.glst'}
            assert required <= entries.keys()
            for name in required:
                body = archive.read(name)
                assert len(body) == entries[name]['size']
                assert hashlib.sha256(body).hexdigest() == entries[name]['sha256']
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(body)
        shutil.copyfile(root / 'tools/genres/genres_fb2.glst', root / 'genres_fb2.glst')
        shutil.copyfile(binary, root / 'CollectionViewsTest.exe')
        for marker in ('uselocaldata', 'uselocaltemp'):
            (root / marker).touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        (root / 'myhomelib2.ini').write_text(
            '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
            '[INTERFACE]\nWindowsDarkThemeOfferDismissed=1\n', encoding='utf-8')
        env = {**os.environ, 'TEMP': str(root), 'TMP': str(root),
               'LOCALAPPDATA': str(root / 'Local'), 'APPDATA': str(root / 'Roaming')}
        started = time.monotonic()
        process = subprocess.run([str(root / 'CollectionViewsTest.exe'), 'compression-preferences'],
            cwd=root, env=env, capture_output=True, timeout=150,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
        output = (process.stdout + process.stderr).decode('utf-8', errors='replace')
        (stage / ('preferences-' + platform + '.log')).write_text(output, encoding='utf-8')
        assert process.returncode == 0 and 'PASS compression preferences:' in output, output
        result.update(status='PASS', seconds=round(time.monotonic() - started, 3),
            scope='Real private collection databases, reopen, rename/relocation, full import reset, corrupt choices, recovery registry and scaled dialog')
    result['temporary_root_removed'] = not root.exists()
    assert result['temporary_root_removed']
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'package', 'stage'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--package-sha256', required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    run(**vars(parser.parse_args()))

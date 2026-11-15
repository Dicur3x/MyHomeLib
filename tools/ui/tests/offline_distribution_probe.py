"""Validate actual full/minimal ZIPs with the production native installer.

Checks package hashes, all pinned fonts, manually extracted module inventory,
installation receipts and preservation of personal files. This does not claim
clean-Windows prerequisites, GUI function coverage or network isolation.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('offline_staging', ROOT / 'scripts/stage-offline-components.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', action='append', required=True, type=Path)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    args.stage.mkdir(exist_ok=False)
    report = dict(status='RUNNING', scope=__doc__, checks=[])
    try:
        for source in args.archive:
            staging.disk_guard(args.stage, source.stat().st_size * 5)
            with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-offline-package-', dir=args.stage) as name:
                root = Path(name)
                job = root / 'prepared'
                job.mkdir()
                # Bundle verification reopens the original ZIP beside its
                # prepared manifest, just as the actual downloader stores it.
                archive_path = job / 'release.zip'
                shutil.copy2(source, archive_path)
                with zipfile.ZipFile(archive_path) as archive:
                    manifest_bytes = archive.read('HomeLibRu.update.json')
                    manifest = json.loads(manifest_bytes)
                    files = {item['path']: item for item in manifest['files']}
                    assert len(files) == len(manifest['files'])
                    assert len(archive.namelist()) == len(files) + 1
                    assert set(archive.namelist()) == set(files) | {'HomeLibRu.update.json'}
                    assert len({name.casefold() for name in files}) == len(files)
                    assert all(staging.safe_member(name) for name in files)
                    assert not any(name.casefold().startswith(('data/', 'presets/')) for name in files)
                    for path, item in files.items():
                        data = archive.read(path)
                        assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
                    full = manifest['distribution'] == 'full'
                    prerequisites = []
                    parts = {part['component']: part['version'] for part in manifest.get('bundle', [])}
                    if full:
                        assert set(parts) == staging.COMPONENTS
                        assert 'HomeLibreReader.exe' in files and 'HomeLibReader.exe' not in files
                        fonts = json.loads((ROOT / 'Installer/ReaderFonts/manifest.json').read_bytes())
                        for font in fonts['files']:
                            assert files['tools/fonts/' + font['path']]['sha256'] == font['sha256']
                        public = json.loads(archive.read('tools/updates/OFFLINE.json'))
                        assert {part['component'] for part in public['components']} == staging.COMPONENTS
                        assert all(set(part) <= {'component', 'version', 'official', 'reader_application'}
                                   for part in public['components'])
                        if manifest.get('offline_prerequisites'):
                            prerequisites = json.loads((ROOT / 'Installer/OfflinePrerequisites.json').read_bytes())['files']
                            bundled = json.loads(archive.read('tools/prerequisites/PREREQUISITES.json'))['files']
                            assert bundled == prerequisites
                            for row in prerequisites:
                                item = files['tools/prerequisites/' + row['path']]
                                assert item['size'] == row['size'] and item['sha256'] == row['sha256']
                    else:
                        assert manifest['distribution'] == 'minimal' and not parts
                        assert not any(name.startswith(('Readers/', 'tools/fonts/', 'tools/python/')) for name in files)
                        assert 'HomeLibreReader.exe' not in files
                    manual = root / 'manual'
                    archive.extractall(manual)
                native = args.native_root.resolve() / manifest['platform'] / 'ProgramUpdateInstallerTest.exe'
                environment = dict(os.environ, TEMP=str(args.stage.resolve()), TMP=str(args.stage.resolve()),
                                   LOCALAPPDATA=str(root / 'local-appdata'), APPDATA=str(root / 'appdata'))

                def run(*command):
                    staging.disk_guard(args.stage)
                    result = subprocess.run([str(native), *map(str, command)], env=environment, cwd=root,
                        capture_output=True, timeout=300,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    output = result.stdout.decode('utf-8', errors='replace')
                    try:
                        error = result.stderr.decode('utf-8')
                    except UnicodeDecodeError:
                        error = result.stderr.decode('cp1251', errors='replace')
                    assert result.returncode == 0, (command, output, error)
                    return output

                def check_modules(target, manual=False):
                    states = {item['id']: item for item in json.loads(run('--runtime-state', target).splitlines()[0])}
                    for identity, version in parts.items():
                        item = states[identity]
                        inventory = item['manifest_inventory'] if manual else item['inventory']
                        assert item['version'] == version and not item['repair'] and inventory > 0, item
                    return states

                check_modules(manual, manual=True)
                target = root / 'installed'
                target.mkdir()
                # The native updater accepts an existing application directory;
                # a clean installation is the manual-extraction case above.
                initial = manual / 'HomeLibre.exe'
                if not initial.is_file():
                    initial = manual / 'tools/updates/catalogue/HomeLibre.exe'
                shutil.copy2(initial, target / 'HomeLibre.exe')
                personal = {'Data/private-state.bin': b'ratings, collections, reading positions',
                            'myhomelib2.ini': b'private settings', 'HomeLibReader.ini': b'reader settings'}
                if full:
                    personal['Readers/AlReader/$savevtut.ini'] = b'personal AlReader settings'
                for name, data in personal.items():
                    path = target / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                run('--prepare', archive_path, staging.sha(archive_path), manifest['release'], job)
                if full:
                    assert (job / 'manifest.json').read_bytes() == manifest_bytes
                run('--install', job, target)
                for name, data in personal.items():
                    assert (target / name).read_bytes() == data, name
                for name, item in files.items():
                    if name not in personal:
                        destination = 'HomeLibre.exe' if name == 'tools/updates/catalogue/HomeLibre.exe' else name
                        assert staging.sha(target / destination) == item['sha256'], name
                if 'tools/updates/catalogue/HomeLibre.exe' in files:
                    assert not (target / 'tools/updates/catalogue/HomeLibre.exe').exists()
                states = check_modules(target)
                for row in prerequisites:
                    state = json.loads(run('--offline-prerequisite', target, row['id'], row['architecture']).splitlines()[0])
                    assert state['available'] and state['version'] == row['version']
                owned = set()
                for identity in parts:
                    receipt = target / 'tools/component-state' / (identity.lower().replace(' ', '-') + '.json')
                    for item in json.loads(receipt.read_text('utf-8-sig'))['files']:
                        owned.add(item['path'])
                        # Ownership retains the shipped hash of a preserved user
                        # configuration, so later removal recognizes it as changed.
                        if item['path'] in personal:
                            assert item['sha256'] == files[item['path']]['sha256']
                        else:
                            assert staging.sha(target / item['path']) == item['sha256'], item['path']
                unowned_fonts = sorted(name for name in files if name.startswith('tools/fonts/') and name not in owned)
                assert not unowned_fonts, unowned_fonts
                report['checks'].append(dict(archive=str(source.resolve()), sha256=staging.sha(source),
                    platform=manifest['platform'], distribution=manifest['distribution'], files=len(files),
                    components=len(parts), native_sha256=staging.sha(native), runtime_states=states,
                    manually_extracted_inventory=True, receipt_hashes_verified=True, personal_preserved=True,
                    unowned_font_files=unowned_fonts, offline_prerequisites_verified=len(prerequisites), installers_executed=False))
                print('PASS actual ZIP preparation/installation/inventory ' + manifest['platform'] +
                      ' ' + manifest['distribution'], flush=True)
            assert not root.exists()
        report.update(status='PASS', owned_profiles_removed=True)
    except Exception as error:
        report.update(status='FAIL', error=str(error))
        raise
    finally:
        (args.stage / 'distribution-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

"""Compose/install 13 real cached modules to exercise the former 9/12 limits.

These historical components are test inputs, not the final offline distribution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--reader-packages', required=True, type=Path)
    parser.add_argument('--zstandard-packages', required=True, type=Path)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    stage = args.stage.resolve()
    stage.mkdir(exist_ok=False)
    report = dict(status='RUNNING', scope=__doc__, checks=[])
    for platform in ('Win32', 'Win64'):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-large-bundle-', dir=stage) as name:
            root = Path(name)
            env = dict(os.environ, TEMP=str(stage), TMP=str(stage))
            native = args.native_root.resolve() / platform / 'ProgramUpdateInstallerTest.exe'

            def run(*command, expected=0):
                actual = subprocess.run([str(native), *map(str, command)], env=env, cwd=root,
                    capture_output=True, encoding='utf-8', errors='replace', timeout=240,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert actual.returncode == expected, (command, actual.stdout, actual.stderr)
                return actual.stdout

            paths = sorted(args.packages.glob('*-' + platform + '.zip'))
            paths += [args.reader_packages / f'HomeLibRu-HomeLibReader-3.0.0.13-{platform}.zip',
                      args.zstandard_packages / f'HomeLibRu-Zstandard-1.5.7-{platform}.zip']
            assert len(paths) == 13
            jobs, sources, ids = [], [], set()
            for index, path in enumerate(paths):
                with zipfile.ZipFile(path) as archive:
                    manifest = json.loads(archive.read('HomeLibRu.update.json'))
                assert manifest['platform'] == platform and manifest['component'] not in ids
                ids.add(manifest['component'])
                job = root / f'job-{index}'
                job.mkdir()
                download = job / 'release.zip'
                shutil.copy2(path, download)
                run('--prepare-component', download, sha(download), manifest['release'], job,
                    manifest['component'], manifest['version'])
                jobs.append(job)
                sources.append(dict(path=str(path), sha256=sha(path), id=manifest['component'], version=manifest['version']))
            combined = root / 'combined'
            run('--combine', combined, '3.0.0_pre1.13', *jobs)
            manifest = json.loads((combined / 'manifest.json').read_text('utf-8-sig'))
            assert len(manifest['bundle']) == 13 and {part['component'] for part in manifest['bundle']} == ids
            target = root / 'target'
            target.mkdir()
            shutil.copy2(native, target / 'HomeLibre.exe')
            (target / 'Data').mkdir()
            personal = target / 'Data/private-sentinel.bin'
            personal.write_bytes(b'User state must survive installation')
            run('--install', combined, target)
            assert personal.read_bytes() == b'User state must survive installation'
            states = json.loads(run('--runtime-state', target).splitlines()[0])
            indexed = {item['id']: item for item in states}
            for source in sources:
                actual = indexed[source['id']]
                assert not actual['repair'] and actual['version'] == source['version'] and actual['inventory'] > 0, actual
            receipts = [target / 'tools/component-state' / (identity.lower().replace(' ', '-') + '.json')
                        for identity in sorted(ids)]
            assert len(receipts) == 13 and all(path.is_file() for path in receipts)
            for receipt in receipts:
                for item in json.loads(receipt.read_text('utf-8-sig'))['files']:
                    assert sha(target / item['path']) == item['sha256']
            report['checks'].append(dict(platform=platform, components=len(ids), files=len(manifest['files']),
                native_sha256=sha(native), packages=sources, receipt_hashes_verified=True, personal_preserved=True))
            print('PASS 13-component real composition/install/inventory ' + platform, flush=True)
        assert not root.exists()
    report.update(status='PASS', owned_profiles_removed=True)
    (stage / 'large-bundle-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

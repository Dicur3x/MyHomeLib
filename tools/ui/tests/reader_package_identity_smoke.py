"""Install exact production Reader ZIPs in owned fixtures, without launching them."""
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

SOURCE = Path(__file__).resolve().parents[3]


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SOURCE / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-root', required=True, type=Path)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    stage = args.stage.resolve()
    stage.mkdir(exist_ok=False)
    package, publication = module('package-reader-components'), module('prepare-component-publication')
    report = dict(status='RUNNING', cases=[], packages=[], published=False)
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-reader-real-', dir=stage) as name:
        root = Path(name)
        env = dict(os.environ, TEMP=str(stage), TMP=str(stage), LOCALAPPDATA=str(root / 'local'))
        for platform in ('Win32', 'Win64'):
            native = args.native_root.resolve() / platform / 'ExecutableIdentityTest.exe'
            entry, result = package.package(args.build_root.resolve(), platform, 'HomeLibReader',
                package.COMPONENT_RELEASE_TAG, 'unused', stage)
            report['packages'].append(result)

            def run(*command):
                actual = subprocess.run([str(native), *map(str, command)], env=env, cwd=root,
                    capture_output=True, encoding='utf-8', timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
                assert actual.returncode == 0, (command, actual.stdout, actual.stderr)
                return actual.stdout.strip()

            with zipfile.ZipFile(result['archive']) as archive:
                manifest = json.loads(archive.read('HomeLibRu.update.json'))
                payload = {item['path']: archive.read(item['path']) for item in manifest['files']}
            publication.portable_reader_asset(stage, entry, payload, manifest)
            for layout, key in (('compat', 'archive'), ('portable', 'portable_archive')):
                # Downloaded files must also be inside the guarded fixture root.
                archive = root / Path(result[key]).name
                shutil.copy2(result[key], archive)
                target = root / f'{platform}-{layout}'
                target.mkdir()
                (target / 'HomeLibre.exe').write_bytes(native.read_bytes())
                (target / 'HomeLibReader.exe').write_bytes(native.read_bytes() + b'previous reader fixture')
                private = {'HomeLibReader.ini': b'[Book.1]\nPosition=875\n',
                           'reader-user.dbs2': b'private sentinel'}
                for filename, body in private.items():
                    (target / filename).write_bytes(body)
                job = root / f'job-{platform}-{layout}'
                job.mkdir()
                shutil.copy2(archive, job / 'release.zip')
                run('--prepare', archive, sha(archive), package.COMPONENT_RELEASE_TAG, job, 'HomeLibReader', entry['version'])
                run('--verify', job, package.COMPONENT_RELEASE_TAG)
                run('--install', job, target)
                reader = args.build_root / f'Utils/HomeLibreReader/Out/{platform}/HomeLibreReader.exe'
                assert sha(target / 'HomeLibreReader.exe') == sha(reader)
                assert sha(target / 'HomeLibReader.exe') == sha(reader)
                for filename, body in private.items():
                    assert (target / filename).read_bytes() == body
                state = json.loads(run('--reader-state', target))
                assert state['file'] == 'HomeLibreReader.exe' and state['version'] == entry['version'] and not state['repair'], state
                removal = json.loads(run('--reader-removal', target))
                assert removal['blocked'] == 0 and {'HomeLibreReader.exe', 'HomeLibReader.exe'} <= set(removal['files']), removal
                assert run('--resolve', target, 'HomeLibReader.exe') == 'HomeLibreReader.exe'
                receipt = json.loads((target / 'tools/component-state/homelibreader.json').read_text('utf-8-sig'))
                for item in receipt['files']:
                    assert sha(target / item['path']) == item['sha256']
                report['cases'].append(dict(platform=platform, layout=layout, native_sha256=sha(native),
                    archive_sha256=sha(archive), inventory_files=len(receipt['files'])))
                print('PASS real Reader package ' + platform + ' ' + layout, flush=True)
    report.update(status='PASS', owned_profile_removed=not root.exists())
    (stage / 'verification-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

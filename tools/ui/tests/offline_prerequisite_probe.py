"""Verify real offline Microsoft installers without executing an installer."""
import argparse
import copy
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def file_version(path):
    api = ctypes.windll.version
    size = api.GetFileVersionInfoSizeW(str(path), None)
    assert size
    data = ctypes.create_string_buffer(size)
    assert api.GetFileVersionInfoW(str(path), 0, size, data)
    value, length = ctypes.c_void_p(), ctypes.c_uint()
    assert api.VerQueryValueW(data, '\\', ctypes.byref(value), ctypes.byref(length))
    fields = struct.unpack('<13I', ctypes.string_at(value, 52))
    return '.'.join(map(str, [fields[2] >> 16, fields[2] & 65535, fields[3] >> 16, fields[3] & 65535]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--definition', required=True, type=Path)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--platform', required=True, choices=('Win32', 'Win64'))
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    args.stage.mkdir(exist_ok=False)
    assert shutil.disk_usage('C:/').free >= 8 * 1024**3
    assert shutil.disk_usage(args.stage).free >= 1024**3
    definition = json.loads(args.definition.read_bytes())
    native = args.native_root.resolve() / args.platform / 'ProgramUpdateInstallerTest.exe'
    report = dict(status='RUNNING', scope=__doc__, checks=[], platform=args.platform, native_sha256=sha(native))
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-offline-prereq-', dir=args.stage) as name:
            root = Path(name)
            environment = dict(os.environ, TEMP=str(args.stage.resolve()), TMP=str(args.stage.resolve()),
                               LOCALAPPDATA=str(root / 'local-appdata'), APPDATA=str(root / 'appdata'))
            folder = root / 'tools/prerequisites'
            folder.mkdir(parents=True)
            metadata = folder / 'PREREQUISITES.json'

            def run(identity='WebView2', architecture='x64', failure=False):
                actual = subprocess.run([str(native), '--offline-prerequisite', str(root), identity, architecture],
                    env=environment, cwd=root, capture_output=True, timeout=120,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                output = actual.stdout.decode('utf-8', errors='replace')
                error = actual.stderr.decode('utf-8', errors='replace')
                if failure:
                    assert actual.returncode != 0, output
                    return output + error
                assert actual.returncode == 0, output + error
                return json.loads(output.splitlines()[0])

            assert not run()['available']
            report['checks'].append('absent bundle remains available to the online fallback')
            for row in definition['files']:
                source = args.inputs / row['path']
                assert source.stat().st_size == row['size'] and sha(source) == row['sha256']
                # The positive fixtures are read-only. Negative cases below do
                # not write to these links or to the original downloaded files.
                os.link(source, folder / row['path'])
            metadata.write_text(json.dumps(definition), encoding='utf-8')
            for row in definition['files']:
                actual = run(row['id'], row['architecture'])
                assert actual['available'] and actual['version'] == row['version']
                report['checks'].append('real pinned Microsoft signature: ' + row['path'])
            altered = copy.deepcopy(definition)
            altered['files'][0]['sha256'] = '0' * 64
            metadata.write_text(json.dumps(altered), encoding='utf-8')
            assert 'повреждён' in run('WebView2', 'x86', failure=True)
            report['checks'].append('changed installer hash rejected')
            altered = copy.deepcopy(definition)
            altered['files'][0]['path'] = '../escape.exe'
            metadata.write_text(json.dumps(altered), encoding='utf-8')
            run(failure=True)
            report['checks'].append('foreign path rejected')
            altered = copy.deepcopy(definition)
            altered['files'][0] = altered['files'][1]
            metadata.write_text(json.dumps(altered), encoding='utf-8')
            run(failure=True)
            report['checks'].append('duplicate architecture rejected')
            metadata.write_text(json.dumps(definition), encoding='utf-8')
            run('WebView2', 'unsupported', failure=True)
            report['checks'].append('unsupported offline architecture rejected')
            # Replace only our link, then pad an unsigned test executable to
            # the allowed installer size. It has a valid PE version resource;
            # updated hashes/metadata still cannot bypass publisher verification.
            changed = folder / 'webview2-x86.exe'
            changed.unlink()
            shutil.copy2(native, changed)
            with changed.open('ab') as stream:
                stream.truncate(32 * 1024**2)
            altered = copy.deepcopy(definition)
            altered['files'][0].update(size=changed.stat().st_size, sha256=sha(changed), version=file_version(changed))
            metadata.write_text(json.dumps(altered), encoding='utf-8')
            assert 'подпись' in run('WebView2', 'x86', failure=True)
            report['checks'].append('unsigned PE rejected despite matching hash and version')
            print('PASS offline prerequisite verification ' + args.platform, flush=True)
        assert not root.exists()
        report.update(status='PASS', owned_profiles_removed=True, installers_executed=False)
    except Exception as error:
        report.update(status='FAIL', error=str(error))
        raise
    finally:
        (args.stage / 'prerequisite-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

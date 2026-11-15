"""Keep ordinary update/module limits strict while local full ZIPs grow."""
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
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    args.stage.mkdir(exist_ok=False)
    assert shutil.disk_usage('C:/').free >= 8 * 1024**3
    assert shutil.disk_usage(args.stage).free >= 1024**3
    report = dict(status='RUNNING', checks=[])
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-size-limits-', dir=args.stage) as name:
            root = Path(name)
            module = root / 'oversized-module.zip'
            manifest = dict(format=1, component='HomeLibReader', version='3.0.0.13',
                            release='3.0.0_pre1.13', platform='Win32', files=[dict(path='HomeLibreReader.exe',
                            size=129 * 1024**2, sha256=hashlib.sha256(b'x').hexdigest())])
            # This member is rejected from its declared size before extraction.
            # It cannot become a permitted large prerequisite through a module ID.
            large = root / 'oversized-ordinary.zip'
            block = b'\0' * 1024**2
            notice_sha = hashlib.sha256()
            with zipfile.ZipFile(large, 'w', compression=zipfile.ZIP_STORED) as archive:
                archive.writestr('HomeLibre.exe', b'program')
                archive.writestr('LICENSE', b'license')
                with archive.open('NOTICE', 'w', force_zip64=True) as stream:
                    for index in range(257):
                        assert shutil.disk_usage('C:/').free >= 8 * 1024**3
                        stream.write(block)
                        notice_sha.update(block)
                ordinary = dict(format=1, release='3.0.0_pre1.13', platform='Win32', distribution='minimal',
                    files=[dict(path='HomeLibre.exe', size=7, sha256=hashlib.sha256(b'program').hexdigest()),
                           dict(path='LICENSE', size=7, sha256=hashlib.sha256(b'license').hexdigest()),
                           dict(path='NOTICE', size=257 * 1024**2, sha256=notice_sha.hexdigest())])
                archive.writestr('HomeLibRu.update.json', json.dumps(ordinary))
            digest = sha(large)
            for platform in ('Win32', 'Win64'):
                native = args.native_root.resolve() / platform / 'ProgramUpdateInstallerTest.exe'
                environment = dict(os.environ, TEMP=str(args.stage.resolve()), TMP=str(args.stage.resolve()),
                                   LOCALAPPDATA=str(root / 'local-appdata'), APPDATA=str(root / 'appdata'))
                manifest['platform'] = platform
                with zipfile.ZipFile(module, 'w') as archive:
                    archive.writestr('HomeLibreReader.exe', b'x')
                    archive.writestr('HomeLibRu.update.json', json.dumps(manifest))
                cases = [(['--prepare-component', str(module), sha(module), manifest['release'],
                           str(root / ('module-' + platform)), 'HomeLibReader', manifest['version']], 'Недопустимый файл'),
                         (['--prepare', str(large), digest, ordinary['release'],
                           str(root / ('ordinary-' + platform)), '--fixture'], 'Архив превышает допустимый размер обычного обновления')]
                for command, expected in cases:
                    result = subprocess.run([str(native), *command], cwd=root, env=environment,
                        capture_output=True, timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
                    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
                    assert result.returncode != 0 and expected in output, output
                    assert not (Path(command[4]) / 'payload').exists()
                report['checks'].append(dict(platform=platform, native_sha256=sha(native),
                    ordinary_256MiB_limit_preserved=True, ordinary_module_128MiB_member_limit_preserved=True))
                print('PASS ordinary size limits ' + platform, flush=True)
        assert not root.exists()
        report.update(status='PASS', owned_profiles_removed=True)
    except Exception as error:
        report.update(status='FAIL', error=str(error))
        raise
    finally:
        (args.stage / 'size-limits-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

"""Install exact local component ZIPs through the native production installer.

Uses an owned temporary catalogue copy. Does not download packages, restart a
graphical app, or establish that an older published receiver accepts the ZIPs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('native', type=Path)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    stage, native = args.stage.resolve(), args.native.resolve()
    binary = native.read_bytes()
    machine = struct.unpack_from('<H', binary, struct.unpack_from('<I', binary, 0x3c)[0] + 4)[0]
    assert machine == (0x14c if args.platform == 'Win32' else 0x8664)
    report = dict(status='FAIL', platform=args.platform, native_validator_sha256=sha(native),
                  scope='Native local component preparation and installation; no network, graphical restart or old-receiver claim',
                  components=[], temporary_payloads_removed=False, published=False)
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-components-') as temporary:
            root = Path(temporary)
            target = root / 'target'
            target.mkdir()
            environment = dict(os.environ, LOCALAPPDATA=str(root / 'LocalAppData'))
            catalogue = stage / 'catalogue' / ('HomeLibRu.zip' if args.platform == 'Win32' else 'HomeLibRu_x64.zip')
            with zipfile.ZipFile(catalogue) as archive:
                assert archive.testzip() is None
                for name in archive.namelist():
                    assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
                    assert '..' not in Path(name).parts
                archive.extractall(target)
            report['catalogue_sha256'] = sha(catalogue)
            sentinel = target / 'Data/author-favorites.sqlite'
            sentinel.parent.mkdir()
            sentinel.write_bytes('Private preserved fixture ё'.encode('utf-8'))
            sentinel_hash = sha(sentinel)
            fixtures = []
            for directory in ('reader-r2', 'formats', 'mcp'):
                entries = json.loads((stage / directory / 'HomeLibRu.components.json').read_bytes())['components']
                fixtures.extend((directory, entry) for entry in entries if entry['platform'] == args.platform)
            assert {entry['id'] for _, entry in fixtures} == {
                'HomeLibReader', 'MHLMcpServer', 'BookProcessing', 'ImageProcessing',
                'Kindle', 'LegacyBooks', 'LegacyOffice', 'XPS'}
            assert len(fixtures) == 8

            def run(*parameters):
                result = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                    env=environment, capture_output=True, encoding='utf-8-sig', timeout=120,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert result.returncode == 0, (parameters, result.returncode, result.stdout, result.stderr)
                return result.stdout.strip()

            for directory, entry in fixtures:
                component = entry['id']
                source = stage / directory / entry['archive']
                archive = root / entry['archive']
                assert archive.parent == root
                shutil.copyfile(source, archive)
                digest = sha(archive)
                assert digest == sha(source)
                job = root / ('HomeLibRu-update-' + component)
                result = dict(component=component, version=entry['version'], archive_sha256=digest)
                report['components'].append(result)
                result['native_prepare'] = run('--prepare-component', archive, digest,
                    'optional-alreader-2.5.1009.25', job, component, entry['version'])
                result['native_install'] = run('--install', job, target)
                result['repair_response'] = run('--component-needs-repair', target, component)
                # The native command always emits its final success sentinel.
                assert result['repair_response'].splitlines() == ['0', 'PASS'], result
                journal = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))
                assert journal['state'] == 'installed', journal
                assert sha(sentinel) == sentinel_hash
                if component in ('BookProcessing', 'ImageProcessing'):
                    absent = ['kindle', 'office', 'xps', 'pdfium', 'djvu']
                    if component == 'BookProcessing':
                        absent.append('images')
                    assert all(not (target / 'tools' / name).exists() for name in absent)
                result.update(repair_needed=False, transaction_installed=True, personal_data_preserved=True)
            report['personal_data_preserved'] = sha(sentinel) == sentinel_hash
        report.update(status='PASS', temporary_payloads_removed=True)
    except Exception as error:
        report['error'] = repr(error)
        raise
    finally:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS native component install:', args.platform, '8 independent modules; private payloads removed')


if __name__ == '__main__':
    main()

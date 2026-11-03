"""Install exact local component ZIPs through the native production installer.

Uses an owned temporary catalogue copy. Does not download packages, restart a
graphical app, or establish that an older published receiver accepts the ZIPs.
"""
import argparse
from datetime import datetime, timezone
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
    parser.add_argument('--catalogue-dir', type=Path, required=True)
    parser.add_argument('--reader-packages', type=Path, required=True)
    parser.add_argument('--djvu-packages', type=Path, required=True)
    parser.add_argument('--format-packages', type=Path)
    parser.add_argument('--kindle-packages', type=Path)
    args = parser.parse_args()
    assert not args.report.exists(), 'Preserve previous verification reports'
    stage, native = args.stage.resolve(), args.native.resolve()
    binary = native.read_bytes()
    machine = struct.unpack_from('<H', binary, struct.unpack_from('<I', binary, 0x3c)[0] + 4)[0]
    assert machine == (0x14c if args.platform == 'Win32' else 0x8664)
    report = dict(status='FAIL', platform=args.platform, native_validator_sha256=sha(native),
                  scope='Native local component preparation and installation; no network, graphical restart or old-receiver claim',
                  components=[], temporary_payloads_removed=False, published=False)
    root = None
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-components-') as temporary:
            root = Path(temporary)
            target = root / 'target'
            target.mkdir()
            environment = dict(os.environ, LOCALAPPDATA=str(root / 'LocalAppData'))
            suffix = '_x64' if args.platform == 'Win64' else ''
            candidates = [args.catalogue_dir.resolve() / (brand + suffix + '.zip')
                          for brand in ('HomeLibre', 'HomeLibRu')]
            catalogue, = [path for path in candidates if path.is_file()]
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
            directories = [args.reader_packages.resolve(), (args.format_packages or stage / 'formats').resolve(),
                           stage / 'mcp', args.djvu_packages.resolve()]
            if args.kindle_packages:
                directories.append(args.kindle_packages.resolve())
            for directory in directories:
                feed = directory / 'HomeLibRu.components.json'
                if feed.is_file():
                    entries = json.loads(feed.read_bytes())['components']
                else:
                    # The pinned DjVu repair fixture contains exact ZIPs rather
                    # than a publication feed. This is a local installer probe.
                    assert directory == args.djvu_packages.resolve(), directory
                    entries = []
                    for path in sorted(directory.glob('HomeLibRu-DjVuLibre-*.zip')):
                        with zipfile.ZipFile(path) as package:
                            manifest = json.loads(package.read('HomeLibRu.update.json'))
                        assert manifest['component'] == 'DjVuLibre'
                        entries.append(dict(id=manifest['component'], platform=manifest['platform'],
                                            version=manifest['version'], archive=path.name))
                fixtures.extend((directory, entry) for entry in entries if entry['platform'] == args.platform)
            expected = {
                'HomeLibReader', 'MHLMcpServer', 'BookProcessing', 'ImageProcessing',
                'Kindle', 'LegacyBooks', 'LegacyOffice', 'XPS', 'DjVuLibre'}
            if args.kindle_packages:
                expected.add('KindleExport')
            assert {entry['id'] for _, entry in fixtures} == expected
            assert len(fixtures) == len(expected)

            def run(*parameters):
                result = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                    env=environment, capture_output=True, encoding='utf-8-sig', timeout=120,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert result.returncode == 0, (parameters, result.returncode, result.stdout, result.stderr)
                return result.stdout.strip()

            started = datetime.now(timezone.utc)
            usage_file = target / 'tools/component-state/usage.json'
            for directory, entry in fixtures:
                component = entry['id']
                source = directory / entry['archive']
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
                ledger = json.loads(usage_file.read_text(encoding='utf-8-sig'))
                row = ledger['modules'][component]
                first_seen = datetime.fromisoformat(row['firstSeenUtc'].replace('Z', '+00:00'))
                assert first_seen >= started.replace(microsecond=0), row
                assert not row.get('lastUsedUtc'), 'Installation must not count as actual module use'
                result['fresh_install_clock_started_without_use'] = True

            # Reinstalling/updating an already present module must not make an
            # old unused module look new, or erase its last real use.
            ledger = json.loads(usage_file.read_text(encoding='utf-8-sig'))
            row = ledger['modules']['BookProcessing']
            row.update(firstSeenUtc='2026-01-01T12:00:00Z', lastUsedUtc='2026-01-04T12:00:00Z')
            usage_file.write_text(json.dumps(ledger), encoding='utf-8')
            directory, entry = next((d, e) for d, e in fixtures if e['id'] == 'BookProcessing')
            archive = root / entry['archive']
            job = root / 'HomeLibRu-update-BookProcessing-again'
            run('--prepare-component', archive, sha(archive), 'optional-alreader-2.5.1009.25',
                job, 'BookProcessing', entry['version'])
            run('--install', job, target)
            after = json.loads(usage_file.read_text(encoding='utf-8-sig'))['modules']['BookProcessing']
            assert all(after[key] == row[key] for key in ('firstSeenUtc', 'lastUsedUtc')), after
            report['same_version_reinstall_preserves_existing_use_clock'] = True
            report['personal_data_preserved'] = sha(sentinel) == sentinel_hash
        report.update(status='PASS', temporary_payloads_removed=True)
    except Exception as error:
        report['error'] = repr(error)
        raise
    finally:
        report['temporary_payloads_removed'] = root is not None and not root.exists()
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS native component install:', args.platform, f'{len(report["components"])} independent modules; private payloads removed')


if __name__ == '__main__':
    main()

"""Package and verify a fresh minimal archive, then remove all probe payloads.

Keeps only a small report. Does not publish a release or touch an installed app.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def machine(data):
    return struct.unpack_from('<H', data, struct.unpack_from('<I', data, 0x3c)[0] + 4)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['Win32', 'Win64'])
    parser.add_argument('--node')
    parser.add_argument('--native-exe', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--archive', type=Path, help='Verify this exact final archive instead of making a disposable one')
    parser.add_argument('--adapters', type=Path, help='Pinned optional native adapter ZIP directory')
    parser.add_argument('--scenario', choices=['minimal-first-install','update-repair'], default='minimal-first-install')
    parser.add_argument('--package-only', action='store_true', help='Check archive contents without starting any graphical application')
    options = parser.parse_args()
    if not options.package_only and (not options.node or not options.native_exe):
        parser.error('--node and --native-exe are required unless --package-only is used')
    if not options.package_only and options.scenario == 'minimal-first-install' and not options.adapters:
        parser.error('--adapters is required to exercise download into a minimal install')
    runtime = ROOT/'Program/Out'/('Bin' if options.platform == 'Win32' else 'Bin64')
    report = {'platform':options.platform, 'temporary_payloads_removed':False}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-minimal-package-probe-') as temporary:
        folder = Path(temporary)
        if options.archive:
            archive=options.archive.resolve()
        else:
            packaged = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File',
                str(ROOT/'scripts/package-release.ps1'), '-Platform', options.platform,
                '-OutputDirectory', str(folder/'archives')], cwd=ROOT, capture_output=True, text=True, timeout=240)
            if packaged.returncode:
                raise RuntimeError(packaged.stdout + packaged.stderr)
            archive = folder/'archives'/('HomeLibRu.zip' if options.platform == 'Win32' else 'HomeLibRu_x64.zip')
        with zipfile.ZipFile(archive) as package:
            assert package.testzip() is None
            names = set(package.namelist())
            forbidden_prefixes = ('Readers/', 'converters/', 'tools/bookconvert/', 'tools/kindle/',
                'tools/office/', 'tools/xps/', 'tools/pdfium/',
                'tools/7zip/', 'tools/webp/', 'tools/jpeg-xl/', 'tools/doc/', 'tools/djvu/')
            core_tools = {'tools/fonts/manifest.json'}
            forbidden = [name for name in names if name in ('HomeLibReader.exe', 'MHLMcpServer.exe', 'HomeLibRu.url') or
                name.startswith(forbidden_prefixes) or (name.startswith('tools/') and name not in core_tools)]
            assert not forbidden, forbidden
            manifest = json.loads(package.read('HomeLibRu.update.json'))
            assert manifest['distribution'] == 'minimal' and manifest['platform'] == options.platform
            assert len(names) == len(package.namelist()), 'Duplicate ZIP members'
            assert names == {entry['path'] for entry in manifest['files']} | {'HomeLibRu.update.json'}
            for entry in manifest['files']:
                data = package.read(entry['path'])
                assert len(data) == entry['size'] and sha(data) == entry['sha256'], entry['path']
            for name in ('HomeLibRu.exe', 'HomeLibRuUpdater.exe', 'sqlite3.dll', 'libzstd.dll',
                         'LICENSE', 'NOTICE', 'COMPONENTS.json', *core_tools):
                assert name in names, 'Required catalogue file missing: ' + name
            expected_machine = 0x14c if options.platform == 'Win32' else 0x8664
            for name in ['HomeLibRu.exe','HomeLibRuUpdater.exe']:
                assert machine(package.read(name)) == expected_machine
            report.update({'archive_bytes':archive.stat().st_size, 'manifest_files':len(manifest['files']),
                           'all_member_hashes_verified':True, 'optional_payloads_absent':list(forbidden_prefixes) + ['HomeLibReader.exe'],
                           'catalogue_only_payload_verified':True, 'native_format_adapters_absent':True, 'native_architectures_verified':True,
                           'archive_sha256':sha(archive.read_bytes()),
                           'scenario':'package-only' if options.package_only else options.scenario,'published':False,
                           'application_smoke_tested':False})
        if not options.package_only:
            fixtures = folder/'fixtures'
            subprocess.run([sys.executable, '-B', str(ROOT/'tools/ui/tests/prepare_update_repair_fixtures.py'),
                str(archive), str(runtime), str(fixtures), '--sha256', sha(archive.read_bytes()),
                *(['--adapters', str(options.adapters.resolve())] if options.adapters else [])], cwd=ROOT, check=True)
            tested = subprocess.run([options.node, str(ROOT/'tools/ui/tests/native_collection_tests.js'),
                str(runtime), '-', '-', str(options.native_exe.resolve()), '--views-mode='+options.scenario,
                '--repair-fixtures='+str(fixtures)], cwd=ROOT, capture_output=True, text=True, timeout=180)
            report['native_minimal_install_exit'] = tested.returncode
            report['native_minimal_install_output'] = tested.stdout + tested.stderr
            options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            if tested.returncode:
                raise RuntimeError(report['native_minimal_install_output'])
    report['temporary_payloads_removed'] = True
    options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS minimal package: ' + options.platform + '; hashes, exclusions, architecture and '+report['scenario']+'; probe payloads removed')


if __name__ == '__main__':
    main()

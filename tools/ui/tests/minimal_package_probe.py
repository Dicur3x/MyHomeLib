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
    parser.add_argument('--node', required=True)
    parser.add_argument('--native-exe', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    options = parser.parse_args()
    runtime = ROOT/'Program/Out'/('Bin' if options.platform == 'Win32' else 'Bin64')
    report = {'platform':options.platform, 'temporary_payloads_removed':False}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-minimal-package-probe-') as temporary:
        folder = Path(temporary)
        packaged = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File',
            str(ROOT/'scripts/package-release.ps1'), '-Platform', options.platform,
            '-OutputDirectory', str(folder/'archives')], cwd=ROOT, capture_output=True, text=True, timeout=240)
        if packaged.returncode:
            raise RuntimeError(packaged.stdout + packaged.stderr)
        archive = folder/'archives'/('HomeLibRu.zip' if options.platform == 'Win32' else 'HomeLibRu_x64.zip')
        with zipfile.ZipFile(archive) as package:
            assert package.testzip() is None
            names = set(package.namelist())
            forbidden = ['tools/7zip/7z.exe','tools/webp/libwebp.dll','tools/jpeg-xl/djxl.exe',
                'tools/doc/DocSharp.Binary.Doc.dll','tools/djvu/djvused.exe',
                'Readers/AlReader/AlReader2.exe','Readers/SumatraPDF/SumatraPDF.exe']
            assert not names.intersection(forbidden), names.intersection(forbidden)
            manifest = json.loads(package.read('HomeLibRu.update.json'))
            assert manifest['distribution'] == 'minimal' and manifest['platform'] == options.platform
            for entry in manifest['files']:
                data = package.read(entry['path'])
                assert len(data) == entry['size'] and sha(data) == entry['sha256'], entry['path']
            for name in ['convert_book.py','text_inputs.py','fixed_layout.py','README.md']:
                assert package.read('tools/bookconvert/'+name) == (ROOT/'tools/bookconvert'/name).read_bytes()
            expected_machine = 0x14c if options.platform == 'Win32' else 0x8664
            for name in ['HomeLibRu.exe','HomeLibRuUpdater.exe']:
                assert machine(package.read(name)) == expected_machine
            report.update({'archive_bytes':archive.stat().st_size, 'manifest_files':len(manifest['files']),
                           'all_member_hashes_verified':True, 'optional_binaries_absent':forbidden,
                           'converter_matches_source':True, 'native_architectures_verified':True,
                           'published':False})
        fixtures = folder/'fixtures'
        subprocess.run([sys.executable, '-B', str(ROOT/'tools/ui/tests/prepare_update_repair_fixtures.py'),
            str(archive), str(runtime), str(fixtures), '--sha256', sha(archive.read_bytes())], cwd=ROOT, check=True)
        tested = subprocess.run([options.node, str(ROOT/'tools/ui/tests/native_collection_tests.js'),
            str(runtime), '-', '-', str(options.native_exe.resolve()), '--views-mode=minimal-first-install',
            '--repair-fixtures='+str(fixtures)], cwd=ROOT, capture_output=True, text=True, timeout=180)
        report['native_minimal_install_exit'] = tested.returncode
        report['native_minimal_install_output'] = tested.stdout + tested.stderr
        options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        if tested.returncode:
            raise RuntimeError(report['native_minimal_install_output'])
    report['temporary_payloads_removed'] = True
    options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS fresh minimal package: ' + options.platform + '; hashes, exclusions, architecture and actual first-use installation; probe payloads removed')


if __name__ == '__main__':
    main()

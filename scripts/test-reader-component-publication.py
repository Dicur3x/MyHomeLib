"""Regression for the permanent component publication contract (no downloads)."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('reader_packages', Path(__file__).with_name('package-reader-components.py'))
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)
publication = __import__('runpy').run_path(str(Path(__file__).with_name('prepare-component-publication.py')))


class PublicationContract(unittest.TestCase):
    def reader_fixture(self, root, platform):
        repo = root / 'repo'
        runtime = repo / 'Program/Out' / ('Bin' if platform == 'Win32' else 'Bin64')
        reader = repo / 'Utils/HomeLibreReader/Out' / platform
        runtime.mkdir(parents=True)
        reader.mkdir(parents=True)
        header = bytearray(96)
        header[:2] = b'MZ'
        struct.pack_into('<I', header, 0x3c, 64)
        header[64:68] = b'PE\0\0'
        struct.pack_into('<H', header, 68, 0x14c if platform == 'Win32' else 0x8664)
        (reader / 'HomeLibreReader.exe').write_bytes(header)
        for name in ('HomeLibRuUpdater.exe', 'sqlite3.dll'):
            (runtime / name).write_bytes(header)
        for path, data in {
                repo / 'LICENSE': b'fixture licence',
                runtime / 'NOTICE': b'fixture notices',
                runtime / 'tools/fonts/manifest.json': b'{}',
                repo / 'Installer/Release.json': b'{"version":"3.0.0.1"}',
                repo / 'Installer/Components.json': packages.json_bytes({
                    'format': 1,
                    'components': [{'id': 'HomeLibReader', 'platform': platform,
                                    'version': '3.0.0.1', 'history': [
                                        {'version': '3.0.0.1', 'notes': 'fixture release'}]}],
                })}.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return repo

    def test_permanent_destination(self):
        self.assertEqual(packages.publication_tag('optional-alreader-2.5.1009.25'),
                         'optional-alreader-2.5.1009.25')

    def test_application_tag_rejected_before_build_or_output_access(self):
        for component in ('HomeLibReader', 'PDFium', 'BookConverter'):
            for tag in ('2.7.0_pre5.35', '2.7.0_pre5.36', '', '../release'):
                with self.subTest(component=component, tag=tag):
                    with self.assertRaisesRegex(ValueError, 'permanent component release'):
                        packages.package(Path('missing-runtime'), 'Win64', component,
                                         tag, '2.7.0.1103', Path('missing-output'))

    def test_reader_asset_name_matches_versioned_feed_and_transport(self):
        for platform in ('Win32', 'Win64'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix='HomeLibre-reader-package-') as folder:
                root = Path(folder)
                repo = self.reader_fixture(root, platform)
                with patch.object(packages, 'file_version', return_value='3.0.0.1'), \
                        patch.object(packages, 'verify_reader_manifest'):
                    entry, report = packages.package(repo, platform, 'HomeLibReader',
                        packages.COMPONENT_RELEASE_TAG, 'unused', root / 'output')
                expected = f'HomeLibRu-HomeLibReader-3.0.0.1-{platform}.zip'
                self.assertEqual(entry['archive'], expected)
                self.assertEqual(Path(report['archive']).name, entry['archive'])
                with zipfile.ZipFile(report['archive']) as archive:
                    manifest = json.loads(archive.read('HomeLibRu.update.json'))
                    self.assertEqual(manifest['version'], entry['version'])
                    self.assertEqual(manifest['reader_application'], 'HomeLibreReader.exe')
                    self.assertIn('HomeLibReader.exe', archive.namelist())
                    self.assertNotIn('HomeLibreReader.exe', archive.namelist())
                    self.assertEqual(manifest['platform'], platform)
                    self.assertEqual(manifest['release'], packages.COMPONENT_RELEASE_TAG)
                    self.assertNotIn('libzstd.dll', archive.namelist())
                    self.assertFalse(any(name.startswith(('tools/bookconvert/', 'tools/kindle/',
                        'tools/office/', 'tools/xps/')) for name in archive.namelist()))

                with zipfile.ZipFile(report['portable_archive']) as archive:
                    names = archive.namelist()
                    self.assertIn('HomeLibreReader.exe', names)
                    self.assertNotIn('HomeLibReader.exe', names)
                    manifest = json.loads(archive.read('HomeLibRu.update.json'))
                    self.assertEqual({item['path'] for item in manifest['files']}, set(names) - {'HomeLibRu.update.json'})
                    self.assertEqual(archive.read('HomeLibreReader.exe'),
                                     (repo / 'Utils/HomeLibreReader/Out' / platform / 'HomeLibreReader.exe').read_bytes())
                with zipfile.ZipFile(report['archive']) as archive:
                    compatible = json.loads(archive.read('HomeLibRu.update.json'))
                    payload = {item['path']: archive.read(item['path']) for item in compatible['files']}
                asset = publication['portable_reader_asset'](root / 'output', entry, payload, compatible)
                self.assertEqual(asset['path'], report['portable_archive'])
                self.assertEqual(asset['digest'], 'sha256:' + report['portable_sha256'])
                portable = Path(report['portable_archive'])
                with zipfile.ZipFile(portable) as archive:
                    altered = {name: archive.read(name) for name in archive.namelist()}
                altered['HomeLibreReader.exe'] += b'altered'
                with zipfile.ZipFile(portable, 'w') as archive:
                    for name, body in altered.items():
                        archive.writestr(name, body)
                with self.assertRaises(AssertionError):
                    publication['portable_reader_asset'](root / 'output', entry, payload, compatible)

    def test_stale_reader_rejected_without_output(self):
        self.assert_reader_version_rejected(['2.7.0.1105'])

    def test_stale_updater_rejected_without_output(self):
        self.assert_reader_version_rejected(['3.0.0.1', '2.7.0.1105'])

    def assert_reader_version_rejected(self, versions):
        with tempfile.TemporaryDirectory(prefix='HomeLibre-reader-package-') as folder:
            root = Path(folder)
            repo = self.reader_fixture(root, 'Win32')
            with patch.object(packages, 'file_version', side_effect=versions), \
                    patch.object(packages, 'verify_reader_manifest'):
                with self.assertRaisesRegex(ValueError, 'Rebuild Reader and updater'):
                    packages.package(repo, 'Win32', 'HomeLibReader',
                        packages.COMPONENT_RELEASE_TAG, 'unused', root / 'output')
            self.assertFalse((root / 'output').exists())


if __name__ == '__main__':
    unittest.main()

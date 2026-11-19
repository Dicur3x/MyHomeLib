"""Check public release bytes and native preparation, without launching an app.

Component checks use Python HTTPS and native preparation. Core checks use the
actual production download thread. Installation and restart are covered
separately; do not describe this as a first-use UI test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import urllib.request
import zipfile

from component_publication_probe import component_ids


def open_release_asset(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'HomeLibre-release-verification',
                                                   'Cache-Control': 'no-cache'})
    return urllib.request.urlopen(request, timeout=90)


def verify_public_archive(asset, expected_size, expected_sha256):
    assert asset['size'] == expected_size
    assert asset['digest'] == 'sha256:' + expected_sha256
    count = 0
    digest = hashlib.sha256()
    with open_release_asset(asset['browser_download_url']) as response:
        assert response.status == 200
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            assert count <= expected_size, 'Public download exceeds the release manifest'
            digest.update(chunk)
    assert count == expected_size and digest.hexdigest() == expected_sha256, asset['name']
    return dict(name=asset['name'], size=count, sha256=expected_sha256, asset_id=asset['id'])


def check_core(args, native_root, cache, get):
    report = dict(status='FAIL', scope='Live GitHub release metadata through both production '
        'parsers, followed by real production download threads and native preparation. '
        'No graphical frontend, installation or restart in this probe.', platforms=[],
        additional_archives=[], temporary_downloads_removed=False)
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-public-core-', dir=cache) as temporary:
            root = Path(temporary)
            releases = json.loads(subprocess.check_output(['gh', 'api',
                'repos/Dicur3x/MyHomeLib/releases?per_page=100'], encoding='utf-8'))
            tag = args.core_tag or '3.0.0_pre1.1'
            current = next(value for value in releases if value['tag_name'] == tag)
            assert not current['draft']
            assert current['prerelease'] == (args.core_prerelease or not args.core_tag)
            catalogue = args.catalogue_dir or args.stage / 'catalogue-r3'
            packages = {}
            for platform, suffix in (('Win32', ''), ('Win64', '_x64')):
                package, = [p for brand in ('HomeLibre', 'HomeLibRu')
                            if (p := catalogue / f'{brand}{suffix}.zip').is_file()]
                packages[platform] = package
            assets = {value['name']: value for value in current['assets']}
            documented_checksums = (args.checksums or catalogue / 'SHA256SUMS.txt').read_bytes()
            manifest = {}
            for line in documented_checksums.decode('ascii').splitlines():
                match = re.fullmatch(r'([a-fA-F0-9]{64})  ((?:HomeLibre|HomeLibRu)(?:_x64)?(?:_portable|_full)?\.zip)', line)
                assert match is not None, 'Unexpected line in the catalogue checksum file'
                digest, name = match.groups()
                assert name not in manifest, 'Duplicate archive in the catalogue checksum file'
                manifest[name] = digest.lower()
            assert {p.name for p in packages.values()} <= set(manifest)
            assert set(assets) == {'SHA256SUMS.txt'} | set(manifest)
            api_file = root / 'releases.json'
            api_file.write_text(json.dumps(releases), encoding='utf-8')
            checksums = get(assets['SHA256SUMS.txt']['browser_download_url'])
            assert checksums == documented_checksums
            native_archives = set()
            for platform, compatibility in packages.items():
                native = native_root / platform / 'ProgramUpdateInstallerTest.exe'

                def run(*parameters):
                    completed = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                        capture_output=True, encoding='utf-8-sig', timeout=180,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    assert completed.returncode == 0, (parameters, completed.stdout, completed.stderr)
                    return completed.stdout.strip()

                parsed = run('--parse', api_file)
                values = json.loads(parsed.removesuffix('PASS').strip())
                portable = compatibility.stem + '_portable.zip'
                candidates = {name for name in (compatibility.name, portable) if name in manifest}
                selected, = [name for name in candidates if assets[name]['browser_download_url'] == values[1]]
                package = catalogue / selected
                asset = assets[package.name]
                digest = hashlib.sha256(package.read_bytes()).hexdigest()
                assert digest == manifest[package.name]
                assert values[:4] == [tag, asset['browser_download_url'], digest, asset['size']]
                job = root / platform
                result = run('--download', values[1], values[3], values[2], values[0], job)
                downloaded = job / 'release.zip'
                assert downloaded.stat().st_size == asset['size']
                assert hashlib.sha256(downloaded.read_bytes()).hexdigest() == digest
                with zipfile.ZipFile(downloaded) as archive:
                    assert archive.testzip() is None
                native_archives.add(selected)
                report['platforms'].append(dict(platform=platform, tag=values[0], name=selected, asset_id=asset['id'],
                    sha256=digest, size=asset['size'], native_download_and_preparation=result))
                print('PASS production download and preparation', platform, flush=True)
            for name in sorted(set(manifest) - native_archives):
                with (catalogue / name).open('rb') as source:
                    size = os.fstat(source.fileno()).st_size
                    assert hashlib.file_digest(source, 'sha256').hexdigest() == manifest[name]
                report['additional_archives'].append(verify_public_archive(assets[name], size, manifest[name]))
                print('PASS public catalogue archive', name, flush=True)
        report.update(status='PASS', temporary_downloads_removed=not root.exists())
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--core', action='store_true', help='Check published core with production download threads')
    parser.add_argument('--core-tag', help='Expected public catalogue release tag')
    parser.add_argument('--core-prerelease', action='store_true', help='Expect a GitHub prerelease')
    parser.add_argument('--catalogue-dir', type=Path, help='Local catalogue archives and checksums for --core')
    parser.add_argument('--checksums', type=Path, help='Local checksum file if stored separately from the archives')
    parser.add_argument('--native-root', type=Path, help='Directory containing the Win32 and Win64 native verifier builds')
    parser.add_argument('--plan', type=Path, help='Local component publication plan')
    parser.add_argument('--staged-feed', type=Path,
                        help='Verify public ZIPs against the local feed before switching the public feed')
    args = parser.parse_args()
    assert not args.report.exists(), 'Preserve previous verification reports'
    stage = args.stage.resolve()
    repo = Path(__file__).resolve().parents[3]
    native_root = args.native_root.resolve() if args.native_root else repo / 'Program/Tests/Out'
    cache = Path('G:/HomeLibRu-build-cache').resolve(strict=True)
    os.environ.update(TEMP=str(cache), TMP=str(cache))
    tempfile.tempdir = None
    report = dict(status='FAIL', scope=__doc__.strip(), archives=[], parsers={},
                  temporary_downloads_removed=False)

    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def get(url):
        with open_release_asset(url) as response:
            assert response.status == 200
            return response.read()

    if args.core:
        check_core(args, native_root, cache, get)
        return

    plan = json.loads((args.plan or stage / 'publication-r3/publication-plan.json').read_bytes())
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-public-release-', dir=cache) as temporary:
            root = Path(temporary)
            metadata = json.loads(subprocess.check_output(['gh', 'api',
                f"repos/Dicur3x/MyHomeLib/releases/{plan['release_id']}"], encoding='utf-8'))
            assets = {entry['name']: entry for entry in metadata['assets']}
            active_feed = assets['HomeLibRu.components.json']
            if args.staged_feed:
                assert active_feed['digest'] == 'sha256:' + plan['observed_feed_sha256'], 'Active feed changed'
                feed_bytes = args.staged_feed.read_bytes()
                report['scope'] = 'Local candidate feed with actual public asset metadata, downloads and native preparation.'
                report['candidate_feed_sha256'] = digest(feed_bytes)
            else:
                feed_bytes = get(active_feed['browser_download_url'])
                report['public_feed_sha256'] = digest(feed_bytes)
            assert digest(feed_bytes) == plan['replacement_feed_sha256'], 'Verified feed bytes differ from plan'
            report['feed_asset_id'] = active_feed['id']
            feed = root / 'HomeLibRu.components.json'
            feed.write_bytes(feed_bytes)
            remote = root / 'release.json'
            remote.write_text(json.dumps(metadata['assets']), encoding='utf-8')
            entries = {}
            for entry in json.loads(feed_bytes)['components']:
                if entry['id'] == 'HomeLibReader':
                    entry = entry.get('minimal_reader', entry)
                entries[entry['archive']] = entry
            ids = component_ids(repo)
            version = json.loads((repo / 'Installer/Release.json').read_bytes())['version']

            def run(platform, *parameters):
                native = native_root / platform / 'ProgramUpdateInstallerTest.exe'
                completed = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                    capture_output=True, encoding='utf-8-sig', timeout=120,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert completed.returncode == 0, (parameters, completed.stdout, completed.stderr)
                return completed.stdout.strip()

            for platform in ('Win32', 'Win64'):
                result = run(platform, '--components', feed, plan['release_tag'], remote, version, '--partial')
                values = json.loads(result.removesuffix('PASS').strip())
                assert len(values) == len(ids) * 3
                parsed = {component: (values[index * 3], values[index * 3 + 1])
                          for index, component in enumerate(ids)}
                expected = [entry for entry in entries.values() if entry['platform'] == platform]
                assert expected and len(expected) == len({entry['id'] for entry in expected})
                prefix = f"https://github.com/Dicur3x/MyHomeLib/releases/download/{plan['release_tag']}/"
                for entry in expected:
                    assert parsed[entry['id']] == (entry['version'], prefix + entry['archive'])
                report['parsers'][platform] = dict(components=len(expected), native_parse_passed=True)

            for item in plan['upload_before_feed']:
                asset = assets[item['name']]
                assert asset['size'] == item['size'] and asset['digest'] == item['digest']
                data = get(item['browser_download_url'])
                assert len(data) == item['size'] and 'sha256:' + digest(data) == item['digest']
                archive = root / item['name']
                archive.write_bytes(data)
                verification = dict(name=item['name'], asset_id=asset['id'], size=len(data), sha256=digest(data))
                if archive.name in entries:
                    with zipfile.ZipFile(archive) as package:
                        assert package.testzip() is None
                    entry = entries[archive.name]
                    verification['native_prepare'] = run(entry['platform'], '--prepare-component', archive, digest(data),
                        plan['release_tag'], root / ('job-' + archive.stem), entry['id'], entry['version'])
                else:
                    verifier = runpy.run_path(str(repo / 'scripts/package-kfx-export-source.py'))
                    assert archive.name == verifier['ARCHIVE'], 'Unexpected archive outside the component feed'
                    verifier['verify'](archive)
                    verification['corresponding_source_verified'] = True
                report['archives'].append(verification)
                print('PASS', item['name'], flush=True)
            assert len(report['archives']) == len(plan['upload_before_feed'])
        report.update(status='PASS', temporary_downloads_removed=not root.exists())
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()

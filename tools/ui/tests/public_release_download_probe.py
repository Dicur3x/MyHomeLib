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
import subprocess
import tempfile
import urllib.request
import zipfile


def check_core(args, repo, cache, get):
    report = dict(status='FAIL', scope='Live GitHub release metadata through both production '
        'parsers, followed by real production download threads and native preparation. '
        'No graphical frontend, installation or restart in this probe.', platforms=[],
        temporary_downloads_removed=False)
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-public-core-', dir=cache) as temporary:
            root = Path(temporary)
            releases = json.loads(subprocess.check_output(['gh', 'api',
                'repos/Dicur3x/MyHomeLib/releases?per_page=100'], encoding='utf-8'))
            current = next(value for value in releases if value['tag_name'] == '3.0.0_pre1.1')
            assert not current['draft'] and current['prerelease']
            assets = {value['name']: value for value in current['assets']}
            assert set(assets) == {'HomeLibRu.zip', 'HomeLibRu_x64.zip', 'SHA256SUMS.txt'}
            api_file = root / 'releases.json'
            api_file.write_text(json.dumps(releases), encoding='utf-8')
            checksums = get(assets['SHA256SUMS.txt']['browser_download_url'])
            assert checksums == (args.stage / 'catalogue-r3/SHA256SUMS.txt').read_bytes()
            for platform, filename in (('Win32', 'HomeLibRu.zip'), ('Win64', 'HomeLibRu_x64.zip')):
                native = repo / f'Program/Tests/Out/{platform}/ProgramUpdateInstallerTest.exe'

                def run(*parameters):
                    completed = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                        capture_output=True, encoding='utf-8-sig', timeout=180,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    assert completed.returncode == 0, (parameters, completed.stdout, completed.stderr)
                    return completed.stdout.strip()

                parsed = run('--parse', api_file)
                values = json.loads(parsed.removesuffix('PASS').strip())
                asset = assets[filename]
                digest = hashlib.sha256((args.stage / 'catalogue-r3' / filename).read_bytes()).hexdigest()
                assert values[:4] == ['3.0.0_pre1.1', asset['browser_download_url'], digest, asset['size']]
                job = root / platform
                result = run('--download', values[1], values[3], values[2], values[0], job)
                downloaded = job / 'release.zip'
                assert downloaded.stat().st_size == asset['size']
                assert hashlib.sha256(downloaded.read_bytes()).hexdigest() == digest
                with zipfile.ZipFile(downloaded) as archive:
                    assert archive.testzip() is None
                report['platforms'].append(dict(platform=platform, tag=values[0], asset_id=asset['id'],
                    sha256=digest, size=asset['size'], native_download_and_preparation=result))
                print('PASS production download and preparation', platform, flush=True)
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
    args = parser.parse_args()
    assert not args.report.exists(), 'Preserve previous verification reports'
    stage = args.stage.resolve()
    publication = stage / 'publication-r3'
    plan = json.loads((publication / 'publication-plan.json').read_bytes())
    repo = Path(__file__).resolve().parents[3]
    cache = Path('G:/HomeLibRu-build-cache').resolve(strict=True)
    os.environ.update(TEMP=str(cache), TMP=str(cache))
    tempfile.tempdir = None
    report = dict(status='FAIL', scope=__doc__.strip(), archives=[], parsers={},
                  temporary_downloads_removed=False)

    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def get(url):
        request = urllib.request.Request(url, headers={'User-Agent': 'HomeLibre-release-verification',
                                                       'Cache-Control': 'no-cache'})
        with urllib.request.urlopen(request, timeout=90) as response:
            assert response.status == 200
            return response.read()

    if args.core:
        check_core(args, repo, cache, get)
        return

    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-public-release-', dir=cache) as temporary:
            root = Path(temporary)
            metadata = json.loads(subprocess.check_output(['gh', 'api',
                f"repos/Dicur3x/MyHomeLib/releases/{plan['release_id']}"], encoding='utf-8'))
            assets = {entry['name']: entry for entry in metadata['assets']}
            feed_bytes = get(assets['HomeLibRu.components.json']['browser_download_url'])
            assert digest(feed_bytes) == plan['replacement_feed_sha256'], 'Public feed bytes differ'
            report['public_feed_sha256'] = digest(feed_bytes)
            report['feed_asset_id'] = assets['HomeLibRu.components.json']['id']
            feed = root / 'HomeLibRu.components.json'
            feed.write_bytes(feed_bytes)
            remote = root / 'release.json'
            remote.write_text(json.dumps(metadata['assets']), encoding='utf-8')
            entries = {entry['archive']: entry for entry in json.loads(feed_bytes)['components']}
            component_ids = re.findall(r"\(ID:'([^']+)'", (repo /
                'Program/Units/unit_ComponentUpdates.pas').read_text(encoding='utf-8-sig'))
            assert len(component_ids) == len(set(component_ids)) == 20

            def run(platform, *parameters):
                native = repo / f'Program/Tests/Out/{platform}/ProgramUpdateInstallerTest.exe'
                completed = subprocess.run([str(native), *map(str, parameters)], cwd=root,
                    capture_output=True, encoding='utf-8-sig', timeout=120,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert completed.returncode == 0, (parameters, completed.stdout, completed.stderr)
                return completed.stdout.strip()

            for platform in ('Win32', 'Win64'):
                result = run(platform, '--components', feed, plan['release_tag'], remote, '2.7.0.1105', '--partial')
                values = json.loads(result.removesuffix('PASS').strip())
                assert len(values) == len(component_ids) * 3
                parsed = {component: (values[index * 3], values[index * 3 + 1])
                          for index, component in enumerate(component_ids)}
                expected = [entry for entry in entries.values() if entry['platform'] == platform]
                assert len(expected) == 17
                prefix = f"https://github.com/Dicur3x/MyHomeLib/releases/download/{plan['release_tag']}/"
                for entry in expected:
                    assert parsed[entry['id']] == (entry['version'], prefix + entry['archive'])
                report['parsers'][platform] = dict(components=17, native_parse_passed=True)

            for item in plan['upload_before_feed']:
                asset = assets[item['name']]
                assert asset['size'] == item['size'] and asset['digest'] == item['digest']
                data = get(item['browser_download_url'])
                assert len(data) == item['size'] and 'sha256:' + digest(data) == item['digest']
                archive = root / item['name']
                archive.write_bytes(data)
                with zipfile.ZipFile(archive) as package:
                    assert package.testzip() is None
                entry = entries[item['name']]
                result = run(entry['platform'], '--prepare-component', archive, digest(data),
                    plan['release_tag'], root / ('job-' + archive.stem), entry['id'], entry['version'])
                report['archives'].append(dict(name=item['name'], asset_id=asset['id'],
                    size=len(data), sha256=digest(data), native_prepare=result))
                print('PASS', item['name'], flush=True)
            assert len(report['archives']) == 18
        report.update(status='PASS', temporary_downloads_removed=not root.exists())
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()

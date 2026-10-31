"""Reconcile tested component ZIPs with the verified current public feed.

Writes a local publication plan only; does not upload, replace or delete assets.
The original public feed must match GitHub's current size and SHA-256. Every new
archive must match the source bootstrap identity and its complete manifest.
Unchanged third-party and legacy converter entries are preserved verbatim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TAG = 'optional-alreader-2.5.1009.25'
PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + TAG + '/'
OWNED = {'HomeLibReader', 'BookProcessing', 'ImageProcessing', 'Kindle',
         'LegacyBooks', 'LegacyOffice', 'XPS', 'MHLMcpServer'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def entries(value):
    assert value['format'] == 1
    result = {}
    for entry in value['components']:
        key = entry['id'], entry['platform']
        assert key not in result, 'Duplicate component/platform: ' + str(key)
        assert key[1] in ('Win32', 'Win64')
        assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', entry['version'])
        assert Path(entry['archive']).name == entry['archive']
        assert '/' not in entry['archive'] and '\\' not in entry['archive']
        result[key] = entry
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--base-feed', type=Path, required=True)
    parser.add_argument('--release-metadata', type=Path, required=True)
    parser.add_argument('--reader-packages', type=Path, required=True,
                        help='Explicit directory of current Reader ZIPs; never infer a numbered build directory')
    parser.add_argument('--djvu-packages', type=Path, required=True,
                        help='Repaired mirror with the required reader bridge and matching source')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    stage, output = args.stage.resolve(), args.output.resolve()
    assert not output.exists(), 'Use a new publication output directory'
    metadata = json.loads(args.release_metadata.read_bytes())
    assert metadata['tag_name'] == TAG and metadata['draft'] is False
    old_assets = {asset['name']: asset for asset in metadata['assets']}
    assert len(old_assets) == len(metadata['assets']), 'Duplicate remote asset'
    base_bytes = args.base_feed.read_bytes()
    remote_feed = old_assets['HomeLibRu.components.json']
    assert len(base_bytes) == remote_feed['size'], 'Public feed size is stale'
    assert 'sha256:' + digest(base_bytes) == remote_feed['digest'], 'Public feed hash is stale'
    baseline = entries(json.loads(base_bytes))
    bootstrap = entries(json.loads((ROOT / 'Installer/Components.json').read_bytes()))
    identity = json.loads((ROOT / 'Installer/Release.json').read_bytes())
    expected = {(component, platform) for component in OWNED | {'DjVuLibre'} for platform in ('Win32', 'Win64')}
    replacement, uploads, checked = {}, [], []
    new_names = set()
    directories = (args.reader_packages.resolve(), stage / 'formats', stage / 'mcp', args.djvu_packages.resolve())
    for directory in directories:
        for key, entry in entries(json.loads((directory / 'HomeLibRu.components.json').read_bytes())).items():
            assert key in expected and key not in replacement, 'Unexpected/duplicate replacement'
            assert entry['version'] == (bootstrap[key]['version'] if key[0]=='DjVuLibre' else identity['version'])
            assert all(entry[field] == bootstrap[key][field] for field in ('id', 'platform', 'version', 'archive'))
            path = directory / entry['archive']
            data = path.read_bytes()
            assert entry['archive'] not in new_names
            if entry['archive'] in old_assets:
                assert key[0]=='DjVuLibre' and entry['archive']==baseline[key]['archive'], 'Unexpected existing asset replacement'
            else:
                assert key[0] in OWNED
            new_names.add(entry['archive'])
            with zipfile.ZipFile(path) as archive:
                names = archive.namelist()
                assert len(names) == len(set(names)), 'Duplicate ZIP member'
                assert archive.testzip() is None, 'Corrupt ZIP member'
                manifest = json.loads(archive.read('HomeLibRu.update.json'))
                assert (manifest['format'], manifest['release'], manifest['component'],
                        manifest['platform'], manifest['version']) == (1, TAG, *key, entry['version'])
                payload_names = [item['path'] for item in manifest['files']]
                assert len(payload_names) == len(set(payload_names)), 'Duplicate manifest member'
                assert set(names) == set(payload_names) | {'HomeLibRu.update.json'}
                for item in manifest['files']:
                    name = item['path']
                    assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
                    assert '..' not in Path(name).parts
                    payload = archive.read(name)
                    assert len(payload) == item['size'] and digest(payload) == item['sha256'], name
                if key[0] == 'HomeLibReader':
                    current = ROOT / 'Utils/HomeLibReader/Out' / key[1] / 'HomeLibReader.exe'
                    for source in (ROOT / 'Program/Units/unit_BookSendOptions.pas',
                                   ROOT / 'Program/Units/unit_Settings.pas',
                                   ROOT / 'Program/Forms/frm_ReaderHost.pas',
                                   ROOT / 'Program/Forms/frm_BuiltinReader.pas'):
                        assert current.stat().st_mtime_ns >= source.stat().st_mtime_ns, (
                            'Rebuild current Reader after source changes: ' + str(source))
                    assert archive.read('HomeLibReader.exe') == current.read_bytes(), (
                        'Reader archive does not match current executable: ' + str(path))
            replacement[key] = entry
            asset = dict(name=entry['archive'], size=len(data), digest='sha256:' + digest(data),
                         browser_download_url=PREFIX + entry['archive'])
            uploads.append(dict(path=str(path), **asset))
            checked.append(dict(component=key[0], platform=key[1], version=entry['version'],
                                archive_sha256=digest(data), managed_files=len(payload_names)))
    assert set(replacement) == expected
    assert set(baseline) == set(bootstrap), 'Public/bootstrap component sets differ'
    merged = {key: replacement.get(key, entry) for key, entry in baseline.items()}
    unchanged = set(baseline) - expected
    for key in unchanged:
        assert merged[key] == baseline[key] == bootstrap[key], 'Unchanged component metadata drift: ' + str(key)
        entry = merged[key]
        asset = old_assets[entry['archive']]
        assert asset['browser_download_url'] == PREFIX + entry['archive']
        assert asset['size'] > 0 and re.fullmatch(r'sha256:[0-9a-f]{64}', asset['digest'])
    replacing_existing = [old_assets[item['name']] for item in uploads if item['name'] in old_assets]
    obsolete = [old_assets[baseline[key]['archive']] for key in sorted(expected) if key[0] in OWNED]
    obsolete_names = {asset['name'] for asset in obsolete}
    assert len(obsolete_names) == len(OWNED)*2
    feed = encoded(dict(format=1, components=list(merged.values())))
    retained_assets = [asset for name, asset in old_assets.items()
                       if name not in obsolete_names | {asset['name'] for asset in replacing_existing} | {'HomeLibRu.components.json'}]
    new_assets = [{key: item[key] for key in ('name', 'size', 'digest', 'browser_download_url')} for item in uploads]
    feed_asset = dict(name='HomeLibRu.components.json', size=len(feed), digest='sha256:' + digest(feed),
                      browser_download_url=PREFIX + 'HomeLibRu.components.json')
    publication = dict(draft=False, prerelease=False, tag_name=TAG,
                       assets=retained_assets + new_assets + [feed_asset])
    assert len(publication['assets']) == len({asset['name'] for asset in publication['assets']})
    plan = dict(published=False, scope='Local plan; no network, uploads or removals performed',
                release_id=metadata['id'], release_tag=TAG, observed_updated_at=metadata['updated_at'],
                observed_feed_sha256=digest(base_bytes), replacement_feed_sha256=digest(feed),
                upload_before_feed=uploads, replace_feed_last=feed_asset,
                replace_existing_assets_before_upload=replacing_existing,
                obsolete_assets_after_verified_publication=obsolete,
                retained_non_owned_entries=len(unchanged), preserved_external_assets=len(retained_assets))
    report = dict(status='PASS', published=False, components=checked,
                  merged_entries=len(merged), unchanged_entries_preserved=len(unchanged),
                  public_feed_size_and_sha256_verified=True, bootstrap_identities_verified=True,
                  exact_manifest_and_payloads_verified=True, feed_sha256=digest(feed))
    report['reader_archives_match_current_executables'] = True
    report['reader_packages_directory'] = str(args.reader_packages.resolve())
    output.mkdir(parents=True, exist_ok=False)
    files = {'HomeLibRu.components.json': feed, 'assets.json': encoded(publication['assets']),
             'local-mirror-release.json': encoded(publication),
             'publication-plan.json': encoded(plan), 'verification-report.json': encoded(report)}
    for name, value in files.items():
        with (output / name).open('xb') as stream:
            stream.write(value)
    print(f'PASS component publication plan: {len(uploads)} archives; unchanged entries preserved; not published')


if __name__ == '__main__':
    main()

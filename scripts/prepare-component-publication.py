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
import runpy
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TAG = 'optional-alreader-2.5.1009.25'
PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + TAG + '/'
OWNED = {'HomeLibReader', 'BookProcessing', 'ImageProcessing', 'Kindle',
         'LegacyBooks', 'LegacyOffice', 'XPS', 'MHLMcpServer', 'KindleExport', 'FB2Export', 'KoboExport', 'EpubPdfExport',
         'KfxExport', 'OPDSTls'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def archive_name(entry):
    if entry['id'] == 'HomeLibReader' and 'archive' not in entry:
        # Old clients use the unversioned bridge when the feed omits the name.
        return f"HomeLibRu-HomeLibReader-{entry['platform']}.zip"
    return entry['archive']


def entries(value):
    assert value['format'] == 1
    result = {}
    for entry in value['components']:
        key = entry['id'], entry['platform']
        assert key not in result, 'Duplicate component/platform: ' + str(key)
        assert key[1] in ('Win32', 'Win64')
        assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', entry['version'])
        name = archive_name(entry)
        assert Path(name).name == name
        assert '/' not in name and '\\' not in name
        result[key] = entry
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--base-feed', type=Path, required=True)
    parser.add_argument('--release-metadata', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--reader-only', action='store_true',
                       help='Replace just the two minimal Reader archives in the existing feed')
    modes.add_argument('--selected-only', action='store_true',
                       help='Replace Reader and only the format components explicitly staged')
    parser.add_argument('--reader-packages', type=Path, required=True,
                        help='Explicit directory of current Reader ZIPs; never infer a numbered build directory')
    parser.add_argument('--format-packages', type=Path,
                        help='Verified unchanged format archives, without copying them into stage')
    parser.add_argument('--kindle-packages', type=Path,
                        help='Separate verified KindleExport archives, unless included with formats')
    parser.add_argument('--djvu-packages', type=Path,
                        help='Repaired mirror with the required reader bridge and matching source')
    parser.add_argument('--kfx-source', type=Path,
                        help='Corresponding source ZIP for both KfxExport archives')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    partial = args.reader_only or args.selected_only
    if args.selected_only and args.format_packages is None:
        parser.error('Selected publication requires --format-packages')
    if not partial and (args.djvu_packages is None or args.kfx_source is None):
        parser.error('Full publication requires --djvu-packages and --kfx-source')
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
    reader_keys = {('HomeLibReader', platform) for platform in ('Win32', 'Win64')}
    directories = [args.reader_packages.resolve()]
    if partial:
        expected = reader_keys
        if args.selected_only:
            formats = args.format_packages.resolve()
            selected = set(entries(json.loads((formats / 'HomeLibRu.components.json').read_bytes())))
            assert selected and not selected & reader_keys
            assert {component for component, _ in selected} <= OWNED - {'KfxExport', 'MHLMcpServer'}
            for component in {component for component, _ in selected}:
                assert {(component, 'Win32'), (component, 'Win64')} <= selected, component
            expected = reader_keys | selected
            directories.append(formats)
    else:
        expected = {(component, platform) for component in OWNED | {'DjVuLibre'} for platform in ('Win32', 'Win64')}
        source_verifier = runpy.run_path(str(ROOT / 'scripts/package-kfx-export-source.py'))
        kfx_source = args.kfx_source.resolve(strict=True)
        assert kfx_source.name == source_verifier['ARCHIVE'], 'Unexpected KFX source archive name'
        source_verifier['verify'](kfx_source)
        source_asset = dict(name=kfx_source.name, size=kfx_source.stat().st_size,
                            digest='sha256:' + digest(kfx_source.read_bytes()),
                            browser_download_url=PREFIX + kfx_source.name)
        directories.extend([(args.format_packages or stage / 'formats').resolve(),
                            stage / 'mcp', args.djvu_packages.resolve()])
        if args.kindle_packages:
            directories.append(args.kindle_packages.resolve())
        if (stage / 'opds-tls').is_dir():
            directories.append(stage / 'opds-tls')
    replacement, uploads, checked = {}, [], []
    new_names = set()
    for directory in directories:
        for key, entry in entries(json.loads((directory / 'HomeLibRu.components.json').read_bytes())).items():
            assert key in expected and key not in replacement, 'Unexpected/duplicate replacement'
            assert all(entry[field] == bootstrap[key][field] for field in ('id', 'platform', 'version', 'archive'))
            if key in reader_keys:
                assert entry['version'] == identity['version']
            elif key in baseline and key[0] != 'DjVuLibre':
                assert tuple(map(int, entry['version'].split('.'))) > tuple(
                    map(int, baseline[key]['version'].split('.'))), 'Component version must advance: ' + str(key)
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
                    assert 'libzstd.dll' not in payload_names, 'Reader package must not bundle Zstandard'
                    current = ROOT / 'Utils/HomeLibReader/Out' / key[1] / 'HomeLibReader.exe'
                    for reader_source in (ROOT / 'Program/Units/unit_BookSendOptions.pas',
                                          ROOT / 'Program/Units/unit_Settings.pas',
                                          ROOT / 'Program/Forms/frm_ReaderHost.pas',
                                          ROOT / 'Program/Forms/frm_BuiltinReader.pas'):
                        assert current.stat().st_mtime_ns >= reader_source.stat().st_mtime_ns, (
                            'Rebuild current Reader after source changes: ' + str(reader_source))
                    assert archive.read('HomeLibReader.exe') == current.read_bytes(), (
                        'Reader archive does not match current executable: ' + str(path))
                if key[0] == 'KfxExport':
                    prefix = 'tools/kfx-export/'
                    assert source_asset['browser_download_url'].encode('ascii') in archive.read(prefix + 'SOURCE.txt')
                    for file in (source_verifier['BUILDER'], source_verifier['PATCH']):
                        assert archive.read(prefix + file) == (ROOT / 'scripts' / file).read_bytes()
            history = entry.get('history', [])
            if args.selected_only and key not in reader_keys:
                history = [note for note in bootstrap[key]['history'] if note['version'] == entry['version']]
                assert len(history) == 1, 'Missing current component notes: ' + str(key)
            versions = {note['version'] for note in history}
            previous_entry = baseline.get(key, {})
            if key in reader_keys:
                previous_entry = previous_entry.get('minimal_reader', previous_entry)
            replacement[key] = {**entry, 'history': history + [note for note in previous_entry.get('history', [])
                                                                 if note['version'] not in versions]}
            asset = dict(name=entry['archive'], size=len(data), digest='sha256:' + digest(data),
                         browser_download_url=PREFIX + entry['archive'])
            # Existing identical mirrors need no deletion/re-upload. Preserve
            # their asset IDs and already working download URLs.
            previous = old_assets.get(entry['archive'])
            if previous is None or any(previous[field] != asset[field] for field in ('size', 'digest')):
                uploads.append(dict(path=str(path), **asset))
            checked.append(dict(component=key[0], platform=key[1], version=entry['version'],
                                archive_sha256=digest(data), managed_files=len(payload_names)))
    assert set(replacement) == expected
    identical_archive_count = len(checked) - len(uploads)
    if not partial:
        previous_source = old_assets.get(kfx_source.name)
        if previous_source is None:
            uploads.insert(0, dict(path=str(kfx_source), **source_asset))
        else:
            assert all(previous_source[key] == value for key, value in source_asset.items()), (
                'Existing corresponding source must remain available unchanged')
    assert not set(baseline) - set(bootstrap), 'Public components would be dropped'
    # A newly introduced component needs both validated architectures.
    added = set(bootstrap) - set(baseline)
    new_ids = {'KindleExport', 'FB2Export', 'KoboExport', 'EpubPdfExport', 'KfxExport', 'OPDSTls'}
    assert {component for component, _ in added} <= new_ids, 'Unexpected new components: ' + str(added)
    for component in {component for component, _ in added}:
        assert {(component, 'Win32'), (component, 'Win64')} <= added, 'Incomplete new component: ' + component
    assert added <= set(replacement)
    merged = {**baseline, **replacement}
    # Older clients keep their verified legacy archive. New clients choose the
    # nested minimal archive using the same component ID and release metadata.
    for key in reader_keys:
        legacy = baseline[key]
        assert archive_name(legacy) != replacement[key]['archive']
        if 'minimal_reader' in legacy:
            previous = tuple(map(int, legacy['minimal_reader']['version'].split('.')))
            current = tuple(map(int, replacement[key]['version'].split('.')))
            assert current > previous, 'Reader version must advance'
        merged[key] = {**legacy, 'minimal_reader': replacement[key]}
    unchanged = set(baseline) - expected
    for key in unchanged | reader_keys:
        if key in unchanged and args.selected_only:
            assert all(baseline[key][field] == bootstrap[key][field] for field in ('id', 'platform', 'version', 'archive')), (
                'Unchanged component identity drift: ' + str(key))
        elif key in unchanged and not partial:
            assert baseline[key] == bootstrap[key], 'Unchanged component metadata drift: ' + str(key)
        entry = baseline[key]
        name = archive_name(entry)
        asset = old_assets[name]
        assert asset['browser_download_url'] == PREFIX + name
        assert asset['size'] > 0 and re.fullmatch(r'sha256:[0-9a-f]{64}', asset['digest'])
    replacing_existing = [old_assets[item['name']] for item in uploads if item['name'] in old_assets]
    previous_owned = set(baseline) & (expected - reader_keys)
    previous_owned = {key for key in previous_owned if key[0] in OWNED}
    obsolete = [old_assets[baseline[key]['archive']] for key in sorted(previous_owned)]
    obsolete.extend(old_assets[baseline[key]['minimal_reader']['archive']]
                    for key in sorted(reader_keys) if 'minimal_reader' in baseline[key])
    obsolete_names = {asset['name'] for asset in obsolete}
    assert len(obsolete_names) == len(obsolete)
    assert not obsolete_names.intersection(archive_name(baseline[key]) for key in reader_keys)
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
                  identical_existing_archives_retained=identical_archive_count,
                  public_feed_size_and_sha256_verified=True, bootstrap_identities_verified=True,
                  exact_manifest_and_payloads_verified=True, feed_sha256=digest(feed))
    if not partial:
        report['kfx_corresponding_source'] = source_asset
    report['reader_archives_match_current_executables'] = True
    report['legacy_reader_archives_retained'] = [archive_name(baseline[key]) for key in sorted(reader_keys)]
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

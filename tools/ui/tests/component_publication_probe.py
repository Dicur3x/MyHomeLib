"""Verify the exact reconciled feed with both native production parsers.

Uses the same partial-feed mode as ParseComponentMirror. AlReader and WebP are
discovered independently by production code, so neither is invented in this
feed merely to satisfy the older full-feed test interface. No HTTP or uploads.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
TAG = 'optional-alreader-2.5.1009.25'
PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + TAG + '/'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    return subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                          encoding='utf-8-sig', timeout=120,
                          creationflags=subprocess.CREATE_NO_WINDOW)


def component_ids(root):
    source = root / 'Program/Units/unit_ComponentUpdates.pas'
    installer = root / 'Program/Units/unit_ProgramUpdateInstaller.pas'
    constants = dict(re.findall(r"(?m)^\s*([A-Z][A-Z0-9_]+)\s*=\s*'([^']+)';",
                                installer.read_text(encoding='utf-8-sig')))
    ids = [literal or constants[constant] for literal, constant in re.findall(
        r"\(ID:(?:'([^']+)'|([A-Z][A-Z0-9_]+));", source.read_text(encoding='utf-8-sig'))]
    assert ids and len(ids) == len(set(ids))
    return ids


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--publication-dir', type=Path,
                        help='Exact newly reconciled publication directory')
    parser.add_argument('--reader-packages', type=Path, required=True)
    parser.add_argument('--djvu-packages', type=Path, required=True)
    parser.add_argument('--base-feed', type=Path, required=True)
    parser.add_argument('--release-metadata', type=Path, required=True)
    parser.add_argument('--kfx-source', type=Path, required=True)
    args = parser.parse_args()
    stage = args.stage.resolve()
    publication = args.publication_dir.resolve() if args.publication_dir else stage / 'publication-r1'
    source = ROOT / 'Program/Units/unit_ComponentUpdates.pas'
    ids = component_ids(ROOT)
    version = json.loads((ROOT / 'Installer/Release.json').read_bytes())['version']
    bootstrap = json.loads((ROOT / 'Installer/Components.json').read_bytes())['components']
    feed_path = publication / 'HomeLibRu.components.json'
    assets_path = publication / 'assets.json'
    feed = json.loads(feed_path.read_bytes())
    assets = json.loads(assets_path.read_bytes())
    report = dict(status='FAIL', published=False,
                  scope='Exact staged feed through native partial-feed parsers; no HTTP/download or publication',
                  feed_sha256=sha(feed_path), parser_source_sha256=sha(source),
                  test_source_sha256=sha(ROOT / 'Program/Tests/ProgramUpdateInstallerTest.dpr'),
                  native_checks=[], temporary_payloads_removed=False)
    try:
        plan_path = publication / 'publication-plan.json'
        plan = json.loads(plan_path.read_bytes())
        for upload in plan['upload_before_feed']:
            payload = Path(upload['path'])
            assert payload.name == upload['name'], 'Upload path points to a different file: ' + upload['name']
            assert payload.stat().st_size == upload['size'] and 'sha256:' + sha(payload) == upload['digest'], (
                'Upload path bytes differ from the verified archive: ' + upload['name'])
        report['upload_paths_and_hashes_verified'] = True
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-feed-') as temporary:
            runtime = Path(temporary).resolve()
            assert runtime.parent == Path(os.environ['TEMP']).resolve()
            assert runtime.name.startswith('HomeLibRu-update-test-feed-') and not runtime.is_symlink()
            for platform in ('Win32', 'Win64'):
                native = ROOT / 'Program/Tests/Out' / platform / 'ProgramUpdateInstallerTest.exe'
                command = [native, '--components', feed_path, TAG, assets_path, version, '--partial']
                result = run(command)
                assert result.returncode == 0, (platform, result.returncode, result.stdout, result.stderr)
                lines = result.stdout.strip().splitlines()
                assert lines[-1] == 'PASS'
                parsed = json.loads(lines[0])
                assert len(parsed) == len(ids) * 3
                actual = {component: (parsed[index * 3], parsed[index * 3 + 1])
                          for index, component in enumerate(ids)}
                expected = [entry for entry in feed['components'] if entry['platform'] == platform]
                assert sorted(entry['id'] for entry in expected) == sorted(
                    entry['id'] for entry in bootstrap if entry['platform'] == platform)
                for entry in expected:
                    selected = entry.get('minimal_reader', entry) if entry['id'] == 'HomeLibReader' else entry
                    assert actual[entry['id']] == (selected['version'], PREFIX + selected['archive']), (platform, entry)
                assert actual['AlReader'] == ('', '') and actual['WebP'] == ('', '')
                # A syntactically invalid digest must not become an install URL.
                broken_assets = json.loads(assets_path.read_bytes())
                target = next(entry['archive'] for entry in expected if entry['id'] == 'BookProcessing')
                next(asset for asset in broken_assets if asset['name'] == target)['digest'] = 'sha256:invalid'
                bad_assets = runtime / ('bad-assets-' + platform + '.json')
                bad_assets.write_text(json.dumps(broken_assets), encoding='utf-8')
                broken_command = command.copy()
                broken_command[4] = bad_assets
                rejected = run(broken_command)
                assert rejected.returncode != 0 and 'component feed' in rejected.stderr
                report['native_checks'].append(dict(platform=platform, native_sha256=sha(native),
                    parsed_feed_entries=len(expected), exact_versions_and_urls=True,
                    invalid_asset_digest_rejected=True))
            negative = runtime / 'stale-feed-output'
            stale_feed = runtime / 'stale-feed.json'
            stale_feed.write_bytes(args.base_feed.read_bytes() + b'\n')
            result = run([sys.executable, '-B', '-X', 'utf8', ROOT / 'scripts/prepare-component-publication.py',
                stage, '--base-feed', stale_feed,
                '--reader-packages', args.reader_packages.resolve(),
                '--djvu-packages', args.djvu_packages.resolve(),
                '--release-metadata', args.release_metadata.resolve(),
                '--kfx-source', args.kfx_source.resolve(),
                '--output', negative])
            assert result.returncode != 0 and 'Public feed size is stale' in result.stderr
            assert not negative.exists(), 'Stale feed created publication output'
            report['stale_cached_feed_rejected_before_output'] = True
            # Keep the current release identity and a self-consistent manifest,
            # but replace the Reader bytes. This checks the source/build gate
            # without depending on a previous numbered staging directory.
            stale_readers = runtime / 'stale-reader-packages'
            stale_readers.mkdir()
            reader_feed_bytes = (args.reader_packages / 'HomeLibRu.components.json').read_bytes()
            (stale_readers / 'HomeLibRu.components.json').write_bytes(reader_feed_bytes)
            reader_entries = json.loads(reader_feed_bytes)['components']
            for index, entry in enumerate(reader_entries):
                source_archive = args.reader_packages / entry['archive']
                destination = stale_readers / entry['archive']
                if index:
                    destination.write_bytes(source_archive.read_bytes())
                    continue
                with zipfile.ZipFile(source_archive) as archive:
                    payload = {name: archive.read(name) for name in archive.namelist()}
                binary = bytearray(payload['HomeLibReader.exe'])
                binary[-1] ^= 1
                payload['HomeLibReader.exe'] = bytes(binary)
                manifest = json.loads(payload['HomeLibRu.update.json'])
                executable = next(item for item in manifest['files'] if item['path'] == 'HomeLibReader.exe')
                executable['sha256'] = hashlib.sha256(binary).hexdigest()
                payload['HomeLibRu.update.json'] = json.dumps(manifest).encode('utf-8')
                with zipfile.ZipFile(destination, 'x', zipfile.ZIP_DEFLATED) as archive:
                    for name, data in payload.items():
                        archive.writestr(name, data)
            stale_reader_output = runtime / 'stale-reader-output'
            result = run([sys.executable, '-B', '-X', 'utf8', ROOT / 'scripts/prepare-component-publication.py',
                stage, '--base-feed', args.base_feed.resolve(),
                '--release-metadata', args.release_metadata.resolve(),
                '--reader-packages', stale_readers, '--djvu-packages', args.djvu_packages.resolve(),
                '--kfx-source', args.kfx_source.resolve(),
                '--output', stale_reader_output])
            assert result.returncode != 0 and 'Reader archive does not match current executable' in result.stderr
            assert not stale_reader_output.exists(), 'Stale Reader created publication output'
            report['stale_reader_archives_rejected_before_output'] = True
        report.update(status='PASS', temporary_payloads_removed=True,
                      package_verification=json.loads((publication / 'verification-report.json').read_bytes()),
                      publication_plan=str(publication / 'publication-plan.json'))
    except Exception as error:
        report['error'] = repr(error)
        raise
    finally:
        with args.report.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
    print('PASS: exact feed x86/x64; invalid digest and stale cache rejected; private payloads removed; not published')


if __name__ == '__main__':
    main()

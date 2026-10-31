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

ROOT = Path(__file__).resolve().parents[3]
TAG = 'optional-alreader-2.5.1009.25'
PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + TAG + '/'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    return subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                          encoding='utf-8-sig', timeout=120,
                          creationflags=subprocess.CREATE_NO_WINDOW)


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
    args = parser.parse_args()
    stage = args.stage.resolve()
    publication = args.publication_dir.resolve() if args.publication_dir else stage / 'publication-r1'
    source = ROOT / 'Program/Units/unit_ComponentUpdates.pas'
    component_ids = re.findall(r"\(ID:'([^']+)'", source.read_text(encoding='utf-8-sig'))
    assert len(component_ids) == len(set(component_ids)) == 20
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
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-feed-') as temporary:
            runtime = Path(temporary).resolve()
            assert runtime.parent == Path(os.environ['TEMP']).resolve()
            assert runtime.name.startswith('HomeLibRu-update-test-feed-') and not runtime.is_symlink()
            for platform in ('Win32', 'Win64'):
                native = ROOT / 'Program/Tests/Out' / platform / 'ProgramUpdateInstallerTest.exe'
                command = [native, '--components', feed_path, TAG, assets_path, '2.7.0.1105', '--partial']
                result = run(command)
                assert result.returncode == 0, (platform, result.returncode, result.stdout, result.stderr)
                lines = result.stdout.strip().splitlines()
                assert lines[-1] == 'PASS'
                parsed = json.loads(lines[0])
                assert len(parsed) == len(component_ids) * 3
                actual = {component: (parsed[index * 3], parsed[index * 3 + 1])
                          for index, component in enumerate(component_ids)}
                expected = [entry for entry in feed['components'] if entry['platform'] == platform]
                assert len(expected) == 17
                for entry in expected:
                    assert actual[entry['id']] == (entry['version'], PREFIX + entry['archive']), (platform, entry)
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
            result = run([sys.executable, '-B', '-X', 'utf8', ROOT / 'scripts/prepare-component-publication.py',
                stage, '--base-feed', ROOT / 'tools/ui/tests/Out/pre537-final-20261029-r1/remote/HomeLibRu.components.json',
                '--reader-packages', args.reader_packages.resolve(),
                '--djvu-packages', args.djvu_packages.resolve(),
                '--release-metadata', args.release_metadata.resolve(),
                '--output', negative])
            assert result.returncode != 0 and 'Public feed size is stale' in result.stderr
            assert not negative.exists(), 'Stale feed created publication output'
            report['stale_cached_feed_rejected_before_output'] = True
            stale_reader_output = runtime / 'stale-reader-output'
            result = run([sys.executable, '-B', '-X', 'utf8', ROOT / 'scripts/prepare-component-publication.py',
                stage, '--base-feed', args.base_feed.resolve(),
                '--release-metadata', args.release_metadata.resolve(),
                '--reader-packages', stage / 'reader-r2', '--djvu-packages', args.djvu_packages.resolve(),
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

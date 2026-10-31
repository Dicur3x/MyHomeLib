"""Run the production release parser against branded and legacy archive feeds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tester', type=Path)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    assert not args.report.exists(), 'Preserve earlier reports'
    suffix = '_x64' if args.platform == 'Win64' else ''
    other = '' if suffix else '_x64'
    legacy, branded = 'HomeLibRu' + suffix + '.zip', 'HomeLibre' + suffix + '.zip'
    tag = '3.0.0_pre1.2'
    base = 'https://github.com/Dicur3x/MyHomeLib/releases/download/'
    digest = 'a' * 64
    report = dict(status='INCOMPLETE', platform=args.platform, cases=[],
                  tester_sha256=hashlib.sha256(args.tester.read_bytes()).hexdigest(),
                  temporary_root_removed=False,
                  scope='Production parser only; no downloading, installation, or publishing')
    env = dict(os.environ, TEMP=str(args.work_dir), TMP=str(args.work_dir))

    def asset(name, **changes):
        return dict(name=name, browser_download_url=base + tag + '/' + name,
                    digest='sha256:' + digest, size=123) | changes

    def release(assets, version=tag):
        return dict(tag_name=version, draft=False, prerelease=False, body='Fixture', assets=assets)

    cases = [
        ('legacy', [asset(legacy)], legacy),
        ('branded', [asset(branded)], branded),
        ('prefer-branded', [asset(legacy), asset(branded)], branded),
        ('prefer-branded-reverse', [asset(branded), asset(legacy)], branded),
        ('invalid-branded-url', [asset(legacy), asset(branded, browser_download_url='https://example.org/book.zip')], legacy),
        ('invalid-branded-size', [asset(legacy), asset(branded, size=0)], legacy),
        ('invalid-legacy-after-branded', [asset(branded), asset(legacy, size=-1)], branded),
        ('wrong-platform', [asset('HomeLibre' + other + '.zip')], None),
        ('invalid-checksum', [asset(branded, digest='sha256:bad')], None),
        ('invalid-repository', [asset(branded, browser_download_url=base.replace('Dicur3x', 'another') + tag + '/' + branded)], None),
        ('invalid-size', [asset(branded, size=-1)], None),
    ]
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-archive-names-', dir=args.work_dir) as temporary:
            root = Path(temporary)
            for name, assets, expected in cases:
                feed = root / (name + '.json')
                feed.write_text(json.dumps([release(assets)]), encoding='utf-8')
                run = subprocess.run([str(args.tester.resolve()), '--parse', str(feed)],
                    capture_output=True, encoding='utf-8-sig', env=env, timeout=20,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                assert run.returncode == 0, (name, run.stdout, run.stderr)
                values = json.JSONDecoder().raw_decode(run.stdout.strip())[0]
                assert values[0] == tag
                assert values[1] == (base + tag + '/' + expected if expected else ''), (name, values)
                assert values[2:4] == ([digest, 123] if expected else ['', 0]), (name, values)
                report['cases'].append(dict(name=name, status='PASS', selected=expected))
        report.update(status='PASS', temporary_root_removed=not root.exists())
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()

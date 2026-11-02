"""Run real book/Reader/conversion usage checks, one fresh native process per book."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / 'tools/ui/tests/Out'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    if not re.fullmatch(r'[a-z0-9-]{1,24}', args.label):
        raise ValueError('Invalid evidence label')
    report = OUT / f'{args.label}-{args.platform}.json'
    if report.exists():
        raise ValueError('Refuse to overwrite native evidence')
    spec = importlib.util.spec_from_file_location('usage_cases', Path(__file__).with_name('component_usage_formats.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = [(extension, *case) for extension, case in module.CASES.items()]
    cases.append(('.wps', 743118, 'LegacyOffice'))
    architecture = 'Bin64' if args.platform == 'Win64' else 'Bin'
    exe = OUT / args.platform / 'CollectionViewsTest.exe'
    result = {'status': 'RUNNING', 'platform': args.platform, 'binary_sha256': digest(exe),
              'native_test_source_sha256': digest(Path(__file__).with_name('Feedback532Tests.inc')),
              'package_feed_sha256': digest(args.packages / 'format-components.json'), 'rows': []}
    if args.reuse_passed_from:
        previous = json.loads(args.reuse_passed_from.read_text(encoding='utf-8'))
        for key in ('platform', 'binary_sha256', 'native_test_source_sha256', 'package_feed_sha256'):
            if previous[key] != result[key]:
                raise ValueError('Earlier native evidence has a different ' + key)
        for row in previous['rows']:
            if row['status'] != 'PASS' or digest(Path(row['result'])) != row['sha256'] or digest(Path(row['log'])) != row['log_sha256']:
                raise ValueError('Earlier passing evidence changed')
            if (row['extension'], row['id'], row['component']) not in cases:
                raise ValueError('Earlier evidence describes an unrequested book')
            result['rows'].append(dict(row, reused_from=str(args.reuse_passed_from.resolve())))
    environment = dict(os.environ, HOMELIB_TEST_FORMAT_USAGE='1',
                       HOMELIB_FORMAT_COMPONENT_PACKAGES=str(args.packages.resolve()))

    def save():
        report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    save()
    try:
        for extension, book_id, component in cases:
            if any(row['id'] == book_id for row in result['rows']):
                print('REUSE verified native actual usage', args.platform, extension, book_id, flush=True)
                continue
            label = f'{args.label}-{book_id}'
            log = OUT / f'{label}-{args.platform}.txt'
            if log.exists():
                raise ValueError('Refuse to overwrite case evidence')
            command = ['node', str(Path(__file__).with_name('native_collection_tests.js')),
                       str(REPO / 'Program/Out' / architecture), '-', '-', str(exe),
                       '--views-mode=catalogue-formats', '--offline-only',
                       '--catalogue-inventory=' + str(OUT / 'pre533-format-inventory.json'),
                       '--catalogue-python=' + str(args.python.resolve()),
                       '--catalogue-select=id:' + str(book_id), '--catalogue-label=' + label,
                       '--catalogue-expect-success']
            print('START native actual usage', args.platform, extension, book_id, flush=True)
            with log.open('x', encoding='utf-8') as output:
                completed = subprocess.run(command, cwd=REPO, env=environment, stdout=output,
                                           stderr=subprocess.STDOUT, timeout=300,
                                           creationflags=0x08000000)
            if completed.returncode:
                raise ValueError(f'Native {extension}/{book_id} failed; see {log}')
            source = OUT / f'pre532-{args.platform}-{label}-results.json'
            rows = json.loads(source.read_text(encoding='utf-8-sig'))
            if len(rows) != 1 or rows[0]['id'] != book_id:
                raise ValueError('Wrong native book report')
            row = rows[0]
            for stage in ('read', 'fb2', 'epub'):
                used = row['usage_' + stage]
                if not isinstance(used, list) or (component and component not in used):
                    raise ValueError('Actual source-module use was omitted: ' + stage)
                if set(used) - ({component, 'BookProcessing'} if component else {'BookProcessing'}):
                    raise ValueError('Native book operation recorded an unrelated module')
                if stage != 'read' and not row.get('.' + stage + '_identity_copy') and 'BookProcessing' not in used:
                    raise ValueError('Actual converter was not recorded')
            if row['read'] != 'ok' or row['.fb2'] != 'ok' or row['.epub'] != 'ok':
                raise ValueError('Reading or conversion failed')
            result['rows'].append({'id': book_id, 'extension': extension, 'component': component,
                                   'status': 'PASS', 'result': str(source), 'sha256': digest(source),
                                   'log': str(log), 'log_sha256': digest(log),
                                   'usage': {stage: row['usage_' + stage] for stage in ('read', 'fb2', 'epub')}})
            save()
            print('PASS native actual usage', args.platform, extension, book_id, flush=True)
        result['status'] = 'PASS_NATIVE_REAL_BOOK_USAGE'
    except Exception as error:
        result['status'] = 'FAIL'
        result['error'] = str(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--reuse-passed-from', type=Path)
    run(parser.parse_args())

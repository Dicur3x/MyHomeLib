"""Exercise updater instance coordination using only owned synthetic windows.

This validates the production controller, argv, source leases, orderly close,
state restoration, failure recovery, and isolation from another installation.
It does not claim to verify real book rendering or complete update packages.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def wait_for(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise AssertionError('Owned fixture did not reach the requested state')


def peers(root):
    query = "Get-CimInstance Win32_Process -Filter \"Name='HomeLibReader.exe' OR Name='HomeLibRu.exe'\" | Select-Object ProcessId,ExecutablePath | ConvertTo-Json -Compress"
    raw = subprocess.check_output(['powershell', '-NoProfile', '-NonInteractive', '-Command', query],
                                  encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW)
    rows = json.loads(raw) if raw.strip() else []
    if isinstance(rows, dict):
        rows = [rows]
    return [row for row in rows if row.get('ExecutablePath') and
            Path(row['ExecutablePath']).is_relative_to(root)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tester', type=Path)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-related-', dir=work)).resolve()
    assert root.parent == work and not root.is_junction() and not root.is_symlink()
    env = dict(os.environ, TEMP=str(work), TMP=str(work))
    report = dict(status='INCOMPLETE', root=str(root), tester_sha256=sha(args.tester),
                  temporary_root_removed=False, cases=[])
    fixtures = []

    def launch(app, name, source=None, *, hidden=False, refuse=False, session=False,
               left=120, top=120, purge=None, current=None, origin=None):
        state = app.parent / (name + '.state.json')
        exe = app / ('HomeLibRu.exe' if name.startswith('catalogue') else 'HomeLibReader.exe')
        command = [str(exe), '--related-fixture', '--fixture-state=' + str(state),
                   '--fixture-page=1', '--fixture-left=' + str(left), '--fixture-top=' + str(top)]
        if hidden:
            command += ['--fixture-hidden=1']
        if refuse:
            command += ['--fixture-refuse=1']
        if purge:
            command += ['--fixture-purge=' + str(purge)]
        if current:
            command += ['--fixture-current=' + str(current)]
        if origin:
            command += ['--fixture-origin=' + str(origin)]
        if source:
            if session:
                request = app.parent / (name + '-request.json')
                request.write_text(json.dumps(dict(source=str(source))), encoding='utf-8')
                command += ['--session=' + str(request)]
            else:
                command += ['--open=' + str(source)]
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        fixture = dict(state=state, process=process, source=source, original_pid=process.pid)
        fixtures.append(fixture)
        wait_for(lambda: (data := read_json(Path(str(state) + '.live')))['pid'] == process.pid and
                 data.get('protocol') == 2)
        return fixture

    def stop_all():
        for item in fixtures:
            Path(str(item['state']) + '.allow-close').write_text('allow', encoding='ascii')
            Path(str(item['state']) + '.stop').write_text('stop', encoding='ascii')
        wait_for(lambda: not peers(root), 25)
        for item in fixtures:
            item['process'].wait(timeout=5)
            item['process'].stdout.close()
        fixtures.clear()

    last_output = None
    scenario = 'not-started'
    try:
        for scenario in ('normal', 'close-refused', 'missing-input', 'current-book', 'current-book-no-cli'):
            case = root / scenario
            app, other, cache = case / 'installation', case / 'other-installation', case / 'cache'
            for directory in (app, other, cache):
                directory.mkdir(parents=True)
            for directory in (app, other):
                for name in ('HomeLibRu.exe', 'HomeLibReader.exe'):
                    shutil.copyfile(args.tester, directory / name)
            sources = []
            for index in range(4):
                source = (other if index == 3 else cache) / ('Книга № %d & проверка.book' % index)
                source.write_text('Owned cached book %d' % index, encoding='utf-8')
                sources.append(source)
            original = {str(source): sha(source) for source in sources}
            current = origin = None
            expected_purged = []
            if scenario.startswith('current-book'):
                current, origin = cache / 'selected-book.book', cache / 'origin-archive.book'
                current.write_text('Current selected payload', encoding='utf-8')
                origin.write_text('Original archive for save continuation', encoding='utf-8')
                original.update({str(value): sha(value) for value in (current, origin)})
                del original[str(sources[0])]
                expected_purged = [str(sources[0])]
            one = launch(app, 'reader-a', None if scenario == 'current-book-no-cli' else sources[0],
                         left=150, top=170, current=current, origin=origin)
            two = launch(app, 'reader-b', sources[1], session=True,
                         refuse=scenario == 'close-refused', left=620, top=210)
            ghost = launch(app, 'ghost', hidden=True)
            foreign = launch(other, 'foreign', sources[3], left=1060, top=220)
            catalogue = launch(app, 'catalogue-a', purge=cache, left=80, top=450)
            # Deliberately hold the observer's read handle across several native
            # timer writes. A test window must survive this normal polling race.
            with Path(str(one['state']) + '.live').open('rb') as observer:
                time.sleep(0.4)
                assert one['process'].poll() is None, 'The observer read lock crashed its fixture'
            for item, page in ((one, 23), (two, 57)):
                pending = Path(str(item['state']) + '.page.new')
                pending.write_text(str(page), encoding='ascii')
                os.replace(pending, Path(str(item['state']) + '.page'))
                wait_for(lambda: read_json(Path(str(item['state']) + '.live'))['page'] == page)
            before = {item['original_pid']: wait_for(lambda: read_json(Path(str(item['state']) + '.live')))
                      for item in (one, two, catalogue)}
            profile = case / 'caller-profile'
            profile.mkdir()
            (profile / 'HomeLibReader.ini').write_text('[ReaderSession]\nPendingFile=' + str(sources[2]) + '\n', encoding='utf-8')
            caller = case / 'caller-command.txt'
            caller.write_text('"' + str(app / 'HomeLibReader.exe') + '" "--profile=' + str(profile) + '"', encoding='utf-8')
            if scenario == 'missing-input':
                sources[0].unlink()
            job = case / 'job'
            run = subprocess.run([str(args.tester.resolve()), '--related-cycle', str(app), str(job),
                                  '1000' if scenario == 'close-refused' else '10000', str(caller)],
                                 env=env, capture_output=True, timeout=45,
                                 creationflags=subprocess.CREATE_NO_WINDOW)
            output = (run.stdout + run.stderr).decode('utf-8', errors='replace')
            last_output = dict(scenario=scenario, exit_code=run.returncode, output=output,
                processes=[dict(pid=item['original_pid'], exit_code=item['process'].poll(),
                    output=item['process'].stdout.read().decode('utf-8', errors='replace')
                        if item['process'].poll() is not None else None,
                    closed=Path(str(item['state']) + '.closed').exists()) for item in fixtures])
            assert foreign['process'].poll() is None and not Path(str(foreign['state']) + '.closed').exists()
            if scenario == 'missing-input':
                assert run.returncode == 1, output
                assert all(item['process'].poll() is None for item in fixtures)
                assert not any(Path(str(item['state']) + '.closed').exists() for item in fixtures)
                result = dict(scenario=scenario, status='PASS', rejected_before_close=True, native_output=output)
            else:
                assert run.returncode == (1 if scenario == 'close-refused' else 0), output
                state = read_json(job / 'restart-instances.json')
                assert len(state['instances']) == 4 and state['caller_input_pinned']
                entries = {entry['pid']: entry for entry in state['instances']}
                assert foreign['original_pid'] not in entries
                assert not entries[ghost['original_pid']]['restore_window']
                if scenario != 'close-refused':
                    assert state['phase'] == 'restored', state
                    assert ghost['process'].poll() == 0
                    assert not entries[ghost['original_pid']]['restarted']
                else:
                    assert two['process'].poll() is None, 'The refusing window was forcibly terminated'
                    assert not entries[two['original_pid']]['restarted']
                restored = []
                for item in ((one, two, catalogue) if scenario != 'close-refused' else (one, catalogue)):
                    entry = entries[item['original_pid']]
                    assert entry['restarted'] and entry['restart_pid'] != item['original_pid']
                    live = wait_for(lambda: (data if (data := read_json(Path(str(item['state']) + '.live')))['pid'] == entry['restart_pid'] else None))
                    previous = before[item['original_pid']]
                    assert live['page'] == previous['page']
                    assert live['source'] == previous['source'], 'The original CLI book replaced the current book'
                    assert all(live[key] == previous[key] for key in ('left', 'top', 'width', 'height'))
                    assert item['process'].poll() == 0
                    restored.append(dict(old_pid=item['original_pid'], new_pid=live['pid'], page=live['page']))
                assert all(sha(Path(path)) == digest for path, digest in original.items()), 'Cached input was removed during the update'
                closed_core = read_json(Path(str(catalogue['state']) + '.closed'))
                assert closed_core['purged'] == expected_purged
                result = dict(scenario=scenario, status='PASS', restored=restored,
                              observer_read_lock_survived=True,
                              different_installation_untouched=True, cached_inputs_preserved=True,
                              hidden_process_not_reopened=scenario != 'close-refused',
                              current_book_and_archive_origin_preserved=bool(current), native_output=output)
            report['cases'].append(result)
            stop_all()
        report['status'] = 'PASS'
        assert root.parent == work and not peers(root)
        shutil.rmtree(root)
        report['temporary_root_removed'] = not root.exists()
    except BaseException as error:
        report['error'] = repr(error)
        report['last_run'] = last_output
        report['fixture_failures'] = [dict(pid=item['original_pid'], exit_code=item['process'].poll(),
            output=item['process'].stdout.read().decode('utf-8', errors='replace'))
            for item in fixtures if item['process'].poll() not in (None, 0)]
        raise
    finally:
        if fixtures:
            stop_all()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(dict(status=report['status'], root=report['root'],
        temporary_root_removed=report['temporary_root_removed'],
        cases=[{key: value for key, value in item.items() if key != 'native_output'}
               for item in report['cases']]), ensure_ascii=False))


if __name__ == '__main__':
    main()

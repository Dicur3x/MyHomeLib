"""Repair missing distribution components using the real native installer.

All targets, archives and profiles are created below a fresh temporary folder.
The supplied release ZIP must match its independently supplied SHA-256.
No existing installation or personal data is used or removed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile

p = argparse.ArgumentParser()
p.add_argument('tester', type=Path)
p.add_argument('archive', type=Path)
p.add_argument('--sha256', required=True)
p.add_argument('--preservation-only', action='store_true')
p.add_argument('--work-dir', type=Path, required=True)
p.add_argument('--log-dir', type=Path, required=True)
a = p.parse_args()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
assert sha(a.archive) == a.sha256, 'Release fixture SHA-256 differs'
a.work_dir.mkdir(parents=True, exist_ok=True)
a.log_dir.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-repair-', dir=a.work_dir)).resolve()
env = os.environ.copy()
env['TEMP'] = env['TMP'] = str(a.work_dir.resolve())
archive = root / 'release.zip'
shutil.copyfile(a.archive, archive)
events = []


def run(arguments, expected=0):
    result = subprocess.run([str(a.tester.resolve()), *map(str, arguments)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=120, creationflags=0x08000000)
    log = a.log_dir / (root.name + '-%03d.log' % (len(events) + 1))
    log.write_bytes(result.stdout)
    try:
        output = result.stdout.decode('utf-8')
    except UnicodeDecodeError:
        output = result.stdout.decode('cp1251')
    events.append(dict(arguments=list(map(str, arguments)), exit_code=result.returncode,
                       expected_exit_code=expected, log=log.name, log_sha256=sha(log)))
    assert result.returncode == expected, output
    return output


with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    manifest = json.loads(z.read('HomeLibRu.update.json').decode('utf-8-sig'))
    tag = manifest['release']
    for name in z.namelist():
        parts = name.replace('\\', '/').split('/')
        assert not name.startswith(('/', '\\')) and ':' not in name and '..' not in parts
    target = root / 'installation'
    z.extractall(target)
profile_names = ['myhomelib2.ini', 'Data/collections.db', 'Data/personal.sqlite',
                 'Data/library-a.hlc2', 'Data/library-b.hlc2', 'Data/groups.db',
                 'Data/notes.json', 'Data/bookmarks.json', 'Data/favorites.json',
                 'Data/ratings.json', 'Data/reviews.json', 'Data/progress.json',
                 'Data/queue.json', 'Data/history.json', 'presets.cxml2', 'uselocaldata',
                 'Readers/AlReader/$savevtut.ini', 'Readers/AlReader/options.ini',
                 'Readers/SumatraPDF/SumatraPDF-settings.txt']
for name in profile_names:
    file = target / name
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text('Owned Unicode profile: Заметки и история / ' + name, encoding='utf-8')
personal_before = {name: sha(target / name) for name in profile_names}
cases = [('7-Zip', 'tools/7zip'), ('DocSharp', 'tools/doc'), ('DjVuLibre', 'tools/djvu'),
         ('AlReader', 'Readers/AlReader'), ('SumatraPDF', 'Readers/SumatraPDF'),
         ('SQLite', 'sqlite3.dll')]
for component, _ in cases:
    assert run(['--component-needs-repair', target, component]).splitlines()[0] == '0', component
completed = []
preservation = []
try:
    for index, (component, member) in enumerate([] if a.preservation_only else cases):
        saved = root / ('held-' + str(index))
        (target / member).rename(saved)
        # Personal reader profiles are independent from program distribution files.
        # Restore them into the new partial folder before running the installer.
        for name in profile_names:
            if name.startswith(member + '/'):
                destination = target / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(saved / Path(name).relative_to(member), destination)
        assert run(['--component-needs-repair', target, component]).splitlines()[0] == '1', component
        job = root / ('job-' + str(index))
        run(['--prepare', archive, a.sha256, tag, job])
        shutil.copyfile(archive, job / 'release.zip')
        if index == 0:
            helper = Path(run(['--prepared-helper', job, tag, a.sha256]).splitlines()[0])
            assert helper == job / 'payload/HomeLibRuUpdater.exe'
            payload = helper.read_bytes()
            record = job / 'manifest.json'
            original_manifest = record.read_bytes()
            broken = payload[:-1] + bytes([payload[-1] ^ 1])
            helper.write_bytes(broken)
            try:
                run(['--prepared-helper', job, tag, a.sha256], 1)
                modified = json.loads(original_manifest.decode('utf-8-sig'))
                next(f for f in modified['files'] if f['path'] == 'HomeLibRuUpdater.exe')['sha256'] = sha(helper)
                record.write_text(json.dumps(modified), encoding='utf-8')
                run(['--prepared-helper', job, tag, a.sha256], 1)
            finally:
                helper.write_bytes(payload)
                record.write_bytes(original_manifest)
            run(['--prepared-helper', job, tag, '0' * 64], 1)
            run(['--prepared-helper', job, tag, a.sha256])
            print('PASS prepared helper rejects changed payload, edited loose manifest and wrong archive hash', flush=True)
        run(['--install', job, target])
        assert run(['--component-needs-repair', target, component]).splitlines()[0] == '0', component
        assert {name: sha(target / name) for name in profile_names} == personal_before
        for f in manifest['files']:
            if f['path'] == 'Readers/AlReader/$savevtut.ini':
                continue
            assert sha(target / f['path']) == f['sha256'], f['path']
        state = json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state']
        assert state == 'installed'
        completed.append(component)
        print('PASS real release repairs missing ' + component + ' and preserves 19 personal files', flush=True)
    # Simulate a separately installed newer 7-Zip by changing only the fixed
    # version resource in owned target copies. Packages remain the pinned bytes.
    import struct
    for name in ['7z.exe', '7z.dll']:
        file = target / 'tools/7zip' / name
        data = bytearray(file.read_bytes())
        key = 'VS_VERSION_INFO\0'.encode('utf-16-le')
        value = (data.index(key) + len(key) + 3) & ~3
        assert data[value:value + 4] == bytes.fromhex('bd04effe')
        offset = value + 8
        struct.pack_into('<I', data, offset, struct.unpack_from('<I', data, offset)[0] + 1)
        file.write_bytes(data)
    assert run(['--component-needs-repair', target, '7-Zip']).splitlines()[0] == '0'
    newer_files = {file.name: sha(file) for file in (target / 'tools/7zip').iterdir() if file.is_file()}
    for missing in [False, True]:
        if missing:
            (target / 'tools/7zip/License.txt').unlink()
            assert run(['--component-needs-repair', target, '7-Zip']).splitlines()[0] == '1'
        job = root / ('newer-incomplete' if missing else 'newer-complete')
        run(['--prepare', archive, a.sha256, tag, job])
        shutil.copyfile(archive, job / 'release.zip')
        run(['--install', job, target])
        assert run(['--component-needs-repair', target, '7-Zip']).splitlines()[0] == '0'
        assert {name: sha(target / name) for name in profile_names} == personal_before
        if missing:
            for f in manifest['files']:
                if f['path'].startswith('tools/7zip/'):
                    assert sha(target / f['path']) == f['sha256'], f['path']
            label = 'incomplete newer 7-Zip is repaired as one complete distribution component'
        else:
            assert {file.name: sha(file) for file in (target / 'tools/7zip').iterdir() if file.is_file()} == newer_files
            label = 'complete independently installed newer 7-Zip is preserved'
        assert json.loads((job / 'journal.json').read_text(encoding='utf-8-sig'))['state'] == 'installed'
        preservation.append(label)
        print('PASS ' + label + '; 19 personal files unchanged', flush=True)
finally:
    proof = dict(platform=manifest['platform'], release=tag, root=str(root), tester_sha256=sha(a.tester),
                 archive_sha256=sha(archive), completed_components=completed, preservation_cases=preservation,
                 preservation_only=a.preservation_only, personal_files=personal_before,
                 native_calls=events)
    (a.log_dir / ('component-repair-' + manifest['platform'] + '-' + root.name + '.json')).write_text(
        json.dumps(proof, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('PASS repair installer cases=' + str(len(completed) + len(preservation)) + ' (' + manifest['platform'] + ')', flush=True)

"""Exercise the actual paired official download worker, not just extraction."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, tempfile

source_exe, runtime, fixtures = map(lambda p: Path(p).resolve(), sys.argv[1:4])
root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-network-'))
app = root / 'runtime'; app.mkdir()
exe = app / source_exe.name; shutil.copy2(source_exe, exe)
for component in ('doc', '7zip'):
    shutil.copytree(runtime / 'tools' / component, app / 'tools' / component)
primary = fixtures / 'docsharp.binary.doc.0.21.0.nupkg'
secondary = fixtures / 'docsharp.binary.common.0.21.0.nupkg'

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(*args, expected=0):
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True,
                            timeout=90, creationflags=0x08000000)
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    assert result.returncode == expected, (args, result.returncode, output)
    return output

target = root / 'target'; target.mkdir()
protected = {'reader.ini': b'position=42', 'reader-notes.json': b'personal notes',
             'myhomelib2.ini': b'preferences', 'Data/books.hlc2': b'catalog',
             'Data/user.dbs2': b'ratings, groups, history', 'HomeLibRu.exe': b'program'}
for name, data in protected.items():
    path = target / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)

def download(job, option=''):
    return run('--download-doc', '0.21.0', primary.stat().st_size,
               secondary.stat().st_size, '-', job, option, expected=1 if option else 0)

job = root / 'HomeLibRu-update-success'
download(job)
assert digest(job / 'release.zip') == digest(primary)
assert digest(job / 'secondary.archive') == digest(secondary)
manifest = json.loads((job / 'manifest.json').read_text(encoding='utf-8-sig'))
assert manifest['official'] and manifest['component'] == 'DocSharp' and manifest['version'] == '0.21.0'
assert any(f['path'].endswith('DocSharp.Binary.Doc.dll') for f in manifest['files'])
assert any(f['path'].endswith('DocSharp.Binary.Common.dll') for f in manifest['files'])
run('--install', job, target)
for entry in manifest['files']: assert digest(target / entry['path']) == entry['sha256']
for name, data in protected.items(): assert (target / name).read_bytes() == data
print('PASS actual paired NuGet streaming, validation and install preserve books/settings/history/notes', flush=True)

state = {p.relative_to(target).as_posix(): digest(p) for p in target.rglob('*') if p.is_file()}
for option in ('--bad-second-size', '--cancel'):
    failed = root / ('HomeLibRu-update-' + option[2:])
    output = download(failed, option)
    assert not (failed / 'manifest.json').exists(), output
    assert state == {p.relative_to(target).as_posix(): digest(p) for p in target.rglob('*') if p.is_file()}
    print('PASS ' + option + ' cannot produce an installable job or alter installed data', flush=True)
report = {'root': str(root), 'exe_sha256': digest(exe), 'primary_sha256': digest(primary),
          'secondary_sha256': digest(secondary), 'protected_files': len(protected), 'cases': 3}
(root / 'verification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print('PASS official paired pipeline:', root, flush=True)

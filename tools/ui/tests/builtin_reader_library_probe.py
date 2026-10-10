"""Read selected LightLib archive members into an isolated temporary runtime."""
import argparse, base64, hashlib, json, os, pathlib, shutil, subprocess, tempfile, zipfile
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser()
p.add_argument('runtime', type=pathlib.Path)
p.add_argument('exe', type=pathlib.Path)
p.add_argument('books', type=pathlib.Path)
a = p.parse_args()
runtime, exe, books = a.runtime.resolve(), a.exe.resolve(), a.books.resolve()
assert books.is_dir(), 'Provide the directory containing the selected LightLib archives'
extractor = runtime/'tools/7zip/7za.exe'
selected = {
    'd.fb2-009373-367300.zip': ['110535.fb2', '110119.fb2'],
    'f.fb2-173909-177717.zip': ['173914.fb2', '173916.fb2', '173953.fb2', '177455.fb2'],
}
def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

root = pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-lightlib-')).resolve()
assert root.parent == pathlib.Path(tempfile.gettempdir()).resolve()
(root/'Data').mkdir()
shutil.copy2(exe, root/exe.name)
shutil.copytree(runtime/'tools/webp', root/'tools/webp')
for marker in ('uselocaldata', 'uselocaltemp'): (root/marker).write_text('')
(root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
(root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\n[OPDS]\nEnabled=0\n', encoding='utf-8')
startup = subprocess.STARTUPINFO()
startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
startup.wShowWindow = 0
report = []
for archive_name, members in selected.items():
    archive = (books/archive_name).resolve()
    assert archive.parent == books
    before = sha(archive)
    with zipfile.ZipFile(archive) as z:
        for member in members:
            info = z.getinfo(member)
            assert info.file_size < 64*1024*1024
            result = subprocess.run([str(extractor), 'e', '-so', str(archive), member],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=60, startupinfo=startup)
            assert result.returncode == 0, result.stderr.decode('mbcs', errors='replace')
            assert len(result.stdout) == info.file_size
            (root/member).write_bytes(result.stdout)
            tree = ET.fromstring(result.stdout)
            binaries = [n for n in tree.iter() if n.tag.rsplit('}', 1)[-1] == 'binary']
            signatures = [base64.b64decode(n.text or '')[:12] for n in binaries]
            report.append({'archive': archive_name, 'member': member,
                           'bytes': info.file_size, 'method': info.compress_type,
                           'binaries': len(binaries),
                           'webp_binaries': sum(b[:4] == b'RIFF' and b[8:12] == b'WEBP' for b in signatures),
                           'sha256': hashlib.sha256(result.stdout).hexdigest()})
    assert sha(archive) == before
before = {f.name: sha(f) for f in root.glob('*.fb2')}
env = dict(os.environ, HOMELIBRU_NATIVE_TEST='1')
result = subprocess.run([str(root/exe.name)], cwd=root, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, encoding='mbcs', errors='replace',
                        timeout=150, startupinfo=startup, env=env)
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
print(result.stdout, flush=True)
assert result.returncode == 0 and 'PASS isolated real library reader probe' in result.stdout
assert before == {name: sha(root/name) for name in before}
print('PASS original LightLib archives and extracted books unchanged; no network server started')
print('RETAINED', root)

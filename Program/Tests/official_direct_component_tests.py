"""Real official Windows archives + production installer in isolated TEMP targets."""
from pathlib import Path
import os, sys, tempfile, subprocess, json, hashlib, shutil, time

exe=Path(sys.argv[1]).resolve(); fixtures=Path(sys.argv[2]).resolve(); runtime=Path(sys.argv[3]).resolve()
root=Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-direct-'))
platform='Win64' if exe.read_bytes()[int.from_bytes(exe.read_bytes()[0x3c:0x40],'little')+4:][:2]==b'\x64\x86' else 'Win32'
arch='x64' if platform=='Win64' else 'x86'; count=0

def run(*args, expected=0, timeout=45):
    r=subprocess.run([str(exe),*map(str,args)],capture_output=True,timeout=timeout,creationflags=0x08000000)
    try:text=(r.stdout+r.stderr).decode('utf-8')
    except UnicodeDecodeError:text=(r.stdout+r.stderr).decode('cp1251')
    assert r.returncode==expected,(args,r.returncode,text)
    return text

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pass_(text):
    global count
    count+=1;print('PASS '+text,flush=True)
def copy(name):
    dest=root/name;shutil.copy2(fixtures/name,dest);return dest

urls=[('7-Zip','26.04',f'https://github.com/ip7z/7zip/releases/download/26.04/7z2604'+('-x64' if platform=='Win64' else '')+'.exe',''),
      ('DocSharp','0.21.0','https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/0.21.0/docsharp.binary.doc.0.21.0.nupkg',''),
      ('DocSharp','0.21.0','https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/0.21.0/docsharp.binary.common.0.21.0.nupkg','secondary')]
for id,ver,url,secondary in urls:
    run('--official-url',id,ver,url,secondary)
    for bad in [url.replace('https:','http:'),url+'?redirect=evil',url.replace('https://','https://evil.example/'),url.replace('0.21.0/','0.21.1/'),url.replace('26.04/','26.05/')]:
        if bad!=url:run('--official-url',id,ver,bad,secondary,expected=1)
pass_('official origin, version and architecture allowlists reject foreign and altered URLs')

for id,filename,version,secondary in [('7-Zip',f'7zip-{arch}.exe','26.04',''),('DjVuLibre','djvu.exe','3.5.29','djvu-source.tar.gz'),
                                    ('DocSharp','docsharp.binary.doc.0.21.0.nupkg','0.21.0','docsharp.binary.common.0.21.0.nupkg')]:
    archive=copy(filename);extra=copy(secondary) if secondary else '-'
    job=root/('HomeLibRu-update-'+id)
    run('--official-prepare',archive,job,id,version,extra,runtime)
    m=json.loads((job/'manifest.json').read_text(encoding='utf-8-sig'))
    assert m['component']==id and m['official'] and m['version']==version
    for f in m['files']:assert sha(job/'payload'/f['path'])==f['sha256']
    target=root/('target-'+id);target.mkdir()
    protected={'myhomelib2.ini':b'saved preferences','reader.ini':b'positions','reader-notes.json':b'personal notes',
               'Data/books.hlc2':b'catalog','Data/user.dbs2':b'ratings, groups and history',
               'Readers/AlReader/$savevtut.ini':b'external reader preferences','Readers/SumatraPDF/SumatraPDF-settings.txt':b'history',
               'HomeLibRu.exe':exe.read_bytes()}
    for n,b in protected.items():
        p=target/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
    originals={}
    for f in m['files']:
        p=target/f['path'];p.parent.mkdir(parents=True,exist_ok=True);b=b'old distribution '+f['path'].encode();p.write_bytes(b);originals[f['path']]=b
    run('--install',job,target,'1',expected=1)
    for n,b in originals.items():assert (target/n).read_bytes()==b,(id,'rollback',n)
    for n,b in protected.items():assert (target/n).read_bytes()==b,(id,'protected rollback',n)
    pass_(id+' interrupted install rolls every distribution file back without changing user data')
    # A rolled-back job is deliberately not reused: make a fresh verified job.
    fresh=root/('HomeLibRu-update-'+id+'-success');run('--official-prepare',archive,fresh,id,version,extra,runtime)
    run('--install',fresh,target)
    for f in m['files']:assert sha(target/f['path'])==f['sha256']
    for n,b in protected.items():assert (target/n).read_bytes()==b,(id,'protected install',n)
    pass_(id+' installs directly from its author archive; books, notes, settings and history are byte-identical')
    if id=='DocSharp':
        doc=fixtures.parent/'office-feedback-fixtures/styled-fixture.doc'
        assert doc.is_file(),'Real DOC fixture is required'
        if doc.is_file():
            original_doc_sha=sha(doc)
            baseline=root/'official-doc-baseline.docx'
            before=subprocess.run([str(runtime/'tools/doc/HomeLibDoc.exe'),str(doc),str(baseline)],capture_output=True,timeout=30,creationflags=0x08000000)
            assert before.returncode==0,(before.stdout,before.stderr)
            output=root/'official-doc-result.docx'
            r=subprocess.run([str(target/'tools/doc/HomeLibDoc.exe'),str(doc),str(output)],capture_output=True,timeout=30,creationflags=0x08000000)
            assert r.returncode==0,(r.stdout,r.stderr)
            import zipfile
            with zipfile.ZipFile(output) as z,zipfile.ZipFile(baseline) as bz:
                body=z.read('word/document.xml')
                assert len(body)>100 and body==bz.read('word/document.xml')
            assert sha(doc)==original_doc_sha
            pass_('official DocSharp retains real DOC structure exactly and preserves the original book')
        mismatch=root/'HomeLibRu-update-DOC-mismatch';run('--official-prepare',archive,mismatch,id,'0.22.0',extra,runtime,expected=1)
        absent=root/'HomeLibRu-update-DOC-incomplete';run('--official-prepare',archive,absent,id,version,'-',runtime,expected=1)
        pass_('incomplete or mismatched DocSharp pairs are rejected before installation')

# Probe failures must be nonzero, otherwise an incompatible decoder could
# pass the install gate despite a successful process launch.
for name in ('missing','incompatible','valid'):
    folder=root/('djvu-probe-'+name);folder.mkdir()
    shutil.copy2(runtime/'tools/djvu/HomeLibDjvu.exe',folder/'HomeLibDjvu.exe')
    if name=='incompatible':shutil.copy2(runtime/'tools/7zip/7z.dll',folder/'libdjvulibre.dll')
    if name=='valid':
        for dll in (runtime/'tools/djvu').glob('*.dll'):shutil.copy2(dll,folder/dll.name)
    result=subprocess.run([str(folder/'HomeLibDjvu.exe'),'--self-test'],capture_output=True,timeout=15,creationflags=0x08000000)
    assert result.returncode==(0 if name=='valid' else 1),(name,result.returncode,result.stderr)
pass_('DjVu ABI probe accepts its decoder and rejects missing or incompatible libraries')

wrong=copy('7zip-'+('x86' if arch=='x64' else 'x64')+'.exe')
run('--official-prepare',wrong,root/'HomeLibRu-update-wrong-arch','7-Zip','26.04','-',runtime,expected=1)
pass_('wrong-architecture official archive is rejected before installation')

manifest=runtime/'tools/fonts/manifest.json';cache=root/'font-cache'
run('--font-download',manifest,cache,'Noto Serif Armenian')
m=json.loads(manifest.read_text(encoding='utf-8-sig'));members=[f for f in m['files'] if f['path'].startswith('noto/NotoSerifArmenian-')]
assert len(members)>=2
for f in members:assert sha(cache/f['path'])==f['sha256']
assert (cache/'noto/NotoSerifArmenian-ready').read_text()=='f873d2b4ab19bbd1c854d7ff5a1be032451c9ee72ce2382f6f1da7104f666053'
state={f['path']:(sha(cache/f['path']),(cache/f['path']).stat().st_mtime_ns) for f in members}
run('--font-download',manifest,cache,'Noto Serif Armenian')
assert state=={f['path']:(sha(cache/f['path']),(cache/f['path']).stat().st_mtime_ns) for f in members}
pass_('language fonts download from pinned author URLs; reopening reuses exact cached files')
bad=root/'bad-font-manifest.json';bad.write_text(manifest.read_text(encoding='utf-8-sig').replace('raw.githubusercontent.com','evil.example'))
run('--font-download',bad,cache,'Noto Serif Armenian',expected=1)
run('--font-download',manifest,cache,'Noto Serif Armenian','cancel',expected=1)
assert state=={f['path']:(sha(cache/f['path']),(cache/f['path']).stat().st_mtime_ns) for f in members}
assert not list(cache.rglob('*.part'))
pass_('altered font manifest and cancellation preserve cached fonts without partial files')
print('PASS TOTAL',count,platform,'isolated fixtures:',root,flush=True)

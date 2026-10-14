"""Native bridge + private bundled Python, in an isolated target on TEMP."""
from pathlib import Path
import base64, hashlib, importlib.util, json, os, shutil, subprocess, sys, tempfile, time, zipfile
import xml.etree.ElementTree as ET

exe, runtime = (Path(p).resolve() for p in sys.argv[1:3])
repository = Path(__file__).resolve().parents[2]
root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-conversion-'))
app = root/'runtime'
shutil.copytree(runtime/'tools/kindle/python', app/'tools/kindle/python')
script = app/'tools/bookconvert/convert_book.py'; script.parent.mkdir(parents=True)
shutil.copy2(repository/'tools/bookconvert/convert_book.py',script)
fixture_module = repository/'tools/bookconvert/tests/test_conversion.py'
spec = importlib.util.spec_from_file_location('conversion_fixtures',fixture_module)
fixtures = importlib.util.module_from_spec(spec);spec.loader.exec_module(fixtures)
source = root/'source.fb2'; source.write_text(fixtures.FB2.replace('{image}',base64.b64encode(fixtures.PNG).decode()),encoding='utf-8')
target = root/'exports'; target.mkdir()
work = root/'temporary'; work.mkdir()
protected = {'reader.ini':b'positions', 'notes.json':b'thoughts', 'books.hlc2':b'catalog', 'settings.ini':b'preferences'}
for name,data in protected.items(): (target/name).write_bytes(data)

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(source, destination, option='', expected=0):
    before = digest(source); started=time.monotonic()
    result = subprocess.run([str(exe),'--convert',str(source),str(destination),str(work),str(app),option],
                            capture_output=True,timeout=60,creationflags=0x08000000)
    assert result.returncode==expected,(option,result.returncode,(result.stdout+result.stderr).decode('utf-8',errors='replace'))
    assert digest(source)==before
    assert not list(work.iterdir()),'Native bridge must clean its own work directory'
    assert not list(target.glob('*.homelib-new-*'))
    for name,data in protected.items(): assert (target/name).read_bytes()==data
    return round((time.monotonic()-started)*1000)

epub = target/'converted.epub'
forward_ms=run(source,epub,'--stream')
with zipfile.ZipFile(epub) as z:
    assert z.testzip() is None
    for name in z.namelist():
        if name.endswith(('.xhtml','.opf','.xml')): ET.fromstring(z.read(name))
back = target/'converted.fb2'; reverse_ms=run(epub,back,'--stream')
original, converted=ET.parse(source).getroot(),ET.parse(back).getroot()
for name in ('description','body','stylesheet'):
    assert [fixtures.shape(n) for n in fixtures.c.children(original,name)]==[fixtures.shape(n) for n in fixtures.c.children(converted,name)]
assert {n.get('id'):base64.b64decode(fixtures.c.plain(n)) for n in fixtures.c.children(converted,'binary')}=={'cover':fixtures.PNG,'unused':fixtures.PNG}
print('PASS native separate FB2→EPUB and EPUB→FB2 preserve caller stream position, chapters/notes/images/metadata/styles',forward_ms,reverse_ms,'ms',flush=True)

copied=target/'same-format.fb2'; run(source,copied); assert digest(copied)==digest(source)
existing=digest(epub); run(source,epub,expected=1); assert digest(epub)==existing
print('PASS same-format copy is exact; existing output is never replaced',flush=True)

canceled=target/'cancel.epub'; run(source,canceled,'--cancel',expected=1); assert not canceled.exists()
print('PASS cancellation after child start removes owned temporary files and preserves source/profile',flush=True)

invalid=root/'invalid.epub'; invalid.write_bytes(b'broken epub')
failed=target/'failed.fb2'; run(invalid,failed,expected=1); assert not failed.exists()
print('PASS malformed input reports a failure without a misleading output',flush=True)
report={'root':str(root),'native_sha256':digest(exe),'converter_sha256':digest(script),
        'forward_ms':forward_ms,'reverse_ms':reverse_ms,'protected_files':len(protected),'cases':5}
(root/'verification.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('PASS native converter:',root,flush=True)

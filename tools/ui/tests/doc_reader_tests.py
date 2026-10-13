"""Black-box bundled DOC reader checks; all inputs stay read-only."""
import argparse, hashlib, pathlib, subprocess, tempfile, zipfile
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser()
p.add_argument('component', type=pathlib.Path)
p.add_argument('fixtures', type=pathlib.Path)
p.add_argument('--keep', action='store_true')
a = p.parse_args()
tool = (a.component/'HomeLibDoc.exe').resolve()
fixtures = a.fixtures.resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-doc-')).resolve()
assert root.parent == pathlib.Path(tempfile.gettempdir()).resolve()
(root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
ns = {'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
def run(source, destination):
    return subprocess.run([str(tool),str(source),str(destination)], capture_output=True,
                          timeout=35, creationflags=subprocess.CREATE_NO_WINDOW)
def compact(text):
    return ''.join(ch for ch in text if not ch.isspace() and ord(ch)>=32)
sources = [fixtures/'under-dome.doc', fixtures/'styled-fixture.doc']
before = {s:hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
try:
    output = root/'Книга с пробелами — ё.docx'
    result = run(sources[0], output)
    assert result.returncode == 0, result.stderr.decode('utf-8-sig', errors='replace')
    with zipfile.ZipFile(output) as z:
        body = ET.fromstring(z.read('word/document.xml'))
        text = '\n'.join(''.join(t.text or '' for t in para.findall('.//w:t',ns))
                         for para in body.findall('.//w:body/w:p',ns))
        assert not any('vba' in n.lower() for n in z.namelist())
    assert compact(text) == compact((fixtures/'palynovy-expected.txt').read_text(encoding='utf-8'))
    print('PASS full real DOC body matches independent reference:',result.stdout.decode('utf-8-sig').strip(),flush=True)
    styled = root/'styled.docx'
    result = run(sources[1],styled); assert result.returncode == 0, result.stderr
    with zipfile.ZipFile(styled) as z:
        body = ET.fromstring(z.read('word/document.xml'))
        headings = [e.get('{'+ns['w']+'}val') for e in body.findall('.//w:pStyle',ns)]
        assert 'Heading1' in headings and 'Heading2' in headings
        assert len([n for n in z.namelist() if n.startswith('word/media/')]) == 1
        assert body.findall('.//w:b',ns) and body.findall('.//w:i',ns)
        assert 'Текст после картинки — конец.' in ''.join(t.text or '' for t in body.findall('.//w:t',ns))
    print('PASS DOC Unicode, heading hierarchy, emphasis and embedded PNG survive',flush=True)
    sentinel = root/'existing.docx'; sentinel.write_bytes(b'KEEP EXISTING FILE')
    assert run(sources[0],sentinel).returncode != 0 and sentinel.read_bytes()==b'KEEP EXISTING FILE'
    assert run(sources[0],sources[0]).returncode != 0
    for i,data in enumerate([b'',b'bad DOC'*100,b'\xd0\xcf\x11\xe0'+b'\0'*1024,sources[0].read_bytes()[:4096]]):
        damaged = root/f'damaged-{i}.doc'; damaged.write_bytes(data)
        target = root/f'damaged-{i}.docx'; result=run(damaged,target)
        assert result.returncode != 0 and not target.exists(), ('partial result published',i)
    assert before == {s:hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    print('PASS DOC rejects malformed/truncated input, keeps existing outputs and leaves originals unchanged',flush=True)
finally:
    if a.keep:
        print('RETAINED',root,flush=True)
    else:
        import shutil
        assert root.name.startswith('HomeLibRu-native-doc-') and (root/'native-regression.marker').is_file()
        shutil.rmtree(root)

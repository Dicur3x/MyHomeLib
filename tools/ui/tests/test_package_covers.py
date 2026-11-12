"""Exercise actual native package-cover extraction and catalogue previews on private copies."""
import posixpath, urllib.parse, xml.etree.ElementTree as ET
import argparse, base64, hashlib, json, os, shutil, struct, subprocess, tempfile, warnings, zipfile, zlib
from pathlib import Path

def png(width):
    def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,32,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\x22\x88\xcc'*width)*32))+chunk(b'IEND',b'')

def fixtures(root, official):
    root.mkdir(); cases=[]
    image=png(24); (root/'expected.png').write_bytes(image)
    def pack(name, entries, cover=True, expected='expected.png'):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(root/name,'w',compression=zipfile.ZIP_DEFLATED) as z:
                for n,b in entries: z.writestr(n,b)
        cases.append(dict(name=name,cover=cover,expected=expected))
    container='<container><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    def epub(name, metadata='', manifest='', guide='', extra=(), cover=True):
        pack(name,[('META-INF/container.xml',container),('OPS/package.opf','<package><metadata>'+metadata+'</metadata><manifest>'+manifest+'</manifest><guide>'+guide+'</guide></package>')]+list(extra),cover)
    meta='<meta name="cover" content="c"/>'; item='<item id="c" href="images/cover.png" media-type="image/png"/>'
    im=('OPS/images/cover.png',image)
    epub('epub2.epub',meta,item,extra=[im])
    epub('epub3.epub',manifest='<item id="c" href="images/cover.png" properties="nav&#x9;cover-image"/>',extra=[im])
    epub('relative.epub',meta,'<item id="c" href="../Images/a+b%20%D1%91.png#cover"/>',extra=[('Images/a+b ё.png',image)])
    epub('guide.epub',guide='<reference type="cover" href="cover.xhtml"/>',extra=[('OPS/cover.xhtml','<!DOCTYPE html><html><body><svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="images/cover.png"/></svg></body></html>'),im])
    epub('svg-wrapper.epub',meta,'<item id="c" href="cover.svg"/>',extra=[('OPS/cover.svg','<svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="images/cover.png"/></svg>'),im])
    epub('absent.epub',manifest=item,extra=[im],cover=False)
    epub('external.epub',meta,'<item id="c" href="https://invalid.test/image.png"/>',cover=False)
    epub('traversal.epub',meta,'<item id="c" href="../../outside.png"/>',extra=[('outside.png',image)],cover=False)
    epub('duplicate.epub',meta,item,extra=[im,im],cover=False)
    epub('oversize.epub',meta,item,extra=[(im[0],b'x'*(16*1024*1024+1))],cover=False)
    epub('entities.epub',guide='<reference type="cover" href="cover.xhtml"/>',extra=[('OPS/cover.xhtml','<!DOCTYPE html [<!ENTITY x SYSTEM "file:///C:/Windows/win.ini">]><html>&x;</html>')],cover=False)
    epub('vector.epub',meta,'<item id="c" href="cover.svg"/>',extra=[('OPS/cover.svg','<svg><rect width="10" height="10"/></svg>')],cover=False)
    epub('badcrc.epub',meta,item,extra=[im],cover=False)
    p=root/'badcrc.epub'; b=bytearray(p.read_bytes())
    with zipfile.ZipFile(p) as z:
        info=z.getinfo(im[0]); at=info.header_offset
        n,e=struct.unpack_from('<HH',b,at+26); b[at+30+n+e+3]^=0x80
    p.write_bytes(b)
    pack('large-metadata.epub',[('META-INF/container.xml',b'x'*(2*1024*1024+1))],False)
    rel='<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="t" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" Target="docProps/thumb.png"/></Relationships>'
    for ext in ('docx','docm','dotx','dotm','pptx','pptm','potx','potm','ppsx','ppsm','xlsx','xlsm','xlsb','xltx','xltm','fb3'):
        pack('word.'+ext,[('_rels/.rels',rel),('docProps/thumb.png',image)])
    for ext in ('odt','ott','odm','odp','otp','ods','ots','odg','otg','odf'):
        pack('open.'+ext,[('Thumbnails/thumbnail.png',image)])
    pack('root-relative.docx',[('_rels/.rels',rel.replace('Target="docProps','Target="/docProps')),('docProps/thumb.png',image)])
    pack('network.docx',[('_rels/.rels',rel.replace('Target="docProps','Target="//invalid.test/docProps'))],False)
    pack('word-missing.docx',[('_rels/.rels','<Relationships/>'),('word/media/image1.png',image)],False)
    pack('open-missing.odt',[('Pictures/image.png',image)],False)
    rel_ext=rel.replace('Target="docProps','TargetMode="External" Target="https://invalid.test/docProps')
    pack('external.docx',[('_rels/.rels',rel_ext)],False)
    with zipfile.ZipFile(root/'epub2.epub') as z: entries=[(n,z.read(n)) for n in z.namelist()]
    pack('second.epub',[(n,png(48) if n==im[0] else b) for n,b in entries],expected='second.png')
    (root/'second.png').write_bytes(png(48))
    pack('outer.zip',[('books/epub3.epub',(root/'epub3.epub').read_bytes())],False); cases.pop()
    (root/'original.fb2').write_text('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Original</book-title><coverpage><image l:href="#cover"/></coverpage></title-info></description><body><section><p>Text</p></section></body><binary id="cover" content-type="image/png">'+base64.b64encode(image).decode()+'</binary></FictionBook>',encoding='utf-8')
    if official:
        shutil.copy2(official,root/'official.fb3'); cases.append(dict(name='official.fb3',cover=False,expected=''))
    (root/'cases.json').write_text(json.dumps(cases,ensure_ascii=False),encoding='utf-8')
    return len(cases)

def main():
    p=argparse.ArgumentParser()
    for n in ('native','sqlite','icons','genres','result'): p.add_argument('--'+n,type=Path,required=True)
    p.add_argument('--modes',nargs='+',default=['package-covers','package-preview','book-preview','update-theme'])
    p.add_argument('--real',type=Path,action='append',default=[]); p.add_argument('--official',type=Path); p.add_argument('--tools',type=Path)
    a=p.parse_args(); machine=a.native.read_bytes(); logs={}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-covers-') as raw:
        root=Path(raw)/'HomeLibRu-native-cover'; root.mkdir()
        for src,dst in [(a.native,'CollectionViewsTest.exe'),(a.sqlite,'sqlite3.dll'),(a.genres,'genres_fb2.glst')]: shutil.copy2(src,root/dst)
        (root/'Icons').mkdir(); shutil.copy2(a.icons,root/'Icons/MHLIcons.dll')
        for n in ('uselocaldata','uselocaltemp'): (root/n).touch()
        (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
        count=fixtures(root/'cover-fixtures',a.official)
        cases=json.loads((root/'cover-fixtures/cases.json').read_text(encoding='utf-8'))
        real=[]; originals={}
        for i,src in enumerate(a.real):
            originals[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
            name=f'real-{i}.epub'; expected=f'real-{i}-cover.bin'
            shutil.copy2(src,root/'cover-fixtures'/name)
            with zipfile.ZipFile(src) as z:
                c=ET.fromstring(z.read('META-INF/container.xml'))
                opf=next(e.attrib['full-path'] for e in c.iter() if e.tag.endswith('rootfile'))
                d=ET.fromstring(z.read(opf))
                cover_id=next(e.attrib['content'] for e in d.iter() if e.attrib.get('name')=='cover')
                href=next(e.attrib['href'] for e in d.iter() if e.attrib.get('id')==cover_id)
                part=posixpath.normpath(posixpath.join(posixpath.dirname(opf),urllib.parse.unquote(href)))
                (root/'cover-fixtures'/expected).write_bytes(z.read(part))
            cases.append(dict(name=name,cover=True,expected=expected)); real.append(dict(name=name,expected=expected))
        (root/'cover-fixtures/cases.json').write_text(json.dumps(cases),encoding='utf-8')
        (root/'cover-fixtures/real-preview.json').write_text(json.dumps(real),encoding='utf-8')
        count=len(cases)
        if a.tools:
            (root/'tools').mkdir(); shutil.copytree(a.tools/'7zip',root/'tools/7zip')
            work=root/'cover-fixtures'/'seven'; (work/'books').mkdir(parents=True)
            shutil.copy2(root/'cover-fixtures/epub3.epub',work/'books/epub3.epub')
            result=subprocess.run([str(root/'tools/7zip/7za.exe'),'a','-t7z',str(root/'cover-fixtures/outer.7z'),'books/epub3.epub'],cwd=work,capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
            assert result.returncode==0,result.stdout
        hashes={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'cover-fixtures').iterdir() if x.is_file()}
        env=os.environ.copy(); env['LOCALAPPDATA']=str(root/'local')
        for mode in a.modes:
            r=subprocess.run([str(root/'CollectionViewsTest.exe')]+mode.split(),cwd=root,env=env,capture_output=True,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
            output=(r.stdout+r.stderr).decode('utf-8',errors='replace'); logs[mode]=output
            a.result.with_name(a.result.stem+'-'+mode+'.log').write_text(output,encoding='utf-8')
            assert r.returncode==0,(mode,r.returncode,output[-5000:])
        assert originals=={str(src):hashlib.sha256(src.read_bytes()).hexdigest() for src in a.real}
        assert hashes=={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'cover-fixtures').iterdir() if x.is_file()}
    report=dict(status='PASS',native_sha256=hashlib.sha256(machine).hexdigest(),package_cases=count if 'package-covers' in a.modes else 0,source_hashes_preserved=True,private_runtime_removed=not Path(raw).exists(),checks={k:v.count('PASS ') for k,v in logs.items()})
    a.result.write_text(json.dumps(report,indent=2),encoding='utf-8'); print(json.dumps(report))
if __name__=='__main__': main()

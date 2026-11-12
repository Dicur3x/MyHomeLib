"""Exercise actual native package-cover extraction and catalogue previews on private copies."""
import tarfile
import io, posixpath, urllib.parse, xml.etree.ElementTree as ET
import ctypes, ctypes.wintypes as wt
import argparse, base64, hashlib, json, os, shutil, struct, subprocess, tempfile, warnings, zipfile, zlib
from pathlib import Path

def png(width):
    def chunk(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,32,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\x22\x88\xcc'*width)*32))+chunk(b'IEND',b'')

def fixtures(root, official, modes):
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
    def descriptor(cover=False):
        return '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Wrapper</book-title>'+('<coverpage><image l:href="#cover"/></coverpage>' if cover else '')+'</title-info></description>'+('<binary id="cover" content-type="image/png">'+base64.b64encode(png(48)).decode()+'</binary>' if cover else '')+'</FictionBook>'
    for name,covered,first in [('fbd-covered.zip',True,False),('fbd-no-cover.zip',False,False),('fbd-descriptor-first.zip',False,True),('fbd-ambiguous.zip',False,False)]:
        with zipfile.ZipFile(root/name,'w',compression=zipfile.ZIP_DEFLATED) as z:
            if first: z.writestr('book.fbd',descriptor(covered))
            z.writestr('book.epub',(root/'epub2.epub').read_bytes())
            if not first: z.writestr('book.fbd',descriptor(covered))
            if name=='fbd-ambiguous.zip': z.writestr('other.epub',(root/'epub3.epub').read_bytes())
    with zipfile.ZipFile(root/'fbd-html.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr('book.fbd',descriptor(False)); z.writestr('book.html','<html><body><img src="images/page.png"/></body></html>'); z.writestr('images/page.png',image)
    if 'raster-preview' in modes:
        from PIL import Image
        raster=[]; color=(34,136,204)
        def entry(name,cover=True,width=24,height=32):
            raster.append(dict(name=name,cover=cover,width=width,height=height,color=color))
        for ext,fmt in [('png','PNG'),('jpg','JPEG'),('jpeg','JPEG'),('gif','GIF'),('bmp','BMP'),('tif','TIFF'),('tiff','TIFF')]:
            Image.new('RGB',(24,32),color).save(root/('image.'+ext),format=fmt); entry('image.'+ext)
        orient=Image.new('RGB',(24,32),color); orient.paste((255,0,0),(0,0,24,10)); orient.paste((0,255,0),(0,22,24,32)); orient.save(root/'orientation.png'); orient.close()
        entry('orientation.png'); raster[-1].update(top_color=[255,0,0],bottom_color=[0,255,0])
        shutil.copy2(root/'image.png',root/'sidecar-damaged.png'); (root/'sidecar-damaged.fbd').write_text('<broken',encoding='utf-8'); entry('sidecar-damaged.png')
        Image.new('RGB',(800,1200),color).save(root/'large.jpg',quality=95); entry('large.jpg',width=400,height=600)
        Image.new('RGB',(24,32),color).save(root/'multi.tiff',save_all=True,append_images=[Image.new('RGB',(48,64),'red')]); entry('multi.tiff')
        (root/'wrong-extension.jpg').write_bytes(image); entry('wrong-extension.jpg')
        (root/'damaged.png').write_bytes(b'not a valid image'); entry('damaged.png',False)
        # The second natural page and the Mac metadata are intentionally not a cover.
        red=io.BytesIO(); Image.new('RGB',(48,64),'red').save(red,format='PNG')
        with zipfile.ZipFile(root/'comic.cbz','w',compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr('__MACOSX/page0.png',red.getvalue()); z.writestr('pages/page10.png',red.getvalue())
            z.writestr('pages/page2.png',image); z.writestr('pages/page20.png',b'damaged later page')
            z.writestr('ComicInfo.xml','<ComicInfo><Title>Fixture</Title></ComicInfo>')
        entry('comic.cbz'); shutil.copy2(root/'comic.cbz',root/'comic.zip'); entry('comic.zip')
        with zipfile.ZipFile(root/'mixed.zip','w') as z:
            z.writestr('notes.rtf',b'{\\rtf1 Book text}'); z.writestr('page2.png',image)
        entry('mixed.zip',False)
        with zipfile.ZipFile(root/'empty.cbz','w') as z: z.writestr('notes.txt','no pages')
        entry('empty.cbz',False)
        with zipfile.ZipFile(root/'oversize.cbz','w',compression=zipfile.ZIP_DEFLATED) as z: z.writestr('page.png',b'x'*(32*1024*1024+1))
        entry('oversize.cbz',False)
        with zipfile.ZipFile(root/'empty-payload.zip','w') as z: z.writestr('books/empty.cbz',b'')
        entry('empty-payload.zip',False); raster[-1]['member']='books/empty.cbz'
        (root/'raster-cases.json').write_text(json.dumps(raster),encoding='utf-8')
    (root/'cases.json').write_text(json.dumps(cases,ensure_ascii=False),encoding='utf-8')
    return len(cases)

def main():
    p=argparse.ArgumentParser()
    for n in ('native','sqlite','icons','genres','result'): p.add_argument('--'+n,type=Path,required=True)
    p.add_argument('--large-raster',action='store_true')
    p.add_argument('--without-tools',action='store_true')
    p.add_argument('--djvu-dir',type=Path)
    p.add_argument('--full-7zip',type=Path)
    p.add_argument('--comic-real',type=Path)
    p.add_argument('--modes',nargs='+',default=['package-covers','package-preview','book-preview','update-theme'])
    p.add_argument('--real',type=Path,action='append',default=[])
    p.add_argument('--real-document',type=Path,action='append',default=[])
    p.add_argument('--official',type=Path); p.add_argument('--tools',type=Path)
    a=p.parse_args();
    if a.without_tools: a.tools=None
    machine=a.native.read_bytes(); logs={}; memory={}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-covers-') as raw:
        root=Path(raw)/'HomeLibRu-native-cover'; root.mkdir()
        for src,dst in [(a.native,'CollectionViewsTest.exe'),(a.sqlite,'sqlite3.dll'),(a.genres,'genres_fb2.glst')]: shutil.copy2(src,root/dst)
        (root/'Icons').mkdir(); shutil.copy2(a.icons,root/'Icons/MHLIcons.dll')
        for n in ('uselocaldata','uselocaltemp'): (root/n).touch()
        (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
        count=fixtures(root/'cover-fixtures',a.official,a.modes)
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
        for i,src in enumerate(a.real_document):
            originals[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
            name=f'real-document-{i}'+src.suffix.lower(); expected=f'real-document-{i}-thumbnail.bin'
            shutil.copy2(src,root/'cover-fixtures'/name)
            with zipfile.ZipFile(src) as z:
                part=None
                if 'Thumbnails/thumbnail.png' in z.namelist():
                    part='Thumbnails/thumbnail.png'
                elif '_rels/.rels' in z.namelist():
                    rels=ET.fromstring(z.read('_rels/.rels'))
                    matches=[e.attrib['Target'] for e in rels if e.attrib.get('Type','').endswith('/metadata/thumbnail') and e.attrib.get('TargetMode')!='External']
                    assert len(matches)<=1, 'Reference document has ambiguous thumbnails'
                    if matches: part=urllib.parse.unquote(matches[0]).lstrip('/')
                if part:
                    (root/'cover-fixtures'/expected).write_bytes(z.read(part))
                    real.append(dict(name=name,expected=expected))
                cases.append(dict(name=name,cover=part is not None,expected=expected))
        (root/'cover-fixtures/cases.json').write_text(json.dumps(cases),encoding='utf-8')
        (root/'cover-fixtures/real-preview.json').write_text(json.dumps(real),encoding='utf-8')
        count=len(cases)
        if a.large_raster and 'raster-preview' in a.modes:
            from PIL import Image
            im=Image.new('RGB',(4000,24000),(34,136,204)); im.save(root/'cover-fixtures/large-scan.png',compress_level=1); im.close()
            rp=root/'cover-fixtures/raster-cases.json'; rc=json.loads(rp.read_bytes())
            rc.append(dict(name='large-scan.png',cover=True,width=100,height=600,color=[34,136,204]))
            heavy=root/'cover-fixtures/heavy.cbz'
            with zipfile.ZipFile(heavy,'w',compression=zipfile.ZIP_STORED) as z:
                z.writestr('page.png',png(24))
                with z.open('padding.bin','w') as out:
                    for _ in range(1024): out.write(b'\0'*65536)
            with zipfile.ZipFile(root/'cover-fixtures/nested-heavy.zip','w',compression=zipfile.ZIP_DEFLATED) as z: z.write(heavy,'books/heavy.cbz')
            rc.append(dict(name='nested-heavy.zip',member='books/heavy.cbz',cover=True,width=24,height=32,color=[34,136,204]))
            rp.write_text(json.dumps(rc),encoding='utf-8')
        if a.comic_real and 'raster-preview' in a.modes:
            from PIL import Image
            import re
            src=a.comic_real; originals[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
            def eligible(n):
                return not n.endswith('/') and not n.replace('\\','/').startswith('__MACOSX/') and not posixpath.basename(n).startswith('._') and posixpath.splitext(n)[1].lower() in ('.png','.jpg','.jpeg','.gif','.bmp','.webp','.tif','.tiff')
            def natural(n): return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)',n)]
            if zipfile.is_zipfile(src):
                target='real-comic.cbz'; shutil.copy2(src,root/'cover-fixtures'/target)
                with zipfile.ZipFile(src) as z:
                    name=min((n for n in z.namelist() if eligible(n)),key=natural); data=z.read(name)
            else:
                assert a.full_7zip, 'A full 7-Zip directory is required to inspect the real RAR fixture'
                target='real-comic.cbr'; shutil.copy2(src,root/'cover-fixtures'/target)
                command=[str(a.full_7zip/'7z.exe')]
                listing=subprocess.check_output(command+['l','-slt','-sccUTF-8','--',str(src)],timeout=20,creationflags=subprocess.CREATE_NO_WINDOW).decode('utf-8')
                names=[line[7:] for line in listing.split('----------',1)[1].splitlines() if line.startswith('Path = ') and eligible(line[7:])]
                name=min(names,key=natural)
                data=subprocess.check_output(command+['x','-so','-y','-spd','-sccUTF-8','--',str(src),name],timeout=20,creationflags=subprocess.CREATE_NO_WINDOW)
                assert len(data)<=32*1024*1024
            with Image.open(io.BytesIO(data)) as im: w,h=im.size
            scale=min(1,600/max(w,h))
            rp=root/'cover-fixtures/raster-cases.json'; rc=json.loads(rp.read_bytes())
            rc.append(dict(name=target,cover=True,width=max(1,int(w*scale)),height=max(1,int(h*scale)),check_color=False))
            rp.write_text(json.dumps(rc),encoding='utf-8')
        if a.tools:
            (root/'tools').mkdir(); shutil.copytree(a.tools/'7zip',root/'tools/7zip')
            work=root/'cover-fixtures'/'seven'; (work/'books').mkdir(parents=True)
            shutil.copy2(root/'cover-fixtures/epub3.epub',work/'books/epub3.epub')
            result=subprocess.run([str(root/'tools/7zip/7za.exe'),'a','-t7z',str(root/'cover-fixtures/outer.7z'),'books/epub3.epub'],cwd=work,capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
            assert result.returncode==0,result.stdout
            if 'raster-preview' in a.modes:
                comicwork=root/'cover-fixtures'/'comic-seven'; comicwork.mkdir()
                with zipfile.ZipFile(root/'cover-fixtures/comic.cbz') as z: z.extractall(comicwork)
                for ext in ('cb7','7z'):
                    archive=root/'cover-fixtures'/('comic.'+ext)
                    r=subprocess.run([str(root/'tools/7zip/7za.exe'),'a','-t7z',str(archive),'.'],cwd=comicwork,capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
                    assert r.returncode==0,r.stdout
                rp=root/'cover-fixtures/raster-cases.json'; raster=json.loads(rp.read_bytes())
                raster.extend(dict(name='comic.'+ext,cover=True,width=24,height=32,color=[34,136,204]) for ext in ('cb7','7z'))
                rp.write_text(json.dumps(raster),encoding='utf-8')
        if a.djvu_dir and 'raster-preview' in a.modes:
            dest=root/'tools/djvu'; dest.mkdir(parents=True)
            manifest=json.loads((a.djvu_dir/'RUNTIME.json').read_bytes())['djvu']['files']
            for name,sha in manifest.items():
                assert hashlib.sha256((a.djvu_dir/name).read_bytes()).hexdigest()==sha
                shutil.copy2(a.djvu_dir/name,dest/name)
            shutil.copy2(a.djvu_dir/'HomeLibDjvu.exe',dest/'HomeLibDjvu.exe')
            source=a.djvu_dir/'djvulibre-3.5.29.tar.gz'; originals[str(source)]=hashlib.sha256(source.read_bytes()).hexdigest()
            rp=root/'cover-fixtures/raster-cases.json'; rc=json.loads(rp.read_bytes())
            with tarfile.open(source,'r:gz') as t:
                for member in ('doc/lizard2002.djvu','doc/lizard2007.djvu','doc/djvulibre-book-ru.djvu'):
                    entry=t.getmember('djvulibre-3.5.29/'+member); assert 0<entry.size<2*1024*1024
                    data=t.extractfile(entry).read(); target=root/'cover-fixtures'/('djvu-'+Path(member).name); target.write_bytes(data)
                    dims=subprocess.check_output([str(dest/'djvused.exe'),'-e','select 1; size',str(target)],timeout=10,creationflags=subprocess.CREATE_NO_WINDOW).decode('utf-8')
                    import re
                    w,h=map(int,re.findall(r'=(\d+)',dims)); scale=min(1,600/max(w,h))
                    rc.append(dict(name=target.name,cover=True,width=max(1,int(w*scale)),height=max(1,int(h*scale)),check_color=False,dimension_tolerance=1))
            (root/'cover-fixtures/damaged.djvu').write_bytes(b'AT&TFORM damaged source')
            rc.append(dict(name='damaged.djvu',cover=False))
            rp.write_text(json.dumps(rc),encoding='utf-8')
        if a.full_7zip:
            (root/'tools/7zip').mkdir(parents=True,exist_ok=True)
            for name in ('7z.exe','7z.dll'): shutil.copy2(a.full_7zip/name,root/'tools/7zip'/name)
        hashes={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'cover-fixtures').iterdir() if x.is_file()}
        env=os.environ.copy(); env['LOCALAPPDATA']=str(root/'local')
        for mode in a.modes:
            with subprocess.Popen([str(root/'CollectionViewsTest.exe')]+mode.split(),cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW) as r:
                try: stdout,stderr=r.communicate(timeout=90)
                except subprocess.TimeoutExpired:
                    r.kill(); stdout,stderr=r.communicate(); raise
                class Counters(ctypes.Structure):
                    _fields_=[('cb',wt.DWORD),('faults',wt.DWORD)]+[(n,ctypes.c_size_t) for n in ('peak_working','working','peak_paged','paged','peak_nonpaged','nonpaged','pagefile','peak_pagefile')]
                counters=Counters(); counters.cb=ctypes.sizeof(counters)
                if ctypes.windll.psapi.GetProcessMemoryInfo(wt.HANDLE(int(r._handle)),ctypes.byref(counters),counters.cb):
                    memory[mode]=dict(peak_working_set_bytes=counters.peak_working,peak_pagefile_bytes=counters.peak_pagefile)
                output=(stdout+stderr).decode('utf-8',errors='replace'); logs[mode]=output
            a.result.with_name(a.result.stem+'-'+mode+'.log').write_text(output,encoding='utf-8')
            assert r.returncode==0,(mode,r.returncode,output[-5000:])
            if mode=='raster-preview' and a.large_raster:
                assert memory[mode]['peak_working_set_bytes']<96*1024*1024, memory[mode]
        assert originals=={name:hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in originals}
        assert hashes=={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'cover-fixtures').iterdir() if x.is_file()}
    report=dict(status='PASS',native_sha256=hashlib.sha256(machine).hexdigest(),package_cases=count if 'package-covers' in a.modes else 0,source_hashes_preserved=True,private_runtime_removed=not Path(raw).exists(),memory=memory,original_source_sha256=originals,large_scan_dimensions=[4000,24000] if a.large_raster else None,checks={k:v.count('PASS ') for k,v in logs.items()})
    a.result.write_text(json.dumps(report,indent=2),encoding='utf-8'); print(json.dumps(report))
if __name__=='__main__': main()

"""Isolated reader checks. The optional real-formats case reads selected archives only."""
import argparse, pathlib, tempfile, shutil, hashlib, subprocess, zipfile, base64, os, json

p = argparse.ArgumentParser()
p.add_argument('runtime', type=pathlib.Path)
p.add_argument('exe', type=pathlib.Path)
p.add_argument('pdfium', type=pathlib.Path)
p.add_argument('--keep', action='store_true')
p.add_argument('--timeout', type=int, default=600)
p.add_argument('--books-root', type=pathlib.Path, help='Read-only archive directory for cases using selected real books')
p.add_argument('--headers-json', type=pathlib.Path, help='Selected format header inventory for real-formats')
p.add_argument('--raster-catalog', type=pathlib.Path, help='Selected DjVu/comic/TIFF archive inventory')
p.add_argument('--case', choices=('loading-navigation','loading-preferences','same-position-navigation','precision-wheel','document-spacing','pdf-current-page-search','oct10-reader','real-formats','raster-reader','release-pagination'))
a = p.parse_args()
if a.case in ('real-formats', 'raster-reader', 'release-pagination'):
    if a.books_root is None or not a.books_root.is_dir():
        p.error('--books-root must name the existing read-only archive directory')
    books_root = a.books_root.resolve()
    inventory = a.headers_json if a.case == 'real-formats' else a.raster_catalog
    if inventory is None or not inventory.is_file():
        p.error('--headers-json or --raster-catalog must name the matching selected fixture inventory')
runtime, exe, pdfium = a.runtime.resolve(), a.exe.resolve(), a.pdfium.resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-reader-')).resolve()
assert root.parent == pathlib.Path(tempfile.gettempdir()).resolve()
assert root.name.startswith('HomeLibRu-native-reader-')
try:
    shutil.copy2(exe, root/exe.name)
    shutil.copy2(pdfium, root/'pdfium.dll')
    for name in ('sqlite3.dll','libzstd.dll'):
        if (runtime/name).exists(): shutil.copy2(runtime/name, root/name)
    for file in runtime.glob('genres*.glst'):shutil.copy2(file,root/file.name)
    shutil.copy2(pathlib.Path(__file__).resolve().parents[3]/'Installer/Components.json',root/'COMPONENTS.json')
    for arch_dir in ('tools/webp','tools/7zip','tools/djvu'):
        if (runtime/arch_dir).exists(): shutil.copytree(runtime/arch_dir, root/arch_dir)
    for marker in ('uselocaldata','uselocaltemp'): (root/marker).write_text('')
    (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
    (root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\n[OPDS]\nEnabled=0\n',encoding='utf-8')
    if a.case=='real-formats':
        headers=a.headers_json
        rows=json.loads(headers.read_text(encoding='utf-8'))
        formats=root/'formats'; formats.mkdir()
        base=books_root
        chosen=[r for r in rows if r.get('status')=='read original header' and
                (r.get('signature') in ('MHTML','Windows Write') or
                 r.get('catalog_ext') in ('.fb','.original_fb2','.gdoc','.325949'))]
        assert len(chosen)>=8,'Expected original format examples missing'
        archives={}; stamps={}; evidence=[]
        try:
            for row in chosen:
                source=(base/row['archive']).resolve(); assert source.parent==base
                if source not in archives:
                    stamps[source]=(source.stat().st_size,source.stat().st_mtime_ns)
                    archives[source]=zipfile.ZipFile(source,'r')
                z=archives[source]; info=z.getinfo(row['actual_member'])
                assert info.file_size<64*1024*1024
                data=z.read(info)  # complete member CRC is checked by zipfile
                name=f"{row['book_id']}{row['catalog_ext']}"
                (formats/name).write_bytes(data)
                evidence.append({'archive':row['archive'],'member':row['actual_member'],'fixture':name,
                                 'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
        finally:
            for z in archives.values():z.close()
        assert all(stamp==(source.stat().st_size,source.stat().st_mtime_ns) for source,stamp in stamps.items())
        (root/'real-formats-evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    # An actual PNG from a generated RGB image, independent of personal files.
    import struct,zlib
    def chunk(tag,data): return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',160,100,8,2,0,0,0))
    pixels=b''.join(b'\0'+bytes([25,100+(y%80),180])*160 for y in range(100))
    png+=chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
    if a.case in ('raster-reader','release-pagination'):
        from PIL import Image
        import io
        pages=[Image.new('RGB',(400,600),color) for color in ('red','lime','blue')]
        pages[0].save(root/'page.png')
        pages[0].save(root/'pages.tiff',save_all=True,append_images=pages[1:],compression='tiff_deflate')
        with zipfile.ZipFile(root/'pages.cbz','w',zipfile.ZIP_DEFLATED) as z:
            for name,img in zip(('page1.png','page2.png','page10.png'),pages):
                stream=io.BytesIO(); img.save(stream,format='PNG'); z.writestr(name,stream.getvalue())
            z.writestr('__MACOSX/._page0.png',b'not an image')
        with zipfile.ZipFile(root/'broken-page.cbz','w',zipfile.ZIP_DEFLATED) as z:
            for name,img in (('1.png',pages[0]),('3.png',pages[2])):
                stream=io.BytesIO(); img.save(stream,format='PNG'); z.writestr(name,stream.getvalue())
            z.writestr('2.png',b'corrupt page')
        Image.new('RGB',(4001,4001),'red').save(root/'large-page.tiff',compression='tiff_deflate')
        arch=root/'comic-input'; arch.mkdir()
        for name,img in zip(('page1.png','page2.png','page10.png'),pages):img.save(arch/name)
        result=subprocess.run([str(root/'tools/7zip/7za.exe'),'a',str(root/'pages.cb7'),str(arch/'*.png'),'-t7z'],stdout=subprocess.PIPE,check=True)
        real=root/'raster-real'; real.mkdir()
        catalog=json.loads(a.raster_catalog.read_text(encoding='utf8'))[-1]
        selected={}
        for row in catalog['samples']:
            if row['ext'] in ('.cbr','.cbz','.djvu','.tiff') and row['ext'] not in selected:selected[row['ext']]=row
        evidence=[]
        for ext,row in selected.items():
            source=(books_root/row['folder']).resolve()
            assert source.parent==books_root
            if not source.exists():continue
            stamp=(source.stat().st_size,source.stat().st_mtime_ns)
            with zipfile.ZipFile(source,'r') as z:
                member=row['file_name']+ext
                if member not in z.namelist():continue
                info=z.getinfo(member); assert info.file_size<128*1024*1024
                data=z.read(info)
            assert stamp==(source.stat().st_size,source.stat().st_mtime_ns)
            fixture=real/(str(row['book_id'])+ext); fixture.write_bytes(data)
            evidence.append(dict(book_id=row['book_id'],archive=str(source),member=member,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
        assert any(x['member'].endswith('.djvu') for x in evidence),'No original DjVu fixture read'
        (root/'raster-real-evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf8')
    (root/'search.txt').write_text('Needle needle NEEDLE needled cat cathedral.',encoding='utf-8-sig')
    for filename,transfer in (('mime.mht','base64'),('mime-qp.mhtml','quoted-printable')):
        import quopri
        html='<html><body><h1>Русский текст</h1><img src="cid:cover"><p>Сохранённая книга</p><script>script-secret</script></body></html>'.encode('cp1251')
        payload=base64.b64encode(html) if transfer=='base64' else quopri.encodestring(html)
        mime=(b'MIME-Version: 1.0\r\nContent-Type: multipart/related;\r\n boundary="own-boundary"\r\n\r\n--own-boundary\r\n'
              b'Content-Type: text/html; charset="windows-1251"\r\nContent-Transfer-Encoding: '+transfer.encode()+b'\r\n\r\n'+payload+
              b'\r\n--own-boundary\r\nContent-Type: image/png\r\nContent-ID: <cover>\r\nContent-Transfer-Encoding: base64\r\n\r\n'+
              base64.b64encode(png)+b'\r\n--own-boundary--\r\n')
        (root/filename).write_bytes(mime)
    write_text='Текст Windows Write\r\nВторая строка.'.encode('cp1251')
    write_header=bytearray(128); write_header[:2]=b'\x31\xbe'; struct.pack_into('<I',write_header,14,128+len(write_text))
    (root/'write.wri').write_bytes(write_header+write_text)
    (root/'legacy.html').write_bytes('<html><meta charset="windows-1251"><body><h1>Русский HTML</h1><p>Текст<br>ещё текст<script>script-secret</script></body></html>'.encode('cp1251'))
    (root/'fake.pdf').write_text('This is not a PDF',encoding='ascii')
    with zipfile.ZipFile(root/'sample.fb3','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('fb3/body.xml','<fb3-body><section><title><p>Глава FB3</p></title><p>Текст FB3</p></section></fb3-body>')
    text='Это длинный абзац для проверки перелистывания. Русский текст сохраняет буквы, знаки и порядок. '*5
    paragraphs=''.join('<p>'+text+'</p>' for _ in range(80))
    fb2=('<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'
         '<description><title-info><book-title>Тестовая книга</book-title></title-info></description>'
         '<body><section><title><p>Первая глава</p></title><image l:href="#cover"/>'+paragraphs+
         '</section><section><title><p>Вторая глава</p></title><p>Текст второй главы</p>'+paragraphs+'</section></body>'
         '<binary id="cover" content-type="image/png">'+base64.b64encode(png).decode()+'</binary></FictionBook>')
    (root/'sample.fb2').write_text(fb2,encoding='utf-8')
    (root/'alias.fb').write_text(fb2,encoding='utf-8')
    # Lossless WebP with JPEG metadata, matching a PNG pixel for pixel.
    webp=base64.b64decode('UklGRiQAAABXRUJQVlA4TBcAAAAvn8AYAAdQt2aUtv9hABLC//9KRP9T5wA=')
    solid_png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',160,100,8,2,0,0,0))
    solid_png+=chunk(b'IDAT',zlib.compress(b''.join(b'\0'+bytes([25,110,180])*160 for _ in range(100))))+chunk(b'IEND',b'')
    (root/'sample-webp.fb2').write_text(fb2.replace(base64.b64encode(png).decode(),base64.b64encode(webp).decode()).replace('image/png','image/jpeg'),encoding='utf-8')
    (root/'sample-equivalent-png.fb2').write_text(fb2.replace(base64.b64encode(png).decode(),base64.b64encode(solid_png).decode()),encoding='utf-8')
    (root/'text-only.fb2').write_text(fb2.replace('<image l:href="#cover"/>','').replace('<binary id="cover" content-type="image/png">'+base64.b64encode(png).decode()+'</binary>',''),encoding='utf-8')
    tall=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',800,1800,8,2,0,0,0))
    tall+=chunk(b'IDAT',zlib.compress(b''.join(b'\0'+bytes([85,50+(y%80),190])*800 for y in range(1800))))+chunk(b'IEND',b'')
    (root/'large-image.fb2').write_text(fb2.replace(base64.b64encode(png).decode(),base64.b64encode(tall).decode()),encoding='utf-8')
    (root/'sample.txt').write_text('\n\n'.join(text for _ in range(180)),encoding='utf-8-sig')
    (root/'sample.rtf').write_text('{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Georgia;}}\\f0\\fs28 '+('A test paragraph with enough words for several pages. '*20+'\\par ')*80+'}',encoding='ascii')
    with zipfile.ZipFile(root/'sample.epub','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('mimetype','application/epub+zip')
        z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
        z.writestr('OPS/book.opf','<package><metadata><title>Тест EPUB</title></metadata><manifest><item id="first" href="z+chapter.xhtml"/><item id="second" href="a%20chapter.xhtml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>')
        z.writestr('OPS/z+chapter.xhtml','<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"><html><body><h1>Первая по spine</h1><p>Эмодзи: 🌍 &nbsp; &mdash;</p><img src="images/p+cover.png"/>'+paragraphs+'</body></html>')
        z.writestr('OPS/a chapter.xhtml','<html><body><h1>Вторая по spine</h1>'+paragraphs+'</body></html>')
        z.writestr('OPS/images/p+cover.png',png)
    # A permitted remote audio asset must not prevent offline local text reading.
    shutil.copy2(root/'sample.epub',root/'alias.epup')
    with zipfile.ZipFile(root/'sample.epub') as source, zipfile.ZipFile(root/'remote-assets.epub','w',zipfile.ZIP_DEFLATED) as z:
        for item in source.infolist():
            payload=source.read(item.filename)
            if item.filename=='OPS/book.opf':
                payload=payload.replace(b'</manifest>',b'<item id="audio" href="https://example.invalid/audio.mp3" media-type="audio/mpeg"/></manifest>')
            z.writestr(item.filename,payload)
    with zipfile.ZipFile(root/'sample.docx','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        z.writestr('word/_rels/document.xml.rels','<Relationships><Relationship Id="pic1" Target="media/p.png"/><Relationship Id="outside" Target="https://example.invalid/private.png" TargetMode="External"/></Relationships>')
        para=''.join('<w:p><w:r><w:t>'+text+'</w:t></w:r></w:p>' for _ in range(80))
        z.writestr('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>Первая глава</w:t></w:r></w:p><w:p><w:r><a:blip r:embed="pic1"/></w:r></w:p>'+para+'<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Вторая глава</w:t></w:r></w:p>'+para+'</w:body></w:document>')
        z.writestr('word/media/p.png',png)
    with zipfile.ZipFile(root/'sample.odt','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('mimetype','application/vnd.oasis.opendocument.text')
        z.writestr('content.xml','<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:xlink="http://www.w3.org/1999/xlink"><office:body><office:text><text:h>Первая глава</text:h><draw:frame><draw:image xlink:href="Pictures/p.png"/></draw:frame>'+paragraphs+'<text:h>Вторая глава</text:h>'+paragraphs+'</office:text></office:body></office:document-content>')
        z.writestr('Pictures/p.png',png)
    with zipfile.ZipFile(root/'spacing.odt','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('content.xml','<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>A<text:s text:c="3"/>B<text:tab/>C</text:p><text:p>D<text:s/>E</text:p></office:text></office:body></office:document-content>')
    with zipfile.ZipFile(root/'spacing.docx','w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t xml:space="preserve">A  B</w:t><w:tab/><w:t>C</w:t></w:r></w:p></w:body></w:document>')
    small=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',20,12,8,2,0,0,0))
    small+=chunk(b'IDAT',zlib.compress(b''.join(b'\0'+bytes([12,80,150])*20 for _ in range(12))))+chunk(b'IEND',b'')
    extra='<binary id="cover" content-type="image/png">'+base64.b64encode(small).decode()+'</binary>'
    (root/'duplicate-image.fb2').write_text(fb2.replace('</FictionBook>',extra+'</FictionBook>'),encoding='utf-8')
    (root/'missing-images.fb2').write_text(fb2.replace('<image l:href="#cover"/>','<image l:href="#absent"/>'*25),encoding='utf-8')
    # Minimal valid vector PDF with three visibly distinct pages.
    objects=['<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>','<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>']
    for n in range(3):
        content=f'{0.2+n*0.2} 0.4 0.8 rg 40 80 260 420 re f\n'.encode()
        if n==1: content+=b'BT /F1 18 Tf 50 550 Td (Needle on second page) Tj ET\n'
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Resources << /Font << /F1 9 0 R >> >> /Contents {4+n*2} 0 R >>')
        objects.append(f'<< /Length {len(content)} >>\nstream\n'+content.decode()+'endstream')
    objects.extend(['<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
                    '<< /Type /Outlines /First 11 0 R /Last 12 0 R /Count 2 >>',
                    '<< /Title (Start) /Parent 10 0 R /Next 12 0 R /Dest [3 0 R /Fit] >>',
                    '<< /Title (End) /Parent 10 0 R /Prev 11 0 R /Dest [7 0 R /Fit] >>'])
    data=b'%PDF-1.4\n'; offsets=[0]
    for i,obj in enumerate(objects,1): offsets.append(len(data));data+=f'{i} 0 obj\n{obj}\nendobj\n'.encode()
    start=len(data);data+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    data+=b''.join(f'{v:010} 00000 n \n'.encode() for v in offsets[1:])
    data+=f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    (root/'sample.pdf').write_bytes(data)
    (root/'numeric.325949').write_bytes(data)
    content=b'BT /F1 18 Tf 40 500 Td (Needle needle NEEDLE needled) Tj ET\n'
    objects=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
             '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
             f'<< /Length {len(content)} >>\nstream\n'+content.decode()+'endstream','<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    data=b'%PDF-1.4\n'; offsets=[0]
    for i,obj in enumerate(objects,1): offsets.append(len(data));data+=f'{i} 0 obj\n{obj}\nendobj\n'.encode()
    start=len(data);data+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    data+=b''.join(f'{v:010} 00000 n \n'.encode() for v in offsets[1:])
    data+=f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    (root/'search.pdf').write_bytes(data)
    (root/'broken.fb2').write_text('<FictionBook><body><p>broken</body>',encoding='utf-8')
    (root/'internal-dtd.fb2').write_text('<!DOCTYPE FictionBook [<!ENTITY value "external">]><FictionBook><body><p>&value;</p></body></FictionBook>',encoding='utf-8')
    (root/'empty.txt').write_bytes(b'\xef\xbb\xbf')
    (root/'cancel-large.txt').write_text('Отмена большой книги. '*60000,encoding='utf-8')
    (root/'broken.pdf').write_bytes(b'not a PDF')
    (root/'emoji.txt').write_text('Тест 🌍 😀',encoding='utf-8')
    (root/'rtf-escapes.txt').write_bytes('A\\{}\t\r\nПривет 🌍 \u0080\u8000\uffff'.encode('utf-8'))
    (root/'nospace.txt').write_text('漢字'*10000+'БЕЗПРОБЕЛОВКОНЕЦ',encoding='utf-8')
    (root/'nospace-emoji.txt').write_text('🌍'*10000+'БЕЗПРОБЕЛОВКОНЕЦ',encoding='utf-8')
    (root/'literal.xhtml').write_text('<html><body><p><![CDATA[Литерал &nbsp; &mdash;]]></p><p>Разрыв&nbsp;строки</p></body></html>',encoding='utf-8')
    (root/'literal-dtd.xhtml').write_text('<html><body><p><![CDATA[<!DOCTYPE html> обычный текст]]></p></body></html>',encoding='utf-8')
    (root/'encoding-attribute.xhtml').write_text('<html><body><p encoding="windows-1251">Русский текст с эмодзи 🌍</p></body></html>',encoding='utf-8')
    before={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in root.iterdir() if f.suffix in ('.fb2','.epub','.xhtml','.txt','.rtf','.docx','.odt','.pdf')}
    startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
    try:
        r=subprocess.run([str(root/exe.name)]+([a.case] if a.case else []),cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                         encoding='mbcs',errors='replace',timeout=a.timeout,startupinfo=startup)
    except subprocess.TimeoutExpired as error:
        output=error.stdout or ''
        print(output.decode('mbcs',errors='replace') if isinstance(output,bytes) else output,flush=True)
        raise
    print(r.stdout,flush=True)
    assert r.returncode==0 and 'PASS experimental built-in reader native regressions' in r.stdout
    if a.case=='oct10-reader':
        from PIL import Image, ImageChops
        before_image=Image.open(root/'oct10-pdf-before.bmp').convert('RGB')
        after_image=Image.open(root/'oct10-pdf-highlight.bmp').convert('RGB')
        marked=ImageChops.difference(before_image,after_image).getbbox()
        assert marked and marked[3]<after_image.height*0.35, 'PDF highlight moved away from the text near the top of the fixture'
        print('PASS PDF highlight pixels overlap the text region, not the mirrored page bottom',flush=True)
    assert before=={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in before}
    print('PASS isolated reader sources unchanged; no OPDS or personal database used',flush=True)
finally:
    if a.keep: print('RETAINED',root,flush=True)
    else: shutil.rmtree(root)

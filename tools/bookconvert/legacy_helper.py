#!/usr/bin/env python3
# GPL-3.0-only. Standalone read-only LIT/LRF adapter for HomeLib Ru.
# Uses the attributed calibre subset in vendor/calibre_legacy. It communicates
# with the MIT application only through an owned interchange ZIP.
import argparse
from copy import deepcopy
import html
import io
import json
from pathlib import Path
import posixpath
import re
import sys
import struct
from urllib.parse import unquote, urlsplit
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parent/'vendor'))
from calibre_legacy import xmlcompat as etree

MAX_FILE=64*1024*1024
MAX_TOTAL=256*1024*1024


class Log:
    def __init__(self): self.warnings=[]
    def warn(self,*values):
        message=' '.join(map(str,values))
        if any(word in message.lower() for word in ['decompression error','skipping chunk','damaged','invalid','corrupt']):
            raise ValueError(message)
        if message not in self.warnings and len(self.warnings)<30:self.warnings.append(message)


class BoundedInput:
    def __init__(self,stream):
        self.stream=stream;self.name=stream.name
        stream.seek(0,2);self.size=stream.tell();stream.seek(0)
        if not 0<self.size<=MAX_FILE:raise ValueError('Legacy input exceeds 64 MB or is empty')
    def read(self,size=-1):
        if size < -1 or size > MAX_FILE:raise ValueError('Invalid legacy input read')
        return self.stream.read(size)
    def seek(self,offset,whence=0):
        position=offset if whence==0 else self.tell()+offset if whence==1 else self.size+offset
        if not 0<=position<=self.size:raise ValueError('Invalid legacy input offset')
        return self.stream.seek(position)
    def tell(self):return self.stream.tell()


def safe_path(value):
    path=posixpath.normpath(unquote(value).replace('\\','/'))
    if path.startswith('/') or '..' in path.split('/') or ':' in path or '\0' in path:
        raise ValueError('Invalid legacy resource path')
    return path


def xml(data):
    if len(data)>MAX_FILE:raise ValueError('Legacy XML exceeds 64 MB')
    return etree.fromstring(data,etree.XMLParser(resolve_entities=False,no_network=True,huge_tree=True))


def empty_book(title=''):
    root=etree.Element('html');head=etree.SubElement(root,'head')
    etree.SubElement(head,'meta',charset='utf-8')
    etree.SubElement(head,'title').text=title
    return root,etree.SubElement(root,'body')


def lit(source,native,log):
    from calibre_legacy.native_api import configure
    from calibre_legacy.lit.reader import LitFile,UnBinary,OPF_MAP
    configure(native)
    resources={};sections=[];metadata={};total=0
    with source.open('rb') as stream:
        book=LitFile(BoundedInput(stream),log)
        if len(book.manifest)>20000:raise ValueError('Excessive LIT manifest')
        entries={safe_path(entry.path):entry for entry in book.manifest.values()}
        # The metadata comes from the same file. Parse without external DTDs.
        try:
            opf=UnBinary(book.get_file('/meta'),book.opf_path,book.manifest,map=OPF_MAP).raw
            tree=xml(opf)
            for field in ['title','creator','language']:
                found=tree.xpath('//*[local-name()=$name]',name=field)
                if found:metadata[field]=''.join(found[0].itertext()).strip()
        except (etree.XMLSyntaxError,ValueError):
            log.warn('LIT: часть старых метаданных не удалось разобрать; текст читается отдельно.')
        html_paths={path for path,entry in entries.items() if entry.state in ('spine','not spine') and
                    ('html' in str(entry.mime_type) or 'oeb1-document' in str(entry.mime_type))}
        prefixes={path:'lit-'+str(index) for index,path in enumerate(entries) if path in html_paths}
        for path,entry in entries.items():
            data=book.get_file('/data/'+entry.internal+'/content');total+=len(data)
            if total>MAX_TOTAL:raise ValueError('Decoded LIT exceeds 256 MB')
            if path in html_paths:
                converted=UnBinary(data,path,book.manifest,atoms=book.get_atoms(entry)).raw
                sections.append((path,converted))
            else:resources[path]=data
    root,body=empty_book(metadata.get('title',''))
    assets={};asset_names={}
    parser=etree.HTMLParser(no_network=True)
    for path,data in sections:
        document=etree.fromstring(data,parser)
        title=document.find('./head/title')
        if not metadata.get('title') and title is not None:metadata['title']=''.join(title.itertext())
        content=document.find('body')
        if content is None:raise ValueError('LIT section has no body')
        section=etree.SubElement(body,'section',id=prefixes[path]);section.text=content.text
        for child in content:section.append(deepcopy(child))
        for node in section.iter():
            if node is not section and node.get('id'):node.set('id',prefixes[path]+'-'+node.get('id'))
            if node.tag=='img':
                ref=node.get('src','');parts=urlsplit(ref)
                target=safe_path(posixpath.join(posixpath.dirname(path),parts.path))
                if parts.scheme or target not in resources:
                    node.tag='span';node.attrib.clear();node.text='[В исходном LIT отсутствует изображение: '+ref[:160]+']'
                    log.warn('В исходном LIT отсутствует изображение: '+ref[:160])
                else:
                    if target not in asset_names:
                        asset_names[target]='assets/'+str(len(asset_names))+'.bin';assets[asset_names[target]]=resources[target]
                    node.set('src',asset_names[target])
            href=node.get('href')
            if href is not None:
                parts=urlsplit(href)
                if not parts.scheme:
                    target=safe_path(posixpath.join(posixpath.dirname(path),parts.path)) if parts.path else path
                    if target in prefixes:
                        node.set('href','#'+prefixes[target]+('-'+unquote(parts.fragment) if parts.fragment else ''))
                    else:
                        node.attrib.pop('href');log.warn('Служебная ссылка LIT не имеет текстового раздела: '+href[:120])
    if not sections:raise ValueError('LIT has no readable text sections')
    log.warn('LIT: текст, изображения и ссылки перенесены; старое страничное оформление и шрифты упрощены.')
    return root,assets,metadata


def lrf(source,log):
    from calibre_legacy.lrf.document import LRFDocument
    from calibre_legacy.lrf.render import Styles,TextBlock
    with source.open('rb') as stream:
        book=LRFDocument(BoundedInput(stream));book.parse()
        tree=xml(book.to_xml(write_files=False).encode('utf-8'))
        resources={image.file:bytes(image.stream) for image in book.image_map.values()}
        if sum(map(len,resources.values()))>MAX_TOTAL:raise ValueError('LRF images exceed 256 MB')
    objects={node.get('objid'):node for node in tree.iter() if node.get('objid')}
    styles=Styles()
    for node in tree.findall('./Style/TextStyle'):
        index=styles.get_text_styles(node)
        if index is not None:styles.text_style_map[node.get('objid')]=index
    for node in tree.findall('./Style/BlockStyle'):styles.block_style_map[node.get('objid')]=styles.get_block_styles(node)
    buttons={}
    for node in tree.findall('.//Button'):
        target=node.find('.//JumpTo')
        if target is not None:buttons[node.get('objid')]='#lrf-'+target.get('refobj',target.get('refpage',''))
    images={node.get('objid'):objects.get(node.get('refstream')) for node in tree.findall('.//Image')}
    plot_map={key:node.get('file') for key,node in images.items() if node is not None}

    class PreserveText(TextBlock):
        def process_child(self,child):
            known={'CR','P','Span','EmpLine','NoBR','Sup','Sub','Italic','CharButton','Plot'}
            if child.tag in known:return super().process_child(child)
            # Ruby and rare typography still contain text; keep it explicitly.
            log.warn('LRF: упрощён текстовый элемент '+str(child.tag))
            self.process_container(child,etree.Element('span'))

    renderer=PreserveText(styles,buttons,plot_map,log)
    title=html.unescape(book.title);root,body=empty_book(title)
    rendered=set();headings={node.get('refobj'):''.join(node.itertext()) for node in tree.findall('.//TocLabel')}
    def render(node,parent,active=()):
        oid=node.get('objid')
        if len(active)>64 or oid and oid in active:raise ValueError('Cyclic LRF layout reference')
        next_active=active+(oid,) if oid else active
        if node.tag in ('ImageBlock','Image'):
            resource=objects.get(node.get('refstream'))
            if resource is None:raise ValueError('LRF image stream is missing')
            etree.SubElement(parent,'img',src=resource.get('file',''))
        elif node.tag=='TextBlock':
            block=etree.SubElement(parent,'div');renderer.render_block(etree.clone(node),block)
            for item in block.iter():
                if item.get('id'):item.set('id','lrf-'+item.get('id'))
            label=headings.get(oid)
            if label:
                first=next((child for child in block.iter() if child is not block and ''.join(child.itertext()).strip()),None)
                if first is not None and ''.join(first.itertext()).strip()==label.strip():first.tag='h2'
                else:
                    heading=etree.Element('h2');heading.text=label;block.insert(0,heading)
        elif node.tag=='PutObj':
            target=objects.get(node.get('refobj'))
            if target is None:raise ValueError('LRF layout object is missing')
            render(target,parent,next_active)
        elif node.tag in ('Main','Page','PageTree','Canvas','Header','Footer'):
            section=etree.SubElement(parent,'section') if node.tag=='Page' else parent
            if oid and oid not in rendered:section.set('id','lrf-'+oid);rendered.add(oid)
            for child in node:render(child,section,next_active)
        elif node.tag in ('RuledLine','PageDiv'):etree.SubElement(parent,'hr')
        elif node.tag in ('Locate','BlockSpace','Wait'):pass
        else:
            if ''.join(node.itertext()).strip():raise ValueError('Unhandled LRF content block: '+node.tag)
    main=tree.find('Main')
    if main is None:raise ValueError('LRF has no main page tree')
    render(main,body)
    for node in body.iter():
        css=[]
        for name in node.get('class','').split():
            if name.startswith('ts') and name[2:].isdigit():css.append(styles.text_styles[int(name[2:])])
            elif name.startswith('bs') and name[2:].isdigit():css.append(styles.block_styles[int(name[2:])])
        if css:node.set('style',';'.join(key+':'+str(value) for group in css for key,value in group.items()))
        node.attrib.pop('class',None)
    log.warn('LRF: порядок страниц, текст и иллюстрации сохранены; оформление адаптировано для электронной книги.')
    return root,resources,{'title':title,'creator':html.unescape(book.author),'language':html.unescape(book.language)}


def rb(source,log):
    # Rocket eBook layout adapted from calibre/ebooks/rb/reader.py (GPLv3),
    # Copyright 2009 John Schember. Keep entries in memory and bound every chunk.
    from calibre_legacy.compat import bounded_zlib
    data=source.read_bytes()
    if len(data)<32 or data[:14]!=b'\xb0\x0c\xb0\x0c\x02\x00NUVO\x00\x00\x00\x00':raise ValueError('Invalid Rocket eBook header')
    toc,size=struct.unpack_from('<II',data,24)
    if size!=len(data) or not 32<=toc<=len(data)-4:raise ValueError('Invalid Rocket eBook size')
    count=struct.unpack_from('<I',data,toc)[0]
    if not 0<count<=20000 or toc+4+44*count>len(data):raise ValueError('Invalid Rocket eBook index')
    resources={};sections=[];total=0
    for index in range(count):
        at=toc+4+44*index;name=safe_path(data[at:at+32].split(b'\0',1)[0].decode('utf-8'))
        length,offset,flags=struct.unpack_from('<III',data,at+32)
        if offset<32 or offset+length>len(data):raise ValueError('Invalid Rocket eBook entry bounds')
        payload=data[offset:offset+length]
        if name.lower().endswith(('.html','.htm')):
            if flags in (1,2):raise ValueError('Rocket eBook text uses unsupported protection')
            if flags==8:
                if len(payload)<8:raise ValueError('Incomplete Rocket eBook compression header')
                chunks,declared=struct.unpack_from('<II',payload)
                if not 0<chunks<=20000 or 8+4*chunks>len(payload) or declared>MAX_FILE:raise ValueError('Invalid Rocket eBook chunk index')
                sizes=struct.unpack_from('<'+'I'*chunks,payload,8);position=8+4*chunks;parts=[];decoded=0
                for size in sizes:
                    if position+size>len(payload):raise ValueError('Incomplete Rocket eBook chunk')
                    chunk=bounded_zlib.decompress(payload[position:position+size]);position+=size;decoded+=len(chunk)
                    if decoded>MAX_FILE:raise ValueError('Rocket eBook text exceeds 64 MB')
                    parts.append(chunk)
                if decoded!=declared or position!=len(payload):raise ValueError('Rocket eBook decoded size differs')
                payload=b''.join(parts)
            elif flags!=0:raise ValueError('Unknown Rocket eBook text encoding')
            sections.append((name,payload))
        elif flags==0:resources[name]=payload
        total+=len(payload)
        if total>MAX_TOTAL:raise ValueError('Rocket eBook exceeds decoded limit')
    if not sections:raise ValueError('Rocket eBook has no readable text')
    root,body=empty_book();assets={};prefixes={name:'rb-'+str(i) for i,(name,_) in enumerate(sections)}
    for name,payload in sections:
        document=etree.fromstring(payload,etree.HTMLParser(no_network=True));content=document.find('body')
        if content is None:raise ValueError('Rocket eBook has no text body')
        section=etree.SubElement(body,'section',id=prefixes[name]);section.text=content.text
        for child in list(content):section.append(child)
        for node in section.iter():
            if node is not section and node.get('id'):node.set('id',prefixes[name]+'-'+node.get('id'))
            if node.tag=='img':
                parts=urlsplit(node.get('src',''));target=safe_path(posixpath.join(posixpath.dirname(name),parts.path))
                if parts.scheme or target not in resources:raise ValueError('Rocket eBook image is missing')
                alias='assets/'+str(len(assets))+'.bin';assets[alias]=resources[target];node.set('src',alias)
            href=node.get('href')
            if href is not None:
                parts=urlsplit(href)
                if not parts.scheme:
                    target=safe_path(posixpath.join(posixpath.dirname(name),parts.path)) if parts.path else name
                    if target not in prefixes:raise ValueError('Rocket eBook link target is missing')
                    node.set('href','#'+prefixes[target]+('-'+unquote(parts.fragment) if parts.fragment else ''))
    log.warn('Rocket eBook: текст, ссылки и изображения перенесены; старые шрифты и страничная вёрстка адаптированы.')
    return root,assets,{}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--native-library',type=Path)
    parser.add_argument('--kindle',action='store_true')
    options=parser.parse_args();source=options.source.resolve();output=options.output.resolve()
    if output.exists():raise ValueError('Output already exists')
    if not 0<source.stat().st_size<=MAX_FILE:raise ValueError('Legacy input exceeds 64 MB or is empty')
    with source.open('rb') as stream:prefix=stream.read(8)
    if options.kindle:
        from calibre_legacy.native_api import select
        from calibre_legacy.palm_crypto import decode
        select(options.native_library)
        data=decode(source.read_bytes())
        try:
            with output.open('xb') as stream:stream.write(data)
        except BaseException:
            output.unlink(missing_ok=True);raise
        print('OK container-key Kindle preparation')
        return
    log=Log()
    if prefix==b'ITOLITLS':root,assets,metadata=lit(source,options.native_library,log)
    elif prefix==b'L\0R\0F\0\0\0':root,assets,metadata=lrf(source,log)
    elif prefix.startswith(b'\xb0\x0c\xb0\x0c'):root,assets,metadata=rb(source,log)
    else:raise ValueError('Not a LIT or LRF book')
    identifiers=set()
    for node in root.iter():
        if node.get('id'):
            if node.get('id') in identifiers:node.attrib.pop('id')
            else:identifiers.add(node.get('id'))
    for node in root.iter():
        href=node.get('href','')
        if href.startswith('#') and unquote(href[1:]) not in identifiers:
            node.attrib.pop('href');log.warn('Некоторые ссылки исходной книги не имеют существующей цели.')
        if node.tag=='img' and node.get('src','') not in assets:raise ValueError('Decoded legacy image is missing')
    content=etree.tostring(root,encoding='utf-8',method='html')
    if len(content)>MAX_FILE or len(assets)>20000 or sum(map(len,assets.values()))>MAX_TOTAL:
        raise ValueError('Decoded legacy book exceeds limits')
    if not ''.join(root.find('body').itertext()).strip() and not assets:raise ValueError('Legacy book is empty')
    metadata['warnings']=log.warnings
    try:
        with zipfile.ZipFile(output,'x',zipfile.ZIP_DEFLATED) as package:
            package.writestr('book.html',content)
            package.writestr('metadata.json',json.dumps(metadata,ensure_ascii=False))
            for name,data in assets.items():package.writestr(safe_path(name),data)
    except BaseException:
        output.unlink(missing_ok=True);raise
    print('OK legacy book text, images and local links')


if __name__=='__main__':main()

"""Bounded native MOBI/KF8 metadata reads and actual catalogue covers on G:."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib


def image(color=(32,80,176)):
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',24,32,8,2,0,0,0))+
        chunk(b'IDAT',zlib.compress((b'\0'+bytes(color)*24)*32))+chunk(b'IEND',b''))


def header(entries=(),first=2,version=6,text_records=1,exth=True):
    result=bytearray(248)
    struct.pack_into('>HHIHHHH',result,0,1,0,100,text_records,4096,0,0)
    result[16:20]=b'MOBI';struct.pack_into('>I',result,20,232)
    struct.pack_into('>I',result,36,version);struct.pack_into('>I',result,108,first)
    if exth:
        struct.pack_into('>I',result,128,64)
        items=b''
        for key,value in entries:
            raw=value.to_bytes(4,'big') if isinstance(value,int) else value
            items+=struct.pack('>II',key,len(raw)+8)+raw
        result+=b'EXTH'+struct.pack('>II',12+len(items),len(entries))+items
    return bytes(result)


def palm(parts):
    result=bytearray(78);result[:8]=b'Fixture\0';result[60:68]=b'BOOKMOBI'
    struct.pack_into('>H',result,76,len(parts));offset=78+8*len(parts)+2;offsets=[]
    for index,part in enumerate(parts):
        offsets.append(offset);result+=struct.pack('>II',offset,index+1);offset+=len(part)
    return bytes(result)+b'\0\0'+b''.join(parts),offsets


def fixtures(root,real=()):
    root.mkdir();cases=[];blue=image();red=image((176,48,32))
    (root/'blue.png').write_bytes(blue);(root/'red.png').write_bytes(red)
    def add(name,data,cover=False,expected='blue.png',forbidden=(),**extra):
        (root/name).write_bytes(data)
        cases.append(dict(name=name,cover=cover,expected=expected,forbidden=list(forbidden),**extra))
    def ordinary(name,entries=((201,1),),cover=True,first=2,**options):
        text=b'TEXT-RECORD-DO-NOT-READ\n'*100
        data,offsets=palm([header(entries,first=first,**options),text,red,blue])
        add(name,data,cover,forbidden=[(offsets[1],offsets[2])],max_read=2048)
        return data,offsets
    base,offsets=ordinary('declared.mobi')
    ordinary('kf8.azw3',version=8)
    ordinary('default-first-resource.azw',first=0xffffffff)
    ordinary('compact-index.prc',entries=[(201,b'\1')])
    ordinary('thumbnail-only.mobi',entries=[(202,b'\0\1')])
    cases[-1]['status']='Миниатюра'
    ordinary('cover-before-thumbnail.mobi',entries=[(202,0),(201,1)])
    ordinary('absent-cover.mobi',entries=[],cover=False)
    ordinary('absent-exth.mobi',exth=False,cover=False)
    ordinary('sentinel-cover.mobi',entries=[(201,0xffffffff)],cover=False)
    ordinary('sentinel-then-thumbnail.mobi',entries=[(201,0xffffffff),(202,1)])
    ordinary('unknown-metadata.mobi',entries=[(100,b'Ignored UTF-8 title'),(999,b'<!ENTITY x SYSTEM "file:///never">'),(201,1)])
    ordinary('duplicate-cover.mobi',entries=[(201,1),(201,1)],cover=False)
    ordinary('duplicate-thumbnail.mobi',entries=[(202,1),(202,0)],cover=False)
    ordinary('bad-cover-does-not-use-thumbnail.mobi',entries=[(201,100),(202,1)],cover=False)
    ordinary('bad-index.mobi',entries=[(201,0xfffffffe)],cover=False)
    ordinary('zero-resource.mobi',first=0,cover=False)
    ordinary('cover-points-to-text.mobi',first=1,entries=[(201,0)],cover=False)
    ordinary('boundary-points-to-text.mobi',entries=[(121,2)],cover=False)
    ordinary('future-version.azw3',version=9,cover=False)
    ordinary('invalid-number-size.mobi',entries=[(201,b'123')],cover=False)
    ordinary('cancel.mobi');cases[-1]['cancel']=True
    data,parts=palm([header([(201,0)]),b'text',blue+b'\0'*(2*1024*1024)])
    add('cancel-during-cover.mobi',data,cancel=True,cancel_bytes=65536,max_read=100000,
        forbidden=[(parts[1],parts[2])])
    for name,at,value in [('bad-header-size',offsets[0]+20,0xffffffff),
            ('bad-exth-size',offsets[0]+248+4,0xffffffff),
            ('bad-exth-count',offsets[0]+248+8,0xffffffff),
            ('short-exth-record',offsets[0]+248+16,7),
            ('bad-table-offset',78,1),('duplicate-table-offset',86,offsets[0]),
            ('table-past-eof',78,len(base)),('next-record-list',72,100)]:
        data=bytearray(base);struct.pack_into('>I',data,at,value);add(name+'.mobi',data)
    data=bytearray(base);struct.pack_into('>H',data,76,65535);add('truncated-record-table.mobi',data)
    data=bytearray(base);struct.pack_into('>H',data,76,0);add('empty-record-table.mobi',data)
    data=bytearray(base);data[60:68]=b'TEXtREAd';add('palmdoc-no-cover.pdb',data)
    add('not-palm.azw',b'not a Kindle file')
    combo,parts=palm([header([(121,3)]),b'first text',b'BOUNDARY',
        header([(201,0)],version=8),b'second text',blue])
    add('combined-kf8.mobi',combo,True,forbidden=[(parts[1],parts[2]),(parts[4],parts[5])],max_read=4096)
    data=bytearray(combo);data[parts[2]]=0;add('forged-kf8-boundary.mobi',data)
    data,_=palm([header([(201,0)]),b'text',b'x'*(16*1024*1024+1)])
    add('oversize-cover.mobi',data,max_read=2048)
    large,parts=palm([header([(201,1)]),b'text'*1024*1024,red,blue])
    add('large-text.mobi',large,True,forbidden=[(parts[1],parts[2])],max_read=2048)
    real_rows=[]
    for index,source in enumerate(real):
        source=Path(source);name='real-'+str(index)+source.suffix.lower();shutil.copyfile(source,root/name)
        with source.open('rb') as stream:
            h=stream.read(78);n=struct.unpack_from('>H',h,76)[0];table=stream.read(8*n)
            off=[struct.unpack_from('>I',table,i*8)[0] for i in range(n)]+[source.stat().st_size]
            stream.seek(off[0]);h=stream.read(off[1]-off[0]);begin=struct.unpack_from('>I',h,20)[0]+16
            count=struct.unpack_from('>I',h,begin+8)[0];at=begin+12;meta={}
            for _ in range(count):
                key,size=struct.unpack_from('>II',h,at)
                if key in (201,202):meta[key]=int.from_bytes(h[at+8:at+size],'big')
                at+=size
            record=struct.unpack_from('>I',h,108)[0]+meta[201];stream.seek(off[record]);cover=stream.read(off[record+1]-off[record])
            text_count=struct.unpack_from('>H',h,8)[0]
        expected='real-'+str(index)+'.bin';(root/expected).write_bytes(cover)
        cases.append(dict(name=name,cover=True,expected=expected,forbidden=[(off[1],off[text_count+1])],max_read=len(cover)+len(h)+len(table)+1024))
        real_rows.append(dict(source=str(source),sha256=sha(source),cover_sha256=hashlib.sha256(cover).hexdigest(),bytes=len(cover),cover_record=record))
    (root/'kindle-cases.json').write_text(json.dumps(cases),encoding='utf-8')
    return cases,real_rows


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    p=argparse.ArgumentParser();p.add_argument('--native',type=Path,required=True)
    p.add_argument('--result',type=Path,required=True);p.add_argument('--real',type=Path,action='append',default=[])
    a=p.parse_args();base=Path(os.environ['TEMP']).resolve()
    assert base.is_relative_to(Path('G:/HL-b14-external').resolve())
    before={str(s):sha(s) for s in a.real}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-native-',dir=base) as folder:
        root=Path(folder);shutil.copyfile(a.native,root/'KindleCoverTest.exe')
        for name in ['uselocaldata','uselocaltemp']:(root/name).touch()
        (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
        cases,real=fixtures(root/'cover-fixtures',a.real)
        expected={str(f.relative_to(root)):sha(f) for f in (root/'cover-fixtures').iterdir()}
        process=subprocess.run([str(root/'KindleCoverTest.exe')],cwd=root,timeout=45,capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
        a.result.with_suffix('.log').write_bytes(process.stdout+process.stderr)
        assert process.returncode==0,(process.returncode,(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        result=json.loads((root/'kindle-result.json').read_text(encoding='utf-8-sig'))
        assert len(result['cases'])==len(cases) and result['status']=='PASS'
        assert expected=={str(f.relative_to(root)):sha(f) for f in (root/'cover-fixtures').iterdir()}
    assert before=={str(s):sha(s) for s in a.real}
    result.update(native_sha256=sha(a.native),real=real,originals_unchanged=True,private_runtime_removed=not root.exists())
    a.result.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps(dict(status='PASS',cases=len(cases),real=len(real),private_runtime_removed=result['private_runtime_removed'])))


if __name__=='__main__':main()

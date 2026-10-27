"""Lossless TIFF/JPEG strip joining (TIFF Technical Note 2), MIT.

Only baseline, interleaved, identical-table strips without restart markers are
joined. Other valid TIFF layouts use the Windows image decoder instead. No JPEG
coefficients are decoded or recompressed, so large photographic books stay small.
"""
from pathlib import Path
import struct


class Unsupported(Exception):
    pass


def jpeg_parts(data):
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
        raise ValueError('Неполный JPEG внутри TIFF.')
    at=2; parts=[]
    while at<len(data)-2:
        if data[at]!=255:raise ValueError('Неверный маркер JPEG внутри TIFF.')
        while at<len(data) and data[at]==255:at+=1
        if at+3>len(data):raise ValueError('Обрезанный заголовок JPEG внутри TIFF.')
        marker=data[at];size=int.from_bytes(data[at+1:at+3],'big');at+=1
        if size<2 or at+size>len(data)-2:raise ValueError('Обрезанный сегмент JPEG внутри TIFF.')
        segment=b'\xff'+bytes([marker])+data[at:at+size];at+=size
        parts.append((marker,segment))
        if marker==0xda:
            scan=data[at:-2];pos=0
            while True:
                pos=scan.find(b'\xff',pos)
                if pos<0:break
                if pos+1>=len(scan):raise ValueError('Обрезанные данные JPEG внутри TIFF.')
                if scan[pos+1]!=0:raise Unsupported()
                pos+=2
            return parts,scan
        if marker not in {0xc0,0xc4,0xdb,0xdd,0xfe,*range(0xe0,0xf0)}:raise Unsupported()
    return parts,None


def plans(data):
    if len(data)<8 or data[:4] not in (b'II*\0',b'MM\0*'):return None
    endian='<' if data[:2]==b'II' else '>'
    def values(kind,count,value):
        size={1:1,3:2,4:4,7:1}.get(kind)
        if size is None:raise Unsupported()
        length=size*count
        if count>1000000:raise ValueError('Слишком большая таблица TIFF.')
        at=value if length>4 else None
        raw=data[at:at+length] if at is not None else struct.pack(endian+'I',value)[:length]
        if len(raw)!=length:raise ValueError('Обрезанная таблица TIFF.')
        if kind in {1,7}:return raw
        return struct.unpack(endian+str(count)+('H' if kind==3 else 'I'),raw)
    def field(tags,key,default=None):
        if key not in tags:
            if default is None:raise Unsupported()
            return default
        result=values(*tags[key])
        if len(result)!=1:raise Unsupported()
        return result[0]
    offset=struct.unpack_from(endian+'I',data,4)[0];seen=set();result=[]
    try:
        while offset:
            if offset<8 or offset+2>len(data) or offset in seen or len(seen)>=5000:
                raise ValueError('Повреждена цепочка страниц TIFF.')
            seen.add(offset);count=struct.unpack_from(endian+'H',data,offset)[0]
            end=offset+2+12*count
            if end+4>len(data):raise ValueError('Обрезана таблица страницы TIFF.')
            tags={}
            for at in range(offset+2,end,12):
                tag,kind,n,value=struct.unpack_from(endian+'HHII',data,at)
                if tag in tags:raise ValueError('Повторный тег страницы TIFF.')
                tags[tag]=(kind,n,value)
            offset=struct.unpack_from(endian+'I',data,end)[0]
            if field(tags,259,1)!=7:raise Unsupported()
            width,height=field(tags,256),field(tags,257)
            if not 0<width<=16384 or not 0<height<=16384 or width*height>16777216:
                raise ValueError('Размер страницы TIFF превышает предел чтения.')
            if field(tags,284,1)!=1 or field(tags,274,1)!=1 or 34675 in tags:raise Unsupported()
            components=field(tags,277,1);photo=field(tags,262)
            if (components,photo) not in {(1,1),(3,6)} or field(tags,531,1)!=1:raise Unsupported()
            if 258 not in tags or tuple(values(*tags[258]))!=(8,)*components:raise Unsupported()
            if 273 not in tags or 279 not in tags:raise Unsupported()
            rows=field(tags,278);offsets=values(*tags[273]);sizes=values(*tags[279])
            if rows<=0 or len(offsets)!=len(sizes) or len(offsets)!=(height+rows-1)//rows:raise Unsupported()
            shared=[]
            if 347 in tags:
                shared,scan=jpeg_parts(bytes(values(*tags[347])))
                if scan is not None or any(m not in {0xdb,0xc4} for m,_ in shared):raise Unsupported()
            table_bytes=b''.join(segment for _,segment in shared)
            template=None;scan_header=None;local_tables=None;scans=[];restart=0
            for index,(start,size) in enumerate(zip(offsets,sizes)):
                if start<8 or size<4 or start+size>len(data):raise ValueError('Обрезана полоса JPEG в TIFF.')
                parts,scan=jpeg_parts(data[start:start+size])
                if scan is None:raise ValueError('В полосе TIFF нет данных JPEG.')
                frames=[segment for m,segment in parts if m==0xc0]
                sos=[segment for m,segment in parts if m==0xda]
                if len(frames)!=1 or len(sos)!=1 or any(m==0xdd for m,_ in parts):raise Unsupported()
                frame=bytearray(frames[0]);channels=frame[9] if len(frame)>=10 else 0
                if len(frame)!=10+3*channels or frame[4]!=8 or channels!=components:raise Unsupported()
                h,w=struct.unpack_from('>HH',frame,5)
                if w!=width or h<min(rows,height-index*rows) or h>rows:raise Unsupported()
                sampling=[frame[11+3*c] for c in range(channels)]
                if any(not 1<=v>>4<=4 or not 1<=v&15<=4 for v in sampling):raise Unsupported()
                mcu_h=8*max(v&15 for v in sampling);mcu_w=8*max(v>>4 for v in sampling)
                if len(offsets)>1 and rows%mcu_h:raise Unsupported()
                interval=((width+mcu_w-1)//mcu_w)*(rows//mcu_h)
                if len(offsets)>1 and not 1<=interval<=65535:raise Unsupported()
                frame[5:7]=height.to_bytes(2,'big')
                tables=b''.join(segment for m,segment in parts if m in {0xdb,0xc4})
                header=sos[0]
                if len(header)!=8+2*channels or header[4]!=channels or header[-3:]!=b'\x00\x3f\x00':raise Unsupported()
                if template is None:
                    template=bytes(frame);scan_header=header;local_tables=tables;restart=interval
                elif bytes(frame)!=template or header!=scan_header or tables!=local_tables:raise Unsupported()
                # Store offsets, not copies of every compressed strip.
                scans.append((start+size-2-len(scan),len(scan)))
            complete_tables=table_bytes+local_tables
            if not any(m==0xdb for m,_ in shared) and not b'\xff\xdb' in local_tables:raise Unsupported()
            if not any(m==0xc4 for m,_ in shared) and not b'\xff\xc4' in local_tables:raise Unsupported()
            dri=b'\xff\xdd\x00\x04'+restart.to_bytes(2,'big') if len(scans)>1 else b''
            result.append((b'\xff\xd8'+complete_tables+template+dri+scan_header,scans))
        if not result:raise ValueError('В TIFF нет страниц.')
        return result
    except Unsupported:
        return None


def pages(source, maximum):
    data=Path(source).read_bytes();layout=plans(data)
    if layout is None:return None
    def generate():
        total=0
        for prefix,scans in layout:
            parts=[prefix]
            for index,(at,size) in enumerate(scans):
                if index:parts.append(b'\xff'+bytes([0xd0+(index-1)%8]))
                parts.append(data[at:at+size])
            parts.append(b'\xff\xd9');image=b''.join(parts);total+=len(image)
            if len(image)>16*1024*1024 or total>maximum:raise ValueError('Страницы TIFF превышают предел чтения.')
            yield image
    return len(layout),generate()

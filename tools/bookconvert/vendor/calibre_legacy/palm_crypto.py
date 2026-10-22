# GPL-3.0-only. Container-key Mobipocket compatibility.
# Format/cipher logic adapted from DeDRM mobidedrm.py and alfcrypto.py:
# Copyright 2008 The Dark Reverser; 2008-2020 Apprentice Harper et al.
# See SOURCE.json. No account data, device PIDs, passwords or installed apps
# are accessed. Individual-key books fail rather than guessing a key.
import struct
from .native_api import pc1


def trailing_size(data,flags):
    size=0;remaining=flags>>1
    while remaining:
        if remaining&1:
            at=len(data)-size;value=0;shift=0
            while True:
                if at<=0:raise ValueError('Incomplete MOBI trailing record')
                at-=1;byte=data[at];value|=(byte&127)<<shift;shift+=7
                if byte&128 or shift>=28:break
            if value<=0 or value>len(data)-size:raise ValueError('Invalid MOBI trailing size')
            size+=value
        remaining>>=1
    if flags&1:
        if size>=len(data):raise ValueError('Invalid MOBI multibyte trailer')
        size+=(data[len(data)-size-1]&3)+1
    if size>len(data):raise ValueError('Excessive MOBI trailing data')
    return size


def decode(data):
    if len(data)<86 or len(data)>64*1024*1024 or data[60:68] not in (b'BOOKMOBI',b'TEXtREAd'):
        raise ValueError('Invalid encrypted Palm container')
    count=struct.unpack_from('>H',data,76)[0]
    if not 2<=count<=20000 or 78+count*8>len(data):raise ValueError('Invalid Palm record table')
    offsets=[struct.unpack_from('>I',data,78+index*8)[0] for index in range(count)]+[len(data)]
    if offsets[0]<78+count*8 or any(a>b or b>len(data) for a,b in zip(offsets,offsets[1:])):
        raise ValueError('Invalid Palm record bounds')
    header=data[offsets[0]:offsets[1]]
    if len(header)<16:raise ValueError('Incomplete Palm header')
    encryption=struct.unpack_from('>H',header,12)[0]
    if encryption==0:return data
    if encryption not in (1,2):raise ValueError('Неизвестный тип шифрования Mobipocket.')
    records=struct.unpack_from('>H',header,8)[0]
    compression=struct.unpack_from('>H',header,0)[0]
    if not 0<records<count or compression not in (1,2,17480):raise ValueError('Invalid encrypted Palm text records')
    mobi=data[60:68]==b'BOOKMOBI'
    if mobi and (len(header)<40 or header[16:20]!=b'MOBI'):raise ValueError('Missing encrypted MOBI header')
    length=struct.unpack_from('>I',header,20)[0] if mobi else 0
    version=struct.unpack_from('>I',header,104)[0] if mobi and len(header)>=108 else -1
    extra=struct.unpack_from('>H',header,242)[0] if length>=228 and version>=5 and len(header)>=244 else 0
    if compression!=17480:extra&=0xfffe
    output=bytearray(data)
    if encryption==1:
        position=14 if not mobi else 144 if version<0 else length+16
        if position+16>len(header):raise ValueError('Incomplete legacy MOBI container key')
        key=pc1(b'QDCVEPMU675RUBSZ',header[position:position+16])
    else:
        if len(header)<184:raise ValueError('Incomplete MOBI key table')
        pointer,number,size,flags=struct.unpack_from('>IIII',header,168)
        if not 0<number<=2048 or size<48*number or pointer<16 or pointer+size>len(header):
            raise ValueError('Invalid MOBI key record bounds')
        standard=bytes.fromhex('723833b0b4f2e3cadf0901d6e2e03f96');key=None
        for index in range(number):
            verification,_,_,checksum,cookie=struct.unpack_from('>IIIBxxx32s',header,pointer+48*index)
            if checksum!=sum(standard)&255:continue
            decoded=pc1(standard,cookie)
            if struct.unpack_from('>I',decoded)[0]==verification:
                key=decoded[8:24];break
        if key is None:
            raise ValueError('Для этой книги нужен индивидуальный ключ владельца. Стандартное кодирование не подходит; конвертация без ключа невозможна.')
        output[offsets[0]+pointer:offsets[0]+pointer+size]=b'\0'*size
        output[offsets[0]+168:offsets[0]+184]=b'\xff'*4+b'\0'*12
    output[offsets[0]+12:offsets[0]+14]=b'\0\0'
    for index in range(1,records+1):
        start,end=offsets[index:index+2];record=data[start:end]
        extra_size=trailing_size(record,extra);stop=len(record)-extra_size
        output[start:start+stop]=pc1(key,record[:stop])
    return bytes(output)

"""Bounded HA CPY/ASC decoding. Apache-2.0; see vendor/ha/ha_LICENSE.txt.

ASC adapted from Mike Krueger's unarc-rs (Apache-2.0), pinned in
vendor/ha/SOURCE.json. Only bytes are decoded; archive paths are never extracted.
"""
from pathlib import Path
import struct
import tempfile
import zlib


class Arithmetic:
    def __init__(self, data):
        if len(data)<2: raise ValueError('Оборван поток ASC.')
        self.data=data;self.at=2;self.low=0;self.high=65535;self.code=int.from_bytes(data[:2],'big');self.bit=0;self.byte=0;self.padding=0
    def next_bit(self):
        if not self.bit:
            if self.at<len(self.data):self.byte=self.data[self.at];self.at+=1
            else:
                self.padding+=1
                if self.padding>2:raise ValueError('Оборван поток ASC.')
                self.byte=0
            self.bit=8
        self.bit-=1;return (self.byte>>self.bit)&1
    def threshold(self,total):
        if not 0<total<65536:raise ValueError('Некорректная модель ASC.')
        value=((((self.code-self.low)&65535)+1)*total-1)//(self.high-self.low+1)
        if not 0<=value<total:raise ValueError('Повреждён арифметический поток ASC.')
        return value
    def update(self,lo,hi,total):
        if not 0<=lo<hi<=total:raise ValueError('Некорректный интервал ASC.')
        width=self.high-self.low+1;self.high=(self.low+width*hi//total-1)&65535;self.low=(self.low+width*lo//total)&65535
        while True:
            if not (self.high^self.low)&32768:
                self.low=(self.low<<1)&65535;self.high=((self.high<<1)|1)&65535;self.code=((self.code<<1)|self.next_bit())&65535
            elif self.low&16384 and not self.high&16384:
                self.low=(self.low<<1)&32767;self.high=((self.high<<1)|32769)&65535;self.code=(((self.code<<1)^32768)|self.next_bit())&65535
            else:break


class Table:
    def __init__(self,count,initial):
        self.count=count;self.values=[0]*count+[initial]*count;self.rebuild()
    def rebuild(self):
        for i in range(self.count-1,0,-1):self.values[i]=self.values[i*2]+self.values[i*2+1]
    def total(self):return self.values[1]
    def frequency(self,symbol):return self.values[self.count+symbol]
    def find(self,threshold):
        node=2;cum=0
        while True:
            value=self.values[node]
            if cum+value<=threshold:cum+=value;node+=1
            if node>=self.count:return node-self.count,cum
            node*=2
    def add(self,symbol,step,maximum):
        at=symbol+self.count
        while at:self.values[at]+=step;at//=2
        if self.total()>=maximum:
            for i in range(self.count,self.count*2):
                if self.values[i]>1:self.values[i]//=2
            self.rebuild()
    def remove(self,symbol):
        at=symbol+self.count;amount=self.values[at]
        while at:self.values[at]-=amount;at//=2


def asc(data, expected):
    if not 0 <= expected <= 64*1024*1024: raise ValueError('Размер ASC превышает предел чтения.')
    coder=Arithmetic(data);chars=Table(256,0);char_escape=Table(256,1);char_weight=1
    lengths=Table(64,0);len_escape=Table(64,1);len_weight=8
    positions=Table(16,0);positions.add(0,24,6000);active=1;pos_max=1
    types=[[40,40] for _ in range(4)];context=0;output=bytearray()
    def symbol(main,escape,weight,step,maximum,locality):
        total=main.total();combined=total+weight;value=coder.threshold(combined)
        if value>=total:
            coder.update(total,combined,combined);total=escape.total();value=coder.threshold(total)
            result,cum=escape.find(value);coder.update(cum,cum+escape.frequency(result),total);escape.remove(result)
            weight=weight+step if escape.total() else 0
            for i in range(max(0,result-locality),min(main.count-1,result+locality)):
                if escape.frequency(i):escape.add(i,1,maximum)
        else:
            result,cum=main.find(value);coder.update(cum,cum+main.frequency(result),combined)
        main.add(result,step,maximum)
        if main.frequency(result)==3*step:
            weight=weight-step if weight>step else 1
        return result,weight
    while True:
        literal,match=types[context];total=literal+match;value=coder.threshold(total+1)
        if value<literal:
            coder.update(0,literal,total+1);types[context][0]+=40
            if total>=6000:types[context]=[max(1,n//2) for n in types[context]]
            context=(context<<1)&3
            value,char_weight=symbol(chars,char_escape,char_weight,1,1000,8);output.append(value)
        elif value<total:
            coder.update(literal,total,total+1);types[context][1]+=40
            if total>=6000:types[context]=[max(1,n//2) for n in types[context]]
            context=((context<<1)|1)&3;emitted=min(len(output),31200)
            while emitted>pos_max:positions.add(active,24,6000);active+=1;pos_max*=2
            count=positions.total();value=coder.threshold(count);code,cum=positions.find(value)
            coder.update(cum,cum+positions.frequency(code),count);positions.add(code,24,6000)
            position=code
            if code>1:
                base=1<<(code-1);count=emitted-(pos_max>>1) if base==pos_max>>1 else base
                extra=coder.threshold(count);coder.update(extra,extra+1,count);position=base+extra
            code,len_weight=symbol(lengths,len_escape,len_weight,8,6000,4)
            if code==15:length=783
            elif code>=16:
                extra=coder.threshold(16);coder.update(extra,extra+1,16);length=(code-16)*16+extra+15
            else:length=code
            length+=3
            if position>=emitted or len(output)+length>expected:raise ValueError('Некорректная ссылка ASC.')
            for _ in range(length):output.append(output[-position-1])
        else:
            coder.update(total,total+1,total+1);break
        if len(output)>expected:raise ValueError('ASC превышает объявленную длину.')
    if len(output)!=expected:raise ValueError(f'Неполный результат ASC: {len(output)} из {expected}.')
    return bytes(output)


def entries(data, maximum=256*1024*1024):
    if not data.startswith(b'HA') or len(data)<4:raise ValueError('Не найден заголовок HA.')
    count=int.from_bytes(data[2:4],'little')
    if not 0<count<=20000:raise ValueError('Некорректное число файлов HA.')
    at=4;total=0;result=[]
    for _ in range(count):
        if at+17>len(data):raise ValueError('Оборван заголовок HA.')
        kind,packed,size,crc,_date=struct.unpack_from('<BIIII',data,at);at+=17
        names=[]
        for _ in range(2):
            end=data.find(b'\0',at,min(len(data),at+4097))
            if end<0:raise ValueError('Некорректное имя файла HA.')
            names.append(data[at:end].decode('cp866'));at=end+1
        if at>=len(data):raise ValueError('Оборван заголовок HA.')
        info=data[at];at+=1+info;total+=size
        if kind>>4>2 or at+packed>len(data) or total>maximum or size>64*1024*1024:raise ValueError('HA повреждён или превышает предел чтения.')
        name='/'.join(names).strip('/').replace('\\','/')
        if ':' in name or '..' in name.split('/'):raise ValueError('Некорректный путь HA.')
        result.append((name,kind&15,packed,size,crc,at));at+=packed
    if at!=len(data):raise ValueError('Неожиданные данные после HA.')
    return result


def unpack(data, entry):
    name,method,packed,size,crc,at=entry;payload=data[at:at+packed]
    if method==0:result=payload
    elif method==1:result=asc(payload,size)
    else:raise ValueError('Этот HA использует пока неподдерживаемый метод HSC.')
    if len(result)!=size or zlib.crc32(result)&0xffffffff!=crc:raise ValueError('Не совпадает длина или контрольная сумма HA.')
    return result


def convert(source, output, warnings, target_extension, convert_book, detect_input, **metadata):
    data=source.read_bytes();items=entries(data)
    allowed={'.fb2','.epub','.pdf','.djvu','.txt','.text','.faq','.html','.htm','.xhtml','.shtml','.rtf',
             '.doc','.docx','.odt','.mobi','.prc','.lit','.lrf','.chm','.rb','.abw','.sxw','.pdb','.tcr',
             '.ppt','.pptx','.xls','.xlsx','.ods','.odp','.mht','.md','.markdown','.fb3','.xps','.wri'}
    service={'lib.rus.ec.txt','flibusta.net.txt','flibusta.is.txt'}
    with tempfile.TemporaryDirectory(prefix='homelib-ha-',dir=output.parent) as directory:
        candidates=[]
        for index,entry in enumerate(items):
            if Path(entry[0]).name.lower() in service or entry[1] in {14,15} and entry[3]==0:continue
            # Generated names keep archive paths off disk. Inspect decoded bytes:
            # a missing or incorrect member suffix must not hide the book.
            extracted=Path(directory)/('member-'+str(index)+Path(entry[0]).suffix.lower())
            extracted.write_bytes(unpack(data,entry))
            if detect_input(extracted) in allowed:candidates.append(extracted)
            else:extracted.unlink()
            if len(candidates)>1:break
        if len(candidates)!=1:raise ValueError('В HA должно быть ровно одно книжное вложение. Для нескольких книг сначала извлеките нужный файл.')
        converted=Path(directory)/('converted'+target_extension)
        report=convert_book(candidates[0],converted,**metadata)
        warnings.update(report['warnings']);output.write_bytes(converted.read_bytes())
    warnings.add('Книжное вложение HA прочитано с проверкой длины и CRC32. Служебные файлы библиотеки не добавлялись к тексту.')

"""Isolated read-only KindleUnpack bridge for unencrypted MOBI/KF8 books."""
import contextlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys


class Mobi7ImageRecords:
    def __init__(self, names):
        self.names = names

    def __getitem__(self, index):
        # MOBI references are one-based, so the decoder's index -1 means
        # an invalid reference to record zero, not the last illustration.
        if 0 <= index < len(self.names) and self.names[index]:
            return self.names[index]
        # KindleUnpack generates imageNNNNN names for actual resources.
        # Leave a distinct missing-image path for the regular HTML reader.
        return f'homelibre-missing-mobi-image-{index + 1}.img'


def explicit_asins(header):
    # KindleUnpack generates a UUID when this EXTH field is absent.
    start = 16 + int.from_bytes(header[20:24], 'big')
    if start < 40 or start + 12 > len(header) or header[start:start + 4] != b'EXTH':
        return []
    length, count = struct.unpack_from('>II', header, start + 4)
    position, end = start + 12, start + length
    if not position <= end <= len(header) or count > (end - position) // 8:
        return []
    values = []
    for _ in range(count):
        if position + 8 > end:
            return []
        number, size = struct.unpack_from('>II', header, position)
        if not 8 <= size <= end - position:
            return []
        if number == 113 and 8 < size <= 136:
            value = header[position + 8:position + size].decode('ascii', errors='replace')
            if value.isascii() and all(char.isalnum() or char in '-_.' for char in value) and value not in values:
                values.append(value)
        position += size
    return values


def main():
    source, manifest, work = [Path(p).resolve() for p in sys.argv[1:4]]
    if manifest.exists() or work.exists() or not source.is_file(): raise ValueError('Invalid owned conversion paths')
    if source.stat().st_size > 64 * 1024 * 1024: raise ValueError('Kindle source exceeds 64 MB')
    with source.open('rb') as f:
        header = f.read(86)
        if len(header) != 86 or header[60:68] != b'BOOKMOBI': raise ValueError('Unsupported Palm/Kindle container')
        offset = struct.unpack('>I', header[78:82])[0]
        if offset + 40 > source.stat().st_size: raise ValueError('Incomplete Kindle header')
        f.seek(offset); record = f.read(40)
    if record[16:20] != b'MOBI': raise ValueError('Unsupported legacy PalmDoc container')
    encrypted=struct.unpack('>H', record[12:14])[0]!=0
    if struct.unpack('>I', record[4:8])[0] > 64 * 1024 * 1024: raise ValueError('Kindle text exceeds 64 MB')
    work.mkdir()
    compatibility_warnings=[]
    if encrypted:
        prepared=work/'prepared.mobi'
        decoder=Path(__file__).with_name('legacy_helper.py')
        native=Path(sys.argv[4]).resolve() if len(sys.argv)>4 else decoder.parent/'vendor/calibre_legacy/native/HomeLibLegacy.dll'
        result=subprocess.run([sys.executable,'-I','-B','-X','utf8',str(decoder),str(source),str(prepared),
                               '--kindle','--native-library',str(native)],capture_output=True,timeout=60,creationflags=0x08000000)
        if result.returncode:raise ValueError(result.stderr.decode('utf-8',errors='replace')[-1400:])
        source=prepared
        compatibility_warnings.append('Стандартное кодирование Mobipocket подготовлено по ключу самого файла; исходник не изменён.')
    # Some old public-domain MOBI files leave a zero/unrelated NCX pointer.
    # A non-INDX record is not a usable navigation index. Clear only that
    # impossible pointer in the owned copy; keep all book text and resources.
    data=source.read_bytes();count=int.from_bytes(data[76:78],'big')
    if not 2<=count<=20000 or 78+count*8>len(data):raise ValueError('Invalid Kindle record table')
    offsets=[int.from_bytes(data[78+index*8:82+index*8],'big') for index in range(count)]+[len(data)]
    if offsets[0]<78+count*8 or any(a>b or b>len(data) for a,b in zip(offsets,offsets[1:])):
        raise ValueError('Invalid Kindle record bounds')
    header=data[offsets[0]:offsets[1]]
    if len(header)>=248 and int.from_bytes(header[20:24],'big')+16>=248 and int.from_bytes(header[36:40],'big')<8:
        index=int.from_bytes(header[244:248],'big')
        if index!=0xffffffff and (index>=count or data[offsets[index]:offsets[index]+4]!=b'INDX'):
            patched=bytearray(data);patched[offsets[0]+244:offsets[0]+248]=b'\xff'*4
            source=work/'navigation-compatible.mobi';source.write_bytes(patched)
            compatibility_warnings.append('В исходном MOBI повреждён указатель оглавления. Текст и ресурсы перенесены; навигация строится по доступным заголовкам.')
    def inside(path):
        path = Path(os.fsdecode(path)).resolve()
        return path == work or path.is_relative_to(work) or path == manifest
    def audit(event, args):
        if event == 'open' and not isinstance(args[0], int):
            mode, flags = args[1], args[2]
            writing = (mode is not None and any(x in mode for x in 'wax+')) or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC)
            if writing and not inside(args[0]): raise PermissionError('Write outside owned Kindle workspace')
        elif event in {'os.mkdir', 'os.remove', 'os.rmdir'} and not inside(args[0]): raise PermissionError('Change outside owned Kindle workspace')
        elif event in {'socket.connect', 'subprocess.Popen', 'os.system', 'os.symlink', 'os.link'}: raise PermissionError('External operation during Kindle unpacking')
    sys.addaudithook(audit)
    kindle_root=Path(sys.argv[5]).resolve() if len(sys.argv)>5 else Path(__file__).resolve().parents[1]/'kindle'
    sys.path.insert(0,str(kindle_root))
    from lib import kindleunpack
    from convert_kf8 import unpack_preserving_resource_slots

    HTMLProcessor = kindleunpack.HTMLProcessor
    insert_hrefs = HTMLProcessor.insertHREFS
    def insert_mobi7_hrefs(processor):
        names = processor.rscnames
        processor.rscnames = Mobi7ImageRecords(names)
        try:
            return insert_hrefs(processor)
        finally:
            processor.rscnames = names

    HTMLProcessor.insertHREFS = insert_mobi7_hrefs
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            incomplete_fonts = unpack_preserving_resource_slots(kindleunpack, source, work, epubver='3')
    finally:
        HTMLProcessor.insertHREFS = insert_hrefs
    if incomplete_fonts:
        records = ', '.join(map(str, incomplete_fonts))
        compatibility_warnings.append(f'Не перенесены встроенные шрифты Kindle. Повреждённые записи: {records}.')
    files = [p for p in work.rglob('*') if p.is_file()]
    if len(files) > 20000 or sum(p.stat().st_size for p in files) > 256 * 1024 * 1024: raise ValueError('Kindle resources exceed conversion limits')
    epubs = [p for p in files if p.suffix.lower() == '.epub']
    if len(epubs) == 1: result = {'format': 'epub', 'path': str(epubs[0])}
    elif not epubs and (work / 'mobi7/book.html').is_file(): result = {'format': 'html', 'path': str(work / 'mobi7/book.html')}
    else: raise ValueError('KindleUnpack did not produce one readable book')
    if result['format'] == 'html':
        result['asins'] = explicit_asins(header)
    result['warnings']=compatibility_warnings
    with manifest.open('x', encoding='utf-8') as f: json.dump(result, f)
    print('OK unencrypted Kindle text and resources')


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error)); sys.exit(1)

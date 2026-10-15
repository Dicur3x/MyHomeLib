"""Isolated read-only KindleUnpack bridge for unencrypted MOBI/KF8 books."""
import contextlib
import io
import json
import os
from pathlib import Path
import struct
import sys


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
    if struct.unpack('>H', record[12:14])[0]: raise ValueError('Encrypted Kindle books are not supported')
    if struct.unpack('>I', record[4:8])[0] > 64 * 1024 * 1024: raise ValueError('Kindle text exceeds 64 MB')
    work.mkdir()
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
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'kindle'))
    from lib.kindleunpack import unpackBook
    with contextlib.redirect_stdout(io.StringIO()): unpackBook(str(source), str(work), epubver='3', use_hd=True)
    files = [p for p in work.rglob('*') if p.is_file()]
    if len(files) > 20000 or sum(p.stat().st_size for p in files) > 256 * 1024 * 1024: raise ValueError('Kindle resources exceed conversion limits')
    epubs = [p for p in files if p.suffix.lower() == '.epub']
    if len(epubs) == 1: result = {'format': 'epub', 'path': str(epubs[0])}
    elif not epubs and (work / 'mobi7/book.html').is_file(): result = {'format': 'html', 'path': str(work / 'mobi7/book.html')}
    else: raise ValueError('KindleUnpack did not produce one readable book')
    with manifest.open('x', encoding='utf-8') as f: json.dump(result, f)
    print('OK unencrypted Kindle text and resources')


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error)); sys.exit(1)

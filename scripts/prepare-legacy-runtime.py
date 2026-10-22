"""Build the small read-only LIT decoder for the bundled Python runtime.

Only the pinned TinyCC compiler is downloaded; sources are kept in the repository.
The temporary compiler and intermediate binaries are removed on every exit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
COMPILERS = {
    'Win32': ('win32','02e2bfe8c272a549b15e4bfa4507bd7e05304692af1761db6c1e8e88af675651'),
    'Win64': ('win64','34a721949a2583fdff725312da092fa0f5f1f284b702e6f811c6954714faabb2'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform',choices=COMPILERS)
    options = parser.parse_args()
    vendor = ROOT/'tools/bookconvert/vendor/calibre_legacy'
    source = vendor/'native'
    destination = ROOT/'Program/Out'/('Bin' if options.platform=='Win32' else 'Bin64')/'tools/bookconvert/vendor/calibre_legacy/native'
    compiler_arch, expected = COMPILERS[options.platform]
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-legacy-build-') as temporary:
        work = Path(temporary)
        url = 'https://download.savannah.nongnu.org/releases/tinycc/tcc-0.9.27-'+compiler_arch+'-bin.zip'
        with urllib.request.urlopen(url,timeout=60) as response: data=response.read(16*1024*1024+1)
        if len(data)>16*1024*1024 or hashlib.sha256(data).hexdigest()!=expected:
            raise RuntimeError('Compiler checksum mismatch')
        archive = work/'compiler.zip';archive.write_bytes(data)
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if name.startswith(('/','\\')) or ':' in name or '..' in Path(name).parts:
                    raise RuntimeError('Unexpected compiler member')
            package.extractall(work/'compiler')
        output = work/'HomeLibLegacy.dll'
        command = [str(work/'compiler/tcc/tcc.exe'),'-shared','-D_MSC_VER=1900','-I'+str(source),'-o',str(output)]
        command += [str(source/name) for name in ['bridge.c','lzxd.c','des.c']]
        compiled=subprocess.run(command,cwd=work,capture_output=True,timeout=120,creationflags=0x08000000)
        if compiled.returncode:
            raise RuntimeError((compiled.stdout+compiled.stderr).decode('utf-8',errors='replace'))
        data=output.read_bytes(); offset=struct.unpack_from('<I',data,0x3c)[0]
        if struct.unpack_from('<H',data,offset+4)[0] != (0x14c if options.platform=='Win32' else 0x8664):
            raise RuntimeError('Decoder architecture mismatch')
        destination.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(output,destination/'HomeLibLegacy.dll')
        report={'platform':options.platform,'source':json.loads((vendor/'SOURCE.json').read_text(encoding='utf-8'))['commit'],
                'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),
                'compiler_url':url,'compiler_sha256':expected,
                'sources':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in source.iterdir() if path.suffix in ('.c','.h')}}
        (destination/'RUNTIME.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('PASS legacy decoder built '+options.platform+'; compiler and build payloads removed')


if __name__=='__main__':main()

"""Bounded PDF reader benchmark using an existing generated native fixture."""
import argparse, ctypes, hashlib, json, pathlib, shutil, subprocess, tempfile, time

p=argparse.ArgumentParser()
p.add_argument('fixture',type=pathlib.Path)
p.add_argument('exe',type=pathlib.Path)
p.add_argument('pdfium',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
a=p.parse_args()
root=pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-pdf-benchmark-')).resolve()
assert root.parent==pathlib.Path(tempfile.gettempdir()).resolve()
assert a.fixture.parent.resolve().name.startswith('HomeLibRu-native-reader-')
class Counters(ctypes.Structure):
    _fields_=[('cb',ctypes.c_ulong),('faults',ctypes.c_ulong)]+[(n,ctypes.c_size_t) for n in ('peak_ws','ws','peak_paged','paged','peak_nonpaged','nonpaged','pagefile','peak_pagefile','private')]
psapi=ctypes.WinDLL('psapi',use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.POINTER(Counters),ctypes.c_ulong]
psapi.GetProcessMemoryInfo.restype=ctypes.c_int
shutil.copy2(a.exe,root/a.exe.name)
shutil.copy2(a.fixture,root/'sample.pdf')
shutil.copy2(a.pdfium,root/'pdfium.dll')
for name in ('uselocaldata','uselocaltemp'): (root/name).write_text('')
(root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
(root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\n[OPDS]\nEnabled=0\n',encoding='utf-8')
before=hashlib.sha256((root/'sample.pdf').read_bytes()).hexdigest()
startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
peak_private=peak_ws=0; start=time.perf_counter(); log=root/'benchmark.log'
with log.open('wb') as f:
    proc=subprocess.Popen([str(root/a.exe.name)],cwd=root,stdout=f,stderr=subprocess.STDOUT,startupinfo=startup)
    while proc.poll() is None:
        info=Counters();info.cb=ctypes.sizeof(info)
        if psapi.GetProcessMemoryInfo(int(proc._handle),ctypes.byref(info),info.cb):
            peak_private=max(peak_private,info.private);peak_ws=max(peak_ws,info.ws)
        if time.perf_counter()-start>90: proc.kill();proc.wait();raise TimeoutError('PDF benchmark')
        time.sleep(.01)
output=log.read_text(encoding='mbcs',errors='replace');print(output,flush=True)
result=dict(peak_private_sampled=peak_private,peak_working_set_sampled=peak_ws,elapsed=time.perf_counter()-start,log=output,fixture_sha256=before,root=str(root),returncode=proc.returncode)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
assert before==hashlib.sha256((root/'sample.pdf').read_bytes()).hexdigest()
assert proc.returncode==0 and 'PASS PDF raster' in output
print('PASS isolated PDF benchmark; retained',root,flush=True)

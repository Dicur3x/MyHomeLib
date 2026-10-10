"""Bounded native reader benchmark on generated books, never personal data."""
import argparse, pathlib, tempfile, shutil, subprocess, hashlib, json, ctypes, time

p = argparse.ArgumentParser()
p.add_argument('runtime', type=pathlib.Path)
p.add_argument('exe', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--keep', action='store_true')
a = p.parse_args()
root = pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-reader-benchmark-')).resolve()
assert root.parent == pathlib.Path(tempfile.gettempdir()).resolve()
assert root.name.startswith('HomeLibRu-native-reader-benchmark-')

class MemoryCounters(ctypes.Structure):
    _fields_ = [('cb',ctypes.c_ulong),('faults',ctypes.c_ulong)] + [
        (n,ctypes.c_size_t) for n in ('peak_ws','ws','peak_paged','paged','peak_nonpaged','nonpaged','pagefile','peak_pagefile','private')]

psapi=ctypes.WinDLL('psapi',use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.POINTER(MemoryCounters),ctypes.c_ulong]
psapi.GetProcessMemoryInfo.restype=ctypes.c_int
results=[]
try:
    shutil.copy2(a.exe.resolve(),root/a.exe.name)
    for name in ('sqlite3.dll','libzstd.dll'):
        if (a.runtime/name).exists(): shutil.copy2(a.runtime/name,root/name)
    for marker in ('uselocaldata','uselocaltemp'): (root/marker).write_text('')
    (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1',encoding='utf-8')
    (root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\n[OPDS]\nEnabled=0\n',encoding='utf-8')
    sentence='Это самостоятельный тест большой книги. Быстрое чтение сохраняет русский текст, переносы строк и эмодзи 🌍. '
    paragraph=sentence*5
    for megabytes in (1,8):
        count=(megabytes*1024*1024)//len((paragraph+'\n\n').encode('utf-8'))
        text='\n\n'.join([paragraph]*count)+'\n\nTAIL_MARKER_20261009 Конец книги.'
        for ext in ('txt','fb2'):
            name=f'large-{megabytes}.{ext}'
            payload=text if ext=='txt' else '<FictionBook><body><section><title><p>Большая книга</p></title>'+''.join('<p>'+v+'</p>' for v in text.split('\n\n'))+'</section></body></FictionBook>'
            file=root/name; file.write_text(payload,encoding='utf-8-sig')
            before=hashlib.sha256(file.read_bytes()).hexdigest()
            log=root/(name+'.log')
            startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
            start=time.perf_counter(); peak_private=peak_ws=0; stages={}
            with log.open('wb') as f:
                proc=subprocess.Popen([str(root/a.exe.name),name],cwd=root,stdout=f,stderr=subprocess.STDOUT,startupinfo=startup)
                while proc.poll() is None:
                    info=MemoryCounters();info.cb=ctypes.sizeof(info)
                    if psapi.GetProcessMemoryInfo(int(proc._handle),ctypes.byref(info),info.cb):
                        peak_private=max(peak_private,info.private);peak_ws=max(peak_ws,info.ws)
                        captured=log.read_bytes()
                        for stage in ('load','next_30','search_tail','bookmark','resumed_previous','font_change'):
                            if stage not in stages and ('PROFILE '+stage+'_ms=').encode() in captured:
                                stages[stage]={'private':info.private,'working_set':info.ws,'elapsed':time.perf_counter()-start}
                    if time.perf_counter()-start>180:
                        proc.kill();proc.wait();raise TimeoutError(name)
                    time.sleep(.025)
            output=log.read_text(encoding='mbcs',errors='replace'); print(name,output,flush=True)
            assert proc.returncode==0 and 'PASS large reader fixture' in output
            assert before==hashlib.sha256(file.read_bytes()).hexdigest()
            result={'file':name,'bytes':file.stat().st_size,'sha256':before,'peak_private_sampled':peak_private,'peak_working_set_sampled':peak_ws,'stages_sampled':stages,'log':output}
            results.append(result);a.output.parent.mkdir(parents=True,exist_ok=True)
            a.output.write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    print('PASS bounded reader benchmark; source fixtures unchanged; no network server',flush=True)
finally:
    if a.keep: print('RETAINED',root,flush=True)
    else: shutil.rmtree(root)

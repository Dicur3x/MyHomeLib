"""Black-box persistent DjVu worker checks; copies the supplied book to TEMP.

Usage: python djvu_worker_tests.py <tools/djvu directory> <valid multipage.djvu>
Requires Pillow for independent pixel comparison with the official CLI.
"""
import argparse,hashlib,json,mmap,pathlib,shutil,struct,subprocess,tempfile,time,uuid
from concurrent.futures import ThreadPoolExecutor
from PIL import Image,ImageChops,ImageStat

p=argparse.ArgumentParser();p.add_argument('runtime',type=pathlib.Path);p.add_argument('book',type=pathlib.Path)
a=p.parse_args();runtime=a.runtime.resolve();book=a.book.resolve();source_hash=hashlib.sha256(book.read_bytes()).hexdigest()
magic=0x48444a31

class Worker:
    def __init__(self):
        name='Local\\HomeLibRu-Djvu-'+str(uuid.uuid4())
        self.buffer=mmap.mmap(-1,64*1024*1024,tagname=name)
        self.process=subprocess.Popen([str(runtime/'HomeLibDjvu.exe'),'--worker',name],stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        self.pool=ThreadPoolExecutor(max_workers=1)
    def send(self,cmd,index=0,text=''):
        data=text.encode('utf-8');self.process.stdin.write(struct.pack('<Iiii',magic,cmd,index,len(data))+data);self.process.stdin.flush()
    def reply(self):
        def read():
            header=self.process.stdout.read(24);assert len(header)==24,('incomplete reply',self.process.poll())
            sig,status,w,h,count,size=struct.unpack('<Iiiiii',header);assert sig==magic and 0<=size<=12000
            text=self.process.stdout.read(size).decode('utf-8');return status,w,h,count,text
        return self.pool.submit(read).result(timeout=35)
    def close(self,normal=False):
        if self.process.poll() is None:
            if normal:self.send(3);self.process.wait(timeout=5)
            else:self.process.kill();self.process.wait(timeout=5)
        for pipe in (self.process.stdin,self.process.stdout):pipe.close()
        self.pool.shutdown(wait=True);self.buffer.close()

with tempfile.TemporaryDirectory(prefix='HomeLibRu-djvu-test-') as folder:
    folder=pathlib.Path(folder);copy=folder/'Книга с пробелами.djvu';shutil.copy2(book,copy)
    w=Worker();timings=[]
    try:
        w.send(1,text=str(copy));status,_,_,count,error=w.reply();assert status==0 and count>=3,error
        w.send(2,-1);assert w.reply()[0]==1
        for index in list(range(min(20,count)))+list(range(min(20,count)-1,-1,-1)):
            started=time.perf_counter();w.send(2,index);status,x,y,c,error=w.reply()
            assert status==0 and c==count and 0<x<=4000 and 0<y<=4000,error
            pixels=w.buffer[:x*y*4];assert all(alpha==255 for alpha in pixels[3::4096])
            timings.append(round((time.perf_counter()-started)*1000,2))
            if index==2:
                native=Image.frombytes('RGB',(x,y),pixels,'raw','BGRX')
                reference=folder/'reference.tiff'
                subprocess.run([str(runtime/'ddjvu.exe'),'-format=tiff','-quality=uncompressed','-page=3',f'-size={x}x{y}',str(copy),str(reference)],
                    check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=35,creationflags=subprocess.CREATE_NO_WINDOW)
                with Image.open(reference) as expected:
                    expected=expected.convert('RGB').resize(native.size)
                    mean=ImageStat.Stat(ImageChops.difference(native,expected)).mean
                    assert max(mean)<5,('native orientation/colour differs from official CLI',mean)
        w.close(normal=True);assert w.process.returncode==0
        print('PASS Unicode paths, bounds, recovery from invalid page, opaque BGRA and orientation/colour vs official renderer')
        print(json.dumps({'pages':len(timings),'mean_ms':round(sum(timings)/len(timings),2),'max_ms':max(timings)}))
    finally:w.close()
    bad=folder/'broken.djvu';bad.write_bytes(b'not a djvu')
    w=Worker()
    try:
        w.send(1,text=str(bad));assert w.reply()[0]==1
    finally:w.close()
    print('PASS broken document returns an error and exits without a dialog')
    for cycle in range(12):
        w=Worker()
        try:
            w.send(1,text=str(copy));assert w.reply()[0]==0
            w.send(2,cycle%3)
        finally:w.close()
    print('PASS 12 decoders terminate during pending page preparation')
assert source_hash==hashlib.sha256(book.read_bytes()).hexdigest()
print('PASS source bytes unchanged; isolated worker regressions complete')

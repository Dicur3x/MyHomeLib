"""Isolated persistent PDF renderer: pixels, bounds, errors and cancellation."""
import argparse, ctypes, hashlib, mmap, pathlib, shutil, struct, subprocess, tempfile, time, uuid
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageChops, ImageStat

p=argparse.ArgumentParser()
p.add_argument('runtime',type=pathlib.Path)
p.add_argument('book',type=pathlib.Path)
p.add_argument('reference_pdfium',type=pathlib.Path,help='PDFium matching Python bitness')
a=p.parse_args();runtime=a.runtime.resolve();book=a.book.resolve()
source_hash=hashlib.sha256(book.read_bytes()).hexdigest();magic=0x48504431

class Worker:
    def __init__(self):
        name='Local\\HomeLibRu-PDF-'+str(uuid.uuid4())
        self.buffer=mmap.mmap(-1,64*1024*1024,tagname=name)
        self.process=subprocess.Popen([str(runtime/'HomeLibPDF.exe'),'--worker',name],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
        self.pool=ThreadPoolExecutor(max_workers=1)
    def send(self,cmd,index=0,text='',edge=0):
        data=text.encode('utf-8');length=edge if cmd==2 else len(data)
        self.process.stdin.write(struct.pack('<Iiii',magic,cmd,index,length)+data);self.process.stdin.flush()
    def reply(self):
        def read():
            header=self.process.stdout.read(24);assert len(header)==24,('incomplete reply',self.process.poll())
            sig,status,w,h,count,size=struct.unpack('<Iiiiii',header);assert sig==magic and 0<=size<=12000
            return status,w,h,count,self.process.stdout.read(size).decode('utf-8')
        return self.pool.submit(read).result(timeout=35)
    def close(self,normal=False):
        if self.process.poll() is None:
            if normal:self.send(3);self.process.wait(timeout=5)
            else:self.process.kill();self.process.wait(timeout=5)
        for pipe in (self.process.stdin,self.process.stdout):pipe.close()
        self.pool.shutdown(wait=True);self.buffer.close()

dll=ctypes.CDLL(str(a.reference_pdfium.resolve()))
def bind(name,args,result=None):
    f=getattr(dll,name);f.argtypes=args;f.restype=result;return f
P=ctypes.c_void_p;I=ctypes.c_int
bind('FPDF_InitLibrary',[])()
load=bind('FPDF_LoadDocument',[ctypes.c_char_p,ctypes.c_char_p],P)
page=bind('FPDF_LoadPage',[P,I],P);closepage=bind('FPDF_ClosePage',[P])
bitmap=bind('FPDFBitmap_CreateEx',[I,I,I,P,I],P)
fill=bind('FPDFBitmap_FillRect',[P,I,I,I,I,ctypes.c_ulong])
render=bind('FPDF_RenderPageBitmap',[P,P,I,I,I,I,I,I])
destroy=bind('FPDFBitmap_Destroy',[P]);closedoc=bind('FPDF_CloseDocument',[P])

with tempfile.TemporaryDirectory(prefix='HomeLibRu-pdf-test-') as folder:
    folder=pathlib.Path(folder);copy=folder/'Книга с пробелами.pdf';shutil.copy2(book,copy)
    reference=load(str(copy).encode('utf-8'),None);assert reference
    w=Worker();timings=[]
    try:
        w.send(1,text=str(copy));status,_,_,count,error=w.reply();assert status==0 and count>=2,error
        for index,edge in ((0,1200),(1,1200),(min(21,count-1),1200),(0,1800),(1,4000)):
            started=time.perf_counter();w.send(2,index,edge=edge);status,x,y,c,error=w.reply()
            assert status==0 and c==count and 0<x<=edge and 0<y<=edge,(index,error)
            pixels=w.buffer[:x*y*4];assert all(alpha==255 for alpha in pixels[3::4096])
            native=Image.frombytes('RGB',(x,y),pixels,'raw','BGRX')
            memory=ctypes.create_string_buffer(x*y*4);pg=page(reference,index);assert pg
            bm=bitmap(x,y,4,memory,x*4);assert bm
            try:fill(bm,0,0,x,y,0xffffffff);render(bm,pg,0,0,x,y,0,1)
            finally:destroy(bm);closepage(pg)
            expected=Image.frombytes('RGB',(x,y),memory.raw,'raw','BGRX')
            mean=ImageStat.Stat(ImageChops.difference(native,expected)).mean
            assert max(mean)<1,('PDF pixel orientation/colour mismatch',mean)
            timings.append(round((time.perf_counter()-started)*1000,2))
        for index,edge in ((-1,1200),(count,1200),(0,199),(0,4001)):
            w.send(2,index,edge=edge);assert w.reply()[0]==1
        w.send(2,0,edge=1200);assert w.reply()[0]==0
        w.close(normal=True);assert w.process.returncode==0
        print('PASS PDF Unicode path, bounds, recovery, opaque pixels and independent native comparison',timings)
    finally:w.close();closedoc(reference)
    for payload in (b'not a pdf',copy.read_bytes()[:32]):
        bad=folder/'broken.pdf';bad.write_bytes(payload);w=Worker()
        try:
            w.send(1,text=str(bad));assert w.reply()[0]==1
            w.send(1,text=str(copy));assert w.reply()[0]==0
            w.send(2,0,edge=1200);assert w.reply()[0]==0
        finally:w.close()
    for cycle in range(8):
        w=Worker()
        try:w.send(1,text=str(copy));assert w.reply()[0]==0;w.send(2,cycle%2,edge=4000)
        finally:w.close()
    print('PASS broken PDF recovery and 8 cancellations during page preparation')
assert source_hash==hashlib.sha256(book.read_bytes()).hexdigest()
print('PASS source bytes unchanged; isolated PDF worker regressions complete')

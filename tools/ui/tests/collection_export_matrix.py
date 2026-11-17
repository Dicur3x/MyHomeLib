"""Probe actual converter/writer directions on bounded read-only catalogue copies.

This covers the backend, not the ordinary save dialog or native TXT/FB2.ZIP.
Unknown/nested/nonbook inputs remain explicit pending rows. A writer success
is separate from independent content checks and final release-package proof.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, shutil, subprocess, tempfile, time, zipfile

REPO=Path(__file__).resolve().parents[3]
WRITERS={'BookProcessing','KindleExport','KoboExport','KfxExport','EpubPdfExport','FB2Export',
         'Kindle','LegacyBooks','LegacyOffice','7-Zip','DocSharp','DjVuLibre','PDFium','WebP'}
OUTPUTS=[('fb2','.fb2',None),('epub','.epub',None),('mobi','.mobi',None),('azw3','.azw3',None),
         ('epub2','.epub','epub2'),('epub3','.epub','epub3'),('kepub','.kepub.epub','kepub'),
         ('kfx','.kfx','kfx'),('azw8','.azw8','azw8'),('pdf','.pdf','pdf'),('md','.md','md')]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def reserve(path):
    if shutil.disk_usage('C:/').free<8*1024**3 or shutil.disk_usage(path).free<2*1024**3:
        raise RuntimeError('Test volume or system reserve exhausted')
def load(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def owned_g(path):
    path=path.resolve()
    if path.drive.upper()!='G:':raise ValueError('New matrix work stays on G:')
    return path

def prepare_runtime(root,plan,helpers,source_overlay=True):
    packages=[]
    for entry in plan['packages']:
        if entry['id'] not in WRITERS:continue
        source=Path(entry['archive']).resolve()
        if source.drive.upper()=='E:' or sha(source)!=entry['sha256']:raise ValueError('Unpinned/forbidden package')
        with zipfile.ZipFile(source) as z:
            manifest=json.loads(z.read('HomeLibRu.update.json'))
            if manifest['component']!=entry['id'] or manifest['platform']!=plan['platform']:
                raise ValueError('Component identity mismatch')
            for item in manifest['files']:
                target=(root/item['path']).resolve()
                if not item['path'].startswith('tools/') or not target.is_relative_to(root):raise ValueError('Invalid runtime path')
                data=z.read(item['path'])
                if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:raise ValueError('Runtime file mismatch')
                target.parent.mkdir(parents=True,exist_ok=True)
                if target.exists() and target.read_bytes()!=data:raise ValueError('Conflicting runtime packages')
                target.write_bytes(data)
        packages.append(entry)
    if {e['id'] for e in packages}!=WRITERS:raise ValueError('Incomplete explicit runtime plan')
    overlays={}
    for source in (REPO/'tools/bookconvert').rglob('*') if source_overlay else ():
        relative=source.relative_to(REPO/'tools/bookconvert')
        if not source.is_file() or {'tests','__pycache__'}&set(relative.parts):continue
        if source.suffix not in {'.py','.txt','.js','.json','.bin'} and source.name!='py.typed':continue
        target=root/'tools/bookconvert'/relative;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target);overlays[relative.as_posix()]=sha(source)
    # The PDF bridge is installed with its optional writer, outside the common
    # Python folder. Overlay the script actually loaded by advanced_output too.
    optional={}
    for relative in ['tools/epub-pdf/epub_pdf_output.py'] if source_overlay else ():
        target=root/relative
        if target.is_file():
            source=REPO/'tools/bookconvert'/target.name
            shutil.copy2(source,target);optional[relative]=sha(source)
    local={}
    for name in ['xps','images']:
        shutil.copytree(helpers/name,root/'tools'/name)
        for source in (helpers/name).rglob('*'):
            if source.is_file():local[source.relative_to(helpers).as_posix()]=sha(source)
    return dict(packages=packages,source_overlay_enabled=source_overlay,current_source_overlay=overlays,
                optional_module_source_overlay=optional,local_helper_sha256=local)

def extract_sample(candidate,expected,root):
    errors=[]
    for copy in candidate['copies']:
        source=(Path(copy['root'])/copy['folder']).resolve()
        if source.drive.upper()=='E:':raise ValueError('E: input is forbidden')
        if source.suffix.lower()!='.zip':continue
        if not source.is_file():continue
        stamp=source.stat();member=copy['file']+copy['extension']
        try:
            with zipfile.ZipFile(source) as z:
                matches=[i for i in z.infolist() if i.filename.casefold()==member.casefold()]
                if len(matches)!=1:continue
                info=matches[0]
                if not 0<info.file_size<=4*1024*1024:continue
                with z.open(info) as stream:data=stream.read(4*1024*1024+1)
                if len(data)!=info.file_size:raise ValueError('Incomplete/oversized payload')
            after=source.stat()
            if (stamp.st_size,stamp.st_mtime_ns,stamp.st_ino)!=(after.st_size,after.st_mtime_ns,after.st_ino):raise ValueError('Original archive changed')
            if hashlib.sha256(data).hexdigest()!=expected['sha256']:raise ValueError('Previous sampled payload identity differs')
            # The stored extension is retained only when it is a simple suffix.
            ext=candidate['extension']
            if not ext[1:].isascii() or not ext[1:].isalnum():ext='.unknown'
            target=root/('source-'+str(candidate['book_id'])+ext);target.write_bytes(data)
            return target,dict(archive=str(source),member=info.filename,source_sha256=expected['sha256'])
        except (OSError,ValueError,zipfile.BadZipFile,NotImplementedError) as error:errors.append(str(error))
    raise ValueError('No exact bounded ZIP payload: '+'; '.join(errors[-2:]))

def run(args):
    stage=owned_g(args.stage);stage.mkdir(parents=True,exist_ok=True);reserve(stage)
    destination=stage/'report.json'
    if destination.exists():raise ValueError('Refuse to overwrite evidence')
    plan=load(args.plan);inventory=load(args.inventory);samples=load(args.samples)
    report=dict(status='RUNNING',scope=__doc__,platform=plan['platform'],rows=[],pending=[],input_sha256={str(p):sha(p) for p in [args.plan,args.inventory,args.samples,Path(__file__)]})
    def save():destination.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    save();raw=None
    try:
        with tempfile.TemporaryDirectory(prefix='runtime-',dir=stage) as raw:
            root=Path(raw).resolve()
            if root.parent!=stage or not root.name.startswith('runtime-'):raise ValueError('Invalid owned runtime')
            report['runtime']=prepare_runtime(root,plan,args.helpers);save()
            python=root/'tools/python/python.exe';script=root/'tools/bookconvert/convert_book.py'
            spec=importlib.util.spec_from_file_location('matrix_api',REPO/'tools/bookconvert/convert_book.py')
            api=importlib.util.module_from_spec(spec);spec.loader.exec_module(api)
            seen=set();requested=set(args.detected or [])
            for sample in samples['results']:
                detected=sample.get('detected')
                if requested and detected not in requested:continue
                if sample['status']!='sampled' or detected not in api.BOOK_EPUB_INPUTS:
                    report['pending'].append(dict(extension=sample['extension'],reason='Needs native preparation, nonbook classification or an accessible sample'));continue
                if detected in seen:continue
                seen.add(detected)
                candidates=[r for r in inventory['representative_candidates'] if r['book_id']==sample['book_id']]
                row=dict(id=sample['book_id'],recorded_extension=sample['extension'],detected=detected,operations=[])
                report['rows'].append(row)
                try:
                    if len(candidates)!=1:raise ValueError('Ambiguous candidate identity')
                    source,origin=extract_sample(candidates[0],sample,root);row['origin']=origin
                except ValueError as error:
                    row.update(status='PENDING_SOURCE',error=str(error));save();continue
                for name,suffix,profile in OUTPUTS:
                    if name=='pdf' and detected=='.pdf':
                        row['operations'].append(dict(target=name,status='NATIVE_IDENTITY_PATH_PENDING'));continue
                    reserve(root);work=root/(str(sample['book_id'])+'-'+name);work.mkdir()
                    output=work/('copy'+suffix);details=work/'report.json'
                    command=[str(python),'-I','-B','-X','utf8',str(script),str(source),str(output),'--tools-root',str(root/'tools'),'--report',str(details)]
                    if profile:command+=['--output-profile',profile]
                    started=time.monotonic()
                    try:
                        completed=subprocess.run(command,cwd=root,timeout=180,capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW,
                            env={**os.environ,'TEMP':str(root),'TMP':str(root),'LOCALAPPDATA':str(root/'local')})
                        result=load(details) if details.exists() else {}
                        good=completed.returncode==0 and output.is_file() and output.stat().st_size>0
                        op=dict(target=name,status='PASS_BACKEND' if good else 'FAIL',result=result,
                            diagnostic=(completed.stdout+completed.stderr).decode('utf-8',errors='replace')[-2500:])
                        if good:op.update(bytes=output.stat().st_size,sha256=sha(output))
                    except subprocess.TimeoutExpired:op=dict(target=name,status='TIMEOUT')
                    op['seconds']=round(time.monotonic()-started,3);row['operations'].append(op)
                    if sha(source)!=sample['sha256']:raise ValueError('Conversion changed the source')
                    save();print(plan['platform'],detected,name,op['status'],flush=True)
                row['status']='GAPS_FOUND' if any(o['status'] in {'FAIL','TIMEOUT'} for o in row['operations']) else 'BACKEND_PROBED'
                source.unlink();save()
            if requested-seen:raise ValueError('Requested input families were not exercised: '+str(sorted(requested-seen)))
            if not any(row['operations'] for row in report['rows']):
                raise ValueError('No actual conversions were exercised')
            report['status']='GAPS_FOUND' if any(r['status']=='GAPS_FOUND' for r in report['rows']) else 'BACKEND_PROBED'
    except Exception as error:
        report.update(status='HARNESS_OR_RUNTIME_ERROR',error=str(error));raise
    finally:
        report['private_runtime_removed']=raw is None or not Path(raw).exists();save()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ['plan','inventory','samples','helpers','stage']:parser.add_argument('--'+key,type=Path,required=True)
    parser.add_argument('--detected',nargs='+',help='Optional explicit detected families for targeted fix regressions')
    run(parser.parse_args())

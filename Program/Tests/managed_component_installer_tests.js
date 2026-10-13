'use strict';
// Real component archives and native installer; targets are isolated under TEMP.
const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const cp=require('node:child_process'), crypto=require('node:crypto'), assert=require('node:assert/strict');
const [testerArg,packageArg,python='python']=process.argv.slice(2);
const tester=path.resolve(testerArg), packages=path.resolve(packageArg);
const binary=fs.readFileSync(tester), platform=binary.readUInt16LE(binary.readUInt32LE(0x3c)+4)===0x8664?'Win64':'Win32';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'HomeLibRu-update-test-managed-'));
const ids=['SQLite','AlReader','SumatraPDF','DjVuLibre','7-Zip','DocSharp'];
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const read=p=>fs.readFileSync(p), json=p=>JSON.parse(read(p).toString('utf8').replace(/^\uFEFF/,''));
let number=0, count=0;
const next=label=>path.join(root,label+'-'+number++);
const pass=label=>{count++;console.log('PASS '+label);};
function run(args,status=0) {
  const result=cp.spawnSync(tester,args,{encoding:'utf8',windowsHide:true,timeout:30000});
  assert.ifError(result.error);assert.equal(result.status,status,result.stdout+result.stderr);return result.stdout;
}
function pythonRun(code,args=[],input) {
  const result=cp.spawnSync(python,['-X','utf8','-c',code,...args],{input,encoding:'utf8',windowsHide:true,maxBuffer:40*1024*1024});
  assert.ifError(result.error);assert.equal(result.status,0,result.stderr);return result.stdout;
}
const archives=Object.fromEntries(ids.map(id=>[id,path.join(packages,`HomeLibRu-${id}-${platform}.zip`)]));
const loadZip=zip=>JSON.parse(pythonRun('import sys,json,zipfile,base64\nwith zipfile.ZipFile(sys.argv[1]) as z: print(json.dumps([[n,base64.b64encode(z.read(n)).decode()] for n in z.namelist() if not n.endswith("/")]))',[zip])).map(([n,b])=>[n,Buffer.from(b,'base64')]);
const entries=Object.fromEntries(ids.map(id=>[id,loadZip(archives[id])]));
const manifests=Object.fromEntries(ids.map(id=>[id,JSON.parse(entries[id].find(e=>e[0]==='HomeLibRu.update.json')[1].toString('utf8').replace(/^\uFEFF/,''))]));
for(const id of ids) {
  assert.equal(manifests[id].component,id);assert.equal(manifests[id].platform,platform);
  for(const file of manifests[id].files) {
    const bytes=entries[id].find(e=>e[0]===file.path)?.[1];assert(bytes,file.path);
    assert.equal(bytes.length,file.size);assert.equal(sha(bytes),file.sha256);
  }
}
const tag=manifests.DocSharp.release;
const personal={'myhomelib2.ini':'personal theme and reader settings','Data/collections.db':'personal collection',
  'Data/reader-history.json':'reading position','Data/reader-notes.json':'thoughts and quotations',
  'Data/books/book.fb2':'personal book','presets.cxml2':'personal filters','uselocaldata':'',
  'Readers/AlReader/options.ini':'external reader options','Readers/AlReader/$savevtut.ini':'existing portable marker',
  'Readers/SumatraPDF/SumatraPDF-settings.txt':'external history'};
function write(rootDir,name,bytes) {const p=path.join(rootDir,name);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,bytes);}
function target() {const p=next('installation');write(p,'HomeLibRu.exe',binary);for(const [name,bytes] of Object.entries(personal))write(p,name,bytes);return p;}
const snapshot=p=>Object.fromEntries(['HomeLibRu.exe',...Object.keys(personal)].map(name=>[name,sha(read(path.join(p,name)))]));
function prepare(id,zip=archives[id],status=0) {const job=next('job');run(['--prepare-component',zip,sha(read(zip)),tag,job,id,manifests[id].version],status);return job;}
function verifyPayload(id,p) {for(const file of manifests[id].files) {
  if(file.path==='Readers/AlReader/$savevtut.ini')continue;
  assert.equal(sha(read(path.join(p,file.path))),file.sha256,file.path);
}}
function alteredArchive(id,mutate) {
  let altered=entries[id].filter(e=>e[0]!=='HomeLibRu.update.json').map(([n,b])=>[n,Buffer.from(b)]);
  const manifest=structuredClone(manifests[id]);mutate(manifest,altered);
  manifest.files=altered.map(([name,data])=>({path:name,size:data.length,sha256:sha(data)}));
  altered.push(['HomeLibRu.update.json',Buffer.from(JSON.stringify(manifest))]);
  const zip=next('altered')+'.zip';
  pythonRun('import sys,json,zipfile,base64\nwith zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:\n for n,b in json.load(sys.stdin): z.writestr(n,base64.b64decode(b))',[zip],JSON.stringify(altered.map(([n,b])=>[n,b.toString('base64')])));
  return zip;
}
function bumpVersion(bytes) {
  const result=Buffer.from(bytes),fixed=result.indexOf(Buffer.from([0xbd,0x04,0xef,0xfe]));assert(fixed>=0);
  result.writeUInt32LE(99<<16,fixed+8);result.writeUInt32LE(0,fixed+12);return result;
}
function clrOffset(data) {
  const pe=data.readUInt32LE(0x3c), opt=data.readUInt16LE(pe+20), rva=data.readUInt32LE(pe+24+96+14*8);
  for(let i=0;i<data.readUInt16LE(pe+6);i++) {const s=pe+24+opt+i*40,va=data.readUInt32LE(s+12),size=data.readUInt32LE(s+16);
    if(rva>=va && rva-va+72<=size)return data.readUInt32LE(s+20)+rva-va;
  }throw Error('No CLR fixture header');
}
async function lockedFile(file,job,p,before) {
  const child=cp.spawn(tester,['--holdfile',file],{windowsHide:true});
  const done=new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',code=>code===0?resolve():reject(Error('lock helper exit '+code)));});
  const marker=file+'.locked';for(let i=0;!fs.existsSync(marker)&&i<100;i++)await new Promise(r=>setTimeout(r,25));
  assert(fs.existsSync(marker),'Native exclusive lock was not obtained');
  run(['--install',job,p],1);assert.deepEqual(snapshot(p),before);await done;
  run(['--install',job,p]);
}
async function main() {
  const jobs={};
  for(const id of ids) {
    jobs[id]=prepare(id);const p=target(),before=snapshot(p);
    run(['--install',jobs[id],p]);verifyPayload(id,p);assert.deepEqual(snapshot(p),before);
    run(['--install',jobs[id],p]);assert.deepEqual(snapshot(p),before);
    pass(id+' complete installation and repeat preserve books, notes, settings and history');
  }
  for(const [id,missing] of [['DocSharp','tools/doc/DocSharp.Binary.Common.dll'],['7-Zip','tools/7zip/7z.dll'],['DjVuLibre','tools/djvu/libdjvulibre.dll']]) {
    prepare(id,alteredArchive(id,(m,e)=>e.splice(e.findIndex(x=>x[0]===missing),1)),1);
    pass(id+' incomplete runtime rejected before installation');
  }
  prepare('DocSharp',alteredArchive('DocSharp',(m,e)=>{const item=e.find(x=>x[0]==='tools/doc/DocSharp.Binary.Common.dll');item[1]=bumpVersion(item[1]);}),1);
  pass('mismatched DocSharp assembly versions rejected');
  for(const flags of [2,0x20000]) {
    prepare('DocSharp',alteredArchive('DocSharp',(m,e)=>{const data=e.find(x=>x[0]==='tools/doc/HomeLibDoc.exe')[1];data.writeUInt32LE(1|flags,clrOffset(data)+16);}),1);
  }pass('32-bit-only and prefer-32-bit DOC helpers rejected for both distributions');
  prepare('DocSharp',alteredArchive('DocSharp',(m,e)=>{const data=e.find(x=>x[0]==='tools/doc/DocSharp.Binary.Doc.dll')[1];data.writeUInt32LE(0,data.readUInt32LE(0x3c)+24+96+14*8);}),1);
  pass('DOC library without managed CLR header rejected');
  prepare('DjVuLibre',alteredArchive('DjVuLibre',(m,e)=>{const item=e.find(x=>x[0]==='tools/djvu/RUNTIME.json');const value=JSON.parse(item[1].toString('utf8').replace(/^\uFEFF/,''));value.djvu.files['djvused.exe']='a'.repeat(64);item[1]=Buffer.from(JSON.stringify(value));}),1);
  pass('DjVu runtime identity cannot be asserted with a mismatched executable hash');
  for(const id of ['DocSharp','7-Zip','DjVuLibre']) {
    const p=target(),before=snapshot(p),job=prepare(id);
    write(p,manifests[id].files[0].path,Buffer.from('old runtime file'));
    const original=sha(read(path.join(p,manifests[id].files[0].path)));
    run(['--install',job,p,'1'],1);assert.deepEqual(snapshot(p),before);
    assert.equal(sha(read(path.join(p,manifests[id].files[0].path))),original);
    for(const f of manifests[id].files.slice(1))assert(!fs.existsSync(path.join(p,f.path)),f.path);
    assert.equal(json(path.join(job,'journal.json')).state,'rolled-back');
    pass(id+' mid-install failure restores old runtime and removes new runtime files');
  }
  for(const [id,name] of [['DocSharp','tools/doc/DocSharp.Binary.Common.dll'],['7-Zip','tools/7zip/7z.dll'],['DjVuLibre','tools/djvu/libdjvulibre.dll']]) {
    const p=target(),job=prepare(id);for(const [n,b] of entries[id])if(n!=='HomeLibRu.update.json')write(p,n,b);
    await lockedFile(path.join(p,name),job,p,snapshot(p));verifyPayload(id,p);
    pass(id+' locked dependency aborts without changes; retry succeeds after release');
  }
  for(const id of ['DocSharp','7-Zip','DjVuLibre']) {
    const p=target();for(const [n,b] of entries[id])if(n!=='HomeLibRu.update.json')write(p,n,b);
    if(id==='DocSharp')for(const name of ['tools/doc/DocSharp.Binary.Doc.dll','tools/doc/DocSharp.Binary.Common.dll'])write(p,name,bumpVersion(read(path.join(p,name))));
    if(id==='7-Zip')for(const name of ['tools/7zip/7z.exe','tools/7zip/7z.dll'])write(p,name,bumpVersion(read(path.join(p,name))));
    if(id==='DjVuLibre') {const n='tools/djvu/RUNTIME.json',value=json(path.join(p,n));value.djvu.version='99.0.0';write(p,n,JSON.stringify(value));}
    const kept=manifests[id].files.map(f=>sha(read(path.join(p,f.path)))),before=snapshot(p);
    run(['--install',prepare(id),p]);assert.deepEqual(snapshot(p),before);
    assert.deepEqual(manifests[id].files.map(f=>sha(read(path.join(p,f.path)))),kept);
    pass(id+' newer installed version keeps the entire runtime without downgrade');
  }
  const batch=next('batch');run(['--combine',batch,tag,...ids.map(id=>jobs[id])]);
  assert.equal(json(path.join(batch,'manifest.json')).bundle.length,6);
  const p=target(),before=snapshot(p);run(['--install',batch,p]);assert.deepEqual(snapshot(p),before);
  for(const id of ids)verifyPayload(id,p);pass('all six components install atomically together while personal files remain unchanged');
  const failed=next('batch');run(['--combine',failed,tag,...ids.map(id=>jobs[id])]);
  const failedTarget=target(),failedBefore=snapshot(failedTarget);run(['--install',failed,failedTarget,'12'],1);
  assert.deepEqual(snapshot(failedTarget),failedBefore);assert.equal(json(path.join(failed,'journal.json')).state,'rolled-back');
  for(const id of ids)for(const f of manifests[id].files)if(!Object.hasOwn(personal,f.path))assert(!fs.existsSync(path.join(failedTarget,f.path)),f.path);
  pass('six-component transaction failure restores all personal files and removes partial components');
  run(['--combine',next('duplicate'),tag,jobs.DocSharp,jobs.DocSharp],1);
  pass('duplicate DOC component cannot enter an installation transaction');
  console.log(`PASS ${count} managed component scenarios (${platform}); retained ${root}`);
}
main().catch(error=>{console.error(error.stack);console.error('Retained '+root);process.exitCode=1;});

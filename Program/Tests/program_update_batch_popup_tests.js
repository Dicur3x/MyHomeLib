'use strict';
// Offline native popup and installer tests. Every installation and archive is
// newly created in TEMP, and HTTP serves only these fixtures over loopback.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process'),http=require('node:http');
const crypto=require('node:crypto'),assert=require('node:assert/strict');
const [viewsArg,testArg,runtimeArg,python='python']=process.argv.slice(2),runtime=path.resolve(runtimeArg);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'HomeLibRu-native-HomeLibRu-update-test-batch-popup-'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const app=fs.readFileSync(path.resolve(testArg)),platform=app.readUInt16LE(app.readUInt32LE(0x3c)+4)===0x8664?'Win64':'Win32';
const before=Buffer.from('2.7.0_pre5.11','utf16le'),after=Buffer.from('2.7.0_pre5.14','utf16le');
let n=app.indexOf(before),replaced=0;
while(n>=0){after.copy(app,n);replaced++;n=app.indexOf(before,n+before.length);}assert(replaced>0);
function zip(name,entries,component){
 const manifest={format:1,release:'2.7.0_pre5.14',platform,files:entries.map(([p,b])=>({path:p,size:b.length,sha256:sha(b)}))};
 if(component){manifest.component=component;manifest.version='9.0.0.0';}
 entries.push(['HomeLibRu.update.json',Buffer.from(JSON.stringify(manifest))]);
 const target=path.join(root,name+'.zip');
 const result=cp.spawnSync(python,['-c','import sys,json,zipfile,base64\nwith zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:\n for n,d in json.load(sys.stdin): z.writestr(n,base64.b64decode(d))',target],{
  input:JSON.stringify(entries.map(([p,b])=>[p,b.toString('base64')])),encoding:'utf8',windowsHide:true});
 assert.equal(result.status,0,result.stderr);return fs.readFileSync(target);
}
const payloads={app:zip('app',[['HomeLibRu.exe',app],['LICENSE',Buffer.from('fixture license')],['NOTICE',Buffer.from('fixture notice')]])};
const componentFiles={SQLite:'sqlite3.dll',SumatraPDF:'Readers/SumatraPDF/SumatraPDF.exe'},expected={};
for(const [id,file] of Object.entries(componentFiles)){
 const b=fs.readFileSync(path.join(runtime,file)),offset=b.indexOf(Buffer.from([0xbd,0x04,0xef,0xfe]));assert(offset>=0);
 b.writeUInt32LE(9<<16,offset+8);b.writeUInt32LE(0,offset+12);expected[id]=b;
 payloads[id]=zip(id,[[file,b]],id);
}
function stage(scenario){
 const folder=path.join(root,'HomeLibRu-native-'+scenario);fs.mkdirSync(folder);
 fs.copyFileSync(path.resolve(viewsArg),path.join(folder,'HomeLibRu.exe'));
 for(const name of ['sqlite3.dll','libzstd.dll','libeay32.dll','ssleay32.dll','homelib_webp.dll','HomeLibRuUpdater.exe'])
  if(fs.existsSync(path.join(runtime,name)))fs.copyFileSync(path.join(runtime,name),path.join(folder,name));
 fs.mkdirSync(path.join(folder,'tools/webp'),{recursive:true});fs.copyFileSync(path.join(runtime,'tools/webp/libwebp.dll'),path.join(folder,'tools/webp/libwebp.dll'));
 fs.mkdirSync(path.join(folder,'Readers/SumatraPDF'),{recursive:true});fs.copyFileSync(path.join(runtime,componentFiles.SumatraPDF),path.join(folder,componentFiles.SumatraPDF));
 if(fs.existsSync(path.join(runtime,'Icons')))fs.cpSync(path.join(runtime,'Icons'),path.join(folder,'Icons'),{recursive:true});
 for(const name of fs.readdirSync(runtime))if(/^genres.*\.glst$/i.test(name))fs.copyFileSync(path.join(runtime,name),path.join(folder,name));
 fs.copyFileSync(path.resolve(__dirname,'../../Installer/Components.json'),path.join(folder,'COMPONENTS.json'));
 for(const name of ['uselocaldata','uselocaltemp'])fs.writeFileSync(path.join(folder,name),'');
 fs.writeFileSync(path.join(folder,'native-regression.marker'),'HomeLib Ru isolated native regression v1');
 fs.writeFileSync(path.join(folder,'myhomelib2.ini'),'[SYSTEM]\r\nCheckUpdates=0\r\nCheckLibrusecUpdates=0\r\n[INTERFACE]\r\nLocale=ru\r\n[BEHAVIOR]\r\nCoverPanel=0\r\nShowCover=0\r\nShowAnnotation=0\r\nAutoLoadReview=0\r\nIgnoreAbsentArchives=1\r\n[OPDS]\r\nEnabled=0\r\n');
 return folder;
}
async function test(scenario){
 const folder=stage(scenario),requests=[];
 const cacheRoot=fs.mkdtempSync(path.join(os.tmpdir(),'HomeLibRu-update-test-cache-'));
 const server=http.createServer((req,res)=>{
  const id=req.url.slice(1);requests.push(id);
  if(scenario==='failure'&&id==='SQLite'){res.writeHead(500);res.end('fixture failure');return;}
  const payload=payloads[id];if(!payload){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Length':payload.length});let index=0;
  const timer=setInterval(()=>{res.write(payload.subarray(index,index+65536));index+=65536;
   if(index>=payload.length){clearInterval(timer);res.end();}},5);res.on('close',()=>clearInterval(timer));
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{
  const base='http://127.0.0.1:'+server.address().port;
  const descriptor=path.join(folder,'component-fixtures.json');
  fs.writeFileSync(descriptor,JSON.stringify(Object.keys(componentFiles).map(id=>({id,url:base+'/'+id,size:payloads[id].length,sha256:sha(payloads[id])}))));
  const args=['program-update-download',base+'/app',String(payloads.app.length),sha(payloads.app),descriptor,scenario];
  const child=cp.spawn(path.join(folder,'HomeLibRu.exe'),args,{cwd:folder,windowsHide:true,
    env:{...process.env,LOCALAPPDATA:cacheRoot}});let output='';
  child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
  const timer=setTimeout(()=>child.kill(),120000);
  const status=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',resolve);});clearTimeout(timer);
  console.log(output);assert.equal(status,0,output);
  if(scenario==='failure'){
   assert.match(output,/PASS failed component download/);assert.deepEqual(requests,['app','SQLite']);
   assert.deepEqual(fs.readFileSync(path.join(folder,'HomeLibRu.exe')),fs.readFileSync(path.resolve(viewsArg)));
   assert.deepEqual(fs.readFileSync(path.join(folder,'sqlite3.dll')),fs.readFileSync(path.join(runtime,'sqlite3.dll')));
  }else{
   assert.deepEqual(requests,scenario==='components'?['SQLite','SumatraPDF']:['app','SQLite','SumatraPDF']);
   if(scenario==='components'){
    assert.match(output,/PASS component batch download restores/);
    const readyFiles=[];function find(dir){for(const item of fs.readdirSync(dir,{withFileTypes:true})){
      const p=path.join(dir,item.name);if(item.isDirectory())find(p);else if(item.name==='ready.json')readyFiles.push(p);}}
    find(cacheRoot);assert.equal(readyFiles.length,1);
    const ready=JSON.parse(fs.readFileSync(readyFiles[0],'utf8').replace(/^\uFEFF/,''));assert.equal(ready.component,'batch');
    const result=cp.spawnSync(path.resolve(testArg),['--install',ready.job,folder],{encoding:'utf8',windowsHide:true,timeout:25000});
    assert.equal(result.status,0,result.stdout+result.stderr);
    assert.deepEqual(fs.readFileSync(path.join(folder,'HomeLibRu.exe')),fs.readFileSync(path.resolve(viewsArg)));
   }else{
    for(let i=0;i<150&&!fs.existsSync(path.join(folder,'update-restarted.txt'));i++)await new Promise(r=>setTimeout(r,100));
    assert(fs.existsSync(path.join(folder,'update-restarted.txt')),'Combined installation did not restart');
    assert.deepEqual(fs.readFileSync(path.join(folder,'HomeLibRu.exe')),app);
   }
   for(const [id,file] of Object.entries(componentFiles))assert.deepEqual(fs.readFileSync(path.join(folder,file)),expected[id]);
   assert(fs.existsSync(path.join(folder,'Data')));assert(fs.existsSync(path.join(folder,'myhomelib2.ini')));
  }
  console.log('PASS native batch popup '+scenario+' ('+platform+')');
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
}
(async()=>{for(const scenario of ['all','components','failure'])await test(scenario);console.log('PASS all batch popup scenarios; fixtures: '+root);})().catch(e=>{console.error(e.stack);process.exitCode=1;});

'use strict';
// Offline by default: production parsers and controlled author checks only.
// --live-check explicitly opts into public metadata requests (no downloads).
// --install-fixtures opts into the separate historical archive installer checks.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process');
const crypto=require('node:crypto'),assert=require('node:assert/strict'),http=require('node:http');
const args=process.argv.slice(2),[exeArg,officialArg]=args.filter(a=>!a.startsWith('--'));
assert(exeArg,'Usage: node component_updates_tests.js <ProgramUpdateInstallerTest.exe> [official-fixture-dir] [--live-check] [--install-fixtures] [--work-dir=dir]');
const exe=path.resolve(exeArg),official=officialArg?path.resolve(officialArg):null;
const live=args.includes('--live-check'),install=args.includes('--install-fixtures');
const workArg=args.find(a=>a.startsWith('--work-dir='));
const workDir=workArg?path.resolve(workArg.slice('--work-dir='.length)):os.tmpdir();
fs.mkdirSync(workDir,{recursive:true});
const root=fs.mkdtempSync(path.join(workDir,'HomeLibRu-update-test-components-'));
const childEnv={...process.env,TEMP:workDir,TMP:workDir};
const bytes=fs.readFileSync(exe),platform=bytes.readUInt16LE(bytes.readUInt32LE(0x3c)+4)===0x8664?'Win64':'Win32';
const arch=platform==='Win64'?'x64':'x86';let count=0;
function run(args,expected=0){const r=cp.spawnSync(exe,args,{encoding:'utf8',windowsHide:true,timeout:120000,env:childEnv});assert.ifError(r.error);assert.equal(r.status,expected,r.stdout+r.stderr);return r.stdout;}
function first(args){return JSON.parse(run(args).split('\n')[0]);}
function pass(s){++count;console.log('PASS '+s);}
for(const size of [0,1,3,135,136,137,271,272,273,1024*1024+1]){
  const data=crypto.randomBytes(size),file=path.join(root,'vector-'+size);fs.writeFileSync(file,data);
  assert.equal(run(['--sha3',file]).split(/\r?\n/)[0],crypto.createHash('sha3-256').update(data).digest('hex'));
}pass('SHA3-256 agrees with independent implementation across rate boundaries and streaming');
async function main(){
const sqliteDownload=path.join(root,'sqlite-download.html'),sqliteChanges=path.join(root,'sqlite-changes.html');
fs.writeFileSync(sqliteDownload,`PRODUCT,3.53.4,2026/sqlite-dll-win-${arch}-3530400.zip,1234567,${'a'.repeat(64)}`);
fs.writeFileSync(sqliteChanges,'<h3>2026-07-24 (3.53.4)</h3><ul><li>Owned fix.</li></ul><h3>2026-06-01 (3.53.3)</h3><p>Older release.</p>');
if(install&&official){fs.copyFileSync(path.join(official,'sqlite-download.html'),sqliteDownload);fs.copyFileSync(path.join(official,'sqlite-changes.html'),sqliteChanges);}
const sqlite=first(['--sqlite-parse',sqliteDownload,sqliteChanges,'3.53.3']);
assert.equal(sqlite[0],'3.53.4');assert.match(sqlite[1],new RegExp('/sqlite-dll-win-'+arch+'-3530400\\.zip$'));
assert.equal(sqlite[2].length,64);assert(sqlite[3]>1000000);assert.match(sqlite[4],/^3\.53\.4 \u2014 24\.07\.2026\r?$/m);assert.doesNotMatch(sqlite[4],/^3\.53\.3(?: \u2014 [^\r\n]+)?\r?$/m);
pass('official SQLite metadata chooses running architecture and combines only missed changelog');
const badHTML=path.join(root,'bad.html');fs.writeFileSync(badHTML,'PRODUCT,3.53.4,https://evil.example/sqlite.zip,123,'+'a'.repeat(64));
run(['--sqlite-parse',badHTML,sqliteChanges],1);pass('SQLite parser refuses foreign or malformed archives');
const sumatraJSON=path.join(root,'sumatra.json');
fs.writeFileSync(sumatraJSON,JSON.stringify([{tag_name:'3.7',prerelease:true,body:'unstable'},
  {tag_name:'3.5.2rel',body:'older'},{tag_name:'3.6.1rel',body:'Bugfixes.'},
  {tag_name:'4.0',draft:true,body:'hidden'}]));
const sumatra=first(['--sumatra-parse',sumatraJSON,'-','3.5.2']);
assert.equal(sumatra[0],'3.6.1');assert.match(sumatra[1],new RegExp('/SumatraPDF-3.6.1'+(arch==='x64'?'-64':'')+'\\.zip$'));
assert.match(sumatra[4],/Bugfixes/);assert.doesNotMatch(sumatra[4],/older|unstable|hidden/);
assert.match(sumatra[5],/Bugfixes[\s\S]*older/);
pass('Sumatra parser chooses stable official archive and excludes drafts and prereleases');
if(install){
assert(official,'--install-fixtures requires an official archive fixture directory');
for(const [id,filename,version] of [['SQLite','sqlite-'+arch+'.zip','3.53.4'],['SumatraPDF','sumatra-'+arch+'.zip','3.6.1']]){
  const job=path.join(root,'HomeLibRu-update-'+id),target=path.join(root,'target-'+id);fs.mkdirSync(target);
  fs.writeFileSync(path.join(target,'myhomelib2.ini'),'personal');fs.writeFileSync(path.join(target,'HomeLibRu.exe'),bytes);
  fs.mkdirSync(path.join(target,'Readers/SumatraPDF'),{recursive:true});fs.writeFileSync(path.join(target,'Readers/SumatraPDF/SumatraPDF-settings.txt'),'history');
  run(['--official-prepare',path.join(official,filename),job,id,version]);
  const manifest=JSON.parse(fs.readFileSync(path.join(job,'manifest.json'),'utf8').replace(/^\uFEFF/,''));
  assert.equal(manifest.component,id);assert.equal(manifest.version,version);assert.equal(manifest.official,true);
  if(id==='SQLite')assert.equal(run(['--sha3',path.join(official,filename)]).split(/\r?\n/)[0],sqlite[2]);
  if(id==='SumatraPDF'){
    const file=path.join(job,'payload/Readers/SumatraPDF/SumatraPDF.exe');run(['--signature',file]);
    const tampered=path.join(root,'tampered.exe'),data=fs.readFileSync(file);data[4096]^=1;fs.writeFileSync(tampered,data);run(['--signature',tampered],1);
  }
  run(['--install',job,target]);assert.equal(fs.readFileSync(path.join(target,'myhomelib2.ini'),'utf8'),'personal');
  assert.equal(fs.readFileSync(path.join(target,'Readers/SumatraPDF/SumatraPDF-settings.txt'),'utf8'),'history');
  assert.deepEqual(fs.readFileSync(path.join(target,'HomeLibRu.exe')),bytes);pass('official '+id+' archive verifies identity and installs without changing application or history');
}
}
const ids=['SQLite','AlReader','SumatraPDF','DjVuLibre','7-Zip','DocSharp'];
let redirectHead=false;const unexpected=[];
const server=http.createServer((req,res)=>{
 if(req.url!=='/head'||req.method!=='HEAD'){unexpected.push(req.method+' '+req.url);res.writeHead(404);res.end();return;}
 if(redirectHead){res.writeHead(302,{'Location':'/forbidden-redirect'});res.end();return;}
 res.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':'128'});res.end();
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const headURL=`http://127.0.0.1:${server.address().port}/head`;
function fixture(failure){return new Promise((resolve,reject)=>{
 const child=cp.spawn(exe,['--component-check-fixture',headURL,failure],{windowsHide:true,env:childEnv});let out='',err='';
 const timeout=setTimeout(()=>{child.kill();reject(Error('Controlled component check timed out'));},15000);
 child.stdout.on('data',b=>out+=b.toString('utf8'));child.stderr.on('data',b=>err+=b.toString('utf8'));
 child.on('error',reject);child.on('close',code=>{clearTimeout(timeout);try{assert.equal(code,0,out+err);resolve({rows:JSON.parse(out.split(/\r?\n/)[0]),out});}catch(e){reject(e);}});
});}
function healthy(rows,failed=''){
 assert.deepEqual(rows.map(r=>r.id),ids);
 for(const row of rows){
  if(row.id===failed || failed==='all'){
   assert(row.error,row.id);assert.equal(row.url,'');assert.equal(row.warning,'');
   assert(row.details.length<=4096);assert(row.details.includes('Fixture HTTP 503'));
   assert(!row.error.includes('<html>')&&!row.error.includes('secret'),row.error);continue;
  }
  if(row.id==='AlReader'){
   assert.equal(row.url,'');assert.equal(row.error,'');assert(row.warning);assert.equal(row.size,0);continue;
  }
  assert.equal(row.error,'',row.id+': '+row.error);assert.equal(row.warning,'');
  assert.equal(row.official,true,row.id);assert.equal(row.checkOnly,false,row.id);assert(row.size>0,row.id);
  run(['--official-url',row.id,row.version,row.url]);
  if(row.secondary)run(['--official-url',row.id,row.version,row.secondary,'secondary']);
 }
 assert.equal(rows[5].additional.length,failed==='DocSharp'||failed==='all'?0:2);
}
try{
 for(const forbidden of ['http://localhost:80/head','https://127.0.0.1:80/head',
  headURL.replace('/head','/head?foreign=1'),headURL.replace('/head','@evil.example/head'),
  headURL.replace('127.0.0.1','127.0.0.1.evil.example')])run(['--component-check-fixture',forbidden,''],1);
 pass('fixture transport rejects foreign hosts, credentials, alternate schemes and paths before making requests');
 const success=await fixture('');healthy(success.rows);
 assert(success.out.includes('https://www.alreader.com/'),'AlReader was silently skipped');
 assert.equal(success.rows[3].size,256);assert.equal(success.rows[5].size,512);
 pass('controlled official checks include AlReader and offer architecture-matched direct DjVu, 7-Zip and all four DocSharp packages');
 const unavailable=await fixture('all');healthy(unavailable.rows,'all');
 pass('unavailable author sources retain six bounded errors without stale install URLs or raw server details in messages');
 const partial=await fixture('SumatraPDF');healthy(partial.rows,'SumatraPDF');
 pass('one unavailable author does not remove independent verified component updates');
 const incomplete=await fixture('DocSharp-head');healthy(incomplete.rows,'DocSharp');
 assert.equal(incomplete.rows[5].secondary,'');assert.equal(incomplete.rows[5].size,0);assert.equal(incomplete.rows[5].official,false);
 pass('unavailable package HEAD removes the whole incomplete DocSharp package set before it can enter installation');
 const retried=await fixture('');healthy(retried.rows);
 pass('retry replaces failed metadata and restores the direct package without inheriting the previous error');
 redirectHead=true;
 const redirected=await fixture('');
 for(const i of [2,3,5]){assert(redirected.rows[i].error);assert.equal(redirected.rows[i].url,'');}
 assert.deepEqual(unexpected,[]);
 pass('direct loopback fixture refuses HEAD redirects and never requests any other host, port or path');
}finally{await new Promise(resolve=>server.close(resolve));}
if(live){
 const rows=first(['--official-check-details']);assert.deepEqual(rows.map(r=>r.id),ids);
 for(const row of rows){
  if(row.error){assert.equal(row.url,'');console.log('LIVE unavailable '+row.id+': '+row.error);continue;}
  if(row.warning){assert.equal(row.id,'AlReader');assert.equal(row.url,'');console.log('LIVE unverified AlReader: '+row.warning);continue;}
  assert(row.official&&!row.checkOnly&&row.size>0,row.id);run(['--official-url',row.id,row.version,row.url]);
  if(row.secondary)run(['--official-url',row.id,row.version,row.secondary,'secondary']);
 }
 pass('opt-in live metadata reports current direct author packages and explicit unavailable or unverified sources');
}
const raster=path.join(root,'raster.json');
fs.writeFileSync(raster,JSON.stringify({tag_name:'26.04',body:'Official release.',draft:false,prerelease:false}));
assert.equal(first(['--raster-parse',raster,'7-Zip'])[0],'26.04');
for(const change of [{draft:true},{prerelease:true},{tag_name:'26.04/evil'}]){
  fs.writeFileSync(raster,JSON.stringify({tag_name:'26.04',...change}));run(['--raster-parse',raster,'7-Zip'],1);
}
fs.writeFileSync(raster,'/projects/djvu/files/DjVuLibre/3.5.99/ /projects/djvu/files/DjVuLibre_Windows/3.5.28%2B4.11/ /projects/djvu/files/DjVuLibre_Windows/3.5.29+4.12/');
assert.equal(first(['--raster-parse',raster,'DjVuLibre'])[0],'3.5.29');
fs.writeFileSync(raster,'/projects/djvu/files/DjVuLibre/3.5.99/');run(['--raster-parse',raster,'DjVuLibre'],1);
pass('raster checks reject drafts, prereleases, malformed versions and source-only DjVu releases');
console.log('PASS TOTAL '+count+' ('+platform+'); isolated fixtures: '+root);
}
main().catch(error=>{console.error('FAIL',error);process.exitCode=1;});

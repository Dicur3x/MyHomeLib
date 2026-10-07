'use strict';
// Exercises the production component parsers, SHA3, publisher checks and installers
// against tiny metadata fixtures and official archives, in an isolated TEMP root.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process');
const crypto=require('node:crypto'),assert=require('node:assert/strict');
const [exeArg,officialArg]=process.argv.slice(2),exe=path.resolve(exeArg),official=path.resolve(officialArg);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'HomeLibRu-update-test-components-'));
const bytes=fs.readFileSync(exe),platform=bytes.readUInt16LE(bytes.readUInt32LE(0x3c)+4)===0x8664?'Win64':'Win32';
const arch=platform==='Win64'?'x64':'x86';let count=0;
function run(args,expected=0){const r=cp.spawnSync(exe,args,{encoding:'utf8',windowsHide:true,timeout:35000});assert.ifError(r.error);assert.equal(r.status,expected,r.stdout+r.stderr);return r.stdout;}
function first(args){return JSON.parse(run(args).split('\n')[0]);}
function pass(s){++count;console.log('PASS '+s);}
for(const size of [0,1,3,135,136,137,271,272,273,1024*1024+1]){
  const data=crypto.randomBytes(size),file=path.join(root,'vector-'+size);fs.writeFileSync(file,data);
  assert.equal(run(['--sha3',file]).split(/\r?\n/)[0],crypto.createHash('sha3-256').update(data).digest('hex'));
}pass('SHA3-256 agrees with independent implementation across rate boundaries and streaming');
const sqlite=first(['--sqlite-parse',path.join(official,'sqlite-download.html'),path.join(official,'sqlite-changes.html'),'3.53.3']);
assert.equal(sqlite[0],'3.53.4');assert.match(sqlite[1],new RegExp('/sqlite-dll-win-'+arch+'-3530400\\.zip$'));
assert.equal(sqlite[2].length,64);assert(sqlite[3]>1000000);assert.match(sqlite[4],/^3\.53\.4 \u2014 24\.07\.2026\r?$/m);assert.doesNotMatch(sqlite[4],/^3\.53\.3(?: \u2014 [^\r\n]+)?\r?$/m);
pass('official SQLite metadata chooses running architecture and combines only missed changelog');
const badHTML=path.join(root,'bad.html');fs.writeFileSync(badHTML,'PRODUCT,3.53.4,https://evil.example/sqlite.zip,123,'+'a'.repeat(64));
run(['--sqlite-parse',badHTML,path.join(official,'sqlite-changes.html')],1);pass('SQLite parser refuses foreign or malformed archives');
const sumatraJSON=path.join(root,'sumatra.json');
fs.writeFileSync(sumatraJSON,JSON.stringify([{tag_name:'3.7',prerelease:true,body:'unstable'},
  {tag_name:'3.5.2rel',body:'older'},{tag_name:'3.6.1rel',body:'Bugfixes.'},
  {tag_name:'4.0',draft:true,body:'hidden'}]));
const sumatra=first(['--sumatra-parse',sumatraJSON,'-','3.5.2']);
assert.equal(sumatra[0],'3.6.1');assert.match(sumatra[1],new RegExp('/SumatraPDF-3.6.1'+(arch==='x64'?'-64':'')+'\\.zip$'));
assert.match(sumatra[4],/Bugfixes/);assert.doesNotMatch(sumatra[4],/older|unstable|hidden/);
assert.match(sumatra[5],/Bugfixes[\s\S]*older/);
pass('Sumatra parser chooses stable official archive and excludes drafts and prereleases');
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
const checked=first(['--official-check']);assert.equal(checked[0],'SQLite');assert(checked[2].startsWith('https://www.sqlite.org/'));assert.equal(checked[4],'');
assert.deepEqual(checked.slice(5,10),['','','',0,'']);
assert.equal(checked[10],'SumatraPDF');assert(checked[12].startsWith('https://www.sumatrapdfreader.org/'));assert(checked[13]>0);assert.equal(checked[14],'');
pass('real official checks query SQLite and SumatraPDF while skipping AlReader');
console.log('PASS TOTAL '+count+' ('+platform+'); isolated fixtures: '+root);

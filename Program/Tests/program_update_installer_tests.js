'use strict';
// Tests real native update code only in a new TEMP installation. No personal
// profiles, collections, or published archives are modified.
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const cp = require('node:child_process'), crypto = require('node:crypto');
const assert = require('node:assert/strict'), http = require('node:http');
const [testArg, helperArg, python = 'python'] = process.argv.slice(2);
const tester = path.resolve(testArg), helper = path.resolve(helperArg);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'HomeLibRu-update-test-'));
const platform = fs.readFileSync(tester).readUInt16LE(fs.readFileSync(tester).readUInt32LE(0x3c)+4) === 0x8664 ? 'Win64' : 'Win32';
const tag = '2.7.0_pre5.11'; let count = 0, number = 0, server;
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const read = p => fs.readFileSync(p);
const json = p => JSON.parse(read(p).toString('utf8').replace(/^\uFEFF/, ''));
const pass = label => { count++; console.log('PASS ' + label); };
const folder = label => { const p = path.join(root, label + '-' + number++); fs.mkdirSync(p); return p; };
const job = () => folder('HomeLibRu-update-job');
function run(args, expected = 0) {
  const result = cp.spawnSync(tester, args, {encoding:'utf8', windowsHide:true, timeout:25000});
  assert.ifError(result.error); assert.equal(result.status, expected, result.stdout + result.stderr);
  return result.stdout;
}
async function asyncRun(args, expected = 0, executable = tester) {
  const child = cp.spawn(executable, args, {windowsHide:true});
  let text = ''; child.stdout?.on('data', b => text += b); child.stderr?.on('data', b => text += b);
  const timeout = setTimeout(() => child.kill(), 30000);
  const result = await new Promise((resolve, reject) => {child.on('error',reject);child.on('exit', resolve);});
  clearTimeout(timeout); assert.equal(result, expected, text); return text;
}
function archive(options = {}) {
  let entries = [ ['HomeLibRu.exe', read(tester)], ['LICENSE', Buffer.from('new license')],
    ['NOTICE', Buffer.from('new notice')], ['HomeLibRuUpdater.exe', read(helper)],
    ['sqlite3.dll', Buffer.from('new sqlite')], ['Help/update.html', Buffer.from('new help')],
    ['Readers/AlReader/AlReader2.exe', Buffer.from('new reader')],
    ['Readers/AlReader/$savevtut.ini', Buffer.from('new portable marker')] ];
  if(options.component) {
    const componentPath = options.component==='SQLite' ? 'sqlite3.dll' : `Readers/${options.component}/${options.component==='AlReader'?'AlReader2':'SumatraPDF'}.exe`;
    entries=[[componentPath,read(path.join(path.dirname(helper),componentPath))]];
    if(options.component==='AlReader') entries.push(['Readers/AlReader/$savevtut.ini',Buffer.from('new portable marker')]);
  }
  if(options.runtimeComponents) {
    for(const entry of entries) if(entry[0]==='sqlite3.dll') entry[1]=read(path.join(path.dirname(helper),entry[0]));
    entries.push(['Readers/SumatraPDF/SumatraPDF.exe',read(path.join(path.dirname(helper),'Readers/SumatraPDF/SumatraPDF.exe'))]);
  }
  if (options.entry) entries.push([options.entry, Buffer.from('extra')]);
  const manifest = {format:1, release:options.tag || tag, platform:options.platform || platform,
    files: entries.map(([name, data]) => ({path:name,size:data.length,sha256:sha(data)}))};
  if(options.component) { manifest.component=options.component; manifest.version=options.version; }
  if (options.mutate) options.mutate(manifest, entries);
  if (!options.noManifest) entries.push(['HomeLibRu.update.json', Buffer.from(JSON.stringify(manifest))]);
  if (options.extra) entries.push([options.extra, Buffer.from('unlisted')]);
  if (options.duplicate) entries.push(['LICENSE', Buffer.from('duplicate')]);
  const filename = path.join(root, 'archive-' + number++ + '.zip');
  const script = 'import sys,json,zipfile,base64\nitems=json.load(sys.stdin)\nwith zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:\n for name,data in items: z.writestr(name,base64.b64decode(data))';
  const zipped = cp.spawnSync(python, ['-c', script, filename], {
    input:JSON.stringify(entries.map(([name,data])=>[name,data.toString('base64')])), encoding:'utf8', windowsHide:true});
  assert.equal(zipped.status,0,zipped.stderr); return filename;
}
function prepare(zip, destination = job(), fixture = false, expected = 0, release = tag) {
  run(['--prepare',zip,sha(read(zip)),release,destination,...(fixture?['--fixture']:[])],expected); return destination;
}
function target() {
  const p = folder('installation');
  const files = { 'HomeLibRu.exe':read(tester), 'LICENSE':'old license', 'NOTICE':'old notice',
    'sqlite3.dll':'old sqlite', 'myhomelib2.ini':'personal settings', 'Data/collections.db':'personal database',
    'presets.cxml2':'personal presets', 'uselocaldata':'', 'Readers/AlReader/$savevtut.ini':'existing marker',
    'Readers/AlReader/options.ini':'reader options', 'Readers/SumatraPDF/SumatraPDF-settings.txt':'reading history' };
  for (const [name, bytes] of Object.entries(files)) {const file=path.join(p,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,bytes);}
  return p;
}
const personal = ['myhomelib2.ini','Data/collections.db','presets.cxml2','uselocaldata','Readers/AlReader/$savevtut.ini','Readers/AlReader/options.ini','Readers/SumatraPDF/SumatraPDF-settings.txt'];
const snapshot = (p, names) => names.map(n=>sha(read(path.join(p,n))));
async function until(file) { for(let i=0;i<150;i++){if(fs.existsSync(file))return;await new Promise(r=>setTimeout(r,50));}throw Error('Timeout '+file); }
async function main() {
  run(['--metadata']); pass('schedule, never, custom interval, backward clock and safe names');
  const versions={SQLite:'3.53.4.0',AlReader:'2.5.1009.25',SumatraPDF:'3.6.1.0'};
  for(const id of Object.keys(versions)) {
    const componentZip=archive({component:id,version:versions[id]}), componentJob=job(), componentTarget=target();
    run(['--prepare-component',componentZip,sha(read(componentZip)),tag,componentJob,id,versions[id]]);
    const preserved=snapshot(componentTarget,['HomeLibRu.exe','LICENSE','NOTICE',...personal]);
    run(['--install',componentJob,componentTarget]);
    assert.deepEqual(snapshot(componentTarget,['HomeLibRu.exe','LICENSE','NOTICE',...personal]),preserved);
    pass('independent '+id+' installation preserves application and all profiles');
    run(['--prepare-component',componentZip,sha(read(componentZip)),tag,job(),id,'9.9.9.9'],1);
  }
  const compZip=archive({component:'SQLite',version:versions.SQLite,entry:'HomeLibRu.exe'});
  run(['--prepare-component',compZip,sha(read(compZip)),tag,job(),'SQLite',versions.SQLite],1);
  pass('component package cannot replace the main application or a different version');
  const feedFile=path.join(root,'components.json'), assetsFile=path.join(root,'assets.json');
  const feed={format:1,components:Object.entries(versions).map(([id,version])=>({id,version,platform,history:[{version,notes:'new '+id},{version:'1.0',notes:'already installed'}]}))};
  const assets=Object.keys(versions).map(id=>({name:`HomeLibRu-${id}-${platform}.zip`,digest:'sha256:'+'a'.repeat(64),size:123,
    browser_download_url:`https://github.com/Dicur3x/MyHomeLib/releases/download/${tag}/HomeLibRu-${id}-${platform}.zip`}));
  fs.writeFileSync(feedFile,JSON.stringify(feed));fs.writeFileSync(assetsFile,JSON.stringify(assets));
  const parsedComponents=JSON.parse(run(['--components',feedFile,tag,assetsFile,'1.0']).split('\n')[0]);
  assert.equal(parsedComponents[0],versions.SQLite);assert.match(parsedComponents[2],/new SQLite/);assert.doesNotMatch(parsedComponents[2],/already installed/);
  assets[0].browser_download_url='https://other.example/evil.zip';fs.writeFileSync(assetsFile,JSON.stringify(assets));
  run(['--components',feedFile,tag,assetsFile,'1.0'],1);pass('component feed validates architecture, own GitHub assets and missed-version changelog');
  const expectedName = platform === 'Win64' ? 'HomeLibRu_x64.zip' : 'HomeLibRu.zip';
  const release = (tag,body,draft=false) => ({tag_name:tag,body,draft,assets:[{name:expectedName,
    browser_download_url:`https://github.com/Dicur3x/MyHomeLib/releases/download/${tag}/${expectedName}`,digest:'sha256:'+'a'.repeat(64),size:123}]});
  const jsonFile=path.join(root,'releases.json');
  fs.writeFileSync(jsonFile,JSON.stringify([release('2.7.0_pre5.14','new14'),release('2.7.0_pre5.13','installed13'),release('2.7.0_pre5.16','draft',true),release('2.7.0_pre5.15','new15')]));
  const parsed=JSON.parse(run(['--parse',jsonFile]).split('\n')[0]);
  assert.equal(parsed[0],'2.7.0_pre5.15');assert.equal(parsed[3],123);
  assert.match(parsed[4],/new15[\s\S]*new14/);assert.doesNotMatch(parsed[4],/installed13|draft/);
  assert.match(parsed[5],/new15[\s\S]*new14[\s\S]*installed13/);pass('combined changelog in newest-first order, drafts excluded');
  for(const change of [r=>r.assets[0].browser_download_url='https://other.example/update.zip',r=>r.assets[0].digest=null,r=>r.assets[0].size=300*1024*1024]) {
    const r=release('2.7.0_pre5.14','text');change(r);fs.writeFileSync(jsonFile,JSON.stringify([r]));
    assert.equal(JSON.parse(run(['--parse',jsonFile]).split('\n')[0])[1],'');
  }pass('foreign URL, missing checksum and oversized release cannot be downloaded');
  const zip=archive(), prepared=prepare(zip);pass('strict archive, every hash, PE architecture and ProductVersion verified');
  for(const [label,options] of [
    ['missing manifest',{noManifest:true}],['wrong release',{tag:'2.7.0_pre5.12'}],
    ['wrong architecture',{platform:platform==='Win64'?'Win32':'Win64'}],['unlisted profile',{extra:'Data/collections.db'}],
    ['traversal',{entry:'Help/../evil.exe'}],['absolute path',{entry:'C:/evil.exe'}],
    ['reserved filename',{entry:'Help/CON.txt'}],['alternate stream',{entry:'Help/file:ads'}],
    ['reader profile',{entry:'Readers/AlReader/options.ini'}],['duplicate',{duplicate:true}],
    ['case alias',{entry:'license'}],['wrong file checksum',{mutate:m=>m.files[1].sha256='0'.repeat(64)}],
    ['wrong file length',{mutate:m=>m.files[1].size++}],['missing license',{mutate:(m,e)=>{m.files.splice(1,1);e.splice(1,1);}}],
    ['invalid format',{mutate:m=>m.format=2}],['invalid executable',{mutate:(m,e)=>{e[0][1]=Buffer.from('not PE');m.files[0].size=e[0][1].length;m.files[0].sha256=sha(e[0][1]);}}]
  ]) {prepare(archive(options),job(),false,1);pass('rejects '+label);}
  run(['--prepare',zip,'0'.repeat(64),tag,job()],1);pass('rejects damaged archive before extraction');
  const dest=target(), before=snapshot(dest,personal);
  run(['--install',prepared,dest]);assert.deepEqual(snapshot(dest,personal),before);
  assert.equal(read(path.join(dest,'sqlite3.dll')).toString(),'new sqlite');
  assert.equal(read(path.join(dest,'Readers/AlReader/AlReader2.exe')).toString(),'new reader');
  assert.equal(json(path.join(prepared,'journal.json')).state,'installed');
  run(['--install',prepared,dest]);pass('full distribution replacement preserves all user data, repeat is harmless');
  const newerTarget=target(), newerNames=['sqlite3.dll','Readers/SumatraPDF/SumatraPDF.exe'];
  for(const name of newerNames) {
    const bytes=Buffer.from(read(path.join(path.dirname(helper),name)));
    const fixed=bytes.indexOf(Buffer.from([0xbd,0x04,0xef,0xfe]));assert(fixed>=0);
    bytes.writeUInt32LE(bytes.readUInt32LE(fixed+8)+1,fixed+8);
    const file=path.join(newerTarget,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,bytes);
  }
  const newerBefore=snapshot(newerTarget,newerNames), newerPersonal=snapshot(newerTarget,personal);
  run(['--install',prepare(archive({runtimeComponents:true})),newerTarget]);
  assert.deepEqual(snapshot(newerTarget,newerNames),newerBefore);assert.deepEqual(snapshot(newerTarget,personal),newerPersonal);
  assert.equal(read(path.join(newerTarget,'LICENSE')).toString(),'new license');
  pass('application update preserves independently installed newer SQLite and reader');
  const olderComponent=archive({component:'SQLite',version:versions.SQLite}), olderJob=job();
  run(['--prepare-component',olderComponent,sha(read(olderComponent)),tag,olderJob,'SQLite',versions.SQLite]);
  run(['--install',olderJob,newerTarget]);assert.deepEqual(snapshot(newerTarget,newerNames),newerBefore);
  pass('a delayed component archive cannot downgrade a newer installed version');
  const rolled=prepare(zip), old=target(), originals=snapshot(old,['LICENSE','NOTICE','sqlite3.dll',...personal]);
  run(['--install',rolled,old,'5'],1);assert.deepEqual(snapshot(old,['LICENSE','NOTICE','sqlite3.dll',...personal]),originals);
  assert(!fs.existsSync(path.join(old,'HomeLibRuUpdater.exe')));assert(!fs.existsSync(path.join(old,'Help/update.html')));
  assert.equal(json(path.join(rolled,'journal.json')).state,'rolled-back');pass('mid-copy failure rolls back original and newly created files');
  const damaged=prepare(zip), untouched=target();fs.appendFileSync(path.join(damaged,'payload/LICENSE'),'tamper');
  run(['--install',damaged,untouched],1);assert.equal(read(path.join(untouched,'LICENSE')).toString(),'old license');pass('modified prepared payload never changes installation');
  const locked=prepare(zip), busy=target(), lockFile=path.join(busy,'sqlite3.dll');
  const locker=cp.spawn(tester,['--holdfile',lockFile],{windowsHide:true});await until(lockFile+'.locked');
  run(['--install',locked,busy],1);assert.equal(read(path.join(busy,'LICENSE')).toString(),'old license');
  await new Promise(r=>locker.on('exit',r));run(['--install',locked,busy]);pass('busy DLL fails before replacement and can retry after reader exits');
  const outside=folder('outside'), linked=target();fs.symlinkSync(outside,path.join(linked,'Help'),'junction');
  run(['--install',prepare(zip),linked],1);assert.equal(fs.readdirSync(outside).length,0);pass('junction target is never written');
  const restartJob=prepare(zip), restartTarget=target(), argv=['--probe','профиль пользователя','quoted value','C:\\путь с пробелом\\'];
  fs.copyFileSync(helper,path.join(restartJob,'HomeLibRuUpdater.exe'));
  const parent=cp.spawn(path.join(restartTarget,'HomeLibRu.exe'),['--parent','1500'],{windowsHide:true});await until(path.join(restartTarget,'parent-ready.txt'));
  const commandLine='"'+path.join(restartTarget,'HomeLibRu.exe')+'" '+argv.map(a=>'"'+a+'"').join(' ');
  fs.writeFileSync(path.join(restartJob,'request.json'),JSON.stringify({target:restartTarget,pid:parent.pid,tag,sha256:sha(read(zip)),args:argv,commandLine}));
  fs.copyFileSync(zip,path.join(restartJob,'release.zip'));
  await asyncRun(['--job',restartJob],0,path.join(restartJob,'HomeLibRuUpdater.exe'));await until(path.join(restartTarget,'probe.json'));
  assert.deepEqual(json(path.join(restartTarget,'probe.json')),argv.slice(1));pass('native helper waits for exit and restarts same Unicode/quoted profile arguments');
  const recoverJob=prepare(zip), recoverTarget=target();
  fs.mkdirSync(path.join(recoverJob,'backup'));fs.copyFileSync(path.join(recoverTarget,'LICENSE'),path.join(recoverJob,'backup/LICENSE'));
  fs.writeFileSync(path.join(recoverTarget,'LICENSE'),'interrupted new version');
  fs.writeFileSync(path.join(recoverJob,'journal.json'),JSON.stringify({target:recoverTarget,state:'installing',files:[{path:'LICENSE',existed:true}]}));
  fs.copyFileSync(helper,path.join(recoverJob,'HomeLibRuUpdater.exe'));
  fs.writeFileSync(path.join(recoverJob,'request.json'),JSON.stringify({target:recoverTarget,pid:0xffffffff,tag,sha256:sha(read(zip)),args:['--probe','recovered'],recover:true}));
  await asyncRun(['--job',recoverJob],0,path.join(recoverJob,'HomeLibRuUpdater.exe'));await until(path.join(recoverTarget,'probe.json'));
  assert.equal(read(path.join(recoverTarget,'LICENSE')).toString(),'old license');pass('interrupted transaction restores old installation and restarts');
  const bytes=read(zip);
  server=http.createServer((req,res)=>{
    if(req.url==='/404'){res.writeHead(404);res.end();return;}
    if(req.url==='/redirect'){res.writeHead(302,{Location:'/ok'});res.end();return;}
    res.writeHead(200,{'Content-Length':req.url==='/length'?bytes.length+1:bytes.length,'Content-Type':'application/zip'});
    if(req.url==='/slow'){let n=0;const timer=setInterval(()=>{res.write(bytes.subarray(n,n+8192));n+=8192;if(n>=bytes.length){clearInterval(timer);res.end();}},40);res.on('close',()=>clearInterval(timer));}
    else if(req.url==='/truncated'){res.end(bytes.subarray(0,bytes.length-2));}
    else res.end(bytes);
  });await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const address='http://127.0.0.1:'+server.address().port;
  for(const url of ['/ok','/redirect']){await asyncRun(['--download',address+url,String(bytes.length),sha(bytes),tag,job()]);pass('native HTTP download '+url);}
  for(const url of ['/404','/length','/truncated']){await asyncRun(['--download',address+url,String(bytes.length),sha(bytes),tag,job()],1);pass('native HTTP rejects '+url);}
  await asyncRun(['--download',address+'/ok',String(bytes.length),'0'.repeat(64),tag,job()],1);pass('download checksum failure');
  await asyncRun(['--download',address+'/slow',String(bytes.length),sha(bytes),tag,job(),'--cancel'],1);pass('cancelled download cannot be installed');
  console.log(`PASS TOTAL ${count} (${platform}); isolated fixtures: ${root}`);
}
main().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(()=>{server?.closeAllConnections();server?.close();});

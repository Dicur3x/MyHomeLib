'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process'),http=require('node:http');
const crypto=require('node:crypto'),assert=require('node:assert/strict');
const [viewsArg,testArg,runtimeArg,python='python']=process.argv.slice(2);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'HomeLibRu-native-HomeLibRu-update-test-popup-')),runtime=path.resolve(runtimeArg);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');let server;
const exe=fs.readFileSync(path.resolve(testArg)),architecture=exe.readUInt16LE(exe.readUInt32LE(0x3c)+4),platform=architecture===0x8664?'Win64':'Win32';
const old=Buffer.from('2.7.0_pre5.11','utf16le'),fresh=Buffer.from('2.7.0_pre5.14','utf16le');let offset=exe.indexOf(old),replaced=0;
while(offset>=0){fresh.copy(exe,offset);replaced++;offset=exe.indexOf(old,offset+old.length);}assert(replaced>0,'Test version resource missing');
const entries=[['HomeLibRu.exe',exe],['LICENSE',Buffer.from('test license')],['NOTICE',Buffer.from('test notice')]];
const manifest={format:1,release:'2.7.0_pre5.14',platform,files:entries.map(([name,b])=>({path:name,size:b.length,sha256:sha(b)}))};
entries.push(['HomeLibRu.update.json',Buffer.from(JSON.stringify(manifest))]);
const zip=path.join(root,'release.zip'),script='import sys,json,zipfile,base64\nwith zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:\n for n,d in json.load(sys.stdin): z.writestr(n,base64.b64decode(d))';
const zipped=cp.spawnSync(python,['-c',script,zip],{input:JSON.stringify(entries.map(([n,d])=>[n,d.toString('base64')])),encoding:'utf8',windowsHide:true});assert.equal(zipped.status,0,zipped.stderr);
fs.copyFileSync(path.resolve(viewsArg),path.join(root,'HomeLibRu.exe'));
for(const name of ['sqlite3.dll','libzstd.dll','libeay32.dll','ssleay32.dll','homelib_webp.dll','HomeLibRuUpdater.exe']){
 if(fs.existsSync(path.join(runtime,name)))fs.copyFileSync(path.join(runtime,name),path.join(root,name));
}
fs.mkdirSync(path.join(root,'tools/webp'),{recursive:true});fs.copyFileSync(path.join(runtime,'tools/webp/libwebp.dll'),path.join(root,'tools/webp/libwebp.dll'));
if(fs.existsSync(path.join(runtime,'Icons')))fs.cpSync(path.join(runtime,'Icons'),path.join(root,'Icons'),{recursive:true});
for(const name of fs.readdirSync(runtime))if(/^genres.*\.glst$/i.test(name))fs.copyFileSync(path.join(runtime,name),path.join(root,name));
fs.copyFileSync(path.resolve(__dirname,'../../Installer/Components.json'),path.join(root,'COMPONENTS.json'));
for(const name of ['uselocaldata','uselocaltemp'])fs.writeFileSync(path.join(root,name),'');
fs.writeFileSync(path.join(root,'native-regression.marker'),'HomeLib Ru isolated native regression v1');
fs.writeFileSync(path.join(root,'myhomelib2.ini'),'[SYSTEM]\r\nCheckUpdates=0\r\nCheckLibrusecUpdates=0\r\n[INTERFACE]\r\nLocale=ru\r\n[BEHAVIOR]\r\nCoverPanel=0\r\nShowCover=0\r\nShowAnnotation=0\r\nAutoLoadReview=0\r\nIgnoreAbsentArchives=1\r\n[OPDS]\r\nEnabled=0\r\n');
async function main(){
 const payload=fs.readFileSync(zip);let requests=0;
 server=http.createServer((req,res)=>{requests++;res.writeHead(200,{'Content-Length':payload.length});let n=0;const timer=setInterval(()=>{res.write(payload.subarray(n,n+32768));n+=32768;if(n>=payload.length){clearInterval(timer);res.end();}},10);res.on('close',()=>clearInterval(timer));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port+'/release.zip';
 const child=cp.spawn(path.join(root,'HomeLibRu.exe'),['program-update-download',url,String(payload.length),sha(payload)],{cwd:root,windowsHide:true});let text='';
 child.stdout.on('data',b=>text+=b);child.stderr.on('data',b=>text+=b);const timeout=setTimeout(()=>child.kill(),45000);
 const status=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',resolve);});clearTimeout(timeout);console.log(text);assert.equal(status,0,text);
 for(let i=0;i<150&&!fs.existsSync(path.join(root,'update-restarted.txt'));i++)await new Promise(r=>setTimeout(r,100));
 const result=fs.readFileSync(path.join(root,'update-restarted.txt'),'utf8').replace(/^\uFEFF/,'');assert.equal(result,[url,String(payload.length),sha(payload)].join('\r\n'));
 assert.equal(requests,1,'Repeated or automatic download');assert.deepEqual(fs.readFileSync(path.join(root,'HomeLibRu.exe')),exe);
 assert(fs.existsSync(path.join(root,'Data')),'Collections lost');assert(fs.existsSync(path.join(root,'myhomelib2.ini')),'Settings lost');
 console.log('PASS full popup download, progress, Later, ready restore, main exit, replacement and exact restart ('+platform+'); isolated fixtures: '+root);
}
main().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(()=>{server?.closeAllConnections();server?.close();});

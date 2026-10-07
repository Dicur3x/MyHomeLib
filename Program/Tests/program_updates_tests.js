'use strict';
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
let cachedRequests=0, bodyDownloads=0, modifiedRequests=0;
const server = http.createServer((req, res) => {
  if (req.url === '/cached') {
    ++cachedRequests;
    if(cachedRequests > 1) assert.equal(req.headers['if-none-match'], cachedRequests===4?'"v2"':'"v1"');
    if(cachedRequests===2) {res.writeHead(304);return res.end();}
    if(cachedRequests===4) {res.writeHead(503);return res.end();}
    ++bodyDownloads;
    res.writeHead(200, {'Content-Type':'application/json','ETag':cachedRequests===3?'"v2"':'"v1"'});
    return res.end(JSON.stringify([{tag_name:cachedRequests===3?'2.7.0_pre5.09':'2.7.0_pre5.08',draft:false,
      body:'Stable cached history',assets:[{name:'HomeLibRu.zip'}]}]));
  }
  if (req.url === '/modified') {
    ++modifiedRequests;
    if(modifiedRequests===2) {
      assert.equal(req.headers['if-modified-since'],'Wed, 07 Oct 2026 12:00:00 GMT');
      res.writeHead(304);return res.end();
    }
    res.writeHead(200,{'Content-Type':'application/json','Last-Modified':'Wed, 07 Oct 2026 12:00:00 GMT'});
    return res.end(JSON.stringify([{tag_name:'2.7.0_pre5.08',draft:false,assets:[{name:'HomeLibRu.zip'}]}]));
  }
  if (req.url === '/slow') return; // client timeout must be quiet
  if (req.url === '/forbidden') res.writeHead(403);
  else if (req.url === '/missing') res.writeHead(404);
  else res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(req.url === '/ok' ? JSON.stringify([{
    tag_name: '2.7.0_pre5.08', draft: false, assets: [{ name: 'HomeLibRu_x64.zip' }]
  }]) : 'not JSON');
});
server.listen(0, '127.0.0.1', () => {
  const exe = path.resolve(process.argv[2]);
  const child = spawn(exe, [`http://127.0.0.1:${server.address().port}`], { windowsHide: true });
  const timeout = setTimeout(() => child.kill(), 25000);
  let output = '', error = '';
  child.stdout.on('data', data => output += data);
  child.stderr.on('data', data => error += data);
  child.on('error', err => { throw err; });
  child.on('exit', code => {
    clearTimeout(timeout);
    server.closeAllConnections();
    server.close();
    assert.equal(code, 0, error || output);
    assert.equal(cachedRequests,4);assert.equal(bodyDownloads,2);assert.equal(modifiedRequests,2);
    process.stdout.write(output);
  });
});

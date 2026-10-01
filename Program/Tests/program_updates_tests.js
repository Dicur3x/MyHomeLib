'use strict';
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const server = http.createServer((req, res) => {
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
    process.stdout.write(output);
  });
});

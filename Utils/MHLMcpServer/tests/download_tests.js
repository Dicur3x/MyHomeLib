#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');

if (process.argv.length !== 3) {
  console.error('Usage: node download_tests.js <MHLMcpServer.exe>');
  process.exit(1);
}

const source = path.resolve(process.argv[2]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'homelib-download-test-'));
const exe = path.join(root, 'MHLMcpServer.exe');
const payload = fs.readFileSync(path.join(__dirname, 'fixtures', 'structured.fb2'));
const requests = [];

function execute(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(exe, args, { cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => child.kill(), 60000);
    child.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
    child.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

async function main() {
  // Copy only runtime dependencies, never a developer's settings or databases.
  for (const name of ['MHLMcpServer.exe', 'sqlite3.dll', 'libzstd.dll', 'genres_fb2.glst']) {
    fs.copyFileSync(path.join(path.dirname(source), name), path.join(root, name));
  }
  const zipInput = path.join(root, 'online-member.fb2');
  const zipFile = path.join(root, 'online-response.fb2.zip');
  fs.writeFileSync(zipInput, payload);
  const zip = spawnSync('python', ['-c',
    'import sys,zipfile; z=zipfile.ZipFile(sys.argv[2],"w",compression=zipfile.ZIP_DEFLATED); z.write(sys.argv[1],"server-member.fb2"); z.close()',
    zipInput, zipFile], { cwd: root, windowsHide: true, encoding: 'utf8' });
  assert.equal(zip.status, 0, zip.stderr || String(zip.error || 'ZIP fixture creation failed'));
  const zippedPayload = fs.readFileSync(zipFile);
  const server = http.createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      requests.push({ method: req.method, url: req.url, body, type: req.headers['content-type'] });
      if (req.method === 'POST' && req.url === '/b/854807/get') {
        res.writeHead(303, { Location: `http://127.0.0.1:${server.address().port}/result/book.fb2.zip` });
        res.end('intermediate redirect response must not be saved');
      } else if (req.method === 'POST' && req.url === '/zip-redirect/b/854807/get') {
        res.writeHead(303, { Location: `http://127.0.0.1:${server.address().port}/result/online.fb2.zip` });
        res.end('online ZIP intermediate response must not be saved');
      } else if (req.url === '/zip/b/854807/get' || req.url === '/result/online.fb2.zip') {
        res.writeHead(200, { 'Content-Type': 'application/zip' });
        res.end(zippedPayload);
      } else {
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
        res.end(payload);
      }
    });
  });
  try {
    const guarded = await execute(['--download-selftest']);
    assert.notEqual(guarded.code, 0, 'missing profile switches accepted');
    assert.match(guarded.stderr, /uselocaldata user mcpfixture/);
    assert.ok(!fs.existsSync(path.join(root, 'mcpfixture')), 'guard created a fixture');
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const run = await execute(['--download-selftest', 'uselocaldata', 'user', 'mcpfixture',
      String(server.address().port)]);
    assert.equal(run.code, 0, run.stderr || 'self-test process failed');
    const messages = run.stdout.trim().split(/\r?\n/).map(JSON.parse);
    assert.equal(messages.length, 2, 'expected fixture and download reports');
    assert.equal(messages[1].cases.length, 7);
    assert.equal(messages[1].webp_default_enabled, true, 'normal downloads must work with the default WebP policy');
    assert.equal(messages[1].clear_status_notified, true, 'cleared local status not delivered to VCL');
    for (const item of messages[1].cases) {
      assert.equal(item.downloaded, true, `${item.name}: download failed`);
      assert.equal(item.local, true, `${item.name}: not marked local`);
      assert.equal(item.notified, true, `${item.name}: local-status notification lost or corrupted`);
      assert.ok(path.resolve(item.path).startsWith(root + path.sep));
      assert.deepEqual(fs.readFileSync(item.path), item.archive ? zippedPayload : payload,
        `${item.name}: response changed or appended`);
      const ext = path.extname(item.path);
      assert.ok(!fs.existsSync(item.path.slice(0, -ext.length) + '.part' + ext));
      if (item.archive) {
        for (const artifact of [item.stream_path, item.descriptor_path]) {
          assert.ok(path.resolve(artifact).startsWith(root + path.sep));
          assert.deepEqual(fs.readFileSync(artifact), payload,
            `${item.name}: extracted book or preview changed a normal FB2 without WebP`);
        }
      }
    }
    assert.deepEqual(requests.map(({ method, url }) => [method, url]), [
      ['GET', '/b/854807/get'],
      ['POST', '/post/854807/get'],
      ['POST', '/b/854807/get'],
      ['GET', '/result/book.fb2.zip'],
      ['GET', '/result/book.fb2.zip'],
      ['GET', '/encoded/a%2Fb%20c?token=x%2By%26z&literal=%252F&plus=a+b'],
      ['GET', '/unicode/%D0%9A%D0%BD%D0%B8%D0%B3%D0%B0%201.fb2'],
      ['GET', '/zip/b/854807/get'],
      ['POST', '/zip-redirect/b/854807/get'],
      ['GET', '/result/online.fb2.zip'],
      ['GET', '/result/online.fb2.zip'],
    ]);
    assert.match(requests[1].type, /^multipart\/form-data;/i);
    assert.match(requests[1].body, /name="token"/);
    assert.match(requests[1].body, /value\+with%literal/);
    console.log('PASS: seven download cases, including genuine online Deflate ZIP, POST redirect, legacy member-name fallback, preview and book extraction; exact bytes, default WebP policy, local flags and VCL status messages');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  const target = path.resolve(root);
  assert.equal(path.dirname(target), path.resolve(os.tmpdir()));
  assert.ok(path.basename(target).startsWith('homelib-download-test-'));
  fs.rmSync(target, { recursive: true, force: true });
});

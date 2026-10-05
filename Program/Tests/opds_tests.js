#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');

if (process.argv.length !== 4) {
  console.error('Usage: node opds_tests.js <OPDSServerTest.exe> <MHLMcpServer.exe>');
  process.exit(2);
}

const tester = path.resolve(process.argv[2]);
const mcp = path.resolve(process.argv[3]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'homelib-opds-test-'));
const feeds = [];
const formatFixtures = new Map([
  [103, { ext: '.epub', mime: 'application/epub+zip', name: 'opds097.epub' }],
  [104, { ext: '.pdf', mime: 'application/pdf', name: 'opds098.pdf' }],
  [105, { ext: '.txt', mime: 'text/plain', name: 'opds099.txt' }],
  [106, { ext: '.bin', mime: 'application/octet-stream', name: 'opds100.bin' }],
]);
let server, serverExit, address, stderr = '', stdout = '', idle;
let checks = 0;
function pass(message) { checks++; console.log(`PASS ${message}`); }
function sha(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function unescapeXML(value) {
  return value.replace(/&(amp|lt|gt|quot|apos);/g,
    (_, name) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" })[name]);
}
function links(xml, rel) {
  return [...xml.matchAll(/<link\b([^>]*?)\/>/g)].map(match => {
    const attrs = Object.fromEntries([...match[1].matchAll(/([\w:-]+)="([^"]*)"/g)]
      .map(item => [item[1], unescapeXML(item[2])]));
    return attrs;
  }).filter(link => !rel || link.rel === rel);
}
function entries(xml) {
  return [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].map(match => ({
    id: unescapeXML(match[1].match(/<id>([^<]*)<\/id>/)?.[1] || ''),
    title: unescapeXML(match[1].match(/<title>([^<]*)<\/title>/)?.[1] || ''),
    xml: match[1],
  }));
}
function bookIDs(xml) { return entries(xml).map(entry => Number(entry.id.match(/:book:(\d+)$/)?.[1])); }
function httpRequest(requestPath, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: address.hostname, port: address.port,
      path: requestPath, method, agent: false }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.once('error', reject);
      res.once('end', () => resolve({ status: res.statusCode, headers: res.headers,
        bytes: Buffer.concat(chunks), text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.setTimeout(10000, () => req.destroy(new Error(`Timeout: ${requestPath}`)));
    req.once('error', reject);
    req.end();
  });
}
async function request(route = '', method = 'GET') {
  return httpRequest(address.pathname + route, method);
}
async function feedPath(requestPath, kind = 'acquisition') {
  const response = await httpRequest(requestPath);
  assert.equal(response.status, 200, response.text);
  assert.match(response.headers['content-type'], new RegExp(`application/atom\\+xml;.*kind=${kind}`));
  assert.match(response.headers['content-type'], /charset=utf-8/i);
  assert.equal(response.headers['cache-control'], 'no-store');
  assert.equal(response.headers['x-content-type-options'], 'nosniff');
  assert.equal(Number(response.headers['content-length']), response.bytes.length);
  feeds.push(response.text);
  return response;
}
async function feed(route, kind) { return feedPath(address.pathname + route, kind); }
function spawnChecked(exe, args) {
  const run = spawnSync(exe, args, { cwd: root, encoding: 'utf8', windowsHide: true, timeout: 60000 });
  assert.equal(run.status, 0, run.error?.message || run.stderr);
  return run;
}
async function unusedPort() {
  const listener = net.createServer();
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}
function snapshot(folder) {
  const result = {};
  for (const name of fs.readdirSync(folder)) {
    const file = path.join(folder, name);
    // SHM locks and empty WAL containers are transient SQLite bookkeeping.
    // Nonempty WAL content is compared too, so logical writes cannot hide there.
    if (/\.hlc2-shm$/i.test(name)) continue;
    if (/\.hlc2-wal$/i.test(name) && fs.statSync(file).size === 0) continue;
    if (fs.statSync(file).isDirectory()) {
      for (const [child, hash] of Object.entries(snapshot(file))) result[path.join(name, child)] = hash;
    } else result[name] = sha(file);
  }
  return result;
}

async function main() {
  fs.copyFileSync(tester, path.join(root, 'OPDSServerTest.exe'));
  for (const name of ['MHLMcpServer.exe', 'sqlite3.dll', 'libzstd.dll', 'genres_fb2.glst']) {
    fs.copyFileSync(path.join(path.dirname(mcp), name), path.join(root, name));
  }
  fs.writeFileSync(path.join(root, 'uselocaltemp'), '');
  const fixture = JSON.parse(spawnChecked(path.join(root, 'MHLMcpServer.exe'),
    ['--make-fixture', 'uselocaldata', 'user', 'mcpfixture']).stdout.trim());
  assert.equal(fixture.books.length, 6);
  const collectionRoot = fixture.root;
  const db = path.join(collectionRoot, 'mcpfixture.hlc2');
  const exe = path.join(root, 'OPDSServerTest.exe');
  const port = await unusedPort();
  const preparedFormats = spawnSync('python', ['-X', 'utf8', '-c', String.raw`
import sys, pathlib, zipfile
books=pathlib.Path(sys.argv[1])/'books'
cp1251=books/'book3.fb2'
xml=cp1251.read_text(encoding='utf-8-sig').replace('encoding="utf-8"','encoding="windows-1251"')
cp1251.write_bytes(xml.encode('cp1251'))
with zipfile.ZipFile(books/'opds097.epub','w') as z:
 z.writestr('mimetype','application/epub+zip',compress_type=zipfile.ZIP_STORED)
 z.writestr('META-INF/container.xml','<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
 z.writestr('book.opf','<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:homelibru:opds-test</dc:identifier><dc:title>OPDS EPUB test</dc:title><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>')
 z.writestr('chapter.xhtml','<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>OPDS EPUB test</title></head><body><p>OPDS EPUB test</p></body></html>')
 z.writestr('toc.ncx','<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:homelibru:opds-test"/></head><docTitle><text>OPDS EPUB test</text></docTitle><navMap><navPoint id="chapter" playOrder="1"><navLabel><text>Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>')
content=b'BT /F1 12 Tf 20 100 Td (OPDS PDF test) Tj ET\n'
objs=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(content)).encode()+b' >>\nstream\n'+content+b'endstream']
pdf=bytearray(b'%PDF-1.4\n'); offsets=[0]
for i,obj in enumerate(objs,1):
 offsets.append(len(pdf)); pdf.extend(str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n')
xref=len(pdf); pdf.extend(b'xref\n0 6\n0000000000 65535 f \n')
for offset in offsets[1:]: pdf.extend(('%010d 00000 n \n'%offset).encode())
pdf.extend(b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n')
(books/'opds098.pdf').write_bytes(pdf)
(books/'opds099.txt').write_text('Проверка передачи текста через OPDS.\n',encoding='utf8')
(books/'opds100.bin').write_bytes(bytes(range(256)))
`, collectionRoot], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
  assert.equal(preparedFormats.status, 0, preparedFormats.stderr);
  const originalDBHash = sha(db);
  for (const args of [[], ['server', db, collectionRoot, String(port)],
    ['server', path.join(root, 'unrelated.hlc2'), collectionRoot, String(port),
      'uselocaldata', 'user', 'mcpfixture']]) {
    const denied = spawnSync(exe, args, { cwd: root, encoding: 'utf8', windowsHide: true, timeout: 10000 });
    assert.notEqual(denied.status, 0);
    assert.equal(denied.stdout.trim(), '');
    assert.equal(sha(db), originalDBHash);
  }
  pass('native tester guards reject unrelated paths and missing profile switches');
  server = spawn(exe, ['server', db, collectionRoot, String(port),
    'uselocaldata', 'user', 'mcpfixture'], { cwd: root, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  server.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
  server.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
  serverExit = new Promise((resolve, reject) => {
    server.once('error', reject);
    server.once('close', (code, signal) => resolve({ code, signal }));
  });
  let readyTimer;
  const ready = await Promise.race([
    new Promise((resolve, reject) => {
      readyTimer = setTimeout(() => reject(new Error(`No OPDS startup report: ${stderr}`)), 30000);
      function receive() {
        if (!stdout.includes('\n')) return;
        clearTimeout(readyTimer);
        server.stdout.off('data', receive);
        try { resolve(JSON.parse(stdout.split(/\r?\n/)[0])); } catch (error) { reject(error); }
      }
      server.stdout.on('data', receive);
      receive();
    }),
    serverExit.then(result => { throw new Error(`OPDS exited before ready: ${JSON.stringify(result)} ${stderr}`); }),
  ]).finally(() => clearTimeout(readyTimer));
  assert.equal(ready.visible_books, 105);
  assert.equal(ready.read_only_checked, true);
  assert.equal(ready.online_start_rejected, true);
  assert.equal(ready.online_start_reject_checks, 2);
  pass('online collections are rejected with a Russian explanation; inactive and active servers end inactive');
  assert.equal(ready.lan_loopback_checked, true);
  pass('AllowLAN binds an IPv4 wildcard listener; a loopback Atom GET and Stop succeed');
  address = new URL(ready.url);
  assert.equal(address.hostname, '127.0.0.1');
  assert.match(address.pathname, /^\/[0-9a-f-]{36}\/opds$/);
  const before = snapshot(collectionRoot);
  pass('read-only SQLite rejects UPDATE; listener uses loopback and a fresh secret URL');

  const rootFeed = await feed('', 'navigation');
  assert.equal(entries(rootFeed.text).length, 4);
  assert.match(rootFeed.text, /OPDS &amp; &lt;каталог&gt; &quot;проверка&quot;/);
  assert.equal(links(rootFeed.text, 'search')[0].type, 'application/opensearchdescription+xml');
  assert.equal(links(rootFeed.text, 'start')[0].href, address.pathname);
  assert.equal((await request('/')).status, 200);
  pass('OPDS root has navigation, UTF-8, XML escaping, self/start/search links');

  const searchDescription = await request('/search.xml');
  assert.equal(searchDescription.status, 200);
  assert.match(searchDescription.headers['content-type'], /application\/opensearchdescription\+xml/);
  assert.ok(searchDescription.text.includes(address.origin + address.pathname + '/books?q={searchTerms}'));
  feeds.push(searchDescription.text);
  pass('OpenSearch advertises the reachable acquisition URL and UTF-8 input');

  const pages = [];
  const bookHrefs = new Map();
  let nextPath = address.pathname + '/books', previous = '';
  do {
    const response = await feedPath(nextPath);
    const current = bookIDs(response.text);
    for (const entry of entries(response.text)) {
      const acquisitions = links(entry.xml, 'http://opds-spec.org/acquisition');
      assert.equal(acquisitions.length, 1);
      const bookID = Number(entry.id.match(/:book:(\d+)$/)[1]);
      const format = formatFixtures.get(bookID) || { ext: '.fb2', mime: 'application/x-fictionbook+xml' };
      // KOReader and FBReaderJ register the exact FB2 MIME; the suffix aids other readers.
      assert.equal(acquisitions[0].type, format.mime);
      assert.equal(acquisitions[0].href, address.pathname + `/book/${bookID}${format.ext}`);
      bookHrefs.set(bookID, acquisitions[0].href);
    }
    pages.push(current);
    assert.equal(links(response.text, 'previous').length, previous ? 1 : 0);
    if (previous) assert.equal(links(response.text, 'previous')[0].href, previous);
    const self = links(response.text, 'self')[0].href;
    previous = self;
    nextPath = links(response.text, 'next')[0]?.href || '';
  } while (nextPath);
  assert.deepEqual(pages.map(page => page.length), [50, 50, 5]);
  const allIDs = pages.flat();
  assert.equal(new Set(allIDs).size, 105, 'series joins duplicated physical books');
  assert.deepEqual(allIDs, Array.from({ length: 106 }, (_, i) => 106 - i).filter(id => id !== 6));
  pass('105 physical books paginate 50/50/5 with next/previous and no multi-series duplicates');

  const authors = await feed('/authors', 'navigation');
  assert.ok(entries(authors.text).length >= 3);
  assert.ok(!authors.text.includes('OPDS автор без книг'));
  assert.ok(!authors.text.includes('OPDS удалённый автор'));
  const authorBooks = await feedPath(links(entries(authors.text)[0].xml, 'subsection')[0].href);
  assert.ok(entries(authorBooks.text).length > 0);
  const genres = await feed('/genres', 'navigation');
  assert.ok(entries(genres.text).length >= 3);
  const genreBooks = await feedPath(links(entries(genres.text)[0].xml, 'subsection')[0].href);
  assert.ok(entries(genreBooks.text).length > 0);
  const series = await feed('/series', 'navigation');
  for (const title of ['OPDS общий цикл', 'OPDS дополнительный цикл']) {
    const entry = entries(series.text).find(item => item.title === title);
    assert.ok(entry, title);
    const first = await feedPath(links(entry.xml, 'subsection')[0].href);
    const second = await feedPath(links(first.text, 'next')[0].href);
    assert.equal(bookIDs(first.text).length, 50);
    assert.equal(bookIDs(second.text).length, 50);
    assert.equal(links(second.text, 'next').length, 0);
    assert.equal(new Set([...bookIDs(first.text), ...bookIDs(second.text)]).size, 100);
  }
  pass('author/genre/primary and secondary series navigation filters correctly and skips orphan/deleted-only authors');

  const searches = [
    ['проверка', [7]], ['Книга плюс+процент%_', [8]], ['іваненко', null],
    ['%', [8, 7, 2]], ['_', [8, 7, 3]], ['+', [8, 7]], ['& <тег>', [7]],
    ["' OR 1=1 --", []],
  ];
  for (const [query, expected] of searches) {
    const response = await feed('/books?q=' + encodeURIComponent(query));
    if (expected) assert.deepEqual(bookIDs(response.text), expected, query);
    else assert.ok(bookIDs(response.text).length > 0, query);
    if (query === 'проверка') assert.match(response.text, /😀/);
  }
  const plusSpace = await feed('/books?q=OPDS+pagination');
  assert.equal(entries(plusSpace.text).length, 50);
  assert.ok(links(plusSpace.text, 'next')[0].href.includes('q=OPDS'));
  const plusSpaceNext = await feedPath(links(plusSpace.text, 'next')[0].href);
  assert.equal(entries(plusSpaceNext.text).length, 47);
  pass('Unicode titles/authors, literal %/_/+, encoded &, SQL-shaped text and search pagination work');

  const expectedBook = fs.readFileSync(fixture.books[0].path);
  const book1Route = bookHrefs.get(1).slice(address.pathname.length);
  const download = await request(book1Route);
  assert.equal(download.status, 200);
  assert.match(download.headers['content-type'], /^application\/x-fictionbook\+xml/);
  assert.doesNotMatch(download.headers['content-type'], /charset=/i);
  assert.match(download.headers['content-disposition'], /^attachment; filename="book-1\.fb2"$/);
  assert.deepEqual(download.bytes, expectedBook);
  assert.deepEqual((await request('/book/1')).bytes, expectedBook, 'legacy decimal book URL');
  for (const route of ['', '/books', book1Route]) {
    const get = await request(route);
    const head = await request(route, 'HEAD');
    assert.equal(head.status, get.status);
    assert.equal(head.bytes.length, 0);
    assert.equal(head.headers['content-length'], get.headers['content-length']);
    assert.equal(head.headers['content-type'], get.headers['content-type']);
  }
  const cp1251Download = await httpRequest(bookHrefs.get(3));
  assert.equal(cp1251Download.status, 200);
  assert.doesNotMatch(cp1251Download.headers['content-type'], /charset=/i);
  assert.deepEqual(cp1251Download.bytes, fs.readFileSync(fixture.books[2].path));
  assert.ok(cp1251Download.bytes.includes(Buffer.from('encoding="windows-1251"')));
  const cp1251Head = await httpRequest(bookHrefs.get(3), 'HEAD');
  assert.equal(cp1251Head.bytes.length, 0);
  assert.equal(cp1251Head.headers['content-type'], cp1251Download.headers['content-type']);
  assert.equal(cp1251Head.headers['content-length'], cp1251Download.headers['content-length']);
  const archiveDownload = await httpRequest(bookHrefs.get(4));
  assert.equal(archiveDownload.status, 200);
  assert.deepEqual(archiveDownload.bytes, fs.readFileSync(fixture.books[3].path));
  for (const [id, format] of formatFixtures) {
    const response = await httpRequest(bookHrefs.get(id));
    assert.equal(response.status, 200);
    assert.equal(response.headers['content-type'].split(';')[0], format.mime);
    assert.doesNotMatch(response.headers['content-type'], /charset=/i);
    assert.equal(response.headers['content-disposition'], `attachment; filename="book-${id}${format.ext}"`);
    assert.deepEqual(response.bytes, fs.readFileSync(path.join(collectionRoot, 'books', format.name)));
    const head = await httpRequest(bookHrefs.get(id), 'HEAD');
    assert.equal(head.status, 200);
    assert.equal(head.bytes.length, 0);
    assert.equal(head.headers['content-length'], response.headers['content-length']);
    assert.equal(head.headers['content-type'], response.headers['content-type']);
  }
  const parallel = await Promise.all(Array.from({ length: 4 }, () => request(book1Route)));
  for (const response of parallel) {
    assert.equal(response.status, 200);
    assert.deepEqual(response.bytes, expectedBook);
  }
  pass('UTF-8/CP1251 FB2, ZIP, EPUB/PDF/TXT/BIN downloads retain bytes and MIME; parallel reads and HEAD work');

  for (const route of ['/book/6', '/book/6.fb2', '/book/999999', '/book/-1', '/book/no', '/unknown',
    '/book/+1.fb2', '/book/1.epub', '/book/1.bin', '/book/1.fb2.exe', '/book/1.',
    '/book/../../myhomelib2.ini', '/book/%2e%2e%2fmyhomelib2.ini']) {
    assert.equal((await request(route)).status, 404, route);
  }
  assert.equal((await httpRequest('/opds')).status, 404);
  assert.equal((await httpRequest('/00000000-0000-0000-0000-000000000000/opds')).status, 404);
  assert.equal((await request('', 'POST')).status, 405);
  assert.equal((await request('', 'DELETE')).status, 405);
  assert.equal((await request('', 'POST')).headers.allow, 'GET, HEAD');
  for (const route of ['/books?page=-1', '/books?page=1000001', '/books?page=no',
    '/books?page=999999999999999999', '/books?q=' + 'a'.repeat(201), '/author?id=' + 'a'.repeat(101)]) {
    assert.equal((await request(route)).status, 400, route);
  }
  pass('deleted/unknown books, traversal and wrong tokens return 404; unsafe methods 405; invalid query bounds 400');

  const missingFile = path.join(collectionRoot, 'books', 'opds100.bin');
  const missingBytes = fs.readFileSync(missingFile);
  fs.unlinkSync(missingFile);
  try { assert.equal((await httpRequest(bookHrefs.get(106))).status, 404); }
  finally { fs.writeFileSync(missingFile, missingBytes); }
  const heldDB = db + '.held';
  fs.renameSync(db, heldDB);
  try {
    const unavailable = await request('/books');
    assert.equal(unavailable.status, 503);
    assert.ok(!unavailable.text.includes(root));
    assert.ok(!unavailable.text.includes('SELECT'));
  } finally { fs.renameSync(heldDB, db); }
  assert.equal((await request('/book/1')).status, 200);
  pass('missing files return 404, unavailable database returns a private 503, and recovery works');

  // Standard-library XML parsing checks well-formedness/namespaces and mandatory Atom metadata.
  const validation = spawnSync('python', ['-X', 'utf8', '-c', `
import sys,json,xml.etree.ElementTree as ET
a='{http://www.w3.org/2005/Atom}'
for value in json.load(sys.stdin):
 r=ET.fromstring(value)
 if r.tag=='{http://a9.com/-/spec/opensearch/1.1/}OpenSearchDescription': continue
 assert r.tag==a+'feed',r.tag
 for tag in ['id','title','updated']:
  assert len(r.findall(a+tag))==1
 for e in r.findall(a+'entry'):
  for tag in ['id','title','updated']:
   assert len(e.findall(a+tag))==1
  assert e.find(a+'content') is not None or any(l.get('rel','alternate')=='alternate' for l in e.findall(a+'link'))
print('valid Atom/OpenSearch XML')
`], { input: JSON.stringify(feeds), encoding: 'utf8', windowsHide: true, timeout: 10000 });
  assert.equal(validation.status, 0, validation.stderr);
  pass(`${feeds.length} responses parse as Atom/OpenSearch XML with mandatory entry metadata`);
  assert.deepEqual(snapshot(collectionRoot), before);
  pass('all catalog and book bytes remain unchanged after HTTP requests');

  idle = net.connect(Number(address.port), address.hostname);
  await once(idle, 'connect');
  const stoppedAt = Date.now();
  server.stdin.end('stop\n');
  let stopTimer;
  const result = await Promise.race([serverExit,
    new Promise((_, reject) => { stopTimer = setTimeout(() => reject(new Error('OPDS shutdown timed out')), 15000); })
  ]).finally(() => clearTimeout(stopTimer));
  assert.equal(result.code, 0, stderr);
  assert.ok(stdout.includes('"stopped":true'));
  assert.ok(Date.now() - stoppedAt < 15000);
  idle.destroy();
  fs.renameSync(db, heldDB); fs.renameSync(heldDB, db);
  assert.deepEqual(snapshot(collectionRoot), before);
  await assert.rejects(request(''), /ECONNREFUSED|socket hang up|ECONNRESET/);
  pass('Stop closes an idle connection, releases database handles and preserves the library');
  console.log(`PASS: ${checks} OPDS integration groups; isolated 106-book fixture, no personal data`);
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  idle?.destroy();
  if (server && server.exitCode === null) {
    server.kill();
    await serverExit.catch(() => {});
  }
  const target = path.resolve(root);
  assert.equal(path.dirname(target), path.resolve(os.tmpdir()));
  assert.ok(path.basename(target).startsWith('homelib-opds-test-'));
  fs.rmSync(target, { recursive: true, force: true });
});

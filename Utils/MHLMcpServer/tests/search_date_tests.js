#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');

if (process.argv.length !== 3) {
  console.error('Usage: node search_date_tests.js <MHLMcpServer.exe>');
  process.exit(2);
}

const source = path.resolve(process.argv[2]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'homelib-search-date-test-'));

try {
  // Only runtime dependencies are copied, never settings or a personal library.
  for (const name of ['MHLMcpServer.exe', 'sqlite3.dll', 'libzstd.dll', 'genres_fb2.glst']) {
    fs.copyFileSync(path.join(path.dirname(source), name), path.join(root, name));
  }
  const preset = fs.readFileSync(path.join(__dirname, 'fixtures', 'search-date-reported.cxml2'));
  const xml = zlib.inflateSync(preset).toString('utf8');
  assert.match(xml, /<Preset displayName="сегодня">/);
  assert.match(xml, /<Preset displayName="за 3 дня">/);
  assert.match(xml, /<Preset displayName="за неделю">/);
  fs.writeFileSync(path.join(root, 'search-date-reported.cxml2'), preset);
  const run = spawnSync(path.join(root, 'MHLMcpServer.exe'),
    ['--make-fixture', 'uselocaldata', 'user', 'mcpfixture'], {
      cwd: root, encoding: 'utf8', windowsHide: true, timeout: 60000,
    });
  assert.equal(run.status, 0, run.error?.message || run.stderr || 'fixture self-test failed');
  const summary = JSON.parse(run.stdout.trim());
  assert.equal(summary.date_search_checks, 17, 'not all production date searches ran');
  assert.equal(summary.reported_date_presets_checked, true, 'attached preset was not tested');
  assert.equal(summary.books.length, 6, 'date tests changed the fixture book count');
  assert.ok(!fs.existsSync(path.join(summary.root, 'search-date-roundtrip.cxml2')));
  console.log('PASS: 17 real SQLite searches — six periods without presets, six saved/reloaded presets, three reported presets, custom date, empty date; changes rolled back');
} finally {
  const target = path.resolve(root);
  assert.equal(path.dirname(target), path.resolve(os.tmpdir()));
  assert.ok(path.basename(target).startsWith('homelib-search-date-test-'));
  fs.rmSync(target, { recursive: true, force: true });
}

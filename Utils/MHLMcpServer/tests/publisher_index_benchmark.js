#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

if (process.argv.length < 3 || process.argv.length > 4) {
  console.error('Usage: node publisher_index_benchmark.js <MHLMcpServer.exe> [40-book.7z]');
  process.exit(1);
}

const exe = path.resolve(process.argv[2]);
const realArchive = process.argv[3] ? path.resolve(process.argv[3]) : null;

function execute(args, timeout) {
  const result = spawnSync(exe, args, {
    cwd: path.dirname(exe), encoding: 'utf8', input: '',
    timeout, maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}

// A missing profile switch must fail before the fixture bootstrap can touch
// any settings. It also rejects an older executable without this CLI mode.
const guarded = execute(['--publisher-index-benchmark'], 30000);
assert.notEqual(guarded.status, 0, 'benchmark accepted missing disposable-profile switches');
assert.match(guarded.stderr, /uselocaldata user mcpfixture/);

const args = ['--publisher-index-benchmark', 'uselocaldata', 'user', 'mcpfixture'];
if (realArchive) args.push('--real-archive', realArchive);
const run = execute(args, 600000);
assert.equal(run.status, 0, run.stderr || 'benchmark failed');
const messages = run.stdout.split(/\r?\n/).filter(line => line.trim()).map(JSON.parse);
assert.equal(messages.length, 2, 'expected fixture and benchmark JSON messages only');
assert.equal(messages[0].publisher_indexer_checked, true, 'resume/cancel regression did not pass');
const report = messages[1];
assert.equal(report.benchmark, 'publisher_index');
assert.equal(report.profile, 'mcpfixture');
assert.equal(report.runs.length, realArchive ? 2 : 1);

for (const [index, sample] of report.runs.entries()) {
  const expected = index === 0 ? 1000 : 40;
  assert.equal(sample.books, expected);
  assert.equal(sample.results_equal, true);
  for (const mode of ['legacy_dom_per_entry', 'current_uncached', 'current_cached', 'current_forced']) {
    const value = sample[mode];
    assert.ok(Number.isFinite(value.elapsed_ms) && value.elapsed_ms >= 0, `${mode} elapsed_ms`);
    assert.equal(value.failed, 0, `${mode} errors`);
    assert.equal(value.indexed, mode === 'current_cached' ? 0 : expected, `${mode} indexed`);
    assert.equal(value.cached, mode === 'current_cached' ? expected : 0, `${mode} cached`);
    assert.equal(value.archive_opens,
      mode === 'legacy_dom_per_entry' ? expected : mode === 'current_cached' ? 0 : 1,
      `${mode} archive opens`);
    assert.equal(value.batches,
      index === 1 && ['current_uncached', 'current_forced'].includes(mode) ? 1 : 0,
      `${mode} batches`);
  }
}

console.log(JSON.stringify(report, null, 2));
console.log('PASS: publisher indexing regression, benchmark counts and legacy-result equality');

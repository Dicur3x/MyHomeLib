'use strict';


const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const CHECKER = path.join(__dirname, '..', 'check_glst.js');

const ORIGINAL = [
  '#---- comment ----',
  '0.1 Фантастика',
  '0.1.0 sf_history;Альтернативная история',
].join('\n');

let caseNo = 0;

function run(translated, opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `glst${caseNo++}-`));
  const bom = opts.bom === false ? '' : '﻿';
  const body = opts.eol ? translated.split('\n').join(opts.eol) : translated;
  const origBody = opts.originalEol
    ? ORIGINAL.split('\n').join(opts.originalEol)
    : ORIGINAL;
  fs.writeFileSync(path.join(dir, 'genres_fb2.glst'), '﻿' + origBody, 'utf8');
  fs.writeFileSync(path.join(dir, 'genres_fb2_xx.glst'), bom + body, 'utf8');
  const r = spawnSync(process.execPath, [CHECKER, dir], { encoding: 'utf8' });
  return { status: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

const checks = [
  ['a faithful translation passes', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Алтернативна история',
    ].join('\n'));
    return r.status === 0;
  }],

  ['a changed fb2 code fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_hystory;Алтернативна история',
    ].join('\n'));
    return r.status === 1 && /sf_history/.test(r.out);
  }],

  ['a changed tree path fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.9 sf_history;Алтернативна история',
    ].join('\n'));
    return r.status === 1 && /0\.1\.0/.test(r.out);
  }],

  ['a dropped line fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
    ].join('\n'));
    return r.status === 1 && /record count/i.test(r.out);
  }],

  ['a lost semicolon fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history Алтернативна история',
    ].join('\n'));
    return r.status === 1 && /is a category, original line 3 is a genre/.test(r.out);
  }],

  ['an empty translated name fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;',
    ].join('\n'));
    return r.status === 1 && /empty/i.test(r.out);
  }],

  ['a name identical to the original passes', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Альтернативная история',
    ].join('\n'));
    return r.status === 0;
  }],

  ['a missing BOM fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Алтернативна история',
    ].join('\n'), { bom: false });
    return r.status === 1 && /BOM/i.test(r.out);
  }],

  ['CRLF against an LF original fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Алтернативна история',
    ].join('\n'), { eol: '\r\n' });
    return r.status === 1 && /line endings are CRLF, the original uses LF/.test(r.out);
  }],

  ['LF against a CRLF original fails', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Алтернативна история',
    ].join('\n'), { originalEol: '\r\n' });
    return r.status === 1 && /line endings are LF, the original uses CRLF/.test(r.out);
  }],

  ['CRLF matching a CRLF original passes', () => {
    const r = run([
      '#---- comment ----',
      '0.1 Фантастика',
      '0.1.0 sf_history;Алтернативна история',
    ].join('\n'), { eol: '\r\n', originalEol: '\r\n' });
    return r.status === 0;
  }],

  ['a directory with no translated lists passes', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), `glstnone-`));
    fs.writeFileSync(path.join(dir, 'genres_fb2.glst'), '﻿' + ORIGINAL, 'utf8');
    const r = spawnSync(process.execPath, [CHECKER, dir], { encoding: 'utf8' });
    return r.status === 0;
  }],
];

let failed = 0;
checks.forEach(([name, fn], i) => {
  let ok = false;
  let err = '';
  try {
    ok = fn();
  } catch (e) {
    err = ` (${e.message})`;
  }
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${String(i + 1).padStart(2)}  ${name}${err}`);
});

console.log(`\n${checks.length - failed}/${checks.length} passed`);
process.exit(failed === 0 ? 0 : 1);

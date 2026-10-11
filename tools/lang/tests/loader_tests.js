'use strict';

// LangTest.exe is in no dproj: build it first (tools/lang/tests/build.sh).

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

// The real key, not a throwaway: only it proves the compiled-in public key matches.
const SIGN_KEY = process.env.MHL_LANG_KEY
  || path.join(os.homedir(), '.myhomelib', 'lang-signing-key.pem');

function signBytes(bytes) {
  const key = crypto.createPrivateKey(fs.readFileSync(SIGN_KEY));
  return crypto.sign('sha256', bytes, { key, dsaEncoding: 'ieee-p1363' });
}

const EXE = process.argv[2];
if (!EXE || !fs.existsSync(EXE)) {
  console.error('usage: node loader_tests.js <path-to-LangTest.exe>');
  process.exit(1);
}

const PROBES = ['Автор', 'Назва', 'Серія'];

let caseNo = 0;

// opts.locale -> [INTERFACE] Locale; opts.catalogs -> files in Lang\;
// opts.noLangDir -> no Lang\; opts.appFiles -> files beside the exe (genre lists).
function run(opts) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `langtest${caseNo++}-`));
  fs.copyFileSync(EXE, path.join(dir, 'LangTest.exe'));
  fs.writeFileSync(path.join(dir, 'probe.json'),
    JSON.stringify(PROBES), 'utf8');

  for (const [name, body] of Object.entries(opts.appFiles || {})) {
    fs.writeFileSync(path.join(dir, name), body, 'utf8');
  }

  const ini = opts.locale === undefined
    ? '[INTERFACE]\r\n'
    : `[INTERFACE]\r\nLocale=${opts.locale}\r\n`;
  fs.writeFileSync(path.join(dir, 'myhomelib2.ini'), ini, 'utf8');

  if (!opts.noLangDir) {
    const ld = path.join(dir, 'Lang');
    fs.mkdirSync(ld);
    for (const [name, body] of Object.entries(opts.catalogs || {})) {
      fs.writeFileSync(path.join(ld, name),
        typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
    }
    for (const [name, sig] of Object.entries(opts.sigs || {})) {
      fs.writeFileSync(path.join(ld, name), sig);
    }
  }

  const report = path.join(dir, 'report.json');
  const r = spawnSync(path.join(dir, 'LangTest.exe'),
    ['uselocaldata', report], { encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error(`harness exit ${r.status}: ${r.stderr || r.stdout}`);
  }
  // TEncoding.UTF8 writes a BOM, which JSON.parse refuses.
  return JSON.parse(fs.readFileSync(report, 'utf8').replace(/^﻿/, ''));
}

const checks = [
  ['uk: embedded identity catalog installs nothing', () => {
    const r = run({ locale: 'uk', noLangDir: true });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['uk is always offered even with no Lang directory at all', () => {
    const r = run({ locale: 'uk', noLangDir: true });
    return r.locales.some(l => l.code === 'uk' && l.name === 'Українська');
  }],

  ['en works with no Lang directory at all -- it is in the exe', () => {
    const r = run({ locale: 'en', noLangDir: true });
    return r.active === true
      && r.translations['Автор'] === 'Author'
      && r.translations['Назва'] === 'Title';
  }],

  ['en is offered with no Lang directory at all', () => {
    const r = run({ locale: 'en', noLangDir: true });
    return r.locales.some(l => l.code === 'en' && l.name === 'English');
  }],

  ['a file en.json cannot override the embedded English', () => {
    const r = run({ locale: 'en', catalogs: { 'en.json': {
      locale: 'en', name: 'English',
      strings: { k1: { source: 'Автор', target: 'HIJACKED' } }, dfm: {},
    } } });
    return r.active === true && r.translations['Автор'] === 'Author';
  }],

  // LANG_XX/LANG_ZZ are linked only into the harness (make_fixture_res.js) and
  // model unsigned catalogs a resource editor could add.
  ['an embedded catalog with no signature resource is not offered', () => {
    const r = run({ locale: 'uk', noLangDir: true });
    return !r.locales.some(l => l.code === 'xx');
  }],

  ['an embedded catalog with a bogus signature is not offered', () => {
    const r = run({ locale: 'uk', noLangDir: true });
    return !r.locales.some(l => l.code === 'zz');
  }],

  ['selecting an unsigned embedded locale falls back to Ukrainian', () => {
    const r = run({ locale: 'xx', noLangDir: true });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['selecting a bogusly signed embedded locale falls back to Ukrainian', () => {
    const r = run({ locale: 'zz', noLangDir: true });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['a file catalog declaring a different locale is refused', () => {
    const r = run({ locale: 'pl', catalogs: { 'pl.json': {
      locale: 'de', name: 'Polski',
      strings: { k1: { source: 'Автор', target: 'Autor' } }, dfm: {},
    } } });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['an unsigned foreign-locale catalog is refused', () => {
    const r = run({ locale: 'pl', catalogs: { 'pl.json': {
      locale: 'pl', name: 'Polski',
      strings: { k1: { source: 'Автор', target: 'Autor' } }, dfm: {},
    } } });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['an unsigned catalog is not offered in the language menu', () => {
    const r = run({ locale: 'uk', catalogs: { 'pl.json': {
      locale: 'pl', name: 'Polski',
      strings: { k1: { source: 'Автор', target: 'Autor' } }, dfm: {},
    } } });
    return !r.locales.some(l => l.code === 'pl');
  }],

  ['a signed foreign-locale catalog loads and is offered', () => {
    const body = JSON.stringify({ locale: 'pl', name: 'Polski',
      strings: { k1: { source: 'Автор', target: 'Autor' } }, dfm: {} });
    const r = run({ locale: 'pl',
      catalogs: { 'pl.json': body },
      sigs: { 'pl.json.sig': signBytes(Buffer.from(body, 'utf8')) } });
    return r.active === true
      && r.translations['Автор'] === 'Autor'
      && r.locales.some(l => l.code === 'pl' && l.name === 'Polski');
  }],

  // Must be SIGNED: unsigned catalogs are rejected before these rules run.
  ['malformed catalog does not crash and does not install', () => {
    const body = '{ this is not json';
    const r = run({ locale: 'pl',
      catalogs: { 'pl.json': body },
      sigs: { 'pl.json.sig': signBytes(Buffer.from(body, 'utf8')) } });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['all-identity catalog yields an empty index, so nothing installs', () => {
    const body = JSON.stringify({ locale: 'pl', name: 'Polski',
      strings: { k1: { source: 'Автор', target: 'Автор' } }, dfm: {} });
    const r = run({ locale: 'pl',
      catalogs: { 'pl.json': body },
      sigs: { 'pl.json.sig': signBytes(Buffer.from(body, 'utf8')) } });
    return r.active === false;
  }],

  ['empty target is ignored rather than blanking the string', () => {
    const body = JSON.stringify({ locale: 'pl', name: 'Polski',
      strings: {
        k1: { source: 'Автор', target: '   ' },
        k2: { source: 'Назва', target: 'Tytuł' },
      },
      dfm: {} });
    const r = run({ locale: 'pl',
      catalogs: { 'pl.json': body },
      sigs: { 'pl.json.sig': signBytes(Buffer.from(body, 'utf8')) } });
    return r.active === true
      && r.translations['Автор'] === 'Автор'
      && r.translations['Назва'] === 'Tytuł';
  }],

  ['missing Locale key defaults to uk', () => {
    const r = run({ noLangDir: true });
    return r.active === false && r.translations['Автор'] === 'Автор';
  }],

  ['verifier accepts a correctly signed catalog', () => {
    const body = JSON.stringify({ locale: 'verify', name: 'V',
      strings: { k1: { source: 'Автор', target: 'A' } }, dfm: {} });
    const r = run({ locale: 'uk',
      catalogs: { 'verify.json': body },
      sigs: { 'verify.json.sig': signBytes(Buffer.from(body, 'utf8')) } });
    return r.verify === true;
  }],

  ['verifier rejects a catalog with no signature at all', () => {
    const body = JSON.stringify({ locale: 'verify', name: 'V',
      strings: {}, dfm: {} });
    const r = run({ locale: 'uk', catalogs: { 'verify.json': body } });
    return r.verify === false;
  }],

  ['verifier rejects a one-byte tampered catalog', () => {
    const body = JSON.stringify({ locale: 'verify', name: 'V',
      strings: { k1: { source: 'Автор', target: 'A' } }, dfm: {} });
    const sig = signBytes(Buffer.from(body, 'utf8'));
    const r = run({ locale: 'uk',
      catalogs: { 'verify.json': body.replace('"A"', '"B"') },
      sigs: { 'verify.json.sig': sig } });
    return r.verify === false;
  }],

  ['verifier rejects a truncated signature', () => {
    const body = JSON.stringify({ locale: 'verify', name: 'V',
      strings: {}, dfm: {} });
    const sig = signBytes(Buffer.from(body, 'utf8')).subarray(0, 32);
    const r = run({ locale: 'uk',
      catalogs: { 'verify.json': body }, sigs: { 'verify.json.sig': sig } });
    return r.verify === false;
  }],

  ['verifier rejects a signature made with a different key', () => {
    const body = JSON.stringify({ locale: 'verify', name: 'V',
      strings: {}, dfm: {} });
    const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const sig = crypto.sign('sha256', Buffer.from(body, 'utf8'),
      { key: other.privateKey, dsaEncoding: 'ieee-p1363' });
    const r = run({ locale: 'uk',
      catalogs: { 'verify.json': body }, sigs: { 'verify.json.sig': sig } });
    return r.verify === false;
  }],

  ['bg works with no Lang directory at all -- it is in the exe', () => {
    // Not Автор: it is identical in Bulgarian and Ukrainian.
    const r = run({ locale: 'bg', noLangDir: true });
    return r.active === true
      && r.translations['Назва'] === 'Заглавие'
      && r.translations['Серія'] === 'Поредица';
  }],

  ['bg is offered with no Lang directory at all', () => {
    const r = run({ locale: 'bg', noLangDir: true });
    return r.locales.some(l => l.code === 'bg');
  }],

  ['bg carries its machine-translation disclosure in the menu name', () => {
    // This string is the disclosure's only path to users.
    const r = run({ locale: 'uk', noLangDir: true });
    const bg = r.locales.find(l => l.code === 'bg');
    return !!bg && /машинен превод/.test(bg.name);
  }],

  // These test which FILE resolves, not its content (check_glst.js does that).

  ['genres: no locale list present falls back to the Russian original', () => {
    const r = run({ locale: 'bg', noLangDir: true });
    return r.genres.fb2 === 'genres_fb2.glst'
      && r.genres.nonfb2 === 'genres_nonfb2.glst';
  }],

  ['genres: a matching locale list is preferred', () => {
    const r = run({
      locale: 'bg',
      noLangDir: true,
      appFiles: { 'genres_fb2_bg.glst': '﻿0.1 Фантастика\r\n' },
    });
    return r.genres.fb2 === 'genres_fb2_bg.glst';
  }],

  ['genres: fb2 and nonfb2 resolve independently', () => {
    // Catches resolving both lists from one existence check.
    const r = run({
      locale: 'bg',
      noLangDir: true,
      appFiles: { 'genres_fb2_bg.glst': '﻿0.1 Фантастика\r\n' },
    });
    return r.genres.fb2 === 'genres_fb2_bg.glst'
      && r.genres.nonfb2 === 'genres_nonfb2.glst';
  }],

  ['genres: a list for a different locale is ignored', () => {
    const r = run({
      locale: 'uk',
      noLangDir: true,
      appFiles: { 'genres_fb2_bg.glst': '﻿0.1 Фантастика\r\n' },
    });
    return r.genres.fb2 === 'genres_fb2.glst';
  }],

  ['genres: uk gets its own list when one is present', () => {
    const r = run({
      locale: 'uk',
      noLangDir: true,
      appFiles: { 'genres_fb2_uk.glst': '﻿0.1 Фантастика\r\n' },
    });
    return r.genres.fb2 === 'genres_fb2_uk.glst';
  }],
];

let failed = 0;
for (const [name, fn] of checks) {
  let ok = false, err = null;
  try { ok = fn(); } catch (e) { err = e; }
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${err ? ` (${err.message})` : ''}`);
}
console.log(`\n${checks.length - failed}/${checks.length} passed`);
process.exit(failed ? 1 : 0);

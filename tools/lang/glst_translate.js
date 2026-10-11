'use strict';

// A translator handed the whole file eventually perturbs a key, which fails
// silently. So `apply` walks the ORIGINAL and substitutes only names from the
// map; paths, fb2 codes, comments, BOM and EOLs cannot drift.
// Names are keyed by tree path: several genres share a name.
// <base> is genres_fb2 or genres_nonfb2.

const fs = require('fs');
const path = require('path');

// NOT Installer/Common: that is untracked build staging.
const DIR = path.join(__dirname, '..', '..', 'Installer', 'GenreLists');

function fail(message) {
  console.error(message);
  process.exit(1);
}

// Same shape as the parser in check_glst.js; change both together.
function read(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const hadBom = raw.charCodeAt(0) === 0xfeff;
  const body = hadBom ? raw.slice(1) : raw;
  const eol = body.includes('\r\n') ? '\r\n' : '\n';
  const lines = body.split(/\r?\n/);
  const trailingNewline = lines.length > 0 && lines[lines.length - 1] === '';
  if (trailingNewline) lines.pop();

  const records = lines.map((text) => {
    if (text.startsWith('#')) return { kind: 'comment', text };

    const sp = text.indexOf(' ');
    if (sp < 0) return { kind: 'other', text };

    const treePath = text.slice(0, sp);
    const rest = text.slice(sp + 1);
    const semi = rest.indexOf(';');
    if (semi < 0) return { kind: 'category', treePath, name: rest };

    return {
      kind: 'genre',
      treePath,
      code: rest.slice(0, semi),
      name: rest.slice(semi + 1),
    };
  });

  return { records, hadBom, eol, trailingNewline };
}

function originalPath(base) {
  const file = path.join(DIR, `${base}.glst`);
  if (!fs.existsSync(file)) fail(`no such genre list: ${file}`);
  return file;
}

function cmdExport(base, outFile) {
  if (!base || !outFile) {
    fail('Usage: glst_translate.js export <base> <out.json>');
  }

  const { records } = read(originalPath(base));
  const map = {};
  let categories = 0;
  let genres = 0;

  for (const r of records) {
    if (r.kind !== 'category' && r.kind !== 'genre') continue;
    if (map[r.treePath] !== undefined) {
      fail(`duplicate tree path "${r.treePath}" in ${base}.glst -- `
        + 'the map cannot be keyed by path');
    }
    map[r.treePath] = r.name;
    if (r.kind === 'category') categories++; else genres++;
  }

  fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify(map, null, 2) + '\n', 'utf8');

  console.log(`wrote ${outFile}`);
  console.log(`${categories + genres} names (${categories} categories, ${genres} genres)`);
  process.exit(0);
}

function cmdApply(base, locale, mapFile) {
  if (!base || !locale || !mapFile) {
    fail('Usage: glst_translate.js apply <base> <locale> <map.json>');
  }
  if (!/^[a-z]{2}$/.test(locale)) {
    fail(`locale must be two lowercase letters, got "${locale}"`);
  }

  let map;
  try {
    map = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
  } catch (e) {
    fail(`${mapFile} is not valid JSON (${e.message})`);
  }

  const src = read(originalPath(base));

  // Validate the whole map before writing: a partial map was written against
  // another revision of the list.
  const missing = [];
  const unknown = [];
  const empty = [];
  const known = new Set();

  for (const r of src.records) {
    if (r.kind !== 'category' && r.kind !== 'genre') continue;
    known.add(r.treePath);
    const t = map[r.treePath];
    if (t === undefined) missing.push(r.treePath);
    else if (typeof t !== 'string' || t.trim() === '') empty.push(r.treePath);
  }
  for (const key of Object.keys(map)) {
    if (!known.has(key)) unknown.push(key);
  }

  const report = (label, list) => {
    if (list.length === 0) return false;
    console.error(`${list.length} ${label}:`);
    for (const k of list.slice(0, 20)) console.error(`  ${k}`);
    if (list.length > 20) console.error(`  ... and ${list.length - 20} more`);
    return true;
  };

  let bad = false;
  bad = report('tree path(s) missing from the map', missing) || bad;
  bad = report('tree path(s) in the map that the list does not have', unknown) || bad;
  bad = report('empty translation(s)', empty) || bad;
  if (bad) process.exit(1);

  const out = src.records.map((r) => {
    switch (r.kind) {
      case 'comment':
      case 'other':
        return r.text;
      case 'category':
        return `${r.treePath} ${map[r.treePath]}`;
      case 'genre':
        return `${r.treePath} ${r.code};${map[r.treePath]}`;
      default:
        return '';
    }
  });

  const text = (src.hadBom ? '﻿' : '')
    + out.join(src.eol)
    + (src.trailingNewline ? src.eol : '');

  const outFile = path.join(DIR, `${base}_${locale}.glst`);
  fs.writeFileSync(outFile, text, 'utf8');

  console.log(`wrote ${outFile}`);
  console.log(`${out.length} records, ${src.eol === '\r\n' ? 'CRLF' : 'LF'}`
    + `, ${src.hadBom ? 'BOM' : 'no BOM'} -- copied from the original`);
  process.exit(0);
}

const [, , cmd, ...rest] = process.argv;
switch (cmd) {
  case 'export': cmdExport(rest[0], rest[1]); break;
  case 'apply': cmdApply(rest[0], rest[1], rest[2]); break;
  default:
    fail('Usage:\n'
      + '  node tools/lang/glst_translate.js export <base> <out.json>\n'
      + '  node tools/lang/glst_translate.js apply  <base> <locale> <map.json>');
}

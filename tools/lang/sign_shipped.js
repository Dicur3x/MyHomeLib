'use strict';

// Community catalogs are NOT signed here: each goes through sign.js after review
// (tools/lang/README.md, "Accepting a community translation").
//
// Key: the argument, else $MHL_LANG_KEY, else the sign.js default.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { EMBEDDED } = require('./embedded_locales');

const ROOT = path.join(__dirname, '..', '..');
const LANG_DIR = path.join(ROOT, 'Program', 'Lang');
const SIGN = path.join(__dirname, 'sign.js');

const keyPath = process.argv[2] || process.env.MHL_LANG_KEY;
if (keyPath && !fs.existsSync(keyPath)) {
  console.error(`ERROR: no key at ${keyPath}`);
  process.exit(1);
}

let failed = 0;
let signed = 0;

for (const code of EMBEDDED) {
  const file = path.join(LANG_DIR, `${code}.json`);
  if (!fs.existsSync(file)) {
    // A clone without the private catalog repo just builds with fewer languages.
    console.log(`SKIP  ${code}.json is not present`);
    continue;
  }

  const r = spawnSync(process.execPath, [SIGN, file], {
    encoding: 'utf8',
    env: keyPath ? { ...process.env, MHL_LANG_KEY: keyPath } : process.env,
  });
  process.stdout.write(r.stdout || '');
  process.stderr.write(r.stderr || '');

  if (r.status !== 0 || !fs.existsSync(`${file}.sig`)) {
    failed++;
  } else {
    signed++;
  }
}

console.log('');
console.log(`${signed} signed, ${failed} failed`);
if (failed > 0) {
  console.log('The build will keep refusing until every shipped catalog is signed.');
}
process.exit(failed > 0 ? 1 : 0);

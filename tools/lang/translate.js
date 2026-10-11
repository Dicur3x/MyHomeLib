'use strict';

// share one Russian string, and unit_Localization.pas LoadSection keeps the

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const LANG_DIR = path.join(REPO_ROOT, 'Program', 'Lang');

const CYRILLIC = /[\u0400-\u04FF]/;

function fail(message) {
  console.error(message);
  process.exit(1);
}

function catalogPath(locale) {
  return path.join(LANG_DIR, `${locale}.json`);
}

function loadCatalog(locale) {
  const file = catalogPath(locale);
  if (!fs.existsSync(file)) fail(`No catalog at ${file}.`);
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`${file} is not valid JSON (${e.message}).`);
  }
  for (const section of ['strings', 'dfm']) {
    const value = data[section];
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      fail(`${file}: "${section}" section is missing or not an object.`);
    }
  }
  return { file, data };
}

function writeCatalog(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2), { encoding: 'utf8' });
}

function groupOf(section, key) {
  if (section === 'dfm') return key.split('.')[0];
  const m = key.match(/^(.*?)_(rstr|rsrt|c_|[A-Z])/);
  return m ? m[1] : key;
}

function entries(data) {
  const out = [];
  for (const section of ['strings', 'dfm']) {
    for (const [key, entry] of Object.entries(data[section])) {
      out.push({ section, key, entry });
    }
  }
  return out;
}

function uniqueSources(data) {
  const map = new Map();
  for (const { section, key, entry } of entries(data)) {
    if (typeof entry.source !== 'string') continue;
    let rec = map.get(entry.source);
    if (!rec) {
      rec = { group: `${section}:${groupOf(section, key)}`, keys: [], target: '' };
      map.set(entry.source, rec);
    }
    rec.keys.push(key);
    if (!rec.target && typeof entry.target === 'string') rec.target = entry.target;
  }
  return map;
}

function cmdExport(locale, outFile) {
  if (!outFile) fail('Usage: translate.js export <locale> <out.json>');
  const { data } = loadCatalog(locale);
  const map = uniqueSources(data);

  const list = [];
  for (const [source, rec] of map) {
    list.push({
      group: rec.group,
      keys: rec.keys,
      needsTranslation: CYRILLIC.test(source),
      source,
      target: rec.target,
    });
  }
  list.sort((a, b) => (a.group < b.group ? -1 : a.group > b.group ? 1 : 0));

  fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify(list, null, 2), { encoding: 'utf8' });

  const cyr = list.filter((e) => e.needsTranslation).length;
  const done = list.filter((e) => e.target).length;
  console.log(`wrote ${outFile}`);
  console.log(
    `${list.length} unique sources (${cyr} need translation, ` +
    `${list.length - cyr} already Latin), ${done} already have a target`
  );

  const byGroup = new Map();
  for (const e of list) {
    if (!e.needsTranslation) continue;
    byGroup.set(e.group, (byGroup.get(e.group) || 0) + 1);
  }
  for (const [group, n] of [...byGroup].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(4)}  ${group}`);
  }
}

function loadMap(file) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`${file} is not valid JSON (${e.message}).`);
  }
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    fail(`${file} must be a flat JSON object of source -> target.`);
  }
  for (const [k, v] of Object.entries(data)) {
    if (typeof v !== 'string') {
      fail(`${file}: target for ${JSON.stringify(k)} is not a string.`);
    }
  }
  return data;
}

function cmdApply(locale, args) {
  const fillLatin = args.includes('--fill-latin');
  const mapFiles = args.filter((a) => !a.startsWith('--'));
  if (mapFiles.length === 0 && !fillLatin) {
    fail('Usage: translate.js apply <locale> <map.json>... [--fill-latin]');
  }

  const { file, data } = loadCatalog(locale);
  const known = new Set();
  for (const { entry } of entries(data)) {
    if (typeof entry.source === 'string') known.add(entry.source);
  }

  const merged = new Map();
  const unknown = [];
  const clashes = [];
  for (const mapFile of mapFiles) {
    for (const [source, target] of Object.entries(loadMap(mapFile))) {
      if (!known.has(source)) {
        unknown.push({ mapFile, source });
        continue;
      }
      const prev = merged.get(source);
      if (prev && prev.target !== target) {
        clashes.push({ source, a: prev, b: { target, file: mapFile } });
        continue;
      }
      merged.set(source, { target, file: mapFile });
    }
  }

  if (unknown.length > 0) {
    console.error(`${unknown.length} source(s) in the map files match no catalog entry:`);
    for (const u of unknown.slice(0, 20)) {
      console.error(`  [${u.mapFile}] ${JSON.stringify(u.source)}`);
    }
    if (unknown.length > 20) console.error(`  ... and ${unknown.length - 20} more`);
    fail('Refusing to apply: fix the source text (copy it from the worklist) and re-run.');
  }

  if (clashes.length > 0) {
    console.error(`${clashes.length} source(s) given two different targets:`);
    for (const c of clashes) {
      console.error(`  ${JSON.stringify(c.source)}`);
      console.error(`    [${c.a.file}] ${JSON.stringify(c.a.target)}`);
      console.error(`    [${c.b.file}] ${JSON.stringify(c.b.target)}`);
    }
    fail('Refusing to apply: one source can only have one translation.');
  }

  let written = 0;
  let latinFilled = 0;
  for (const { entry } of entries(data)) {
    const hit = merged.get(entry.source);
    if (hit) {
      if (entry.target !== hit.target) written++;
      entry.target = hit.target;
      delete entry.stale;
      delete entry.staleTarget;
    } else if (fillLatin && !entry.target && !CYRILLIC.test(entry.source)) {
      entry.target = entry.source;
      latinFilled++;
    }
  }

  writeCatalog(file, data);

  const all = entries(data);
  const empty = all.filter((e) => !e.entry.target).length;
  console.log(`${file}: ${written} target(s) written, ${latinFilled} filled as identity (Latin source)`);
  console.log(`${all.length - empty}/${all.length} entries have a target, ${empty} still empty`);
  if (empty > 0) {
    const remaining = new Set(all.filter((e) => !e.entry.target).map((e) => e.entry.source));
    console.log(`${remaining.size} unique source(s) remain untranslated. First few:`);
    for (const s of [...remaining].slice(0, 10)) console.log(`  ${JSON.stringify(s)}`);
  }
}

function cmdTable(locale, outFile) {
  if (!outFile) fail('Usage: translate.js table <locale> <out.md>');
  const { data } = loadCatalog(locale);
  const map = uniqueSources(data);

  const byGroup = new Map();
  for (const [source, rec] of map) {
    if (!byGroup.has(rec.group)) byGroup.set(rec.group, []);
    byGroup.get(rec.group).push({ source, ...rec });
  }

  const cell = (s) =>
    s.replace(/\r\n/g, ' ¶ ').replace(/\r|\n/g, ' ¶ ').replace(/\|/g, '\\|');

  const lines = [
    `# ${locale} translation review`,
    '',
    `${map.size} unique source strings, grouped by unit / form.`,
    '`¶` marks a line break in the original. Identical targets for one source',
    'are intentional: the runtime indexes by source text.',
    '',
  ];
  for (const group of [...byGroup.keys()].sort()) {
    const rows = byGroup.get(group);
    lines.push(`## ${group} (${rows.length})`, '');
    lines.push('| Russian | Translation | Used by |', '| --- | --- | --- |');
    for (const r of rows) {
      const used = r.keys.length === 1 ? r.keys[0] : `${r.keys[0]} +${r.keys.length - 1}`;
      lines.push(`| ${cell(r.source)} | ${cell(r.target)} | \`${cell(used)}\` |`);
    }
    lines.push('');
  }

  fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
  fs.writeFileSync(outFile, lines.join('\n'), { encoding: 'utf8' });
  console.log(`wrote ${outFile} (${map.size} rows in ${byGroup.size} groups)`);
}

function main() {
  const [command, locale, ...rest] = process.argv.slice(2);
  if (!command || !locale) {
    fail(
      'Usage:\n' +
      '  node tools/lang/translate.js export <locale> <out.json>\n' +
      '  node tools/lang/translate.js apply  <locale> <map.json>... [--fill-latin]\n' +
      '  node tools/lang/translate.js table  <locale> <out.md>'
    );
  }
  if (command === 'export') return cmdExport(locale, rest[0]);
  if (command === 'apply') return cmdApply(locale, rest);
  if (command === 'table') return cmdTable(locale, rest[0]);
  fail(`Unknown command "${command}".`);
}

if (require.main === module) {
  main();
}

module.exports = { uniqueSources, groupOf };

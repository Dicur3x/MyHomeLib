'use strict';

// different keys legitimately share the same Russian source string (e.g.
// eighteen different keys all have the source "Изменить"). That is fine as

const fs = require('fs');
const path = require('path');

const LANG_DIR = path.join(__dirname, '..', '..', 'Program', 'Lang');
const STRICT = process.argv.includes('--strict');

function loadCatalogs(dir) {
  const files = fs.readdirSync(dir)
    .filter((f) => f.toLowerCase().endsWith('.json'))
    .sort();

  const catalogs = [];
  const loadErrors = [];

  for (const file of files) {
    const full = path.join(dir, file);

    let raw;
    try {
      raw = fs.readFileSync(full, 'utf8');
    } catch (err) {
      loadErrors.push({ file, message: `could not read file (${err.message})` });
      continue;
    }

    let data;
    try {
      data = JSON.parse(raw);
    } catch (err) {
      loadErrors.push({ file, message: `invalid JSON (${err.message})` });
      continue;
    }

    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      loadErrors.push({ file, message: 'catalog root is not a JSON object' });
      continue;
    }

    let sectionTypeError = null;
    for (const sectionName of ['strings', 'dfm']) {
      if (!Object.prototype.hasOwnProperty.call(data, sectionName)) continue;
      const value = data[sectionName];
      const isPlainObject = typeof value === 'object' && value !== null && !Array.isArray(value);
      if (!isPlainObject) {
        sectionTypeError = `"${sectionName}" section is present but not an object (got ${JSON.stringify(value)})`;
        break;
      }
    }
    if (sectionTypeError) {
      loadErrors.push({ file, message: sectionTypeError });
      continue;
    }

    const strings = data.strings || {};
    const dfm = data.dfm || {};

    const merged = {};
    const malformedEntries = [];

    const ingest = (section, sectionName) => {
      for (const [key, entry] of Object.entries(section)) {
        const valid =
          typeof entry === 'object' &&
          entry !== null &&
          !Array.isArray(entry) &&
          typeof entry.source === 'string' &&
          typeof entry.target === 'string';

        if (!valid) {
          malformedEntries.push({
            key,
            section: sectionName,
            reason: `entry is not a { source, target } object (got ${JSON.stringify(entry)})`,
          });
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(merged, key)) {
          malformedEntries.push({
            key,
            section: sectionName,
            reason: 'key appears in both "strings" and "dfm" sections',
          });
          continue;
        }
        merged[key] = entry;
      }
    };
    ingest(strings, 'strings');
    ingest(dfm, 'dfm');

    catalogs.push({
      locale: typeof data.locale === 'string' && data.locale ? data.locale : path.basename(file, '.json'),
      file,
      merged,
      malformedEntries,
    });
  }

  return { catalogs, loadErrors };
}

function hasAccelerator(text) {
  return typeof text === 'string' && text.replace(/&&/g, '').includes('&');
}

function isNonEmpty(text) {
  return typeof text === 'string' && text.length > 0;
}

function findConflicts(catalog) {
  const bySource = new Map();
  for (const [key, entry] of Object.entries(catalog.merged)) {
    if (!isNonEmpty(entry.target)) continue;
    if (!bySource.has(entry.source)) bySource.set(entry.source, []);
    bySource.get(entry.source).push({ key, target: entry.target });
  }

  const conflicts = [];
  for (const [source, entries] of bySource) {
    const distinctTargets = new Set(entries.map((e) => e.target));
    if (distinctTargets.size > 1) {
      conflicts.push({ source, entries });
    }
  }
  return conflicts;
}

function findSourceMismatches(catalogs) {
  const byKey = new Map(); // key -> Map(locale -> source)
  for (const cat of catalogs) {
    for (const [key, entry] of Object.entries(cat.merged)) {
      if (!byKey.has(key)) byKey.set(key, new Map());
      byKey.get(key).set(cat.locale, entry.source);
    }
  }

  const mismatches = [];
  for (const key of Array.from(byKey.keys()).sort()) {
    const bySource = byKey.get(key);
    const distinct = new Set(bySource.values());
    if (distinct.size > 1) {
      mismatches.push({ key, bySource: Array.from(bySource.entries()) });
    }
  }
  return mismatches;
}

function findKeyDrift(catalogs) {
  const allKeys = new Set();
  for (const cat of catalogs) {
    for (const key of Object.keys(cat.merged)) allKeys.add(key);
  }

  const drift = [];
  for (const key of Array.from(allKeys).sort()) {
    const present = [];
    const missing = [];
    for (const cat of catalogs) {
      if (Object.prototype.hasOwnProperty.call(cat.merged, key)) {
        present.push(cat.locale);
      } else {
        missing.push(cat.locale);
      }
    }
    if (missing.length > 0) {
      drift.push({ key, present, missing });
    }
  }
  return drift;
}

function findAcceleratorMismatches(catalog) {
  const mismatches = [];
  for (const [key, entry] of Object.entries(catalog.merged)) {
    if (!isNonEmpty(entry.target)) continue;
    const sourceHasAmp = hasAccelerator(entry.source);
    const targetHasAmp = hasAccelerator(entry.target);
    if (sourceHasAmp !== targetHasAmp) {
      mismatches.push({ key, source: entry.source, target: entry.target });
    }
  }
  return mismatches;
}

function countTranslationState(catalog) {
  let total = 0;
  let translated = 0;
  let stale = 0;
  const untranslatedKeys = [];
  const staleKeys = [];
  for (const [key, entry] of Object.entries(catalog.merged)) {
    total++;
    if (isNonEmpty(entry.target)) {
      translated++;
    } else {
      untranslatedKeys.push(key);
    }
    if (entry.stale === true) {
      stale++;
      staleKeys.push(key);
    }
  }
  return { total, translated, stale, untranslatedKeys, staleKeys };
}

function analyzeSharedSources(catalog) {
  const bySource = new Map();
  for (const key of Object.keys(catalog.merged)) {
    const source = catalog.merged[key].source;
    if (!bySource.has(source)) bySource.set(source, []);
    bySource.get(source).push(key);
  }

  const total = Object.keys(catalog.merged).length;
  const distinct = bySource.size;
  const shared = [];
  for (const [source, keys] of bySource) {
    if (keys.length > 1) shared.push({ source, count: keys.length });
  }
  shared.sort((a, b) => b.count - a.count);

  return { total, distinct, shared };
}

// share one Russian source string. Without this filter, that identity
function findChains(catalog) {
  const bySource = new Map();
  for (const [key, entry] of Object.entries(catalog.merged)) {
    if (!isNonEmpty(entry.target)) continue;
    if (entry.target === entry.source) continue;
    if (!bySource.has(entry.source)) bySource.set(entry.source, []);
    bySource.get(entry.source).push(key);
  }

  const chains = [];
  for (const [key, entry] of Object.entries(catalog.merged)) {
    if (!isNonEmpty(entry.target)) continue;
    const sourceKeys = (bySource.get(entry.target) || []).filter((k) => k !== key);
    if (sourceKeys.length > 0) {
      chains.push({ key, text: entry.target, sourceKeys });
    }
  }
  return chains;
}

const FORMAT_SPEC = /%(?:%|(\d+:)?-?(?:\d+|\*)?(?:\.(?:\d+|\*))?([diuefgnmpsxDIUEFGNMPSX]))/g;

function formatSpecs(text) {
  const specs = [];
  let indexed = false;
  for (const m of text.matchAll(FORMAT_SPEC)) {
    if (m[0] === '%%') continue; // literal '%', carries no argument
    if (m[1]) indexed = true;
    specs.push(m[2].toLowerCase());
  }
  return { specs, indexed };
}

function findFormatMismatches(catalog) {
  const mismatches = [];
  for (const [key, entry] of Object.entries(catalog.merged)) {
    if (!isNonEmpty(entry.target)) continue;
    const src = formatSpecs(entry.source);
    const tgt = formatSpecs(entry.target);

    const positional = !src.indexed && !tgt.indexed;
    const same = positional
      ? src.specs.join(',') === tgt.specs.join(',')
      : [...src.specs].sort().join(',') === [...tgt.specs].sort().join(',');

    if (!same) {
      mismatches.push({
        key,
        source: entry.source,
        target: entry.target,
        sourceSpecs: src.specs,
        targetSpecs: tgt.specs,
      });
    }
  }
  return mismatches;
}

function main() {
  const { catalogs, loadErrors } = loadCatalogs(LANG_DIR);

  console.log('=== Localization catalog check ===');
  console.log(`Catalogs: ${catalogs.map((c) => c.file).join(', ') || '(none loaded)'}`);
  console.log('');

  console.log('--- Check 4: malformed catalogs / entries ---');
  let anyMalformed = false;
  for (const err of loadErrors) {
    anyMalformed = true;
    console.log(`  [${err.file}] FAILED TO LOAD -- ${err.message}`);
  }
  for (const cat of catalogs) {
    if (cat.malformedEntries.length === 0) continue;
    anyMalformed = true;
    console.log(`  [${cat.file}] ${cat.malformedEntries.length} malformed entrie(s):`);
    for (const m of cat.malformedEntries) {
      console.log(`    ${m.section}.${m.key} -- ${m.reason}`);
    }
  }
  if (!anyMalformed) {
    console.log('  OK - every catalog parsed and every entry is a well-formed { source, target } object.');
  }
  console.log('');

  if (catalogs.length === 0) {
    console.log('=== Result ===');
    console.log('FAIL - no catalog could be loaded');
    process.exit(1);
  }

  let anyAlwaysFail = anyMalformed;
  let anyStrictFail = false;

  const perLocaleConflicts = new Map();
  const perLocaleAccelMismatches = new Map();
  const perLocaleTranslationState = new Map();
  const perLocaleChains = new Map();
  const perLocaleFormatMismatches = new Map();

  for (const cat of catalogs) {
    const conflicts = findConflicts(cat);
    perLocaleConflicts.set(cat.locale, conflicts);
    if (conflicts.length > 0) anyAlwaysFail = true;

    const accel = findAcceleratorMismatches(cat);
    perLocaleAccelMismatches.set(cat.locale, accel);
    if (accel.length > 0) anyAlwaysFail = true;

    const chains = findChains(cat);
    perLocaleChains.set(cat.locale, chains);
    if (chains.length > 0) anyAlwaysFail = true;

    const formats = findFormatMismatches(cat);
    perLocaleFormatMismatches.set(cat.locale, formats);
    if (formats.length > 0) anyAlwaysFail = true;

    const state = countTranslationState(cat);
    perLocaleTranslationState.set(cat.locale, state);
    if (STRICT && (state.total - state.translated > 0 || state.stale > 0)) {
      anyStrictFail = true;
    }
  }

  const drift = findKeyDrift(catalogs);
  if (drift.length > 0) anyAlwaysFail = true;

  const sourceMismatches = findSourceMismatches(catalogs);
  if (sourceMismatches.length > 0) anyAlwaysFail = true;

  console.log('--- Check 1: conflicting targets for one source ---');
  let anyConflictAtAll = false;
  for (const cat of catalogs) {
    const conflicts = perLocaleConflicts.get(cat.locale);
    if (conflicts.length === 0) continue;
    anyConflictAtAll = true;
    console.log(`  [${cat.locale}] ${conflicts.length} conflicting source(s):`);
    for (const c of conflicts) {
      console.log(`    source: ${JSON.stringify(c.source)}`);
      for (const e of c.entries) {
        console.log(`      - ${e.key} => ${JSON.stringify(e.target)}`);
      }
    }
  }
  if (!anyConflictAtAll) {
    console.log('  OK - no source has two differing non-empty targets in any catalog.');
  }
  console.log('');

  console.log('--- Check 2: key-set drift across catalogs ---');
  if (drift.length === 0) {
    console.log('  OK - every key is present in every catalog.');
  } else {
    console.log(`  ${drift.length} key(s) not present in every catalog:`);
    for (const d of drift) {
      console.log(
        `    ${d.key} -- present in [${d.present.join(', ')}], missing from [${d.missing.join(', ')}]`
      );
    }
  }
  console.log('');

  console.log('--- Check 7: divergent source for the same key across catalogs ---');
  if (sourceMismatches.length === 0) {
    console.log('  OK - every catalog agrees on the source text for every shared key.');
  } else {
    console.log(`  ${sourceMismatches.length} key(s) with disagreeing source text:`);
    for (const s of sourceMismatches) {
      console.log(`    ${s.key}:`);
      for (const [locale, source] of s.bySource) {
        console.log(`      - ${locale}: ${JSON.stringify(source)}`);
      }
    }
  }
  console.log('');

  console.log('--- Check 3: accelerator mismatch ---');
  let anyAccelAtAll = false;
  for (const cat of catalogs) {
    const mismatches = perLocaleAccelMismatches.get(cat.locale);
    if (mismatches.length === 0) continue;
    anyAccelAtAll = true;
    console.log(`  [${cat.locale}] ${mismatches.length} mismatch(es):`);
    for (const m of mismatches) {
      console.log(
        `    ${m.key} -- source: ${JSON.stringify(m.source)}, target: ${JSON.stringify(m.target)}`
      );
    }
  }
  if (!anyAccelAtAll) {
    console.log('  OK - every translated entry keeps "&" in step with its source.');
  }
  console.log('');

  console.log('--- Check 8: translation chains within a catalog ---');
  let anyChainAtAll = false;
  for (const cat of catalogs) {
    const chains = perLocaleChains.get(cat.locale);
    if (chains.length === 0) continue;
    anyChainAtAll = true;
    console.log(`  [${cat.locale}] ${chains.length} chain(s):`);
    for (const c of chains) {
      for (const sourceKey of c.sourceKeys) {
        console.log(
          `    ${c.key}.target == ${sourceKey}.source -- shared text: ${JSON.stringify(c.text)}`
        );
      }
    }
  }
  if (!anyChainAtAll) {
    console.log('  OK - no target in any catalog is also a source in that same catalog.');
  }
  console.log('');

  console.log('--- Check 9: format-specifier agreement ---');
  let anyFormatAtAll = false;
  for (const cat of catalogs) {
    const mismatches = perLocaleFormatMismatches.get(cat.locale);
    if (mismatches.length === 0) continue;
    anyFormatAtAll = true;
    console.log(`  [${cat.locale}] ${mismatches.length} mismatch(es):`);
    for (const m of mismatches) {
      console.log(`    ${m.key} -- source [${m.sourceSpecs.join(' ')}] ${JSON.stringify(m.source)}`);
      console.log(`               target [${m.targetSpecs.join(' ')}] ${JSON.stringify(m.target)}`);
    }
  }
  if (!anyFormatAtAll) {
    console.log('  OK - every translated entry keeps its format specifiers, in order.');
  }
  console.log('');

  console.log('--- Checks 5/6 + per-locale summary (untranslated/stale reported always) ---');
  for (const cat of catalogs) {
    const state = perLocaleTranslationState.get(cat.locale);
    const conflicts = perLocaleConflicts.get(cat.locale);
    const untranslated = state.total - state.translated;
    console.log(
      `  ${cat.locale}: ${state.translated}/${state.total} translated, ` +
        `${untranslated} untranslated, ${state.stale} stale, ${conflicts.length} conflicts`
    );
  }
  console.log('');

  console.log('--- Corpus summary: shared sources ---');
  const shared = analyzeSharedSources(catalogs[0]);
  console.log(
    `  ${shared.distinct} distinct source text(s) across ${shared.total} entries ` +
      `(${shared.shared.length} source(s) shared by 2+ keys).`
  );
  console.log(
    '  Shared sources necessarily share ONE translation: filling in different ' +
      'targets for keys that share a source will silently discard all but one.'
  );
  if (shared.shared.length > 0) {
    const topN = shared.shared.slice(0, 5);
    console.log('  Top offenders:');
    for (const s of topN) {
      console.log(`    ${JSON.stringify(s.source)} -- ${s.count} keys`);
    }
  }
  console.log('');

  const fail = anyAlwaysFail || anyStrictFail;

  console.log('=== Result ===');
  if (!fail) {
    console.log(STRICT ? 'PASS (strict mode)' : 'PASS');
  } else {
    const reasons = [];
    if (anyMalformed) reasons.push('malformed catalog(s)/entrie(s)');
    if (anyConflictAtAll) reasons.push('conflicting targets for one source');
    if (drift.length > 0) reasons.push('key-set drift across catalogs');
    if (sourceMismatches.length > 0) reasons.push('divergent source for one or more keys across catalogs');
    if (anyAccelAtAll) reasons.push('accelerator mismatch');
    if (anyFormatAtAll) reasons.push('format-specifier mismatch');
    if (anyChainAtAll) reasons.push('translation chain (a target equals another entry\'s source)');
    if (anyStrictFail) reasons.push('untranslated/stale entries present (--strict)');
    console.log(`FAIL - ${reasons.join('; ')}`);
  }

  process.exit(fail ? 1 : 0);
}

main();

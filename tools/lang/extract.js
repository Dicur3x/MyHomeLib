'use strict';

// Reads the .drc, not .pas: resourcestrings are concatenated at compile time and
// TranslateText() matches the exact runtime text, which only the compiler knows.

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DRC_PATH = path.join(REPO_ROOT, 'Program', 'OUT', 'Bin64', 'MyHomeLib.drc');
const EXE_PATH = path.join(REPO_ROOT, 'Program', 'OUT', 'Bin64', 'MyHomeLib.exe');
const PROGRAM_DIR = path.join(REPO_ROOT, 'Program');
const LANG_DIR = path.join(REPO_ROOT, 'Program', 'Lang');
const ALLOWLIST_PATH = path.join(__dirname, 'vcl_allowlist.json');

// The .drc is written ~tens of ms before its .exe in the same build; a real stale
// .drc (exe rebuilt without /p:DCC_OutputDRCFile=true) is minutes or more older.
const STALE_TOLERANCE_MS = 5 * 60 * 1000;

// Russian was removed by decision (docs/superpowers/specs/2026-08-11-signed-lang-catalogs-design.md);
// do not re-add it. The Bulgarian name carries its machine-translation
// disclosure, which the language menu shows.
const LOCALES = [
  { code: 'uk', name: 'Українська' },
  { code: 'en', name: 'English' },
  { code: 'bg', name: 'Български (машинен превод)' },
];

// Combo boxes whose items are VALUES: their .Text is stored into book metadata
// and search filters, so translating items would corrupt data. (cbDate is
// translated: its .Text is read only when the user typed a date.)
const ITEMS_ARE_DATA = new Set(['cbLang', 'cbLibRate']);

const OURS = /^(frm_|frame_|unit_|Data_|dm_|FBD|SQLiteWrap_|BookInfoPanel_)/;
const PROPS = new Set(['Caption', 'Hint', 'Text', 'TextHint']);

function fail(message) {
  console.error(message);
  process.exit(1);
}

// Segment match, not substring: a checkout path containing "OUT" must not be skipped.
function isExcludedSegment(name) {
  const lower = name.toLowerCase();
  return lower === 'out' || lower === '__history';
}

// A .pas newer than the .drc holds an uncompiled resourcestring edit.
function findNewestPas(dir) {
  let best = null;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (isExcludedSegment(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const sub = findNewestPas(full);
      if (sub && (!best || sub.mtime > best.mtime)) best = sub;
    } else if (entry.isFile() && full.toLowerCase().endsWith('.pas')) {
      const mtime = fs.statSync(full).mtimeMs;
      if (!best || mtime > best.mtime) best = { mtime, file: full };
    }
  }
  return best;
}

function checkDrcFreshness() {
  if (!fs.existsSync(DRC_PATH)) {
    fail(`Build Win64 first: ${DRC_PATH} not found`);
  }
  if (!fs.existsSync(EXE_PATH)) {
    fail(`Build Win64 first: ${EXE_PATH} not found`);
  }
  const drcTime = fs.statSync(DRC_PATH).mtimeMs;
  const exeTime = fs.statSync(EXE_PATH).mtimeMs;
  if (drcTime + STALE_TOLERANCE_MS < exeTime) {
    fail(
      'MyHomeLib.drc is stale or missing. Rebuild with:\n' +
      '  msbuild Program\\MHL.groupproj /t:Build /p:Config=Release /p:Platform=Win64 /p:DCC_OutputDRCFile=true'
    );
  }
  const newestPas = findNewestPas(PROGRAM_DIR);
  if (newestPas && drcTime + STALE_TOLERANCE_MS < newestPas.mtime) {
    fail(
      `MyHomeLib.drc is stale: ${newestPas.file} was modified more recently ` +
      'than the .drc, so the .drc cannot reflect its current resourcestrings. Rebuild with:\n' +
      '  msbuild Program\\MHL.groupproj /t:Build /p:Config=Release /p:Platform=Win64 /p:DCC_OutputDRCFile=true'
    );
  }
}

// One pass, not chained .replace(): \\ must be consumed as one token, or C:\new
// loses its second backslash to the \n rule.
function decodeDrcValue(raw) {
  return raw.replace(/\\(x[0-9a-fA-F]{4}|[\s\S])/g, (_, esc) => {
    if (esc[0] === 'x') return String.fromCharCode(parseInt(esc.slice(1), 16));
    switch (esc) {
      case 'r': return '\r';
      case 'n': return '\n';
      case 't': return '\t';
      case 'a': return '\x07';
      case 'b': return '\b';
      case 'f': return '\f';
      case 'v': return '\v';
      case '0': return '\0';
      default: return esc;
    }
  });
}

function readDrc(drcPath, allowlist) {
  const lines = fs.readFileSync(drcPath, 'utf8').split(/\r?\n/);
  const out = new Map();
  let inTable = false;
  for (const line of lines) {
    if (line.startsWith('STRINGTABLE')) { inTable = true; continue; }
    if (!inTable) continue;
    const m = line.match(/^\t(\w+),\t+L"(.*)"$/);
    if (!m) continue;
    const [, name, raw] = m;
    const isOurs = OURS.test(name);
    const isAllowed = allowlist.includes(name);
    if (!isOurs && !isAllowed) continue;
    const text = decodeDrcValue(raw);
    // No Cyrillic filter for resourcestrings: many English ones are translatable,
    // and untranslatable ones are harmless (identity entries are never indexed).
    // The filter applies only to DFM values, against designer junk like 'Edit1'.
    if (text.trim() === '') continue;
    out.set(name, text);
  }
  return out;
}

// TTreeView Items.NodeData layout (reverse-engineered from a real blob):
//   byte version; int32 node count; byte len + UTF-16LE class name ("TTreeNode");
//   per node: fixed binary fields, byte caption length, UTF-16LE caption.
// Captions are found heuristically, so the count is checked against the header
// and a mismatch fails: a short read would drop captions silently.
function decodeNodeData(hex, where) {
  const buf = Buffer.from(hex.replace(/[^0-9A-Fa-f]/g, ''), 'hex');
  if (buf.length < 6) fail(`${where}: NodeData too short to hold a header`);

  const declared = buf.readInt32LE(1);
  const nameLen = buf[5];
  let pos = 6 + nameLen * 2;

  const out = [];
  for (let i = pos; i + 1 < buf.length; i++) {
    const n = buf[i];
    if (n < 2 || n > 120) continue;
    if (i + 1 + n * 2 > buf.length) continue;
    let s = '';
    let ok = true;
    for (let k = 0; k < n; k++) {
      const cp = buf.readUInt16LE(i + 1 + k * 2);
      // Printable ASCII or Cyrillic only; anything else is binary that looked
      // like a length prefix.
      if (cp < 0x20 || (cp > 0x7e && cp < 0x400) || cp > 0x4ff) { ok = false; break; }
      s += String.fromCharCode(cp);
    }
    if (ok && /\p{L}/u.test(s)) { out.push(s); i += n * 2; }
  }

  if (out.length !== declared) {
    fail(
      `${where}: NodeData declares ${declared} nodes but ${out.length} caption(s) ` +
      'were recovered. The blob format may have changed -- fix decodeNodeData ' +
      'rather than letting captions disappear from the catalogs.'
    );
  }
  return out.map((text, index) => [index, text]);
}

function decodeDfmValue(tok) {
  let out = '', i = 0;
  while (i < tok.length) {
    if (tok[i] === "'") {
      i++;
      while (i < tok.length) {
        if (tok[i] === "'") {
          if (tok[i + 1] === "'") { out += "'"; i += 2; continue; }
          i++; break;
        }
        out += tok[i++];
      }
    } else if (tok[i] === '#') {
      let n = '';
      i++;
      while (i < tok.length && /[0-9]/.test(tok[i])) n += tok[i++];
      out += String.fromCharCode(parseInt(n, 10));
    } else {
      i++;
    }
  }
  return out;
}

function readDfm(file) {
  const base = path.basename(file, '.dfm');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const stack = [];
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    let m;
    if ((m = t.match(/^(?:object|inherited|inline)\s+(\w+)\s*:/))) {
      stack.push({ type: 'object', label: m[1] });
      continue;
    }
    if ((m = t.match(/^(\w+)\s*=\s*<$/))) {
      stack.push({ type: 'collection', name: m[1], counter: 0 });
      continue;
    }
    if (t === 'item') {
      const top = stack[stack.length - 1];
      let label;
      if (top && top.type === 'collection') {
        label = `${top.name}[${top.counter}]`;
        top.counter++;
      } else {
        // Unreachable in a well-formed DFM.
        label = 'item';
      }
      stack.push({ type: 'item', label });
      continue;
    }
    if (t === 'end') { stack.pop(); continue; }
    if (t === 'end>') {
      stack.pop();
      stack.pop();
      continue;
    }
    // TTreeNode captions live only in the binary NodeData blob; neither the DFM
    // text parser nor the runtime walker can see them. frm_settings rewrites the
    // nodes itself in DoCreate.
    if (/^Items\.NodeData\s*=\s*\{$/.test(t)) {
      const owner = stack.filter((f) => f.label !== undefined).map((f) => f.label);
      let hex = '';
      let j = i + 1;
      while (j < lines.length && !/\}$/.test(lines[j].trim())) { hex += lines[j].trim(); j++; }
      if (j < lines.length) hex += lines[j].trim().replace(/\}$/, '');
      for (const [index, text] of decodeNodeData(hex, [base, ...owner].join('.'))) {
        found.push([[base, ...owner, `Nodes[${index}]`].join('.'), text]);
      }
      i = j;
      continue;
    }
    // The generic property regex cannot match a dotted name. The closing paren
    // shares a line with the final item.
    if (/^Items\.Strings\s*=\s*\($/.test(t)) {
      const owner = stack.filter((f) => f.label !== undefined).map((f) => f.label);
      // Absent from the catalog means it cannot be translated: fail-safe.
      const ownerName = owner[owner.length - 1];
      if (ITEMS_ARE_DATA.has(ownerName)) {
        let k = i + 1;
        while (k < lines.length && !/\)\s*$/.test(lines[k])) k++;
        i = k;
        continue;
      }
      let index = 0;
      let buf = '';
      let j = i + 1;
      let closed = false;
      while (j < lines.length && !closed) {
        let s = lines[j].trim();
        if (s === ')') { closed = true; break; }
        if (s.endsWith(')')) { s = s.slice(0, -1).trimEnd(); closed = true; }
        buf += s;
        if (buf.endsWith('+')) { buf = buf.slice(0, -1); j++; continue; }
        const value = decodeDfmValue(buf);
        buf = '';
        // Index counts every item so it matches the runtime Items[] index.
        if (/[Ѐ-ӿ]/.test(value)) {
          found.push([[base, ...owner, `Items[${index}]`].join('.'), value]);
        }
        index++;
        if (!closed) j++;
      }
      i = j;
      continue;
    }
    if ((m = t.match(/^(\w+)\s*=\s*(.*)$/))) {
      if (!PROPS.has(m[1])) continue;
      let tok = m[2];
      // A value may start on the next line ("Caption =" then "'part' +").
      // Adopt following lines only if the next non-empty one opens a string
      // literal (' or #), so a truly absent value swallows nothing.
      if (tok.trim() === '') {
        let j = i + 1;
        while (j < lines.length && lines[j].trim() === '') j++;
        if (j < lines.length && /^['#]/.test(lines[j].trim())) {
          tok = lines[j].trim();
          i = j;
        }
      }
      while (tok.trimEnd().endsWith('+') && i + 1 < lines.length) {
        tok = tok.trimEnd().slice(0, -1) + lines[++i].trim();
      }
      const value = decodeDfmValue(tok);
      if (!/[Ѐ-ӿ]/.test(value)) continue;
      const pathLabels = stack.filter((f) => f.label !== undefined).map((f) => f.label);
      found.push([[base, ...pathLabels, m[1]].join('.'), value]);
    }
  }
  return found;
}

function findDfmFiles(dir) {
  const results = [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (isExcludedSegment(entry.name)) continue;
    if (entry.isDirectory()) {
      results.push(...findDfmFiles(full));
    } else if (entry.isFile() && full.toLowerCase().endsWith('.dfm')) {
      results.push(full);
    }
  }
  return results;
}

function merge(existing, extracted) {
  const out = {};
  let newKeys = 0, droppedKeys = 0, staleKeys = 0;
  const extractedKeys = new Set(extracted.map(([key]) => key));
  for (const key of Object.keys(existing)) {
    if (!extractedKeys.has(key)) droppedKeys++;
  }
  for (const [key, source] of extracted) {
    const prev = existing[key];
    if (!prev) { out[key] = { source, target: '' }; newKeys++; continue; }
    const target = prev.target || '';
    const entry = { source, target };

    const justWentStale = prev.source !== source && !!target;

    // staleTarget snapshots the target when flagged, so a translator edit
    // clears the flag and plain re-extraction keeps it.
    const stillStale = prev.stale === true && target === prev.staleTarget;

    if (justWentStale || stillStale) {
      entry.stale = true;
      entry.staleTarget = target;
      staleKeys++;
    }
    out[key] = entry;
  }
  return { out, newKeys, droppedKeys, staleKeys };
}

function writeJsonNoBom(filePath, obj) {
  const json = JSON.stringify(obj, null, 2);
  fs.writeFileSync(filePath, json, { encoding: 'utf8' });
}

function loadExisting(filePath) {
  // A missing file is a first run. An unparsable one aborts everything: merging
  // against {} would blank every translation.
  if (!fs.existsSync(filePath)) return {};

  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (e) {
    fail(`Cannot read existing catalog ${filePath}: ${e.message}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    fail(`Existing catalog ${filePath} is not valid JSON (${e.message}). Refusing to continue -- fix the file or restore it from git before re-running.`);
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    fail(`Existing catalog ${filePath} does not have an object root. Refusing to continue -- fix the file or restore it from git before re-running.`);
  }

  return parsed;
}

function main() {
  checkDrcFreshness();

  const allowlist = JSON.parse(fs.readFileSync(ALLOWLIST_PATH, 'utf8'));

  const codeMap = readDrc(DRC_PATH, allowlist);
  const codeEntries = Array.from(codeMap.entries());

  const dfmFiles = findDfmFiles(PROGRAM_DIR);
  const dfmEntries = [];
  for (const file of dfmFiles) {
    dfmEntries.push(...readDfm(file));
  }

  if (!fs.existsSync(LANG_DIR)) {
    fs.mkdirSync(LANG_DIR, { recursive: true });
  }

  console.log(`Code strings extracted: ${codeEntries.length}`);
  console.log(`DFM files scanned: ${dfmFiles.length}`);
  console.log(`DFM strings extracted: ${dfmEntries.length}`);
  console.log('');

  // Validate every locale before writing any, so a broken catalog cannot leave
  // a partial write.
  const plans = LOCALES.map(({ code, name }) => {
    const filePath = path.join(LANG_DIR, `${code}.json`);
    const existing = loadExisting(filePath);
    return { code, name, filePath, existing };
  });

  for (const plan of plans) {
    const existingStrings = plan.existing.strings || {};
    const existingDfm = plan.existing.dfm || {};

    const stringsResult = merge(existingStrings, codeEntries);
    const dfmResult = merge(existingDfm, dfmEntries);

    let strings = stringsResult.out;
    let dfm = dfmResult.out;

    if (plan.code === 'uk') {
      // The base catalog is regenerated each run and can never be stale;
      // flagging it would make check_lang --strict fail on nothing.
      const reset = (section) => {
        for (const entry of Object.values(section)) {
          entry.target = entry.source;
          delete entry.stale;
          delete entry.staleTarget;
        }
      };
      reset(strings);
      reset(dfm);
    }

    plan.catalog = { locale: plan.code, name: plan.name, strings, dfm };
    plan.newKeys = stringsResult.newKeys + dfmResult.newKeys;
    plan.droppedKeys = stringsResult.droppedKeys + dfmResult.droppedKeys;
    plan.staleKeys = stringsResult.staleKeys + dfmResult.staleKeys;
  }

  for (const plan of plans) {
    writeJsonNoBom(plan.filePath, plan.catalog);
    console.log(
      `${plan.code} (${plan.name}): strings=${Object.keys(plan.catalog.strings).length} ` +
      `dfm=${Object.keys(plan.catalog.dfm).length} new=${plan.newKeys} dropped=${plan.droppedKeys} stale=${plan.staleKeys}`
    );
  }
}

if (require.main === module) {
  main();
}

module.exports = { merge, loadExisting, readDfm, findDfmFiles, findNewestPas };

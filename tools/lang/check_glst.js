'use strict';

// .glst lines: "#..." comment | "<path> <name>" category | "<path> <code>;<name>" genre.
// The path and fb2 code are keys (the database stores the code); a perturbed key
// fails silently -- books land in "Неотсортированное" -- so structure is compared
// positionally. Names are never compared: some Bulgarian names equal the Russian.

const fs = require('fs');
const path = require('path');

// Not Installer/Common: that is untracked build staging.
const DIR = process.argv[2]
  || path.join(__dirname, '..', '..', 'Installer', 'GenreLists');

const BASES = ['genres_fb2', 'genres_nonfb2'];

const problems = [];

function problem(file, message) {
  problems.push(`${file}: ${message}`);
}

// A trailing newline yields a final empty element that is not a record.
function parse(raw) {
  const hadBom = raw.charCodeAt(0) === 0xfeff;
  const body = hadBom ? raw.slice(1) : raw;
  const hadCrLf = body.includes('\r\n');
  const lines = body.split(/\r?\n/);
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();

  const records = lines.map((text, i) => {
    const no = i + 1;
    if (text.startsWith('#')) return { no, kind: 'comment' };

    const sp = text.indexOf(' ');
    if (sp < 0) return { no, kind: 'malformed', text };

    const treePath = text.slice(0, sp);
    const rest = text.slice(sp + 1);
    const semi = rest.indexOf(';');
    if (semi < 0) return { no, kind: 'category', treePath, name: rest };

    return {
      no,
      kind: 'genre',
      treePath,
      code: rest.slice(0, semi),
      name: rest.slice(semi + 1),
    };
  });

  return { records, hadBom, hadCrLf };
}

function compare(originalFile, translatedFile) {
  const orig = parse(fs.readFileSync(path.join(DIR, originalFile), 'utf8'));
  const tr = parse(fs.readFileSync(path.join(DIR, translatedFile), 'utf8'));

  // Compared against the original, not a fixed value: core.autocrlf makes the
  // files LF in git and CRLF in the working tree.
  if (orig.hadBom !== tr.hadBom) {
    problem(translatedFile, tr.hadBom
      ? 'has a UTF-8 BOM, the original has none'
      : 'missing UTF-8 BOM (the original has one)');
  }
  if (orig.hadCrLf !== tr.hadCrLf) {
    problem(translatedFile,
      `line endings are ${tr.hadCrLf ? 'CRLF' : 'LF'}, `
      + `the original uses ${orig.hadCrLf ? 'CRLF' : 'LF'}`);
  }

  if (orig.records.length !== tr.records.length) {
    problem(translatedFile,
      `record count ${tr.records.length}, original has ${orig.records.length}`);
    return; // positional comparison past this point is meaningless
  }

  for (let i = 0; i < orig.records.length; i++) {
    const o = orig.records[i];
    const t = tr.records[i];

    if (t.kind === 'malformed') {
      problem(translatedFile, `line ${t.no}: cannot parse ${JSON.stringify(t.text)}`);
      continue;
    }
    if (o.kind !== t.kind) {
      problem(translatedFile,
        `line ${t.no}: is a ${t.kind}, original line ${o.no} is a ${o.kind}`);
      continue;
    }
    if (o.kind === 'comment') continue;

    if (o.treePath !== t.treePath) {
      problem(translatedFile,
        `line ${t.no}: tree path "${t.treePath}", original has "${o.treePath}"`);
    }
    if (o.kind === 'genre' && o.code !== t.code) {
      problem(translatedFile,
        `line ${t.no}: fb2 code "${t.code}", original has "${o.code}"`);
    }
    if (t.name.trim() === '') {
      problem(translatedFile, `line ${t.no}: empty name`);
    }
  }
}

let checked = 0;
for (const base of BASES) {
  const original = `${base}.glst`;
  if (!fs.existsSync(path.join(DIR, original))) continue;

  const translated = fs.readdirSync(DIR)
    .filter((f) => new RegExp(`^${base}_[a-z]{2}\\.glst$`).test(f))
    .sort();

  for (const file of translated) {
    compare(original, file);
    checked++;
  }
}

if (problems.length > 0) {
  console.error(`${problems.length} problem(s):`);
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}

console.log(`check_glst: ${checked} translated list(s) OK`);
process.exit(0);

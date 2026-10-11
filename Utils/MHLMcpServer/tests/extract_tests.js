const { spawnSync } = require('child_process');
const path = require('path');

const exe = process.argv[2];
const fx = f => path.join(__dirname, 'fixtures', f);

function extract(file) {
  const run = spawnSync(exe, ['--extract', fx(file)], { encoding: 'utf8' });
  if (run.status !== 0) throw new Error(`exit ${run.status}: ${run.stderr}`);
  return JSON.parse(run.stdout);
}

function extractExpectFail(file) {
  const run = spawnSync(exe, ['--extract', fx(file)], { encoding: 'utf8' });
  return { status: run.status, stderr: run.stderr };
}

const checks = [
  ['structured: two sections', () => {
    const r = extract('structured.fb2');
    return r.structured === true
      && r.sections.length === 2
      && r.sections[0].title === 'Chapter One'
      && r.sections[1].title === 'Chapter Two';
  }],
  ['structured: section 0 slice has its own text, not section 1\'s', () => {
    const r = extract('structured.fb2');
    const slice = r.text.substr(r.sections[0].offset, r.sections[0].length);
    return slice.includes('Alpha text.') && !slice.includes('Beta text.');
  }],
  ['structured: section 1 slice has its own text, not section 0\'s', () => {
    const r = extract('structured.fb2');
    const slice = r.text.substr(r.sections[1].offset, r.sections[1].length);
    return slice.includes('Beta text.') && !slice.includes('Alpha text.');
  }],
  ['flat: one untitled section whose slice covers the (windows-1251) text', () => {
    const r = extract('flat.fb2');
    if (r.sections.length !== 1) return false;
    const s = r.sections[0];
    return r.text.includes('Текст без заголовків')
      && s.title === ''
      && r.text.substr(s.offset, s.length).includes('Текст без заголовків');
  }],
  ['broken: falls back to text, structured=false', () => {
    const r = extract('broken.fb2');
    return r.structured === false && r.text.includes('Salvageable text.');
  }],
  ['broken + windows-1251: fallback decodes Cyrillic correctly, not mojibake', () => {
    const r = extract('broken_cp1251.fb2');
    return r.structured === false
      && r.text.includes('Пошкоджений текст без закриття тегів.');
  }],
  ['broken: raw unescaped < resynchronises instead of truncating the rest of the book', () => {
    const r = extract('broken_raw_lt.fb2');
    return r.structured === false
      && r.text.includes('Price is 5')
      && r.text.includes('Second paragraph survives after resync.');
  }],
  ['broken: <binary> base64 payload is not emitted as text', () => {
    const r = extract('broken_binary.fb2');
    return r.structured === false
      && r.text.includes('Real content paragraph.')
      && !r.text.includes('QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=');
  }],
  // --extract does not expose Kind; this message is unique to eekNoText.
  ['picture-only: valid XML, empty body -> "has no extractable text", not "extraction failed"', () => {
    const r = extractExpectFail('picture_only.fb2');
    return r.status === 1
      && r.stderr.includes('FB2 book has no extractable text (likely picture-only or an empty body)');
  }],
  ['empty file: 0 bytes -> "extraction failed", not "has no extractable text"', () => {
    const r = extractExpectFail('empty.fb2');
    return r.status === 1
      && r.stderr.includes('FB2 extraction failed: no text could be recovered from this file')
      && !r.stderr.includes('picture-only');
  }],
];

let failed = 0;
for (const [name, fn] of checks) {
  let ok = false, err = '';
  try { ok = fn(); } catch (e) { err = e.message; }
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${err ? ' — ' + err : ''}`);
  if (!ok) failed++;
}
process.exit(failed ? 1 : 0);

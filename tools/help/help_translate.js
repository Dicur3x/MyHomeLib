'use strict';

// a translator supplies text, never structure. `build` takes each Russian

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const HELP = path.join(ROOT, 'Program', 'Help');
const TOPICS = path.join(__dirname, 'topics.json');

const TITLE_SUFFIX = {
  ru: 'Справка HomeLib Ru',
  uk: 'Довідка HomeLib Ru',
  en: 'HomeLib Ru Help',
  bg: 'Помощ за HomeLib Ru',
};

function fail(message) {
  console.error(message);
  process.exit(1);
}

function loadSpec() {
  return JSON.parse(fs.readFileSync(TOPICS, 'utf8'));
}

function cmdTitles(outFile) {
  if (!outFile) fail('Usage: help_translate.js titles <out.json>');

  const spec = loadSpec();
  const out = { sections: {}, topics: {} };

  for (const s of spec.sections) {
    out.sections[s.title] = s.title;
    for (const t of s.topics) out.topics[t.file] = t.title;
  }

  fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n', 'utf8');

  console.log(`wrote ${outFile}`);
  console.log(`${Object.keys(out.sections).length} section title(s), `
    + `${Object.keys(out.topics).length} topic title(s)`);
  process.exit(0);
}

function buildToc(spec, titles, cur, eol) {
  const lines = [''];
  const indexTitle = titles.topics['index.html'];

  lines.push(`<p class="nav-title"><a href="index.html">${indexTitle}</a></p>`);

  for (const s of spec.sections) {
    lines.push(`<p class="nav-section">${titles.sections[s.title]}</p>`);
    lines.push('<ul>');
    for (const t of s.topics) {
      if (t.file === 'index.html') continue;
      const label = titles.topics[t.file];
      const mark = t.file === cur ? ' class="cur" aria-current="page"' : '';
      lines.push(`<li><a href="${t.file}"${mark}>${label}</a></li>`);
    }
    lines.push('</ul>');
  }

  lines.push('');
  return lines.join(eol);
}

function blockEol(html, beginMarker, endMarker) {
  const a = html.indexOf(beginMarker);
  const b = html.indexOf(endMarker);
  if (a < 0 || b < 0 || b < a) return '\n';
  return html.slice(a + beginMarker.length, b).includes('\r\n') ? '\r\n' : '\n';
}

function replaceBetween(html, beginMarker, endMarker, replacement, what) {
  const a = html.indexOf(beginMarker);
  const b = html.indexOf(endMarker);
  if (a < 0 || b < 0 || b < a) fail(`${what}: markers not found or out of order`);
  return html.slice(0, a + beginMarker.length) + replacement + html.slice(b);
}

function cmdBuild(locale, titlesFile, bodyDir) {
  if (!locale || !titlesFile || !bodyDir) {
    fail('Usage: help_translate.js build <locale> <titles.json> <bodydir>');
  }
  if (!/^[a-z]{2}$/.test(locale)) fail(`locale must be two lowercase letters, got "${locale}"`);
  const suffix = TITLE_SUFFIX[locale];
  if (!suffix) fail(`no title suffix defined for "${locale}" -- add one here and in check_help.js`);

  const spec = loadSpec();
  const titles = JSON.parse(fs.readFileSync(titlesFile, 'utf8'));
  const allTopics = spec.sections.flatMap((s) => s.topics);

  const missing = [];
  for (const s of spec.sections) {
    if (!titles.sections?.[s.title]) missing.push(`section title: ${s.title}`);
  }
  for (const t of allTopics) {
    if (!titles.topics?.[t.file]) missing.push(`topic title: ${t.file}`);
    if (!fs.existsSync(path.join(bodyDir, t.file))) missing.push(`body: ${t.file}`);
    if (!fs.existsSync(path.join(HELP, t.file))) missing.push(`source page: ${t.file}`);
  }
  if (missing.length > 0) {
    console.error(`${missing.length} missing input(s):`);
    for (const m of missing.slice(0, 20)) console.error(`  ${m}`);
    if (missing.length > 20) console.error(`  ... and ${missing.length - 20} more`);
    process.exit(1);
  }

  const outDir = path.join(HELP, locale);
  fs.mkdirSync(outDir, { recursive: true });
  fs.copyFileSync(path.join(HELP, 'help.css'), path.join(outDir, 'help.css'));

  for (const t of allTopics) {
    let html = fs.readFileSync(path.join(HELP, t.file), 'utf8');
    const title = titles.topics[t.file];

    const tocEol = blockEol(html, '<!-- TOC:BEGIN -->', '<!-- TOC:END -->');
    const bodyEol = blockEol(html, '<!-- BODY:BEGIN -->', '<!-- BODY:END -->');
    const body = fs.readFileSync(path.join(bodyDir, t.file), 'utf8')
      .trim()
      .replace(/\r?\n/g, bodyEol);

    html = html.replace('<html lang="ru">', `<html lang="${locale}">`);

    const fullTitle = t.file === 'index.html' ? title : `${title} — ${suffix}`;
    html = html.replace(/<title>[^<]*<\/title>/, `<title>${fullTitle}</title>`);

    html = html.replace(/<h1>[\s\S]*?<\/h1>/, `<h1>${title}</h1>`);

    html = replaceBetween(html, '<!-- TOC:BEGIN -->', '<!-- TOC:END -->',
      buildToc(spec, titles, t.file, tocEol), `${t.file} TOC`);
    html = replaceBetween(html, '<!-- BODY:BEGIN -->', '<!-- BODY:END -->',
      bodyEol + body + bodyEol, `${t.file} body`);

    fs.writeFileSync(path.join(outDir, t.file), html, 'utf8');
  }

  console.log(`wrote ${allTopics.length} page(s) + help.css to ${outDir}`);
  console.log('run `node tools/help/check_help.js` to validate');
  process.exit(0);
}

// Rewrites the BODY block of the Russian source pages in place.
//
function cmdPatch(bodyDir) {
  if (!bodyDir) fail('Usage: help_translate.js patch <bodydir>');

  const spec = loadSpec();
  const allTopics = spec.sections.flatMap((s) => s.topics);
  const supplied = fs.readdirSync(bodyDir).filter((f) => f.endsWith('.html'));

  const unknown = supplied.filter((f) => !allTopics.some((t) => t.file === f));
  if (unknown.length > 0) {
    fail(`${unknown.length} file(s) in ${bodyDir} are not declared topics: `
      + unknown.slice(0, 10).join(', '));
  }

  let patched = 0;
  for (const file of supplied) {
    const page = path.join(HELP, file);
    let html = fs.readFileSync(page, 'utf8');

    const bodyEol = blockEol(html, '<!-- BODY:BEGIN -->', '<!-- BODY:END -->');
    const body = fs.readFileSync(path.join(bodyDir, file), 'utf8')
      .trim()
      .replace(/\r?\n/g, bodyEol);

    html = replaceBetween(html, '<!-- BODY:BEGIN -->', '<!-- BODY:END -->',
      bodyEol + body + bodyEol, `${file} body`);

    fs.writeFileSync(page, html, 'utf8');
    patched++;
  }

  console.log(`patched ${patched} source page(s) in ${HELP}`);
  console.log('run `node tools/help/check_help.js` to validate');
  process.exit(0);
}

const [, , cmd, ...rest] = process.argv;
switch (cmd) {
  case 'titles': cmdTitles(rest[0]); break;
  case 'build': cmdBuild(rest[0], rest[1], rest[2]); break;
  case 'patch': cmdPatch(rest[0]); break;
  default:
    fail('Usage:\n'
      + '  node tools/help/help_translate.js titles <out.json>\n'
      + '  node tools/help/help_translate.js build <locale> <titles.json> <bodydir>\n'
      + '  node tools/help/help_translate.js patch <bodydir>');
}

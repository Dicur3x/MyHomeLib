const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const exe = process.argv[2];
if (!exe || !fs.existsSync(exe)) {
  console.error(`Server exe not found: ${exe}`);
  process.exit(2);
}

const ARGS = ['--make-fixture', 'uselocaldata', 'user', 'mcpfixture'];

let failed = 0;
function check(name, ok, detail) {
  if (ok) { console.log(`PASS ${name}`); }
  else { failed++; console.log(`FAIL ${name}`); if (detail) console.log(`  ${detail}`); }
}

const run = spawnSync(exe, ARGS, { encoding: 'utf8' });
check('exit code 0', run.status === 0, `status=${run.status} stderr=${run.stderr.trim()}`);

const lines = (run.stdout || '').split(/\r?\n/).filter(l => l.trim());
check('exactly one stdout line', lines.length === 1, `got ${lines.length} lines`);

let summary = null;
try { summary = JSON.parse(lines[0]); } catch (e) {}
check('summary parses as JSON', summary !== null, lines[0]);

if (summary) {
  check('collection_id is 1', summary.collection_id === 1, `got ${summary.collection_id}`);
  check('system db exists', fs.existsSync(summary.db), summary.db);
  check('collection root exists', fs.existsSync(summary.root), summary.root);
  check('books is an array', Array.isArray(summary.books), typeof summary.books);
}

if (summary && Array.isArray(summary.books)) {
  check('six books', summary.books.length === 6, `got ${summary.books.length}`);
  check('ids are 1..6',
    summary.books.every((b, i) => b.book_id === i + 1),
    JSON.stringify(summary.books.map(b => b.book_id)));
  check('every book file exists',
    summary.books.every(b => fs.existsSync(b.path)),
    JSON.stringify(summary.books.map(b => b.path)));
  check('deleted book is last',
    summary.books[5] && summary.books[5].title === 'Вилучена книга',
    JSON.stringify(summary.books[5]));
}

const again = spawnSync(exe, ARGS, { encoding: 'utf8' });
let second = null;
try { second = JSON.parse((again.stdout || '').split(/\r?\n/).filter(l => l.trim())[0]); } catch (e) {}
check('second run is idempotent', again.status === 0 && second && second.collection_id === 1,
  `status=${again.status} stderr=${again.stderr.trim()}`);

// TMHLSettings.Create seeds <user>.ini from myhomelib2.ini when missing.
const iniPath = path.join(path.dirname(exe), 'mcpfixture.ini');
const iniText = fs.existsSync(iniPath) ? fs.readFileSync(iniPath, 'utf8') : null;
check('mcpfixture.ini exists', iniText !== null, iniPath);
check('mcpfixture.ini carries no inherited settings',
  iniText !== null && !iniText.split(/\r?\n/).some(l => /^\s*[\[\w]/.test(l)),
  `${iniPath}: ${JSON.stringify((iniText || '').slice(0, 200))}`);

// Without the switches an unguarded build would delete the REAL system
// database, so this runs a copy in a sandbox with a `uselocaldata` marker and a
// sentinel at the path an unguarded build would delete.
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'mhlmcp-guard-'));
try {
  const exeDir = path.dirname(exe);
  const sandboxExe = path.join(sandbox, path.basename(exe));
  fs.copyFileSync(exe, sandboxExe);
  fs.copyFileSync(path.join(exeDir, 'sqlite3.dll'), path.join(sandbox, 'sqlite3.dll'));
  fs.writeFileSync(path.join(sandbox, 'uselocaldata'), '');

  const sentinelDir = path.join(sandbox, 'Data');
  const sentinel = path.join(sentinelDir, 'user.dbs2');
  const SENTINEL = 'stand-in for the real system database; must survive';
  fs.mkdirSync(sentinelDir);
  fs.writeFileSync(sentinel, SENTINEL);

  const bare = spawnSync(sandboxExe, ['--make-fixture'], { encoding: 'utf8' });
  const bareErr = (bare.stderr || '').trim();

  check('guard: bare --make-fixture exits non-zero', bare.status !== 0,
    `status=${bare.status}`);
  check('guard: bare --make-fixture writes nothing to stdout',
    (bare.stdout || '').trim() === '', JSON.stringify(bare.stdout));
  check('guard: stderr names the refusal and the required switches',
    /refuses to run against/.test(bareErr) &&
    /user\.dbs2/i.test(bareErr) &&
    /uselocaldata user mcpfixture/.test(bareErr),
    bareErr);
  check('guard: the system database was NOT deleted',
    fs.existsSync(sentinel) && fs.readFileSync(sentinel, 'utf8') === SENTINEL,
    sentinel);
  check('guard: the collection folder was NOT created',
    !fs.existsSync(path.join(sandbox, 'mcpfixture')),
    path.join(sandbox, 'mcpfixture'));
} finally {
  try { fs.rmSync(sandbox, { recursive: true, force: true }); } catch (e) {}
}

process.exit(failed ? 1 : 0);

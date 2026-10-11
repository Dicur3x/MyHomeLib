const { spawnSync } = require('child_process');

const exe = process.argv[2];

const run = spawnSync(exe, ['--cache-selftest'], { encoding: 'utf8' });
if (run.status !== 0) {
  console.error(`--cache-selftest exited ${run.status}: ${run.stderr}`);
  process.exit(2);
}

let result;
try {
  result = JSON.parse(run.stdout.trim());
} catch (e) {
  console.error(`--cache-selftest did not print a single JSON line: ${e.message}`);
  console.error(`stdout: ${run.stdout}`);
  console.error(`stderr: ${run.stderr}`);
  process.exit(2);
}

let failed = 0;
for (const c of result.checks) {
  console.log(`${c.pass ? 'PASS' : 'FAIL'} ${c.name}${c.detail ? ' — ' + c.detail : ''}`);
  if (!c.pass) failed++;
}

process.exit(failed ? 1 : 0);

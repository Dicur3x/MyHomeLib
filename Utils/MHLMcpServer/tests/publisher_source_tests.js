const { spawnSync } = require('child_process');
const exe = process.argv[2];
if (!exe) {
  console.error('Usage: node publisher_source_tests.js <MHLMcpServer.exe>');
  process.exit(2);
}
const run = spawnSync(exe, ['--publisher-source-selftest'], {
  encoding: 'utf8', timeout: 120000,
});
if (run.status !== 0) {
  console.error(`Publisher source self-test failed: ${run.error || run.stderr}`);
  process.exit(2);
}
let result;
try {
  result = JSON.parse(run.stdout.trim());
} catch (error) {
  console.error(`Invalid self-test output: ${error.message}\n${run.stdout}`);
  process.exit(2);
}
if (!Array.isArray(result.checks) || result.checks.length < 10) {
  console.error('Publisher source self-test did not finish all checks');
  process.exit(2);
}
for (const check of result.checks) {
  console.log(`${check.pass ? 'PASS' : 'FAIL'} ${check.name}`);
}
process.exit(result.checks.every(check => check.pass === true) ? 0 : 1);

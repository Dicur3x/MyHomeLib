'use strict';
// Validate the actual ZIP and install it over a previous release in TEMP only.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const cp = require('node:child_process'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const [testerArg, previousArg, candidateArg, python = 'python'] = process.argv.slice(2);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'HomeLibRu-update-test-real-release-'));
const installation = path.join(root, 'installation'), job = path.join(root, 'job');
const archive = path.join(root, 'release.zip'), unpacked = path.join(root, 'unpacked');
const tester = fs.realpathSync(testerArg);
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const read = filename => fs.readFileSync(filename);
function execute(exe, args) {
  const run = cp.spawnSync(exe, args, {encoding: 'utf8', windowsHide: true, timeout: 60000});
  assert.ifError(run.error); assert.equal(run.status, 0, run.stdout + run.stderr);
  return run.stdout;
}
function unpack(source, destination) {
  // Published/candidate distributions are also checked by the native validator.
  const script = 'import sys,zipfile,pathlib\nroot=pathlib.Path(sys.argv[2]).resolve()\nwith zipfile.ZipFile(sys.argv[1]) as z:\n assert z.testzip() is None\n for n in z.namelist():\n  p=(root/n).resolve()\n  assert p.is_relative_to(root)\n z.extractall(root)';
  execute(python, ['-c', script, source, destination]);
}
function files(folder, prefix = '') {
  return fs.readdirSync(folder, {withFileTypes: true}).flatMap(item => {
    const name = prefix + item.name, full = path.join(folder, item.name);
    return item.isDirectory() ? files(full, name + '/') : [name];
  });
}
fs.copyFileSync(candidateArg, archive);
unpack(previousArg, installation); unpack(archive, unpacked);
const manifest = JSON.parse(read(path.join(unpacked, 'HomeLibRu.update.json')));
assert.equal(manifest.release, '2.7.0_pre5.13');
const payload = new Set(manifest.files.map(entry => entry.path));
assert.equal(payload.size, manifest.files.length);
for (const entry of manifest.files) {
  const bytes = read(path.join(unpacked, entry.path));
  assert.equal(bytes.length, entry.size); assert.equal(sha(bytes), entry.sha256);
  assert(!/^(Data|Presets)\//i.test(entry.path));
}
assert.deepEqual(files(unpacked).sort(), [...payload, 'HomeLibRu.update.json'].sort());
fs.writeFileSync(path.join(installation, 'uselocaldata'), '');
execute(path.join(installation, 'MHLMcpServer.exe'), ['--make-fixture', 'uselocaldata', 'user', 'mcpfixture']);
const profiles = {'myhomelib2.ini': '[SYSTEM]\r\nCheckUpdates=0\r\n',
  'presets.cxml2': 'isolated saved presets', 'Readers/AlReader/options.ini': 'saved reader options',
  'Readers/SumatraPDF/SumatraPDF-settings.txt': 'saved reading history'};
for (const [name, contents] of Object.entries(profiles)) fs.writeFileSync(path.join(installation, name), contents);
const protectedFiles = files(installation).filter(name => !payload.has(name) && name !== 'HomeLibRu.update.json');
const before = protectedFiles.map(name => sha(read(path.join(installation, name))));
execute(tester, ['--prepare', archive, sha(read(archive)), manifest.release, job]);
execute(tester, ['--install', job, installation]);
assert.deepEqual(protectedFiles.map(name => sha(read(path.join(installation, name)))), before);
for (const entry of manifest.files) assert.equal(sha(read(path.join(installation, entry.path))), entry.sha256);
console.log(`PASS ${manifest.platform}: actual ZIP CRC, ${payload.size} manifest files, installation over previous release, ${protectedFiles.length} profile/library files preserved`);
console.log(`Artifacts: ${root}`);

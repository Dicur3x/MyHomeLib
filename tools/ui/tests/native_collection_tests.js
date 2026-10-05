"use strict";

// Runs only freshly built native tests, each beside an isolated runtime copy.
// Usage: node native_collection_tests.js <runtime-dir> <GenreRegistryTest.exe>
//        <MetabibImportTest.exe> <CollectionViewsTest.exe>
// The native tests create their own tiny fixtures; no existing Data/profile is copied.
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const marker = "HomeLib Ru isolated native regression v1";
const [runtimeArg, genreArg, importArg, viewsArg] = process.argv.slice(2);
if (!runtimeArg || !genreArg || !importArg || !viewsArg) {
  console.error("Usage: node native_collection_tests.js <runtime-dir> <GenreRegistryTest.exe> <MetabibImportTest.exe> <CollectionViewsTest.exe>");
  process.exit(2);
}
const runtime = fs.realpathSync(runtimeArg);
const tests = [genreArg, importArg, viewsArg].map(p => fs.realpathSync(p));
const names = ["GenreRegistryTest.exe", "MetabibImportTest.exe", "CollectionViewsTest.exe"];
function machine(file) {
  const data = fs.readFileSync(file);
  if (data.length < 64 || data.toString("ascii", 0, 2) !== "MZ") throw new Error(`Invalid PE file: ${file}`);
  const offset = data.readUInt32LE(0x3c);
  if (offset + 6 > data.length || data.readUInt32LE(offset) !== 0x4550) throw new Error(`Invalid PE header: ${file}`);
  return data.readUInt16LE(offset + 4);
}
for (let i = 0; i < tests.length; i++) {
  if (path.basename(tests[i]).toLowerCase() !== names[i].toLowerCase()) throw new Error(`Expected ${names[i]}: ${tests[i]}`);
}
const architecture = machine(tests[0]);
if (![0x14c, 0x8664].includes(architecture)) throw new Error("Tests must be x86 or x64.");
for (const exe of tests) if (machine(exe) !== architecture) throw new Error("Native test architectures differ.");
if (machine(path.join(runtime, "sqlite3.dll")) !== architecture) throw new Error("SQLite DLL architecture does not match tests.");
const modes = ["genre-order", "", "language-isolation", "favorites-add", "genre-link", "source-genres", "publisher-selection", "reader-compatibility"];
const requiredViews = {
  "genre-order": ["PASS Unsorted is last"],
  "": ["PASS unopened genre filter", "PASS first series visit", "PASS changed deletion filter", "PASS visible genre view", "PASS first group visit", "PASS empty author selection"],
  "language-isolation": ["PASS language choice survives"],
  "favorites-add": ["PASS adding a book before first group visit"],
  "genre-link": ["PASS genre link restores"],
  "source-genres": ["PASS imported source genre survives"],
  "publisher-selection": ["PASS deferred publisher view restores"],
  "reader-compatibility": ["PASS plain FB2 reader preserves ordinary paths"],
};
function requiredPasses(executable, mode) {
  if (path.basename(executable).toLowerCase() === "metabibimporttest.exe") return [
    "PASS production import registers", "PASS conflicting source import", "PASS production importer stops",
    "PASS production INPX import", "PASS production book stream", "PASS single-source full INPX update",
    "PASS production script extraction", "PASS production uppercase FB2 export", "PASS production same-title batch extraction",
  ];
  if (path.basename(executable).toLowerCase() === "collectionviewstest.exe") return [
    "PASS header menu keeps column IDs", "PASS default author selection and saved book", ...requiredViews[mode || ""],
  ];
  return ["PASS registry preservation"];
}
function copyDllTree(source, target) {
  fs.mkdirSync(target, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const src = path.join(source, entry.name), dst = path.join(target, entry.name);
    if (entry.isDirectory()) copyDllTree(src, dst);
    else if (entry.isFile() && /\.dll$/i.test(entry.name)) fs.copyFileSync(src, dst);
  }
}
function stage(folder, executable) {
  fs.copyFileSync(executable, path.join(folder, path.basename(executable)));
  for (const name of ["sqlite3.dll", "libzstd.dll", "libeay32.dll", "ssleay32.dll", "homelib_webp.dll"]) {
    const src = path.join(runtime, name);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(folder, name));
  }
  const decoder = path.join(runtime, "tools", "webp", "libwebp.dll");
  if (!fs.existsSync(decoder) || machine(decoder) !== architecture) throw new Error("WebP decoder is absent or has the wrong architecture.");
  const decoderDir = path.join(folder, "tools", "webp");
  fs.mkdirSync(decoderDir, { recursive: true });
  fs.copyFileSync(decoder, path.join(decoderDir, "libwebp.dll"));
  // Icons and bundled genres contain no personal profiles or library databases.
  if (fs.existsSync(path.join(runtime, "Icons"))) copyDllTree(path.join(runtime, "Icons"), path.join(folder, "Icons"));
  for (const name of fs.readdirSync(runtime)) if (/^genres[^\\/]*\.glst$/i.test(name)) fs.copyFileSync(path.join(runtime, name), path.join(folder, name));
  fs.writeFileSync(path.join(folder, "uselocaldata"), "");
  fs.writeFileSync(path.join(folder, "uselocaltemp"), "");
  fs.writeFileSync(path.join(folder, "native-regression.marker"), marker, "utf8");
  fs.writeFileSync(path.join(folder, "myhomelib2.ini"), [
    "[SYSTEM]", "CheckUpdates=0", "CheckLibrusecUpdates=0", "[INTERFACE]", "Locale=ru", "ActivePage=0",
    "[BEHAVIOR]", "CoverPanel=0", "ShowCover=0", "ShowAnnotation=0", "AutoLoadReview=0", "IgnoreAbsentArchives=1",
    "[OPDS]", "Enabled=0", "", // A network server is never started by view regression.
  ].join("\r\n"), "utf8");
}
function run(executable, mode) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder);
  const expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  try {
    stage(folder, executable);
    const exe = path.join(folder, path.basename(executable));
    const result = cp.spawnSync(exe, mode ? [mode] : [], { cwd: folder, encoding: "utf8", timeout: 60000, windowsHide: true, maxBuffer: 2 * 1024 * 1024 });
    const output = (result.stdout || "") + (result.stderr || "");
    process.stdout.write(`${path.basename(exe)}${mode ? ` (${mode})` : ""}:\n${output}`);
    if (result.error) throw result.error;
    if (result.status !== 0 || !/^PASS\b/m.test(output) || /^FAIL\b/m.test(output)) throw new Error(`Native test failed: ${path.basename(exe)} ${mode || "default"}, exit ${result.status}`);
    for (const expected of requiredPasses(executable, mode)) {
      if (!output.includes(expected)) throw new Error(`Native test did not run required scenario (${expected}); reload and rebuild its DPR from disk.`);
    }
  } finally {
    // Only this process's verified, unique temporary runtime is removed.
    if (absolute.startsWith(expectedRoot) && path.basename(absolute).startsWith("HomeLibRu-native-")) fs.rmSync(absolute, { recursive: true, force: true });
  }
}
try {
  run(tests[0], "");
  run(tests[1], "");
  for (const mode of modes) run(tests[2], mode);
  console.log(`PASS all native collection regressions (${architecture === 0x8664 ? "x64" : "x86"}); only temporary fixtures used`);
} catch (error) {
  console.error(`FAIL ${error.stack || error}`);
  process.exitCode = 1;
}

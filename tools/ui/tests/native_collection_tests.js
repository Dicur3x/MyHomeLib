"use strict";

// Runs only freshly built native tests, each beside an isolated runtime copy.
// Usage: node native_collection_tests.js <runtime-dir> <GenreRegistryTest.exe>
//        <MetabibImportTest.exe> <CollectionViewsTest.exe>
// The native tests create their own tiny fixtures; no existing Data/profile is copied.
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const http = require("http");
const marker = "HomeLib Ru isolated native regression v1";
const [runtimeArg, genreArg, importArg, viewsArg] = process.argv.slice(2);
const onlineOnly = process.argv.includes("--online-only");
const archiveOnly = process.argv.includes("--online-archive-only");
const plainOnly = process.argv.includes("--online-plain-only");
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
const modes = ["genre-order", "", "language-isolation", "favorites-add", "genre-link", "source-genres", "publisher-selection", "reader-compatibility", "read-folder-cleanup", "temp-exit-cleanup"];
const requiredViews = {
  "genre-order": ["PASS Unsorted is last"],
  "": ["PASS unopened genre filter", "PASS first series visit", "PASS changed deletion filter", "PASS visible genre view", "PASS first group visit", "PASS empty author selection"],
  "language-isolation": ["PASS language choice survives"],
  "favorites-add": ["PASS adding a book before first group visit"],
  "genre-link": ["PASS genre link restores"],
  "source-genres": ["PASS imported source genre survives"],
  "publisher-selection": ["PASS deferred publisher view restores"],
  "reader-compatibility": ["PASS plain FB2 reader preserves ordinary paths"],
  "read-folder-cleanup": ["PASS manual reader cleanup", "PASS custom reading folder is cleared", "PASS reader cleanup does not follow"],
  "temp-exit-cleanup": ["PASS real main-form exit removes temporary converted copies"],
  "online-download": ["PASS online main reader downloads ZIP", "PASS online main queue downloads ZIP", "PASS online main queue restarts for another remote book"],
  "online-plain": ["PASS plain online FB2 is downloaded before compatibility conversion"],
};
function requiredPasses(executable, mode) {
  if (path.basename(executable).toLowerCase() === "metabibimporttest.exe") return [
    "PASS production import registers", "PASS conflicting source import", "PASS production importer stops",
    "PASS production INPX import", "PASS production book stream", "PASS single-source full INPX update",
    "PASS production script extraction", "PASS production uppercase FB2 export", "PASS production same-title batch extraction",
    "PASS ordinary single-source online INPX", "PASS mixed-source online INPX",
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
    "[OPDS]", "Enabled=0", "", // OPDS is never started; dedicated online tests use only loopback.
  ].join("\r\n"), "utf8");
}
function run(executable, mode) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder);
  const expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  try {
    stage(folder, executable);
    if (mode === "read-folder-cleanup") {
      const reading = path.join(folder, "junction-reading"), target = path.join(folder, "junction-target");
      fs.mkdirSync(reading); fs.mkdirSync(target);
      fs.writeFileSync(path.join(reading, "ordinary.tmp"), "isolated root cleanup probe");
      fs.writeFileSync(path.join(target, "keep.fb2"), "junction target must survive");
      fs.symlinkSync(target, path.join(reading, "webp-png"), "junction");
    }
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
async function runOnline(executable, mode) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder), expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  const requests = [];
  const expected = mode === "online-plain" ? ["/b/900003/get"] : ["/b/900001/get", "/b/900002/get", "/b/900004/get"];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if (req.method !== "GET" || !expected.includes(req.url)) { res.writeHead(404); res.end(); return; }
    const filename = mode === "online-plain" ? "online-plain-response.fb2" : "download-response.zip";
    try {
      const payload = fs.readFileSync(path.join(folder, filename));
      res.writeHead(200, { "Content-Type": mode === "online-plain" ? "application/fb2+xml" : "application/zip", "Content-Length": payload.length });
      res.end(payload);
    } catch (error) { res.writeHead(500); res.end(String(error)); }
  });
  try {
    stage(folder, executable);
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    const exe = path.join(folder, path.basename(executable)), port = server.address().port;
    const output = await new Promise((resolve, reject) => {
      const child = cp.spawn(exe, [mode, String(port)], { cwd: folder, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
      let text = "", timedOut = false;
      const timer = setTimeout(() => { timedOut = true; child.kill(); }, 60000);
      const collect = data => { text += data.toString("utf8"); if (text.length > 2 * 1024 * 1024) child.kill(); };
      child.stdout.on("data", collect); child.stderr.on("data", collect);
      child.once("error", error => { clearTimeout(timer); reject(error); });
      child.once("close", status => {
        clearTimeout(timer);
        process.stdout.write(`${path.basename(exe)} (${mode}):\n${text}`);
        if (timedOut || status !== 0 || /^FAIL\b/m.test(text)) reject(new Error(`Native online test failed: ${mode}, exit ${status}${timedOut ? ", timed out" : ""}`));
        else resolve(text);
      });
    });
    for (const marker of requiredPasses(executable, mode)) if (!output.includes(marker)) throw new Error(`Native online test omitted ${marker}; reload and rebuild DPR.`);
    if (JSON.stringify(requests) !== JSON.stringify(expected.map(url => `GET ${url}`))) throw new Error(`Unexpected online requests: ${JSON.stringify(requests)}`);
    console.log(`PASS exact loopback requests for main ${mode}; repeated reads use the downloaded book`);
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    if (absolute.startsWith(expectedRoot) && path.basename(absolute).startsWith("HomeLibRu-native-")) fs.rmSync(absolute, { recursive: true, force: true });
  }
}
(async () => {
try {
  if (!onlineOnly && !archiveOnly && !plainOnly) {
    run(tests[0], "");
    run(tests[1], "");
    for (const mode of modes) run(tests[2], mode);
  }
  if (!plainOnly) await runOnline(tests[2], "online-download");
  if (!archiveOnly) await runOnline(tests[2], "online-plain");
  console.log(`PASS all native collection regressions (${architecture === 0x8664 ? "x64" : "x86"}); only temporary fixtures used`);
} catch (error) {
  console.error(`FAIL ${error.stack || error}`);
  process.exitCode = 1;
}
})();

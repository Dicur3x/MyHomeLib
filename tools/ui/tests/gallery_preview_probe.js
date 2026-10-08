"use strict";
// Interactive gallery check in a unique profile containing generated test pictures.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const [runtimeArg, fixtureArg, mode = 'book-gallery'] = process.argv.slice(2);
if (!['book-gallery', 'column-filters', 'catalog-sources-ui', 'book-information'].includes(mode)) throw new Error('Unsupported isolated visual scenario');
if (!runtimeArg || !fixtureArg) throw new Error("Usage: node gallery_preview_probe.js <runtime> <CollectionViewsTest.exe>");
const runtime = fs.realpathSync(runtimeArg), fixture = fs.realpathSync(fixtureArg);
const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-gallery-"));
for (const entry of fs.readdirSync(runtime, {withFileTypes: true})) {
  if (entry.isFile() && /\.(dll|glst)$/i.test(entry.name)) fs.copyFileSync(path.join(runtime, entry.name), path.join(folder, entry.name));
  if (entry.isDirectory() && ["Icons", "tools"].includes(entry.name)) fs.cpSync(path.join(runtime, entry.name), path.join(folder, entry.name), {recursive: true});
}
fs.copyFileSync(fixture, path.join(folder, "CollectionViewsTest.exe"));
fs.copyFileSync(path.resolve(__dirname, "../../../Installer/Components.json"), path.join(folder, "COMPONENTS.json"));
for (const name of ["uselocaldata", "uselocaltemp"]) fs.writeFileSync(path.join(folder, name), "");
fs.writeFileSync(path.join(folder, "native-regression.marker"), "HomeLib Ru isolated native regression v1");
fs.writeFileSync(path.join(folder, "myhomelib2.ini"), "[SYSTEM]\r\nCheckUpdates=0\r\nCheckLibrusecUpdates=0\r\n[INTERFACE]\r\nLocale=ru\r\n[BEHAVIOR]\r\nCoverPanel=0\r\nShowCover=0\r\nShowAnnotation=0\r\nIgnoreAbsentArchives=1\r\n[OPDS]\r\nEnabled=0\r\n");
console.log(`Isolated gallery profile: ${folder}`);
if (mode === 'book-information') require('./book_information_fixture')(runtime, folder);
const app = cp.spawn(path.join(folder, "CollectionViewsTest.exe"), [mode, "visual"], {cwd: folder, windowsHide: true, stdio: "inherit"});
app.on("error", error => { console.error(error); process.exitCode = 1; });
app.on("exit", code => { console.log(`Gallery exit: ${code}`); if (code !== 0) process.exitCode = 1; });

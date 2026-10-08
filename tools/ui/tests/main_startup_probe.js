"use strict";
// Run the real application with a small native fixture, never the owner's profile.
// Close its window normally after inspection; the probe reports the actual exit.
// Close other HomeLib Ru instances first: its single-instance check can exit 0
// without showing a new window. Confirm the probe's own window before closing it.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const [runtimeArg, fixtureArg, pageArg = "6"] = process.argv.slice(2);
if (!runtimeArg || !fixtureArg || !(/^[0-6]$/.test(pageArg) || pageArg === 'first-run'))
  throw new Error("Usage: node main_startup_probe.js <runtime> <CollectionViewsTest.exe> [saved page 0..6 or first-run]");
const runtime = fs.realpathSync(runtimeArg), fixture = fs.realpathSync(fixtureArg);
const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-startup-"));
for (const entry of fs.readdirSync(runtime, {withFileTypes: true})) {
  if (entry.isFile() && (/\.(dll|glst)$/i.test(entry.name) || entry.name === "HomeLibRu.exe"))
    fs.copyFileSync(path.join(runtime, entry.name), path.join(folder, entry.name));
  if (entry.isDirectory() && ["Icons", "tools", "Help", "Readers"].includes(entry.name))
    fs.cpSync(path.join(runtime, entry.name), path.join(folder, entry.name), {recursive: true});
}
fs.copyFileSync(fixture, path.join(folder, "CollectionViewsTest.exe"));
for (const marker of ["uselocaldata", "uselocaltemp"]) fs.writeFileSync(path.join(folder, marker), "");
fs.writeFileSync(path.join(folder, "native-regression.marker"), "HomeLib Ru isolated native regression v1");
fs.writeFileSync(path.join(folder, "myhomelib2.ini"), "[SYSTEM]\r\nCheckUpdates=0\r\nCheckLibrusecUpdates=0\r\nProgramCheckMinutes=0\r\n[INTERFACE]\r\nLocale=ru\r\n[BEHAVIOR]\r\nCoverPanel=0\r\nShowCover=0\r\nShowAnnotation=0\r\nAutoLoadReview=0\r\nIgnoreAbsentArchives=1\r\n");
if (pageArg !== 'first-run') {
const result = cp.spawnSync(path.join(folder, "CollectionViewsTest.exe"), ["publisher-selection"],
  {cwd: folder, encoding: "utf8", windowsHide: true, timeout: 60000});
if (result.status !== 0) throw new Error(`Fixture preparation failed: ${result.stdout}\n${result.stderr}`);
let ini = fs.readFileSync(path.join(folder, "myhomelib2.ini"), "utf8");
for (const [key, value] of Object.entries({ActivePage: pageArg, CoverPanel: 1, ShowCover: 1,
  ShowAnnotation: 1, InfoPanelHeight: 310, FormWidth: 1173, FormHeight: 1073, WindowState: 0,
  Splitters: "250;250;250;250;250;434"})) {
  const pattern = new RegExp(`^${key}=.*$`, "m");
  if (!pattern.test(ini)) throw new Error(`Native fixture did not save ${key}`);
  ini = ini.replace(pattern, `${key}=${value}\r`);
}
fs.writeFileSync(path.join(folder, "myhomelib2.ini"), ini);
} else {
  fs.mkdirSync(path.join(folder, 'Books'));
}
fs.copyFileSync(path.resolve(__dirname, '../../../Installer/Components.json'), path.join(folder, 'COMPONENTS.json'));
console.log(`Isolated profile: ${folder}`);
// This is an interactive smoke probe: inspect and close the application window.
const app = cp.spawn(path.join(folder, "HomeLibRu.exe"), [], {cwd: folder, stdio: "ignore"});
console.log(`Actual application PID: ${app.pid}; saved page ${pageArg}`);
app.on("error", error => { console.error(error); process.exitCode = 1; });
app.on("exit", (code, signal) => {
  console.log(`Actual application exit: ${code}; signal: ${signal || "none"}`);
  if (code !== 0) process.exitCode = 1;
});

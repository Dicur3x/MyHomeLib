"use strict";
// Run already built native export tests in disposable profiles; no private Data is copied.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const [runtimeArg, exportArg, uiArg] = process.argv.slice(2);
const selector = process.argv[5] || "all";
if (!["all", "metadata", "worker", "ui"].includes(selector)) throw new Error("Unknown export test selector");
if (!runtimeArg || !exportArg || !uiArg) throw new Error("Usage: node export_tests.js <runtime> <MetabibExportTest.exe> <GroupExportUITest.exe>");
const runtime = fs.realpathSync(runtimeArg);
const cases = [[exportArg, "MetabibExportTest.exe", selector === "metadata" ? ["PASS metadata_roundtrip", "PASS snapshot_literal_text_roundtrip"] : selector === "worker" ? ["PASS group export preserves all author cycles", "PASS downloaded_online_book"] : ["PASS metadata_roundtrip", "PASS snapshot_literal_text_roundtrip", "PASS group export preserves all author cycles", "PASS downloaded_online_book"]],
  [uiArg, "GroupExportUITest.exe", ["PASS group_ignores_view_filters", "PASS active collection does not restrict", "PASS first-use"]]];
function machine(file) {
  const b = fs.readFileSync(file), offset = b.readUInt32LE(0x3c);
  if (b.toString("ascii", 0, 2) !== "MZ" || b.readUInt32LE(offset) !== 0x4550) throw new Error("Invalid PE");
  return b.readUInt16LE(offset + 4);
}
for (const [sourceArg, expectedName, expectedPasses] of cases) {
  if (selector === "ui" && expectedName !== "GroupExportUITest.exe") continue;
  if (["metadata", "worker"].includes(selector) && expectedName === "GroupExportUITest.exe") continue;
  const source = fs.realpathSync(sourceArg);
  if (path.basename(source).toLowerCase() !== expectedName.toLowerCase()) throw new Error("Unexpected test executable");
  if (machine(source) !== machine(path.join(runtime, "sqlite3.dll"))) throw new Error("Test architecture differs from SQLite");
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-export-"));
  fs.copyFileSync(source, path.join(folder, expectedName));
  for (const entry of fs.readdirSync(runtime, {withFileTypes:true})) {
    if (entry.isFile() && /(?:\.dll|\.glst)$/i.test(entry.name)) fs.copyFileSync(path.join(runtime, entry.name), path.join(folder, entry.name));
    if (entry.isDirectory() && ["Icons", "tools"].includes(entry.name)) fs.cpSync(path.join(runtime, entry.name), path.join(folder, entry.name), {recursive:true});
  }
  for (const marker of ["uselocaldata", "uselocaltemp"]) fs.writeFileSync(path.join(folder, marker), "");
  fs.writeFileSync(path.join(folder, "native-regression.marker"), "HomeLib Ru isolated native regression v1", "utf8");
  fs.writeFileSync(path.join(folder, "myhomelib2.ini"), "[SYSTEM]\r\nCheckUpdates=0\r\nCheckLibrusecUpdates=0\r\nProgramCheckMinutes=0\r\n[INTERFACE]\r\nLocale=ru\r\n[BEHAVIOR]\r\nIgnoreAbsentArchives=1\r\n", "utf8");
  const args = expectedName === "MetabibExportTest.exe" ? [selector] : [];
  const result = cp.spawnSync(path.join(folder, expectedName), args, {cwd:folder,encoding:"utf8",windowsHide:true,timeout:900000,maxBuffer:2*1024*1024});
  process.stdout.write(`${expectedName}:\n${result.stdout || ""}${result.stderr || ""}Artifacts: ${folder}\n`);
  if (result.error) throw result.error;
  if (result.status !== 0 || /^FAIL\b/m.test(result.stdout || "")) throw new Error(`Native export failed (${result.status})`);
  for (const expected of expectedPasses) if (!(result.stdout || "").includes(expected)) throw new Error(`Scenario not run: ${expected}`);
}

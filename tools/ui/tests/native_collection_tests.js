"use strict";

// Runs only freshly built native tests, each beside an isolated runtime copy.
// Usage: node native_collection_tests.js <runtime-dir> <GenreRegistryTest.exe>
//        <MetabibImportTest.exe> <CollectionViewsTest.exe>
// The native tests create their own tiny fixtures; no existing Data/profile is copied.
// Optional --views-mode=<name> runs one local main-form scenario.
// --core-only runs the genre registry and production import scenarios.
// --views-mode=native-folder-picker is interactive (Computer Use); excluded from the batch.
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const http = require("http");
const marker = "HomeLib Ru isolated native regression v1";
const [runtimeArg, genreArg, importArg, viewsArg] = process.argv.slice(2);
const offlineOnly = process.argv.includes("--offline-only");
const coreOnly = process.argv.includes("--core-only");
const keepFixtures = process.argv.includes("--keep");
const largeInpxArg = process.argv.find(arg => arg.startsWith("--large-inpx="));
const onlineOnly = process.argv.includes("--online-only");
const archiveOnly = process.argv.includes("--online-archive-only");
const plainOnly = process.argv.includes("--online-plain-only");
const reviewsOnly = process.argv.includes("--online-reviews-only");
const auditCaseArg = process.argv.find(arg => arg.startsWith('--audit-case='));
const viewsModeArg = process.argv.find(arg => arg.startsWith("--views-mode="));
const amberArchiveArg = process.argv.find(arg => arg.startsWith("--amber-archive="));
const previewBookArg = process.argv.find(arg => arg.startsWith("--preview-book="));
const readerFixturesArg = process.argv.find(arg => arg.startsWith("--reader-fixtures="));
const conversionFixturesArg = process.argv.find(arg => arg.startsWith("--conversion-fixtures="));
const viewsMode = viewsModeArg ? viewsModeArg.slice("--views-mode=".length) : null;
const visualCache = process.argv.includes("--visual-cache");
const visualUI = process.argv.includes("--visual-ui");
const toolProbe = process.argv.includes("--tool-probe");
if (toolProbe && (viewsMode !== "feedback22" || visualUI)) throw new Error("Tool probe requires feedback22 without visual-ui");
const visualRecords = process.argv.includes('--visual-records');
const proposalVisualModes = ['metadata-book-columns-visual', 'main-search-proposals-visual', 'catalog-proposals-visual', 'reader-notes-visual', 'update-proposals-visual'];
if (visualRecords && viewsMode !== 'feedback21') throw new Error('Visual records inspection requires feedback21');
const visualUpdate = process.argv.includes("--visual-update");
if (visualUpdate && viewsMode !== "program-update-ui") throw new Error("Visual update inspection requires --views-mode=program-update-ui");
if (visualUI && !["oct11-ui", "feedback22", "settings-workflow-audit"].includes(viewsMode)) throw new Error("Visual inspection requires --views-mode=oct11-ui, feedback22 or settings-workflow-audit");
if (visualCache && viewsMode !== "persistent-cache") throw new Error("Visual cache inspection requires --views-mode=persistent-cache");
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
const modes = ["metadata-book-columns", "author-display-setting", "export-results-audit", "search-query-modes", "legacy-import-preview", "inp-streaming", "inp-streaming-memory", "reader-notes-proposals", "update-keyboard-accessibility", "update-source-failures", "reader-conversion-audit", "settings-workflow-audit", "catalog-audit", "export-preparation", "feedback22", "feedback21", "metadata-archive-codecs", "feedback20-main", "update-form-notifier", "book-preview-layout", "metadata-fill-layout", "metadata-fill-ui", "collection-metadata-sync", "metabib-size","reader-pipeline-cache","conversion-menu","publisher-metadata-index","main-toolbar-states", "main-publisher-index-cache", "feedback19-main","catalog-sources-workflow","search-startup-layout","queue-serialization","queue-persistence","queue-load-negative","queue-load-truncated","queue-load-zero","search-preset-transfer","external-reader-names","metadata-prefix-bounds","ordinary-book-export-identity","atomic-ini","group-book-identity","reader-copy-identity","favorite-ui","update-outcomes","system-remap","favorite-columns","author-favorites","favorite-dao","publisher-search","publisher-columns","filter-captions","deleted-filter","cache-presets","search-presets","builtin-export","series-stream","fbd-editor-save","update-theme","bulk-writes","query-batch","oct11-ui","merge-scale","audit-new","persistent-cache","feedback14","book-preview","large-inpx","genre-order", "", "language-isolation", "favorites-add", "genre-link", "source-genres", "publisher-selection", "adjacent-series", "publisher-startup", "publisher-links", "publisher-error-log", "reader-compatibility", "builtin-reader", "loose-archive", "book-gallery", "book-information", "column-filters", "list-performance", "collection-merge", "catalog-sources", "read-folder-cleanup", "temp-exit-cleanup", "program-update-ui", "first-run", "first-run-cancel"];
if (viewsMode !== null && !modes.includes(viewsMode) && !['main-search-proposals-visual','catalog-proposals-visual','reader-notes-visual','update-proposals-visual','native-folder-picker','cancel-interactive','export-cancel-interactive','legacy-import-interactive','reader-filter','reader-main-filter','reader-chapters'].includes(viewsMode)) throw new Error(`Unknown view scenario: ${viewsMode}`);
const requiredViews = {"metadata-book-columns-visual": ["PASS metadata columns visual fixture closed explicitly"], "metadata-book-columns": ["PASS metadata columns actual header menus expose four new IDs once and preserve default layouts", "PASS metadata columns DAO-backed rows render publisher translators city year ISBN in all six book lists and groups", "PASS metadata columns numeric year order empty Unicode yo exact and combined filters on flat and grouped lists", "PASS metadata columns saved order width visibility survive fresh column stores and actual Main header reconstruction", "PASS metadata columns numeric and checklist editors apply cancel and missing-year choices in both themes"], "author-display-setting": ["PASS existing author initials/full-name menus preserve eleven Unicode/compound/incomplete names", "PASS actual Add to Search preserves literal, legacy and expression drafts"], "update-proposals-visual": ["PASS update proposals visual fixtures closed explicitly"], "reader-notes-visual": ["PASS reader-notes-visual closed_by_operator"], "catalog-proposals-visual": ["PASS proposal legacy visual preview closed"], "main-search-proposals-visual": ["PASS Main search proposals visual fixtures explicitly inspected"], "export-results-audit": ["PASS export results all six actual Main scenarios"], "search-query-modes": ["PASS proposal search modes literal SQL metacharacters"], "legacy-import-preview": ["PASS proposal legacy preview counts", "PASS proposal legacy target editor starts empty until row selection and restores explicitly saved mappings"], "inp-streaming": ["PASS proposal INP reader matches", "PASS proposal actual INP worker preserves"], "inp-streaming-memory": ["PASS proposal INP large-member spool preserves 90000 Unicode rows"], "reader-notes-proposals": ["PASS reader-note-conflict", "PASS reader-note-filter", "PASS reader-notes-proposals"], "update-keyboard-accessibility": ["PASS update history native Tab Enter Space name state focus scroll reload", "PASS update theme tolerates deletion of its formerly focused control in a real form callback", "PASS update theme preserves a newly shown callback input form without restoring the old header"], "update-source-failures": ["PASS update sources unavailable manual check", "PASS update sources partial failure", "PASS update sources Retry", "PASS update sources automatic failures"], "legacy-import-interactive": ["PASS Main uppercase MHLUD imports the actual file", "PASS Main legacy import cancel preserves earlier values"], "reader-conversion-audit": ["PASS reader-conversion-audit local_html_markdown=24 rejected_resources=3 source_and_stream_preserved=1"], "settings-workflow-audit": ["PASS settings custom update interval 1000", "PASS settings custom update interval 1020", "PASS settings custom update interval 525600", "PASS settings Add script", "PASS settings Edit script", "PASS settings Cancel script", "PASS settings deleting other scripts", "PASS settings delete boundaries cover no selection, Standard, first/middle/last default and every removed row with profile reload (20 combinations)"], "catalog-audit": ["PASS catalog audit legacy headers", "PASS catalog audit legacy EOF", "PASS catalog audit quoted comparisons", "PASS catalog audit actual legacy import preserves catalog and personal cards, named groups and a second collection"], "export-preparation": ["PASS Main failed NFT export restores the saved folder template"], "export-cancel-interactive": ["PASS Main export destination cancel preserves marked books tag=799", "PASS Main export destination cancel preserves marked books tag=850"], "feedback22": ["PASS feedback22 readable XML", "PASS feedback22 favorite profile", "PASS feedback22 author initials", "PASS feedback22 standalone tools"], "native-folder-picker": ["PASS native folder picker case 1", "PASS native folder picker case 2", "PASS native folder picker case 3", "PASS native folder picker case 4"], "feedback21": ["PASS feedback21 portable PPTX/XLSX/ODP/ODS reader", "PASS feedback21 actual official four-package Office update", "PASS feedback21 archived FBD card/cover/gallery preview-paired-ppmd.zip", "PASS feedback21 archived FBD card/cover/gallery preview-paired-solid.7z", "PASS feedback21 archived FBD card/cover/gallery preview-single-fbd.zip", "PASS feedback21 portable favorite authors", "PASS feedback21 reader toolbar order", "PASS feedback21 actual updater form"],"metadata-archive-codecs": ["PASS native metadata prefix ppmd.zip", "PASS native metadata prefix ordinary.7z", "PASS native metadata prefix solid.7z", "PASS native archive prefix limit and cancellation", "PASS bounded publication metadata .epub packed=1", "PASS bounded publication metadata .docx packed=1", "PASS bounded publication metadata .odt packed=1", "PASS bounded publication metadata .fb3 packed=1", "PASS single-book metadata container single.fb2.xz", "PASS single-book metadata container renamed-odt.zip detected=.odt", "PASS single-book metadata container single-fbd.zip detected=.fbd", "PASS metadata package MIME distinguishes text ODT", "PASS ambiguous metadata archive", "PASS 1206 interleaved archive records", "PASS bounded parallel metadata pipeline"],"feedback20-main": ["PASS feedback20 metadata predicates", "PASS feedback20 actual search fields", "PASS feedback20 note identities", "PASS feedback20 global notes manager", "PASS feedback20 local export timestamps", "PASS feedback20 actual information card shows catalog annotation"],"update-form-notifier": ["PASS updater component check actual success survives form HWND recreation with owned loopback transport", "PASS updater component check actual failures release checking state after form HWND recreation", "PASS updater pre-Start UI failure frees its real canceled suspended worker without waiting forever or making HTTP requests", "PASS updater component in-flight teardown joins its actual worker before removing the notifier", "PASS updater download actual progress and verification failure survive form HWND recreation", "PASS updater download actual cancel completes through the stable form notifier", "PASS updater form in-flight teardown joins its actual download worker and removes its notifier without orphan windows", "PASS updater notifier lifecycle leaves catalog, personal cards and installed component source bytes unchanged", "PASS updater fixture restores the original process-local cache environment"],
  "oct11-ui": ["PASS app theme switch", "PASS Windows dark-theme suggestion"],"merge-scale": ["PASS large merge reuses imported books"],"audit-new": ["PASS adversarial audit fixed checks"],
  "filter-captions": ["PASS caption font measurements", "PASS annotation caption expanded dark=1 dpi=192"],
  "deleted-filter": ["PASS fresh search and tree-mode changes never load the whole catalog", "PASS search and group count/rows hide six deleted books", "PASS deletion toggle uses only the applied snapshot", "PASS legacy presets inherit the shared mode after reopen"],
  "cache-presets": ["PASS cache folder presets"],
  "publisher-search": ["PASS publisher queries preserve Unicode case", "PASS publisher input waits for Apply", "PASS publisher presets preserve typed expressions", "PASS expanded annotation remains visible"],
  "author-favorites": ["PASS favorite authors baseline", "PASS favorite authors persistence", "PASS favorite authors isolated durable profile"],
  "ordinary-book-export-identity": ["PASS ordinary Main export identity matching", "PASS ordinary Main export identity replaced-before-worker"],
  "search-startup-layout": ["PASS search startup first category header, Author label and input are fully visible without scaling or scrolling", "PASS search startup fix preserves deliberate Date focus and scrolling during ordinary view refresh"],
  "queue-serialization": ["PASS queue serializer legacy odd", "PASS queue serializer restores versioned identity", "PASS queue serializer malformed/future identity", "PASS queue serializer rejects truncation"],
  "metabib-size": ["PASS actual native Metabib and INPX import preserve the same 2000", "PASS Metabib retains annotation, publication metadata"],
  "reader-pipeline-cache": ["PASS actual LRU Touch keeps proved bounded input", "PASS unmanaged raw input stamps", "PASS actual bundled DOC cold preparation runs once", "PASS actual KF8 warm adapter", "PASS pipeline preparation preserves"],
  "publisher-metadata-index": ["PASS FB2 publisher parser", "PASS real publisher index", "PASS publisher, publisher series and source completion", "PASS publisher fill preserves known catalog values and rejects reused BookID"],
  "conversion-menu": ["PASS zero-script raw collection actual context menu converts to .epub", "PASS zero-script raw collection actual context menu converts to .fb2"],
  "collection-metadata-sync": ["PASS strict complete bounded metadata", "PASS real FB2/ZIP read-only preview", "PASS stale ID/path/root/source/late edits fail closed", "PASS canceled preview writes nothing", "PASS resumed fill preserves its committed chunk", "PASS resumable metadata scan", "PASS same-plan annotation selection", "PASS metadata cache invalidates"],
  "book-preview-layout": ["PASS fixed information footer dark=0 dpi=96", "PASS fixed information footer dark=0 dpi=144", "PASS fixed information footer dark=0 dpi=192", "PASS fixed information footer dark=1 dpi=96", "PASS fixed information footer dark=1 dpi=144", "PASS fixed information footer dark=1 dpi=192", "PASS source bytes/profile preserved; short/long/cover/gallery/scroll/DPI/native click/cycling checked"],
  "metadata-fill-layout": ["PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=96", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=144", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=192", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=96", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=144", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=192"],
  "metadata-fill-ui": ["PASS metadata ETA warmup", "PASS actual metadata form defaults", "PASS actual Main metadata action fills", "PASS Sources target exposes independent", "PASS actual metadata UI rejects a changed collection root", "PASS wizard successful INPX Finish opens only the requested exact collection metadata dialog without auto-preview or writes", "PASS wizard ordinary finish, cancel, uncommitted preview, creation failure and vanished collection never request or open metadata fill", "PASS wizard metadata choice revalidates its registered local root and refuses unavailable or online-only targets", "PASS wizard Finish metadata button and explanation fit six theme/DPI combinations without scanning"],
  "main-toolbar-states": ["PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=96", "PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=144", "PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=192", "PASS Main toolbar state matrix restores original theme, DPI and window without catalog changes", "PASS actual Main three-row font and DPI growth restores automatic options without catalog or personal card changes"],
  "main-publisher-index-cache": ["PASS actual publisher index refreshes active rows, column and filter cache", "PASS inactive author books and publisher series reload new metadata", "PASS zero-commit cached publisher index keeps node identity"],
  "feedback19-main": ["PASS native author locate preserves Cyrillic", "PASS native series locate preserves Cyrillic", "PASS native publisher series locate preserves Cyrillic", "PASS favorite author funnel actual pixels dark=1", "PASS favorite hearts paint independently", "PASS actual Main color-only theme toggles", "PASS favorite author funnel actual pixels dark=0", "PASS favorite worker completion survives actual Main HWND recreation", "PASS actual update-check producer delivers through stable Main notifier after HWND recreation using only loopback"],
  "catalog-sources-workflow": ["PASS catalog source mode changes", "PASS target namespace changes and interleaved worker", "PASS target-only series scope", "PASS compact source dialog resizes"],
  "queue-persistence": ["PASS queue complete native serialization", "PASS queue actual Save read-only-lock-serialization failures", "PASS queue generic stream read fault", "PASS queue valid records remain complete after actual Main close"],
  "queue-load-negative": ["PASS queue startup negative", "PASS queue failed startup negative"],
  "queue-load-truncated": ["PASS queue startup truncated", "PASS queue failed startup truncated"],
  "queue-load-zero": ["PASS queue startup zero", "PASS queue failed startup zero"],
  "atomic-ini": ["PASS atomic INI initial large UTF8 bytes match RTL", "PASS atomic INI lock failure and destructor retain the last complete profile", "PASS atomic INI data preservation all native cases"],
  "group-book-identity": ["PASS Main saved group identity empty", "PASS Main saved group identity zero", "PASS Main saved group identity trusted", "PASS Main saved group identity rawunknown", "PASS saved download identity matching", "PASS saved download identity before-worker", "PASS saved download identity during-response", "PASS saved download identity legacy-matching", "PASS saved download identity legacy-replacement", "PASS saved download identity posted-completion"],
  "reader-copy-identity": ["PASS reused positive IDs", "PASS matching stable and merged verified copies", "PASS placeholder cache/history IDs", "PASS atomic reader progress/local/personal guards", "PASS concurrent catalog commit after identity read"],
  "favorite-ui": ["PASS favorite baseline", "PASS favorite search intersects", "PASS known commits refresh", "PASS favorite removal refreshes", "PASS inline favorite condition fits"],
  "update-outcomes": ["PASS update outcomes"],
  "system-remap": ["PASS system remap swap/raw BLOBs", "PASS system remap three-way cycle", "PASS system remap False mode quarantines", "PASS system remap exact BLOBs/personal fields/groups"],
  "favorite-columns": ["PASS favorite column checkbox"],
  "favorite-dao": ["PASS favorite DAO intersects"],
  "publisher-columns": ["PASS publisher column uses loaded metadata"],
  "search-preset-transfer": ["PASS preset transfer editable XML and legacy cxml2-cxml", "PASS preset transfer validates the entire input before merge", "PASS preset transfer actual import menu keeps draft and old names", "PASS preset transfer actual selected-all export snapshots", "PASS preset transfer legacy import, invalid-locked-readonly failures", "PASS preset transfer compact menu stays inside existing preset row at96-144-192DPI in both themes without widening search"],
  "search-presets": ["PASS presets preserve typed names"],
  "builtin-export": ["PASS independent native FB2 to EPUB and EPUB to FB2 actions", "PASS ordinary PDF copying is unchanged", "PASS cancelled native export workers", "PASS native conversion warnings", "PASS MTP export branch marshals", "PASS export log dark=1 dpi=192"],
  "persistent-cache": ["PASS bounded persistent cache", "PASS cache menu and settings", "PASS delayed cursor status"],
  "feedback14": ["PASS visible-result series choices", "PASS optional publisher-series column", "PASS nested ZIP and standalone FBD", "PASS broken body Unicode"],
  "cancel-interactive": ["PASS real mouse cancels running SQLite without a frozen white window"],
  "book-preview": ["PASS asynchronous book preview keeps latest selection", "PASS missing metadata shows explicit explanations"],
  "large-inpx": ["PASS full INPX production import and heavy native lists"],
  "first-run": ["PASS visible first-run wizard creates an empty collection without indexing"],
  "first-run-cancel": ["PASS visible first-run wizard cancellation exits cleanly"],
  "genre-order": ["PASS Unsorted is last"],
  "": ["PASS unopened genre filter", "PASS first series visit", "PASS changed deletion filter", "PASS visible genre view", "PASS first group visit", "PASS empty author selection"],
  "language-isolation": ["PASS language choice survives"],
  "favorites-add": ["PASS adding a book before first group visit"],
  "genre-link": ["PASS genre link restores"],
  "source-genres": ["PASS imported source genre survives"],
  "adjacent-series": ["PASS adjacent series consistently select the first book"],
  "publisher-selection": ["PASS deferred publisher view restores"],
  "publisher-startup": ["PASS saved publisher page starts with visible cover and information panel", "PASS startup publisher view survives collection switches"],
  "publisher-links": ["PASS flat publisher list ignores old grouping", "PASS publisher links keep current card"],
  "publisher-error-log": ["PASS actual publisher indexing saves all errors"],
  "loose-archive": ["PASS loose archives open readable members", "PASS archive picker handles several books"],
  "builtin-reader": ["PASS main built-in reader action opens selected book", "PASS malformed and canceled readers return"],
  "external-reader-names": ["PASS real FB2 rewrite changes only private copy for Readable original book", "PASS real FB2 rewrite changes only private copy for 0031", "PASS external title-first Unicode name", "PASS equal titles/raw IDs remain separate", "PASS changed source refreshes owned alias", "PASS actual prepared extension, wrong-origin rejection", "PASS invalid control/device/path title", "PASS touched canonical warm hit uses dependency metadata", "PASS legacy missing dependency metadata and explicit same-size FB2 rewrite refresh safely after cache Touch", "PASS small cache limit keeps the canonical input alive", "PASS external friendly alias uses cancellable background lifecycle", "PASS external-reader filename policy preserves original/canonical bytes, profiles, reader history and notes"],
  "metadata-prefix-bounds": ["PASS metadata prefix UTF8 all two-three-four-byte body splits, BOM and public parser, no extra body reads", "PASS metadata prefix closed Unicode metadata ignores malformed body, exact legal replacement character and series preserved", "PASS metadata prefix UTF16 LE-BE odd byte and split surrogate remain body-only, source position exact", "PASS metadata prefix 121 deterministic UTF8 corruption probes fail closed without changing series metadata", "PASS metadata prefix UTF16 malformed high-low-surrogate metadata rejected by recovery and public parser", "PASS metadata prefix fragmented split inside metadata resumes exactly, byte bound and both cancellation paths preserved", "PASS metadata prefix failed stream untouched, source bytes ownership and main profile preserved"],
  "reader-chapters": ["PASS chapter titles exact nine independent mixed-level labels, numbering toggle, position objects and selected chapter", "PASS chapter titles all614 Dome labels and native positions match frozen original reader SHA, text and source/profile unchanged"],
  "reader-filter": ["PASS actual PDF DjVu EPUB TXT FB2 and DOC readers stay visible and avoid catalogue scans with filter on and off"],
  "reader-main-filter": ["PASS native sole/multiple selections retain old hidden/focus/children-above/resolved/next/dirty-delete-add-unselect-invert/reentrant-clear/init semantics", "PASS actual Main modal opens and pages identical Under Dome content at a 50K tail selection, with filter off/on and complete idle actions"],
  "reader-compatibility": ["PASS plain FB2 reader preserves ordinary paths", "PASS stable reader cache survives reimport", "PASS reader cache hit avoids source extraction"],
  "read-folder-cleanup": ["PASS manual reader cleanup", "PASS custom reading folder is cleared", "PASS reader cleanup does not follow"],
  "book-gallery": ["PASS gallery loads lazily in background", "PASS illustration preview arrows work and resized window position persists", "PASS changing books cancels old gallery", "PASS EPUB gallery leaves source unchanged"],
  "catalog-sources": ["PASS multiple INPX sources keep separate roots", "PASS statistics count book records once", "PASS all sources participate without multiselect"],
  "book-information": ["PASS common book information loads real FLibrary biographies", "PASS review parser preserves Russian text"],
  "collection-merge": ["PASS safe merge previews", "PASS optional copy merging verifies origin", "PASS merge preview reuses sparse target user snapshot"],
  "list-performance": ["PASS list profiling preserves", "PASS nested genre iterators retain independent membership", "PASS main window repaints while SQL runs and cancel is available", "PASS filtered focused-book actions avoid repeated complete catalogue scans", "PASS no-focus and group-focus idle actions cache checks"],
  "column-filters": ["PASS column filters combine, survive regrouping, hide empty groups and mark only matching books", "PASS compact size popup converts fractional MB", "PASS per-column dialogs expose only their own loaded values"],
  "temp-exit-cleanup": ["PASS real main-form exit removes temporary converted copies"],
  "program-update-ui": ["PASS automatic update cycle waits for both responses", "PASS one-line update summaries combine all available components", "PASS new update default is three days and preserves explicit choices", "PASS update settings preserve never and custom hours", "PASS update popup shows installed version", "PASS dates and shared formatting", "PASS update notes retain nested SQLite", "PASS previous changelogs start collapsed", "PASS update window expands reading space", "PASS saved histories survive reopening", "PASS resized update window and text zoom", "PASS short release height stays compact", "PASS expanded old release ends directly after its text"],
  "online-download": ["PASS online main reader downloads ZIP", "PASS online main queue downloads ZIP", "PASS online main queue restarts for another remote book"],
  "online-plain": ["PASS plain online FB2 is downloaded before compatibility conversion"],
  "review-http": ["PASS HTTP reviews decode UTF-8"],
};
// Each independent layout suite retains its full DPI sequence and the same
// 90-second deadline. The default runner requires all three; none is optional.
function filterCaptionPasses(subcase) {
  const common = [`TRACE filter caption native subcase=${subcase}`, "PASS header menu keeps column IDs", "PASS default author selection and saved book", "TRACE main cleanup complete"];
  if (subcase === "popup") return [...common,
    ...[0,1].flatMap(dark => [96,144,192].map(dpi => `PASS filter captions dark=${dark} dpi=${dpi}`)),
    "PASS caption font measurements"];
  const dark = subcase === "annotation-light" ? 0 : subcase === "annotation-dark" ? 1 : null;
  if (dark === null) throw new Error(`Unknown mandatory filter-caption case: ${subcase}`);
  return [...common,
    ...[96,144,192].map(dpi => `PASS annotation caption expanded dark=${dark} dpi=${dpi}`),
    ...[96,144,192].map(dpi => `TRACE annotation stage after-collapsed-scale-dark-${dark}-dpi-${dpi}`),
    `PASS annotation caption reexpanded dark=${dark} dpi=192`,
    `PASS annotation caption complete theme=${dark}`];
}
function requiredPasses(executable, mode) {
  if (mode === "search-startup-layout") return ["PASS header menu keeps column IDs", ...requiredViews[mode], "TRACE main cleanup complete"];
  if (mode === "series-stream") return ["PASS sequential series stream matches ordinary lookup"];
  if (mode === "fbd-editor-save") return ["PASS FBD editor preserves unsaved metadata"];
  if (mode === "update-theme") return ["PASS update notes retain visible dark/light foreground"];
  if (mode === "bulk-writes") return ["PASS bulk writes preserve Unicode fields", "PASS current catalogs reopen without schema/data writes", "PASS metadata delta matches full writes", "PASS metadata delta preserves exact personal review prefix"];
  if (mode === "query-batch") return ["PASS bounded statement reuse, cleared parameters, concurrent queries, schema changes and rollback"];
  if (path.basename(executable).toLowerCase() === "metabibimporttest.exe") return [
    "PASS production import registers", "PASS conflicting source import", "PASS production importer stops",
    "PASS production INPX import", "PASS production book stream", "PASS single-source full INPX update",
    "PASS production script extraction", "PASS production uppercase FB2 export", "PASS production same-title batch extraction",
    "PASS ordinary single-source online INPX", "PASS mixed-source online INPX",
  ];
  if (mode === "merge-scale") return requiredViews[mode];
  if (mode === "large-inpx") return requiredViews[mode];
  if (mode.startsWith("first-run")) return requiredViews[mode];
  if (path.basename(executable).toLowerCase() === "collectionviewstest.exe") return [
    "PASS header menu keeps column IDs", "PASS default author selection and saved book", ...requiredViews[mode || ""], ...(mode === "feedback22" && toolProbe ? ["PASS feedback22 actual standalone launch"] : []),
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
  const archiveDll = path.join(runtime,'tools/7zip/7z.dll');
  if (fs.existsSync(archiveDll)) {
    fs.mkdirSync(path.join(folder,'tools/7zip'),{recursive:true});
    fs.copyFileSync(archiveDll,path.join(folder,'tools/7zip/7z.dll'));
  }
  const decoder = path.join(runtime, "tools", "webp", "libwebp.dll");
  if (!fs.existsSync(decoder) || machine(decoder) !== architecture) throw new Error("WebP decoder is absent or has the wrong architecture.");
  const decoderDir = path.join(folder, "tools", "webp");
  fs.mkdirSync(decoderDir, { recursive: true });
  fs.copyFileSync(decoder, path.join(decoderDir, "libwebp.dll"));
  // Icons and bundled genres contain no personal profiles or library databases.
  if (fs.existsSync(path.join(runtime, "Icons"))) copyDllTree(path.join(runtime, "Icons"), path.join(folder, "Icons"));
  for (const name of fs.readdirSync(runtime)) if (/^genres[^\\/]*\.glst$/i.test(name)) fs.copyFileSync(path.join(runtime, name), path.join(folder, name));
  // The DOC component uses managed AnyCPU assemblies, all bundled and isolated.
  if (fs.existsSync(path.join(runtime, 'tools', 'doc'))) fs.cpSync(path.join(runtime, 'tools', 'doc'), path.join(folder, 'tools', 'doc'), {recursive:true});
  fs.writeFileSync(path.join(folder, "uselocaldata"), "");
  fs.copyFileSync(path.resolve(__dirname, '../../../Installer/Components.json'), path.join(folder, 'COMPONENTS.json'));
  fs.writeFileSync(path.join(folder, "uselocaltemp"), "");
  fs.writeFileSync(path.join(folder, "native-regression.marker"), marker, "utf8");
  fs.writeFileSync(path.join(folder, "myhomelib2.ini"), [
    "[SYSTEM]", "CheckUpdates=0", "CheckLibrusecUpdates=0", "[INTERFACE]", "Locale=ru", "ActivePage=0",
    "[BEHAVIOR]", "CoverPanel=0", "ShowCover=0", "ShowAnnotation=0", "AutoLoadReview=0", "IgnoreAbsentArchives=1",
    "[OPDS]", "Enabled=0", "", // OPDS is never started; dedicated online tests use only loopback.
  ].join("\r\n"), "utf8");
}
function run(executable, mode, subcase = "") {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder);
  const expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  const readonlyInputs = [];
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  try {
    stage(folder, executable);
    if (mode === 'feedback22') {
      const target = path.join(folder, 'favorite-real');
      fs.mkdirSync(target);
      fs.symlinkSync(target, path.join(folder, 'favorite-alias'), 'junction');
    }
    if (mode === 'metadata-archive-codecs' || mode === 'conversion-menu' || mode === 'feedback21' || mode === 'reader-pipeline-cache') {
      const arg = process.argv.find(a => a.startsWith('--metadata-archive-fixtures='));
      if (!arg) throw new Error('Metadata codec fixtures are required');
      fs.cpSync(arg.slice('--metadata-archive-fixtures='.length),path.join(folder,'metadata-archive-fixtures'),{recursive:true});
    }

    if (mode === 'feedback21' || mode === 'reader-pipeline-cache') {
      for (const name of ['kindle','bookconvert','office','7zip']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
    }
    if (mode === 'update-outcomes') {
      if (!conversionFixturesArg) throw new Error('Update outcome gate requires --conversion-fixtures=<folder>');
      const inputs = fs.realpathSync(conversionFixturesArg.slice('--conversion-fixtures='.length));
      const source = path.join(inputs, 'source.fb2');
      readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
      const destination = path.join(folder, 'conversion-fixtures');
      fs.mkdirSync(destination);
      fs.copyFileSync(source,path.join(destination,'source.fb2'));
    }
    if (mode === 'builtin-export' || mode === 'conversion-menu') {
      if (!conversionFixturesArg) throw new Error('Export gate requires --conversion-fixtures=<folder>');
      const inputs = fs.realpathSync(conversionFixturesArg.slice('--conversion-fixtures='.length));
      const destination = path.join(folder, 'conversion-fixtures');
      fs.mkdirSync(destination);
      for (const name of ['source.fb2','source.epub','warning.epub']) {
        const source = path.join(inputs, name);
        readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
        fs.copyFileSync(source,path.join(destination,name));
      }
      fs.cpSync(path.join(runtime,'tools/kindle'),path.join(folder,'tools/kindle'),{recursive:true});
      fs.cpSync(path.join(runtime,'tools/bookconvert'),path.join(folder,'tools/bookconvert'),{recursive:true});
      for (const name of ['pdfium','djvu','7zip']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
    }
    if (mode === 'reader-conversion-audit') {
      fs.cpSync(path.join(runtime,'tools/kindle/python'),path.join(folder,'tools/kindle/python'),{recursive:true});
      const source = path.resolve(__dirname, '../../bookconvert');
      const target = path.join(folder,'tools/bookconvert');
      fs.mkdirSync(target,{recursive:true});
      for (const name of fs.readdirSync(source)) {
        if (/\.py$/i.test(name)) fs.copyFileSync(path.join(source,name),path.join(target,name));
      }
      fs.cpSync(path.join(source,'vendor'),path.join(target,'vendor'),{
        recursive:true, filter:item=>!item.split(path.sep).includes('__pycache__') && !/\.pyc$/i.test(item)
      });
    }
    if (mode === 'group-book-identity' || mode === 'ordinary-book-export-identity') {
      fs.cpSync(path.join(runtime,'tools/kindle/python'),path.join(folder,'tools/kindle/python'),{recursive:true});
      fs.cpSync(path.join(runtime,'tools/bookconvert'),path.join(folder,'tools/bookconvert'),{recursive:true});
      for (const name of ['pdfium','djvu','7zip']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
    }
    if (mode === 'reader-main-filter' || mode === 'reader-chapters') {
      if (!readerFixturesArg) throw new Error('Actual Main reader test requires --reader-fixtures=<folder>');
      const fixtureRoot = fs.realpathSync(readerFixturesArg.slice('--reader-fixtures='.length));
      const source = path.join(fixtureRoot, 'reader-dome.fb2');
      readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
      fs.copyFileSync(source,path.join(folder,'reader-dome.fb2'));
    }
    if (mode === 'metabib-size') {
      const arg = process.argv.find(value => value.startsWith('--metabib-size-fixtures='));
      if (!arg) throw new Error('Metabib size test requires --metabib-size-fixtures=<folder>');
      const fixtureRoot = fs.realpathSync(arg.slice('--metabib-size-fixtures='.length));
      const destination = path.join(folder,'metabib-size-inputs'); fs.mkdirSync(destination);
      for (const name of ['same-records-full.jsonl','same-records.inpx']) {
        const source = path.join(fixtureRoot,name);
        readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
        fs.copyFileSync(source,path.join(destination,name));
      }
    }
    if (mode === 'reader-pipeline-cache') {
      if (!readerFixturesArg) throw new Error('Pipeline cache test requires --reader-fixtures=<folder>');
      const fixtureRoot = fs.realpathSync(readerFixturesArg.slice('--reader-fixtures='.length));
      const source = path.join(fixtureRoot, 'reader-novel.doc');
      readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
      fs.copyFileSync(source,path.join(folder,'reader-novel.doc'));
      fs.cpSync(path.join(runtime,'tools/kindle'),path.join(folder,'tools/kindle'),{recursive:true});
    }
    if (mode === 'reader-filter') {
      if (!readerFixturesArg) throw new Error('Reader filter test requires --reader-fixtures=<folder>');
      const fixtureRoot = fs.realpathSync(readerFixturesArg.slice('--reader-fixtures='.length));
      for (const name of ['reader-sky.pdf','reader-apple.djvu','reader-quixote.epub','reader-story.txt','reader-dome.fb2','reader-novel.doc']) {
        const source=path.join(fixtureRoot,name);
        readonlyInputs.push([source,require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')]);
        fs.copyFileSync(source,path.join(folder,name));
      }
      for (const name of ['pdfium','djvu']) {
        const source=path.join(runtime,'tools',name), target=path.join(folder,'tools',name);
        fs.mkdirSync(target,{recursive:true});
        for (const entry of fs.readdirSync(source,{withFileTypes:true})) {
          if (entry.isFile() && /\.(dll|exe)$/i.test(entry.name)) fs.copyFileSync(path.join(source,entry.name),path.join(target,entry.name));
        }
      }
    }
    if (mode === 'audit-new' && auditCaseArg === '--audit-case=legacy') {
      const legacy = path.join(folder, 'legacy-read'); fs.mkdirSync(legacy);
      fs.writeFileSync(path.join(legacy, 'personal.pdf'), 'personal preserved');
      fs.writeFileSync(path.join(legacy, 'homelib-owned.pdf'), 'legacy owned book');
      fs.writeFileSync(path.join(legacy, 'homelib-owned.pdf.origin'), path.join(folder, 'legacy-source.zip'));
      fs.appendFileSync(path.join(folder, 'myhomelib2.ini'), '\r\n[PATH]\r\nRead=' + legacy + '\r\n');
      const make = cp.spawnSync('python', ['-c', 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("book.pdf",b"%PDF-1.4 synthetic"); z.close()', path.join(folder,'legacy-source.zip')], {windowsHide:true, encoding:'utf8'});
      if (make.error || make.status !== 0) throw new Error('Cannot create legacy archive fixture');
    }
    if (mode === 'book-preview' && previewBookArg) {
      const source = fs.realpathSync(previewBookArg.slice('--preview-book='.length));
      if (path.extname(source).toLowerCase() !== '.fb2') throw new Error('Expected a read-only FB2 preview input');
      fs.copyFileSync(source,path.join(folder,'preview-real.fb2'));
    }
    if (mode === "large-inpx") {
      if (!largeInpxArg) throw new Error("Large test requires --large-inpx=<source>");
      const source = fs.realpathSync(largeInpxArg.slice("--large-inpx=".length));
      if (path.extname(source).toLowerCase() !== ".inpx") throw new Error("Expected INPX input");
      fs.copyFileSync(source, path.join(folder, "large-fixture.inpx"));
      console.log(`NATIVE input_sha256=${require("crypto").createHash("sha256").update(fs.readFileSync(source)).digest("hex")}`);
    }
    if (mode === 'book-information') require('./book_information_fixture')(runtime, folder);
    if (mode === "read-folder-cleanup") {
      const reading = path.join(folder, "junction-reading"), target = path.join(folder, "junction-target");
      fs.mkdirSync(reading); fs.mkdirSync(target);
      fs.writeFileSync(path.join(reading, "ordinary.tmp"), "isolated root cleanup probe");
      fs.writeFileSync(path.join(target, "keep.fb2"), "junction target must survive");
      fs.symlinkSync(target, path.join(reading, "webp-png"), "junction");
    }
    const exe = path.join(folder, path.basename(executable));
    const result = cp.spawnSync(exe, mode ? [mode,...(subcase ? [subcase] : []),...(mode === "audit-new" ? [auditCaseArg ? auditCaseArg.slice(13) : "filters", ...(amberArchiveArg ? [fs.realpathSync(amberArchiveArg.slice(16))] : [])] : []),...(toolProbe ? ["probe"] : []),...((visualCache || visualUI || visualUpdate || visualRecords) ? ["visual"] : []),...(mode === "feedback14" && amberArchiveArg ? [fs.realpathSync(amberArchiveArg.slice("--amber-archive=".length))] : [])] : [], { cwd: folder, encoding: "utf8", timeout: mode === "large-inpx" ? 900000 : mode === 'native-folder-picker' || mode === 'cancel-interactive' || mode === 'export-cancel-interactive' || mode === 'legacy-import-interactive' || proposalVisualModes.includes(mode) || visualUI || visualUpdate || visualRecords ? 900000 : visualCache ? 180000 : 90000, windowsHide: !mode.startsWith("first-run") && mode !== 'cancel-interactive' && mode !== 'export-cancel-interactive' && mode !== 'legacy-import-interactive' && !proposalVisualModes.includes(mode) && !visualCache && !visualUI && !visualRecords, maxBuffer: 2 * 1024 * 1024 });
    const output = (result.stdout || "") + (result.stderr || "");
    process.stdout.write(`${path.basename(exe)}${mode ? ` (${mode})` : ""}:\n${output}`);
    if (result.error) throw result.error;
    if (result.status !== 0 || !/^PASS\b/m.test(output) || /^FAIL\b/m.test(output)) throw new Error(`Native test failed: ${path.basename(exe)} ${mode || "default"}, exit ${result.status}`);
    const expectedPasses = mode === "filter-captions" && subcase
      ? filterCaptionPasses(subcase)
      : mode === "group-book-identity" && subcase
      ? [subcase.startsWith("manager-") ? "PASS queued download manager " + subcase.slice(8) : subcase.startsWith("download-") ? "PASS saved download identity " + subcase.slice(9) : "PASS Main saved group identity " + subcase]
      : requiredPasses(executable, mode);
    for (const expected of expectedPasses) {
      if (!output.includes(expected)) throw new Error(`Native test did not run required scenario (${expected}); reload and rebuild its DPR from disk.`);
    }
    for (const [source,hash] of readonlyInputs) {
      if (require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')!==hash) throw new Error('Readonly reader input was changed: '+source);
    }
  } finally {
    // Only this process's verified, unique temporary runtime is removed.
    if (keepFixtures) console.log('RETAINED',absolute);
    else if (absolute.startsWith(expectedRoot) && path.basename(absolute).startsWith("HomeLibRu-native-")) fs.rmSync(absolute, { recursive: true, force: true });
  }
}
// Each complete case keeps the same 90-second deadline and a fresh profile.
// No subcase marker is optional: all fourteen are required by the default suite.
function runView(mode) {
  if (mode === "filter-captions") {
    for (const subcase of ["popup", "annotation-light", "annotation-dark"]) run(tests[2], mode, subcase);
  } else if (mode === "group-book-identity") {
    for (const subcase of ["empty", "zero", "trusted", "rawunknown", "download-matching", "download-before-worker", "download-during-response", "download-legacy-matching", "download-legacy-replacement", "download-posted-completion", "manager-cancel-before-loop", "manager-cancel-after-success", "manager-cancel-during-interval", "manager-matching-count"]) run(tests[2], mode, subcase);
  } else run(tests[2], mode);
}
async function runOnline(executable, mode) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder), expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  const requests = [];
  const expected = mode === 'review-http' ? ['/b/1/', '/b/2/', '/b/3/', '/b/4/'] : mode === "online-plain" ? ["/b/900003/get"] : ["/b/900001/get", "/b/900002/get", "/b/900004/get"];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if (req.method !== "GET" || !expected.includes(req.url)) { res.writeHead(404); res.end(); return; }
    if (mode === 'review-http') {
      if (req.url === '/b/2/') { res.writeHead(503); res.end('unavailable'); return; }
      const text = req.url === '/b/3/' ? '<h1>Access denied</h1>' : '<h2>Аннотация</h2><p>Русская аннотация</p><form></form><a href="/polka/show/1">Читатель</a><br><p>Очень хорошая книга</p><div></div><div id="newann"></div>';
      const reply = () => { res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'}); res.end(text); };
      if (req.url === '/b/4/') {
        fs.writeFileSync(path.join(folder, 'review-request-started.marker'), 'request active');
        setTimeout(reply, 1000);
      } else reply();
      return;
    }
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
  if (viewsMode !== null) {
    runView(viewsMode);
    console.log(`PASS native view scenario ${viewsMode || "default"}; only temporary fixtures used`);
    return;
  }
  if (coreOnly) {
    run(tests[0], "");
    run(tests[1], "");
    console.log("PASS native genre registry and production import regressions; only temporary fixtures used");
    return;
  }
  if (!onlineOnly && !archiveOnly && !plainOnly && !reviewsOnly) {
    run(tests[0], "");
    run(tests[1], "");
    for (const mode of modes.filter(m => m !== "large-inpx")) runView(mode);
  }
  if (offlineOnly) {
    console.log(`PASS offline native regressions (${architecture === 0x8664 ? "x64" : "x86"}); no network server started`);
    return;
  }
  if (!plainOnly && !reviewsOnly) await runOnline(tests[2], "online-download");
  if (!archiveOnly && !reviewsOnly) await runOnline(tests[2], "online-plain");
  if (reviewsOnly || (!plainOnly && !archiveOnly && !onlineOnly)) await runOnline(tests[2], 'review-http');
  console.log(`PASS all native collection regressions (${architecture === 0x8664 ? "x64" : "x86"}); only temporary fixtures used`);
} catch (error) {
  console.error(`FAIL ${error.stack || error}`);
  process.exitCode = 1;
}
})();

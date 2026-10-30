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
const catalogueLabelArg=process.argv.find(a=>a.startsWith('--catalogue-label='));
const catalogueLabel=catalogueLabelArg ? catalogueLabelArg.slice('--catalogue-label='.length) : '';
if(catalogueLabel && !/^[a-z0-9-]{1,40}$/.test(catalogueLabel))throw Error('Invalid catalogue audit label');
const visualCache = process.argv.includes("--visual-cache");
const visualUI = process.argv.includes("--visual-ui");
const visualEstimates = process.env.HOMELIB_TEST_ESTIMATE_VISUAL === '1';
if (visualEstimates && viewsMode !== 'estimate-failure-visibility') throw new Error('Estimate visual review requires its isolated view scenario');
const toolProbe = process.argv.includes("--tool-probe");
if (toolProbe && (viewsMode !== "feedback22" || visualUI)) throw new Error("Tool probe requires feedback22 without visual-ui");
const visualRecords = process.argv.includes('--visual-records');
const proposalVisualModes = ['release23-ready-visual', 'metadata-book-columns-visual', 'main-search-proposals-visual', 'catalog-proposals-visual', 'reader-notes-visual', 'update-proposals-visual'];
if (visualRecords && viewsMode !== 'feedback21') throw new Error('Visual records inspection requires feedback21');
const visualUpdate = process.argv.includes("--visual-update");
if (visualUpdate && viewsMode !== "program-update-ui") throw new Error("Visual update inspection requires --views-mode=program-update-ui");
if (visualUI && !["post525-update", "oct11-ui", "feedback22", "settings-workflow-audit", "image-quality-dialog"].includes(viewsMode)) throw new Error("Visual inspection is not supported by the selected view scenario");
if (visualCache && viewsMode !== "persistent-cache") throw new Error("Visual cache inspection requires --views-mode=persistent-cache");
if (!runtimeArg || !genreArg || !importArg || !viewsArg) {
  console.error("Usage: node native_collection_tests.js <runtime-dir> <GenreRegistryTest.exe> <MetabibImportTest.exe> <CollectionViewsTest.exe>");
  process.exit(2);
}
const runtime = fs.realpathSync(runtimeArg);
const focusedViews = viewsMode !== null || process.argv.includes('--download-scenarios-only') || onlineOnly || archiveOnly || plainOnly || reviewsOnly;
const tests = [genreArg, importArg, viewsArg].map((p,i) => i<2 && p==='-' && focusedViews ? null : fs.realpathSync(p));
const names = ["GenreRegistryTest.exe", "MetabibImportTest.exe", viewsMode==='reader-story' ? "StoryReaderTest.exe" : "CollectionViewsTest.exe"];
function machine(file) {
  const data = fs.readFileSync(file);
  if (data.length < 64 || data.toString("ascii", 0, 2) !== "MZ") throw new Error(`Invalid PE file: ${file}`);
  const offset = data.readUInt32LE(0x3c);
  if (offset + 6 > data.length || data.readUInt32LE(offset) !== 0x4550) throw new Error(`Invalid PE header: ${file}`);
  return data.readUInt16LE(offset + 4);
}
for (let i = 0; i < tests.length; i++) {
  if (tests[i]===null) continue; // focused runs do not execute core/import binaries
  if (path.basename(tests[i]).toLowerCase() !== names[i].toLowerCase()) throw new Error(`Expected ${names[i]}: ${tests[i]}`);
}
const architecture = machine(tests[2]);
if (![0x14c, 0x8664].includes(architecture)) throw new Error("Tests must be x86 or x64.");
for (const exe of tests) if (exe!==null && machine(exe) !== architecture) throw new Error("Native test architectures differ.");
if (machine(path.join(runtime, "sqlite3.dll")) !== architecture) throw new Error("SQLite DLL architecture does not match tests.");
let post530Fixtures;
const modes = ["sqlite-mapping", "reader-open-choice", "reader-host-session", "reader-session-context", "reader-cache-settings", "reader-packages", "reader-components", "minimal-first-install", "post530", "update-mounts", "reader-spread", "optional-components", "feedback529", "view-sessions", "startup-deferred", "startup-deferred-publisher", "startup-deferred-fallback", "startup-deferred-close", "reader-resource-idle", "post525-update", "update-repair", "reader-cache-performance", "compact-book-views", "release23-filters", "metadata-book-columns", "author-display-setting", "export-results-audit", "search-query-modes", "legacy-import-preview", "inp-streaming", "inp-streaming-memory", "reader-notes-proposals", "update-keyboard-accessibility", "update-source-failures", "reader-conversion-audit", "settings-workflow-audit", "catalog-audit", "export-preparation", "feedback22", "feedback21", "metadata-archive-codecs", "feedback20-main", "update-form-notifier", "book-preview-layout", "metadata-fill-layout", "metadata-fill-ui", "collection-metadata-sync", "metabib-size","reader-pipeline-cache","conversion-menu","publisher-metadata-index","main-toolbar-states", "main-publisher-index-cache", "feedback19-main","catalog-sources-workflow","search-startup-layout","queue-serialization","queue-persistence","queue-load-negative","queue-load-truncated","queue-load-zero","search-preset-transfer","external-reader-names","metadata-prefix-bounds","ordinary-book-export-identity","atomic-ini","group-book-identity","reader-copy-identity","favorite-ui","update-outcomes","system-remap","favorite-columns","author-favorites","favorite-dao","publisher-search","publisher-columns","filter-captions","deleted-filter","cache-presets","search-presets","builtin-export","series-stream","fbd-editor-save","update-theme","bulk-writes","query-batch","oct11-ui","merge-scale","audit-new","persistent-cache","feedback14","book-preview","large-inpx","genre-order", "", "language-isolation", "favorites-add", "genre-link", "source-genres", "publisher-selection", "adjacent-series", "publisher-startup", "publisher-links", "publisher-error-log", "reader-compatibility", "builtin-reader", "loose-archive", "book-gallery", "book-information", "column-filters", "list-performance", "collection-merge", "catalog-sources", "read-folder-cleanup", "temp-exit-cleanup", "program-update-ui", "first-run", "first-run-cancel"];
modes.push('reader-small-fb2', 'reader-session-process', 'book-preview-adaptive');
modes.push('duplicate-source', 'review-formatting');
modes.push('ibk-components');
modes.push('ibk-download-live');
modes.push('component-mirrors', 'reader-portable');
if (process.env.HOMELIB_PUBLISHED_COMPONENT_PACKAGES || viewsMode === 'published-components') modes.push('published-components');
if (process.env.HOMELIB_MCP_COMPONENT_PACKAGES || viewsMode === 'optional-mcp') modes.push('optional-mcp');
if (process.env.HOMELIB_ZSTD_COMPONENT_PACKAGES || viewsMode === 'optional-zstd') modes.push('optional-zstd');
if (process.env.HOMELIB_FORMAT_COMPONENT_PACKAGES || viewsMode === 'format-components') modes.push('format-components');
modes.push('webp-live');
modes.push('archive-open-feedback');
modes.push('component-prompt-feedback');
modes.push('djvu-first-use-feedback');
modes.push('component-batch-feedback');
modes.push('save-dependency-feedback');
modes.push('reader-link-feedback');
modes.push('distribution-layout');
modes.push('export-path-feedback');
modes.push('flibrary-source-preparation');
modes.push('estimate-failure-visibility');
modes.push('export-cache-lifecycle');
if (viewsMode !== null && !modes.includes(viewsMode) && !proposalVisualModes.includes(viewsMode) && !['reader-story','save-host-resume','save-module-restart','save-planning','minimum-save','unified-send','diagnostics-cache-age','paged-export-progress','image-components','catalogue-formats','catalogue-performance','book-output-reset','display-labels','flibrary-quality','first-book-list','first-book-list-large','image-quality-dialog','refactor-audit','native-folder-picker','cancel-interactive','export-cancel-interactive','legacy-import-interactive','reader-filter','reader-main-filter','reader-chapters'].includes(viewsMode)) throw new Error(`Unknown view scenario: ${viewsMode}`);
const requiredViews = {
  'book-preview-adaptive': ['PASS adaptive preview uses actual Main bounded automatic height in all six views', 'PASS expanded illustrations keep panel height and wide description position', 'PASS adaptive preview keeps thumbnail pixels and original source unchanged'],
  'export-cache-lifecycle': ['PASS real archived-book estimate removes work immediately and retains reusable cached sources until exit', 'PASS failed archived-book estimate removes all operation work and preserves original archives', 'PASS in-flight estimate cancellation removes operation work and preserves original archives', 'PASS successful failed and cancelled real exports remove operation work and preserve source files', 'PASS real main-form exit clears archived-book estimate and export caches while preserving every original', 'PASS opt-in detailed diagnostics persist capture real failed cancelled exports with exact paths redact credentials exclude book contents and report local component versions', 'PASS native diagnostic journal option remains visible persists and toggles correctly at 96 144 192 DPI'],
  'estimate-failure-visibility': ['PASS complete estimate report preserves every failed book full reason identity required modules partial known sizes and atomic UTF8 save', 'PASS real batch estimate shows all 22 failures without hovering opens full report resets changed format and remains usable light dark 96 144 192 DPI'],
  'flibrary-source-preparation': ['PASS actual FLibrary source restores one cover and two illustrations with unchanged borrowed bytes', 'PASS repeated FLibrary restoration does not create another cover or illustration', 'PASS repeated native FB2 metadata rewrite preserves every restored image and readable body'],
  'export-path-feedback': ['PASS export long Unicode filenames complete deep directories native ZIP exact bytes collisions and same-format copies', 'PASS atomic output race and cancellation preserve existing files sources and caller stream position', 'PASS explicit overwrite replaces only saved copies and rejects original identities including hard links', 'PASS Shell copy keeps numbered duplicates by default and replaces saved copies only when requested', 'PASS batch export failures retain every book reason use one final summary and preserve existing paths', 'PASS restored Save As dialog keeps mixed policy image quality ZIP masks path and scan exclusions', 'PASS save continuation exact Unicode options remaining identities one consumer live owner stale source unrelated update and bounded count', 'PASS default ask per-file choices batch apply-to-all cancellation source content and Shell collisions at 96 and 192 DPI', 'PASS protected source Shell collision reports one failed book continues the batch and preserves original bytes'],
  'distribution-layout': ['PASS distribution layout resolves grouped and legacy resources all genre languages and update metadata without root copies'],
  'reader-link-feedback': ['PASS FB2 EPUB internal chapter links navigate by click preserve footnotes and dragging selection in single and double pages'],
  'save-dependency-feedback': ['PASS one book reports known missing processing image and format modules together with content detection cancellation and unchanged copies'],
  'component-batch-feedback': ['PASS explicit operation batches only its known missing modules, validates both real packages and uses one restart'],
  'djvu-first-use-feedback': ['PASS DjVu first use downloads its ready verified package without another 7-Zip install'],
  'component-prompt-feedback': ['PASS component prompts show purpose once preserve context and agree on small download sizes', 'PASS reader formats help names native handlers and external updates with scrollable light dark 96 144 192 DPI dialog'],
  'archive-open-feedback': ['PASS archive picker prefers main document keeps companion text and double click confirms reading and conversion', 'PASS CBZ literal bracket Unicode duplicate base names natural order and all page pixels'],
  'format-components': ['PASS independent format base converts FB2 to EPUB without Kindle Office XPS', 'PASS independent format component prepare verify install BookProcessing', 'PASS independent format component prepare verify install ImageProcessing', 'PASS independent format component prepare verify install Kindle', 'PASS independent format component prepare verify install LegacyBooks', 'PASS independent format component prepare verify install LegacyOffice', 'PASS independent format component prepare verify install XPS'],
  'optional-mcp': ['PASS optional MCP setup preserves default custom Unicode profiles', 'PASS optional MCP is hidden until requested', 'PASS optional MCP actual package verifies architecture version restricted files'],
  'optional-zstd': ['PASS optional Zstandard real compact download cancel tamper install without restart', 'PASS optional Zstandard newly installed official decoder reads actual Metabib'],
  'published-components': ['PASS published component manifest prepare verify install HomeLibReader', 'PASS published component manifest prepare verify install BookConverter', 'PASS published component manifest prepare verify install PDFium'],
  'component-mirrors': ['PASS component mirror source and real download fallback preserve exact version architecture and bytes', 'PASS component mirror native UI shows exact fallback version and GitHub source', 'PASS IBK mirror preserves unchanged complete original distributions'],
  'ibk-download-live': ['PASS IBK live native source check and updater download preserve pinned identities and prepare complete original data'],
  'ibk-components': ['PASS IBK original component requests on first use', 'PASS catalogue-formats audit completed'],
  'duplicate-source': ['PASS duplicate source preference: bulk choice', 'PASS duplicate preview: scoped identity', 'PASS duplicate apply: preferred ID', 'PASS duplicate large preview: 100000 rows'],
  'reader-session-process': ['PASS independent reader process returns progress across restart rejects foreign and missing replies survives catalogue close and removes only session files'],
  "reader-small-fb2": ["PASS actual Main small unchanged FB2 opens and pages through explicit builtin and default reader actions without repeated preparation"],
  "paged-export-progress": ["PASS paged export actual progress caption, bar, cancel enabled and source preservation cancel=0", "PASS paged export actual progress caption, bar, cancel enabled and source preservation cancel=1"],
  "minimal-first-install": ["PASS minimal first install verifies actual archive, excludes optional binaries and installs 7-Zip DocSharp DjVuLibre with preserved private files"],
  "reader-session-context": ["PASS reader session preserves selected archive member history settings progress notes and source leases while rejecting invalid replies"],
  "sqlite-mapping": ["PASS SQLite mapped reads beyond 256 MB preserve concurrent snapshots Unicode rollback backup restore and compaction"],
  "reader-open-choice": ["PASS catalogue open-book choice keeps catalogue colours while reading theme stays independent; accept cancel and remembered choice work"],
  "reader-host-session": ["PASS catalogue reader host opens the selected archive member with existing history notes bookmarks progress and source protection"],
  "reader-cache-settings": ["PASS standalone reader cache settings preserve books notes positions and active files with age size cancel and reload"],
  "reader-packages": ["PASS real reader PDF and conversion packages verify architecture hashes versions and install without catalogue preserving personal files"],
  "reader-components": ["PASS catalogue FB2 baseline offers external readers first hides absent format modules and keeps installed conversion modules", "PASS standalone reader hides catalogue updates and resolves missing format modules with correct independent download"],
  "post530": ["PASS post530 metadata dependency stops readers and indexing once and releases the modal scan before first-use handoff", "PASS post530 component results and actions arrive independently of a slow source", "PASS post530 close joins parallel component probes without stale delivery", "PASS post530 one pinned AlReader archive verifies for both host architectures", "PASS post530 official 7-Zip 26.05 installs without a previous unpacker and rejects a changed bootstrap", "PASS first-list title prefilter preserves Cyrillic literal percent underscore quotes exact title and hidden deleted"],"optional-components": ["PASS optional packages verify actual binary identities", "PASS optional updates are opt-in", "PASS first-use decoder request", "PASS optional AlReader mirror"], "export-cancel-interactive": ["PASS Main export destination cancel preserves marked books tag=795", "PASS Main export destination cancel preserves marked books tag=799", "PASS Main export destination cancel preserves marked books tag=850"],"reader-resource-idle": ["PASS reader resource idle control retains the same +4 budgets without repeated reader lifecycles"],"post525-update": ["PASS update history loads 3 then 3 then 3 then the remainder", "PASS update history cache preserves locked/read-only/empty histories and foreign temporaries, cleans failed writes and saves Unicode", "PASS lazy startup, author version display, DjVu date parsing and separate versions in both themes at 96/144/192 DPI"],"update-repair": ["PASS cached component with a vanished updater requests full repair before restart and preserves installed files", "PASS application-only web release remains visible and opens its own release page", "PASS application repair uses the verified matching installer even when an installed helper exists", "PASS updater component selection respects the 5000ms budget for 100 changes", "PASS unavailable application archive does not block an independent component download or open its web page", "PASS unavailable optional reader author does not force installation or block required runtime repair", "PASS same-release repair downloads minimal verified application without forcing optional archive or DOC components", "PASS missing updater fallback is bound to exact archive bytes and rejects changed helpers or source digests", "PASS same-version ready repair survives reopening with a missing updater and preserves readable controls in two themes and three DPI settings"], "metadata-book-columns-visual": ["PASS metadata columns visual fixture closed explicitly"], "metadata-book-columns": ["PASS metadata columns actual header menus expose four new IDs once and preserve default layouts", "PASS metadata columns DAO-backed rows render publisher translators city year ISBN in all six book lists and groups", "PASS metadata columns numeric year order empty Unicode yo exact and combined filters on flat and grouped lists", "PASS metadata columns saved order width visibility survive fresh column stores and actual Main header reconstruction", "PASS metadata columns numeric and checklist editors apply cancel and missing-year choices in both themes", "PASS metadata groups read current catalog after metadata delta without replacing personal annotation review rating progress or identity", "PASS metadata groups keep empty zero replaced and missing LibID publication fields blank and preserve personal cards", "PASS metadata groups return saved cards from an unavailable catalog without creating its missing file", "PASS metadata groups project 129 cards in two catalog searches preserving count order and read-only personal data"], "author-display-setting": ["PASS existing author initials/full-name menus preserve eleven Unicode/compound/incomplete names", "PASS actual Add to Search preserves literal, legacy and expression drafts"], "update-proposals-visual": ["PASS update proposals visual fixtures closed explicitly"], "reader-notes-visual": ["PASS reader-notes-visual closed_by_operator"], "catalog-proposals-visual": ["PASS proposal legacy visual preview closed"], "main-search-proposals-visual": ["PASS Main search proposals visual fixtures explicitly inspected"], "export-results-audit": ["PASS export results MTP TXT filesystem-shell surrogate sends exact Unicode TXT from plain and archived FB2 and preserves stale FB2", "PASS export results all six actual Main scenarios"], "search-query-modes": ["PASS proposal search modes literal SQL metacharacters"], "legacy-import-preview": ["PASS proposal legacy preview counts", "PASS proposal legacy target editor starts empty until row selection and restores explicitly saved mappings"], "inp-streaming": ["PASS proposal INP reader matches", "PASS proposal actual INP worker preserves"], "inp-streaming-memory": ["PASS proposal INP large-member spool preserves 90000 Unicode rows"], "reader-notes-proposals": ["PASS reader-bookmark-rename stale_shift_rejected cancel_preserves normal_unicode_rename", "PASS reader-note-conflict", "PASS reader-note-filter", "PASS reader-notes-proposals"], "update-keyboard-accessibility": ["PASS update history paging native Tab Enter Space MSAA and final-batch focus", "PASS update history native Tab Enter Space name state focus scroll reload", "PASS update theme tolerates deletion of its formerly focused control in a real form callback", "PASS update theme preserves a newly shown callback input form without restoring the old header", "PASS update theme coalesces rapid changes and preserves the latest native Windows and accessibility focus", "PASS update theme tolerates deletion of a queued focus target before deferred delivery"], "update-source-failures": ["PASS restored component-only batch page uses saved canonical sources for all components and safe legacy-invalid URL fallbacks without network or installation cases=23", "PASS update sources unavailable manual check", "PASS update sources partial failure", "PASS update sources Retry", "PASS update sources automatic failures"], "legacy-import-interactive": ["PASS Main uppercase MHLUD imports the actual file", "PASS Main legacy import cancel preserves earlier values"], "reader-conversion-audit": ["PASS reader-conversion-audit local_html_markdown=24 rejected_resources=3 source_and_stream_preserved=1"], "settings-workflow-audit": ["PASS settings custom update interval 1000", "PASS settings custom update interval 1020", "PASS settings custom update interval 525600", "PASS settings Add script", "PASS settings Edit script", "PASS settings Cancel script", "PASS settings deleting other scripts", "PASS settings delete boundaries cover no selection, Standard, first/middle/last default and every removed row with profile reload (20 combinations)"], "catalog-audit": ["PASS catalog audit legacy headers", "PASS catalog audit legacy EOF", "PASS catalog audit quoted comparisons", "PASS catalog audit actual legacy import preserves catalog and personal cards, named groups and a second collection"], "export-preparation": ["PASS Main failed NFT export restores the saved folder template"], "export-cancel-interactive": ["PASS Main export destination cancel preserves marked books tag=799", "PASS Main export destination cancel preserves marked books tag=850"], "feedback22": ["PASS feedback22 readable XML", "PASS feedback22 favorite profile", "PASS feedback22 author initials", "PASS feedback22 standalone tools"], "native-folder-picker": ["PASS native folder picker case 1", "PASS native folder picker case 2", "PASS native folder picker case 3", "PASS native folder picker case 4"], "feedback21": ["PASS feedback21 portable PPTX/XLSX/ODP/ODS reader", "PASS feedback21 actual official four-package Office update", "PASS feedback21 archived FBD card/cover/gallery preview-paired-ppmd.zip", "PASS feedback21 archived FBD card/cover/gallery preview-paired-solid.7z", "PASS feedback21 archived FBD card/cover/gallery preview-single-fbd.zip", "PASS feedback21 portable favorite authors", "PASS feedback21 reader toolbar order", "PASS feedback21 actual updater form"],"metadata-archive-codecs": ["PASS native metadata prefix ppmd.zip", "PASS native metadata prefix ordinary.7z", "PASS native metadata prefix solid.7z", "PASS native archive prefix limit and cancellation", "PASS bounded publication metadata .epub packed=1", "PASS bounded publication metadata .docx packed=1", "PASS bounded publication metadata .odt packed=1", "PASS bounded publication metadata .fb3 packed=1", "PASS single-book metadata container single.fb2.xz", "PASS single-book metadata container renamed-odt.zip detected=.odt", "PASS single-book metadata container single-fbd.zip detected=.fbd", "PASS metadata package MIME distinguishes text ODT", "PASS ambiguous metadata archive", "PASS 1206 interleaved archive records", "PASS bounded parallel metadata pipeline"],"feedback20-main": ["PASS feedback20 metadata predicates", "PASS feedback20 actual search fields", "PASS feedback20 note identities", "PASS feedback20 global notes manager", "PASS feedback20 local export timestamps", "PASS feedback20 actual information card shows catalog annotation"],"update-form-notifier": ["PASS updater component check actual success survives form HWND recreation with owned loopback transport", "PASS updater component check actual failures release checking state after form HWND recreation", "PASS updater pre-Start UI failure frees its real canceled suspended worker without waiting forever or making HTTP requests", "PASS updater component in-flight teardown joins its actual worker before removing the notifier", "PASS updater download actual progress and verification failure survive form HWND recreation", "PASS updater download actual cancel completes through the stable form notifier", "PASS updater form in-flight teardown joins its actual download worker and removes its notifier without orphan windows", "PASS updater notifier lifecycle leaves catalog, personal cards and installed component source bytes unchanged", "PASS updater fixture restores the original process-local cache environment"],
  "oct11-ui": ["PASS app theme switch", "PASS Windows dark-theme suggestion"],"merge-scale": ["PASS large merge reuses imported books"],"audit-new": ["PASS adversarial audit fixed checks"],
  "filter-captions": ["PASS caption font measurements", "PASS annotation caption expanded dark=1 dpi=192"],
  "deleted-filter": ["PASS fresh search and tree-mode changes never load the whole catalog", "PASS search and group count/rows hide six deleted books", "PASS deletion toggle uses only the applied snapshot", "PASS legacy presets inherit the shared mode after reopen"],
  "cache-presets": ["PASS cache folder presets"],
  "publisher-search": ["PASS publisher queries preserve Unicode case", "PASS publisher input waits for Apply", "PASS publisher presets preserve typed expressions", "PASS expanded annotation remains visible"],
  "author-favorites": ["PASS favorite authors baseline", "PASS favorite authors persistence", "PASS favorite authors isolated durable profile"],
  "ordinary-book-export-identity": ["PASS ordinary Main export identity matching", "PASS ordinary Main export identity replaced-before-worker"],
  "search-startup-layout": ["PASS search startup naturally focuses Author and keeps query mode reachable and escapable by Tab steps=", "PASS search startup first category header, Author label and input are fully visible without scaling or scrolling", "PASS search startup fix preserves deliberate Date focus and scrolling during ordinary view refresh"],
  "queue-serialization": ["PASS queue serializer legacy odd", "PASS queue serializer restores versioned identity", "PASS queue serializer malformed/future identity", "PASS queue serializer rejects truncation"],
  "metabib-size": ["PASS actual native Metabib and INPX import preserve the same 2000", "PASS Metabib retains annotation, publication metadata"],
  "reader-pipeline-cache": ["PASS actual LRU Touch keeps proved bounded input", "PASS unmanaged raw input stamps", "PASS actual bundled DOC cold preparation runs once", "PASS actual KF8 warm adapter", "PASS pipeline preparation preserves"],
  "publisher-metadata-index": ["PASS FB2 publisher parser", "PASS real publisher index", "PASS publisher, publisher series and source completion", "PASS publisher fill preserves known catalog values and rejects reused BookID"],
  "conversion-menu": ["PASS zero-script raw collection actual context menu converts to .epub", "PASS zero-script raw collection actual context menu converts to .fb2"],
  "collection-metadata-sync": ["PASS strict complete bounded metadata", "PASS real FB2/ZIP read-only preview", "PASS stale ID/path/root/source/late edits fail closed", "PASS canceled preview writes nothing", "PASS resumed fill preserves its committed chunk", "PASS resumable metadata scan", "PASS same-plan annotation selection", "PASS metadata cache invalidates"],
  "reader-cache-performance": ["PROFILE managed input 8MB cold_ms=", "PASS managed input identity preserves native locks, dependency edits, overlapping readers, cancellation and same-size replacement after release", "PASS held managed input avoids repeated full payload scans"],
  "compact-book-views": ["PASS compact book views keep complete rows at minimum and normal height cases=72"],
  "book-preview-layout": ["PASS book batch applies one final native viewport size dark=0 dpi=96", "PASS book batch applies one final native viewport size dark=1 dpi=192", "PASS annotation text cache preserves external Text Lines and native handle restoration dark=0 dpi=96", "PASS annotation text cache preserves external Text Lines and native handle restoration dark=1 dpi=192", "PASS fixed information footer dark=0 dpi=96", "PASS fixed information footer dark=0 dpi=144", "PASS fixed information footer dark=0 dpi=192", "PASS fixed information footer dark=1 dpi=96", "PASS fixed information footer dark=1 dpi=144", "PASS fixed information footer dark=1 dpi=192", "PASS source bytes/profile preserved; short/long/cover/gallery/scroll/DPI/native click/cycling checked"],
  "metadata-fill-layout": ["PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=96", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=144", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=0 dpi=192", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=96", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=144", "PASS metadata form captions/footer/defaults fit normal and minimum window dark=1 dpi=192"],
  "metadata-fill-ui": ["PASS metadata ETA warmup", "PASS actual metadata form defaults", "PASS actual Main metadata action fills", "PASS Sources target exposes independent", "PASS actual metadata UI rejects a changed collection root", "PASS wizard successful INPX Finish opens only the requested exact collection metadata dialog without auto-preview or writes", "PASS wizard ordinary finish, cancel, uncommitted preview, creation failure and vanished collection never request or open metadata fill", "PASS wizard metadata choice revalidates its registered local root and refuses unavailable or online-only targets", "PASS wizard Finish metadata button and explanation fit six theme/DPI combinations without scanning"],
  "main-toolbar-states": ["PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=96 logical_width=1200", "PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=96 logical_width=800", "PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=144 logical_width=1200", "PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=144 logical_width=800", "PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=192 logical_width=1200", "PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=192 logical_width=800", "PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=96", "PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=144", "PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=192", "PASS Main toolbar state matrix restores original theme, DPI and window without catalog changes", "PASS actual Main three-row font and DPI growth restores automatic options without catalog or personal card changes"],
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
  "favorite-ui": ["PASS favorite baseline", "PASS favorite search intersects", "PASS known commits refresh", "PASS favorite removal refreshes", "PASS inline favorite condition fits", "PASS all favorite authors actual menu includes absent names, filters, DPI, cancel, exact-key removal and reopen without changing books"],
  "update-outcomes": ["PASS update outcomes"],
  "system-remap": ["PASS system remap swap/raw BLOBs", "PASS system remap three-way cycle", "PASS system remap False mode quarantines", "PASS system remap exact BLOBs/personal fields/groups"],
  "favorite-columns": ["PASS favorite column checkbox"],
  "favorite-dao": ["PASS favorite DAO intersects"],
  "publisher-columns": ["PASS publisher column uses loaded metadata"],
  "search-preset-transfer": ["PASS preset transfer editable XML and legacy cxml2-cxml", "PASS preset transfer validates the entire input before merge", "PASS preset transfer actual import menu keeps draft and old names", "PASS preset transfer actual selected-all export snapshots", "PASS preset transfer legacy import, invalid-locked-readonly failures", "PASS preset transfer compact menu stays inside existing preset row at96-144-192DPI in both themes without widening search"],
  "search-presets": ["PASS presets preserve typed names"],
  "builtin-export": ["PASS independent native FB2 to EPUB and EPUB to FB2 actions", "PASS converted FB2 and EPUB replace only selected existing output after complete conversion", "PASS ordinary PDF copying is unchanged", "PASS cancelled native export workers", "PASS native conversion warnings", "PASS MTP export branch marshals", "PASS export log dark=1 dpi=192"],
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
  "update-mounts": ["PASS real volume-GUID mount accepts update preparation", "PASS mounted-volume descendants remain rejected"],
  "reader-spread": ["PASS reader spread draws both pages"],
  "builtin-reader": ["PASS main built-in reader action opens selected book", "PASS malformed and canceled readers return"],
  "external-reader-names": ["PASS real FB2 rewrite changes only private copy for Readable original book", "PASS real FB2 rewrite changes only private copy for 0031", "PASS external title-first Unicode name", "PASS equal titles/raw IDs remain separate", "PASS changed source refreshes owned alias", "PASS actual prepared extension, wrong-origin rejection", "PASS invalid control/device/path title", "PASS touched canonical warm hit uses dependency metadata", "PASS legacy missing dependency metadata and explicit same-size FB2 rewrite refresh safely after cache Touch", "PASS small cache limit keeps the canonical input alive", "PASS external friendly alias uses cancellable background lifecycle", "PASS external-reader filename policy preserves original/canonical bytes, profiles, reader history and notes"],
  "metadata-prefix-bounds": ["PASS metadata prefix UTF8 all two-three-four-byte body splits, BOM and public parser, no extra body reads", "PASS metadata prefix closed Unicode metadata ignores malformed body, exact legal replacement character and series preserved", "PASS metadata prefix UTF16 LE-BE odd byte and split surrogate remain body-only, source position exact", "PASS metadata prefix 121 deterministic UTF8 corruption probes fail closed without changing series metadata", "PASS metadata prefix UTF16 malformed high-low-surrogate metadata rejected by recovery and public parser", "PASS metadata prefix fragmented split inside metadata resumes exactly, byte bound and both cancellation paths preserved", "PASS metadata prefix failed stream untouched, source bytes ownership and main profile preserved"],
  "reader-chapters": ["PASS chapter titles exact nine independent mixed-level labels, numbering toggle, position objects and selected chapter", "PASS chapter titles all614 Dome labels and native positions match frozen original reader SHA, text and source/profile unchanged"],
  "reader-filter": ["PASS actual PDF DjVu EPUB TXT FB2 and DOC readers stay visible and avoid catalogue scans with filter on and off"],
  "reader-main-filter": ["PASS native sole/multiple selections retain old hidden/focus/children-above/resolved/next/dirty-delete-add-unselect-invert/reentrant-clear/init semantics", "PASS actual Main modal opens and pages identical Under Dome content at a 50K tail selection, with filter off/on and complete idle actions"],
  "reader-compatibility": ["PASS external opening detects PDF under FB2 name without rewriting metadata or changing source", "PASS plain FB2 reader preserves ordinary paths", "PASS stable reader cache survives reimport", "PASS reader cache hit avoids source extraction"],
  "read-folder-cleanup": ["PASS manual reader cleanup", "PASS custom reading folder is cleared", "PASS reader cleanup does not follow"],
  "book-gallery": ["PASS gallery loads lazily in background", "PASS illustration preview arrows work and resized window position persists", "PASS changing books cancels old gallery", "PASS EPUB gallery leaves source unchanged"],
  "feedback529": ["PASS feedback529 block chapter boundaries", "PASS feedback529 asynchronous statistics", "PASS feedback529 JPEG XL alpha", "PASS feedback529 verified publisher/mixed/bracket", "PASS snapshot restore creates an isolated catalog", "PASS sync export destination persists", "PASS duplicate preview: scoped identity", "PASS duplicate apply: preferred ID", "PASS duplicate large preview: 100000 rows", "PASS backup descriptions preserve UTC time and operation", "PASS backup cleanup pins exact folders", "PASS backup cleanup refreshes missing rows"],
  "catalog-sources": ["PASS multiple INPX sources keep separate roots", "PASS statistics count book records once", "PASS all sources participate without multiselect", "PASS source text reflows and wheel reaches the report"],
  "book-information": ["PASS common book information loads real FLibrary biographies", "PASS review parser preserves Russian text"],
  "collection-merge": ["PASS safe merge previews", "PASS optional copy merging verifies origin", "PASS merge preview reuses sparse target user snapshot"],
  "display-labels": ["PASS diagnostic display labels same-process alternating comparison preserves all values"],
  "first-book-list": ["PASS book display labels preserve established Unicode whitespace initials nicknames empty single multiple authors genres cases=2058", "PASS first-list stored book strings nested arrays scalars survive iterator release rebuild expanded series and fresh-query comparison", "PASS first-list stored Unicode annotation review keywords survive iterator destruction and tree clear", "PASS full author stream matches independent lookups with dangling links renamed Unicode authors bound=3", "PASS full author stream matches independent lookups with dangling links renamed Unicode authors bound=0", "PASS full author stream matches independent lookups with dangling links renamed Unicode authors bound=1", "PASS full author stream matches independent lookups with dangling links renamed Unicode authors bound=2", "PASS full visible metadata matches independent lookups across leading middle trailing deleted gaps empty lists coauthors and expanded series", "PASS first-list actual queries preserve compact expanded deleted metadata counts and source bytes"],
  "list-performance": ["PASS list profiling preserves", "PASS nested genre iterators retain independent membership", "PASS main window repaints while SQL runs and cancel is available", "PASS filtered focused-book actions avoid repeated complete catalogue scans", "PASS no-focus and group-focus idle actions cache checks"],
  "column-filters": ["PASS column filters combine, survive regrouping, hide empty groups and mark only matching books", "PASS compact size popup converts fractional MB", "PASS per-column dialogs expose only their own loaded values"],
  "temp-exit-cleanup": ["PASS real main-form exit removes temporary converted copies"],
  "program-update-ui": ["PASS component table and dedicated changes tab remain separate", "PASS automatic update cycle waits for both responses", "PASS one-line update summaries combine all available components", "PASS new update default is three days and preserves explicit choices", "PASS update settings preserve never and custom hours", "PASS update popup shows installed version", "PASS dates and shared formatting", "PASS update notes retain nested SQLite", "PASS previous changelogs start collapsed", "PASS update window expands reading space", "PASS saved histories survive reopening", "PASS resized update window and text zoom", "PASS short release height stays compact", "PASS expanded old release ends directly after its text"],
  "online-download": ["PASS online main reader downloads ZIP", "PASS online main queue downloads ZIP", "PASS online main queue restarts for another remote book"],
  "online-plain": ["PASS plain online FB2 is downloaded before compatibility conversion"],
  "review-http": ["PASS HTTP reviews decode UTF-8"],
  "review-formatting": ["PASS review formatting separates reviewers paragraphs", "PASS review formatting handles missing div separators", "PASS long review lists preserve all reviewer", "PASS native review memo wraps scrolls preserves cached text", "PASS book page without reviews remains empty"],
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
  if (mode==='flibrary-source-preparation') return requiredViews[mode];
  if (mode==='distribution-layout') return requiredViews[mode];
  if (mode==='webp-live') return ['PASS live WebP update check'];
  if (mode==='reader-portable') return ['PASS portable catalogue and standalone reader default without marker explicit profile Unicode books sessions and unchanged existing data'];
  if (mode==='book-output-reset') return ['PASS diagnostic out reset preserves every established field and retained nested arrays','RESETBENCH trial=6','PASS diagnostic managed out record reset comparison completed'];
  if (mode==='display-labels') return ['PASS book display labels preserve established Unicode whitespace initials nicknames empty single multiple authors genres cases=2058','iterations=2000000 trials=7','before_cycles=','LABELBENCH phase=2 trial=6','PASS diagnostic display labels same-process alternating comparison preserves all values'];
  if (mode==='save-module-restart') return ['PASS compact legacy converter to independent processing download actual installer restart restored review cancel and unchanged source'];
  if (mode==='reader-story') return ['PASS interactive story independent interface hiding and F11 full screen restore window menu answers and exact scene','PASS native SM false suffix, real controls, conditional branch, Unicode input, FB2 EPUB route export, verified resume, existing target and cancellation cleanup'];
  if (mode==='save-host-resume') return ['PASS actual reader host consumes restarted Save As once, restores options over visible book, cancels without output and preserves source'];
  if (mode==='save-planning') return ['PASS real mixed save keep-fb2-epub-other-epub FB2 EPUB PDF DjVu scan-PDF scan-DjVu','PASS real illustrated and scan size estimates include all image modes and ZIP without source changes','PASS save continuation exact Unicode options remaining identities one consumer live owner stale source unrelated update and bounded count','PASS save estimate known bytes four modes native ZIP unavailable module cancellation and unchanged source'];
  if (mode==='minimum-save') return ['PASS minimum save byte-exact FB2 EPUB and native ZIP without converter or 7-Zip; real changes report one missing-module request'];
  if (mode==='unified-send') return ['PASS unified save layout dark=1 ppi=192','PASS unified TXT minified UTF8 CP1251','PASS unified send original TXT stays byte-exact','PASS unified send public command preserves source formats, explicit conversions, image presets, mixed batches, cancellation, marks and Shell delivery'];
  if (mode==='flibrary-quality') return ['PASS explicit FLibrary text-only export needs no JPEG XL decoder and cannot replace a restored reading copy','PASS FLibrary JPEG XL quality-aware FB2 EPUB exports preserve alpha or remove pictures while retaining the complete text'];
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-ui')) return ['ACTUAL startup ui_fixture=1','PASS streamed alphabet theme=1 ppi=192','PASS tree text and headers fit theme=1 ppi=192','PASS streamed alphabets preserve exact letters order geometry and real author series filter actions','PASS actual catalogue startup phase profile completed','TRACE catalogue orderly cleanup complete'];
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-startup')) return ['PASS actual catalogue startup phase profile completed','PASS actual catalogue uses the distributed deferred startup path','ACTUAL startup icons_load_ms=','ACTUAL startup main_create_ms=','TRACE catalogue orderly cleanup complete'];
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-sample')) return ['PASS actual catalogue sampled iterator profile completed','TRACE cache-clear symbol RVA','TRACE catalogue orderly cleanup complete'];
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-record-transfer')) return ['TRANSFER copy=1 trial=1','TRANSFER copy=0 trial=8','PASS same-binary full catalogue record ownership transfer comparison preserves all row counts','TRACE cache-clear symbol RVA','TRACE catalogue orderly cleanup complete'];
  if (mode==='catalogue-performance') return [process.argv.includes('--catalogue-profile')
    ? 'PASS actual catalogue startup and full-list profile completed'
    : 'PASS actual catalogue startup empty hide-deleted title author series publisher queries completed',
    'TRACE cache-clear symbol RVA', 'TRACE catalogue orderly cleanup complete'];
  if (mode==='first-book-list-large') return ['PASS first-list actual queries preserve compact expanded deleted metadata counts and source bytes'];
  if (mode==='image-quality-dialog') return ['PASS image quality layout ppi=96','PASS image quality dialog choice='];
  if (mode === 'diagnostics-cache-age') return [
    'PASS native quality snapshot tolerates exclusive and shared readers',
    'PASS direct hidden-library search matches materialized',
    'PASS native image quality estimates, FB2/EPUB exports',
    'PASS native TIFF and TIFF comic keep every frame',
    'PASS cache age expires unused files',
    'PASS seven-day bounded Unicode diagnostics',
  ];
  if (mode==='catalogue-formats') return ['PASS catalogue-formats audit completed'];
  if (mode==='image-components') return ['PASS image-components WebP requested','PASS image-components WebP package native verification','PASS image-components official JPEG XL ZIP','PASS image-components JPEG XL keeps alpha'];
  if (mode==='download-scenarios') return Array.from({length:9},(_,i)=>'PASS download-scenarios case='+(i+1)+' result=');
  if (mode === 'view-sessions') return ['PASS view sessions isolate all six tabs and collections', 'PASS actual process restart restores automatically, asks yes/no after paint, disables restore and persists reset', 'PASS malformed view configuration is ignored without eager book loading', 'PASS view session settings persist all choices and reject invalid preference', 'PASS restore prompt remembers affirmative and negative choices across another process restart', 'TRACE main cleanup complete'];
  if (mode === 'startup-deferred-close') return ['PASS actual Main closes during background startup'];
  if (mode.startsWith('startup-deferred')) return [...(mode === 'startup-deferred-publisher' ? ['PASS publisher startup restores its language from one database snapshot'] : []), 'PASS actual Main appears before catalogue', 'PASS default author selection and saved book', 'PASS deferred startup workers cancel, preserve errors and free before Start', 'PASS deferred startup keeps saved book, view and collection fallback', 'PASS preferred sources preserve empty Unicode fallback rollback and expanded search rows', 'TRACE main cleanup complete'];
  if (mode === 'release23-filters') return ['PASS reader font offer does not expose its internal panel name', 'PASS release23 all 19 actual filter editors empty and populated in both themes at 96 144 192 DPI cases=57'];
  if (mode === 'release23-ready-visual') return ['PASS ready updater native row colours and selection lock in both themes at 96 144 192 DPI'];
  if (mode === "refactor-audit") return ["PASS refactor import rolls back", "PASS refactor bulk catalog restore", "PASS refactor batched notes", "PASS refactor legacy converter cancellation", "PASS refactor ZIP collision", "PASS refactor preliminary download cancellation", "PASS refactor incomplete link markup", "PASS refactor full Main DPI pass"];
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
function stage(folder, executable, mode = '') {
  fs.copyFileSync(executable, path.join(folder, path.basename(executable)));
  for (const name of ["sqlite3.dll", "libzstd.dll", "libeay32.dll", "ssleay32.dll", "homelib_webp.dll"]) {
    if (['optional-zstd','reader-components'].includes(mode) && name==='libzstd.dll') continue;
    const src = path.join(runtime, name);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(folder, name));
  }
  const archiveDll = path.join(runtime,'tools/7zip/7z.dll');
  if (!['minimum-save','save-module-restart'].includes(mode) && fs.existsSync(archiveDll)) {
    fs.mkdirSync(path.join(folder,'tools/7zip'),{recursive:true});
    fs.copyFileSync(archiveDll,path.join(folder,'tools/7zip/7z.dll'));
  }
  const decoder = path.join(runtime, "tools", "webp", "libwebp.dll");
  if (!['minimum-save','save-module-restart'].includes(mode)) {
    if (!fs.existsSync(decoder) || machine(decoder) !== architecture) throw new Error("WebP decoder is absent or has the wrong architecture.");
    const decoderDir = path.join(folder, "tools", "webp");
    fs.mkdirSync(decoderDir, { recursive: true });
    fs.copyFileSync(decoder, path.join(decoderDir, "libwebp.dll"));
  }
  // Icons and bundled genres contain no personal profiles or library databases.
  if (fs.existsSync(path.join(runtime, "Icons"))) copyDllTree(path.join(runtime, "Icons"), path.join(folder, "Icons"));
  for (const name of fs.readdirSync(runtime)) if (/^genres[^\\/]*\.glst$/i.test(name)) fs.copyFileSync(path.join(runtime, name), path.join(folder, name));
  // The DOC component uses managed AnyCPU assemblies, all bundled and isolated.
  if (!['minimum-save','save-module-restart'].includes(mode) && fs.existsSync(path.join(runtime, 'tools', 'doc'))) fs.cpSync(path.join(runtime, 'tools', 'doc'), path.join(folder, 'tools', 'doc'), {recursive:true});
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
function hashLargeFile(file) {
  const hash=require('crypto').createHash('sha256'), buffer=Buffer.allocUnsafe(1024*1024);
  const handle=fs.openSync(file,'r');
  try { let count; while((count=fs.readSync(handle,buffer,0,buffer.length,null))>0) hash.update(buffer.subarray(0,count)); }
  finally { fs.closeSync(handle); }
  return hash.digest('hex');
}
function requireNoCatalogueJournal(source) {
  // An empty WAL left after a clean close contains no committed frames. Never
  // copy a catalogue with actual WAL/rollback data, nor remove those files.
  for (const suffix of ['-wal','-journal']) {
    const journal=source+suffix;
    if (fs.existsSync(journal) && fs.statSync(journal).size!==0)
      throw Error('Catalogue has a nonempty journal; no raw snapshot is safe');
  }
}
function run(executable, mode, subcase = "") {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "HomeLibRu-native-"));
  const absolute = path.resolve(folder);
  const expectedRoot = path.resolve(os.tmpdir()) + path.sep;
  const readonlyInputs = [];
  let performanceSnapshot=null;
  if (!absolute.startsWith(expectedRoot) || !path.basename(absolute).startsWith("HomeLibRu-native-")) throw new Error("Unsafe temporary path.");
  try {
    stage(folder, executable, mode);
    if (mode==='book-preview-adaptive' && process.env.HOMELIB_TEST_PREVIEW_VISUAL==='1') fs.writeFileSync(path.join(folder,'preview-adaptive-visual.flag'),'isolated visual review');
    if (mode==='flibrary-source-preparation') {
      const arg=process.argv.find(a=>a.startsWith('--flibrary-source-fixtures='));
      if(!arg) throw Error('Read-only FLibrary source fixtures are required');
      const source=fs.realpathSync(arg.slice('--flibrary-source-fixtures='.length));
      if(!fs.existsSync(path.join(source,'557950.fb2'))) throw Error('Missing exact source fixture');
      fs.cpSync(source,path.join(folder,'flibrary-source-fixtures'),{recursive:true});
      fs.cpSync(path.join(runtime,'tools/jpeg-xl'),path.join(folder,'tools/jpeg-xl'),{recursive:true});
    }
    if (['reader-small-fb2','reader-main-filter'].includes(mode)) {
      fs.copyFileSync(executable,path.join(folder,'HomeLibReader.exe'));
      for (const [source,name] of [
        [path.resolve(__dirname,'../../../LICENSE'),'HomeLibReader-LICENSE.txt'],
        [path.join(runtime,'HomeLibRuUpdater.exe'),'HomeLibRuUpdater.exe'],
        [path.join(runtime,'NOTICE'),'NOTICE']]) fs.copyFileSync(source,path.join(folder,name));
    }
    if(mode==='catalogue-performance' && !process.argv.includes('--catalogue-ui')) {
      const argument=process.argv.find(a=>a.startsWith('--performance-catalogue='));
      if(!argument)throw Error('An explicit catalogue path is required');
      const source=fs.realpathSync(argument.slice('--performance-catalogue='.length));
      if(path.extname(source).toLowerCase()!=='.hlc2'||!fs.statSync(source).isFile())throw Error('Expected a catalogue file');
      requireNoCatalogueJournal(source);
      const before=fs.statSync(source);
      console.log('Preparing an isolated catalogue copy; source bytes are read only.');
      const hash=hashLargeFile(source), copy=path.join(folder,'performance-copy.hlc2');
      fs.copyFileSync(source,copy,fs.constants.COPYFILE_EXCL);
      const after=fs.statSync(source);
      requireNoCatalogueJournal(source);
      if(before.size!==after.size||before.mtimeMs!==after.mtimeMs||hashLargeFile(copy)!==hash)throw Error('Catalogue changed during snapshot');
      performanceSnapshot={source,size:after.size,mtime:after.mtimeMs,hash};
      console.log('Catalogue copy verified SHA256='+hash+' bytes='+after.size);
    }
    if (mode === 'diagnostics-cache-age') {
      // The independent BookProcessing/ImageProcessing packages are staged below; no legacy converter bundle.
      cp.execFileSync(path.join(runtime,'tools/kindle/python/python.exe'),['-I','-B','-c',
        'import sys,pathlib,zipfile;sys.path.insert(0,sys.argv[1]);from test_image_input import tiff;from test_image_quality import ImageQuality;root=pathlib.Path(sys.argv[2]);ImageQuality.setUpClass();root.joinpath("quality-scan.png").write_bytes(ImageQuality.picture);root.joinpath("native-pages.tiff").write_bytes(tiff());z=zipfile.ZipFile(root/"native-pages.cbz","w");z.writestr("2.tif",tiff());z.close()',
        path.resolve(__dirname,'../../bookconvert/tests'),folder],{stdio:'pipe',windowsHide:true,timeout:15000});
    }
    if (mode === 'paged-export-progress') {
      for(const name of ['pdfium','kindle','bookconvert']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true,filter:item=>!item.split(path.sep).includes('__pycache__')&&!/\.pyc$/i.test(item)});
      const generator=path.resolve(__dirname,'../../bookconvert/tests');
      cp.execFileSync(path.join(runtime,'tools/kindle/python/python.exe'),['-I','-B','-c', 'import sys,pathlib;sys.path.insert(0,sys.argv[1]);from test_legacy_fixed import pdf_fixture;pathlib.Path(sys.argv[2]).write_bytes(pdf_fixture(pages=12))',generator,path.join(folder,'paged-export.pdf')],{stdio:'pipe',windowsHide:true});
    }
    if (mode === 'catalogue-formats' || mode === 'ibk-components') {
      const inventory=process.argv.find(a=>a.startsWith('--catalogue-inventory='));
      const python=process.argv.find(a=>a.startsWith('--catalogue-python='));
      if(!inventory||!python)throw Error('Catalogue audit requires explicit inventory JSON and Python runtime');
      for(const name of ['webp','jpeg-xl','pdfium','djvu','7zip','kindle','bookconvert','xps']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true,filter:item=>!item.split(path.sep).includes('__pycache__')&&!/\.pyc$/i.test(item)});
      const select=process.argv.find(a=>a.startsWith('--catalogue-select='));
      cp.execFileSync(python.slice('--catalogue-python='.length),[path.resolve(__dirname,'../../diagnostics/prepare_catalogue_examples.py'),inventory.slice('--catalogue-inventory='.length),folder,...(select?[select.slice('--catalogue-select='.length)]:[])],{stdio:'pipe',windowsHide:true});
      if(mode==='ibk-components') {
        // Give the isolated install target an owned application identity,
        // as the existing reader-session fixture does. It is never launched.
        fs.copyFileSync(executable,path.join(folder,'HomeLibRu.exe'));
        const input=process.argv.find(a=>a.startsWith('--ibk-packages='));
        if(!input)throw Error('IBK test requires original verified component archives');
        const source=fs.realpathSync(input.slice('--ibk-packages='.length));
        fs.mkdirSync(path.join(folder,'ibk-packages'));
        for(const name of ['original.zip','innoextract.zip'])fs.copyFileSync(path.join(source,name),path.join(folder,'ibk-packages',name));
      } else {
        const installed=process.argv.find(a=>a.startsWith('--ibk-runtime='));
        if(installed)fs.cpSync(fs.realpathSync(installed.slice('--ibk-runtime='.length)),path.join(folder,'tools/ibk'),{recursive:true});
      }
    }
    if (mode === 'image-components') {
      const official=process.argv.find(a=>a.startsWith('--official-jxl-zip='));
      if(!official)throw Error('Image-component audit requires the actual verified author JPEG XL ZIP');
      const source=official.slice('--official-jxl-zip='.length);
      const sha=require('node:crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex');
      if(sha!==(architecture===0x8664?'3025d7e308390796d20492322e606bc92decaee7b6bc99d3f7547870ae5db7de':'a675587f4fa4f907081ad2abb59d3e2890cac20c91350c27a9b4518f8952941c'))throw Error('JPEG XL author fixture digest mismatch');
      fs.copyFileSync(source,path.join(folder,'official-jxl.zip'));
      for(const name of ['webp','jpeg-xl','7zip']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
      fs.copyFileSync(path.join(__dirname,'fixtures/transparent-ink.jxl'),path.join(folder,'transparent-ink.jxl'));
      const platform=architecture===0x8664?'Win64':'Win32';
      fs.copyFileSync(path.join(__dirname,'../../../Installer/Out/optional-codecs-20261022','WebP-1.6.0-'+platform+'.zip'),path.join(folder,'WebP-1.6.0-'+platform+'.zip'));
    }
    if (mode==='save-module-restart') {
      const old=process.argv.find(a=>a.startsWith('--save-old-converter='));
      if(!old) throw Error('save-module-restart requires --save-old-converter=verified-old-archive');
      const python=process.env.HLRU_PYTHON; if(!python) throw Error('HLRU_PYTHON is required to prepare the private candidate');
      const prep=cp.spawnSync(python,['-B','-X','utf8',path.join(__dirname,'prepare_save_module_fixture.py'),runtime,folder,path.resolve(old.slice('--save-old-converter='.length))],{encoding:'utf8',windowsHide:true,env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'},timeout:120000});
      if(prep.status!==0) throw Error('Save module fixture preparation failed: '+prep.stdout+prep.stderr);
      fs.copyFileSync(path.join(runtime,'HomeLibRuUpdater.exe'),path.join(folder,'HomeLibRuUpdater.exe'));
    }
    if (mode==='reader-story') for(const name of ['kindle','bookconvert','xps']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true,filter:item=>!item.split(path.sep).includes('__pycache__')&&!/\.pyc$/i.test(item)});
    if (['unified-send','save-planning','builtin-export','export-cache-lifecycle','diagnostics-cache-age'].includes(mode)) {
      const packages=process.env.HOMELIB_FORMAT_COMPONENT_PACKAGES;
      if(!packages || !process.env.HLRU_PYTHON) throw Error('Save checks require the actual independent format packages and HLRU_PYTHON');
      const staged=cp.spawnSync(process.env.HLRU_PYTHON,['-B','-X','utf8',path.join(__dirname,'prepare_format_runtime_fixture.py'),packages,folder,architecture===0x8664?'Win64':'Win32','BookProcessing','ImageProcessing',...(mode==='diagnostics-cache-age'?['XPS']:[])],{encoding:'utf8',windowsHide:true,timeout:120000,env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
      if(staged.status!==0) throw Error('Independent format fixture failed: '+staged.stdout+staged.stderr);
    }
    if (['save-planning'].includes(mode)) {
      for (const name of ['pdfium','djvu']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
      const made=cp.spawnSync(process.env.HLRU_PYTHON||'python',[path.join(__dirname,'prepare_save_mixed_fixtures.py'),folder,runtime],{windowsHide:true,encoding:'utf8',timeout:45000,env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
      if(made.status!==0) throw new Error('Cannot prepare real mixed Save As documents: '+made.stdout+made.stderr);
    }
    if (mode === 'feedback529' || mode === 'flibrary-quality') {
      fs.mkdirSync(path.join(folder,'tools/jpeg-xl'),{recursive:true});
      fs.copyFileSync(path.join(runtime,'tools/jpeg-xl/djxl.exe'),path.join(folder,'tools/jpeg-xl/djxl.exe'));
      fs.copyFileSync(path.join(runtime,'tools/7zip/7za.exe'),path.join(folder,'tools/7zip/7za.exe'));
      fs.copyFileSync(path.join(__dirname,'fixtures/transparent-ink.jxl'),path.join(folder,'transparent-ink.jxl'));
      if(mode==='flibrary-quality') for(const name of ['kindle','bookconvert','xps']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true,filter:item=>!item.split(path.sep).includes('__pycache__')&&!/\.pyc$/i.test(item)});
    }
    if (/update/.test(mode) || mode === 'optional-components' || mode === 'minimal-first-install' || mode === 'post530') {
      // Complete distribution-only component inventory; no reader profiles.
      for (const name of ['7zip','djvu']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
      for (const name of ['AlReader','SumatraPDF']) {
        const src=path.join(runtime,'Readers',name),dst=path.join(folder,'Readers',name);fs.mkdirSync(dst,{recursive:true});
        for(const entry of fs.readdirSync(src,{withFileTypes:true})) if(entry.isFile() && /\.(exe|dll|txt)$/i.test(entry.name)) fs.copyFileSync(path.join(src,entry.name),path.join(dst,entry.name));
      }
      fs.copyFileSync(path.join(runtime,'HomeLibRuUpdater.exe'),path.join(folder,'HomeLibRuUpdater.exe'));
    }
    if (['program-update-ui','update-form-notifier','post530'].includes(mode)) {
      // These scenarios explicitly exercise the full installed classic inventory.
      for (const name of ['webp','jpeg-xl']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
    }
    if (mode==='post530') fs.cpSync(post530Fixtures,path.join(folder,'post530-fixtures'),{recursive:true});
    if (mode==='optional-components') {
      const arg=process.argv.find(a=>a.startsWith('--optional-fixtures='));
      if (!arg) throw new Error('optional-components requires verified local packages via --optional-fixtures=dir');
      const src=path.resolve(arg.slice('--optional-fixtures='.length)),dst=path.join(folder,'optional-packages');fs.mkdirSync(dst);
      const minimal=process.argv.find(a=>a.startsWith('--minimal-fixture=')); if (minimal) fs.copyFileSync(path.resolve(minimal.slice('--minimal-fixture='.length)),path.join(dst,'minimal.zip'));
      for (const name of ['HomeLibRu.components.json',...['AlReader','SumatraPDF','DjVuLibre','DocSharp'].map(id=>'HomeLibRu-'+id+'-'+(architecture===0x8664?'Win64':'Win32')+'.zip')]) fs.copyFileSync(path.join(src,name),path.join(dst,name));
    }
    if (mode==='update-repair' || mode==='minimal-first-install') {
      // Repair starts with the complete installed inventory, including new optional codecs.
      if (mode==='update-repair') for (const name of ['jpeg-xl','webp']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
      const arg=process.argv.find(a=>a.startsWith('--repair-fixtures='));
      if(!arg) throw new Error('update-repair requires owned archive fixtures via --repair-fixtures=dir');
      const src=path.resolve(arg.slice('--repair-fixtures='.length)),dst=path.join(folder,'repair-fixtures');
      const index=JSON.parse(fs.readFileSync(path.join(src,'fixtures.json'),'utf8'));
      if(index.platform!==(architecture===0x8664?'Win64':'Win32')) throw new Error('Repair archive fixtures have a different architecture');
      fs.mkdirSync(dst);fs.copyFileSync(path.join(src,'fixtures.json'),path.join(dst,'fixtures.json'));
      const crypto=require('node:crypto');
      const names=['application.zip','sevenzip.zip','doc.nupkg','common.nupkg','ppt.nupkg','xls.nupkg'];
      if(mode==='minimal-first-install') names.push(index.DocSharp_adapter,index.DjVuLibre_adapter,'djvu.zip','djvu-source.tar.gz');
      for(const name of names) {
        if(typeof name!=='string'||path.basename(name)!==name) throw Error('Invalid repair fixture member');
        const bytes=fs.readFileSync(path.join(src,name));
        if(crypto.createHash('sha256').update(bytes).digest('hex')!==index.files[name]) throw new Error('Changed repair fixture: '+name);
        fs.writeFileSync(path.join(dst,name),bytes);
      }
    }

    if (mode === 'feedback22') {
      const target = path.join(folder, 'favorite-real');
      fs.mkdirSync(target);
      fs.symlinkSync(target, path.join(folder, 'favorite-alias'), 'junction');
    }
    if (mode === 'metadata-archive-codecs' || (mode === 'conversion-menu' && subcase !== 'layout') || mode === 'feedback21' || mode === 'reader-pipeline-cache') {
      const arg = process.argv.find(a => a.startsWith('--metadata-archive-fixtures='));
      if (!arg) throw new Error('Metadata codec fixtures are required');
      fs.cpSync(arg.slice('--metadata-archive-fixtures='.length),path.join(folder,'metadata-archive-fixtures'),{recursive:true});
    }

    if (mode === 'reader-spread') {
      fs.cpSync(path.join(runtime,'tools/pdfium'),path.join(folder,'tools/pdfium'),{recursive:true});
      const objects=['<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R 9 0 R 11 0 R] /Count 5 >>'];
      for(let i=0;i<5;i++) {
        const content=`BT /F1 24 Tf 50 680 Td (Spread page ${i+1}) Tj ET\n0.8 0.9 0.8 rg 50 400 280 180 re f\n`;
        objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${i%2?620:500} 750] /Resources << /Font << /F1 13 0 R >> >> /Contents ${4+2*i} 0 R >>`,
          `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream`);
      }
      objects.push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
      let pdf='%PDF-1.4\n', offsets=[0];
      objects.forEach((obj,i)=>{offsets.push(Buffer.byteLength(pdf));pdf+=`${i+1} 0 obj\n${obj}\nendobj\n`;});
      const xref=Buffer.byteLength(pdf);
      pdf+=`xref\n0 ${objects.length+1}\n0000000000 65535 f \n`+offsets.slice(1).map(n=>String(n).padStart(10,'0')+' 00000 n \n').join('')+
        `trailer\n<< /Size ${objects.length+1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
      fs.writeFileSync(path.join(folder,'reader-spread.pdf'),pdf);
      fs.cpSync(path.join(runtime,'tools/djvu'),path.join(folder,'tools/djvu'),{recursive:true,filter:p=>!p.includes('HomeLibDjvu-source')&&!p.endsWith('.tar.gz')});
      const script=`import sys,zlib,struct,zipfile,tarfile
from PIL import Image
def chunk(k,d): return struct.pack('>I',len(d))+k+d+struct.pack('>I',zlib.crc32(k+d)&0xffffffff)
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_STORED) as archive:
 for i in range(5):
  row=b'\\x00'+bytes([(i*43+70)%240,(i*61+90)%240,(i*29+110)%240])*4000
  raw=row*4000
  data=b'\\x89PNG\\r\\n\\x1a\\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',4000,4000,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
  archive.writestr(str(i+1)+'.png',data)
frames=[Image.new('RGB',(1200+i*40,1600),(70+i*30,120,160)) for i in range(5)]
frames[0].save(sys.argv[2]+'/reader-spread.tiff',save_all=True,append_images=frames[1:],compression='tiff_adobe_deflate')
frames[0].save(sys.argv[2]+'/reader-spread.png')
with tarfile.open(sys.argv[3]) as t:
 with open(sys.argv[2]+'/reader-spread.djvu','wb') as output: output.write(t.extractfile('djvulibre-3.5.29/doc/djvulibre-book-en.djvu').read())
paragraph='A numbered paragraph for continuous reading with saved positions, selections and bookmarks. '*4
text='\\n'.join(str(i)+'. '+paragraph for i in range(180))
with open(sys.argv[2]+'/reader-spread.txt','w',encoding='utf-8') as f: f.write(text)
with open(sys.argv[2]+'/reader-spread.rtf','w') as f: f.write('{\\\\rtf1\\\\ansi '+text.replace('\\n','\\\\par ')+ '}')
with zipfile.ZipFile(sys.argv[2]+'/reader-spread.epub','w') as z:
 z.writestr('mimetype','application/epub+zip')
 z.writestr('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
 z.writestr('book.opf','<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">spread</dc:identifier><dc:title>Spread</dc:title><dc:language>en</dc:language></metadata><manifest><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="body"/></spine></package>')
 z.writestr('body.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Spread</title></head><body>'+''.join('<p>'+str(i)+'. '+paragraph+'</p>' for i in range(180))+'</body></html>')
`.replace(/^\+/gm,'');
      const made=cp.spawnSync(process.env.HLRU_PYTHON||'python',['-c',script,path.join(folder,'reader-spread.cbz'),folder,path.join(runtime,'tools/djvu/djvulibre-3.5.29.tar.gz')],{windowsHide:true,encoding:'utf8'});
      if(made.status!==0)throw new Error(made.stdout+made.stderr);

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
    if (mode === 'builtin-export' || (mode === 'conversion-menu' && subcase !== 'layout')) {
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
      if (mode !== 'builtin-export') fs.cpSync(path.join(runtime,'tools/bookconvert'),path.join(folder,'tools/bookconvert'),{recursive:true});
      for (const name of ['pdfium','djvu','7zip']) fs.cpSync(path.join(runtime,'tools',name),path.join(folder,'tools',name),{recursive:true});
    }
    if (mode === 'conversion-menu' && subcase !== 'layout') {
      const fixtures=cp.spawnSync(process.env.HLRU_PYTHON||'python',[path.join(__dirname,'prepare_converter_menu_fixtures.py'),folder,runtime],{encoding:'utf8',windowsHide:true,timeout:45000});
      if(fixtures.status!==0) throw new Error('Cannot prepare converter menu fixtures: '+fixtures.stdout+fixtures.stderr);
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
    if (mode === 'feedback529') {
      const target = path.join(folder, 'backup-cleanup-link-target');
      for (const part of ['', 'nested-backup']) {
        const root = path.join(target, part); fs.mkdirSync(root, {recursive:true});
        fs.writeFileSync(path.join(root, 'restore-paths.txt'), 'isolated linked backup');
        fs.writeFileSync(path.join(root, 'destination.hlc2'), 'live target sentinel');
        fs.writeFileSync(path.join(root, 'system.hlc2'), 'personal target sentinel');
      }
      fs.symlinkSync(target, path.join(folder, 'backup-cleanup-linked'), 'junction');
      const fileLink = path.join(folder, 'backup-cleanup-file-link'); fs.mkdirSync(fileLink);
      fs.writeFileSync(path.join(fileLink, 'restore-paths.txt'), 'isolated reparse file');
      fs.symlinkSync(target, path.join(fileLink, 'destination.hlc2'), 'junction');
    }
    if (mode === "read-folder-cleanup") {
      const reading = path.join(folder, "junction-reading"), target = path.join(folder, "junction-target");
      fs.mkdirSync(reading); fs.mkdirSync(target);
      fs.writeFileSync(path.join(reading, "ordinary.tmp"), "isolated root cleanup probe");
      fs.writeFileSync(path.join(target, "keep.fb2"), "junction target must survive");
      fs.symlinkSync(target, path.join(reading, "webp-png"), "junction");
    }
    const exe = path.join(folder, path.basename(executable));
    const result = cp.spawnSync(exe, mode ? [mode,...(subcase ? [subcase] : []),...(mode === "audit-new" ? [auditCaseArg ? auditCaseArg.slice(13) : "filters", ...(amberArchiveArg ? [fs.realpathSync(amberArchiveArg.slice(16))] : [])] : []),...(toolProbe ? ["probe"] : []),...((visualCache || visualUI || visualUpdate || visualRecords) ? ["visual"] : []),...(mode === "feedback14" && amberArchiveArg ? [fs.realpathSync(amberArchiveArg.slice("--amber-archive=".length))] : [])] : [], { cwd: folder, env: {...process.env, LOCALAPPDATA: path.join(folder, "LocalAppData")}, encoding: "utf8", timeout: visualEstimates || (mode==='book-preview-adaptive' && process.env.HOMELIB_TEST_PREVIEW_VISUAL==='1') ? 900000 : mode==='save-module-restart' || mode==='unified-send' || mode==='save-planning' ? 900000 : mode==='catalogue-performance' || mode==='first-book-list-large' || mode==='image-quality-dialog' ? 900000 : mode==='catalogue-formats' ? 3600000 : mode==='conversion-menu' ? 300000 : !!process.env.HLRU_FEEDBACK529_VISUAL && mode === "feedback529" ? 300000 : mode === "post525-update" ? (visualUI ? 900000 : 180000) : mode === "filter-captions" && ["annotation-light", "annotation-dark"].includes(subcase) ? 240000 : mode === "large-inpx" ? 900000 : ["reader-spread", "view-sessions", "builtin-reader", "reader-resource-idle", "update-repair", "compact-book-views", "book-preview-layout", "metadata-book-columns", "reader-notes-proposals", "update-keyboard-accessibility", "main-toolbar-states", "favorite-ui"].includes(mode) ? 180000 : mode === 'native-folder-picker' || mode === 'cancel-interactive' || mode === 'export-cancel-interactive' || mode === 'legacy-import-interactive' || proposalVisualModes.includes(mode) || visualUI || visualUpdate || visualRecords ? 900000 : visualCache ? 180000 : 90000, windowsHide: !process.env.HLRU_FEEDBACK529_VISUAL && mode !== 'update-keyboard-accessibility' && !mode.startsWith("first-run") && mode !== 'cancel-interactive' && mode !== 'export-cancel-interactive' && mode !== 'legacy-import-interactive' && !proposalVisualModes.includes(mode) && !visualCache && !visualUI && !visualRecords && !visualEstimates, maxBuffer: 2 * 1024 * 1024 });
    const output = (result.stdout || "") + (result.stderr || "");
    if (mode === "favorite-ui") {
      const screenshot = path.join(folder, "all-favorite-authors.png");
      if (fs.existsSync(screenshot)) fs.copyFileSync(screenshot,
        path.join(path.dirname(executable), "all-favorite-authors.png"));
    }
    process.stdout.write(`${path.basename(exe)}${mode ? ` (${mode})` : ""}:\n${output}`);
    if (result.error) throw result.error;
    if (result.status !== 0 || !/^PASS\b/m.test(output) || /^FAIL\b/m.test(output)) throw new Error(`Native test failed: ${path.basename(exe)} ${mode || "default"}, exit ${result.status}`);
    if (mode === 'optional-mcp') {
      const hash = filename => require('node:crypto').createHash('sha256').update(fs.readFileSync(filename)).digest('hex');
      const protectedFiles = [];
      function collect(dir) {
        for (const entry of fs.readdirSync(dir, {withFileTypes:true})) {
          const file = path.join(dir, entry.name);
          if (entry.isDirectory()) collect(file);
          else if (/\.(ini|dbs|dbs2|hlc2|fb2)$/i.test(entry.name)) protectedFiles.push(file);
        }
      }
      collect(folder);
      const before = protectedFiles.map(hash);
      // Portable catalogue distributions no longer need this marker. The
      // optional server must resolve the same profile without one as well.
      fs.renameSync(path.join(folder,'uselocaldata'),path.join(folder,'mcp-portable-marker-stored'));
      try {
      const messages = [
        {jsonrpc:'2.0', id:1, method:'initialize', params:{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'HomeLibRu optional module check',version:'1'}}},
        {jsonrpc:'2.0', method:'notifications/initialized'},
        {jsonrpc:'2.0', id:2, method:'tools/list'},
        {jsonrpc:'2.0', id:3, method:'tools/call', params:{name:'list_collections',arguments:{}}}
      ];
      const server = cp.spawnSync(path.join(folder,'MHLMcpServer.exe'), [], {
        cwd:folder, windowsHide:true, timeout:20000, encoding:'utf8',
        env:{...process.env,LOCALAPPDATA:path.join(folder,'LocalAppData'),APPDATA:path.join(folder,'Roaming')},
        input:messages.map(message=>JSON.stringify(message)).join('\n')+'\n', maxBuffer:1024*1024
      });
      if (server.error) throw server.error;
      if (server.status!==0) throw Error('Installed MCP server failed: '+server.stdout+server.stderr);
      const replies=server.stdout.trim().split(/\r?\n/).map(line=>JSON.parse(line));
      if (replies.length!==3 || replies.some(reply=>reply.error)) throw Error('MCP protocol returned invalid replies');
      const tools=replies.find(reply=>reply.id===2)?.result?.tools;
      if (!Array.isArray(tools) || !tools.some(tool=>tool.name==='search_books')) throw Error('MCP catalogue tools missing');
      const result=replies.find(reply=>reply.id===3)?.result;
      if (result?.isError) throw Error('MCP collection query failed: '+JSON.stringify(result));
      const collections=JSON.parse(result.content[0].text).collections;
      if (!Array.isArray(collections) || collections.length<2) throw Error('MCP did not read native fixture collections');
      if (JSON.stringify(before)!==JSON.stringify(protectedFiles.map(hash))) throw Error('MCP changed catalogue, profile or book data');
      console.log('PASS installed optional MCP stdio initialize tools and actual collection query preserve private files');
      } finally {
        fs.renameSync(path.join(folder,'mcp-portable-marker-stored'),path.join(folder,'uselocaldata'));
      }
    }
    if (mode==='ibk-components' || (mode==='catalogue-formats' && process.argv.includes('--catalogue-expect-success'))) {
      const rows=JSON.parse(fs.readFileSync(path.join(folder,'catalogue-format-results.json'),'utf8').replace(/^\uFEFF/,''));
      if(!rows.length || rows.some(r=>r.read!=='ok'||r['.fb2']!=='ok'||r['.epub']!=='ok')) throw Error('A selected supported catalogue book failed reading or conversion; inspect its per-book report');
    }
    const expectedPasses = mode === 'conversion-menu' && subcase === 'layout'
      ? ['PASS conversion menu accepts legacy and unknown suffixes', 'PASS conversion menu offers new text containers', 'PASS conversion menu layout retains sync copying']
      : mode === "filter-captions" && subcase
      ? filterCaptionPasses(subcase)
      : mode === "group-book-identity" && subcase
      ? [subcase.startsWith("manager-") ? "PASS queued download manager " + subcase.slice(8) : subcase.startsWith("download-") ? "PASS saved download identity " + subcase.slice(9) : "PASS Main saved group identity " + subcase]
      : requiredPasses(executable, mode);
    for (const expected of expectedPasses) {
      if (!output.includes(expected)) throw new Error(`Native test did not run required scenario (${expected}); reload and rebuild its DPR from disk.`);
    }
    if (mode === "program-update-ui" && subcase.startsWith("layout-") &&
        !output.includes("TRACE changes DPI=" + subcase.slice(7) + " "))
      throw new Error("The requested native update DPI was not inspected: " + subcase);
    if(performanceSnapshot) {
      requireNoCatalogueJournal(performanceSnapshot.source);
      const current=fs.statSync(performanceSnapshot.source);
      if(current.size!==performanceSnapshot.size||current.mtimeMs!==performanceSnapshot.mtime||hashLargeFile(performanceSnapshot.source)!==performanceSnapshot.hash)
        throw Error('Original catalogue changed during performance run');
      console.log('PASS original catalogue source SHA256 preserved');
    }
    for (const [source,hash] of readonlyInputs) {
      if (require('crypto').createHash('sha256').update(fs.readFileSync(source)).digest('hex')!==hash) throw new Error('Readonly reader input was changed: '+source);
    }
  } finally {
    if(mode==='save-module-restart') {
      const report=path.join(folder,'save-module-result.txt');
      if(fs.existsSync(report)) fs.copyFileSync(report,path.join(__dirname,'Out','pre535-'+(architecture===0x8664?'Win64':'Win32')+'-save-module-result.txt'));
      const debug={root:folder,files:{}};
      const collect=(dir)=>{for(const item of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,item.name);if(item.isDirectory()&&!['tools','Icons','save-module-fixture'].includes(item.name))collect(file);else if(item.isFile()&&/^(save-module-.*\.txt|request\.json|journal\.json|result\.txt|.*pending-save.*)$/.test(item.name)&&fs.statSync(file).size<65536)debug.files[path.relative(folder,file)]=fs.readFileSync(file,'utf8');}};
      collect(folder);fs.writeFileSync(path.join(__dirname,'Out','pre535-'+(architecture===0x8664?'Win64':'Win32')+'-save-module-debug.json'),JSON.stringify(debug,null,2));
    }
    if(mode==='catalogue-performance') {
      for(const name of ['actual-startup-profile.tsv','actual-book-list-profile.tsv']) {
        const file=path.join(folder,name);
        if(fs.existsSync(file))fs.copyFileSync(file,path.join(__dirname,'Out',(process.argv.includes('--catalogue-ui')?'pre534-ui-':'pre534-')+(architecture===0x8664?'Win64':'Win32')+'-'+name));
      }
    }
    if(mode==='first-book-list' || mode==='first-book-list-large' || mode.startsWith('startup-deferred')) {
      for(const name of fs.readdirSync(folder).filter(n=>/^(first-list|startup-).*\.tsv$/.test(n))) {
        fs.copyFileSync(path.join(folder,name),path.join(__dirname,'Out','pre534-'+(architecture===0x8664?'Win64':'Win32')+'-'+name));
      }
    }
    if(mode==='catalogue-formats' || mode==='ibk-components') {
      for(const [source,name] of [['catalogue-format-results.json','results'],['catalogue-examples/examples.json','examples']]) {
        const file=path.join(folder,source);
        if(fs.existsSync(file))fs.copyFileSync(file,path.join(__dirname,'Out','pre532-'+(architecture===0x8664?'Win64':'Win32')+(catalogueLabel?'-'+catalogueLabel:'')+'-'+name+'.json'));
      }
    }
    // Only this process's verified, unique temporary runtime is removed.
    if (keepFixtures) console.log('RETAINED',absolute);
    else if (absolute.startsWith(expectedRoot) && path.basename(absolute).startsWith("HomeLibRu-native-")) fs.rmSync(absolute, { recursive: true, force: true });
  }
}
// Every subcase uses a fresh profile. The complete annotation DPI matrix has
// a 240-second functional guard; the identity subcases retain 90 seconds.
// Native geometry assertions and explicit speed budgets remain unchanged.
// No subcase marker is optional: all fourteen are required by the default suite.
function runView(mode) {
  if (mode==='save-module-restart') {
    for (const application of ['HomeLibReader.exe','HOMELIBREADER.EXE','homelibru.exe','legacy-request']) run(tests[2],mode,application);
    return;
  }
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-ui-legacy')) return run(tests[2],mode,'ui-legacy');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-ui')) return run(tests[2],mode,'ui');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-startup-late')) return run(tests[2],mode,'startup-late');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-startup')) return run(tests[2],mode,'startup');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-sample')) return run(tests[2],mode,'sample');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-record-transfer')) return run(tests[2],mode,'record-transfer');
  if (mode==='catalogue-performance' && process.argv.includes('--catalogue-profile')) return run(tests[2],mode,'profile');
  if (mode === 'conversion-menu' && process.argv.includes('--menu-layout-only')) return run(tests[2],mode,'layout');
  if (mode === "book-preview-layout" && process.argv.includes("--profile-footer")) return run(tests[2],mode,"profile");
  if (mode === 'release23-filters') {
    // Each fresh profile renders 57 states within the normal functional guard.
    // All four subcases must pass; together they cover 228 native layouts.
    for (const subcase of ['populated-light','empty-light','populated-dark','empty-dark']) run(tests[2], mode, subcase);
  } else if (mode === "program-update-ui" && !visualUpdate && !visualUI) {
    // Repeat the entire workflow and cached-history assertions for every DPI.
    // Keep the normal 90-second functional guard on each fresh process.
    for (const subcase of ["layout-96", "layout-144", "layout-192"]) run(tests[2], mode, subcase);
  } else if (mode === "filter-captions") {
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
  const expected = mode === 'review-http' ? ['/b/1/', '/b/2/', '/b/3/', '/b/5/', '/b/4/'] : mode === "online-plain" ? ["/b/900003/get"] : ["/b/900001/get", "/b/900002/get", "/b/900004/get"];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if(mode==='download-scenarios') {
      req.resume();
      const reply=(plain=false,bad=false)=>{
        let payload=fs.readFileSync(path.join(folder,plain?'online-plain-response.fb2':'download-response.zip'));
        if(bad)payload=payload.subarray(0,Math.floor(payload.length/2));
        res.writeHead(200,{'Content-Type':plain?'application/fb2+xml':'application/zip','Content-Length':payload.length});res.end(payload);
      };
      if(req.url==='/archive/redirect.fb2.zip') {reply();return;}
      if(req.url==='/archive/retry.fb2.zip') {reply(false,requests.filter(x=>x==='GET '+req.url).length===1);return;}
      const m=/^\/b\/90100([1-9])\/get$/.exec(req.url);
      if(!m || req.method!==(Number(m[1])===6||Number(m[1])===9?'GET':'POST')) {res.writeHead(404);res.end();return;}
      const id=Number(m[1]);
      if(id===3||id===4) {res.writeHead(302,{Location:id===3?'/archive/redirect.fb2.zip':'/archive/retry.fb2.zip'});res.end();return;}
      if(id===5) {res.writeHead(200,{'Content-Type':'text/html'});res.end('<!doctype html><html>Login required</html>');return;}
      if(id===8) {res.writeHead(405);res.end('Method not allowed');return;}
      reply(id===2||id===9,id===7);return;
    }

    if (req.method !== "GET" || !expected.includes(req.url)) { res.writeHead(404); res.end(); return; }
    if (mode === 'review-http') {
      if (req.url === '/b/2/') { res.writeHead(503); res.end('unavailable'); return; }
      const text = req.url === '/b/3/' ? '<h1>Access denied</h1>' : req.url === '/b/5/' ? '<h2>Отзывы</h2><div id="newann"></div>' : '<h2>Аннотация</h2><p>Русская аннотация</p><form></form><a href="/polka/show/1">Читатель</a><br><p>Очень <strong>хорошая</strong> книга</p><p>Второй абзац.</p><div></div><a href="/polka/show/2">Другой читатель</a><br><p>Отдельный отзыв.</p><div></div><div id="newann"></div>';
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
      const child = cp.spawn(exe, [mode, String(port)], { cwd: folder, env: {...process.env, LOCALAPPDATA: path.join(folder, "LocalAppData")}, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
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
    const expectedRequests=mode==='download-scenarios'?[
      'POST /b/901001/get','POST /b/901002/get','POST /b/901003/get','GET /archive/redirect.fb2.zip',
      'POST /b/901004/get','GET /archive/retry.fb2.zip','GET /archive/retry.fb2.zip',
      'POST /b/901005/get','GET /b/901006/get','GET /b/901006/get','POST /b/901007/get','POST /b/901008/get','GET /b/901009/get'
    ]:expected.map(url=>`GET ${url}`);
    if (JSON.stringify(requests) !== JSON.stringify(expectedRequests)) throw new Error(`Unexpected online requests: ${JSON.stringify(requests)}`);
    console.log(`PASS exact loopback requests for main ${mode}; repeated reads use the downloaded book`);
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    if (absolute.startsWith(expectedRoot) && path.basename(absolute).startsWith("HomeLibRu-native-")) fs.rmSync(absolute, { recursive: true, force: true });
  }
}
(async () => {
try {
  if (process.argv.includes('--download-scenarios-only')) { await runOnline(tests[2],'download-scenarios'); return; }
  if (viewsMode !== null) {
    if (viewsMode==='post530') {
      post530Fixtures=fs.mkdtempSync(path.join(os.tmpdir(),'hlru-531-fixtures-'));
      require('../../test_temp_root.js')(post530Fixtures,'hlru-531-fixtures-');
      const proof=JSON.parse(fs.readFileSync(path.join(__dirname,'../../../docs/audits/2026-10-21-sevenzip-2605.json'),'utf8'));
      const names=[architecture===0x8664?'7z2605-x64.exe':'7z2605.exe','7zr.exe'];
      const assets=[];
      for(const name of names) {
        const a=proof.assets.find(a=>a.name===name),res=await fetch(a.url);
        if(!res.ok)throw Error('Official fixture download '+res.status);
        const b=Buffer.from(await res.arrayBuffer());
        if(b.length!==a.size||require('crypto').createHash('sha256').update(b).digest('hex')!==a.sha256)throw Error('Official fixture digest '+name);
        fs.writeFileSync(path.join(post530Fixtures,name==='7zr.exe'?name:'sevenzip.exe'),b);
        assets.push({name,size:a.size,digest:'sha256:'+a.sha256,browser_download_url:a.url});
      }
      fs.writeFileSync(path.join(post530Fixtures,'sevenzip.json'),JSON.stringify({tag_name:'26.05',draft:false,prerelease:false,assets}));
      fs.copyFileSync(path.join(__dirname,'../../../Installer/Out/optional-alreader-2.5.1009.25/AlReader-2.5.1009.25.zip'),path.join(post530Fixtures,'AlReader-2.5.1009.25.zip'));
    }
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
    for (const mode of modes.filter(m => m !== "large-inpx" && m !== "post530" && m !== "minimal-first-install")) runView(mode);
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

# Reconciled offline component candidates

The earlier offline-input list r563 still selected the published LegacyBooks 5
and old processing helpers. These are not the candidates used by the later
sealed-format checks. The final distribution must use one explicit list rather
than infer current modules from the old staging folder or a developer runtime.

The reconciled candidate plans are:

- G:/HL-b14-external/offline-candidate-ledger-r1677/components-Win32.json
- G:/HL-b14-external/offline-candidate-ledger-r1677/components-Win64.json
- G:/HL-b14-external/offline-candidate-ledger-r1677/report.json

Each architecture has all 25 optional components. The candidate overrides to
r563 are:

| Component | Version | Existing sealed input |
| --- | --- | --- |
| BookProcessing | 3.0.0.14 | transfer-flibrary-modules-r1559 |
| ImageProcessing | 3.0.0.14 | format-modules-r1462/packages |
| XPS | 3.0.0.6 | format-modules-r1462/packages |
| LegacyBooks | 3.0.0.6 | legacy-books-packages-r1413 |
| KfxExport | 3.0.0.6 | kfx-cover-packages-r1504 |
| KindleExport | 3.0.0.9 | format-modules-r1462/packages |
| EpubPdfExport | 3.0.0.9 | format-modules-r1462/packages |

CRC and every manifest member's size/SHA-256 were verified: 1,272 files on
Win32 and 1,273 on Win64, 2,545 altogether. All 139 mapped local producer-source
comparisons per architecture match current source. This includes the nine
collection-packing workers and two catalogue-dump workers, whose installed
paths differ from their repository paths. Image/XPS runtime descriptors bind
the current shared C# source and static-GIF API; XPS also binds OpenXpsNative.cs.

The unchanged inputs retain their recorded package hashes. The ledger records
component identity and architecture, not just a version number. It does not
download modules or substitute unsealed files from the developer's runtime.

## Reconciliation attempts

r1673 correctly detected the obsolete legacy_helper.py in the old r563 list.
The current helper had already been sealed and tested in LegacyBooks 6 r1413;
the sealed writer r1464/r1465 explicitly selected it. Repacking current XPS 6
and LegacyBooks 6 reproduced those existing archives byte for byte on both
architectures. These are identity checks, not four new functional test passes.
The final plans use the existing tested archives. Intermediate r1673/r1675/
r1676 lists are superseded by r1677, which also verifies the mapped workers.
The three owned duplicate-package/workspace directories were then removed;
duplicate-candidate-cleanup-r1685.json retains the equality checks and original
archive hashes. The retained candidate plans reference none of those removed
directories.

Existing evidence remains separate: sealed-writer-validation-r1467,
sealed-all-formats-validation-r1469, kfx-cover-package-validation-r1505 and
transfer-flibrary-update-validation-r1565. The old r691 BookProcessing archive
must not replace r1559; the r691 image helper predates the static-GIF API.

## Beta 14 Reader and combined staging

The historical r1677 plans retained Reader 3.0.0.13. The r1917 plans replace
it with the verified 3.0.0.14 component for each architecture. The production
packaging stage applied all 25 inputs from each plan with the existing native
installer probe. A second inventory check confirmed every intended version and
no module needing repair. The staged `HomeLibreReader.exe` matches the byte
digest of the separately checked beta 14 Reader and uses the canonical version
resource. The native staging receipt is
`G:/HL-b14-external/release-candidate-r1926-offline-components/summary.json`.

Separately, the stock main and Reader archives were matched to the published
asset sizes and digests. On x86 and x64 the native installer first installed the
published Reader 3.0.0.13, then applied the exact 3.0.0.14 component. Both the
canonical filename and the retained legacy launch path contained the same new
Reader. The existing catalogue executable and seeded Reader settings retained
their original digests. Private installations were cleaned. Results are in
`G:/HL-b14-external/release-candidate-r1930-stock-reader-upgrade/{Win32,Win64}.json`.
This used the native installer engine directly on stock files with neither a
restart nor the published graphical update client.

## Current BookProcessing package

The estimate fix in `ae9c17fd` ships in the two BookProcessing 3.0.0.14 ZIPs
in `G:/HL-b14-external/release-candidate-r1937-bookprocessing`. The earlier
r1559 packages were unpublished. The new archives differ from those inputs
only in the estimator, its descriptor checksum and the package manifest.
The 12-test estimator suite passed with the staged tools on each architecture.
The estimator extracted from each new ZIP also ran successfully with its own
embedded Python in a separate standalone DjVu test.

The r1937 `components-{Win32,Win64}.json` plans supersede r1917. Each changes
only the BookProcessing archive and digest. The native installer restaged
all 25 packages with each new plan and confirmed the exact matching estimator
digest, Reader digest and installed component versions. Both private staging
trees were removed. See
`G:/HL-b14-external/release-candidate-r1938-offline-components/summary.json`.

The r1939 selected publication plan was regenerated from the verified public
baseline and the new archives. The output feed is byte-identical to r1922;
the two BookProcessing ZIPs are the only uploads with new hashes. The matching
KFX source and 30 unrelated feed records are unchanged. No upload or removal
was performed. See
`G:/HL-b14-external/release-candidate-r1939-component-plan/verified-delta.json`.

## Production binaries and candidate distributions

The r1941 compatibility launcher and the r1942 catalogue builds passed on
x86 and x64 with actual 3.0.0.14 Windows resources. The exact launchers
passed the r1952 native argument and working-directory tests in both archive
layouts. The packaged Reader and updater retain their checked r1915 builds.
The overlapping tracked release source matches the local b98f43ab snapshot.

`G:/HL-b14-external/r1950-distribution-verification/distribution-report.json`
records independent preparation, installed-file verification and inventory
checks for all six r1946/r1947 archives. The four minimal/bridge archives
contain 241 managed files each. The full x86/x64 archives contain 1,625/1,626
managed files, including 25 components each, fonts and all three pinned
Microsoft installers. Test settings and other private files survived; the
private workspaces were removed. The Microsoft installers were verified for
availability and identity but not executed.

The r1948 native installer test applied the verified production bridge
archives over copies of the original published beta 13 archives on x86 and
x64. All 241 managed files matched, the exact compatibility launcher was
retained, and the settings and private SQLite test database hashes were
unchanged. The old update window, restart and Windows shortcut are outside
this test. The r1949 frontend test has verified inputs on both architectures.

## Still open

The ordinary beta 13 to beta 14 update with restart, clean-Windows prerequisite
installation, offline GUI operation, and the remaining install/remove/update
and licensing/source checks are release gates. Desktop replacement and
publication remain open.

All preparation is on G:. No E: input or user-library modification is involved.

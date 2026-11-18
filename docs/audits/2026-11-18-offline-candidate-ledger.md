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
this test. The r1949 frontend test passed on x86 and x64 using the regular
update window of the original published
beta 13. The old process wrote its own installation request, exited normally,
and the exact packaged helper restarted `HomeLibre.exe`. An unchanged Windows
shortcut targeting `HomeLibRu.exe` opened the renamed catalogue. All 241
managed files, the seven fixture books, the saved geometry and personal
settings were verified after shutdown; private payloads were removed. This
used a prepared package restored from the update cache, not the published
GitHub download route. Reports are in the two
`release-candidate-r1949-frontend-{Win32,Win64}/report.json` files.

The separate stock beta 13 Reader uses its installed helper for component
updates. That helper installed the original beta 14 candidate entirely as
`HomeLibReader.exe`. On restart the corrected Reader now uses the old
helper's receipt to verify the executable and publish `HomeLibreReader.exe`
alongside the existing file. The existing book opens on that first restart
under the old process name. The component inventory owns both paths.

Both stock Readers installed the prepared r1958 packages from their Components
windows. The seven-book catalogue test above is separate. Here each Reader
reopened the same test FB2. Both executable hashes and all package entries
matched, and both private installations were removed. On x64 the stock helper
reported a sharing failure before it changed any files on the first attempt.
The old Reader reopened and its ordinary retry completed. On x86 installation
completed on the first attempt. The two `r1960-stock-reader-gui-*.json`
reports preserve the results. The r1961 publication plan and offline input
lists reference the four new Reader archives.

The native filename regression suite passed 18 case groups per architecture.
The five additional groups cover first startup with the old receipt, resuming
from a partial staging file, a modified legacy binary, an occupied destination
and a missing receipt. The reports are under `r1959-reader-name-native`.

## Module maintenance on the exact release packages

The r1953 run used the new BookProcessing and ImageProcessing ZIPs from the
local publication plan, with the verified distribution's core runtime. The
native removal path removed each module separately and reinstalled it. FB2
to EPUB conversion still worked without ImageProcessing and again after both
modules were restored. It retained the input book, settings, and the catalogue
marker, and restored package ownership records. Both architectures also
passed the existing rollback, lock, changed-file and removal-recovery cases.

The r1954 run installed the published BookProcessing 3.0.0.13 and
ImageProcessing 3.0.0.8, then updated both to the exact 3.0.0.14 candidates
using the stock release SHA-256 records and the native installer. The installed
versions and managed-file digests matched. The catalogue executable, settings,
and private SQLite fixture retained their digests. Both private workspaces
were removed. These are native engine checks; the update window and removal
of the other modules were not covered by these two runs.

The r1956 native downloader obtained both exact compatible catalogue archives
from an owned loopback HTTP server and authenticated the staged catalogue.
A deliberately wrong checksum was rejected without creating a prepared
manifest on either architecture. These are transport and validation checks;
the production server and graphical download command were not used.

Microsoft documents bundling the [WebView2 Evergreen Standalone Installer](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution#offline-deployment)
and the [.NET Framework offline redistributable](https://learn.microsoft.com/en-us/dotnet/framework/deployment/deployment-guide-for-developers#redistributable-packages).
The full packages include the pinned installers, and their availability was
verified; clean-Windows execution remains open. r1955 verified that each of
the 25 modules' notices or licence texts survived unchanged in each full ZIP
(with the documented merged `NOTICE` exception), plus the fonts' OFL texts,
bundled DjVu and legacy Office source, and the two export source links. The
FB2 source link matches the public asset digest; the matching KFX source is
verified locally and must be available when the KFX binaries are published.
The exact AlReader archive
retains the upstream Windows readme, which allows non-commercial use and asks
users to contact the author about preinstallation or commercial use. The
maintainer confirmed the noncommercial distribution and chose to retain the
Windows module with its original terms. The release notes link to the
[author's Windows downloads](https://alreader.com/downloads.php?lang=ru).

## Full archives with the corrected Reader

The r1963 check installed both r1962 full archives with the production installer
and also checked their contents after manual extraction. All 25 packaged modules
reported the expected version in both layouts. Installed files and ownership
records matched the manifest. The seeded catalogue data and application and
AlReader settings survived. Each archive carried the three pinned prerequisite
installers. The check verified their bytes without running them.

| Archive | Managed files | SHA-256 |
| --- | ---: | --- |
| `HomeLibre_full.zip` | 1,625 | `61028e5240af390712d7acf12097a5aa16b5e88620e57a970797eb36000ff8a5` |
| `HomeLibre_x64_full.zip` | 1,626 | `117a60496b16572473b9d9c17c72120f4728a7d0a66d3b2b77035e3d96a450b4` |

All 15 AlReader files in each full ZIP matched the selected Windows component
byte for byte, including `Readers/AlReader/readme.txt`. Its SHA-256 is
`c738703c7ab5f0f2d721a66b4a1266924aed9b94cae23b0274733e2e603d2acf`.
The installation report is `r1963-exact-full-verification/distribution-report.json`.

The r1965 maintenance check started from a manual extraction of each exact
full ZIP. It removed AlReader, kept the modified reader settings and a private
file beside them, then reinstalled AlReader and checked its remaining files
against the component manifest. Next it removed all 25 components in one
operation and reinstalled each from its selected local ZIP. The installer
reported the intended version and a healthy module after each installation.
Catalogue binaries, SQLite, pinned fonts and prerequisite installers kept
their digests. Private data survived and both test directories were removed.
See `r1965-module-maintenance/{Win32,Win64}/result.json`.

The r1964 KindleExport source check matched both packaged builds to their
recorded binary hashes and two shipped patches. Each build lists 218
dependencies and carries 347 notice files. The nine source archives selected
for their MPL terms matched the upstream Cargo.lock checksums. See
`r1964-kindle-export-source/sources.json` and the
[pinned Kindling source](https://github.com/ciscoriordan/kindling/tree/3b91b1ea21f892779be09149f21fe4053b1b3569).

## Superseding full and minimal candidates

The r1972 ZIPs carry the updater which restores the visible catalogue after a
Reader update. Relative to r1962 the full manifests differ in exactly two
payloads, the updater and the embedded release history. Both reader component
archives and their standalone variants retain the same Reader executable.
The new full archive digests are
`5c9873ecd1b6951b6f2850ccf2ebbe2a9b06c20a3cade35c26c91919bf3a6c4b`
(x86) and `e6ae65c06d5930fde3b55988698fb682472598041d886f3d77c16b3f51565c86`
(x64). See `r1970-offline-inputs/verified-delta.json`.

Production preparation, manual extraction, installation over a seeded private
target and module inventory passed for both full and all four minimal archives.
The full runs checked 1,625 and 1,626 files, 25 module versions, all bundled
prerequisites and preservation of settings. The four minimal runs checked
241 files apiece. See `r1973-distribution-verification/distribution-report.json`.

Independent upstream downloads of SumatraPDF 3.6.1, kepubify 4.0.4 and
7-Zip 26.05 match the executables shipped on both architectures. For 7-Zip
the DLL and licence also matched the files inside the official installer, and
the official source archive contains the decoder interface and console entry
point. The exact upstream revisions and digests are in
`r1974-upstream-utilities/report.json`.

For the two exact full ZIPs, independent downloads from the PDFium binaries
project, Zstandard and libjxl matched the packaged PDFium and Zstandard DLLs
and both JPEG XL executables byte for byte. The WebP 1.6.0 source archive
matched the recorded digest, and its AUTHORS, COPYING and PATENTS texts matched
the installed notices after line-ending normalization. For the locally built
WebP DLLs the check used the recorded binary digests. Evidence is in
`r1978-codec-upstreams/report.json`. The four Office reader DLLs in each archive
also matched the .NET Framework 4.6.2 files in the recorded NuGet packages.
Both the local helper source and its packaged executable matched their pinned
digests (`r1978-codec-upstreams/docsharp.json`).

## Component links used by older installations

The Win32 and Win64 archives downloaded from the published beta 2, 8 and 13
releases matched their GitHub asset SHA-256 digests. Their bundled component
lists still refer to versioned downloads. In particular, the two beta 13
archives together refer to all 16 files that the previous draft publication
plan would have removed. The beta 2 and beta 8 archives also point to their
respective Reader packages.

The revised local plan retains those downloads, stages 19 uploads and replaces
the component feed last. The draft component release description links directly
to the new standalone Reader for each architecture and explains the two catalogue
editions. Public assets and release text have not been modified. Evidence:
`r1977-component-reference-audit/proof.json`,
`r1977-component-reference-audit/component-body-after-beta14.md` and
`r1977-component-plan`. Catalogue archive digests are unchanged.

## Offline use on a clean Windows installation

The previous Windows 10 LTSC 2021 x64 evaluation ISO was downloaded again
from Microsoft. Its SHA-256 matched the receipt from 8 November. Two separate
writable copies of a newly installed build 19044 had no network adapter, no
default route and no WebView2. The shipped x86 and x64 full ZIPs matched the
catalogue digests above. All 25 modules were recognized in each. Both WebView2
installers and the .NET Framework installer passed the production checks for
size, digest, version and Microsoft signature without network access.

On both copies the standalone Reader opened an illustrated EPUB. Its Save As
command offered the local WebView2 installer and installed version 157.0.4341.60
from the kit, then produced a PDF. Opening the source FB2 in the catalogue's
Reader and saving it as EPUB also succeeded on both copies. Independent checks
of all four GUI exports found the three text passages in source order. Each
EPUB linked to the exact source illustration, and the illustration was visible
in each rendered PDF. The source FB2 kept its digest, and the catalogues closed
normally. The managed image utility also produced a grayscale PNG in each kit.
Windows already included .NET Framework 4.8 (release 528372), so a fresh
installation of .NET on an older OS was not exercised. Both application
architectures ran on x64 Windows.

The receipts are in `G:/HL-b14-external/r1976-offline-vm/report.json` and
`w32e/verified`, `w64e/verified` under that folder. Both guests shut down.
The reusable OS image and the Microsoft ISO are on G:.

## Embedded Kindle, legacy Office and DjVu sources

Both r1975 full ZIPs include all 22 KindleUnpack library files and its licence
byte-for-byte from the pinned upstream commit. Each also contains all 22 files
listed in the legacy Office manifest, including the three source packages for
libwpd, librevenge and libwps. The DjVu decoder, source tarball, notices and
wrapper executable match the 13 pinned digests. The five accompanying wrapper
source files match the repository immediately before the HomeLibre rebranding
commit `b0c0244a` after normalizing line endings. The wrapper retains its old
internal DjVuLibre context name. The comparison used the source corresponding
to the distributed helper. Evidence: `r1979-embedded-sources/report.json`.

## Selected-book compression in the packaged catalogue

On the host, each packaged catalogue from r1975 also completed selected-book
compression through its Book menu on a private Windows desktop. Each fixture
held seven FB2 files. The chosen book still had its original SHA-256 after the
estimate and while waiting for approval. After approval it shrank from
5,049,830 to 664,447 bytes and the catalogue recorded the new size. The FB2
text and XML structure matched, the illustration had equal RGB channels, and
the other six book files and their catalogue rows matched their initial state.
Both applications closed normally. Only synthetic copies were used.
The reports are in `r1980-selected-production/{Win32,Win64}-report.json`.

## Catalogue rebuild after the transfer diagnostic change

The x86 and x64 catalogues were rebuilt with the transfer destination check.
The six local archives in `G:/HL-b14-external/r1982-main-release` include
these executables and the revised release history. The previous r1975 archive
digests matched their saved list. A comparison of all six pairs found exactly
two changed payloads in each archive, the catalogue executable and
`Help/CHANGES.txt`. The updater manifests record both new digests.
Every member listed by each new manifest was read and checked against its size
and SHA-256, including the catalogue at its compatibility path in the two
update archives. File inventories and component payloads matched the previous
packages. The six new archive digests are in `r1982-main-release/SHA256SUMS.txt`.
The comparison receipt is `r1982-package-work/verification.json`.
The native installer then prepared and installed all six revised ZIPs into
private profiles. The checks verified installed file hashes, preserved personal
files, module ownership and inventory. Both full installations recognized the
25 modules and the bundled Microsoft installers. All six profiles were removed.
The receipt is `r1982-distribution-verification/distribution-report.json`.

## Losing the destination after reviewing a transfer

The packaged x86 and x64 catalogues were run separately inside an offline
Windows 10 x64 guest. Each fixture had seven FB2 files, a neighbouring text
file and a separate 1 GiB NTFS destination. With about 480 MiB free, the
preview identified the folder and its available space, explained the 512 MiB
reserve and disabled transfer. After space was freed, the plan was accepted.
Detaching the virtual disk after review and before pressing Transfer produced
a message naming the unavailable folder and asking the user to reconnect it.
The seven source files, catalogue identities and old locations were unchanged
after both refusals. The previous x64 candidate had shown Windows error 3.

After reattachment, reviewing the plan again and confirming completed the
operation in both applications. All seven new catalogue paths resolved to
the original bytes, all seven old book files were gone and the unrelated text
file remained. The guest shut down normally. The host checked both executable
digests against the shipped ZIPs. Receipts and screenshots are in
`r1981-transfer-volume/volume3/verified`. This exercises disconnection before
copying and the real low-space guard. Loss of the destination during a write
and failure of a network share require separate evidence.

## Recovery when the verified staging file disappears

The existing x86 and x64 copy test executables reproduced a separate failure
in private directories on G:. The test stopped immediately after the copier
verified the staged book and before the rename. The fixture removed that
temporary file. Both executables returned Windows error 2 on resume, with the
source intact. A second case confirmed that a missing file already recorded as
published was reported on both architectures. The baseline logs and journal
records are in `r1984-copy-resume/{Win32,Win64}`.

The recovery branch now permits a new copy attempt when both destination names
are missing in the verified phase and the original streams still match the
journal. The published phase retains its separate missing-file check. The
source change and focused tests await a native rebuild. The six r1982 ZIPs
predate this change. A separate unplug-during-write fixture is prepared under
`r1983-transfer-hotplug`. Only its scripts and inputs were checked in this step.

## BookProcessing sources after the shared-illustration fix

The two r1937 update modules and both r1982 full distributions were compared
with the release checkout after `eba46a33`. Each contains 138 source files
and markers owned by BookProcessing. In all four archives the same two files,
`prepare_book_compression.py` and `external_image_preparation.py`, still have
their previous contents. All 138 archived files matched their own manifests.
Both release routes point to those same module digests. The exact old and new
file hashes are in `r1986-release-module-sources/source-comparison.json`.

The component publication planner now checks the module against the same
source selection used by its writer. Full-distribution staging checks the
release-pinned version and applies the source check to the current release
after native package verification. The regression test accepts the matching
source inventory and rejects each superseded worker even when its manifest
and runtime descriptor agree with one another. It also rejects a stale
descriptor when the manifest already matches the corrected source.

The separate release worktree had the older plan generator which proposed
removing downloads still used by installed clients. Its input matched the
known Git revision before the retention fix. The current planner, two FLibrary
workers, transfer recovery source and associated release inputs were copied
after checking the previous contents. The r1977 plan already retains all 16
downloads.

A second checkout had different Git line endings in 31 otherwise identical
source files. Source comparison accepts LF and CRLF for checked-out text.
It still requires exact bytes for binary data and the generated API marker.
Manifest and installed runtime checksums always refer to the actual ZIP bytes.

Regenerate the BookProcessing update archives from the release checkout,
refresh both offline input lists and the upload plan, and recheck the final
full ZIPs and selected compression. The earlier installation and compatibility
results above identify the tested candidate. They do not cover the new bytes.

## Native packages and shared FLibrary illustrations, 19 November

The r1987 BookProcessing ZIPs contain the corrected workers (172 managed files
on x86 and 173 on x64). The publication plan changes only those two archive
digests relative to r1977 and retains the same older downloads. The native
installer checked all six r1987 distributions. Each full installation contained
25 components. All 26 local transfer-copy tests passed on each architecture,
including the missing verified staging file. The optional cross-volume test
was skipped in these two runs.

A private run of the production catalogue exposed a separate problem with
books in subdirectories of a 7z archive. The app sent `first\one.fb2` while
the compression worker indexed `first/one.fb2`. The operation stopped before
changing the files. The selected-book and whole-collection commands now
preserve the resolved name and case and pass archive paths with `/` separators.

On x86 and x64, the r1988 catalogue ran both commands against the same pair
of synthetic FB2s sharing one external picture. Selecting one book left the
picture archive byte-identical and recorded no completed check for that book.
Selecting the full collection recorded both books and reduced the archive
from 1,040,307 to 262,207 bytes with grayscale enabled. Both FB2 members and
the unrelated illustration retained their contents. The channel comparison
confirmed grayscale in the shared output. Reports and before/after screenshots
are in `r1987-shared-production`, build receipts in `r1988-nested-members`,
and the earlier installer report in `r1987-distribution-verification`.

The six r1988 release ZIPs built with the corrected catalogue subsequently
passed native installation and inventory on both architectures. All 25 pinned
optional components had the expected version and a healthy installation in
each full distribution. On two private Windows desktops, the published beta 13
client accepted the prepared r1988 update, installed it and restarted as
`HomeLibre.exe`. All 241 managed files, seven catalogue entries and the
test's personal settings and sentinel survived on each architecture. This
run started with the exact local ZIP. The earlier r1949 test separately
verified the Windows shortcut. Results are in `r1988-distribution-verification`
and `r1988-nested-members/upgrade-{Win32,Win64}/report.json`.

The INPX source-window tests and the full sequence of updates passed on x86
and x64. Reopening an unchanged index after a partial import continues to
list archives still required. The original seven-minute test deadline expired
while the fixtures were committing successive catalogue updates. The complete
private-desktop runs finished in 583 and 582 seconds respectively. Results
are in `r1987-production-refresh/library-update-*-private-{Win32,Win64}`.

## Network destination and unrelated SQLite work

In a disposable Windows 10 guest, the r1988 release executable transferred a
book through an authenticated Windows SMB share. Source and working folders
were local to the guest. The destination used a UNC path through its single
isolated adapter. Verification matched the book SHA-256 and resolved the
live catalogue address to that copy, confirmed the old file was released,
and checked the neighbouring file and the other catalogue records.
The server and client were on the same test Windows system.

- x64 evidence: `r1988-transfer-share/share2/verified`. The x86 attempt in
  that run stopped at the startup-busy notice before performing the move.
- x86 evidence: `r1988-transfer-share/share3/verified`. The corrected driver
  selected the notice's actual OK button when the catalogue was loading.

The ordinary queued cleanup also preserved two unrelated catalogues. The
first had an open rollback transaction in the source folder. It rolled back
successfully after cleanup. The second, in the working folder, had an
uncheckpointed committed WAL after process exit. Its database, WAL and SHM
remained byte-identical, then SQLite recovered the committed note and passed
its integrity check. HomeLibre removed its own claimed snapshots. Results
from the native journal harness on x86 and x64 are in
`r1989-transfer-context/other-sqlite-{Win32,Win64}/test.log`.

## Destination disconnected during a real write

The exact r1988 x64 and x86 portable executables each moved a 100,663,421-byte
book through the normal transfer window of an offline Windows 10 guest. A
private virtual USB drive was detached after its frontend reported 6,361,088
written bytes on x64 and 6,328,320 on x86, while the on-disk journal still
said copying. The source and original catalogue addresses survived. After
reconnection the runner found no published partial book, pressed Continue
and verified the complete destination SHA-256, catalogue address and removal
of the old book. A neighbouring, unrelated file remained intact. The working
folder for the journal stayed online in this test.

Both application runs, the device controller and the independent verification
passed. Guest receipts and screenshots are under
`r1983-transfer-hotplug/release1988e/verified`. The per-device byte counts are
in the adjoining `usb-controller.json`.

## Transfer help and refreshed packages

Both r1989 Main builds include the transfer guide. Four private-desktop tests
completed the ordinary transfer workflow on x86 and x64 at 225% (direct move)
and 100% (stop and continue). The six rebuilt ZIPs have the same member names
as r1988. The only members with changed CRC or size were Main, the transfer
help page and the transport manifest. Main and the help file were independently
compared to the intended build and help source.

The r1989 native distribution checks passed for all six ZIPs. Each full
edition includes all 25 pinned optional components. The published beta 13
frontend upgraded the private catalogue from the new compatibility ZIP and
restarted twice on both architectures. The first parallel x86 attempt was
declined by the test driver's existing-catalogue guard; its separate rerun
passed. Reports: `r1989-distribution-verification/distribution-report.json`,
`r1989-transfer-context/upgrade-Win32-retry/report.json` and
`r1989-transfer-context/upgrade-Win64/report.json`. These were local package
installations. The USB-disconnect and SMB results above used the r1988 Main.

## Remaining checks

Remaining source checks, Desktop replacement and publication remain open.

All preparation is on G:. No E: input or user-library modification is involved.

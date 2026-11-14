# Read-only preparation of selected FLibrary image archives

This is a beta-14 implementation step, not a completed catalogue operation.
`external_image_preparation.py` is packaged but the normal compression command
does not call it yet. No user collection, Desktop executable, feed or GitHub
release was changed.

## Prepared operation

The new module identifies selected resources using the reader's book basename
and sibling-archive rules. Actual outer 7z magic enables FLibrary handling,
including a 7z named .zip. An ordinary outer ZIP does not enable it. A sibling
ZIP has priority over .7z; inactive fallback archives remain opaque.

Only selected cover names and image prefixes are replaced. A basename shared
with an unselected outer member is blocked. Hardlinked side archives currently
require a shared-usage plan and are rejected before preparation.

Raster processing uses the existing image component in batches of at most nine
images and 64 MiB. JPEG XL is decoded with the provided decoder, first trying
exact JPEG reconstruction and then raw PNG. Individual input/output images are
bounded to 16 MiB; decoder execution is bounded and cancellable. Original mode
does not load an image processor or decoder. Prior output-image hashes can be
retained without decoding/reencoding.

The archive replacement layer verifies selected outputs, neighboring members,
archive inventory/CRCs and a strictly smaller physical result. ZIP comments
remain intact. A rejected larger candidate reports original image hashes and
sizes. Cancellation or failure removes prepared candidates. Source and active
dependency identities/hashes are checked again, including a same-size change
with restored timestamp or the arrival of a higher-priority ZIP.

These witnesses are preparation data. They are not yet part of the native
incremental-check ledger or a durable multi-file commit.

## Verified packages and execution

Local `G:/HL-b14-external/packages-r135` candidates:

| Architecture | Bytes | BookProcessing SHA-256 |
| --- | ---: | --- |
| Win64 | 12452546 | abf54c0927bd201812f9c7e643fe01c34962465ddf3f88eb388a56da5f029f63 |
| Win32 | 11193167 | 8cb2ede9d5ceca730e3f75e10dd99a3af0543e7a2d2bbc4eddb98d32f2b84b21 |

The package adds one worker within the existing BookProcessing path prefix.
Existing packing/preparation worker sources and native receipt code are
unchanged. The diagnostics verify package manifests, payload hashes, installed
source equality and native architectures.

Each architecture passed the full 17-case preparation suite plus three existing
native operation regressions. This covers real codecs, batching, exact
neighboring/source bytes, reversible mode without optional tools, all quality
choices, retained image hashes, missing decoder, shared IDs, cancellation,
dependency changes, Unicode paths exceeding 300 characters, Delphi basename
rules and archive priority. Grayscale is checked by comparing decoded RGB
channels pixel by pixel. One case runs the actual isolated embedded Python and
matching native executables of the target architecture.

| Architecture | Final combined run | Seconds | Result |
| --- | --- | ---: | --- |
| Win64 | preparation-Win64-r136 | 110.672 | PASS, 20 cases |
| Win32 | preparation-Win32-r137 | 111.906 | PASS, 20 cases |

The native operation regressions cover normal commit, an unchanged repeat that
avoids preparation and no-gain bookkeeping without authoritative data changes.
They exercise the current operation with the new package, not native publication
of the new external-image candidates.

An additional raw JPEG XL case uses the existing 3,478-byte transparent-ink
regression fixture. Actual decoding falls back to PNG, and transparent/opaque
pixels remain correct after preparation: Win64 `alpha-Win64-r138` PASS 10.781 s;
Win32 `alpha-Win32-r139` PASS 10.750 s. Together, the final runs cover 18 external
preparation cases and three existing-operation cases per architecture.

All passing runtimes were removed. Reports/logs and scoped
`report.external-images.json` measurements remain under `G:/HL-b14-external`.
For the Win64 generated sample, the covers archive is 925,613 → 924,702 bytes;
the images archive is 3,690,579 → 1,925,104 bytes. Unselected image payloads and
the source files remain exact. These are synthetic measurements, not a predicted
saving for a user's collection.

The decoder is from the previously verified official libjxl 0.13.0 Windows
archives. Extracted decoder hashes are
`81795e834bad0c17db5d707fde1f72520834b36788ea46b54269f3469bc85a5c`
(Win64) and
`43f53a772395fd61fb1f2582cb6cac294f97c76c0d8171f032149dfda733cdd4`
(Win32). The independent extraction report is in `decoder-r121/report.json`.
This is private staging, not a component download/installer test.

Earlier `r129`/`r130` passed 14 preparation cases; `r133`/`r134` passed the
embedded-Python case plus three compatibility cases before the final expanded
suite above. Initial `r123`/`r124` found a missing 7-Zip argument in the new module's Packer
configuration. `r126`/`r127` then found a diagnostic path-separator mismatch in
the injected-change assertion. Their failed reports are retained; final runs
use corrected code and normalized diagnostic keys. Embedded-only `r131`/`r132`
also passed before the stronger final changed-payload assertions in `r133`/`r134`.

## Required native connection

Next, add a read-only restoration entry point accepting explicit candidate
covers/images archives, while retaining ordinary discovery for existing callers.
Use it to validate complete FB2/EPUB resources, text, cover and actual sizes
against real FLibrary books, and to build selected-book original backups before
any source write.

Then bind all source/dependency witnesses, prepared physical files and measured
book results in a durable native operation. It must recover each physical
archive replacement, replay catalogue/personal commits and acknowledge only
after refresh. Incremental checks must include active external images rather
than the primary archive alone. Native code must capture its own file-handle
identities rather than interpreting Python stat inode numbers as native keys.
Only committed changed/reused outputs belong in image-history tables; a
rejected no-gain proposal is not a transformed image. Per-source aliases and shared-resource ownership
must remain explicit. The current one-file receipt must not be reused as though
its primary file hash proves these external image changes.

Also connect comparison previews, disk estimates/owned preparation cleanup,
missing-decoder continuation and partial-failure reporting. User-data copies,
final applications/distributions and the rest of beta 14 remain separate gates.
The Python preparation layer does not prove native publication or full-book
readability; current diagnostic book bodies serve only as resource identifiers.

## Worker request bridge

The installed `external_image_preparation.py --job ... --cancel ...` now accepts an explicit versioned external-image preparation request. Its atomic report includes the exact selected members and explicit original/prepared covers/images slots for native complete-book restoration. It is not a publication receipt. Missing JPEG XL is identified as component `JPEGXL`; cancellation, request-version refusal and report collision leave source bytes unchanged and remove owned candidates.

Four focused installed embedded-Python cases passed on each architecture; no unchanged archive/core suites were repeated. Reports: `G:/HL-b14-external/protocol-Win64-r141/report.json` (22.5 s) and `G:/HL-b14-external/protocol-Win32-r142/report.json` (27.282 s). Both private runtimes were removed. Packages-r140 are local candidates, not published or deployed. Native grouped publication remains outstanding.

## Complete-book candidate sources

`RestoreFLibraryBookWithImageSources` now reads explicit covers/images candidates before any source replacement. Nil preserves existing discovery; two explicit slots disable fallback to newly arrived live archives. Missing candidate files and damaged explicit archives fail instead of being silently ignored.

Both architecture builds passed. The selected earlier book 557950 had been removed from its archive, so the real-data diagnostic now takes an existing numeric book/image inventory. On retained book 556344 (source SHA-256 `7cded854125cc9d7474e5593206d8ec14a93079f98d600fbbb26c48942e67d45`, 81,282 body characters), maximum grayscale preparation changed its cover and illustration. Native x86 and x64 both restored the full processed FB2, resolved every image reference and preserved text. Repeated restoration and metadata edits also retained images/text. Source archives were only read; owned fixtures and the private processing runtime were removed. Report: `G:/HL-b14-external/source-restoration-r145/report.json`. This validates FB2 candidate restoration, not grouped publication or other formats.

## Publish recovery data before writes

`TZipMemberDeletion.PublishJournal` separates the existing durable-journal publication from destructive `Execute`, allowing future grouped image replacements to publish all component journals first. Normal Execute still follows the same publication/write sequence. The native fixture publishes a real replacement journal, exits with unchanged source/catalogue/personal bytes, and completes it in a second process. Three focused native scenarios passed per architecture: publish-before-write/reopen, normal job/owned cleanup, and crash recovery across file/database/cleanup boundaries. Reports: `G:/HL-b14-external/journals-Win64-r146/report.json` (35.828 s) and `G:/HL-b14-external/journals-Win32-r147/report.json` (29.625 s). This is the publication primitive; the group coordinator, dependency ledger, full original backup and app flow are still outstanding.

## Linked archive queue

`TBookCompressionFileGroup` binds up to three native replacement journals to the catalogue receipt. Every journal is durable before a `started` marker permits the first source write. A stop before that marker leaves all originals unchanged; after it, the group finishes all files before catalogue/personal commits. Recovery uses the same rule, including an already-pending stop. `TBookCompressionJob` now persists/discovers grouped jobs, checks all completed output identities/hashes, rechecks catalogue locators before the first write and cleans its fixed group artifacts after durable completion.

Thirteen scenarios passed per architecture, including normal legacy single-file behavior, three-file groups, persistent queue replay, explicit process termination across file/database/acknowledgement boundaries, metadata changes during journal preparation, modified completed image sources and preservation of a foreign work-file. Synthetic archive fixtures were used. Reports: `G:/HL-b14-external/group-Win64-r149/report.json` (153.547 s) and `G:/HL-b14-external/group-Win32-r150/report.json` (156.485 s); private runtimes removed. Receipt fixture SHA-256: x64 `5132e837a66b9c29efae8661933491415634379f70a451521d697fbcf3e210ce`, x86 `bba8a27ed7254b1e1fe667b4a6a6407fd64910a21ca66c6a0724549d10c8e209`.

Still open: interrupted preparation before group readiness; image-only groups when the book archive has no smaller candidate; restored logical sizes/dependency-aware history/full originals; connecting the producer report to the application operation and final real-copy/app checks. This queue validation does not mean the current application already submits external-image compression groups.

## Image-only publication

A grouped job can now omit replacement of the book archive when only covers/images have smaller candidates. The unchanged root is pinned and hashed before a new picture write; recovery of an already-started group finishes the picture archives before refusing mismatched root metadata. Every component receipt is checked before catalogue/personal commit. A receipt without a root replacement cannot claim changed raw book payloads. Existing book/copy/personal sizes remain unchanged until the complete-book measurement is connected. The scratch-candidate reference falls back to a component candidate for normal recovery cleanup.

Seven focused scenarios passed on each architecture, including image-only process-crash recovery, unchanged-root refusal, changed root after a partial image write, malformed payload refusal, primary-plus-images and legacy single-file jobs. Source archives, database metadata and old sizes were checked on synthetic fixtures; private runtimes removed. Reports: `G:/HL-b14-external/image-only-Win64-r151/report.json` (65.016 s) and `G:/HL-b14-external/image-only-Win32-r152/report.json` (61.469 s). Native receipt fixture SHA-256: x64 `168474b39a3f9c10879e9362954e1a96894eea72eabe457e217d0aaf89e89a17`; x86 `c457bc869bf897f2c09a108b81544bcc30a4e0578119dcc3999d4dad24727d3f`. The application producer, restored measurements/history/full originals and interrupted preparation remain outstanding.

## Complete books connected to the application operation

`TBookCompressionOperation.RunFile` now requests external-image preparation and binds its exact native image-source identities to the durable grouped receipt. The native reader materializes the complete original and candidate before publication. The installed worker verifies FB2/EPUB non-image content, measures complete books and prepares optional self-contained originals and comparison images. The native owner checks the returned hashes against its own snapshots. Catalogue, copy and personal sizes use this complete measurement; receipt replay accepts the measured size. Unchanged dependencies remain read-leased, while changed archives use the replacement engine's existing checksum proof while its exclusive handle is held. Preparation cleanup covers the owned external candidates and full-book snapshots.

The producer reads content-addressed image history, records only retained/reused image outputs and leaves unsuccessful images eligible for retry. Fast repeat/incremental checks include external source identities. Archive detection now recognizes actual 7z bytes in `.zip`/private `.bin` containers.

Six focused complete-book validation tests passed, including changed text/snapshots, cancellation, optional backup/preview and format refusal. On a copy of retained real book `556344.fb2`, native before/after capture, complete size, full original and preview passed on x86/x64 (`G:/HL-b14-external/source-restoration-r154/report.json`); production sources were read only. The actual application worker-thread pipeline then passed two end-to-end cases per architecture: ordinary `.7z` and 7z named `.zip`. Each case verifies selected compression, untouched neighbor images, full originals, catalogue/copy/personal sizes, exact savings, repeat skipping, history reuse after an image timestamp change and current-collection incremental processing after a new cover. Reports: `G:/HL-b14-external/integrated-Win64-r163/report.json` (78.375 s) and `G:/HL-b14-external/integrated-Win32-r164/report.json` (79.234 s); private runtimes removed. The ordinary ZIP application pipeline also passed during r161. Packages are local `packages-r160`; no Desktop replacement or publication.

Still open: group preparation interrupted before readiness; dependency-aware preservation of complete sizes across INPX rebuilds and stronger repeat checks for same-size/restored-timestamp image changes; extended group-recovery checks for the new complete-size/dependency receipt; real EPUB/other-format application paths and final production builds/packages. The verified pipeline here is FB2; it does not close the entire compression/release task.

## Restored sizes across index replacement

Complete measurements now have a separate native witness: raw payload hash, complete input/output hashes and size, book archive identity/checksum, and the exact external-image set. Index capture/rebuild/restore can retain these sizes when the publisher renumbers a book. It refuses a different physical archive and image sources changed before or during import. The image-set metadata check is cached once per physical source during each pass, avoiding an archive-open pass for every book. This index path uses identities and timestamps; ordinary repeated compression additionally verifies the stored external-image SHA-256 values, so a same-size image mutation with restored timestamps cannot become a cache hit. Repeat runs leave both source archives and catalogue/personal database bytes unchanged.

The actual application compression thread plus transactional index capture/rebuild/restore functions passed on both architectures: `G:/HL-b14-external/index-Win64-r168/report.json` (49.469 s) and `G:/HL-b14-external/index-Win32-r169/report.json` (32.203 s). Cases include renumbering, another archive, image changes before/during import, selected-image CRC damage with unchanged size/time, exact repeat skipping, and incremental processing. Owned runtimes were removed. This targeted check simulates index row replacement; the full INPX import/UI gate remains part of final application validation. Interrupted group preparation and extended full-measurement recovery are the next open compression items.

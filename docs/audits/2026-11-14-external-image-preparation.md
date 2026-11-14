# Read-only preparation of selected FLibrary image archives

This audit records the staged beta-14 implementation. The ordinary compression
command now submits external-image groups, verifies complete books and recovers
interrupted work. The sections below retain evidence from each stage; the latest
sections describe current coverage and remaining release gates. Production
collections were read only for selected real-copy checks. The Desktop executable,
feed and GitHub release have not been replaced.

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

## Interrupted group preparation

An incomplete group can now resume before its ready marker. Previously published component journals must prove that they have not started and that their exact original identity and SHA-256 still match; missing journals are prepared from the durable parent receipt. No source write is enabled until every journal is ready. A crash before the group manifest is saved is recoverable from the parent's bound manifest; only matching native atomic-save prefixes are removed. Foreign contents remain untouched and prevent automatic continuation. A stop during unstarted preparation recovery leaves originals unchanged, while recovery of a started group still finishes its linked files.

Six focused cases passed on x64 and x86, including five crash boundaries from directory creation through the last prepared component, stop/resume, changed original bytes with restored length/time, own versus foreign temporary data, already-started recovery and normal durable queue cleanup. Reports: `G:/HL-b14-external/preparation-Win64-r171/report.json` (62.750 s), `G:/HL-b14-external/preparation-Win32-r172/report.json` (65.875 s). Owned runtimes were removed. These cases use native grouped receipt fixtures; application-thread recovery with complete-book measurements is checked separately next.

## Application-thread recovery with complete measurements

The isolated application-operation test executable now enables the existing test-only fault hook when a fixture explicitly requests it. Three process-termination cases passed per architecture: after one component journal is prepared, halfway through an image archive's metadata write, and between catalogue and personal-store commits. A new operation process resumes each durable job and validates the completed image archives, self-contained original backup, complete catalogue/copy/personal sizes, image history and empty acknowledged queue. Reports: `G:/HL-b14-external/full-recovery-Win64-r173/report.json` (31.843 s) and `G:/HL-b14-external/full-recovery-Win32-r174/report.json` (36.984 s); owned runtimes removed. The fault hook remains excluded from production builds. Next: actual EPUB/other-format application paths, the complete INPX UI/import gate, and final application/package/release validation.

## EPUB containers and actual reading

Nested 7z EPUBs no longer enter the ZIP-only image converter. Their embedded resources are streamed into bounded private files; batch stream ordering is checked by per-member CRC, with exact-name extraction as fallback. Non-image resources are compared before republishing verified smaller inner and outer candidates. Existing FLibrary image mappings and separate images remain in place. Outer 7z books without sidecars also receive complete restoration, measured sizes and self-contained original backups. Native image-source discovery follows actual archive magic, including a 7z named `.zip`; ordinary ZIPs do not acquire unrelated sibling-image dependencies. JPEG XL decoder lookup and engine fingerprint use the installed `jpeg-xl` path.

Four application-operation cases passed per architecture: stripped ZIP EPUB, nested 7z EPUB, embedded plus external images, and nested EPUB without sidecars inside a misnamed outer archive. The normal catalogue book stream was reopened after publication; actual stream size equals catalogue/copy/personal sizes, text/CSS/fonts/SVG are byte-exact, originals are complete, and repeat runs do not rewrite files or databases. Reports: `G:/HL-b14-external/epub-Win64-r181/report.json` (33.406 s), `G:/HL-b14-external/epub-Win32-r183/report.json` (41.250 s). Packaged worker: `packages-r177`.

A selected copy of real retained `699624.epub` from `F:/fb2.flibusta.lib.rus.ec.7z/f.usr-699612-704034.7z` passed on both architectures with the verified official JPEG XL decoder. The book has a nested 7z stream, 82 resources and 31 separate image slots (one cover, 30 illustrations). Native complete reading, self-contained original, non-image equivalence and all catalogue sizes were checked. The canonical reading stream changed from 6,247,298 to 990,933 bytes; physical archive savings were 90,195 bytes, a different measurement because the source already uses FLibrary compression. Source archive SHA-256, sizes and timestamps matched before/after. Reports: `G:/HL-b14-external/real-epub-Win64-r185/report.json` (37.843 s), `G:/HL-b14-external/real-epub-Win32-r186/report.json` (35.719 s), with companion `.real-epub.json` evidence. Owned book copies/runtimes were removed.

## Full index import through the normal application

The actual selected-compression menu, modal options, background operation and `TManualUpdateThread` full INPX import passed on x64 and x86. Compressed sizes and personal progress survived the full import; eleven identity/rollback boundaries also passed. Reports: `G:/HL-b14-external/inpx-ui-Win64-r182/catalogue-Win64-apply.json` (27.375 s) and `G:/HL-b14-external/inpx-ui-Win32-r184/catalogue-Win32-apply.json` (29.219 s). This integration fixture uses a synthetic shared ZIP; external-image witness boundaries are covered by the dedicated index/EPUB checks above. All runs used the exact local BookProcessing package and isolated application profile; no production catalogue was opened for writing. Remaining: other accepted format/module/release gates and the final production applications/packages/Desktop/release, along with the other open beta-14 tasks.

## Mixed images and WebP

The previous quality processor recognized only JPEG/PNG, leaving WebP unchanged even for grayscale. It now decodes static WebP with the installed architecture-matching libwebp, then uses the same bounded quality/grayscale pipeline. The output can be PNG or JPEG; resource names/IDs and links stay stable, and MIME follows the retained content. Lossy processing never restores detail already lost in a source. Small color WebP stays byte-exact when a candidate would grow. Grayscale also remains subject to the archive/no-growth decision; requesting grayscale is not a guarantee that every source image is replaced.

Native FLibrary restoration previously labeled a separate WebP `application/octet-stream`. The full-content safety comparison correctly refused the later image substitution. WebP now receives `image/webp`, including cover extraction. The engine fingerprint includes the WebP decoder/module metadata and shared image decoder source. Animated WebP is retained with an explicit reason rather than flattened to one frame.

Five focused cases per architecture passed using the installed BookProcessing package: mixed embedded PNG/WebP plus external JPEG XL/PNG/WebP in a selected FB2; nested EPUB with embedded/external WebP under misleading PNG resource names; small color WebP without gain; grayscale WebP with transparency; animation retention; and the existing reversible/no-image-processor case (the color/transparency checks share one case). Complete native readback, original backup, text/resource preservation, actual catalogue/copy/personal sizes, physical savings, untouched neighbors and exact repeat skipping are checked by the native cases. Reports: `G:/HL-b14-external/webp-Win64-r196/report.json` (47.375 s) and `G:/HL-b14-external/webp-Win32-r197/report.json` (50.406 s), five tests each, no skips, private runtimes removed. Packages are local `packages-r195`; Desktop and production libraries were not changed.

## Disk headroom

Archive work now checks the Windows system volume even when the workspace is on another drive: below 8 GiB it refuses/interrupts preparation. The requested working bytes additionally require 512 MiB free headroom, replacing the old 16 MiB margin. Temporary-directory creation checks before writing; long preparation loops recheck once per second. Complete-book snapshots check system space and retain 512 MiB on their volume. The IDE build wrapper checks the system reserve before starting and while its own build runs. Four focused mocked-volume checks passed (another-drive workspace, destination margin, refusal before temporary-directory creation, and accepted exact bounds).

Own native test outputs were moved from the worktree to `G:/HL-b14-external/native-test-outputs-r190`, with the old path retained as a junction. The current chat history was compressed with Windows file compression, not deleted. C: had about 15 GiB free after the checks. No files belonging to the active game-project chat were removed. These controls govern this work; they cannot prevent an unrelated application from consuming disk space. The guard and mixed-image tests do not close the remaining beta-14 production/release gates.

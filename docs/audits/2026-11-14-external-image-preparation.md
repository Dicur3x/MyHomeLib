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

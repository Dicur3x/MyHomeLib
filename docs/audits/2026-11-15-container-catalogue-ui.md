# Real container books through the catalogue command

## Scope

Three retained isolated payloads (ODT, DOCX and CBZ) from r668 were selected
simultaneously in the ordinary search list. The rebuilt CollectionViewsTest
creates the real Main form and invokes its existing selected-book action,
options, estimate, background operation, review, comparison and result controls.
The catalogue is a small private fixture, not the full 4.5 GB catalogue used in
the separate native trial. No final production Main/Reader release is claimed.

The test driver now supports two to ten exact members while retaining its old
two-book defaults. For every selected book it seeds/checks the initial Reader
cache, checks the refreshed visible row and physical size, reads the refreshed
cache and verifies the exact backup. Reading progress remains 37. An unselected
neighbor is independently byte-checked. The Python wrapper also verifies every
non-image field/resource and decoded grayscale pixels in the three containers.
Only the positively identified 4.8 MB retained copies are used as payloads;
the original multi-gigabyte archives are only stat-checked against their saved
identities. All test installations and processing stay on G:.

## Found and fixed: first book monopolized comparison

The first ordinary x64 window showed all twelve samples from the CBZ, despite
also processing DOCX and ODT in the same archive. The bounded collector filled
its global slots while visiting the first book. A focused preparation test
reproduced this with two illustrated FB2 books: the second member was absent.
`preview-fairness-baseline-r690` records that intended FAIL (one failure, zero
errors/skips). Its owned runtime was observed removed after the run.

The collector now gives each selected book a share of the twelve slots before
moving to the next book. A single book retains the previous twelve-image cap;
the global byte and individual-image limits are unchanged. This is a bounded
sample, not a promise to show every image or every book in selections larger
than twelve. The viewer text describes samples of selected books.

The regression checks both represented members and exact original/encoded
bytes from the candidate, as well as the unchanged source and neighbor.
`preview-fairness-fixed-r692` passed all nine preview cases: actual FB2/EPUB
pairs, cancellation/publication cleanup, foreign-file retention, no-gain/outer
packing behavior and caps. Zero failures, errors or skips; runtime removed.
The strengthened native GUI check also selects and decodes at least one
comparison pair for every requested illustrated book before approval.

## Evidence

Reports are under `G:/HL-b14-external/`:

| Run | Outcome and exact scope |
| --- | --- |
| `container-gui-Win64-r684` | PASS with r665: three real books, estimate/apply, exact backups, refreshed sizes/caches and new-books repeat; comparison visually inspected. |
| `container-skip-Win64-r686` | PASS with r665: estimate and skip retain the original shared ZIP hash and create no backup. |
| `container-default-Win64-r687` | PASS with r665: old two-FB2 defaults and new-books repeat remain compatible with the generalized driver. |
| `container-gui-Win32-r689` | PASS with r665: same three-book estimate/apply, size/cache/backup and new-books behavior. |
| `container-fair-gui-Win64-r694` | PASS with r691: actual comparison selector contains all three books, all three decode, content/pixels/backup/cache checks pass and repeat skips all three. |
| `container-fair-gui-Win32-r696` | PASS with r691: the same comparison, three-book estimate/apply, visible/cache sizes, non-image content, grayscale, originals and repeat checks. |

The r685 x86 IDE build timed out at 300 s without a compilation log. It was
terminated/reaped by its owning build script. One visible retry r688 completed
successfully. This was not counted as a product test failure or a release gate
pass. Final comparison builds passed without changing their projects:

- Win64 r693, SHA-256 `eb1febeecf8d614b3f9d0df6c84791418b2121c0ca1ea6ba8deaa05a2b427fb8`.
- Win32 r695, SHA-256 `3d1e02baf8121df47775e328464c084020dbdbbcb7d206d83b594557a726ef41`.

The final source ZIP was 4,833,382 bytes including the retained neighbor;
its result is 4,122,677 bytes on x64 and 4,122,562 on x86. Individual payloads:

| Book | Original | Win64 | Win32 |
| --- | ---: | ---: | ---: |
| CBZ | 3,128,863 | 2,896,607 | 2,896,607 |
| DOCX | 1,048,434 | 951,302 | 951,302 |
| ODT | 655,616 | 313,073 | 313,106 |

The x86 book hashes are identical before/after the comparison fix (r689/r696).
Aggregate ZIP sizes include outer compression and cannot be substituted for
the sum of uncompressed book sizes. The result timings include bootstrap,
comparison/DPI checks and cleanup; they are not throughput forecasts.

## Current module candidate

Final builds/feeds must use `G:/HL-b14-external/packages-r691`, not r665.
ImageProcessing is byte-identical to r665; only BookProcessing changed.

| Module/architecture | Bytes | SHA-256 |
| --- | ---: | --- |
| BookProcessing Win64 | 12,466,367 | `5461097248d898952dff7ed4829a1868aa53182db9a0c8e3f79016f8e09df7a2` |
| BookProcessing Win32 | 11,206,989 | `ac3fa5855a673fe5c53d2f6515860e61a5c1dd04b799416c33b7e55eaa3099f8` |
| ImageProcessing Win64 | 13,207 | `2544efb5d075074a998d052a1dbf4479762b7de6449206fff828c7a0a1cadb2d` |
| ImageProcessing Win32 | 13,285 | `6f7f01b023a94e1fca65c9c44b3c03fac431df62f03dfe92343a3d32c470c0d3` |

## Visible inspection

Computer Use inspected the x64 CBZ original/color and grayscale pair at native
100% and fitted scale, then restored 100%. After the fix it inspected the
selector containing four CBZ, four DOCX and four ODT entries, and selected an
actual DOCX pair successfully. The ODT row-selection attempt coincided with the
bounded driver's automatic window completion; no separate visible ODT picture
claim is made. Native control checks independently decode all three books.
The comparison's geometry, original pixel sizing and close control are checked
in both themes at 96/144/192/288 DPI. This does not claim a manual visual audit
of every theme/scale. No foreign apps were controlled.

## Boundaries and remaining work

This verifies the ordinary selected-book command with the actual production
forms and a small isolated catalogue. The previous full-data preservation
trial retains its own native-only scope. Final Main/Reader binaries, normal
copy-registration UI, other outstanding formats and final release packages
remain open. The Desktop copy and public release are unchanged. The retained
4.8 MB inputs are still needed for the normal copy-registration trial; all
completed private runtimes have been removed.

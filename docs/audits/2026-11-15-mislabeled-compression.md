# Compression and readback with misleading book extensions

Actual native operations on x86/x64 confirm that image preparation detects an
EPUB named `one.fb2` and a UTF-16 FB2 named `one.epub` by content. One real
diagnostic defect was reproduced and fixed: a retained RTF named `.fb2` was
reported as FB2 despite being correctly detected as RTF.

The preparation report now retains the detected format for unsupported inputs
as well as optimized ones. Already-transformed reuse also probes the type,
without encoding its images again. Source archive members and catalogue
extensions are not renamed by this diagnostic change. No new RTF image
transformation is introduced.

## Native invariants

The private generated catalogue has a selected book and an untouched neighbour
in a shared ZIP. The real packaged producer and native operation must preserve
all non-size catalogue/personal rows, including annotation/review/extra-note
BLOBs, rating, progress, relationships and the other collection. Actual payload
length must match the catalogue, alternate copy and personal card.

For EPUB, all non-image resources remain byte-identical; the OPF's complete
parsed structure remains equal except the deliberate image media-type change,
which must match the actual image header. For UTF-16 FB2, parsed XML retains
tags, IDs, text, Unicode and attributes except raster bytes/MIME. Native
`GetBookStream` in a new process must return the exact committed payload even
with its misleading extension. Original backups retain the exact input bytes.

The RTF case remains byte-exact, reports `.rtf`, publishes no unnecessary
backup/job and leaves the physical archive unchanged. Each case repeats without
changing archive/store/backup bytes. The two optimized cases additionally
change the worker identity and require actual detected format, `reused=true`,
zero newly processed images, unchanged source/personal/backup and unchanged
non-size catalogue rows. This is native stream readback, not visual Reader UI.

## Evidence

All runs are under `G:/HL-b14-external/`.

| Run | Outcome |
| --- | --- |
| `mislabeled-Win64-r643` / `mislabeled-Win32-r644` | First harness draft failed three assertions: it incorrectly forbade deliberate image MIME changes and required RTF/no-gain archive writes. Not product-corruption evidence. Owned runtimes removed. |
| `mislabeled-baseline-Win64-r645` / `mislabeled-baseline-Win32-r646` | Corrected assertions: both optimized misleading-extension cases passed; the RTF report reproduced `.fb2` instead of `.rtf`. Reports correctly remain FAIL. Owned runtimes removed. |
| `mislabeled-fixed-Win64-r648` / `mislabeled-fixed-Win32-r649` | PASS, four cases each: three new cases and the existing engine-update preservation regression; 21.171 / 21.828 seconds including setup/cleanup. |
| `mislabeled-reuse-Win64-r650` / `mislabeled-reuse-Win32-r651` | Strengthened two optimized cases also passed the new-engine/actual-format reuse checks; 17.516 / 18.468 seconds. |

All passing native reports have no failures, errors or skips; all private
runtimes were removed. A separate unconfigured discovery correctly skips these
native-only cases and is not counted as passing product coverage.

## New local processing candidate

`packages-r647` was built by `scripts/package-format-components.py` and used by
all fixed runs. Archive contents/manifests and actual Python platform are
verified during build/staging. These are unpublished BookProcessing 3.0.0.14
candidates:

- Win32: `b076216abc31e63d8690ab07455d6c6cd6e7447cb69fc706d67bf49cb2e9eb49`.
- Win64: `9dccbf967ae67bbe11b5d0711f10d8b8f2859a8636ade841efe54b8ce2e8732b`.

Final minimal/full distributions and the component feed must use this newer
candidate rather than the earlier r195 bytes. Earlier evidence remains valid
for its recorded versions; no old report/package was rewritten. This does not
close outstanding formats, real-collection copy or final release gates.

# Recompressing zero-numbered FLibrary covers shared by EPUB resources

The remaining known generated legacy layout now has explicit native
recompression/recovery coverage on x86 and x64: an EPUB's `cover.png` and
`cover-alias.png` both refer to external image `one/0`, with a distinct
illustration at `one/1`. The normal and crash cases passed without changing
production code or the installed processing packages.

## Independent content checks

The fixture covers a ZIP EPUB and a nested 7z EPUB in an outer 7z named
`books.zip`. Each is tested with a PNG cover and with an already-compressed
JPEG XL cover. The JPEG XL case deliberately keeps PNG resource names and
manifest declarations before native restoration, testing actual content/MIME
handling. Cover and illustration source pixels differ, so substituting one
for the other cannot satisfy the alias checks.

The actual packaged producer and native operation apply maximum/grayscale
choices, publish one self-contained original backup and acknowledge the job.
Both original-cover resources must match the original PNG, or the original
JPEG reconstructed from the known JPEG XL fixture. The processed full EPUB
must preserve XHTML (including its explicit alias reference), CSS, font, SVG
and container XML. Its two cover resources must remain equal and distinct
from the illustration; both manifest MIME values must match their content.
Independent 7-Zip extraction checks the corresponding physical image member
and exact unselected book/image neighbours.

A retained JPEG XL image must still contain its exact known original and
restore the original JPEG byte-for-byte. Such retention is allowed when a
replacement would not save physical space; the test does not force every
small image to undergo another lossy conversion. Other images still shrink.

Complete Reader-stream length must equal catalogue, alternate-copy and
personal-card sizes, including both copies of the shared resource. A repeated
operation must leave the archive, sidecars and both databases byte-identical.

## Actual interruption checks

Two additional cases terminate only the native test process with exit code 73
at the requested real stage: halfway through first-file metadata replacement,
or after the catalogue commit with the JPEG XL/nested EPUB layout. A new
native process resumes the persisted job before the same full content,
backup, size, alias and repeated-operation assertions run. These are native
worker restarts, not ordinary Main-window startup or hardware power-loss tests.

## Evidence

All reports are under `G:/HL-b14-external/`. Their `operation.json` and log
record PASS, no failures/errors/skips, exact tool hashes and removed private
runtimes.

| Coverage | x64 run / seconds | x86 run / seconds |
| --- | --- | --- |
| Two PNG zero-cover layouts and the existing ordinary `-1` cover control | `zero-cover-Win64-r637` / 35.562 | `zero-cover-Win32-r638` / 37.578 |
| Both JPEG XL zero-cover layouts | `zero-cover-jxl-Win64-r639` / 47.516 | `zero-cover-jxl-Win32-r640` / 48.047 |
| Both actual interruption/recovery boundaries | `zero-cover-crash-Win64-r641` / 41.781 | `zero-cover-crash-Win32-r642` / 48.625 |

That is seven distinct cases on each architecture, including four actual
terminated processes overall. The native operation binaries are the fresh
r626/r628 builds recorded in `2026-11-15-compression-cross-volume.md`;
BookProcessing is `packages-r195`. JPEG XL uses the verified official
libjxl 0.13.0 decoders recorded in each report. The older receipt executables
are runner prerequisites; these selected cases use the operation executable
and are not a rerun of the receipt suite.

Earlier general reading/retention evidence for this layout is in
`2026-11-14-flibrary-sidecar-retention.md`; other native mixed WebP/JPEG XL
and real-book cases are in `2026-11-14-external-image-preparation.md`.
Those older broad suites were not rerun by this milestone. Final production
EXEs/packages, outstanding format work and a user's complete collection
remain outside these generated-layout checks. Desktop and releases were not
changed.

# Large PDF: separate bounded browser memory budget

The long LRF omnibus exposed two distinct constraints. Parallel backend probes
hit an outer four-minute test limit. A diagnostic run with a longer deadline
then produced a complete 1246-page PDF. However, increasing the production PDF
deadline alone did not fix the native worker: the current five-minute package
still failed with `Value does not fall within the expected range` in r1483.

The native launcher separately limits each process in the contained conversion
tree to 512 MiB. That also applies to the WebView2 renderer used for EPUB-based
PDF printing. The PDF route now receives a bounded 2 GiB per-process budget;
other decoder routes, including FB2's separate PDF writer, retain 512 MiB.
Process-tree containment, cancellation, the five-minute writer watchdog, input
and output limits, and atomic publication remain in effect. This is a ceiling,
not a reservation or removal of resource limits.

## Native x64 and x86 results

With the same sealed modules, source book and native workflow, the new x64
binary successfully publishes the PDF. A host-side observer samples only that
worker and its descendants. Its browser renderer exceeds the old budget:

- sampled private memory reaches about 1169 MiB;
- the Windows-recorded peak pagefile/commit counter reaches about 1399 MiB;
- the operation finishes in about three minutes (the last two-second sample
  is 173.41 seconds; this is not a controlled speed comparison with prior runs).

The actual writing form shows activity and never a fabricated normal bar at 98.
The original LRF hash stays unchanged and the private runtime is removed.
The result is in
`G:/HL-b14-external/sealed-native-lrf-pdf-Win64-r1491/report.json`.

The matching x86 native run also succeeds with the same sealed module cohort.
Its last two-second sample is 163.05 seconds, with about 1153 MiB sampled
renderer private memory and 1406 MiB peak pagefile/commit. This independently
exceeds the old ceiling. The progress observer again sees activity during
writing, never a fabricated 98; the original stays byte-identical and the
private runtime is removed. Evidence:
`G:/HL-b14-external/sealed-native-lrf-pdf-Win32-r1491/report.json`.

An independent reader then checks every one of the 1246 PDF pages against the
prepared source: all 668,971 expected words stay in order, with no missing words,
and all fourteen distinct visible images remain. Thirteen resources match exact
RGBA pixels. The remaining cover differs only in hidden RGB values where alpha
is zero; alpha and visible appearance are identical. The initial raw-pixel
finding is retained rather than silently removed. Evidence:
`G:/HL-b14-external/native-lrf-pdf-independent-r1493/report.json`
(`PASS_INDEPENDENT_VISIBLE_CONTENT`).

The full independent readback is repeated for the actual x86 PDF: 1246 pages,
668,971 words, no missing words, preserved order and all fourteen visible
images, with the same transparent-pixel-only cover difference. Evidence:
`G:/HL-b14-external/native-lrf-pdf-independent-Win32-r1495/report.json`
(`PASS_INDEPENDENT_VISIBLE_CONTENT`). Different PDF hashes across native
runs are retained; the files are not claimed byte-identical.

This checks the full PDF against the prepared EPUB, not an independent decoding
of every original LRF feature or physical-device behavior. The x64 binary build
and source/platform checks are in `pdf-memory-build-Win64-r1490`. Both platforms
were subsequently rebuilt from the final explicitly typed `NativeUInt` budget
and hexadecimal 2 GiB constant, avoiding x86's signed constant inference.
The normal Delphi Build interface reported success with zero errors in
12.4 seconds (Win32) and 24.3 seconds (Win64); PE architecture, linked progress
marker and matching source hashes are recorded in `pdf-memory-ui-build-r1494`.

## Still required

The remaining x86 native matrix subsequently completes all 285 directions
with the final typed-budget binary: zero failures, all 26 original copies
unchanged and the private runtime removed. Its final two-second sample is
772.94 seconds. Evidence:
`G:/HL-b14-external/sealed-native-all-Win32-r1491/report.json`.
Together with the separately checked large LRF PDF, this covers the current
26-family/eleven-direction native cohort on both architectures. Full independent
content readback remains scoped to the explicitly documented subsets.

Final production applications and release/update packages are still required. Earlier
failed runs remain separate evidence and are not counted as successful exports.
No Desktop installation or public asset has been changed. All new work stays
on G:, E: is unused and C: retains its required reserve.

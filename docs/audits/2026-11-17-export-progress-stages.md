# Conversion progress without a fabricated 98 percent

The user's observed jump from 0 to 98 percent was explicit in the native
conversion reader: a `kindle-writing` or `advanced-writing` start record assigned
98 even though the writer had not measured its remaining work. PDF pagination
could then take several minutes while the bar appeared almost finished.

The reader now retains the measured preparation value instead of assigning 98.
The export worker chooses a normal bar for counted pages/image processing and
an activity bar for preparation, assembly and writing without a known total.
Captions name the phase and retain the current book/selection count. Completing
an intermediate conversion is still an activity phase while the native worker
publishes its final file. Normal progress style is restored between books and
at the operation boundary. This does not invent timed percentage increments.

## Native evidence

Both current regression binaries were built through the licensed Delphi
Project Build interface: Win64 in 22.7 seconds and Win32 in 13.1 seconds, with
zero compiler errors. PE architectures and a new linked test marker were
independently checked. Metadata/source hashes are in
`G:/HL-b14-external/export-progress-ui-build-r1489/`.

Each architecture exports the same real CHM to PDF, KFX and MOBI through
`SaveFileBooks`, its actual progress form and fresh sealed components. A timer
observes that form during writing; all six operations see the activity style,
never see a normal bar at 98, and publish valid outputs. Original source hashes
remain unchanged and both private runtimes are removed. Reports:

- `G:/HL-b14-external/sealed-native-progress-Win64-r1483/report.json`
- `G:/HL-b14-external/sealed-native-progress-Win32-r1483/report.json`

These are real worker/form observations, not a claim that every uncounted codec
now supplies its own page or byte counter. Final production Main/Reader builds,
ordinary Main selection and release packages retain their separate gates.

The automated IDE invocations preceding the UI build timed out without terminal
compiler reports; they are not successful builds. Opening/building the same
owned project through the normal interface supplied a compiler report. The
initial observer needed an explicit string cast for a VCL caption alias; that
test-only compile error was fixed before the successful builds and executions.
The temporary IDE session was closed afterward.

## Large PDF finish budget

The bounded PDF deadline is now five minutes, matching the native advanced
writer budget. The previous four minutes can expire after pagination has
finished but before the PDF stream/outline has been written. A behavioral test
permits the print checkpoint at 250 seconds and rejects it at 301, retaining
the input and publishing no partial output. The complete advanced-output suite
passes twelve methods with three explicit installed-writer skips (15 total):
`G:/HL-b14-external/pdf-deadline-unit-r1479.log`.

Fresh unpublished EpubPdfExport 3.0.0.9 candidates with this change are in
`G:/HL-b14-external/epub-pdf-packages-r1480/`. They are distinct from the earlier
same-version candidate in r1462; existing reports bind their actual package
hashes. The native progress cohort above uses the new package.

A diagnostic-only longer-deadline run of the real LRF omnibus produced a
1246-page PDF in approximately 259 seconds. Independent pypdf readback found
all 668,971 expected reading-order words, no missing words and all fourteen
visible images. Thirteen images match full RGBA pixels. The remaining image
has equal alpha and differs only in RGB values under fully transparent pixels;
composites on black/white match, so its appearance on any background is equal.
The initial stricter raw-pixel report is retained, alongside that explanation:
`G:/HL-b14-external/lrf-pdf-independent-r1482/visible-content-summary.json`.

That diagnostic used an instrumented host and is not a sealed native pass.
The current sealed x64 long-book run is `sealed-native-lrf-pdf-Win64-r1483`;
its result, the x86 long-book check and the remaining x86 full matrix still
need to be collected/completed. No Desktop application or public asset changed.

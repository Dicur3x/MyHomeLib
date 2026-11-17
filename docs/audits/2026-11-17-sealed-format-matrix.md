# Sealed components: actual format regression matrix

The current module cohort was tested on the 26 frozen original copies retained
by the native byte-identity probe. These are bounded copies from the real
collection, including WRI, LRF and HA; they are not 26 synthetic fixture files.
Their hashes match the previous source inventory. No live library archive or
catalogue was opened during this run.

Each architecture's embedded Python ran eleven directions: FB2, EPUB, MOBI,
AZW3, EPUB 2/3, KEPUB, KFX, AZW8, PDF and Markdown. There were no Python source
overlays. All 1,211 installed manifest files on Win64 and 1,210 on Win32 matched
their sealed packages. The fresh component cohort is recorded in the report,
including BookProcessing/ImageProcessing 3.0.0.14, XPS 3.0.0.6,
KindleExport/EpubPdfExport 3.0.0.9, KfxExport 3.0.0.6 and LegacyBooks 3.0.0.6.

## Observed results

| Per architecture | Backend outputs passing | PDF identity checked separately | Outer test timeout |
| --- | ---: | ---: | ---: |
| Win64 | 284 | 1 | 1 |
| Win32 | 284 | 1 | 1 |

All 72 cells that failed the initial r1364/r1365 baseline now produce valid
outputs. This confirms the previously implemented fixes in a coherent sealed
cohort; it is not a claim that 72 new defects were fixed in this step.

Successful FB2 is parsed as XML; EPUB-family outputs pass ZIP CRC, mimetype,
container and package checks; MOBI/AZW3 and PDF have their format signatures
checked. Production writer validators also run. KFX/AZW8/Markdown here have
output-existence/size checks in addition to their production validators.
These checks do not independently prove the complete prose, image pixels or
links of every output. The separate real CHM/LIT/DOCX cohort independently
confirms 18 PDF/KFX/AZW8 outputs; see the [writer audit](2026-11-17-independent-writer-content.md).

All 26 frozen inputs remain byte-identical. Both private processing runtimes
were removed. Work and temporary files stayed on G:, E: was unused, and C:
retained its required reserve. No Desktop installation or public asset changed.

## Large LRF PDF follow-up

Both LRF-to-PDF cells hit this probe's outer 240-second limit. The actual source
is a Sherlock Holmes omnibus with about 669,682 words and a 4.25 MB XHTML body,
not an ordinary short chapter fixture. Its other ten directions succeed. The
original baseline had produced its PDF in 164.625 seconds on Win64; the new
parallel timeouts alone do not identify a decoder or layout defect.

At that probe the production PDF path had its own four-minute layout deadline
and cleanup grace period. The serial follow-up separates that deadline from
the native process memory ceiling. The two original parallel timeouts remain
timeouts in the original matrix.

The first serial native x64 run (`sealed-native-lrf-pdf-Win64-r1475`) reaches
the real PDF host and fails with `Value does not fall within the expected range`.
The source remains unchanged, no successful PDF is claimed and the private
runtime is removed. Thus the outer parallel timeout was not sufficient to
diagnose the remaining problem. A diagnostic-only host adds phase/page counts
and a complete exception stack in `lrf-pdf-diagnostic-host-r1477`; its modified
binary is not used as sealed-component evidence.

The subsequent production fix gives browser PDF writing a bounded 2 GiB
per-process budget and five-minute deadline. Serial sealed native exports now
pass on x86 and x64. Independent full readback of both actual PDFs confirms
all 1246 pages, all 668,971 reading-order words and fourteen visible images.
See the [bounded-memory follow-up](2026-11-17-large-pdf-memory-budget.md)
for package/binary hashes, measured memory, preserved failed runs and the
transparent-pixel-only difference in one image.

## Evidence and next checks

- Consolidation: `G:/HL-b14-external/sealed-all-formats-validation-r1469/summary.json`.
- Current reports: `sealed-all-formats-Win64-r1468/report.json` and
  `sealed-all-formats-Win32-r1468/report.json` under that evidence root.
- Frozen driver: `G:/HL-b14-external/sealed-all-formats-r1468.py`.
- Retained intermediate LRF and measured content:
  `G:/HL-b14-external/lrf-pdf-diagnosis-r1472/`.

The native fixture now accepts an explicit `outputs` array per real input;
omitting it retains its previous TXT/FB2.ZIP/original test behavior. Fresh
x64 and x86 builds succeeded with the new feature marker. The first x86 IDE
invocation timed out without a terminal compiler report; its clean retry
finished successfully in 21.5 seconds. The native guard correctly rejected an
initial private driver with the wrong temporary-folder prefix (`r1474`); the
driver was corrected to use the existing isolation contract without changing
the guard. Native advanced directions,
large-LRF diagnosis, remaining source/content classification, ordinary Main
selection and final production/update packages still have separate gates.

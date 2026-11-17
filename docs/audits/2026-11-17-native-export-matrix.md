# Native TXT, FB2.ZIP and original-source matrix

The native `SaveFileBooks` worker was exercised on the same bounded real payloads
representing 26 content-detected families. `CollectionNativeExportTests.inc`
adds a dedicated mode to the isolated VCL regression executable. Its JSON input
lists owned source paths, source hashes, book IDs and detected families. Inputs
must remain inside its private `native-export-matrix/sources` directory.

This covers the actual native worker and progress form, UTF-8 TXT, FB2.ZIP and
unchanged-source saving. It is not the ordinary Main save-dialog selection flow,
an original external-archive/FLibrary preparation test, or final package proof.

## Results

| Per architecture | Sampled source families | Successful native operations | TXT operations needing OCR |
| --- | ---: | ---: | ---: |
| x64 | 26 | 70 | 8 |
| x86 | 26 | 70 | 8 |

Each architecture has 78 distinct cells: three saving directions for each input.
All 26 FB2.ZIP outputs and all 26 unchanged-source copies succeeded; 18 TXT
outputs succeeded. The retained original copies match their source SHA-256
exactly. Every successful ZIP passed CRC checking and contains exactly one
parseable FB2; its embedded raster resources were decoded by the independent
inspection script. All source payload hashes remained unchanged.

For each successful TXT output, its full word counts/order were compared with
the corresponding FB2 reading bodies. All 18 pairs per architecture are
consistent, with no missing words. This is a cross-output consistency check,
not independent proof that every original source was decoded completely.

For CHM and LIT, both TXT and FB2.ZIP also pass the separate original-source
word-order/count reference from the legacy-export audit. FB2.ZIP retains the
referenced CHM illustration and explicit LIT cover pixels. These are four
independently checked converted outputs per architecture; the remaining original
copies are independently verified by their byte hashes.

## Confirmed TXT gap

The actual DjVu, CBZ, CBR, RGO, GIF, JPEG, PNG and TIFF samples have no usable
text layer, or store lettering as outlines. Their TXT operation reports that
recognition is required rather than reporting a successful text export. Their
FB2.ZIP/image-preserving outputs and unchanged-source saving work.

Consequently, the requirement for every book input to support every offered
direction remains open. TXT for these image-only books needs OCR; these sixteen
cross-architecture cells are not passing conversions or completed support.

## Matching legacy component

The first x64 development runtime overlaid the repaired GPL `legacy_helper.py`
onto a previously sealed LegacyBooks package. Native integrity checks correctly
rejected that mismatch for LIT/LRF and requested LegacyBooks. The decoder and
availability checks were not bypassed.

Fresh LegacyBooks 3.0.0.6 candidates were packaged with the current helper and
hash-verified original native/vendor payloads, including their licences. Their
descriptors bind the new helper hash. A focused x64 rerun passes all six LIT/LRF
native operations with this package; the x86 run uses the sealed package for all
26 inputs. The combined x64 results replace those two rows rather than counting
duplicate original-copy cells twice. These module candidates are not published.

## Evidence

- Consolidated receipt, classifications and 36 consistency comparisons:
  `G:/HL-b14-external/native-export-validation-r1417/summary.json`.
- x64 initial probe: `collection-native-export-Win64-r1411/report.json`.
- x64 sealed-component LIT/LRF rerun:
  `collection-native-export-Win64-r1414/report.json`.
- x86 sealed-component full probe:
  `collection-native-export-Win32-r1415/report.json`.
- Verified module candidates: `G:/HL-b14-external/legacy-books-packages-r1413/`.
- Frozen private drivers: `collection-native-export-r1411.py` and
  `collection-native-export-r1414.py` under the same evidence root.

All reports bind the native binary, test source, Python overlays, module inputs
and artifact hashes. Both architectures use the same native test source and
Python overlay. The successful x64 binary hash is
`bb311c62d4aba3f598780a40db0a759eff931bdb0df31fcde737d28ef3479e26`;
the x86 binary hash is
`f41f3ffe8e29c15248e0b2d2363a141e00058e11be49c165a942467cc98982e3`.
The initial x86 IDE attempt timed out without a terminal compiler report; the
fresh documented AutoBuild retry completed successfully and supplied this binary.

All three private test runtimes were removed. The unrelated owned diagnostic
runtime from `kindle-legacy-diagnosis-r1399` remains after automatic cleanup was
rejected with no detailed reason; the denied deletion was not retried. E: was
not used, and C: remained above the required 8 GiB reserve.

Independent source references for other formats, OCR, native cancellation and
remaining directions, unclassified/nested/oversized groups, archive/FLibrary
preparation, ordinary final Main/Reader UI and coherent release packages remain
open. Desktop and public release assets were not changed.

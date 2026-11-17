# Independent PDF and KFX content checks

Separate readers inspected the previously backend-only writer cells for the real
DOCX 809647, CHM 776538 and LIT 732247. Original source references remain the
frozen XML/HTML event oracles from the preceding export audits. No OCR is used.

KFX/AZW8 are decoded by John Howell's unmodified GPL KFX Input 2.34.2 library,
downloaded from the calibre plugin repository. Structural checks, position and
location maps, and EPUB reconstruction run before comparison of the full source
word counts/order and decoded illustration pixels. The library is a test-only
dependency, outside the application and its shipped runtime.

PDF is inspected by an isolated pypdf 7.1.0 wheel, checked against its PyPI hash.
All pages are read, their complete extracted text is compared with the original
source word sequence/counts, and embedded images are independently decoded.
This does not establish physical Kindle compatibility or final GUI packaging.

## Observed results

| Source | PDF | KFX | AZW8 |
| --- | --- | --- | --- |
| Real DOCX | Pass after soft-hyphen repair | Pass | Pass |
| Real LIT | Pass | Pass | Pass |
| Real CHM | Pass | Missing referenced illustration | Missing referenced illustration |

Both architectures give the same result: seven independently confirmed outputs
and two remaining failures each, fourteen successful cells across x86/x64.
The CHM/LIT source images and all original prose are checked; this DOCX has no
embedded image resources. Its original text consists of 18,993 words.

## PDF repair

The DOCX contains 375 `w:softHyphen` elements. The intermediate EPUB preserves
these discretionary hints, but Chromium's printed PDF text layer turns them
into spaces, splitting 375 source words. The PDF preparation now removes only
U+00AD from body text/tails in its private served copy. Actual hyphens, element
IDs, URLs, other book parts and the original ZIP bytes are retained. Cancellation
and the operation deadline are checked during this preparation.

The final real DOCX PDFs contain all 18,993 source words in their original order,
with no missing words, on x86/x64. The relevant unit suite passes eleven methods
with three explicit installed-writer skips; real rendering/readback is proved
separately by the focused runtime reports.

The development matrix originally copied current Python sources only into
`tools/bookconvert`, while the PDF bridge actually loads from `tools/epub-pdf`.
The runner now overlays and records that real optional-module location too.
This is a development overlay, not a sealed release component. The final
EpubPdfExport package still needs a new version and its native update checks.

## Remaining CHM image failure

The referenced 88 × 31 GIF has six frames. KFX contains GIF bytes, but the
independent reconstructed EPUB has no image reference or image manifest item;
the resource symbol is reported unused. Investigate the writer's content/link
handling instead of assuming that GIF is unsupported or flattening its frames.
The pinned writer has a GIF format symbol. A temporary static-GIF conversion
draft was rejected and removed from the working tree; animation was not silently
discarded to make the checks pass. These four cells remain open.

## Evidence

- Consolidated result: `G:/HL-b14-external/independent-writer-validation-r1431/summary.json`.
- Initial real cohorts: `independent-writer-content-Win64-r1420/report.json` and
  `independent-writer-content-Win32-r1421/report.json` under that evidence root.
- Latest PDF bridge cohorts: `independent-writer-content-Win64-r1434/report.json`
  and `independent-writer-content-Win32-r1435/report.json`.
- Unit log: `G:/HL-b14-external/pdf-soft-hyphen-unit-r1432.log`.
- Reader archive, wheel, source metadata and hashes:
  `G:/HL-b14-external/independent-readers-r1419/`.

All final private runtimes were removed; source hashes remained unchanged.
The standalone OCR package downloaded before the user's deferral was removed;
OCR integration is not part of beta 14. E: was not used and C: retained its
8 GiB reserve. Other formats, native final UI, cancellation, coherent packages
and release gates retain their separate completion criteria.

Primary reader/API reference:
[Boko's pinned independent kfxlib checker](https://github.com/zacharydenton/boko/blob/9ac23f67a51e6911125a78fc0f876c8367388f3d/tools/kfxcheck.py).

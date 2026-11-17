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
| Real CHM | Pass | Pass after linked-image repair | Pass after linked-image repair |

Both architectures now give nine independently confirmed outputs each: eighteen
successful cells across x86/x64, using fresh sealed components without source
overlays. The four previously failing CHM KFX/AZW8 cells are closed.
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
This was development-overlay evidence. The current sealed EpubPdfExport 3.0.0.9
package independently passes the same real-book checks on both architectures;
native application update checks remain separate.

## Initial CHM image failure and repair

The referenced 88 × 31 GIF has six frames. The initial KFX contained GIF bytes,
but the independently reconstructed EPUB had no image reference or image
manifest item; the resource symbol was reported unused. This directed the
investigation to the writer's content/link handling instead of assuming that
GIF was unsupported or flattening its frames.
The pinned writer has a GIF format symbol. A temporary static-GIF conversion
draft was rejected and removed from the working tree; animation was not silently
discarded to make the checks pass. At that checkpoint four cells remained open.

### Linked-image repair and the user's subsequent GIF decision

The pinned writer flattens link/inline subtrees into text-only segments and
silently skips image leaves. The new patch retains image nodes and inherited
links, splitting neighboring text into separate runs so a KFX element does not
mix a text reference with image children. All 34 storyline tests pass on x64,
including new nested-link/text/image and image-only-link cases. Applying the
complete patch to pristine pinned sources reproduces the tested UTF-8 source.

The production x86/x64 builds were deliberately stopped when system free space
fell below 8 GiB (observed 7,963,721,728 bytes). Their nonzero exits are not
successful build evidence. Sources, toolchains and build work stay on G:.
At that checkpoint the new runtime packages and independent real-book readback
were pending. The chosen KfxExport version was 3.0.0.6; the corresponding-source
archive received a distinct versioned name rather than replacing the published
source ZIP.

After this investigation the user explicitly chose a static GIF result for
beta 14 export: one frame, with original source files unchanged. That conversion
was then implemented and validated as described below. The earlier rejection of an
unapproved static conversion remains a historical observation, not the current
product decision. Do not claim that preserving an animated resource establishes
animation support on a physical Kindle. After beta 14, count GIFs and animated
GIFs in the actual collection before deciding whether to add animation or
frame-by-frame export choices; frequency has not been measured.

Evidence: `G:/HL-b14-external/kfx-inline-images-r1438/storyline-tests-cc.log`,
`G:/HL-b14-external/kfx-patch-check-r1441/` and
`G:/HL-b14-external/kfx-module-build-r1442/aborted-for-system-reserve.json`.

### Current sealed result

The linked-image patch and static-first-frame policy are now built and tested.
KfxExport 3.0.0.6 was compiled successfully for Win64 (`kfx-module-build-r1454`)
and Win32 (`kfx-module-build-r1459`). The Win32 environment required the official
`rust-mingw` target component in addition to `rust-std`; this is documented in
the versioned corresponding-source archive. Its contents and checksums were
verified, and its build script and patch match both runtime packages.

The sealed cohort installs fresh BookProcessing 3.0.0.14, ImageProcessing
3.0.0.14, XPS 3.0.0.6, KindleExport 3.0.0.9, EpubPdfExport 3.0.0.9 and
KfxExport 3.0.0.6, plus LegacyBooks 3.0.0.6 and pinned unchanged dependencies.
All 1,211 installed manifest files on Win64 and 1,210 on Win32 match their
packages. Both source-overlay maps are empty; conversion runs under the
architecture's embedded Python. Independent readers then check all 18 outputs.

The CHM KFX/AZW8 readbacks retain both linked image occurrences, all source
words/order and the first frame's exact decoded pixels. The original GIF has
six frames; the exported PNG has one. Source file hashes remain unchanged.
This closes these specific writer failures, not the all-format matrix, native
GUI/update tests, physical devices or final release gates.

## Evidence

- Current result: `G:/HL-b14-external/sealed-writer-validation-r1467/summary.json`
  (`PASS_SEALED_INDEPENDENT_CONTENT`, 18 passed, 0 failed).
- Current per-architecture reports: `sealed-writer-content-Win64-r1464/report.json`
  and `sealed-writer-content-Win32-r1465/report.json` under the same evidence root.
- Corresponding source: `kfx-corresponding-source-r1466/Boko-0.6.0-HomeLibre-source-3.0.0.6.zip`,
  SHA-256 `16a680fb0fd1ed866a4259dc19171df6207d8fd04e25c1855310238d87e73fb1`.
- Earlier failing result: `G:/HL-b14-external/independent-writer-validation-r1431/summary.json`.
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

# Working collection: bounded format inventory

## Scope

The active Desktop collection was inspected read-only, without launching the
application or changing its catalogue, personal database, archives or books.
This is an inventory for the outstanding compression-format work, not a claim
that every format can already be recompressed or that every book was validated.

Evidence is in `G:/HL-b14-external/working-format-inventory-r652/`:

- `catalogue-inventory.json`: counts and bounded candidate selection.
- `payload-samples.json`: exact-member extraction attempts, detected types,
  sample hashes, container/image counts and cleanup result.

The catalogue is 4,521,861,120 bytes and contains 1,115,159 active cards.
Its extension field has 90 stored spellings, or 84 after case folding.
These are not 84 distinct book formats: the field also contains archive/audio
suffixes, numeric names and malformed fragments of file names.

## Method and limits

- No HomeLibre/legacy catalogue or Reader process was running at the initial
  check; the catalogue WAL was empty. SQLite used `mode=ro&immutable=1` and
  `query_only=ON`. Size, modification time and file identity were unchanged.
- Grouping explicitly used binary collation. Python cannot substitute the
  application's `MHL_SYSTEM_NOCASE` collation. An initial per-extension query
  failed for that reason; a later unindexed per-extension approach was stopped
  at 45 seconds. Neither failure wrote to the source.
- One streaming pass selected candidates, followed by one query for their
  physical-copy paths. This avoided repeated whole-catalogue scans.
- An initial smallest-file selection found tiny FLibrary payloads, so a second
  pass selected up to three candidates per suffix between 2 KiB and 16 MiB,
  preferring accessible G: sources and sizes near 128 KiB. That pass took
  4.797 seconds and yielded 142 candidates for 77 suffixes.
- Extraction required an exact or unique case-insensitive member name. The
  stored member number was never used to guess a different book. Python ZIP
  reads were bounded to 16 MiB; unsupported ZIP compression/7z could use the
  existing 7-Zip helper with the same output limit and a 12-second deadline.
- Source archives were opened for reading. Their size, modification time and
  identity were checked before/after and again after sampling; this is not a
  cryptographic hash of every complete archive.
- All extracted payloads were temporary files on G: and were removed. The
  system-drive reserve remained above 8 GiB. No book content was executed and
  no URL embedded in a document was followed.

The bounded payload run finished in 5.750 seconds and sampled 60 suffix groups.
Seventeen eligible groups had no exact unambiguous member under the catalogue
name; seven other groups had no record within the candidate-size bounds.
Those 24 groups remain unclassified here. A missing exact match is not evidence
of a product defect without checking the application's filename resolution.

## Findings

Actual payloads confirmed FB2, EPUB, PDF, DjVu, DOCX, ODT, CBZ, compound Office
DOC/PPT, RTF, Kindle/Palm-family data, CHM, LIT, RGO, LRF, HTML and raster images.
RAR and 7z signatures establish archive containers, not that each archive is a
comic. ZIP contents and an MPEG audio signature were also observed.

Several unusual suffixes belong to ordinary supported families:

- `.epup` contains an EPUB ZIP with its container marker.
- `.fb` contains FB2 XML.
- `.gdoc` contains a PDF; no cloud-document link was followed.
- Several numeric suffixes contain PDF or DjVu, and another contains ZIP.
- `.dio`, `.jog`, `.lead` and `.sepia` samples contain DjVu.
- `.prc`, `.azw` and `.azw3` samples have the `BOOKMOBI` family signature;
  that signature alone does not establish the exact Kindle variant.

The converter's returned extension is retained in the report, but unknown
binary suffix fallbacks and plain-text recognition are explicitly distinguished
from confirmed container signatures. Sixty sampled suffixes therefore do not
mean sixty independently verified codecs.

Image-container examples make useful next work concrete:

| Actual sample | Image entries | Uncompressed image bytes |
| --- | ---: | ---: |
| EPUB | 1 | 53,573 |
| ODT | 2 | 69,658 |
| CBZ | 23 | 3,128,092 |
| DOCX | 0 | 0 |

These are sample resource sizes, not predicted physical disk savings or totals
for their formats. An illustrated DOCX still needs a suitable sample before
using it to assess image compression.

## Consequence for beta 14

Keep the format work open. Existing FB2/EPUB and partial PDF/DjVu coverage does
not provide general image optimization for ODT, DOCX or CBZ. ODT/CBZ are now
confirmed useful candidates for format-preserving handlers; unsupported books
must continue to retain their original bytes. Remaining work also includes the
unclassified names, an isolated working-catalogue compression trial and final
application/package validation. No production worker or package changed in
this inventory step; the latest BookProcessing candidate remains r647.

## November 17 evidence reconciliation

The later final historical coverage report supersedes its partial summary:
187 paired inputs across 131 suffix spellings, ten nonbook/incomplete groups
and the interactive SM. Every one of the current 84 spellings occurs in these
categories. The 24 unsampled groups in this bounded inventory therefore are
not 24 newly discovered codecs. This mapping does not assert matching identity
for each current book or retest every advanced output. Current native/coherent
component results and their limits are recorded in the
[reading/export audit](2026-11-17-reading-export-coverage.md) and
`G:/HL-b14-external/format-evidence-reconciliation-r1507/report.json`.
The original inventory above remains a record of what that particular run did.

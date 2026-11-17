# Reading and export coverage for beta 14

The release requirement is to open every actual book format represented in the
working collections and support its offered export directions. Catalogue covers,
Reader opening, conversion preparation and successful reading of an exported
book are separate checks. A cover-only fix must not be presented as proof that
a previously unsupported book format can now be read or exported.

The required directions are FB2, FB2.ZIP, EPUB, TXT, MOBI, AZW3, EPUB 2, EPUB 3,
KEPUB, KFX, AZW8, PDF and Markdown, together with unchanged-source saving.
Check content detection for incorrect suffixes, selected archive members and
FLibrary reconstruction before the writer. Image-only sources remain readable
as pages; converting them to editable prose requires OCR and is not implicit in
export. SM preserves the explicitly chosen reading branch, not every possible
interactive path. Damaged/incomplete/encrypted data and nonbook catalogue entries
must have an accurate diagnosis rather than a successful but incomplete book.

## Current inventory and earlier evidence

The November 17 read-only inventory in
`G:/HL-b14-external/reading-export-matrix-r1363/inventory.json` contains 1,115,159
active catalogue cards, 90 stored extension spellings and 84 case-folded suffixes.
It took 12.39 seconds; source catalogue size, modification time and file identity
were unchanged. SQLite used read-only mode, query-only and memory-backed temporary
sorting. Only the report was written, on G:.

Those 84 suffixes are not 84 independent book codecs: they include numeric or
mistyped names, archives, an interactive format, audio and other nonbook entries.
The earlier bounded payload inventory established 60 suffix samples, with 24
unclassified or unavailable groups; it was a content inventory, not a complete
reading/export matrix. See
[the working-format audit](2026-11-15-working-collection-formats.md).

Current `BOOK_EPUB_INPUTS` declares 82 input suffixes including aliases. That is
a routing declaration, not 82 verified format implementations. OpenXPS is
detected by content and normalized to the XPS route. The native save dialog has
six basic and seven advanced choices; TXT and FB2.ZIP use native save paths in
addition to the converter backend.

Earlier reading and FB2/EPUB checks remain valid within their recorded cohorts.
For example, `docs/audits/2026-11-08-post-beta7.md` records 133 paired inputs from
78 suffix groups, subsequent rare-format checks and fixes, and separate
MOBI/AZW3/advanced-writer trials. The retained
`G:/HomeLibRu-build-cache/HomeLibre-bug-audit-20261107/usr-tail-sweep-20261109/verified-partial-summary.json`
currently records 167 paired inputs and 111 suffixes, plus 31 remaining suffixes
in that historical inventory. Its outcomes include explicit expected failures;
the totals must not be reported as 167 successful complete books. Separate
nonbook evidence contains 49 records, including incomplete/damaged sources.
The dated notes and historical test binaries do not establish every output
direction for the current source/package cohort.

## OpenXPS follow-up

The former XPS helper rejected OpenXPS markup. The
[OpenXPS implementation and tests](2026-11-17-oxps-cover-preview.md) close that
specific gap for the tested synthetic files: native catalogue preview, full
FB2/EPUB conversion, embedded fonts and image resources. The consolidated report
independently checks page colors and order in four FB2/EPUB outputs across both
helper architectures.

The subsequent backend probe
`G:/HL-b14-external/oxps-export-directions-r1362.py` writes its reports to
`oxps-export-directions-r1362/Win64.json` and `Win32.json`.
It creates an isolated runtime from six hash-pinned component packages,
explicitly overlays current converter sources and the newly built XPS/image
helpers, and processes a two-page OXPS through all 11 backend directions:
FB2, EPUB, MOBI, AZW3, EPUB 2/3, KEPUB, KFX, AZW8, PDF and Markdown.
Both architectures produced all 11 outputs without converter/writer errors.
Each writer's production output validator ran; the original OXPS hash was
unchanged and both private runtimes were removed. Report SHA256 values are
`7ba8a1dded9847c1324b2f438fac2335f1d038d1c8f909c96266d81863169b6f`
and `ff7bbe90f745aa3d2c01b8a2e15406dc3cf6bbfc1782913f85c7c3015f47a015`.

This is backend evidence with recorded package/source identities. It is not
independent content verification of every generated format, a complete ordinary
save-dialog/Reader test, TXT/FB2.ZIP coverage, or proof of final release packages.
No public asset or Desktop installation changed. All test work stayed on G:,
E: was unused and C: retained its 8 GiB reserve.

## Remaining completion criteria

- Reconcile the current actual payload families and archive/incorrect-name cases
  with the earlier native results. Resolve the unclassified book inputs rather
  than treat each unusual suffix as a new format or silently drop it.
- For each supported family, exercise every offered direction with matching
  current x86/x64 components. Verify text, chapter order, image references,
  links, page count where applicable, source preservation and cancellation.
  Read or independently inspect results; file existence is insufficient.
- Exercise the actual Reader and ordinary save command, including native TXT
  and FB2.ZIP paths, selected archived books and missing-module continuation.
  Physical Kindle/Kobo compatibility remains unverified without those devices.
- Fix discovered decoder/writer/UI gaps, then validate the final production apps
  and packages. Keep the matrix open until these conditions have evidence.

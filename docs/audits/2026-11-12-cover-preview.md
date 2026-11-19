# Catalogue covers after beta 13

The catalogue now reads declared EPUB cover images and package thumbnails, and can display a bounded first-page preview for raster books, in its existing background preview worker. It does not launch the Reader or convert a book just to display its cover. Existing sidecar and FB2/FBD paths retain precedence. This is a local change for beta 14; it has not been published.

## Format matrix

| Format or source | Catalogue path | Evidence and remaining scope |
| --- | --- | --- |
| FB2 and matching FBD descriptors | Existing description and cover reader | Direct FB2, ZIP member selection with the correct FBD, nested UTF-8 paths, ambiguous members and unchanged-source checks pass on x86/x64. |
| EPUB2 and EPUB3 | New package reader: metadata cover ID, `cover-image`, then guide cover page | Exact extracted bytes and actual catalogue images pass for three supplied EPUBs and generated fixtures. XHTML/SVG wrappers may refer to an internal raster image. |
| EPUB inside ZIP or 7z | Existing selected-member extraction, followed by package reader | Correct embedded cover, unchanged outer archive and responsive selection pass on x86/x64. |
| Word DOCX/DOCM/DOTX/DOTM; PowerPoint PPTX/PPTM/POTX/POTM/PPSX/PPSM; Excel XLSX/XLSM/XLSB/XLTX/XLTM | Optional OPC thumbnail relationship in `_rels/.rels` | Generated fixtures for each extension pass. An actual PPTX thumbnail also passes in the catalogue panel. Actual DOCX/XLSX samples with no declared thumbnail return an unavailable-preview explanation; no arbitrary document illustration is substituted. Other real document variants remain to be checked. |
| OpenDocument ODT/OTT/ODM/ODP/OTP/ODS/OTS/ODG/OTG/ODF | Optional `Thumbnails/thumbnail.png` | Generated fixtures for each extension and an actual ODS thumbnail pass. Other real document variants remain to be checked. |
| FB3 | Optional OPC thumbnail relationship | The November 19 check below covers all 17 FB3 archives in the upstream examples and converter test data. The catalogue displays the three available declared covers, including the SVG with a mixed-case filename. |
| FLibrary companion covers | Existing separate-cover reader with bounded decoding | Actual JPEG and JPEG XL companion covers pass on x86/x64, with independent reference pixels, cancellation and no whole-FB2 extraction. Both Windows and INPX-style path separators are accepted. |
| Pure vector SVG covers | Static rendering through the KFX/AZW8 module's resvg helper | Static SVG, inline drawings, composition and bounds now pass native x86/x64 cases; see the [SVG follow-up](2026-11-18-svg-cover-preview.md). Separate stylesheets and unsupported/active resources retain an explicit explanation. |
| DjVu | First page through the existing isolated DjVu decoder when installed | Three documentation samples from the installed DjVuLibre 3.5.29 source archive and an invalid file pass on both app architectures. The decoder is closed after the preview. |
| PDF | Matching FBD, otherwise page zero through the existing isolated PDF worker | Generated two-page and 500-page files, a PDF inside ZIP, a real local PDF, damaged files and missing-module behaviour pass on x86/x64. A matching PDFium module is required; selecting a row does not start installation. |
| XPS/OXPS | Matching FBD when supplied | Rendering a first-page preview from the book itself remains open. |
| CBZ/CBR/CB7 and image-only ZIP/7z/RAR archives | First naturally ordered page using the existing raster decoder | Generated CBZ/CB7, ordinary ZIP/7z and an actual CBR/RAR book from the local collection pass. Later damaged pages are not decoded. Generic archives must contain only image pages and supported comic metadata; an archive containing a document is rejected as a comic. |
| Standalone JPG/JPEG/PNG/GIF/BMP/TIF/TIFF | Scaled first image/frame | Direct files, multi-frame TIFF, PNG bytes with a JPG extension, large JPEG/PNG, orientation, invalid images and damaged FBD sidecars pass. |
| WebP/JPEG XL image codecs | Existing optional conversion helper | WebP standalone images, mismatched JPG extensions, CBZ pages and EPUB covers pass on x86/x64. Actual FLibrary JPEG XL covers pass against independent pixel references. Missing-codec behaviour remains separate from codec-present checks. |
| Kindle MOBI/AZW/AZW3/PRC | No new direct cover extractor | Do not start whole-book Kindle conversion when the user selects a row. Direct metadata/cover extraction remains open. |
| TXT, RTF, HTML, Markdown, old office and other legacy formats | Matching FBD when supplied | A format may have no dedicated cover field. Audit actual metadata and thumbnail conventions before promising previews. |

## Limits and behaviour

ZIP entries are streamed with CRC checking and limits on actual decompressed bytes: 2 MiB for XML and 16 MiB for a cover part. XML disables DTDs and external entities. Cover paths remain within the package; URI decoding preserves literal plus signs. Duplicate exact entry names, external paths, traversal, corrupt data, missing images and loops produce a status instead of a stale cover. Decoded catalogue cover memory is capped at 64 MiB. Pure SVG is not passed to a raster decoder with unresolved external references.

Raster previews prepare page zero at a maximum edge of 600 pixels. Compressed comic pages are rejected above 32 MiB, with a second limit on actual decompressed output. Finished BGRA pixels cross the worker boundary; the UI creates the bitmap. Top/bottom row fixtures verify orientation. Generic archives use the same image-only classification and natural page ordering as the Reader. Cancellation checks also cover page enumeration and sorting. A broken FBD sidecar reports its metadata error without suppressing the readable first page.

PDF previews use `TReaderPDFWorker`, without opening a Reader window or entering the Reader UI's PDFium state. Only page zero is rendered at an edge of 600 pixels. Its private job, process, pipes and file handles are released after the preview or cancellation. Missing PDFium is detected before extracting a large archived PDF; the catalogue displays a module explanation instead of prompting to download it.

Ordinary archived payloads stream straight to a leased disk cache instead of first materializing the complete book in a memory stream. FLibrary's FB2 and 7z PDF reconstruction retain their existing path. Empty payloads are rejected before publishing the cache. Legacy FBD wrappers resolve only a unique matching payload; descriptor covers retain precedence over an embedded EPUB cover, ambiguous wrappers are not guessed, and HTML wrappers keep their linked resources together.

The existing generation check discards a late result from a previously selected book. Cancellation and caller stream position are tested. Optional image-codec errors are reported by the background worker without starting installation from a row selection.

## Local validation

`tools/ui/tests/test_package_covers.py` drives the native `CollectionViewsTest` executable. Each architecture passed 50 package cases plus cancellation, 18 catalogue-preview checks, four asynchronous FB2 preview checks, and updater theme checks. Adding four actual office documents raised the package cases to 54 and catalogue-preview checks to 20; both architectures passed. Separate clean profiles also passed the existing archive/FBD and image-allocation regressions.

The first combined archive-plus-image invocation reused a fixture database and failed on a duplicate test collection name before the image checks ran. Both modes then passed in separate private profiles. The failed logs are retained; this was not reported as a successful combined run.

The current raster cohort passed 30 native checks per architecture, including the real CBR, three DjVu samples, a damaged DjVu, a 4000×24000 PNG, a 64 MiB CBZ inside a ZIP, an empty archived payload, malformed metadata, colour/orientation checks and source-handle release. A separate run without archive tools copied into the private runtime passed 21 native checks. The complete package/FB2/theme suite was rerun on the same binaries. The large-scan raster run peaked at about 40 MiB for Win32 and 46 MiB for Win64 in the catalogue test process; this is not a measurement of the user's full loaded catalogue or of separate decoder processes. Ordinary FB2 preview still has its existing full-description parsing cost; these measurements do not claim that path was optimized.

The subsequent PDF extension passed 36 native raster/PDF checks per architecture, including the local 7 MiB PDF, first-page colours/orientation, the 500-page document, nested PDF, invalid input and exclusive reopening of source PDFs after rendering. The actual PDF page size is independently read through PDFium in the Python harness. Win32 and Win64 app runs use the corresponding pinned PDF worker and DLL. A run without optional archive/PDF modules passed 26 checks per architecture, including an explanation for unavailable PDF previews. Parent catalogue-process memory remained about 40/46 MiB; the isolated PDF process has its own memory usage. The package/FB2/theme regressions are recorded separately for these binaries.

Early raster runs caught a worker-created bitmap colour defect and an incorrect manual row reversal. The final implementation passes pixel buffers and uses VCL's visual row indices. Another reference run failed in the Python report because its comparison omitted the newly added comic source; it now verifies every original source hash. Failure logs are retained separately from passing reports.

Both application architectures ran on the current 64-bit Windows installation. The real RAR and DjVu cases used copies of the locally installed decoder binaries; this does not validate a separate 32-bit Windows installation or the final distribution packages.

Native updater checks sample actual window pixels for both white strips, enabled/disabled notification states, light-to-dark changes and 100/150/200/300 percent scaling. Both catalogue and Reader configurations pass. The shared component-release link is labelled for its actual destination.

Reports and native build receipts: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`. Test binaries include pending local UI/Reader work and are not a clean production release cohort. Temporary runtime profiles were removed. Original user books, catalogue and Desktop installation were not modified.

## FLibrary and codec follow-up

Private copies of a real FLibrary 7z container and its companion cover ZIP supplied matching JPEG and JPEG XL covers. Both references were independently decoded; WebP fixtures include a standalone image, a mismatched JPG extension, a CBZ page and an EPUB cover. Native follow-up tests also check sampled pixels, no full FB2 extraction, cancellation after the JPEG XL child actually starts, temporary-file cleanup, oversized side covers and forged ZIP sizes.

The cancellation callback reaches the catalogue, record helper and side archive. Encoded covers are bounded at 16 MiB; the cover-only JPEG XL process uses one thread with limits of 15 seconds, 512 MiB process memory and 128 MiB output. The full-book image-reconstruction path retains its existing options. Sidecar cover decoding in the catalogue uses the same 64 MiB pixel budget as embedded package covers.

The earlier AutoBuild timeouts were investigated through the actual IDE window. A failed-build dialog was waiting for acknowledgement before writing its log. The source had a nested procedure captured by an anonymous callback and a Windows DeleteFile overload shadowing SysUtils.DeleteFile. Both compilation errors were corrected; subsequent documented IDE builds completed normally. No compiler/licensing bypass or changes to other applications were used.

The first real FLibrary preview run then exposed a path-handling defect: Windows filename helpers ignored forward slashes in a nested INPX-style container path and therefore looked in the wrong companion-cover directory. Archive and member basename resolution now normalize both path separators before deriving companion locations. The previously failing `172792.fb2` JPEG XL cover now displays correctly, and the actual JPEG companion cover passes too.

The final native cohort passed on x86 and x64: 51 raw package cases plus cancellation, 26 catalogue/package checks, 31 raster/WebP checks, four existing FB2 asynchronous-preview checks and three updater-theme checks per architecture. The FLibrary checks include sampled pixels from independently decoded images, no full-FB2 extraction for a cover-only request, cancellation after the real JPEG XL decoder starts, cleanup of its temporary files, and rejection of oversized/forged ZIP cover entries. Original user EPUBs, FLibrary archive and companion ZIP retained their exact SHA256 hashes. Private runtimes were removed.

Reports: `codec-followup-Win32-final.json` and `codec-followup-Win64-final.json` in the existing evidence directory. The failed diagnostic logs remain distinct from the passing reports. These tests use locally installed libjxl 0.12.0 decoder binaries and the respective WebP DLL; the separate official 0.13.0 updater checks do not replace image-rendering tests. The changes are locally validated and unpublished; the remaining format rows and final production-package checks stay open.

FB3 sample source: [official FB3 examples](https://github.com/gribuser/FB3/tree/master/Examples), Git blob `e7e2714b3e1d9b1c6040f8b7914525f634030c8e` (verified before inspection).

## November 17 follow-up

The matrix above records the November 12 cohort. The subsequent
[XPS first-page preview](2026-11-17-xps-cover-preview.md) and
[declared MOBI/KF8 covers](2026-11-17-kindle-cover-preview.md) are now checked
locally on x86/x64. They do not establish OXPS, KFX/AZW8, pure vector SVG or the
remaining legacy/office variants. Final production-package validation is still
separate.

The subsequent [OpenXPS follow-up](2026-11-17-oxps-cover-preview.md) adds locally
validated OXPS first-page preview and conversion through the Windows XPS Object
Model. Both app architectures pass the embedded font, PNG/JPEG XR, first-page
and full-page-order fixtures. This supersedes the OXPS limitation above for that
tested cohort. Other real document variants and final release-package checks
remain open.

## FB3 and document thumbnails, November 19

The upstream FB3 Perl reader takes the package thumbnail as its cover.
The upstream FB2 converter writes that relationship when converting a book with
a cover. HomeLibre now compares ASCII letters in OPC part names without
regard to case. Multiple matching entries produce an ambiguous-cover error.
EPUB and OpenDocument retain their exact part-name matching.
[FB3 reader](https://github.com/gribuser/FB3/blob/92bdc0d1fe89d9ac122ad342fd3c4cdc81a11c24/api/perl/FB3/lib/FB3.pm#L80-L83).
[OPC part-name equivalence](https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/8.0/system-io-packaging-case-insensitive-uri).

All 17 FB3 archives in that upstream revision were checked against their Git
blob hashes. Three named an available image. The catalogue displayed the PNG,
the JPEG also used inside the book, and the SVG in `Hardcore file structure.fb3`.
That book names `cover/thumb.svg` in its relationship and stores `cover/thumb.SVG`.
The SVG's yellow background and white margin were sampled in the rendered cover.
The remaining 14 either omit the thumbnail relationship or point to a missing
part. Their previews cleared the preceding book's image and showed an explanation.
[Upstream FB3 examples and converter tests](https://github.com/gribuser/FB3/tree/92bdc0d1fe89d9ac122ad342fd3c4cdc81a11c24).

Six files from the installed LibreOffice 26.8.3.1 templates cover Draw (OTG),
Writer (OTT and ODT), Impress (OTP) and Calc (OTS). Three carried a thumbnail.
The images matched the sampled colours of their PNG parts. The other three
produced an empty preview with an explanation. The Office regression used
a DOCX with differences in both the relationship filename and thumbnail path.

Both x86 and x64 passed the package-reader and catalogue-panel checks.
The earlier x64 executable missed the generated FB3 mixed-case cover.
Inputs retained their original bytes. Manifests and logs for all 17 books and
six documents are in `G:/HL-b14-external/r1999-fb3-covers` and its
`libreoffice` directory.

## Embedded Office thumbnails in 19 source documents, November 19

The sample covers all 15 supported Office Open XML extensions. Six presentation
files declare JPEG thumbnails, three Word templates declare standard WMF drawings
and ten documents have no thumbnail. Each input matched its upstream Git blob.
[Open XML SDK test assets](https://github.com/dotnet/Open-XML-SDK/tree/431ab05cf160248cc3885a4a766026d4f8243792/test/DocumentFormat.OpenXml.Tests.Assets/assets).
[Apache POI test data](https://github.com/apache/poi/tree/f66927954a29cf1f5b86614fdf1816e6321c8aea/test-data).

The previous x64 build extracted the exact WMF from a Word template but left
the catalogue panel empty. These drawing files have a standard metafile header
without the optional placeable header. Package previews now read this form too.
On x86 and x64 all nine declared covers appeared in the catalogue. The three WMF
previews matched samples of the ink and paper from an independent rendering of
the embedded enhanced drawings. JPEG samples matched the declared images. All
ten documents without a thumbnail cleared the earlier preview and displayed an
explanation. A separate two-colour WMF verified drawing, the decoded image size
limit and rejection of truncated data. Source documents retained their original
bytes. Test manifests and receipts for both catalogue and reader builds are in
`G:/HL-b14-external/r2004-office` and `G:/HL-b14-external/r2005-office-build`.

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
| FB3 | Optional OPC thumbnail relationship | Declared-thumbnail fixture passes. The official FB3 sample contains a file named `Cover.png` without a thumbnail declaration; this change deliberately does not infer a cover from its filename. Other FB3 cover conventions remain to be investigated. |
| FLibrary companion covers | Existing separate-cover reader | Kept ahead of embedded-cover fallback; not newly revalidated against a real FLibrary collection in this run. |
| Pure vector SVG covers | No catalogue renderer yet | An explicit unavailable-preview status is returned. SVG wrappers containing an internal raster image do work. |
| DjVu | First page through the existing isolated DjVu decoder when installed | Three documentation samples from the installed DjVuLibre 3.5.29 source archive and an invalid file pass on both app architectures. The decoder is closed after the preview. |
| PDF, XPS/OXPS | Matching FBD when supplied | Rendering a first-page preview from the book itself remains open. Do not use the Reader's UI-thread PDFium state concurrently from this background worker. |
| CBZ/CBR/CB7 and image-only ZIP/7z/RAR archives | First naturally ordered page using the existing raster decoder | Generated CBZ/CB7, ordinary ZIP/7z and an actual CBR/RAR book from the local collection pass. Later damaged pages are not decoded. Generic archives must contain only image pages and supported comic metadata; an archive containing a document is rejected as a comic. |
| Standalone JPG/JPEG/PNG/GIF/BMP/TIF/TIFF | Scaled first image/frame | Direct files, multi-frame TIFF, PNG bytes with a JPG extension, large JPEG/PNG, orientation, invalid images and damaged FBD sidecars pass. |
| WebP/JPEG XL image codecs | Existing optional conversion helper | Dedicated catalogue preview checks with these codecs remain open; their Reader support alone is not proof. |
| Kindle MOBI/AZW/AZW3/PRC | No new direct cover extractor | Do not start whole-book Kindle conversion when the user selects a row. Direct metadata/cover extraction remains open. |
| TXT, RTF, HTML, Markdown, old office and other legacy formats | Matching FBD when supplied | A format may have no dedicated cover field. Audit actual metadata and thumbnail conventions before promising previews. |

## Limits and behaviour

ZIP entries are streamed with CRC checking and limits on actual decompressed bytes: 2 MiB for XML and 16 MiB for a cover part. XML disables DTDs and external entities. Cover paths remain within the package; URI decoding preserves literal plus signs. Duplicate exact entry names, external paths, traversal, corrupt data, missing images and loops produce a status instead of a stale cover. Decoded catalogue cover memory is capped at 64 MiB. Pure SVG is not passed to a raster decoder with unresolved external references.

Raster previews prepare page zero at a maximum edge of 600 pixels. Compressed comic pages are rejected above 32 MiB, with a second limit on actual decompressed output. Finished BGRA pixels cross the worker boundary; the UI creates the bitmap. Top/bottom row fixtures verify orientation. Generic archives use the same image-only classification and natural page ordering as the Reader. Cancellation checks also cover page enumeration and sorting. A broken FBD sidecar reports its metadata error without suppressing the readable first page.

Ordinary archived payloads stream straight to a leased disk cache instead of first materializing the complete book in a memory stream. FLibrary's FB2 and 7z PDF reconstruction retain their existing path. Empty payloads are rejected before publishing the cache. Legacy FBD wrappers resolve only a unique matching payload; descriptor covers retain precedence over an embedded EPUB cover, ambiguous wrappers are not guessed, and HTML wrappers keep their linked resources together.

The existing generation check discards a late result from a previously selected book. Cancellation and caller stream position are tested. Optional image-codec errors are reported by the background worker without starting installation from a row selection.

## Local validation

`tools/ui/tests/test_package_covers.py` drives the native `CollectionViewsTest` executable. Each architecture passed 50 package cases plus cancellation, 18 catalogue-preview checks, four asynchronous FB2 preview checks, and updater theme checks. Adding four actual office documents raised the package cases to 54 and catalogue-preview checks to 20; both architectures passed. Separate clean profiles also passed the existing archive/FBD and image-allocation regressions.

The first combined archive-plus-image invocation reused a fixture database and failed on a duplicate test collection name before the image checks ran. Both modes then passed in separate private profiles. The failed logs are retained; this was not reported as a successful combined run.

The current raster cohort passed 30 native checks per architecture, including the real CBR, three DjVu samples, a damaged DjVu, a 4000×24000 PNG, a 64 MiB CBZ inside a ZIP, an empty archived payload, malformed metadata, colour/orientation checks and source-handle release. A separate run without archive tools copied into the private runtime passed 21 native checks. The complete package/FB2/theme suite was rerun on the same binaries. The large-scan raster run peaked at about 40 MiB for Win32 and 46 MiB for Win64 in the catalogue test process; this is not a measurement of the user's full loaded catalogue or of separate decoder processes. Ordinary FB2 preview still has its existing full-description parsing cost; these measurements do not claim that path was optimized.

Early raster runs caught a worker-created bitmap colour defect and an incorrect manual row reversal. The final implementation passes pixel buffers and uses VCL's visual row indices. Another reference run failed in the Python report because its comparison omitted the newly added comic source; it now verifies every original source hash. Failure logs are retained separately from passing reports.

Both application architectures ran on the current 64-bit Windows installation. The real RAR and DjVu cases used copies of the locally installed decoder binaries; this does not validate a separate 32-bit Windows installation or the final distribution packages.

Native updater checks sample actual window pixels for both white strips, enabled/disabled notification states, light-to-dark changes and 100/150/200/300 percent scaling. Both catalogue and Reader configurations pass. The shared component-release link is labelled for its actual destination.

Reports and native build receipts: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`. Test binaries include pending local UI/Reader work and are not a clean production release cohort. Temporary runtime profiles were removed. Original user books, catalogue and Desktop installation were not modified.

FB3 sample source: [official FB3 examples](https://github.com/gribuser/FB3/tree/master/Examples), Git blob `e7e2714b3e1d9b1c6040f8b7914525f634030c8e` (verified before inspection).

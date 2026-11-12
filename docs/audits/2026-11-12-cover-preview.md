# Catalogue covers after beta 13

The catalogue now reads declared EPUB cover images and package thumbnails in its existing background preview worker. It does not launch the Reader or convert a book just to display its cover. Existing sidecar and FB2/FBD paths retain precedence. This is a local change for beta 14; it has not been published.

## Format matrix

| Format or source | Catalogue path | Evidence and remaining scope |
| --- | --- | --- |
| FB2 and matching FBD descriptors | Existing description and cover reader | Direct FB2, ZIP member selection with the correct FBD, nested UTF-8 paths, ambiguous members and unchanged-source checks pass on x86/x64. |
| EPUB2 and EPUB3 | New package reader: metadata cover ID, `cover-image`, then guide cover page | Exact extracted bytes and actual catalogue images pass for three supplied EPUBs and generated fixtures. XHTML/SVG wrappers may refer to an internal raster image. |
| EPUB inside ZIP or 7z | Existing selected-member extraction, followed by package reader | Correct embedded cover, unchanged outer archive and responsive selection pass on x86/x64. |
| Word DOCX/DOCM/DOTX/DOTM; PowerPoint PPTX/PPTM/POTX/POTM/PPSX/PPSM; Excel XLSX/XLSM/XLSB/XLTX/XLTM | Optional OPC thumbnail relationship in `_rels/.rels` | Generated fixtures for each extension pass. The package must actually contain a declared thumbnail; no arbitrary document illustration is substituted. Real document samples remain to be checked. |
| OpenDocument ODT/OTT/ODM/ODP/OTP/ODS/OTS/ODG/OTG/ODF | Optional `Thumbnails/thumbnail.png` | Generated fixtures for each extension pass. Real document samples remain to be checked. |
| FB3 | Optional OPC thumbnail relationship | Declared-thumbnail fixture passes. The official FB3 sample contains a file named `Cover.png` without a thumbnail declaration; this change deliberately does not infer a cover from its filename. Other FB3 cover conventions remain to be investigated. |
| FLibrary companion covers | Existing separate-cover reader | Kept ahead of embedded-cover fallback; not newly revalidated against a real FLibrary collection in this run. |
| Pure vector SVG covers | No catalogue renderer yet | An explicit unavailable-preview status is returned. SVG wrappers containing an internal raster image do work. |
| PDF, DjVu, XPS/OXPS | Matching FBD when supplied | Rendering a first-page preview from the book itself remains open. Do not use the Reader's UI-thread PDFium state concurrently from this background worker. |
| CBZ/CBR/CB7 and image-only archives | No new first-page path | Reader page support is not proof of catalogue preview support. Natural page ordering and bounded first-page decoding remain open. |
| Standalone raster images | No new direct-image path | A catalogue thumbnail is still to be added and checked separately. |
| Kindle MOBI/AZW/AZW3/PRC | No new direct cover extractor | Do not start whole-book Kindle conversion when the user selects a row. Direct metadata/cover extraction remains open. |
| TXT, RTF, HTML, Markdown, old office and other legacy formats | Matching FBD when supplied | A format may have no dedicated cover field. Audit actual metadata and thumbnail conventions before promising previews. |

## Limits and behaviour

ZIP entries are streamed with CRC checking and limits on actual decompressed bytes: 2 MiB for XML and 16 MiB for a cover part. XML disables DTDs and external entities. Cover paths remain within the package; URI decoding preserves literal plus signs. Duplicate exact entry names, external paths, traversal, corrupt data, missing images and loops produce a status instead of a stale cover. Decoded catalogue cover memory is capped at 64 MiB. Pure SVG is not passed to a raster decoder with unresolved external references.

The existing generation check discards a late result from a previously selected book. Cancellation and caller stream position are tested. Optional image-codec errors are reported by the background worker without starting installation from a row selection.

## Local validation

`tools/ui/tests/test_package_covers.py` drives the native `CollectionViewsTest` executable. Each architecture passed 50 package cases plus cancellation, 13 catalogue-preview checks, four asynchronous FB2 preview checks, and updater theme checks. Separate clean profiles also passed the existing archive/FBD and image-allocation regressions.

The first combined archive-plus-image invocation reused a fixture database and failed on a duplicate test collection name before the image checks ran. Both modes then passed in separate private profiles. The failed logs are retained; this was not reported as a successful combined run.

Native updater checks sample actual window pixels for both white strips, enabled/disabled notification states, light-to-dark changes and 100/150/200/300 percent scaling. Both catalogue and Reader configurations pass. The shared component-release link is labelled for its actual destination.

Reports and native build receipts: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`. Test binaries include pending local UI/Reader work and are not a clean production release cohort. Temporary runtime profiles were removed. Original user books, catalogue and Desktop installation were not modified.

FB3 sample source: [official FB3 examples](https://github.com/gribuser/FB3/tree/master/Examples), Git blob `e7e2714b3e1d9b1c6040f8b7914525f634030c8e` (verified before inspection).

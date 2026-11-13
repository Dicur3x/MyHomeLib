# Incremental image provenance, local beta 14 work

This is a verified processing layer, not completion of automatic incremental collection compression or a released build.

## Behavior

The previous per-book ledger recognizes an unchanged output hash for a particular physical file and member. A text edit, replaced archive or moved file can invalidate that identity even if its already compressed images have not changed. Preparation now also looks up image byte hashes, scoped to the exact quality/grayscale profile. Known images are retained byte for byte; only new images reach the image encoder.

The catalogue receipt commits `HomeLibreCompressedImages(ProfileSHA256, ImageSHA256)` with a composite primary key, `WITHOUT ROWID`. The table is created only when a committed result includes image provenance. Personal databases are unchanged. Crash recovery replays this idempotently. Legacy receipts without `image_outputs` remain accepted. Each optional list accepts up to 5,000 SHA-256 values; malformed values fail before publication.

Preparation and measurement open the catalogue in read-only mode and never write provenance. Queries use the composite key and a bounded 2,048-entry cache. A missing history table means no known images; a specified missing/unreadable database fails without creating one. History does not rely on path, extension, book ID or declared image MIME alone.

The shared image sampler excludes retained images from its sample and includes their unchanged byte cost. All-known images produce an exact unchanged payload size without launching an encoder. Partial samples remain estimates of book payloads, not predictions of the surrounding solid archive. An output larger than its source is discarded; hashes of discarded re-encodings are not committed.

`PACKING_IMAGE_API` is now 3. The selected compression preparer requires the matching BookProcessing module. The new history reader is included in the component package and required-file inventory for 3.0.0.14.

## Validation

All inputs were private fixtures. Tests used the actual existing HomeLibre Images executable, actual 7-Zip and newly compiled Delphi receipt workers. No user's source books, installed module or desktop installation was changed.

- Win32 full suite: **66 tests passed**, 81.454 seconds. Includes preparation, estimation, receipt validation, real archive replacement, database updates, cancellation, failures and crash/replay.
- Win64 receipt and first pipeline: **18 tests passed**. Subsequent complete incremental pipeline, image-history and estimate cases: **23 tests passed** after adding the second compression operation.
- Ordinary export regression: **10 tests passed**, covering container choice, estimate handshake, illustrated FB2/EPUB, text/cover/GIF preservation, reading defaults, original resolution and ZIP estimates.
- Modified/renamed FB2 and EPUB retain old image bytes. With one newly added illustration only its hash appears in actual encoder input. Text, links, CSS, fonts, SVG and neighbouring archive entries are checked separately.
- After a first real native catalogue commit, a second compression operation reads the committed history, preserves its old image, processes the new one and successfully publishes through the native job. Source file identity and personal data checks remain active.
- Grayscale has its own profile identity. When its high-quality result would enlarge the book, the original and history remain unchanged.
- Read-only history lookup and canceled operations preserve source/database hashes; owned workspaces and runtime overlays are removed.

Native workers were built through the licensed IDE's documented AutoBuild interface. No compiler/license workaround was used.

Win32 worker SHA-256: `626aa78c5481bd09a080c44d1f55cca7f1b1b1897fe2d4eedb8ea89ba3888914`.

Win64 worker SHA-256: `35d6bf346b0d5a452a13a681b9920c4ece1ec3b26da85a1b0a01be02b01013c0`.

Local reports under `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`:

- `incremental-image-tests-20261112-234317.json`: Win32 full suite and runtime cleanup.
- `incremental-image-tests-20261112-232016.json`: Win64 receipt/recovery checks.
- `incremental-image-tests-20261112-233537.json`: Win64 incremental pipeline and estimates.
- Build logs `BookCompressionReceiptTest-Win32-fdd4d923faa4.err` and `BookCompressionReceiptTest-Win64-891da8c06a32.err`.

Early failed runs are retained as failures. They exposed an incorrect expectation that grayscale must always yield savings, two test attribute/decompression mistakes, and were corrected. The final full run above passed without skips.

## Remaining requirements

Per-collection preferences were subsequently added and tested on x86/x64; see [the 13 November follow-up](2026-11-13-collection-compression-preferences.md). Still open: automatic detection/offers after INPX, Metabib, file/folder imports; the explicit new-books command; migration/seeding of already compressed legacy books; full restart/stop/resume UI paths; sidecar-image formats; the final production builds and shipped component installation. A global historical hash only protects bytes that have previously been committed for that profile; it cannot reconstruct missing history of a prior lossy conversion.

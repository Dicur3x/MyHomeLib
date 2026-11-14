# Native JPEG XL PDF/EPUB reading, export and reuse

Local beta-14 work following `38ebac50`. No user-library mutation, Desktop
replacement or public release is included.

## Scope and reproduction

The private fixture contains a valid minimal one-page PDF with an explicit xref,
two direct DCT JPEG streams and a text caption (87,824 bytes), plus a ten-resource
EPUB (88,990 bytes). Its EPUB includes a cover, prose/inline markup, CSS, NCX,
an auxiliary binary asset and a JPEG path with Cyrillic characters and a space.
The images are deterministic generated data. No downloaded book/image is used.

Actual `TCollectionPackingSnapshot` publication must choose the smaller JPEG XL
layout for both books. Native book streams and `PrepareReaderFile` then restore
the PDF's complete SHA-256 and every EPUB resource's SHA-256. EPUB mimetype must
remain first and uncompressed; its private image index must be absent. The
native reflow reader successfully decodes both EPUB pictures and its prose.
Logical sizes, personal progress (37%) and notes are checked in the source and
registered copies. A second publication/read hides the owned original archive;
it must retain the existing outputs rather than require the original.

Ordinary conversion preparation is also exercised. PDF preparation is byte-exact
even with the no-illustrations source option: its encoded storage envelope is
not itself a PDF and must be restored before conversion. Full EPUB preparation
retains all resources. During explicit text-only EPUB export, the private decoder
is held under another filename and PATH is emptied in that test process only.
Text-only conversion must succeed without it; normal full-image preparation with
an uncached identity must request JPEG XL rather than reuse a text-only cache.
The decoder/PATH are restored in a finally block.

`jpeg-formats-Win64-baseline-r70` passed reading/reuse in 12.734 s, but adding
the export cases found a product defect in `jpeg-formats-export-Win64-r71`:
text-only output retained `FLibraryImageIndex.json`, pointing to image sidecars
that no longer belong to that ordinary exported EPUB. A focused Python
regression also failed before the fix. The stale marker could interfere with
subsequent packing or import of that exported book.

## Fix and safeguards

`image_quality.without_images` removes recognized external-image indexes when
creating the text-only candidate. Recognition requires the reserved basename,
a bounded JSON list, exact id/num records, native-range integer image numbers
and safe image-member names. It rejects duplicate fields, Boolean numbers,
unknown schemas and caption-bearing extra fields. Unrelated similarly named
JSON remains byte-identical. Index IDs are raw ZIP member names: literal `#`
and percent characters are not decoded as URI fragments.

Source archives and catalogues remain unchanged; this only changes an explicitly
requested text-only export candidate. The existing text/notes/inline-tail,
legacy-encoding and scanned-content protections remain covered by the complete
13-case `test_no_images` suite, which passed in 3.600 s. Six unknown-JSON
subcases are included in that count, not counted as six additional tests.

## Exact local candidates

BookProcessing `packages-r73`:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 12,446,889 | `44e5c327d56c9c2cec9451a88bce503a6b699c4178e9134841dc7a7dc4e95737` |
| Win32 | 11,187,512 | `f460be57e3abc40f9ddd50738c7f99ff837067e51025aa29400960298bdd7346` |

These use the same verified official libjxl 0.13.0 and image helpers recorded
in the preceding host-capability/prefix audits. The native codec installer
helper was shared between the old INPX case and this fixture; its behavior is
unchanged and still checks the decoder/encoder separately under `HomeLibre.exe`.

Win64 `jpeg-formats-export-Win64-r74` passed the entire scenario in 15.891 s,
including text-only export and full-image cache separation on both publications.
Its own temporary runtime was removed. Fixture SHA-256:
`3a8991bf1f7c53fe5e0915fd416e61eac0234353b0aa0cd0f400adc263408c0c`.
Build log: `CompressionRecovery.local-Win64-118e4849b246.err`.

Win32 `jpeg-formats-export-Win32-r75` passed the same scenario in 16.797 s.
Its fixture SHA-256 is
`d040b1f459f0dce6d50d97798b6195ddd25a47f0ac9491a27c6985437640025e`;
build log: `CompressionRecovery.local-Win32-8060ccdbc23e.err`.
Its temporary runtime was also removed.

## Stored 7z and embedded EPUB identity

An additional verifier wraps the actual native text-only export in a real
stored 7z and runs the installed Packer on it. Both `r76` and `r77` failed:
Python's `zipfile.is_zipfile` accepts the EPUB ZIP embedded near the end of
that 7z. Packer selected the embedded ZIP and could not find the outer member.
The native PDF/EPUB reading/export checks themselves passed in these runs.

The focused regression makes the consequence stricter: a stored 7z contains
`source.epub`, and that outer EPUB has an unrelated inner attachment also
called `source.epub`. Before the fix the Packer successfully published the
inner attachment instead of the requested outer book. The regression failed
on exact output bytes; the owned source archive stayed unchanged.

`is_zip_container` now gives an actual primary 7z signature precedence over
Python's trailing-ZIP heuristic. Packer computes this once per source and
uses it consistently for extraction, FBD and container-retention decisions.
The same guard prevents JPEG XL's EPUB encoder from opening a nested 7z as
its inner ZIP. Ordinary ZIP/ZIP64 recognition remains delegated to Python;
archive extensions alone do not decide the source format.

The fixed single regression passed in 0.628 s. It independently extracts the
published member with 7-Zip and compares the entire outer EPUB, checks the
source hash, and proves that a nested 7z renamed to `.epub` neither creates a
stripped EPUB nor invokes the image encoder.

The verifier had the same trailing-ZIP ambiguity when checking output in
`r79`/`r80`. That observer was corrected to extract exact literal member names
with independent 7-Zip for every archive. No production change followed
those observer failures. Standalone worker diagnostics now explicitly use UTF-8.

Final local `packages-r78` contains both production fixes:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 12,447,023 | `43fb3abe85d7e69221d9e37e01288ae20f3b599b6e5ebcf21df7bcd7dfe14c5b` |
| Win32 | 11,187,651 | `9b8b814e12537e6f3e4cb9a3e8e327aee89bd6445670a4c9cc3326220776c976` |

Both final native scenarios passed with those exact packages and the native
fixture identities above: Win64 `jpeg-formats-repack-Win64-r83`, 41.313 s;
Win32 `jpeg-formats-repack-Win32-r84`, 44.500 s. Both restored PDF/EPUBs,
both publications' text-only exports and missing-decoder cache separation,
personal data and logical sizes passed. The independently repacked text-only
EPUB stayed byte-exact; its source and output archives were both 2,064 bytes
on each architecture (the no-growth fallback retained the valid container).
The source archive hashes stayed unchanged. Both private runtimes were removed.

The complete Packer integration suite also passed against the exact installed
`packages-r78` runtimes: **56 tests per architecture**, zero failures, errors
or skips. Win64 `zip-detection-Win64-r81`: 293.062 s;
Win32 `zip-detection-Win32-r82`: 293.344 s. These include the new stored-7z
identity case, the preceding old-host capability guard and existing FBD,
ZIP64, sidecar, image-history, no-growth and source-change protections.
Both suite runtimes were removed. The runner stages receipt/operation
executables as dependencies but selected only `test_pack_collection` here;
the native recovery suites are not counted as rerun.

## Failed setup/observer attempts retained

- Build `f61d0f1da62f` stopped on a Pascal reserved parameter name and a missing
  byte-array hash overload in the new fixture. The failed Build dialog required
  acknowledgment before AutoBuild wrote its log. The earlier success log was
  not evidence for that attempt; no old binary was run as the new fixture.
- `r68` stopped before native execution because the wrapper assumed every
  scenario supplied an FB2. Its unrelated conversion fixture now has a fallback.
- `r69` exposed the test's exclusive catalogue hash open against its own live
  SQLite connection. The fixture now uses the shared-read hash helper already
  used by the existing native catalogue tests. No production file-lock change
  was made.

## Remaining work

The PDF equality checks prove restoration of every source byte; this fixture
does not install PDFium or render a PDF page. It invokes working application
classes directly rather than every compression/export menu. Legacy nested
FLibrary EPUB/cover sidecars, automatic installation/continuation from missing
components, bounded user-data copies and final distributions remain separate
open checks. Earlier native recovery suites are not counted as rerun here.

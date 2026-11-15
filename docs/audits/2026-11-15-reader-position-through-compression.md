# Existing Reader positions across a new selected-book compression

On x64, an actual bound FLibrary catalogue and production Reader preserved
positions created **before** another compression. The composed run passed;
user collections, Desktop files and public packages were not modified.

## Actual workflow and independent checks

After the existing bound-source compression/full-and-append-INPX fixture,
Computer Use opened EPUB 101 and FB2 301, paged each once and closed each. The
observer captured their saved positions and the complete books reconstructed in
the Reader's separate profile cache. It checks each cache file's physical-source
origin and measured size against the session's catalogue record.

Three visible books (101, 201 and 301) were marked in the ordinary catalogue.
The context-menu selected-book command showed a count of three. Maximum economy
and grayscale were chosen, with per-archive review enabled and original backup
disabled. The first prepared result showed approximately 127.3 to 71.3 KiB.
The real progress window's Apply Remaining action was confirmed. Completion
reported three books in two archive groups and about 112.2 KiB saved. These are
the preferred physical copies of those selected cards, not a claim that all
alternate source copies were recompressed.

Both books were then reopened without navigation and closed normally:

| Book | Prepared bytes before | Prepared bytes after | Position before/after | Visible progress |
|---|---:|---:|---|---:|
| EPUB 101 | 124728 | 67479 | 384 / 384 | 23% |
| FB2 301 | 168990 | 90776 | 464 / 464 | 28% |

The observer independently compared all non-image EPUB member hashes, including
XHTML, CSS, OPF, NCX and the additional binary resource. It compared serialized
FB2 XML with binary nodes removed, retained the image-ID sets and confirmed
changed image payload hashes. The newly opened complete-file sizes equal the
updated catalogue values; the old Reader cache was not reused as current data.
Reviews remain unchanged and persisted Progress is positive.

Only four protected source files changed: `covers/nested-epub.7z`,
`covers/zip-epub.zip`, `images/nested-epub.7z` and `images/zip-epub.zip`, all under
the preferred source. Raw book archives, the second source, the unselected 401
book and the arrival folder remain byte-identical. Compression history changed;
all protected files then stayed unchanged during the final reading sessions.
All four Reader sessions and Main closed normally, Main exit code is zero,
session requests were removed and the parent runner removed the owned runtime.

## Evidence

`G:/HL-b14-external/preposition-Win64-r617/catalogue-Win64-reader.json` and
`catalogue-Win64-apply.json` are PASS. The latter also retains the complete native
prelude result and runtime-removal assertion. This is not a speed benchmark.

- Main: `3e040e144da608d9a7c2b699a74425c34649e05fa3c3c72ed4bbe76f04c0f5ab`.
- Reader: `0c2a16a94b8ff7f82082e9efc4813abc8b02919ad1a9bc06e33ff60789d0ca97`.
- Native fixture: `05a0083992ea1ccd5d291b9683405cffae3244cc713c27b06c426f6450b80c02`.
- BookProcessing package: `e920f4aac2310f7c96bd677d55381f45f2ef9dc12fe90129e2749834f553d7a6`.
- Official JPEG XL archive: `e394519c05ea9e5b83947f89b40afbf1ea7c631a608406c5de945a4c5bdcdcb7`.

The runner's optional `--reader-recompress` mode requires a real Main/Reader
runtime and the existing reviewed-FLibrary fixture. It requires closed first
sessions before another physical change, changed compression history, unchanged
non-image content and restored positions. Ordinary inspection still requires
all source files to remain unchanged throughout reading. Inspection stops if
the system drive reserve falls below 8 GiB.

## Harness corrections and build evidence

The first draft r614 failed before recompression: the session's `source` is the
physical shared archive, not an EPUB payload. Its FAIL reports are retained.
The corrected observer inspects the managed complete book under
`Data/ReaderProfile/Data/BookCache`, checking its `.origin` and `.source` sidecars.
No compression-code change was needed for the successful scenario.

The Reader entry point also still referenced the old `Program/MyhomeLib.dres`
path. It now uses `Program/HomeLibre.dres`. The licensed r615 compilation
reported Success, but its wrapper had been given the wrong output path.
`reader-canonical-resource-Win64-r615/verified-actual-output.json` verifies the
actual fresh output's architecture, linked title, hash, timestamp against the
successful compiler log, and matching source/project files. That exact output
was copied to the test runtime. The attempted wrapper rerun r616 encountered a
Delphi LSP access violation and reached its 240-second deadline; it is not a
successful build and no licence/system settings were changed.

## Remaining scope

This proves the pre-existing-position workflow for these generated x64 EPUB/FB2
books with FLibrary sidecars. Other formats/layouts, outstanding recovery and
temporary-storage cases and final x86/x64 beta 14 distributions remain separate.
Current production candidates still have numeric release identity 13. This does
not mark the whole compression or beta 14 goal complete.

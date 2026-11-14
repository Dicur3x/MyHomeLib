# Complete-book sizes during unchanged FLibrary repacking

Local beta-14 change. No user-library mutation, Desktop replacement or
publication is included.

## Reproduced defect

The generated legacy FLibrary fixture has actual outer 7z archives, EPUBs
stored as ZIP or nested 7z, and separate cover/image archives. Baseline `r98`
showed that both original and maximum profiles could repack an outer archive
without changing its selected book payload. They did not recompress external
images. The complete ZIP EPUB fixture is 48,121 bytes; its stripped stored
payload is only 2,311 bytes.

Against the previous native receipt binary, `flibrary-size-red-r99` reproduced
the catalogue regression: after the real prepared replacement was committed,
BookSize changed from 48,121 to 2,311. The diagnostic is intentionally FAIL.

## Change

- A receipt's payload size remains its physical byte length for verification.
  When input and output hashes are equal, applying the receipt preserves each
  matching catalogue, personal and copy row's current size. Different existing
  sizes in those rows are preserved independently.
- The compression ledger uses -1 for an unknown complete-book size. This value
  is never written to Books or CatalogBookCopies. Exact locators, database
  identities, physical hashes and recovery binding remain mandatory.
- A prior measured size survives an unchanged repack or inspection only when
  the same output has a transformation witness with distinct input/output
  hashes. Its original input witness is retained across profiles. Old unchanged
  inspections that stored surrogate length are invalidated on inspection.
- Full INPX rebuilding accepts only positive sizes with that transformation
  witness. Unknown sizes and legacy unchanged inspections cannot replace a
  publisher's size. This does not infer or repair an already incorrect size
  without measuring the complete restored book.

The receipt schema and packaged Python worker are unchanged.

## Native validation

Six added receipt cases exercise actual generated FLibrary preparation and
native application/inspection: distinct catalogue/card/copy sizes, unchanged
sidecars, a crash between catalogue and personal commits, unknown inspection
sizes, old surrogate witnesses, and a prior measured size across profiles.
The durable-job case also runs normal final acknowledgement checks.

On each architecture, the complete receipt/operation attempt ran 88 cases
(36 receipt and 52 operation). In short private roots `G:/HL-b14-size/r104-64`
and `r105-32`, 87 passed; the remaining case failed before product execution
because its fixed test suffix no longer produced a path longer than 260
characters in the shorter root. The fixture now extends its Unicode workspace
until that condition holds. The only affected test was rerun with the exact
same native binaries in `r109-64` and `r110-32`: PASS, 4.546 and 4.015 seconds.
Thus all 88 distinct cases are covered across the full and targeted runs;
the original full reports correctly retain FAIL and were not rewritten.

The ordinary catalogue compression action followed by a real full INPX update
also passed, including eleven size/identity/rollback boundaries. Added
boundaries reject unknown size and a legacy unchanged-inspection witness.

| Architecture | Ordinary action and INPX | Seconds | Result |
| --- | --- | ---: | --- |
| Win64 | flibrary-size-inpx-Win64-r108 | 20.469 | PASS |
| Win32 | flibrary-size-inpx-Win32-r107 | 16.719 | PASS |

Both runs preserve the selected FB2 text, neighboring book, backups, personal
progress and notes. The shared archive shrinks from 1,288,077 to 127,560 bytes.
The initial Win64 observer attempt `r106` expected the old nine-boundary
marker; the native process completed with exit 0 and all eleven boundaries.
The corrected observer was rerun as `r108` above.

Final native binaries, built with the licensed IDE and unchanged projects:

| Binary | Architecture | SHA-256 |
| --- | --- | --- |
| BookCompressionReceiptTest | Win64 | 79bd736d336762bcef430374f492b1dd2301aa9ad259385d98ba39a9e9101b1e |
| BookCompressionReceiptTest | Win32 | 2796120bd085884b6260b6fab5d08b452b821c44ec9033a269f35e0e7aaff7a8 |
| BookCompressionOperationTest | Win64 | 65180262d6b2f8376b16e7284dcb32095008450e0648ff2c1efa79ae19c4a907 |
| BookCompressionOperationTest | Win32 | 24aa9fa5e2b01a342bde14da8d3dfd759e59eef06d889dab454e0dfe8de0c77e |
| CollectionViewsTest | Win64 | fa385af9c9df154e8f67bab1a8deb9a8c193c3015fe581da4767c1a1c66d0247 |
| CollectionViewsTest | Win32 | efa0c0d32c3b4c9c8ba0cc7eea2157993878885a62d674e9df5f6a94f245291e |

Build logs are in the legacy-history cache's `build-logical-size` directory.
Final receipt logs end in `742b8519d07e` / `35d3deda7d78`, operation logs in
`06a64f496c39` / `1fae7b04fe6d`, and catalogue logs in `c898e61d9ab5` /
`e775a05b6087`. BookProcessing remains the verified `packages-r78` candidate.
Its broad Packer suite was not rerun because this step does not change it.

## Remaining work and diagnostic limits

Earlier `r100`/`r101` found an already-compressed stale-size replay boundary;
the final receipt retains the existing physical-size/old-size validation while
separately deciding whether a size write is justified.

Deep initial operation roots `r102`/`r103` exposed a separate long-path problem:
collection-plan SQLite failed at WAL setup, and a diagnostic could not open
the prepared originals ZIP. Shortening the root removed those failures.
These observations remain open; the passing long Unicode image-workspace test
does not establish that every long catalogue/plan/backup path works.

Quality changes to external FLibrary images, their dependency/cache witnesses,
bounded user-data copies and final application/distribution gates remain open.
This change establishes unchanged repacking and size accounting, not external
image recompression.

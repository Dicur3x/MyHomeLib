# Ordinary Main/Reader after FLibrary compression and reviewed updates

Both generated, isolated collections passed the native processing scenario and
actual production Main/Reader inspection on 15 November 2026. No user collection,
Desktop installation or public release was changed.

## Processing scope

The existing `reviewed-flibrary-compression` scenario processes generated EPUB
and FB2 books with separately stored covers and pictures, including JPEG XL.
It exercises real compression, reviewed full and append INPX, a new download
with external images, compression of only the arriving book, repeated new-only
selection, restored resources/text/covers, measured sizes and personal data.
An unrelated shared ZIP must remain byte-identical. The native logs passed
before GUI inspection on both architectures.

`validate_catalogue_compression.py --reader-runtime PATH` now optionally hands
this owned fixture to `reader_inspection.py`. The observer copies matching real
Main/Reader and their required runtime files, selects the fixture collection,
and watches the normal session protocol and Windows process identities. It
does not create synthetic Reader replies or inject input; Computer Use performs
the normal open, page and close actions.

## GUI and persisted checks

Main displayed the fixture's external covers. The actual
`HomeLibreReader.exe` opened EPUB `FLibrary 101 corrected` and FB2
`FLibrary 301 corrected`, showing their external picture and expected text.
Each was paged once, closed normally, reopened without navigation, and closed
again. Main also closed normally with exit code zero.

| Architecture | EPUB first/reopened position | FB2 first/reopened position | Result |
|---|---|---|---|
| x86 | 384 / 384 (23%) | 464 / 464 (28%) | PASS |
| x64 | 384 / 384 (23%) | 464 / 464 (28%) | PASS |

The observer checks the saved position before and after the second session,
unchanged catalogue BookSize and Review, positive catalogue Progress, exact
SHA-256 of every protected archive/sidecar across reading, and removal of session
requests. Parent reports confirm the entire owned runtime was removed. All
eight Reader processes and both Main processes closed normally.

The Reader's initial `displaying` reply is allowed to omit progress until a
navigation event. The first observer incorrectly required that optional field
and reported FAIL in r523, despite its captured matching positions. It now uses
the saved position and persisted catalogue progress as the independent required
checks; if an initial progress value is present it must also be positive. The
original failing report is retained unchanged; the corrected full reruns below
both passed, including the final archive and catalogue assertions.

## Evidence

- x64: `G:/HL-b14-external/flibrary-reader-final-Win64-r535/catalogue-Win64-apply.json`
  and `catalogue-Win64-reader.json`, both PASS.
- x86: `G:/HL-b14-external/flibrary-reader-final-Win32-r536/catalogue-Win32-apply.json`
  and `catalogue-Win32-reader.json`, both PASS.
- Production EXE hashes match the final Main and Reader builds recorded in
  [the Reader naming audit](2026-11-15-reader-name-migration.md).
- Native compression binaries are the previously built XML-path-fixed test
  hosts: x64 `e243f8ab6689c4c5873bb8d50a7c407e4a1a0337d71052d3fbce579d8f582fe8`,
  x86 `0c552b85ee6746c34294dc3521af23d218212df7f6fe532d0943b962cb901de5`.

Runtime inspection requires `--scenario reviewed-flibrary-compression --mode
apply`, no injected recovery fault, the complete matching runtime, and a bounded
`--reader-timeout` of 30–1800 seconds. Large files and temporary data remain on G:.

## Limits

This GUI inspection uses the ordinary generated collection, not the bound
multi-source variant or the user's full collection. These Reader positions are
created after compression and INPX; the test proves persistence across actual
reading/reopening of the processed books, not a pre-existing Reader position
across a new compression. Native personal-progress preservation is checked by
the preceding processing scenario separately. Other formats, earlier FLibrary
layouts, final beta 14 identities/packages, and remaining recovery and storage
requirements stay open.

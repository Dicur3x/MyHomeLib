# Per-collection compression choices

Quality, grayscale, review-before-replacement, optional original backups and
their folders are now stored in the collection's existing `Settings` table.
Both ordinary commands, for selected books and the whole current collection,
load that collection's choices. An accepted choice is saved before resolving
missing modules, so installing a module does not discard it. Cancelling the
options dialog does not save or start processing.

The application profile still owns the recovery queue identity and all work
roots. Existing jobs are not reassigned when another collection is selected.
A new collection does not inherit another collection's lossy, grayscale or
backup choice. Malformed saved choices produce an explicit warning and safe
defaults for the user to review. No command, executable, automatic-start flag
or foreign queue identity is loaded from the collection preference.

## Native verification

`CollectionViewsTest compression-preferences` uses two private real SQLite
collections. Both x86 and x64 passed:

- independent choices, reopening, rename and root relocation;
- the actual full-import table reset retains the collection setting;
- shared recovery queue and registered work roots remain intact;
- malformed JSON, unsupported versions, invalid field types and relative
  folders return a warning instead of partially applying a choice;
- invalid saves and an active import transaction preserve existing settings;
- remembering choices creates no book-processing or original-backup payload;
- the explanatory label fits at 96, 144, 192 and 288 DPI.

This tests the reset used by full INPX imports, not a complete INPX import file
or an automatic incremental-compression offer. Those remain separate checks.

Reports are under
`G:\HomeLibRu-build-cache\HomeLibre-post13-compression-preferences-20261113`:

| Report | Native SHA-256 | Result |
|---|---|---|
| `native-Win64/preferences-Win64.json` | `648d51a8308849f7e897450310d6bf603b98ab04ec5389714e058dea8a14a405` | PASS; private runtime removed |
| `native-Win32/preferences-Win32.json` | `1234236e289fd325f74b86b03c7ec4ac6a9d3efff300b10ce09bceee4d7cf51f` | PASS; private runtime removed |

These test binaries link the actual main form and compression runtime. Final
production EXEs, beta 14 packages, Desktop replacement and public updates have
not been produced by this milestone.

## Preserved incomplete real-book attempts

The first x64 real-book GUI attempt in `catalogue-Win64` exceeded the external
210-second test deadline. Its old runner buffered output, so the diagnostic was
insufficient; it is not counted as a successful test.

The second attempt in `catalogue-Win64-r2` reached preparation, visual review,
original backup and an in-progress replacement checkpoint, but failed the
native 180-second completion assertion. Its log and bounded JSON diagnostics
were retained. No final content-verification result is claimed for it. Its
attempt marker predates terminal-status recording and still says INCOMPLETE;
the `.log` explicitly records FAIL.

The third attempt, `catalogue-Win64-r3`, completed the native window action and
its cache, backup, progress and preference assertions. The subsequent external
7-Zip payload verification exceeded its 30-second decoder timeout for the
large PPMd-compressed FB2. The complete run is therefore **not PASS**. The
decoder's verification timeout is now 120 seconds; assertions are unchanged.

The runner now streams stdout to a persistent log, records terminal failures,
isolates its temporary/profile directories and disables unrelated automatic
network checks in the private fixture. The complex real-book fixture has a
300-second internal deadline, with a separate outer bound for bootstrap and
teardown. Content, backup, neighbour, cache and personal-progress assertions
are unchanged; the larger test deadline is not a product performance fix.

The third run also exposed corrupted Russian worker-stage captions. Appending
an ACP `AnsiChar` to a `UTF8String` transcoded individual pipe bytes before the
whole JSON line was decoded. Both compression event streams now append raw
bytes by index. The real-book GUI fixture additionally requires exact Russian
preparation/estimate captions; a passing filesystem result alone cannot hide
this display defect.

## Complete x64 real-book follow-up

`catalogue-Win64-r4/catalogue-Win64-apply.json` is **PASS**. This run uses the
ordinary selected-books action with estimate-first, economy quality, colour
images, explicit visual review and original backups. The normal catalogue
remains usable during review. The comparison dialog also exercises both
themes and 96/144/192/288 DPI.

The wrapper independently decoded the resulting PPMd ZIP and checked:

- every FB2 semantic element, text, image identifier and reference, excluding
  deliberately transformed binary image bytes/MIME;
- EPUB member names plus exact XHTML/HTML, CSS, font and NCX bytes;
- byte-exact unselected neighbour and both original-book backup payloads;
- unchanged identities, sizes and timestamps of the two original source
  archives, which are opened only for reading;
- refreshed Reader cache and catalogue size, retained 37% personal reading
  progress, saved per-collection choices and no pending completed job;
- exact Russian preparation and estimate captions through the actual worker
  event stream.

The private shared archive changed from 28,622,902 to 20,230,333 bytes. This is
a regression fixture, not a prediction of savings for an entire collection.
The 93.640-second wall time includes bootstrap, estimation, preparation,
backups, theme/DPI assertions, native replacement, cache validation and
independent archive decoding; it is not an estimate-only performance result.

Native EXE SHA-256:
`441bc02e188f93630090ad2d84fcb9b61c4538f1bbae74a391e0592ed5cd9903`.
Exact locally packaged BookProcessing 3.0.0.14 ZIP SHA-256:
`2a64cbbe9d4ee0d4675e53a829b1cb1050aee8d27537ed27ac6cd71b739196ab`.
The successful return occurs after guarded removal of its private runtime.
The earlier partial/failed runs above remain separate evidence. This new run
does not turn them into passes and does not prove final x86 GUI integration.

## Complete x86 real-book follow-up

`catalogue-Win32-whole/catalogue-Win32-apply.json` is **PASS** using the
ordinary **current-collection** command with estimate-first, explicit review
and optional original backups. It checks the same two real book payloads,
unselected neighbour, complete text/style/font preservation, cache refresh,
personal progress and saved choices as the x64 follow-up. Missing unrelated
default fixture rows are reported as unavailable; this is not a claim to have
compressed a production collection in full.

The private archive is again 28,622,902 → 20,230,333 bytes. Wall time 169.704 s
includes the full regression/verification sequence rather than just size
estimation. The native Russian preparation/estimate caption assertions pass.
The wrapper returned successfully after removal of its private runtime.

Native EXE SHA-256:
`1eafc5358fc1c0ca922c1a9d0e06317b17d82ab3e553b1f9a07f9e7f22df83e3`.
Exact local BookProcessing 3.0.0.14 ZIP SHA-256:
`61c7545cd7f7c72e38e60c2ea0f61da5896cfede82085d2e041f5b8559a08c4d`.
The temporary build project and its generated local/resource siblings are
removed after the build process and GUI fixture have terminated.

## Remaining incremental work

The complete task stays open: detect new/changed books after INPX, Metabib and
file/folder imports; offer an explicit operation with that collection's
choices; add the manual new-books command; migrate older compression history;
handle independent covers/illustrations; and verify restart/resume through
the ordinary application interface. Saving preferences alone does not perform
any of these operations.

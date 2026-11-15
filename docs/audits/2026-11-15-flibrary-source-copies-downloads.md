# FLibrary source copies and incoming external-image books

This step extends the native composition fixture. It changes no production
compression, reading or source-update algorithm.

## Covered workflow

The generated reviewed-FLibrary fixture now has a separately staged incoming
EPUB in `arrived.7z`, plus `covers/arrived.zip` and `images/arrived.zip`. Its cover
is the verified reversible JPEG XL fixture; its illustrations include a large
color JPEG, an alias to the cover and a Cyrillic path. Those files are copied
into a third owned folder only when the test simulates a new download.

`--reviewed-flibrary-bound` creates two real source roots containing the same
three archive names and their separate image/cover archives. Both sources are
imported and merged through the normal refresh/merge workers, leaving four
shared catalogue cards with eight physical copies. The ordinary variant retains
one copy per card. Both variants then use the real compression and reviewed
update workers.

The bound workflow:

1. Compresses all eight physical members, with grayscale balanced quality and
   required actual image changes and physical savings.
2. Applies repeated full INPX to the preferred source, corrects the lower source,
   corrects the preferred source and applies an append. Source priority must stay
   unchanged. New-only compression selects zero and skips all eight members.
3. Adds the incoming book and both image archives through the lower source's new
   INPX and separate download folder. That book must have exactly one physical
   source copy and keep its actual independent folder.
4. Compresses exactly the incoming book, skipping the old eight members. Its
   complete measured size, native Reader resources and preview cover are checked.
5. Repeats full and append updates for that source, then updates the preferred
   source whose index does not contain the incoming book. All five catalogue
   books/nine physical members must remain readable. New-only compression then
   selects zero and recognizes all nine members.

The ordinary workflow covers the corresponding four-to-five member transition
through full/append updates and the separate download folder.

At every relevant stage, each physical copy is checked independently using its
actual path. Checks include raw compressed-member hashes, complete prepared
Reader size, exact FB2 body XML, every EPUB non-image resource, retained decoded
image hashes, the complete native Reader image count and actual decoded preview
cover dimensions. All old outer/side archive hashes and unselected neighbor
members must remain unchanged after updates and incremental work. Personal
progress/notes are preserved and the stored personal-card size must match the
measured preferred book. All four compression-history tables are compared across
updates; the expected history is captured again only after processing the new
book.

The initial `r441`/`r442` attempts failed while preparing the synthetic download:
`ExtractFileDir` did not interpret a manifest's forward-slash suffix as a Windows
subdirectory. The fixture now normalizes that suffix before creating destination
folders. This was a diagnostic setup failure, not a production update defect.
Both failed private runtimes were also removed.

## Evidence

All four new workflow gates and two existing packed-copy retention gates passed
using the unchanged installed processing packages from `packages-r195` and the
verified official libjxl 0.13.0 archives.

| Platform | Case | Run | Seconds |
|---|---|---|---:|
| Win64 | Two sources and incoming book | `update-flibrary-bound-Win64-r445` | 192.719 |
| Win64 | Ordinary catalogue and incoming book | `update-flibrary-incoming-Win64-r446` | 91.406 |
| Win32 | Two sources and incoming book | `update-flibrary-bound-Win32-r448` | 178.609 |
| Win32 | Ordinary catalogue and incoming book | `update-flibrary-incoming-Win32-r449` | 112.765 |
| Win64 | Original/published/reused packed copy | `update-flibrary-copies-retention-Win64-r450` | 18.766 |
| Win32 | Original/published/reused packed copy | `update-flibrary-copies-retention-Win32-r451` | 19.563 |

Licensed IDE builds are `update-flibrary-copies-build-Win64-r444` and
`update-flibrary-copies-build-Win32-r447`, with binary SHA-256 values
`add861645516a6350367d905664e77867e0474b3db12f72cac967065339d5429` and
`18de46097c85f9fb3691b1073a3ee29a421df5e45b9c9078456569458c5e3d91`.
Original local project files were unchanged. The verified aggregate is
`G:/HL-b14-external/update-flibrary-copies-validation-r452/summary.json`; reports
retain exact codec/package/image-helper hashes and native logs. The aggregate
also checks actual second-root traces in the bound cases, download traces in
all four cases and removal of all six successful and two failed runtimes.

## Remaining scope

These are generated ZIP/nested-7z EPUB and FB2 layouts, not a full user collection
or every older FLibrary distribution. This adds no process-death test to the
external-image update scenario. Visual Reader reopening, large-scale and final
application/distribution checks remain separate gates. User libraries, Desktop
executables and published releases were not changed.

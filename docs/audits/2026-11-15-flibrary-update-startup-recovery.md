# Actual update recovery with FLibrary external images

This step adds composed diagnostic coverage. Production compression, update and
recovery algorithms are unchanged.

## Actual operation and termination

`--flibrary-recovery-phase` extends the reviewed-FLibrary fixture. Before the
update, the native test really compresses the original FB2/EPUB books and their
separate pictures. The bound variant has four shared catalogue cards with eight
physical copies in two roots; the ordinary variant has four physical members.
Archive names are repeated across the two bound roots.

A new INPX corrects the preferred-source titles and introduces an EPUB whose
outer 7z, JPEG XL cover archive and illustration archive are in a separate third
folder. The reviewed apply worker is actually terminated with exit code 73 at
one of the two store boundaries:

- `catalogue-committed`: the catalogue is saved, the personal-store transaction
  is not; ordinary startup must restore the previous consistent state.
- `stores-committed`: both stores are saved; startup must retain the completed
  update and its incoming card.

The durable test proof retains each physical member's raw hash, complete Reader
resource signature and measured size; all outer/cover/illustration archive
hashes, compression-history rows, source profiles and protected input hashes.
It is written by the existing guarded termination hook using the actual update
operation GUID.

Between processes, the existing `later_update_personal_neighbour` guard writes a
newer commit witness for another collection. The dedicated FLibrary branch runs
this guard unconditionally, independently of the ordinary-update CLI flag.
Its post-startup assertion must preserve that newer witness.

## Ordinary startup and continuation

The second process enters normal data-module recovery, then creates the normal
main window. The fixture checks:

- No recovery warnings or remaining update jobs; the previous process reached
  the requested actual boundary.
- Exact raw compressed members and independent complete resource signatures for
  every retained copy, including FB2 body XML, EPUB non-image resources, restored
  image bytes and native Reader image counts.
- Actual decoded preview-cover dimensions, complete measured Reader-file size,
  catalogue/copy sizes and existing personal-card size, progress and notes.
- Unchanged outer/side archives, unselected neighbors, all four compression
  history tables, four original favorites, the selected INPX and an untouched
  neighboring catalogue.
- Four original visible titles after rollback, or four corrected titles plus
  the incoming book after completed commit. The incoming card must exist only
  in the latter state.
- A repeated recovery is a no-op and keeps the transaction marker.

After either recovered outcome, the same incoming INPX is applied again through
its reviewed worker and default-No confirmation probe. Exactly one incoming
book is then compressed; the old four/eight members are skipped. Repeated full
and append INPX preserve all resources and personal data, and the final new-only
operation skips all five/nine processed physical members.

The preview and Reader checks use native reading/preparation; they do not inspect
a visually rendered Reader window or pixel hashes.

## Evidence

The coverage consists of both boundaries in both catalogue variants on x86 and
x64: eight actual termination/startup cases. Two additional non-crashing bound
workflows verify that the existing source-copy/download scenario is unchanged.
The passing Win64 catalogue-only pilot is reused in this total.

Evidence folders under `G:/HL-b14-external` are:

- `flibrary-crash-Win64-r454` and `flibrary-crash-matrix-Win64-r456`.
- `flibrary-crash-matrix-Win32-r457`.
- `flibrary-crash-regression-Win64-r459` and
  `flibrary-crash-regression-Win32-r460`.

Licensed IDE builds are `flibrary-crash-build-Win64-r453` and
`flibrary-crash-build-Win32-r455`. Native binary SHA-256 values are
`6bc0ea74516d3a6a683352b98dada28921b9ae7444f4cc56892831c00939f6ec` and
`0998b0837850fc24b962b8af39a19568b185e2902b851355b53ee59281729eec`.
The unchanged installed processing packages are `packages-r195`, with verified
official libjxl 0.13.0 archives. Reports retain exact package/codec/helper hashes.
Original local project files were unchanged. The four recovery cases used 367.124 s
on Win64 and 389.592 s on Win32 in total; the two normal bound regression runs
used 238.765 s and 243.719 s. These are small-fixture gate durations, not performance
measurements for a production library. All ten private runtimes were removed.
The independently verified coverage/crash-log aggregate is
`G:/HL-b14-external/flibrary-crash-validation-r461/summary.json`.

## Remaining scope

These cases prove the two critical store outcomes for these generated separate-
image layouts. Interruption inside recovery/cleanup itself, production-scale
indices, remaining older formats, final visual checks and distribution remain
separate gates. No user-library mutation, Desktop replacement or publication is
included.

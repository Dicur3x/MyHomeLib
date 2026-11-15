# Cancellation before compression journal acknowledgment

The ordinary Main window now retains completed compression jobs when the user
cancels the subsequent book-list reload. It acknowledges them only after a
successful refresh. This local fix passed on x86 and x64; final production
applications/packages, Desktop replacement and publication remain separate.

## Reproduction and change

`FillBooksTree` handles a user cancellation without propagating an exception.
Previously `BookCompressionTick` therefore acknowledged completed jobs even
though their refreshed rows had not been published to the visible list.

Before refreshing a changed collection, Main clears the previous cancellation
flag. If that actual refresh is canceled, it enters the existing refresh-error
path: the result explains that the journal is retained, and recovery remains
necessary. It does not immediately start another reload against that choice.
The ordinary recovery hook can subsequently finish the refresh and acknowledge
the unchanged approved result.

This retains the durable journal, not all bulky preparation payloads. Finished
archive preparation is still cleaned per group; retaining every group's scratch
until a whole collection finishes would unnecessarily consume disk space.

## Actual native regression

The optional `--cancel-compression-refresh` fixture uses two generated FB2 books
and an unselected neighbour in one private ZIP on G:. It first performs the
ordinary selected-book menu workflow, including review and an original backup.
It then compresses those books more strongly with the real worker, defers Main's
timer until that worker finishes, and posts Escape immediately before the real
post-compression reload. There is no injected product exception or fault hook.

Before/after cancellation it checks the immutable `job.json`, `receipt.json`
and `completed.json` hashes, the retained pending job and the visible warning.
It invokes Main's ordinary recovery hook in the **same existing window**, waits
for the successful actual list reload and requires acknowledgment. This is not
a new process-death/startup test; existing ordinary-startup crash coverage is
recorded separately in `2026-11-14-compression-preparation.md`.

Recovery must preserve the already-approved archive and original backup hashes,
restore both visible book sizes, preserve reading progress and prepare complete
Reader files with sizes matching the catalogue. The Python parent independently
compares the full non-image FB2 structure and text, selected member names and
the unselected neighbour's exact bytes. Both successful owned runtimes were
removed after verification. No user collection was modified.

## Evidence

All runs below are under `G:/HL-b14-external/`.

| Run | Result |
| --- | --- |
| `cancel-refresh-baseline-Win64-r619` | Harness failure before the target cancellation: the second worker lacked resolved tool paths. Its private runtime was removed; this is not a product reproduction. |
| `cancel-refresh-baseline-Win64-r621` | Corrected harness reproduced the product defect: `Canceled list refresh acknowledged the completed journal`. Its private runtime was removed. |
| `cancel-refresh-fixed-Win64-r623` | PASS, 29.281 seconds including ordinary menu/review, both compressions, cancellation, recovery, independent content verification and teardown. |
| `cancel-refresh-fixed-Win32-r625` | Corresponding PASS, 44.156 seconds, same checks and teardown. |

The source ZIP decreased from 1,288,077 to 122,101 bytes across the two
compressions on both architectures. These timings are not a compression-speed
benchmark. Build reports verify fresh PE architecture, linked fix/test markers
and unchanged project files:

- x64 fixture: `fc6ae21f86c2928215b78a984090af84d0d6c873bd8feffa4097dcf23ad08065`,
  build `cancel-refresh-fixed-build-Win64-r622`.
- x86 fixture: `0e899c844afb213c77a20e716c78d389505c8e9121e61b6385d52824d260a65f`,
  build `cancel-refresh-fixed-build-Win32-r624`.

The current G: production Main executables predate this small fix. Rebuild and
verify the final applications and distributions after the remaining beta-14
changes; these native results do not claim that gate is complete.

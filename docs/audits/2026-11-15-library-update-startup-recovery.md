# Reviewed library updates: real crash and startup recovery

This checkpoint adds startup recovery for the ordinary local catalogue and a
bound local source of a merged catalogue. The complete sources/update feature
and beta 14 release remain open. No Desktop replacement or publication has been
performed.

## Recovery contract

A fresh operation GUID owns an immutable, atomically published job before the
first catalogue write. The job binds the personal-store file, collection ID,
catalogue path and file identity, book root, previous transaction witnesses and
SHA-256 of its mandatory catalogue backup. A live file lease excludes a second
recovery owner. Journal directory guards reject reparse/resolved aliases; job,
catalogue, personal-store and backup files must be regular single-link files.

Before committing, the worker seals the expected logical catalogue state. The
streaming digest includes schema, typed field values, binary/text embedded NULs,
real values, row IDs and WITHOUT ROWID primary-key order. It does not retain a
database-sized serialization in memory. Derived SQLite planner statistics are
excluded. This scan still needs production-scale timing.

Ordinary startup runs recovery after opening the personal store and before the
main form uses a collection:

- Both previous witnesses: SQLite has rolled back the interrupted write; keep
  the old catalogue and finish the idempotent personal-ID remap.
- Both operation witnesses: keep the committed catalogue, finish the remap and
  acknowledge the job.
- Only the catalogue witness committed: require an exact expected digest and
  verified backup under exclusive catalogue locking, restore that catalogue in
  place, then finish the remap. Never restore the shared personal-store backup.
- Changed identities, contents, backup, invalid metadata or an active owner:
  retain the job and backup and report the conflict. Do not overwrite either
  store to resolve it automatically.

The completion record is durable before moving the job into `completed`.
Repeated recovery of an acknowledged operation does not change its catalogue.
Failed recovery appears in a read-only report, and the affected collection
cannot start another reviewed update or the major catalogue-changing commands
already covered by the main-window guard. This is not a universal read-only
wrapper for every old book-editing path; the digest remains the protection
against overwriting later edits.

Recovery and restore progress enforce the system-drive 8-GiB reserve and a
512-MiB target margin, with additional room for the restore copy. Test profiles,
outputs and temporary files are on G:.

## Native evidence

The fixture prepares a real ZIP/INPX update, writes literal review/annotation,
rating, reading progress and favourite membership, and terminates its own
process with exit 73 at the selected boundary. The next process enters the
ordinary data-module startup and creates the real main form. It reads each
surviving book's matching member from its actual archive, checks the expected
book list and verifies a neighbouring catalogue and the input archives/index.
The test catalogue also contains a WITHOUT ROWID table with embedded NUL bytes
and a binary64 value.

Fresh licensed IDE build receipts:

- Win64: `update-journal-build-Win64-r298`, SHA-256
  `cf860d27529c0580281d383b6b5bbb8068c90d1759b2ca9d5839240a78ab26e1`.
- Win32: `update-journal-build-Win32-r301`, SHA-256
  `db5da2d090bf06878ba080ce6dea92623a2f1813767fe177dc8d13bb0cbee58b`.

Six boundaries are exercised in ordinary and bound-source modes on both
architectures: job publication, row writes, before commit, commit start,
catalogue-only commit and both-store commit. The 24 cases are recorded in
`update-journal-matrix-Win64-r303` (11 cases),
`update-journal-recovery-Win64-r300` (bound both-store commit) and
`update-journal-matrix-Win32-r304` (12 cases).

Twelve additional startup conflict cases cover a later catalogue edit, changed
backup, replacement catalogue, replacement personal-store file, changed job
schema and a live owner. Win64 uses the ordinary mode; Win32 uses the bound
mode. `update-journal-conflict-Win64-r302` supplies the first case; the other
eleven are in `update-journal-conflicts-r305`. The Python controller independently
compares all persisted rows/schema of both stores, the retained journal and
backup, and input/neighbour file hashes. These cases stop after ordinary
data-module startup; the warning report's visual layout is not automated.

The separate `update-journal-neighbour-r306` gate writes a new witness for an
unrelated collection into the shared personal store **after** the process crash.
Its four cases check that catalogue rollback retains that later personal data
in both modes and architectures. This specifically detects restoration of the
old global personal-store backup.

The final binaries also passed the existing ordinary/bound update and twelve-case
cancellation regressions on both architectures:

| Platform | Run | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-journal-regression-Win64-r307/cancel` | PASS | 132.422 |
| Win32 | `update-journal-regression-Win32-r308/cancel` | PASS | 133.250 |
| Win64 | `update-journal-regression-Win64-r307/apply` | PASS | 91.828 |
| Win32 | `update-journal-regression-Win32-r308/apply` | PASS | 92.734 |

The aggregate receipt `update-journal-verification-r309/recovery-summary.json`
checks all 40 recovery-case reports, native binary identities, unchanged
unrelated archives and removal of every passing runtime. The four regression
reports are separately aggregated in that same receipt directory.

All passing private runtimes are removed by the controller. Parallel cases use
separate profiles; their elapsed times are not performance comparisons.

## Failures found during development

- `r292`: SQLite's locking-mode PRAGMA returns a row and cannot use the wrapper's
  no-result `ExecSQL`. It now checks the value through `QuerySingleString`.
- `r294`: the catalogue was restored, but Windows refused to rename the job
  directory while its child lease was open, even with delete sharing. A small
  private Windows reproduction confirmed it. The lease is released only after
  the durable completion record; a concurrent retry then handles metadata only.
- `r299`: the external edit fixture tried to update a title without the native
  locale collation. The fixture now modifies its own catalogue probe table,
  avoiding a fake Python replacement for the application's collation.

These failures are not counted as passing gates.

## Remaining scope

This is a small-fixture process-crash check, not proof of physical power-loss
durability, interruption during backup restoration or every acknowledgement
cleanup step. Bounded backup/cache retention, abandoned preparations, selectable
large workspaces, scale/memory timing, pending-conflict UX and production-package
startup remain open. Packed/online/other catalogue modes and legacy-package
dispatch are still separate source-feature work. See the canonical beta 14 Todo
for the complete release scope.

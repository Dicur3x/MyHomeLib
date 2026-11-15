# Transaction witnesses for reviewed library update recovery

Follow-up: [real process-crash and ordinary startup recovery](2026-11-15-library-update-startup-recovery.md)
adds the controller and records its separate evidence and remaining limits.

This is a recovery prerequisite, not a completed startup recovery controller.
The immutable recovery job, verified backup selection and actual process-kill /
ordinary-startup recovery gates remain open. No Desktop replacement or release
has been performed.

## Change

Each prepared application gets a fresh canonical GUID. The catalogue stores it
as `PROP_LIBRARY_UPDATE_TRANSACTION` inside its own transaction. The native
personal store implements the optional `ISystemCatalogCommitWitness` interface
and records that same GUID per collection inside its personal-data transaction.
Writing a witness outside a transaction is rejected. The new interface does
not change the existing `ISystemData` vtable.

Bound-source merges write both witnesses before the existing catalogue and
personal commits. Ordinary updates now also wrap personal-ID remapping and its
witness in one data-update transaction. Cancellation stays disabled for final
commit and rollback; an early failure rolls back the pending personal witness.
The latest witness overwrites only that collection's row, not other collections.
Bound-source post-merge remapping still follows the two-store merge commit;
the future recovery controller must complete that idempotent step before
forgetting a job.

The witnesses distinguish a commit of both stores from a catalogue-only commit.
They are not, by themselves, authority to restore a database. Recovery still
needs an owned job and checks for the correct profile, catalogue binding,
original file identities and usable backup. A shared personal-store backup
must not be restored wholesale over unrelated collections' newer data.

## Missing-property defect found by the witness gate

The first witness run, `update-witness-Win64-r280`, failed on the first
bound-source early rollback. A diagnostic rebuild reproduced it in
`update-witness-probe-Win64-r283`: the public property reader returned a previous
GUID, while an independent read-only SQL query found **no Settings row** for
that property; the personal witness was empty. This was a stale managed Variant
result, not an unreverted catalogue row.

Both catalogue and system `GetProperty` functions now initialize `Result` to
`Unassigned`. The regression interleaves existing/missing catalogue properties
and existing/missing system records, then checks each cancellation outcome
through fresh catalogue and separate personal-store connections. It retains
the independent raw-row diagnostic for future failures.

## Verification

The twelve cases cover ordinary and bound-source updates at row writes,
pre-commit, commit start, first-store commit and completion, plus errors during
rollback and after a durable save. They verify matching committed GUIDs, absent
rolled-back GUIDs, isolation from the previous collection's witness, actual
books, literal personal fields, favourites, baseline publication and unchanged
book archives. These are small private G: profiles, not a production-scale run.

| Platform | Run | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-witness-Win64-r285` | PASS | 65.719 |
| Win32 | `update-witness-Win32-r287` | PASS | 96.312 |
| Win64 | `update-witness-apply-Win64-r288` | PASS, update regression | 78.297 |
| Win32 | `update-witness-apply-Win32-r289` | PASS, update regression | 42.890 |

The ordinary/bound-source regressions above preserve metadata, personal fields,
favourites, priorities and exclusions across repeat/omission/reappearance,
verify download-root continuation and roll back late publication errors.
All four passing runs removed their private runtimes. Some independent runs
overlapped; elapsed times are not comparative performance measurements.

Fresh IDE receipts: `update-witness-build-Win64-r284` and
`update-witness-build-Win32-r286`. Native SHA-256:

- Win64: `31d8db19184ed5ef7769c0ea03f7fc01e821225ca06a937a38b833a7a211ecd0`.
- Win32: `3b97e21eec4c6b076dd98677f310f1d98ca410e381983bf1b83f6e64b8eacc2c`.

The first build r278 failed because this SDK has no `TryStringToGUID`; validation
uses the already supported `StringToGUID` with conversion-error handling.
That failure and the pre-fix witness failures above are not counted as passes.

Next: publish the immutable recovery intent before catalogue writes, connect
verified recovery before the affected collection is used, and exercise real
termination at each durable boundary followed by normal startup. Keep this
prerequisite distinct from that end-to-end recovery proof.

# Shared catalogue forks and registration publication

The transfer journal now handles the metadata prerequisite for a catalogue
registered under different book roots. It preserves one original catalogue for
the selected registration (or first root group), and prepares a separate copy
for each other root group with divergent shared rows. Registrations with the
same canonical root share the same copy. Their personal registration/book IDs,
book roots and source keys stay unchanged.

This is explicit low-level metadata publication on isolated fixtures. The normal
transfer command remains disabled; no user collection or Desktop executable was
changed. Archive/book locator publication is a separate, still-open step.

## Implementation and recovery

`unit_CollectionTransferForks` extends the unsealed review with `ForkSources`,
`CatalogueForks` and `ForkMembers`. Only conflicted database/root groups require
a snapshot. One private SQLite online-backup snapshot serves all forks of that
source. It includes committed WAL pages, keeps every SQLite table and passes
`quick_check`; its identity, size and full SHA-256 are sealed in the review.
Metadata snapshot creation uses G: work storage, cancellation and free-space
checks. It does not register the snapshot or modify the original database.

Source main-file guards deny ordinary writers, replacement and rename. Canonical
parent directories are pinned. WAL fingerprints are included, while absent and
zero-byte WALs are equivalent. Read-only SQLite may open its WAL with write
access, so its read guard permits that open; the guarded main database excludes
normal SQLite writers. A writable catalogue connection must be released by the
future UI/controller before snapshot creation. Later source changes invalidate
the frozen witness and require a new review.

`PublishCatalogueFork` uses the existing verified whole-file copier to publish a
snapshot under the operation's destination `catalogues` folder without replacing
an existing file. The expected input comes from the sealed review, not mutable
state. It verifies the snapshot hash, source witness, registration filename/root,
database key, root token and collection type before changing a registration.
Existing root groups use the directory's volume/file ID, including whole-root
aliases. This distinguishes replacement directories at the same path and does
not merge distinct case-sensitive directories by uppercasing their names.

All registrations in a fork group switch `Bases.DBFileName` in one personal
database transaction, with `synchronous=FULL` and a matching
`HomeLibreTransferForkReceipts` row per registration. A receipt binds the
operation/review, old registration, target path/key and snapshot hash. No book,
note, progress, rating or group row is rewritten. Root-folder publication has
not happened at this stage.

If the process dies after that commit but before the parent state update, native
recovery checks the personal receipts and live target identity, then records the
parent's published state. It does not recopy the catalogue or restore an earlier
database over newer working metadata. An inconsistent receipt, registration or
target fails without overwriting that target. `EffectiveCatalogue` supplies the
committed registration-to-catalogue mapping for the future archive publisher.

## Native evidence

Licensed IDE AutoBuild passed on x64 (r779) and x86 (r780), with their private G:
IDE temporary directories removed. Final diagnostic binaries:

| Platform | SHA-256 |
| --- | --- |
| x64 | `4913c944c8144d304fe9c4e4998aac64fb4731e33fb1e8575752c0dcd56044ba` |
| x86 | `10a9d9e75e3f42c6aa287e1f9ba42c5cc66e2dd4187ab1b998fbc2cae8206e89` |

The final r781 x64 / r782 x86 runs each passed 21 new fork cases and seven
targeted journal/reference regressions, without failures or skips. New cases
took 362.420 / 377.470 seconds; regressions took 185.062 / 170.443 seconds.
Each final run logged 72 native invocations and 17 forced exits: seven fork boundary points,
two exits in the repeated-failure recovery case, and the previous eight group
boundaries. The repeated-failure case leaves SQLite recovery to the
native process; no Python database observer opens personal/state files between
the forced exits and recovery. Earlier r773 smoke checks also passed.

New-case coverage includes one/multiple alternate roots; sharing one copy among
multiple registration IDs; no-copy behaviour for equal roots; WAL-only committed
data; all fixture personal tables/schema and groups; source changes; changed
registrations; a held writable source; cancellation before COMMIT; missing or
forged state; missing receipts; changed snapshots; pre-existing destinations;
and replacement of an already published catalogue. Native `TBookRecord` streams
read the intended different book bytes under roots A/B/C through the resulting
catalogues, rather than redirecting all registrations to root A's book.

Original catalogue and source A/B payload hashes are compared before/after every
invocation. The WAL case additionally compares the original WAL hash. All
personal data is compared table-by-table, allowing only reviewed registration
filenames and the operation's complete receipt groups. Published copies are
compared with the entire source fixture schema/data, and repeat recovery
preserves later personal notes and working-catalogue metadata edits.

The final matrix also guards original third-root files and the replaced root's
old files. Replacing a directory with a different directory at the same path
rejects the old review before registration publication. This tests directory
identity changes; no Windows case-sensitivity configuration was changed.

Earlier evidence is retained: r775/r776 each passed 20 fork cases and seven
regressions before the directory-identity change; r777/r778 added a targeted
third-root hash observer. These are not relabelled as final-binary evidence.

All final private fixture runtimes were observed removed. C: remained around
14.2 GiB free, above the required 8 GiB reserve. Staged/worktree source hashes:
fork unit `b9def8e5912d7892ca4685e1b55128f2cf3fc4870bdea41e76e10c0a6e046f44`,
journal `d7090d060dc1916c03b2417ac2e53c8e6dad431913c1ad96787a672390b7e15e`,
diagnostic DPR `1d4a3eb7777483b41fc0bdc61fdcc740f4d8c67926899a3dda8125e7ec683177`.

These fixtures prove native path selection and metadata preservation, not Reader
window rendering, full-library scale or arbitrary torn-sector/power-loss safety.

## Remaining whole-operation gates

The normal controller must release/reopen affected writable catalogue caches,
coordinate pending compression/update jobs and expose metadata copy counts and
temporary/destination space in the review. Interrupted initial, unsealed snapshot
creation still needs startup discovery and identity-based artifact cleanup.

Archive groups still need locator commits in every original/fork/personal
database, paired publication markers, live reference reconciliation, source-key
and history/cache/profile rebind, native book/resource checks and full stream
checks before source removal. The old root is intentionally retained during fork
publication: final root changes require a new receipt/validation phase.

Snapshot and child-journal acknowledgement/cleanup, recovery after original
removal, missing future-root mappings, large-catalogue performance, normal UI
and post-move updates remain open. Neither a published metadata fork nor a
prepared archive group means the physical move is complete.

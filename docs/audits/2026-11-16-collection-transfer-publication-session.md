# Reusable publication connections and indexed reference snapshots

## Production behaviour

`TCollectionTransferJournal` now retains a `TTransferPublicationSession` across
archive groups. The session pins and reuses the same personal and catalogue
SQLite connections. Each group reacquires BEGIN IMMEDIATE on the personal store
and all reviewed ready catalogues before using its reference snapshot. It keeps
no writer transaction open during the next archive's copying.

A full reference capture runs once, with indexed disk-backed approved/current
rows for all groups. Group checks use FileID/GroupID indexes. The exact writer
connections retain PRAGMA data_version baselines: own commits do not alter that
value, while a commit by another connection invalidates the snapshot at the
next locked boundary. There is no post-commit baseline update that could swallow
an intervening writer. Notes and unrelated edits can trigger a fresh capture
without being reverted; new references/registrations still require a new plan.

Snapshot invalidation also checks previously unknown catalogue files. A missing
catalogue that arrives cannot remain hidden behind an unchanged personal store.
An existing unknown catalogue forces a fresh capture because the session cannot
prove its unchanged readable content. Errors roll back outstanding transactions,
discard the session and preserve sources plus prepared-copy journals.

A fresh capture recognizes saved prepared destination identities across groups,
including groups published before a process interruption. These aliases only
identify candidate references. They do not authorize publication or deletion:
each current group still requires complete verified prepared leases, exact
native old/new row projection, the matching immutable review and durable
per-database receipts. The publication session is freed before review/state
connections when its owning journal is closed.

## Verification

Both licensed IDE AutoBuilds passed and their temporary directories were removed:

- Win64 r806: `45c60857f1c3e844d3c4aaf3cc26ad835cb57ab85a481ec924c379bcc42311e9`.
- Win32 r808: `2320a9f565b281603f44de78572da8a68b9581edf2d5f820e2b59ffd03ec3d2c`.

The verification covers 24 distinct methods per architecture:

| Platform | Main matrix | Corrected observer scenario |
| --- | --- | --- |
| Win64 | r807: 23 PASS, one observer failure, 505.855 s | r811: 1 PASS, 37.226 s |
| Win32 | r809: 23 PASS, one observer failure, 526.827 s | r812: 1 PASS, 33.699 s |

The main matrices intentionally retain their overall FAIL status. The native
new-reference refusal was correct, but the observer expected sqlite_sequence
Books=3 after its own explicit insertion of BookID 991. The test now expects
that deliberate sequence advance; only that failed method was repeated. Its
corrected pass also removes the deliberate extra row and resumes the same
journal with zero copy streams. Diagnostic r810 independently preserved the
observer traceback; no production code changed for this correction.

Every architecture has 44 JSON-recorded native invocations across its main and
corrected runs plus one separately observed writer-lock process. Four expected
forced exits cover both sides of catalogue/personal commits. All native results
match their requested success/refusal/exit codes; all private runtimes were
removed. Per-run summaries and an aggregate-summary.json beside each corrected
run record exact coverage. These are 24 covered methods, not a claim that the
original main matrix had zero failures.

Both platforms prove exactly one full capture across 26 independent archive
copies. External title, personal-note and WAL commits each cause exactly two
captures across two groups. The title commit occurs immediately after the
catalogue commit, proving that an intervening writer is not acknowledged as an
own write. A new reference between groups is refused before publishing that
group; a previously missing catalogue is rechecked. The retained former fence
scenarios cover process interruption/replay, raw/FBD, detached-image groups,
writer locks, new cards and atomic locator/history rollback.

Source hashes (matching staged build inputs):

- Publication: `5483822acce4ef74bf701c3ef5b8f27bcffc30e192d9a5b420d4a500ac6f98f2`.
- Snapshot: `6bfd4c294587973281d7cfd18bcd2f248038e178e747522291d82881b025f988`.
- Journal: `d505e02ac7e522606fdc7b2dc14da841b6d2776a394cd113f1e22ca2117e0ce8`.
- Diagnostic: `16e05e7566a656be8d9cd68295cb93466fe9c88b424ad6e1e745a12f172e5bd6`.

## Limits and remaining whole-operation work

This cache proves database-reference reuse between group publications. Group
source roots, negative paths, prepared file identities and image sets retain
their existing live checks. Database versions do not prove that arbitrary
outside filesystem resources stayed unchanged. Source removal therefore still
requires its own fresh coordinated reference/resource inspection, native image
mapping and full-stream verification, durable removal intent and recovery after
an original disappears. The cached snapshot must never authorize unlink.

The 26-group fixture proves one capture rather than 26; it is not a timing
benchmark for moving the real library. Full-scale measurements, unknown-source
retention/space estimates, DAO/pending-job coordination, final root/index/cache/
profile publication, missing books, startup recovery/UI and final distribution
remain open. No ordinary move command or source deletion is enabled here.

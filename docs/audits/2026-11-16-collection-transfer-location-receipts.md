# Source-free location receipt verification

The transfer registry can verify a prepared or recovered group's saved
locations and per-database receipts. This is a read-only checkpoint, not an
unlink permission or a completed transfer. No user collection was moved.

## Binding and native projection

Registry.VerifyPublishedGroup obtains the independently recorded group digest
and compares it with the actual held prepared identities, hashes, streams and
native picture mapping. This reuses the verified stream leases rather than
rehashing a large archive during the ordinary live path. Recovery still fully
hashes destinations before returning those leases.

ApplyTransferLocations now has an explicit VerifyOnly path. It reconstructs the
expected native locator kind from the frozen logical container without probing
the original name. ZIP-to-7z fallback preserves that kind; native validation of
the resulting destination still applies. The live main/copy/personal locator
fields, source keys, library IDs and inside indices must match the projected
result, and the exact operation/group/review/binding receipt must already exist.
An old locator with a legitimate receipt is refused. Missing/changed receipts
are never recreated or repaired by verification.

The path does not create tables, register write triggers, update locations,
rebind compression history, acknowledge cleanup or mark an operation complete.
Deleted optional personal cards stay deleted. Newly created personal locators
that still name an original require publication before verification; ordinary
republishing reconciles them without restoring an older note/progress snapshot.
Retained/unresolved personal locators are counted, not silently treated as
permission to delete a source.

## Coordinated database view

The publication session shares one lock-acquisition routine between writing and
verification. Verification starts writer transactions on the personal database
and every ready effective catalogue, captures fresh live references and then
checks all receipts/locators. It rolls back its read-only transactions on normal
return, cancellation or failure. A native probe on separate connections proves
that every ready database rejects a writer during the check and accepts one
afterwards, including forked catalogue configurations.

Session connections now preserve the existing journal mode when opened. This
avoids changing database bytes merely to verify them; application-managed WAL
connections stay WAL. Ordinary publication retains its existing reference-cache
behavior. A verification intentionally requests a fresh capture; its full-scan
cost is not a claimed final large-library cleanup optimization.

## Native evidence

Both licensed IDE builds passed with exact staged/worktree source equality,
unchanged projects and removed owned IDE temporary folders:

- Win64 r856: `3d4a785099a882dde1a0e58f7a380e2260a2cfdd56b2223344a4457616a5ee15`.
- Win32 r858: `663298ebecac7d62f449b7700caf140355763dbd709a02580248e0836f36f327`.

All runs are under G:/HL-b14-external:

| Platform | Main matrix | Additional cases | Publication regressions |
| --- | --- | --- | --- |
| Win64 | r857: 21 PASS, 652.365 s | r862: 2 PASS, 79.383 s | r860: 2 PASS, 200.431 s |
| Win32 | r859: 21 PASS, 689.876 s | r863: 2 PASS, 79.615 s | r861: 2 PASS, 203.255 s |

Each architecture covers 25 distinct methods: 15 new receipt cases, eight
existing locator cases with verification enabled, and two publication/session
regressions. A focused repeat of the existing forked-catalogue case with writer probes
enabled also passed: Win64 r864 (27.386 s) and Win32 r865 (27.436 s). This is
stronger coverage of an existing method, not an extra distinct method.
Each architecture has 59 JSON-recorded native invocations including six expected
forced exits. All 118 return codes match expectations; final runs have no
failures, errors or skips. All successful owned runtimes were removed, as
checked in each summary.json. These totals are diagnostic durations, not
library-transfer throughput.

The cases cover current source-held groups, absent originals, shared native
picture groups, FBD/linked files, divergent shared-catalogue forks, missing
catalogue/personal receipts, a changed receipt digest, a stale live locator,
late personal cards and their republishing, deleted optional cards, changed
notes/rating/progress, cancellation, two consecutive verification process exits,
all writer locks and released locks. Full database/state hashes stay identical
during verification-only cases. Extra cases prove that preparation proofs alone
do not establish a location commit, that the same journal can continue normal
publication, and that absent old roots or a foreign file recreated at the old
name do not invalidate the verified destinations or alter the foreign file.

The ordinary registered 26-group publication still uses one reference capture;
a real external WAL commit still causes two captures and retains the new note.
Thus fresh receipt verification did not replace the normal publication cache
with a per-archive rescan.

## Remaining whole-operation work

This check releases its database transactions when it returns. Its result must
not be cached as authority for a later unlink. The cleanup coordinator still
needs independently durable exact removal intent, a coordinated current
registry/reference/receipt view at the removal boundary, retained-source
classification, strict source identity/stream guards and recoverable per-file
unlink. Normal job/DAO coordination, startup and Sources UI, final roots,
missing/future book paths, update profiles, Reader cache, space accounting,
large-library measurements and final release remain open. Fresh reference
scanning itself can inspect currently registered paths; the source-free claim
concerns reconstruction from frozen original locators, not a ban on diagnosing
an incomplete live registration.

Exact final build input SHA-256 values:

- Program/Units/unit_CollectionTransferLocations.pas: `b3d9e1fefe8bd03d1f87b2a722d60659fcfa63b5c9f9f614ff69f5663a213378`.
- Program/Units/unit_CollectionTransferPublication.pas: `d18e213b957ba13f3fef2287436098feb80f49cca4593a4e841827542624068a`.
- Program/Units/unit_CollectionTransferJournal.pas: `a3f3c61e6e3d5e664b650c67192d35e8dcac182455ea6afff33ff0e989489bc8`.
- Program/Units/unit_CollectionTransferRegistry.pas: `a298cff7ffda599aa6131767925788090d7e7e854217b9cd832095c709cbe0d1`.
- tools/ui/tests/CollectionTransferJournalTest.dpr: `1db8b0227bb17ad3492d72ef24e6e5a0588f14d7cfbbdf1ef5804e711299f73f`.

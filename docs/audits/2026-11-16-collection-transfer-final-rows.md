# Final missing-book locators and alternate-copy roots

## Implemented transaction primitive

`ApplyTransferFinalRows` now writes the unavailable primary, alternate and
personal locators computed by the frozen-layout projector. It updates only
Folder/FileName and explicit alternate-copy Root fields. Book/source keys, IDs,
extensions, internal numbers, sizes and personal data retain their meanings.
Relative copy roots are expanded before mapping into the final source tree.
Empty copy roots continue to inherit the collection default.

The caller must retain database-file leases and writer transactions, a verified
review, published-group proofs and independently recorded finalization intent.
The function checks the personal/selected catalogue file keys and operation
identity. Each row's immutable locator fields must still match; old/new locations
are accepted only before the first final-row receipt. Deleted personal cards are
not recreated. Missing non-personal rows or changed locator identity are errors.
Both the old and future missing paths must remain genuinely absent; access
errors are not converted into absence. An arriving foreign file is preserved
and prevents publication under the old review.

The same transaction records `HomeLibreTransferFinalRows`, binding the operation,
review digest, supplied intent digest, database key and deterministic changed-row
description. An existing receipt is checked rather than overwritten. Verification
requires the existing receipt and new fields and performs no DDL or row writes.
Cancellation/exception requires the owning controller to roll back its transaction.

This is an internal row-writing component, not whole-operation finalization.
It does not change source/profile settings, default registration roots, copy book
payloads, delete originals or complete the operation. The normal move command
remains disabled. Once copy roots change, the future finalization recovery route
must verify final-aware receipts instead of restarting ordinary group application
against the original Root fields.

## Native verification

The diagnostic invokes the actual production row primitive on its private
catalogue and personal writer transactions after the existing production
available-file phase. Its intent digest is explicitly fixture-local: this is not
evidence that the independent whole-operation intent/controller exists. The
driver commits each store separately only to exercise these row primitives;
cross-database crash completion remains a separate integration gate.

Licensed IDE builds with exact staged/worktree native inputs:

- Win64 r906: `2d051b8fb829aa04dd2efdec3751dbd7dd1b057e79e1f5eb1140752140fcdc05`.
- Win32 r907: `a093797d0ad2f34799c1e84bbff2915ad503aec84c2855ea13f1944665c72de0`.

The initial r905 compiler attempt failed because Delphi cannot capture local
named routines or the function Result in an anonymous procedure. Unit-level
helpers and a captured outcome record correct this; that failed log remains.
No IDE/licence settings were modified. Build temporary directories were removed.

Evidence under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| transfer-final-rows-Win64-r908 | Four new row methods plus a source-fork/replay regression PASS, 116.681 s, 11 native invocations. |
| transfer-final-rows-Win32-r909 | Same five methods PASS, 120.923 s, 11 native invocations. |
| transfer-final-rows-extra-Win64-r910 | Three extra row methods PASS, 54.197 s, five native invocations. |
| transfer-final-rows-extra-Win32-r911 | Same three methods PASS, 45.515 s, five native invocations. |

Seven new methods and one prior regression pass per architecture: 32 native
invocations, including eight expected refusals, no forced exits, unexpected
returns or skips. All owned runtimes were removed. Each summary retains counts,
input hashes and cleanup; diagnostic durations are not throughput estimates.

The successful transaction changes three missing locators and two copy roots;
every other existing table/field is compared through the existing independent
available-publication observer with explicit expected missing-archive changes.
Sources JSON and selected default root remain original, and the operation stays
pending. Readonly verification leaves both complete database SHA-256 values
unchanged. Cancellation after the first actual missing-row write rolls back all
rows/receipts; a later retry succeeds. Changed missing-book identity and a foreign
file at the future address cause refusal without changing either store. Relative
copy roots work; a deleted missing personal card stays deleted; a changed receipt
is refused without repair. The source-registration fork/replay regression passes
with the new driver branch disabled.

Final modified native SHA-256 values:

- `unit_CollectionTransferFinalRows.pas`: `9154611458624326b749e011f5003b2f26b4519a1f3a356b2e6b85bd57a78428`.
- `CollectionTransferJournalTest.dpr`: `244437dd65fac55903964efaa962e2fa702863cf56ce533103c335df27ac72fe`.

## Remaining gates

Independent finalization intent, final-aware resume, coordinated source/profile
settings and registration commits, late-card reconciliation, retained source
indices/cache, Reader/live DAO/jobs, startup/Sources UI, space/cleanup, large and
cross-filesystem trials, post-transfer updates and final production/release checks
remain open. No working collection, Desktop installation or public artifact was
modified by this work.

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

Initial modified native SHA-256 values for r906/r907:

- `unit_CollectionTransferFinalRows.pas`: `9154611458624326b749e011f5003b2f26b4519a1f3a356b2e6b85bd57a78428`.
- `CollectionTransferJournalTest.dpr`: `244437dd65fac55903964efaa962e2fa702863cf56ce533103c335df27ac72fe`.

## Copy-root semantic guard

A final review identified an extra boundary: changing Root must not silently
redirect an available copy whose relative Folder has not actually been
published, or which deliberately retains an old address. Before a changed copy
root can be written, the primitive now compares the native logical file path
and book format with the old/new root. A relative unpublished locator which
changes its meaning is refused, rolling back earlier missing-row writes too.
Already published absolute and reviewed future locators retain their meaning.
This guard does not replace whole-operation available-location receipt checks.

Final licensed builds are Win64 r912, SHA-256
`53aa52168617efd52a416e20f7ad93726b7f375f534ba6fef14a95c8829f3a81`,
and Win32 r913, SHA-256
`6e3c1ea636e1b258e03b495a55b017088d33dfae6622fd7fa17b6fa84e4218ed`.
The final row unit hash is
`f6641ecb563883cea45a2eae5ea8c0b3165ee6c7da1d8a2426816d4e4d6211b7`;
the driver is unchanged.

The ordinary final apply/readonly verify and relative-root methods passed on
x64 r914. Its third negative method received the expected native refusal, but
the ordinary observer incorrectly treated a previous group receipt as an
instruction to restore the intentionally stale Folder. This observer failure
is retained: r914 is not a passing matrix. For this negative case the corrected
observer directly compares complete before/after schema/table snapshots, with
no projected mutation allowance. The negative method passes alone in x64 r916
(26.957 s); all three methods pass together in x86 r915 (58.110 s). r914's two
passing methods account for three calls; its two observer-failed-method calls
are excluded from passing evidence. All three owned runtimes were removed.

Including the earlier row stages, eight new methods and one existing regression
pass per architecture: 42 native invocations belonging to passing methods,
including ten expected refusals, no forced exits/unexpected returns/skips.
The two additional observer-failed invocations remain separately recorded.
Each stage summary retains its actual status, input hashes and cleanup.

## Remaining gates

The subsequent independent roots-intent phase, final-aware resume, coordinated
source/profile/default-root commits and late-card handling are recorded in
`docs/audits/2026-11-16-collection-transfer-finalization.md`. Retained source
indices/cache, Reader/live DAO/jobs, startup/Sources UI, space/cleanup, large and
cross-filesystem trials, post-transfer updates and final production/release checks
remain open. No working collection, Desktop installation or public artifact was
modified by this work.

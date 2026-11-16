# Leased stream witnesses and native external-picture mapping

## Production checks

`TTransferPreparedCopy.CheckUnchanged` compares both current physical paths,
full file identities and stream names/sizes against the retained snapshots and
immutable source identity. Existing data streams stay pinned against writes and
replacement, so their previously verified full SHA-256 values remain usable.
The check does not reread every archive. Every prepared result runs this check
before it is returned, including already-in-place and resumed files.

A new independent native probe found a real gap in the rename handoff: the
initial output snapshot shared DELETE for the rename, and its named-stream
handles kept that sharing afterwards. A competing DELETE open on a named stream
was possible even while the default-stream replacement guard was held.
`PinPublishedStreams` now reopens every published stream with strict sharing.
It rehashes named streams under those new handles before accepting the old
checksums, then replaces the old handles. The default data stream remains under
its verified read lease and same-file replacement guard throughout; large
archive contents are not rehashed for this handoff. Resumed/in-place snapshots
already have strict sharing and skip this extra handoff.

`ValidateTransferResources` requires exactly the immutable group's files. It
checks all prepared source/destination mappings and stream witnesses, then calls
the application's native FLibrary picture discovery at each original and
copied owner path. Every nonempty original cover/image slot must resolve to the
mapped prepared sidecar's exact destination identity; an originally empty slot
must remain empty. Shared sidecars are validated for every owner. Foreign new
pictures, missing pictures, wrong mappings and incomplete groups are rejected.

`VerifyGroupResources` runs before locator publication. A versioned per-group
resource digest binds the review, file identities/hashes/streams and native
image mapping in a FULL-sync SQLite transaction. Existing differing receipts
are refused rather than overwritten. Cancellation and interruption around that
receipt remain replayable; no original is removed. This resource receipt alone
is not a catalogue-publication acknowledgement or removal authorization.

## Native evidence

Final matrices r817/r819 and in-place cases r822/r823 use the licensed IDE builds:

- Win64 r816: `b495f177af6e7efe47664a002dd1d485cbf641928c0bd4e956a3081eafcf6f6f`.
- Win32 r818: `e9eff7e6dbd56c0f204c88bb938c139b96744f9d11a626ac3d19342f4a8c1063`.

Their staged/worktree sources match, and IDE temporary directories were removed.
All 18 methods per architecture passed without failures or skips:

| Platform | Main resource/location matrix | Already-in-place case |
| --- | --- | --- |
| Win64 | r817: 17 PASS, 416.498 s | r822: 1 PASS, 39.279 s |
| Win32 | r819: 17 PASS, 411.744 s | r823: 1 PASS, 38.916 s |

Each architecture used 35 native invocations, including six expected forced
exits at resource and catalogue/personal commit boundaries. Per-run summary.json
and aggregate-summary.json record exact native codes and runtime cleanup. Every
successful private runtime was removed.

The named-stream case attempts independent GENERIC_WRITE and DELETE opens on
both main and named streams of source and destination; all fail with sharing
violation while prepared leases are held. Afterwards, independent reads prove
exact named-stream payloads on both originals and both copies. Other cases
prove shared image mapping (four files, two owners, four resource slots),
rejection of a foreign target cover, cancellation without a receipt/locator
change, corrupted-receipt rejection, both resource commit boundaries, repeated
publication, raw/FBD and shared-catalogue forks. The 26-group session still uses
one full reference capture and records 26 resource validations. Atomic history
rollback remains intact. Already-in-place inputs use zero copy streams.

The earlier r814 matrix is retained as failed/stopped evidence of the named
stream sharing gap; its other passing cases are not substituted for the final
build. The first in-place fixture r820/r821 pointed at its runtime root itself
and correctly hit the native isolation guard. The corrected fixture uses a
separate owned subdirectory containing both private source roots; no guard was
weakened. Input paths are checked before moving these private fixture folders.

Source hashes:

- Copy: `cdfe602f043dce24a108a9ad3d399db94b9082ae8ec0798375df09fa4d08b5d5`.
- Resources: `670078e19f36b119260844669e4a59f272754dbe530f5f995a176b4d63af01fa`.
- Journal: `f5e18c6a41056a1dd8e296984c56017a810377eeb8f6bab5ca6afcc4744eaafd`.
- Diagnostic: `23b462934fb08a4748034229aae976238a617ffa93df40f88d253fa1152f915e`.

## Remaining whole-operation gates

These checks cover files that still have complete prepared leases and their
originals. They do not extend the file-copy resume primitive to originals that
have already been removed. Source cleanup still needs a fresh complete live
reference/resource session, all catalogue/personal publication receipts, durable
per-file removal intent, exact handle-based ownership/removal and recovery after
an original disappears. A retained resource receipt is never sufficient by
itself to unlink an original.

Live/unknown references, filesystem arrivals after this check, Reader cache,
final source/index/profile/root publication, missing/future books, pending DAO
and update/compression jobs, child acknowledgement/cleanup, ordinary startup/UI
and real-scale transfer measurements remain open. Source-removal and ordinary
move commands remain disabled; user working archives and Desktop files were not
modified by these private fixtures.

# Independent surviving-destination verification

## Production API and trust boundary

`TCollectionTransferCopy.VerifyDestination` validates a previously prepared
separate destination using `TTransferDestinationProof` supplied independently
by its parent operation. That parent must bind the proof to its durable intent,
immutable reviewed entry, operation and complete group. Reading the mutable
child state alone must never create that authority.

The existing child manifest/entry binding and exclusive owner lease still apply.
The child must be in ready state with the expected target identity/key and
stream description. The destination must have the original reviewed byte count
and exact recorded physical identity. Its current main and named streams are
opened with strict read leases, fully hashed and compared to the independently
supplied SHA-256/stream witnesses. Same-size/time changes and an identical-byte
replacement with a different file ID are refused.

This path does not inspect, read, recreate or remove the source name. It works
when the old file or its parent is absent, and leaves a different file at that
old name alone. Destination directories must already exist; none are created.
It performs no copy, state rewrite, catalogue publication, removal acknowledgement
or operation-complete transition. Repeated cancellation/process interruption
leaves the same journal and destination available for another verification.

Returned `TTransferPreparedCopy.SourceHeld` is false. Its explicit
CheckDestinationUnchanged remains valid under the retained destination leases;
CheckUnchanged refuses the absent source lease. The ordinary Prepare path still
requires a real source and never silently switches to destination-only mode.
Already-in-place entries cannot use the separate-destination recovery API.

## Native validation

Licensed IDE AutoBuilds passed with matching staged/worktree sources and removed
temporary directories:

- Win64 r824: `25c73a0338717166bc2432492e8376176c47f24a364560348ee4adea3c78d35d`.
- Win32 r826: `958ccd49fa349415a50341e01d3df5c53441cd9416a32c5a29ad3a16f75aa6b2`.

| Platform | Run | Methods | Seconds |
| --- | --- | ---: | ---: |
| Win64 | transfer-destination-Win64-r825 | 39 PASS | 33.767 |
| Win32 | transfer-destination-Win32-r827 | 39 PASS | 32.596 |

Each architecture passed 14 new destination cases and the prior 25 copy cases
without failures, errors or skips. There are 90 JSON-recorded native invocations
plus one independently observed concurrent-owner process per architecture;
19 expected forced exits include repeated destination verification interruption
and the prior copy/recovery boundaries. All native return codes match expected
success/refusal/exit values. Every private runtime, including the old cross-volume
fixture, was removed. Per-run summary.json files record counts and cleanup.

The new cases verify missing source/parent, reused original name, ordinary
source-required rejection, explicit source-lease rejection, wrong independent
proof, altered/rehashed child metadata, changed data and named streams with
preserved size/time, correct named-stream retention, same-byte replacement,
missing destination parent, cancellation and two consecutive process exits.
The independent proof and child JSON bytes stay unchanged during verification;
no copied data is rewritten. The old regression matrix retains genuine E: to G:
copying, NTFS streams, long Unicode paths, collision ownership, readonly flags,
interrupted recovery and the single-owner lease checks.

Source hashes:

- Copy: `999f6ecded5406a2f17fd7099055e25c233866eeabff276bd7f8e4c20343c86d`.
- Diagnostic: `cafcba1feeb06d4482c6ebc01010f26dbcdea920ed6880796a5ac2036a9bb2d1`.

## Remaining collection-level work

This is the file primitive for checking a surviving destination. The collection
journal does not yet call it after an original is removed. It must first durably
seal/bind its independent group/file proofs, reconcile all live references and
catalogue/personal receipts, record exact removal intent, perform guarded source
unlink and recover mixed removed/retained groups and native image mappings.
Fresh filesystem checks, pending DAO/job coordination, Reader cache, final
roots/indexes/profiles, missing/future books, startup/UI and full-scale operation
checks remain required. No user archive is removed and no normal move command
is enabled by this checkpoint.

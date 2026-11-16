# Physical consolidation: durable source and history cutover

This checkpoint connects installed cache versions to their participating
catalogues. It is native controller evidence, not completion of the transfer UI
or of beta 14. The ordinary command remains disabled and the whole operation is
still pending.

## Implementation

`TCollectionTransferCachePreparation.PublishMetadata` requires the independently
prepared cache intent, proved final roots and every fixed persistent version.
It reconstructs the installation set from the personal records, verifies their
bindings, redundant paths, directory identities, exact named files and hashes,
and holds the installed outputs under read leases throughout publication. Ready
work snapshots and original cache/input folders are not needed at this stage.

The personal `HomeLibreTransferCachePublication` intent binds the immutable
review, cache intent, roots intent and complete installation-proof set. It is
committed before catalogue settings change. Each catalogue writes both its source
settings and independent update-history settings with a
`HomeLibreTransferCacheMetadata` receipt in the same transaction. The receipt
includes its database identity and both exact resulting JSON hashes. The writer
is reacquired after commit and `data_version` detects an intervening foreign
writer. Only after every receipt and current setting is proved does the personal
publication marker become `published`.

The roots controller now opens a validation guard inside its existing publication
session. A participant with a matching metadata receipt is authorized to use the
exact planned new sources/history; others must retain the roots-only sources and
old history. No nested finalization transaction is started. Replaying roots
cannot reset a successful cache cutover, accept arbitrary edits or invent a lost
receipt. Installed versions remain pinned during those checks.

`TCollectionTransferOperation.Run` exposes the optional `PublishCaches` phase.
An existing publication intent forces its continuation even when the original
option is absent. A successful replay without intervening changes leaves the
catalogue and personal database files byte-identical. Overall-operation completion
and startup/UI routing are separate unfinished gates.

Installation recovery validates the entire manifest filename set before opening
any member. Even a rehashed altered manifest cannot redirect a read/lock to a
foreign file before its name is rejected.

## Validation

Licensed IDE builds of the native adapter succeeded for both platforms:

- Win64 r988: `916b9bc4bd4245aafa23f7c797a8de9fa6e67d3f2968964959e68df18c408ccd`.
- Win32 r990: `70e9346cc15298964afc7b4e41ce27361e8037d98b8e0a322ed87ff06145a349`.

Final coverage and input hashes are recorded under
`G:/HL-b14-external/transfer-cache-metadata-final-r997`. The two matrices r991/r992
were explicitly interrupted for the user's pause. Only completed methods whose
log line ends in `ok` count; unfinished methods were resumed in fresh private
stages r993/r994. The earlier Win64 r989 direct smoke run completed two methods;
its observed terminal result is documented separately from its persisted native
invocations. Interrupted reports are retained without being relabelled PASS.

In total, **18 methods per architecture** passed (13 metadata and five earlier
regressions): **84 native calls**, 18 expected forced exits and 18 expected
refusals, with no unexpected codes or skips. Twenty-nine native inputs match the
staged build and recorded matrix inputs. The completed r993/r994 and regression
stages removed their private runtimes. The two explicitly interrupted runtimes
remain: automatic approval review rejected the bounded, ownership-checked cleanup
with `blocked by policy` and supplied no further reason. No retry was attempted.

The thirteen metadata methods per architecture cover six publication commit
boundaries, cancellation before a catalogue commit, a two-database partial commit
with old caches and work snapshots offline, exact new source/history references,
native book hashes through installed versions, byte-identical replay, preservation
of later notes/ratings/progress, a foreign writer in the commit gap, missing
catalogue receipts, changed source/history settings, altered installation or
publication records, missing independent installed proofs and a rehashed manifest
attempting to open an exclusively locked foreign path. Earlier installation,
preparation, roots, metadata-model and legacy coordinator methods are checked on
the same final binaries. Tests use private data on G:, never user collections or
the forbidden E: drive.

## Remaining

Prove a real full/incremental INPX update after this cutover with only a new
incoming archive, preserving saved publisher/source/review keys, old compressed
payloads, sizes, copies and personal fields. Coordinate normal DAO/Reader/jobs,
route pending recovery before ordinary updates, persist complete-operation state,
and finish ownership-aware cleanup and complete space accounting. Large-cache
performance, actual cross-volume/filesystem cases, visible stop/resume and final
Main/package checks remain required. Desktop applications and public packages
have not been replaced.

# Independent cache preparation before source removal

## Implemented behavior

`TCollectionTransferCachePreparation` connects the replayable metadata model and
work-volume snapshots to the production personal transfer registry. The native
coordinator can request preparation before its first archive group. An existing
independent preparation intent is enforced on continuation even when the caller
does not supply the option again. The ordinary transfer command remains disabled.

The personal database records an operation/review-bound intent containing the
exact participating database keys/paths, current data root, source/history
presence and before/after values, semantic jobs, fixed new versions, raw inputs
and original cache/input file identities. Under the publication session's writer
locks, the controller reconstructs the model with those fixed versions and
compares the entire generated metadata/job/input plan. A rehashed mutable intent
cannot substitute a different layout. Current source/history values must still
match; an authorized completed roots phase is checked through its own controller
before preparation accepts the roots-only settings projection.

All original cache writers and raw inputs needed for a new intent are acquired
before its durable personal commit. A cache registered as a participating
catalogue borrows that same already-locked SQLite connection instead of opening
a competing writer. The snapshot API validates the borrowed connection's main
file identity and active transaction; it neither owns nor closes it. Other cache
connections are owned by the preparation controller. File identities are checked
again when an unready job resumes. Original caches and raw inputs are not written.

`HomeLibreTransferCacheIntent`, `HomeLibreTransferCacheStages` and
`HomeLibreTransferCacheClaims` live outside the mutable child snapshot. Directory
and file claims commit before large writes. Each ready digest commits only after
the snapshot has flushed its manifest and checked every output. Old attempts'
claims remain when a fresh attempt changes the latest stage pointer. Prepared
objects retain all verified output read leases together until the complete
dependency set has been rechecked and its personal state committed. The initial
multi-job preparation has a native denied-write probe for every ready cache.

A matching ready record recovers by independent directory identity, binding and
manifest digest, including when its original cache and index are offline.
Unready attempts require the original identity and start a fresh owned snapshot;
they are not guessed complete. Once the personal intent says `prepared`, a
missing ready proof is a refusal, not permission to recreate it from child JSON.
Cancellation or process termination preserves the independent records and any
work that cannot yet be safely cleaned. The operation still remains `pending`.

The sequential source-removal phase starts only after all requested dependencies
are prepared. A bad second index must therefore preserve every original archive,
even after the first cache has become ready. This is dependency preparation, not
publication of a persistent cache version or completion of the physical move.

## Native evidence

The private fixtures compare every existing catalogue/personal table and field
against independently modeled locator/root changes, all original cache/index
bytes, archive contents, unrelated neighboring files, durable ownership records
and independently hashed prepared outputs. They use real SQLite schemas and
real ZIP containers on G:, not the user's live library.

Licensed IDE builds use the same 28 staged/worktree native inputs, recorded in
each final run's `native-inputs.json`:

- Win64 r966: `7840c9448fbf8156d7a609e3579d019d9f12314f7054ad282b51a443f3d00223`.
- Win32 r967: `c2270b4acb99d71b4ab171a6b31e3b6c37950c8ff05736a931cf6d969441598d`.

Final coverage is `G:/HL-b14-external/transfer-cache-preparation-final-r974/coverage.json`.
It selects only complete passing methods from the following reports, checks
their exact native return codes and compiled-input/binary identities, and excludes
the failed methods rather than relabeling an unsuccessful report:

| Report under `G:/HL-b14-external/` | Selected passing evidence |
| --- | --- |
| transfer-cache-preparation-Win64-r970 | 19 preparation methods; the old second-dependency observer is excluded. |
| transfer-cache-preparation-regressions-Win64-r972 | Corrected second-dependency method and four earlier regressions; 11 native calls, 109.329 s. |
| transfer-cache-preparation-Win32-r969 | 14 preparation methods; six methods needing observer corrections are excluded. |
| transfer-cache-preparation-corrected-Win32-r971 | Those six corrected methods; 17 native calls, 191.891 s. |
| transfer-cache-preparation-regressions-Win32-r973 | Four earlier regressions; nine native calls, 96.469 s. |

Twenty preparation methods and four earlier regressions pass per architecture:
**102 native invocations in passing methods**, 28 expected forced exits and
18 expected refusals, with no unexpected returns or skips in that selected
coverage. All private runtimes, including failed observer trials, were removed.
The four regressions cover committed WAL preservation, original writer blocking
and release, unchanged snapshot/input recovery, fixed metadata replay and the
older sequential coordinator with no cache-preparation request.

New cases include independent claims/readiness, writer reuse for a registered
cache, all six personal commit boundaries in sequence, cancellation, missing
source/history settings, a ready-stage crash with its old cache/index offline,
fresh preparation of an unready stage, changed history/source identity, changed
ready bytes, missing independent proof, a rehashed redirected intent, initial
denied-write guards across multiple ready caches, actual coordinator removal
ordering, mandatory existing-intent replay without the original option, a bad
second dependency after the first is ready, authorized root publication and a
partially committed root phase followed by continuation.

Early r964/r965 reports are retained as failed observer trials: the changed-history
case incorrectly retained the pre-fault expected metadata, and two crash cases
incorrectly required an abruptly killed live-reference scratch store to disappear.
Those are separate from the native refusal/recovery outcome. The later r968
probe trial also incorrectly required not-yet-recovered ready jobs to be locked
at the first replay callback. The denied-write probe is scoped to initial
multi-job preparation; recovered objects are still validated and retained by
the same controller. Failed reports are not counted as passing methods.
The old second-dependency observer assumed source order instead of the semantic
job hashes, which include private runtime paths. Its corrected test first freezes
the review and inspects the plan, then corrupts the input of the actual second
job before preparation. r970/r969 remain unsuccessful reports; only their complete
passing methods contribute to the final coverage above.

## Remaining boundaries

Persistent version directories/files still need exclusive reservation, verified
copy/publication, durable ownership and independent recovery proofs. Source and
history references need per-database atomic receipts, partial-publication replay
and authorization through the prior roots controller. Old shared baselines must
remain usable by other collections. The work-stage snapshots cannot be advertised
as those persistent versions.

Normal DAO/job/Reader coordination must prevent concurrent update/compression
work, account for changing original baselines and preserve reading identity.
Whole-operation completion/discovery, ownership-aware cleanup (including killed
reference scratch stores), complete space estimates, real cache-scale and
cross-volume/filesystem trials, ordinary UI/startup recovery, post-move INPX and
final application/package validation remain open. No Desktop files, public
packages or user books were changed by this work.

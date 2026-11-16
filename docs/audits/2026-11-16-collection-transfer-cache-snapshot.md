# Recoverable work-volume cache snapshots

## Implemented behavior

`TTransferCacheSnapshot` consumes one replayable cache-version job and its raw
inputs. It derives both cache paths from the validated source/version GUIDs and
current data root, checks the semantic job key and requires a binding supplied
by the parent for the immutable review, exact job and input documents. This
binding is not publication authority; the complete parent cache controller is
still required.

Preparation creates a fresh GUID directory in the canonical operation work
root, pins the directory and calls the parent's durable ownership callback.
Every destination file is reserved with CREATE_NEW and its file key is recorded
before large writes. An original database lease prevents cache replacement;
BEGIN IMMEDIATE blocks cooperating SQLite writers. A separate read connection
backs up a consistent snapshot, including committed WAL frames. No cache rows
are written in the original. The SQLite target remains the same already-open,
reserved file through backup and metadata projection.

SQLiteWrap now exposes `BackupToEmpty` for that reserved destination. It refuses
the same object, an active target transaction or an existing schema/data/header
version. The existing filename-based `BackupTo` behavior is unchanged. Empty
target ownership remains the caller's responsibility; the cache snapshot records
its actual file key before copying pages.

The new copy is projected with the existing cache locator/key primitive. Raw
indices are copied in bounded buffers to the owned work folder, flushed and
read back. Known expected SHA-256 values must match. Source originals remain
untouched. System free space is checked against 8 GiB; the work volume keeps
512 MiB and is checked before allocation and during copying/projection/hashing.
This work stage creates no persistent cache-version folder on the profile drive.

The ready proof records the context binding, directory key, original cache key,
pre-projection SQLite-snapshot hash and every exact output file key/length/hash.
Outputs are held read-only through the object's lifetime. Ready JSON is flushed
before the parent saves its digest independently. Recovery requires that
independent digest and directory identity, validates paths/canonical file IDs,
and rehashes all expected files under held read leases. Replaced directories,
redirected/hardlinked/modified outputs and changed ready proofs are refused.
A ready snapshot can be read when the old cache and raw inputs are offline;
recovery does not claim to hold their original writer lock.

Cancellation and unready crashes never become ready from a mutable child file.
A new stage can be prepared; the old partial stage is retained for the complete
parent's ownership-aware cleanup. This unit does not delete any stage or source,
change source/history references, authorize original removal, or complete a move.

## Native evidence

Licensed IDE builds use identical staged/worktree native inputs (27 relevant
files recorded in final `native-inputs.json` reports):

- Win64 r953: `b4d133732cbd4600d0023e262e9b6673bfd481086e16801c821d0ec844a1e9b5`.
- Win32 r955: `46b5b6c1085fd24120fa67edacee1ff0ae13903f411b3c6a83e70e3e29181256`.

Reports under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| transfer-cache-snapshot-first-Win64-r952 | Initial create/read/recover method PASS, 12.117 s; initial r951 binary. |
| transfer-cache-snapshot-Win64-r954 | Fourteen snapshot methods PASS, 39 native calls, two expected forced exits, nine expected refusals, 163.250 s. |
| transfer-cache-snapshot-Win32-r956 | Same fourteen methods PASS, 39 calls, two expected forced exits, nine expected refusals, 163.797 s. |
| transfer-cache-snapshot-regressions-Win64-r957 | Three earlier metadata-replay/native-stream/root-coordinator methods PASS, seven native calls, 36.686 s. |
| transfer-cache-snapshot-regressions-Win32-r958 | Same three methods PASS, seven native calls, 36.253 s. |

Fourteen new methods and three earlier regressions pass per architecture: 92
native invocations, four expected forced exits and eighteen expected refusals,
no unexpected returns or skips. All owned runtimes were removed. The initial
r952 trial is separate evidence and is not added to those final-run counts.

The snapshot methods cover source writer blocking/release, unchanged original
cache/index bytes, copied index hashes, complete native book-stream readback,
committed WAL title preservation and unchanged source logical rows, source-free
ready recovery, a crash after the independent ready record, an unready crash,
ordinary cancellation before projection commit and fresh preparation without
deleting an unproven partial stage. They also cover an incorrect expected index
digest, changed prepared cache/index bytes, changed independent ready digest,
changed request binding, refusal to overwrite an existing catalogue through the
reserved backup API, a Unicode input path and replacement of the stage directory.
Both replacement directory trees remain byte-identical on refusal.

The isolated diagnostic parent records claims in a separate SQLite database
with synchronous FULL, outside the child snapshot. Fault exits occur after the
relevant parent commit. Production must supply the real independent personal
cache intent/claim store before enabling this stage. These are private small
catalogues and book streams, not a real-user cache transfer, visible Reader
position test, power-loss hardware test or large-cache throughput benchmark.

## Remaining at this checkpoint

The independent personal preparation controller was added subsequently; its
integration before source removal and newer evidence are tracked in
`docs/audits/2026-11-16-collection-transfer-cache-preparation.md`. The following
paragraph records the boundary of this snapshot-component checkpoint.

Integrate dependency preparation before source unlink; persist the complete
cache intent in the personal registry; verify source data-root/context changes;
reserve/publish persistent cache versions without overwriting unrelated paths;
copy only their verified files and preserve old shared caches; atomically update
source/history references with per-database receipts; support partial-commit and
authorized root-phase/startup replay. Ownership-aware partial-stage cleanup,
space estimates for all versions, normal DAO/job/Reader coordination, post-move
INPX, real cache-scale and final app/package checks remain open. User collections,
Desktop files and public packages were not changed.

# Replayable cache/source/history settings plan

## Implemented behavior

`TTransferCacheSettingsPlan` builds metadata in a caller-owned work SQLite
transaction. It does not open or copy a baseline cache, create a cache-version
directory, modify application settings/history, or complete a transfer. Source
settings still use the existing frozen layout's reviewed root and catalogue-fork
projection. Independent bound/unbound update history is projected separately.

Jobs deduplicate by exact source ID/namespace plus normalized old cache path and
old/new book roots. Matching current source and bound history share a new GUID
cache version. A registration keeping the old book root gets a separate version
even when its physical old cache was shared. A different namespace or old cache
version also needs its own projection. Source IDs and profile bindings never
change. Unbound history remains usable as its own baseline when there are no
current sources. Absent history stays absent; an unversioned current source
receives a distinct version without inventing history. External catalogue entries
are not converted into INPX caches.

Unknown JSON fields survive. External user-selected INPX refresh paths remain
unchanged. Retained source inputs and historical raw indices get co-located
targets beside the planned new cache, retaining original path spelling and known
SHA-256 values. A shared input initially lacking a digest can acquire the known
history digest; contradictory nonempty digests are refused. These hashes are
expected metadata, not proof that the actual input bytes have been verified.

A caller can replay the plan with GUID versions supplied by semantic job key
from its independent intent. The model reconstructs exactly the same settings,
job list and raw-input targets. Missing replay jobs cannot fall back to random
new versions. Duplicate jobs are refused by the isolated diagnostic reader;
choosing the original cache version is refused by the production model. The
target path still needs exclusive reservation and independent prepared-file
proof before any future publication. The model never treats a GUID or mutable
JSON file as ownership evidence.

Work tables live on the selected work database, not SQLite's in-memory TEMP
store. Current source lists and job sets are limited to 4096; each history
document to 256 entries. These are source/profile metadata limits, not a
book-count limit. Cancellation rolls back the whole work plan.

## Native evidence

Licensed IDE builds use byte-identical worktree/staged inputs (25 relevant
files, hashes in each final stage's `native-inputs.json`):

- Win64 r947: `8c1a28b53e6b037a24f379dbcd713a23c8b7730748dbb4160d24d7a4d63341b2`.
- Win32 r949: `6a12257ea1424509ccb98032380b6230dfea2c9cba6f5849392852a45bef8e58`.

Reports under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| transfer-cache-settings-Win64-r944 | Initial nine metadata methods PASS, nine native calls, four expected refusals, 72.656 s. |
| transfer-cache-settings-Win32-r946 | Initial ten metadata methods PASS, ten native calls, four expected refusals, 79.593 s. |
| transfer-cache-settings-complete-Win64-r948 | Fourteen metadata methods and two existing regressions PASS, 23 calls, seven expected refusals, 146.687 s. |
| transfer-cache-settings-complete-Win32-r950 | Same sixteen methods PASS, 23 calls, seven expected refusals, 146.203 s. |

The final runs account for 46 native invocations and fourteen expected refusals,
with no forced exits, unexpected return codes or skips. All owned runtimes were
removed. These small-fixture durations are not large-library throughput.

The metadata methods cover compatible deduplication, separate roots/namespaces,
bound/unbound histories and unknown fields, shared retained-input targets/digests,
conflicting digests, ordinary cancellation after the first source job, invalid
versions, mismatched history bindings, missing history, unversioned current
caches, history without a source list, exact replay, a missing or duplicate
replay job and refusal to overwrite the original version.

Private baseline cache files contain deliberately invalid SQLite sentinel bytes:
their unchanged hashes prove the metadata planner never opens/rewrites them.
Raw-index sentinel files are likewise unchanged. Main/personal stores and book
payloads are byte-compared by the existing native journal fixture. Planned target
directories/files remain absent. Failed plans leave no work tables after rollback.
This is planning evidence, not cache snapshot/copy verification.

The two regressions are the existing normal snapshot/native stream reads from
verified destination ZIPs with old roots offline and the roots coordinator's
apply/replay flow. Their overall transfer remains pending. No visible Reader
position migration or full/incremental INPX after the complete move is claimed.

## Remaining integration

The model is not yet invoked by the ordinary transfer controller. It still needs
independent per-operation cache intent, old-cache/data-root identity checks,
consistent SQLite snapshots (including committed WAL data), verified raw-input
copies, pinned/exclusive version-directory ownership, space accounting and safe
retry/cleanup. That controller must publish source and history settings together
with receipts across every participant, allow their authorized versions during
root-phase replay, then handle partial-commit/startup recovery. Reader/DAO/job
coordination, post-move INPX, large-cache measurements and the ordinary UI remain
open. User books, Desktop files and public packages were not changed.

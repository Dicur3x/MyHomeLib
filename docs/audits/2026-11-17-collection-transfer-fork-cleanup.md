# Reclaiming completed shared-catalogue snapshots

Completed physical transfers now reclaim the private `catalogue-snapshots`
directory through the existing ordinary-completion and idle-worker cleanup
path. This extends completed-cache cleanup; disposable unreturned constructor
drafts remain a separate path.

## Authority and protected data

The snapshot directory's physical ID is saved in Context while constructing the
review, before backup data. The review is sealed and independently bound by the
personal operation registry and completed receipt. Cleanup does not trust the
mutable draft lease to authorize deletion after completion.

Before any directory is processed, every frozen ForkMembers/CatalogueForks/
ForkSources relation must match its independent publication receipt: operation,
review digest, fork/registration IDs, published target and snapshot digest. The
receipt count must also match; missing or changed proof refuses cleanup.

Only canonical GUID `.hlc2` children of this journal's exact snapshot directory
are eligible. Each present file is held exclusively, checked against its frozen
physical ID, byte count and SHA256, and checked for reparse points, hardlinks,
readonly state and additional streams. All present entries are validated before
any unlink in the directory. Foreign files, subdirectories or changed/busy
objects preserve the directory. There is no recursive deletion.

The directory handle stays open during enumeration and deletion. A concurrent
new entry cannot cause recursive removal: removing a nonempty directory fails.
Hashing uses a bounded 1 MiB buffer and checks cancellation between reads.
Missing known entries are allowed after a prior interrupted cleanup.

Source/installed catalogues, published cache versions, books, review/state,
lease and completion/publication receipts are preserved. Cleanup does not open
the live destination or revalidate mutable source registrations, so a later
update or temporarily unavailable destination does not prevent housekeeping.
Removed-byte counts describe logical working-file bytes, not measured reclaimed
filesystem allocation or a whole-library throughput improvement.

## Retry and older reviews

`HomeLibreTransferForkCleanup` records independent retry/done state. An existing
cache-cleanup Done marker cannot suppress newly added fork cleanup. Queue
discovery supports completed fork operations even without a cache-claims table.
It retains the existing bounded queue and background-worker behavior.

Neither cleanup marker changes the completed transfer summary or makes the
operation pending again. A process exit after unlink or between marker commits
is retryable using the remaining frozen claims and already-missing entries.
Successful repeated cleanup leaves the existing done records unchanged.

Older experimental reviews without a sealed directory key conservatively
retain their snapshot directory. The mutable lease is not used as replacement
authority. These pre-release reviews can still replay their completed receipt.

## Validation

Validation `G:/HL-b14-external/transfer-fork-cleanup-validation-r1287/summary.json`
records PASS on both architectures. All 662 compiled/resource/test inputs match
the source tree, isolated build tree and both final test manifests. PE machines
are checked independently (8664/14c).

- Win64 r1285: 18 methods, 86 native calls, three deliberate process exits and
  seven expected refusals; 1,039.422 seconds. Driver built in r1278, SHA256
  `e36c4ec83c19b43c79c5e7705fbca8cc57501d65e0deba08b82397b3e29c8e0b`.
- Win32 r1286: the same 18 methods/86 calls/three exits/seven refusals;
  1,043.282 seconds. Driver built in r1280, SHA256
  `ca1b1d82bb0f562053fdab159070f23a90037c55375fbf4a05a51594a84f0c8c`.

Each run has nine new shared-catalogue checks and all nine previous cache-only
cleanup checks. Total: 36 methods, 172 calls, six deliberate exits, 14 expected
refusals, no failures/errors/skips and no remaining private fixture runtimes.
The new successful case removes 13 proven work files (4,182,616 logical bytes)
in five directories, including four cache stages and one catalogue snapshot.
Queue count becomes zero; repeated cleanup and completion replay leave database
bytes unchanged. All-table guards, installed cache contents, copied book hashes
and completion/publication receipts remain intact.

New cases cover unavailable live destination, same-ID size/content changes,
foreign entries/subdirectories, replacement directory/file IDs, hardlinks,
file/directory streams, busy readers, independent fork queue with a prior cache
Done marker and no claims table, missing/changed publication receipts, pending
operation refusal, cancellation after snapshot unlink and process loss before
marker persistence. Legacy reviews are genuinely constructed/completed by the
earlier r1269/r1271 binaries (SHA256 recorded in the summary), then cleaned by
the current driver; absent sealed directory proof preserves their snapshot.

These tests use private G: data, not user collections; E: is unused. C: remains
above the 8 GiB reserve. No additional ordinary Main UI or current million-record
validation is claimed for these test-driver builds. Current Main compilation,
ordinary UI, volume/space failure, remaining formats/updates and final beta14
distribution remain separate gates. The Desktop copy and release are unchanged.

Earlier attempts are retained as non-passing evidence. Initial compile r1277
rejected Delphi's inferred Char type for a one-character SQL-filter initializer;
the variable now has explicit string type. Smoke r1279 exposed the inherited
cache-only verifier's incorrect fallback for a newly published retained-root
catalogue; r1281 exposed its hardcoded two-cache count (this shared fixture
correctly publishes four). The fixture now compares the new catalogue with the
original pre-cutover snapshot and derives cache count from the frozen intent.
Initial r1283/r1284 cleanup itself returned success with five removed directories,
but the verifier tried to open the deliberately offline published catalogue.
The verifier now checks that catalogue and its installed cache after restoring
the offline destination. None of those attempts is a passing application gate.

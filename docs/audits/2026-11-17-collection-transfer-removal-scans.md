# Reusing validated reference bindings during physical transfer removal

Previously, every source-removal group forced a full reference capture before
persisting its removal intent and another after committing that intent. Even
with no outside changes, 26 independent archive groups required 53 captures
across publication and removal. The existing publication session already keeps
its SQLite connections and detects outside commits with `PRAGMA data_version`.

Removal now reuses the same validated binding/retention view while connection
versions and unavailable registrations remain unchanged. Own locator commits do
not change normalized file IDs or ownership. Current locators, group proofs and
removal intents are still checked independently under newly acquired writer
transactions for every group. Per-file source/destination identity, contents,
streams, dependency retention and held-handle unlink checks are unchanged.

Catalogue writer transactions remain held across the personal intent commit.
After reopening the personal writer transaction, its same connection's
`data_version` detects another connection's intervening commit. A detected
change, newly available registration or missing snapshot rebuilds the reference
view before removal. The gap path now explicitly requires all relevant writer
transactions to be held. It always reruns group approval and current locator /
receipt checks, even when the reference capture itself can be reused.

The completion-verification path still requests a fresh capture. New processes,
outside catalogue/personal commits and errors continue to invalidate snapshots;
there is no durable unchecked reference cache and no change to the sealed plan.

## Verification scope

The private fixture checks a complete 26-carrier copy/publication/removal,
outside catalogue commits, new references before removal, personal-note and WAL
commits precisely in the intent gap, a new personal reference in that gap, and
actual lock availability (personal writer released only in the intentional gap;
all catalogue writers still excluded). All user tables/locators, original
neighbors and destination hashes have independent fixture guards.

The prior x64 driver (r1278,
`e36c4ec83c19b43c79c5e7705fbca8cc57501d65e0deba08b82397b3e29c8e0b`)
completed the same 26-carrier case with 53 captures in r1291. Current x64 smoke
r1289 completed it with one capture. This measures capture count; overlapping
runs and tiny carriers are not a controlled whole-library throughput benchmark.

Final validation is PASS in
`G:/HL-b14-external/transfer-removal-scans-validation-r1295/summary.json`.
All 663 current source/resource/test inputs match both final test manifests and
the isolated build tree; PE architectures and binary digests are checked.

- Win64 r1293: 14 methods, 26 native calls, two deliberate exits and five
  expected refusals, 366.562 s. Native driver built in r1288, SHA256
  `200af8707473e448de50aacb7c6a8895b714a6a62057b34ddc4bc204307123cc`.
- Win32 r1294: the same method/call/exit/refusal counts, 366.109 s. Driver built
  in r1290, SHA256
  `cf63e6790b919c5fce7d34a528f7620a0d95e8975c45a68d7d1bafdb84c4feb9`.

Total: 28 methods, 52 calls, four deliberate exits, ten expected refusals, no
failures/errors/skips and no remaining private fixture runtimes. Both current
26-carrier cases report one capture, 26 prepared/copied carriers, 26 removed
sources and zero retained sources. Baseline r1291 reports the same successful
carrier counts with 53 captures. The baseline binary is independently bound to
the earlier audit's recorded source hashes and digest; its current runner-input
manifest is not claimed to be the baseline compiler input manifest.

Six new cases cover capture count, external title/reference edits before removal,
personal-note/WAL edits in the intent gap, and a new personal reference in that
gap. The latter refuses before any original is unlinked, then resumes after
removing only the injected fixture row. Eight existing cases cover changed
removal intent, changed FLibrary owner/picture dependency retention, missing
receipt, live reader deferral, protected-source crash recovery, external WAL
invalidation, previously unavailable catalogue arrival, and completed shared-
catalogue/cache publication/cleanup with byte-exact replay.

The work uses private G: fixtures, with the C: 8 GiB reserve maintained and no
E: access. Current million-row data, ordinary Main compilation/UI, volume/space
failures, remaining post-move format/update compositions and final production/
release packages remain gates. The Desktop copy and release are unchanged.

Initial r1292 is retained as a failed verifier attempt: it injected a new
reference to the second archive after publication of the first, then incorrectly
expected the independently completed first archive's source to remain. The
referenced second source was preserved correctly. Final negative fixtures target
the first archive so they can require rejection before the first unlink. The
common fixture now checks the explicitly requested reference container instead
of hardcoding the second archive. This is not counted as an application failure
or a passing integration gate.

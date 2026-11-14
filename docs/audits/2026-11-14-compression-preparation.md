# Unapproved compression preparation: reproduction and verified local fix

The completed transaction-recovery milestone is commit `7bd38b5c`. This is a
separate lifecycle case, not a regression result for that milestone. A local
production fix passed the operation and ordinary-window checks below on x86/x64;
final-application/package gates remain open. Nothing was published or replaced on Desktop.

The new native fixture mode `review-crash` runs the actual packaged preparation
pipeline, waits for its review state, then terminates only its own process with
code 73 before approving any replacement. No durable job or published original
backup exists at this point. A second native operation enters recovery.

Evidence root:
`G:/HomeLibRu-build-cache/HomeLibre-post13-compression-recovery-20261113`.

- `native-unapproved-Win64-baseline-r10`: expected failure at retained-workspace
  assertion. Its helper checked cleanup before the final data assertions.
- `native-unapproved-Win64-baseline-r11`: strengthened ordering; source archive,
  catalogue and personal database hashes are checked unchanged both before and
  after recovery. Recovery reports no error and no changed files, but the final
  assertion confirms that its `prepare-{GUID}` directory remains. One test,
  one assertion failure, no errors or skips; this is not a passing result.
- Both exact private runtimes were independently verified absent after normal
  fixture teardown: `HomeLibre-inspection-runtime-rqmr4ll0` and
  `HomeLibre-inspection-runtime-73c3mpia`. No equivalent retry of an earlier
  denied cleanup was involved.

The fixture executable SHA-256 is
`76613ef76b2035a7a4122c75e9ce3d09fb32c957c1fa128713bed76ec6dec075`.
Its build log is `RecoveryOperation.local-Win64-3d9c409202cc.err`. The first
build failed because the fixture's `Output` JSON variable shadowed the standard
text output; `Flush(System.Output)` corrected that fixture-only compile error.
No production unit changed for the reproduction.

## Requirements recorded from the baseline

Track ownership of unfinished preparation before launching the producer, and
bind its lifecycle to any later published job. Startup and the next operation
must be able to clean an abandoned preparation even with an empty job queue.
Never delete a candidate needed by an already-published job, another live
operation, an unknown folder or a foreign file. Keep queue/profile isolation.

Exercise interruption while the producer is actually running too: its payload
can contain nested `.selected-*` scratch directories, not just final candidate
files. The present `CleanWork` intentionally accepts only flat known outputs.
The existing `TCompressionPlanStore.CleanAbandoned` cleans planning metadata,
not these prepared book payloads. `CheckCompressionRecovery` currently starts
only for pending durable jobs, so ordinary-window startup needs an explicit
unfinished-preparation path as well.

Complete that implementation and its negative ownership/live-job tests, then
verify x86/x64 and ordinary application startup. Do not relabel the baseline
failures, and do not reduce the wider beta-14 Todo to this case.

## Local implementation and current evidence

New native preparations publish a version-2 ownership marker before starting
the producer. It binds the exact canonical folder name, NTFS directory identity,
application queue and intended durable job name. The job uses the same GUID.
Discovery verifies this marker under exclusive file and pinned directory handles;
a copied marker cannot authorize a different physical folder. Live ownership,
another profile, legacy unregistered markers and unknown data are retained.

After taking ownership again, cleanup rechecks the exact associated job. A
published binding, file journal or completion marker forbids orphan cleanup.
Only genuinely unpublished metadata is discarded, under its own directory and
job leases and a fixed allowlist. Atomic temporary metadata has canonical names.

Registered payload cleanup also handles the producer's nested `.selected-*`
and `.estimate-*` scratch directories. It preflights contents, bounds recursion
and entry count, rejects directory junctions/reparse points and hardlinked files,
and keeps unknown top-level data. It never follows an archive's names out into
the user's source folders. Cleanup runs without Python or optional codecs and
is connected to ordinary startup as well as the next compression operation.
The ordinary result distinguishes discarded preparation from changed books.

Earlier version-1 preparations are still accepted for cleanup through their
exact completed-job reference. An unapproved old folder without the new queue
and physical-directory binding is not guessed to belong to this profile.

| Run | Result and actual scope |
| --- | --- |
| `native-preparation-Win64-r12` | Six new ownership/cleanup cases passed. The running-producer case failed because its new test wrapper tried to replace a global callback that is actually a function argument. This remains a failed batch. |
| `native-preparation-Win64-running-r13` | Corrected callback interception passed with a real terminated producer and its `.selected-*` scratch root. The stronger version, requiring actual extracted FB2 bytes before termination, subsequently passed in r16 below. |
| `native-preparation-Win64-protection-r14` | Three cases passed: hardlink preservation, a real directory junction pointing outside preparation, and recovery with deliberately missing Python/codecs. Private runtime removed. |
| `current-Win64-r15` | All three ordinary-window startup cases passed: preparation-ready, receipt-prepared and binding-prepared. Source ZIPs, both books, visible original sizes, cache, personal progress, other collection and correct backup count were checked; all private runtimes removed. |
| `native-preparation-Win64-full-r16` | All 55 operation/whole-collection cases passed without errors, failures or skips in 211.313 seconds including setup/cleanup. Includes the stronger running-producer interruption with a real extracted FB2 inside nested scratch. Private runtime removed. |
| `native-preparation-Win32-full-r17` | The corresponding full 55-case suite passed without errors, failures or skips in 219.703 seconds including setup/cleanup. Private runtime removed. |
| `current-Win32-r18` | All 13 ordinary-window cases passed: six published-job crash points, three ownership protections, ordinary apply and three prepublication interruptions. Every private runtime was removed. |
| `current-Win64-r19` | The six published-job crash points, three ownership protections and ordinary apply all passed. Together with r15, all 13 ordinary-window cases passed on the same x64 fixture. Every private runtime was removed. |

The initial native implementation above used executable SHA-256
`3e1ed5a3f878a2ac383f239a5e4390cec0defb63817f96f5d0ba902abba7d4d1`.
The x64 GUI build is
`b05d8473d86f2a377d430f435f5b475db67bdfbfcdbc8e5196fa496a58eddc91`;
it additionally rejects an empty/non-rooted discovery path before enumerating.
The fresh native x64 build including that guard has SHA-256
`d6510ccb4b064a4382cfac348c51c725bf65a69ec8cdc0d52de3dea7c4748982`
and passed the complete r16 suite. A corresponding x86 build succeeded with
SHA-256 `e3b46cfa550a11f3ba6879c30b9cabe34cb1d5e912ed8307fa5528c1286108ff`;
its complete r17 suite passed as recorded above.
The fresh x86 ordinary-window fixture has SHA-256
`5ff3f82418c83e0154808c7fa6f44e8cb96f6a05ea4d73c1cd89f81f133056c4`,
18,086,400 bytes; build log `CompressionRecovery.local-Win32-1d1398c24386.err`.

This local implementation gate is complete. The operation suites contain 55
passing cases per architecture, without errors, failures or skips. Ordinary
startup has 13 passing cases per architecture. These deliberately terminated
private processes; they do not claim a physical power-loss test.

Remaining for the release: final applications/packages and the larger beta-14
Todo. Do not repeat these suites unless code changes or new evidence justify it.

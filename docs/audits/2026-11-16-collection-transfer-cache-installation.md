# Recoverable persistent cache-version directories

## Implemented behavior

`TTransferCacheInstallation` copies an already verified work snapshot to a fresh
attempt directory beside the fixed new cache version. The publication parent is
the real personal transfer registry, not a mutable child manifest. This stage
materializes new versions; it does not yet switch source/history references or
complete the physical transfer.

The preparation intent now captures the data-directory file identity before the
source-removal phase. Preparation and installation pin that canonical directory
and reject a replacement. Metadata planning also rejects distinct semantic jobs
that select the same physical new version path, including on replay. Existing
source versions and independent histories retain their distinct source/profile
IDs and use the already frozen GUID versions and retained-index targets.

Installation requires an existing prepared cache intent and roots independently
validated by the roots controller. It reuses the real publication session's
personal/catalogue transactions. Every new attempt-directory and file identity
is independently committed before large writes; old-attempt claims are retained.
Sources are the held work-snapshot files. Copying uses bounded buffers, checks
space and cancellation, flushes each file, and reads back the complete bytes.
Copied indices and SQLite databases must match their snapshot hashes.

The complete ready proof commits to the personal store before directory rename.
It binds the immutable review, cache intent, exact job/input documents, snapshot
ready digest, fixed destination, attempt-directory identity and every output
file identity/length/hash. The entire ready directory is renamed by its exact
DELETE-capable handle, without replacement, to the fixed new version. Canonical
parent directory handles remain pinned.

NTFS requires child files to be closed for this directory rename. The controller
first checks their complete named set and hashes under leases, closes those
handles, renames only the already-bound directory handle, then acquires strict
named-file leases and rechecks all identities/hashes and the complete directory
membership before recording publication. Neither a settings change nor operation
completion is authorized during that transition. A changed result is a refusal,
not permission to repair or delete it. The installed file leases remain held
through the parent phase's final checks and commit.

`HomeLibreTransferCacheInstallations` stores copying/ready/published state and the
independently committed proof; `HomeLibreTransferCacheInstallClaims` retains exact
ownership records across attempts. A ready-stage exit resumes the same directory
and rename. An exit after rename is recovered by its directory/file identities
without copying again. An unready attempt starts a fresh directory and preserves
the old claims/files. A published version cannot be guessed from a pathname,
adopt an unrelated directory, silently recover a lost proof, or recreate a
missing published version.

Free-space checks preserve 8 GiB on the system volume and 512 MiB on another
destination volume. When the cache destination is on the system volume, the
remaining copy bytes are accounted for in addition to its 8 GiB reserve. Shared
source parent directories can be created but are never recursively cleaned by
this component. Old shared baseline caches and indices are not removed.

## Native evidence

These are small private real SQLite-schema/ZIP book-stream fixtures. Retained
index contents are sentinel bytes whose copying is checked by SHA-256, not parsed
real INPX data. Real full/incremental INPX after complete metadata cutover and
large-cache throughput remain separate gates.

Licensed IDE builds use the same 29 staged/worktree native inputs:

- Win64 r980: `50a78671160350f82ac6bb03dc2edd97bb8c293f0664b2ccd5ece1745cbc4a56`.
- Win32 r982: `d1dc7af18ea88cdc164e45a226958c9f04086fa650532427c5e97f21767942ff`.

Final coverage is `G:/HL-b14-external/transfer-cache-installation-final-r987/coverage.json`.
It checks per-method native return codes and equal native input/binary hashes.
Reports under `G:/HL-b14-external/`:

| Report | Passing evidence |
| --- | --- |
| transfer-cache-installation-smoke-Win64-r981 | Two methods, four native calls, one forced exit, 74.667 s. Direct unittest process exited 0; observed results are recorded separately. Input hashes were recorded after the run, matched against the unchanged final build, with staged-source mtimes predating its invocation log. |
| transfer-cache-installation-Win64-r984 | Remaining 11 initial installation/target methods, 22 calls, three forced exits, nine expected refusals, 637.125 s. |
| transfer-cache-installation-Win32-r983 | All 13 initial installation/target methods, 26 calls, four forced exits, nine expected refusals, 711.734 s. |
| transfer-cache-installation-regressions-Win64-r986 | Two further installation methods and four earlier regressions, 12 calls, one forced exit, two expected refusals, 258.265 s. |
| transfer-cache-installation-regressions-Win32-r985 | Same six methods and 12 calls, one forced exit, two expected refusals, 258.500 s. |

Per architecture, 15 installation/target methods and four earlier regressions
pass: **76 native invocations**, ten expected forced exits and 22 expected
refusals in total, without unexpected returns or skips. All private runtimes
were removed. The regressions cover unchanged original data and independent
preparation replay, partial roots-commit continuation, exact cache-version/input
metadata replay, and the older coordinator without a cache-preparation request.

New cases cover whole-directory installation, actual native ZIP book-stream
hashes through installed SQLite locators, continuation with both old cache/index
directories offline, ready commit and post-rename exits, unready exit/fresh
attempt/retained ownership, cancellation before rename, foreign destinations and
extra ready-stage files, changed installed bytes, missing independent proof,
replaced directories with both trees preserved, disappeared published versions,
rehashed redirected proof, missing prerequisites, a replaced data directory before
any original archive is removed, and colliding replay targets. Sources/history
are checked to retain their old cache versions at this checkpoint; other
catalogue/personal fields are compared against the earlier independently modeled
locator/roots changes. Installed file keys/times/content stay unchanged on replay.

The initial r975 compile report exposed a missing unit import and the local
Windows API's var-parameter signature; these were fixed before native execution.
The initial r977 native smoke report exposed NTFS's child-handle rename
restriction. The parent ready proof remained durable and the private original
baselines remained unchanged. r979 confirmed the failure occurred after ready
preparation and before rename; the close/rename/reacquire/reverify transition
above fixed that case. Failed reports are preserved separately.

## Remaining

The subsequent cache-metadata checkpoint implements the first paragraph below;
see `2026-11-16-collection-transfer-cache-metadata.md`. These were the remaining
requirements at the installation-only checkpoint.

Atomically publish source and independent-history settings with per-database
receipts, validate partially committed settings through the prior roots
controller, and recover that publication before ordinary source updates. The
roots-only settings are still current at this checkpoint, and tests explicitly
check that the old cache versions/history references have not switched yet.

Reader/DAO/job coordination, old-baseline changes, complete-operation state,
ownership-aware cleanup of incomplete work/install attempts, complete space
estimates, large-cache and cross-volume/filesystem evidence, normal UI/startup
integration, post-move full/incremental INPX, and final app/package checks remain
required. The transfer command stays disabled and the operation stays pending.
No user collections, Desktop applications or public packages were changed.

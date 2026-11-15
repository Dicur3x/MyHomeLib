# Read-only physical collection transfer inventory

## Scope

`unit_CollectionTransferPlan` is the first implementation step of physical source
consolidation, following `docs/design/collection-physical-consolidation.md`.
It is not connected to a move button and performs no payload copy, catalogue
update or source deletion. A streaming caller supplies already resolved physical
payload paths and logical roots. Catalogue enumeration and unavailable-locator
handling remain to be integrated.

The planner writes only an owned indexed SQLite scratch store, reusing the
existing guarded `TCompressionPlanStore`. Payloads and destination folders are
not created or rewritten by planning. It retains roots in memory, not a list of
every book/file. The tests stream 20,000 repeated locators into one physical
archive; this is not a million-file performance or memory benchmark.

## Decisions implemented

- Preserve complete archive bytes and relative layout. Distinct roots receive
  separate folders under one operation-specific destination. Same archive names
  do not collide; no content deduplication or recompression is attempted.
- Already-contained outer roots can stay in place. Overlapping roots share the
  outer root's mapping; a child keeps its relative offset. Whole-root junction
  aliases resolve to one physical root/file. Internal junctions changing relative
  layout receive an explicit rejection rather than breaking adjacent resources.
- Capture file IDs, lengths and modification times. Reject missing, hardlinked
  or linked files, unknown/duplicate root IDs, paths outside their source root
  and occupied destinations. Unicode-folded destination keys also prevent
  case-colliding planned names from being accepted for an ordinary Windows target.
- Use the existing FLibrary discovery rule for a genuine 7z signature, including
  long native Windows paths. Inventory complete covers/images archives once,
  retaining their relative directories. Capture absent sidecars too: a newly
  appearing sidecar invalidates the review.
- Recheck roots, source identities, external-image sets and destination occupancy
  before a future writer begins. This is metadata validation, not a full-file
  hash freeze at preview; streaming SHA-256 verification and source leases are
  explicit gates for the upcoming writer.
- Cancellation or a rejected inventory removes only its positively owned scratch
  database. A foreign file in the chosen work parent survives.

## Native evidence

Licensed IDE builds used isolated output/temp paths on G: and preserved the
project. Current passing reports are under `G:/HL-b14-external/`:

| Run | Tests | Failures/errors/skips | Binary SHA-256 |
| --- | ---: | --- | --- |
| `transfer-plan-Win64-r711` | 17 | 0/0/0 | `8f7cdd5bfe39fcbc04879e5d96e029d5fd9631472038668cf577dd8c63f4464e` |
| `transfer-plan-Win32-r713` | 17 | 0/0/0 | `9eae856d8b86f135f96818995fba2ae43b3c5f79bd4f32c0b3b5dbf78dc76371` |

Each test starts a private runtime with the existing native regression marker.
The cases cover same archive names with different contents; first source as
destination; overlapping roots; repeated paths/aliases; genuine whole-root NTFS
junction aliases; internal junction rejection; real tiny 7z plus ZIP sidecars;
long Unicode FLibrary paths (>300 characters); unknown/duplicate roots; missing,
outside, hardlinked and changed sources; occupied destination before/after
preview; newly appearing sidecars; and cancellation after a committed scratch
batch. The test-only fixture deliberately injects source/destination changes
after planning for the stale-preview cases. Production planning never makes
those changes. These are file-layout/identity tests, not native book rendering
or a transfer of a full library.

All 34 successful private runtimes, scratch databases and temporary junction
aliases were observed removed. Source/destination snapshots check preservation,
apart from the explicitly injected fixture mutation. No user catalogue or book
was moved. Reports took approximately 22 seconds per architecture including
fixture creation/cleanup; this is not transfer throughput.

The G: staged sources used for both builds were byte-checked against the worktree:

- Planner SHA-256: `8924046e24143b28c310103cb5b30f20bdcd5f970c2f20088a562a0d5d6b687a`.
- Diagnostic DPR: `90220208bdaa82abac8e780d78d460a92881439f0d0fcba5cb1f6ec61e47d66c`.

An earlier x64 build/r709 trial passed the initial 12 cases. The final runs
above include the additional sidecar, destination, Unicode and junction checks.
Initial compilation r707 exposed a const-record callback signature mismatch;
dedicated visitor types fixed it. No passing result is assigned to that build.

## System reserve event

During r706, observed free space on C: fell from about 14 GiB to 1.6 GiB; the
build supervisor stopped at its 8 GiB threshold. Its compiler result was not
counted as a pass. The space subsequently returned to about 14 GiB. The cause
was not established; it is not attributed to another chat. All following IDE
invocations explicitly set TEMP/TMP to their owned G: build folders. The final
tests ended above 14 GiB on C: and about 230 GiB on G:. No other chat's files
were deleted or moved.

## Remaining

Catalogue adapter, durable group transfer journal, streamed verified copying,
multi-catalogue locator publication, compression-history rebind, reference-checked
source cleanup, stop/resume/startup recovery and ordinary UI remain open. Existing
compression modules are unchanged (`packages-r691`). Main/Reader release builds,
Desktop replacement and publication are not completed by these planner checks.

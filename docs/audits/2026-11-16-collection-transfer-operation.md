# Sequential transfer phase and source-free personal reconciliation

## Implemented flow

`TCollectionTransferOperation.Run` registers the operation before mutations,
publishes required shared-catalogue forks and streams archive/sidecar groups
sequentially from the frozen on-disk review. It does not collect a book-sized
in-memory worklist. A group with the independent proof and personal location
commit recovers held verified destinations. Otherwise normal original-held
preparation completes or replays the initial publication. Every group then uses
the registry's durable-intent, current-receipt and exact-handle removal stage.
Cancellation preserves completed groups and the registered pending operation.

The phase reports groups, verified physical files and cumulative removed,
missing, retained and pending originals. It deliberately does not mark the
operation complete: final root publication and normal application coordination
remain required. The tests require the personal registry state to stay pending.
No normal Sources command is enabled and no user library was changed.

## Source-free reconciliation

An ordinary app or external Reader may create a personal card carrying the old
address after its original has already been removed. The new reconciliation
path requires the independently registered group proof, held native targets,
current reference/registration locks and all existing location receipts. It
projects from frozen original locator fields; it neither probes old originals
to determine their native kind nor copies compression history again from them.

Non-personal catalogue addresses must already equal the published projection.
A changed address or missing/changed receipt fails instead of being repaired.
Known stale personal rows may receive the saved destination while retaining all
current non-locator fields. A new personal card with a genuinely missing old
file additionally requires a reviewed main BookID, matching filename, extension,
inside index, native format and frozen logical source path. Unsupported aliases
are not treated as absence. An available reused old name must match the actual
reviewed identity before it can be used for personal rebinding.

Reconciliation commits through the same publication connections. The independent
proof must still exist with the exact digest in the locked personal transaction;
this path does not recreate it. The subsequent removal stage obtains its own
current references/receipts and durable intent. Reconciliation itself grants no
later unlink authority.

## Evidence

Final licensed IDE builds, with identical staged/worktree native inputs:

- Win64 r878: `c8e5bd4b4fd62246f0cead4c235a12299fa364ea685c384a5d9e4036adf0a836`.
- Win32 r879: `69ce1d457c4788dc3ab6f5ee8dfcba231f396ca00c0db4b1848b65572538451e`.

Both initial nine-method matrices passed: Win64 r880 in 221.850 s and Win32 r881
in 224.521 s. They execute the production coordinator, rather than selecting
individual preparation/publication/removal calls in the native driver.
They cover registration, processing all groups, stopping after a completed
group, crashes after group completion, partial catalogue commit before personal
proof, protected-source recovery, new and known personal cards with absent
originals, and shared native external-image groups. Replays do not recopy ready
payloads; protected data, neighbors and current personal fields are compared.
Removing a personal location receipt after source deletion fails without
recreating it or altering the verified destinations.

Additional runs r882/r883 each passed three further operation methods: a foreign
archive recreated at an old name is preserved without rebinding a new card to
it, two source-free reconciliation crashes preserve the new personal note, and
registered preparation without locations is published before any removal.
Their fourth shared-catalogue method initially failed in the observer, not in
the native process. The first observer omitted existing fork databases from its
before snapshot; the second version incorrectly recomputed search columns on a
row whose locator was already current. Native data retained the late title and
its original search fields in both observations. The observer now captures all
private registered catalogues and models search triggers only for actual locator
changes. r882/r883 and the focused r884/r885 repeats remain recorded as failed
observer runs, not relabeled as fully passing matrices.

The corrected shared-catalogue method and four focused regressions all passed
in r886/r887: five methods in 215.602 / 215.647 s. The fork keeps its late title
on source-free continuation; ordinary new-card publication, receipt writer locks
and their release, readonly original/named-stream removal, and one reference
capture for 26 ordinary publication groups still pass.

Across these stages, 13 distinct coordinator methods plus four existing
regression methods passed per architecture. The passing methods account for
70 native invocations and ten expected forced exits, with no unexpected return
codes or skips. Eight native invocations belonging to the earlier observer-
failed fork attempts are excluded from that passing-method total. All eight
owned stage runs removed their private runtimes, including the failed observer
runs; each stage's `summary.json` records its actual status/counts and inputs.
These are diagnostic durations, not transfer throughput.

Exact final build input SHA-256 values:

- `unit_CollectionTransferOperation.pas`: `7e18c487a9384ab74b4bcc13f5b263463ecfafaa811a69c57f73685b63c45518`.
- `unit_CollectionTransferLocations.pas`: `0130e4d0c60bebef8a65600408da71d3519a4377771ec7068735cf76406d519f`.
- `unit_CollectionTransferJournal.pas`: `8cd47ee4a287c49b91b77ee978508b1d6e7c2eaa8fa1b3e76aaf9f5ebbd86d6b`.
- `unit_CollectionTransferRegistry.pas`: `b452ade21a9d0fd217655aa9b6fd53e6db60326af8a2cc775ffc2e30151c6ce1`.
- `unit_CollectionTransferPublication.pas`: `7b70e52ea0585f65158ce1baf4890d9d51bf10166e6b31137688b865bc2cfb82`.
- `CollectionTransferJournalTest.dpr`: `36e748379bd489c7a2df447a3991fab83dadc4b380c8ac550d0876d31d617fbe`.

## Remaining before a user-facing move

Final roots/source metadata, unavailable/future paths, bound update-profile
roots, retained index/cache handling and Reader-cache invalidation/rebinding
still need a durable finalization stage. The current group phase leaves the
original registration roots in place while existing book addresses are absolute.
Normal DAO/Reader/job coordination, startup and Sources UI, space accounting and
cleanup, actual cross-volume/filesystem trials, large-library measurements,
post-move updates and final release gates remain open.

Source cleanup still captures references twice per group; normal publication's
existing reference cache does not make this a proven large-library optimization.
Repeated recovery currently rehashes verified destinations and must not be
advertised as a speed benchmark. Neither these small fixtures nor their runtime
durations prove a full collection transfer. Desktop and public files are unchanged.

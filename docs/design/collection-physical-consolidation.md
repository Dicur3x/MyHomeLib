# Physical consolidation of collection sources

Status: native inventory, file/group copy journals, catalogue/fork publication,
resource verification, destination-only recovery, guarded source removal,
the sequential available-file phase, final-layout/final-row primitives and the
durable roots/settings phase, unpublished source-cache projection and replayable
source/history cache-version planning and recoverable work-volume cache snapshots
are implemented internally. Durable cache publication/Reader,
live DAO/job coordination, startup and normal UI remain open. No user collection
has been moved by this work.

## User result

In Sources and Merging, keep the existing option to leave books at their current
locations. Add a separate reviewed operation to gather the current collection's
physical files into one chosen book root, including the first source's folder.
The user keeps one catalogue with its source priorities and future INPX updates.
The folder may contain source subfolders; “one folder” does not mean flattening
all archive names into one directory.

No recompression or book-content deduplication is part of moving. Existing ZIP,
7z, WebP, JPEG XL and other payload bytes remain unchanged. A duplicate cleanup
remains a separate deliberate operation. Transfer whole referenced archives,
including their uncatalogued members, rather than extracting selected books and
rebuilding them.

## File layout and identities

- Preserve relative paths under each source root. Different outside roots get
  different subfolders under `HomeLibre-sources/{operation GUID}/{root hash}`.
  Equal archive names are therefore harmless and never justify overwriting.
- A root already inside the chosen destination can remain in place. Overlapping
  parent/child source roots share one layout and retain their relative offsets;
  canonical aliases share the same physical root. If an outer root encompasses
  the chosen folder, mapping the outer tree may also copy inner sources: show
  the actual estimate, rather than promising every inside file stays put.
- Resolve real root/file paths before containment checks. Detect root aliases
  changing after preview. Existing files and a previously occupied operation
  directory are conflicts, not permission to reuse or delete them.
- For 7z containers, use native `FLibraryImageSourceFiles`: copy the complete
  `covers/<base>.zip|7z` and `images/<base>.zip|7z` beside their book container.
  A book archive and its present sidecars form one publication group. Preserve
  missing-sidecar state too; a newly appearing sidecar requires revalidation.
  If more than one book container shares a sidecar, their connected dependency
  group must be published together; moving the sidecar first would break the
  still-unmoved container.
- Distinct catalogue rows and source keys may name the same physical archive.
  Inventory it once while retaining every logical binding. Identical contents
  in two different source files remain two files unless a separate, explicitly
  reviewed feature handles them.
- Keep book IDs, library IDs, `CatalogSourceBooks.SourceKey`, copy source keys,
  source IDs and priority unchanged. Moving is a locator change, not reimport.
  Root-relative source keys remain stable because their relative layout survives.

## Inventory and review

Stream primary books, physical copies and personal locators through the existing
native path resolver, including linked loose files, FBD and legacy ZIP-to-7z
fallback. Include both the actual payload and required descriptor/resources.
Do not recursively copy an entire source directory: unrelated files are outside
scope. Show unavailable book locators separately; their metadata must remain
available for future updates and must not invent a readable file.

Keep the large file/binding set in an indexed temporary SQLite store on the
chosen work volume. Hold only roots and a bounded working batch in memory.
The implemented `unit_CollectionTransferPlan` accepts already resolved payloads,
calculates collision-free roots/files, inventories native FLibrary sidecars,
deduplicates repeated paths, estimates copy bytes, checks metadata identities and
cleans its owned scratch store. The planner itself does not enumerate a catalogue,
copy payloads or publish database changes. Its inputs must be available files.
Pre-existing hardlinks and file links currently receive an explicit diagnostic.
Internal directory links which change relative layout are rejected as well;
whole-root junction aliases are supported. Discovery uses extended Windows paths
for both the book signature and FLibrary sidecars.

`unit_CollectionTransferCatalogue` now streams native main/copy/personal locators
into indexed scratch metadata and feeds available containers into that planner.
Missing-file/directory and metadata-only records remain explicit. It captures original
locators/source JSON and detects changed databases, registration, files and
ZIP/7z selection. Personal read locks are released before the main scan. Bounded
container caches avoid a disk probe for every book in a shared archive. The
current logical-root limit is 4,096; scale beyond this needs work, not silent
skipping. See `docs/audits/2026-11-16-collection-transfer-catalogue.md` for the
x86/x64 native evidence, including real copy/readback with in-memory locators.
This adapter does not yet publish a path or decide final locators for missing
sources.

The review must explain destination, physically transferred bytes/files,
already-in-place files, sidecars, unavailable books, affected registered
collections and why any source archive will be retained. Display space by volume
and a peak temporary-space estimate; do not add whole-library extraction space.
Recheck the 8 GiB system reserve and destination/work-volume reserves before and
during long work. Losing the reserve stops preparation without deleting sources.

The physical planner now observes all existing declared roots, including an
outer root with no directly assigned book. This keeps its children in one
relative layout without recursively copying unrelated contents. The final-layout
projector uses those frozen destinations and derives unavailable roots from a
known ancestor or an isolated future folder. It preserves native missing-book
locators and source/copy keys, updates only source/profile book-root fields and
retains unknown JSON fields. Empty profile roots and unrelated incoming folders
keep their meanings. This stage is read-only: source/registration settings and
download state are not yet applied. See
`docs/audits/2026-11-16-collection-transfer-layout.md`.

Equal original default roots also need separate catalogue roles if only the
selected registration's final root moves. Retained equal aliases share one fork;
their physical-root witnesses and personal-only paths keep their original
meanings. An unchanged kept root needs no such split. For a non-INPX source that
names a forked registration, the final projection also rebinds its catalogue
filename to that reviewed fork, preserving the registration/source IDs and
unknown fields. INPX references stay unchanged. This is not yet final-settings
publication; see `docs/audits/2026-11-16-collection-transfer-final-forks.md`.

The final-row transaction primitive now applies the reviewed missing-book
locators and explicit alternate-copy roots, with database identity checks,
unchanged locator identity, absence checks, per-database intent-bound receipts
and read-only verification. It does not recreate deleted personal cards or
overwrite changed receipts. Changing a copy root must preserve its current
native logical address/format; an unpublished relative address prevents that
change and rolls back the transaction. Default roots and source/profile settings remain
separate; the owning finalization controller still needs independent durable
intent, final-aware resume and coordinated commits before this can be enabled
in the normal move flow. See
`docs/audits/2026-11-16-collection-transfer-final-rows.md`.

The production coordinator now has a durable roots/settings phase, with personal
intent before any catalogue setting commit, exact per-database receipts,
final-aware reference/location verification, writer-gap data_version checks and
atomic personal-root/phase publication. All affected source-catalogue filenames
follow reviewed forks, while only the selected roots/profiles relocate. Late
personal-only paths retain their meaning; known late missing cards follow their
reviewed future locations. Intent selects the resume route before ordinary
source preparation. The phase ends at `roots-applied` and deliberately leaves
the overall operation pending for source-cache/Reader and complete-controller
integration. See `docs/audits/2026-11-16-collection-transfer-finalization.md`.

## File preparation (implemented at file/group level)

`unit_CollectionTransferCopy` prepares one whole file, preserving and comparing
all enumerated NTFS data streams. It retains source/output read leases and
directory guards, reserves a unique adjacent temporary, verifies its file ID,
flushes and hashes its output, and publishes by handle without overwrite. Its
flushed append-only file journal resumes verified/published files without
recopying. Unknown files and invalid journals are preserved with a diagnostic.
Cancellation and process interruption never remove the source.

Native x86/x64 diagnostics each pass 25 cases, including actual E: to G: copying,
additional streams, long Unicode paths, collisions and interruption/recovery.
See `docs/audits/2026-11-16-collection-transfer-copy.md` for evidence and limits.
This is a building block, not a complete group journal or a usable move command.
The parent operation must supply the independent reviewed binding, retain all
group leases, revalidate original stream sets before cleanup and recover after
source removal. Ordinary Prepare still requires the original. A separate
VerifyDestination primitive now accepts an independently supplied recorded
identity/hash/stream proof and verifies the surviving output without touching
the old name. It retains destination-only leases, performs no copy/state write,
and cannot authorize removal or complete a group. See
`docs/audits/2026-11-16-collection-transfer-destination-recovery.md` for x86/x64
file-level validation. The parent journal now seals complete group proofs and
uses that path to recover mixed removed/retained groups and native image sets,
including kept-in-place files. Its caller must independently persist the proof
digest before any original removal. Recovery does not rewrite the proof/state
or publish/acknowledge source removal. See
`docs/audits/2026-11-16-collection-transfer-group-recovery.md` for the current
group-level evidence and the remaining operation-registry/removal integration.

The production registry in `unit_CollectionTransferRegistry` now records the
operation and independent group digests in the personal database. Discovery is
read-only and does not depend on a fixture control file or an available work
volume. Resume reopens the journal with its saved external review digest and
checks the registration against the immutable context and actual personal-file
identity. A copied personal database cannot silently adopt the original jobs.
`PublishPreparedGroup` commits the group digest with personal locators on the
existing publication connection. Its own registry writes therefore do not force
a complete reference recapture per archive, and no version acknowledgement can
hide an intervening external writer. Standalone preparation registration remains
available without publishing locators. Both paths still require exact retained
source/destination witnesses to seal the group. Registration alone does not
authorize source removal or complete an operation. The separate guarded removal
method and sequential phase do not themselves hook normal startup/UI.

The registry can now check a held group's independent digest and saved location
receipts without requiring the old archives. A shared publication-session lock
routine obtains all ready catalogue/personal writer transactions; verification
captures fresh references, requires the existing matching receipts and checks
the current projected locators. Native kind reconstruction uses frozen logical
containers, preserving ZIP/7z, raw and FBD semantics without probing old names.
It performs no location/history/table writes and rolls back all verification
transactions. This point-in-time result does not authorize a later unlink after
the locks are released. A separate removal method now commits independent exact
intent before protecting/hashing originals, reacquires a current reference and
receipt view, and unlinks only its held original handles. It retains changed,
unknown or dependent originals and distinguishes pending external readers.
Native evidence and scale limits are recorded in
`docs/audits/2026-11-16-collection-transfer-location-receipts.md`.
See also `docs/audits/2026-11-16-collection-transfer-source-removal.md`.

## Group publication, stop and recovery

The preparation half is implemented in `unit_CollectionTransferJournal`:
immutable externally bound review, mutable durable state, on-disk connected
components for shared sidecars, linked child journals and verified group leases.
It rechecks live locator fields without restoring older notes/progress. A ready
copy group remains pending publication and never authorizes original removal.
See `docs/audits/2026-11-16-collection-transfer-journal.md` for native crash/resume
evidence and the remaining whole-operation gates. Registered pending-job discovery
is supplied by the registry; the sequential publication/cleanup phase is supplied
by `unit_CollectionTransferOperation`. Finalization and normal startup/UI remain
separate. The journal's frozen
review now also inventories other registrations and their personal locators by
physical file ID, captures shared-database row conflicts, and records unknown
catalogues or unsupported path/resource aliases as retention requirements.
That inventory is an initial review snapshot, not permission to remove a file:
publication and cleanup must reconcile live references again.

The sequential phase registers before mutation, publishes necessary catalogue
forks and streams groups from the on-disk review. A group with a committed
personal location receipt and independent proof recovers verified destinations;
an uncommitted group prepares original-held files and completes publication.
It then runs the exact guarded removal stage and reports cumulative results.
An interrupted catalogue commit, completed group or protected source can resume
through the same production phase rather than a manually selected fixture path.

Source-free reconciliation requires existing matching per-database receipts;
it cannot recreate missing receipts or repair a changed catalogue address.
It can update known stale personal addresses and new cards for a reviewed main
book, preserving current notes/progress. A missing old file must match the frozen
main-book fields and logical path before this projection is allowed. A reused
old name with a different identity is not used to rebind a new personal card.
Already rebound compression history is not recopied from absent originals.
The phase deliberately leaves the operation registered as pending: final root
publication, unavailable/future locators, profile/cache coordination and normal
UI remain required. See
`docs/audits/2026-11-16-collection-transfer-operation.md`.

Distinguish the user-chosen containing folder from the mapped default book root.
Preserving that mapped default root can retain native relative locators/source
keys rather than gratuitously making every folder absolute. Missing roots need
an explicit future mapping even when no available file submitted that root to
the physical planner.

Inventory registrations by physical database file as well as collection ID.
The same catalogue can be registered with two different book roots: its one
relative row may then mean different physical books. An unconditional absolute
folder rewrite would redirect the other registration to the wrong book. Such a
case needs a proven per-registration strategy (for example deferred root
publication with retained originals, or an owned catalogue fork with unchanged
personal IDs). The selected strategy for divergent shared rows is an owned
catalogue fork per registration/root group that needs different locator
updates, created with the existing SQLite online backup API. Preserve personal
registration/book IDs and source keys; publish the new registration filename
with durable markers before modifying divergent rows. Account for the extra
metadata space and retain the original database until recovery no longer
needs it. Metadata snapshot creation and explicit registration publication are
now implemented and natively tested on x86/x64, including WAL data and repeated
process interruption (see `docs/audits/2026-11-16-collection-transfer-forks.md`).
The journal's group locator publisher now uses that effective-catalogue mapping
and commits each database's locators/history with a matching publication receipt.
See `docs/audits/2026-11-16-collection-transfer-locations.md` for its native
validation. A fresh disk-backed reference scan now precedes locator commits,
while the personal store and every reviewed ready catalogue hold write
transactions. New archive references, registrations, source metadata or newly
unreadable catalogues require a renewed plan before this group changes. New
personal cards for an approved main book and unrelated books remain allowed.
See `docs/audits/2026-11-16-collection-transfer-reference-fence.md` for the initial
native fence. The journal now reuses exact writer connections and an indexed
disk-backed reference snapshot across groups. It reacquires writer transactions
at each boundary; external data_version changes trigger a new capture without
acknowledging intervening writes as own commits. Unknown-file arrivals are
rechecked. Both architectures prove one capture for 26 archive groups and a
new capture after external catalogue/personal/WAL changes. See
`docs/audits/2026-11-16-collection-transfer-publication-session.md` for evidence
and the separate live-filesystem/cleanup/real-scale gates. A cached database
snapshot never grants permission to remove an original. Prepared copy results
now reacquire strict named-stream leases after rename and verify those named
stream hashes, closing the DELETE-sharing gap at handoff. Each group checks
its held file/stream witnesses and native external-picture resolution at the
mapped paths before locator publication; versioned resource receipts are
replayed rather than overwritten. See
`docs/audits/2026-11-16-collection-transfer-resources.md` for x86/x64 evidence.
These resource receipts do not authorize original cleanup or replace its fresh
live-reference/removal-intent proof. The normal UI
still has to close conflicting writable DAO
connections, block other pending compression/update jobs, refresh registrations
after a fork commit and account for snapshot/fork space. Fork publication keeps
the initial book root; final root publication needs its own durable marker and
must extend that validation. None of this permits source archive removal before
the remaining group-publication and cleanup proof.

Process archive groups sequentially. A durable operation journal records an
immutable reviewed file mapping, expected original identities, affected catalogue
and personal bindings, and progress for each group. No pathname taken from a
mutable JSON response grants ownership of existing files.

1. Before copying, guard the source against replacement/writes and verify its
   reviewed identity. Hash its streams with bounded memory and copy to an
   exclusively reserved owned temporary file on the destination volume.
2. Flush the destination, read it back and verify full byte length and checksum.
   Do this for the book container and every required sidecar before publication.
   Recheck destination directory handles/containment; publish without overwrite.
3. Journal intent before changing any catalogue. For the current archive group,
   update all affected main, copy and personal locators in every participating
   registered catalogue. Record a durable operation/group marker in the same
   transaction as each database's locator changes. A multi-database interruption
   is recovered before normal startup or source updates can proceed.
4. Verify native book reading, all changed bindings, personal data and dependent
   resources. Rebind the proven compression history to the new physical file
   identities, paths and sidecar stamps. Copying bytes changes file IDs: dropping
   history would silently allow a later destructive recompression. Existing
   Reader caches need a proven rebind or invalidation with progress retained.
5. Only after every required database marker and native validation is durable
   may the original file name be removed. Recheck exact identity/checksum and
   references from all registered collections. If an unrelated or inaccessible
   catalogue cannot be proven independent, retain the original and report why;
   never sacrifice another collection to meet a “move complete” counter.
6. At final completion, publish new source roots, retained index/cache roots,
   bound update-profile book roots and the target root. Keep relative source
   keys stable. Unavailable records receive explicit future locators without
   being marked downloaded. Recheck negative witnesses so a newly arriving file
   or sidecar cannot be orphaned by the final root switch.

Completing groups incrementally avoids requiring an extra full copy on a volume
when source and destination share that volume. Account for files retained due to
other references in the estimate. A cross-volume destination still needs space
for the incoming payload; do not promise that deleting from another disk makes
space on the destination. Reuse/rename/hardlink optimizations require their own
proof and are not part of the initial planner.

Stop after a safe group boundary and leave previously completed groups readable;
do not undo hours of verified transfer merely because the user stops. Keep an
unfinished journal discoverable, block conflicting updates and offer resume.
On crash, source and destination evidence plus committed database markers decide
whether to finish publication or retain originals. A second crash during recovery
must preserve that decision evidence. Never recursively delete an unrecognised
job folder or an entire old source root. Empty folders can be left behind.

## Required evidence before enabling the command

### Source-cache identity and location projection

`unit_CollectionTransferCache` now projects a caller-owned unpublished cache clone
inside its transaction. It never rewrites the shared original baseline. It uses
the frozen physical-file map, observed whole-root aliases, unavailable-locator
projection and recorded absent ZIP names to retain native ZIP/7z, raw and FBD
addresses. It does not probe old originals, which may be absent or reused.
Unlisted cache books keep their original logical addresses, made absolute when
necessary; changing a source root cannot silently redirect them to new files.
The indexed working path map resides in the owned clone rather than SQLite's
default in-memory TEMP store. Book rows are streamed and key writes are prepared.

Publisher locations and source-link keys survive the change independently of
the new physical locator. Empty-LIBID review keys also survive an address outside
the new source root. The common key algorithms are extracted without changing
their existing bytes. Immutable source snapshots expose saved source keys to the
ordinary merge path; library-update preparation reads/preserves review-key
overrides. Prior availability/exclusion data and unrelated cache metadata stay
with the clone. An operation/source marker refuses projecting an already
successful clone again using its old root; a new preparation attempt must clone
the immutable baseline again.

This is not the durable cache controller. It still needs to enumerate both
current sources and independent update-history baselines in every participating
catalogue, reserve and publish compatible GUID cache versions and retained raw
indices, atomically change their references under independent recovery intent,
and route partial-commit startup before another roots phase. Other collections
may continue using the old shared cache. Reader identities, normal DAO/job
coordination and full/incremental INPX after the complete move remain required.
Evidence: `docs/audits/2026-11-16-collection-transfer-cache.md`.

`TTransferCacheSettingsPlan` supplies the metadata part of that controller. It
projects current source settings through the frozen layout and independently
projects per-profile update history. An indexed owned work store deduplicates
jobs by exact source ID/namespace, old cache path and old/new book roots. Current
source and matching bound history share one new GUID version; another catalogue
which keeps its old root receives a separate version. Unbound profiles retain
their own IDs/baselines, including when there is no current source list. External
catalogues remain external; a user-selected refresh index outside the cache keeps
its original path. Retained raw inputs get explicit per-version co-located copy
targets, preserved expected hashes and conflict detection. Unknown JSON fields
and update-profile bindings survive.

Replay supplies versions by the independently persisted semantic job key. It
reconstructs the same exported settings/input targets, refuses a missing job
instead of inventing another GUID, and cannot choose the original cache path.
The model itself creates no cache directory, copies no input and publishes no
setting. Its GUIDs/paths alone do not prove ownership or authorize publication;
the next controller must bind them to independent intent, snapshots and prepared
file proofs. Details: `docs/audits/2026-11-16-collection-transfer-cache-settings.md`.

`TTransferCacheSnapshot` now creates the actual projected SQLite clone and raw
index copies in a fresh operation-work directory. It reserves/records file IDs
before large writes, takes the baseline through SQLite's backup API under a
source writer lock (including committed WAL rows), projects metadata and retains
read leases on verified outputs. Known raw-input hashes and the copied bytes
must match. A flushed ready manifest is bound to the immutable review/job/inputs;
the parent records its digest and directory identity independently. Recovery
requires both, rehashes every exact file and can recover a ready work snapshot
without its original cache or index. Incomplete stages cannot be guessed ready
and remain for the parent's ownership-aware cleanup. This is preparation only;
no persistent cache-version directory or source/history setting is published.

`TCollectionTransferCachePreparation` connects this preparation to an independent
personal intent before the coordinator's source-removal phase. It captures the
current data root, original cache/input identities, fixed new versions and exact
source/history before/after values under writer/input locks. Replay reconstructs
the metadata model and recovers ready snapshots from independently saved proofs;
unready jobs require their original identities. Directory/file claims and ready
digests commit in the personal store, with old-attempt ownership retained. All
ready output leases stay held until the full dependency set is rechecked and
marked prepared. A catalogue that is also a cache lends its existing writer.
An existing intent is enforced on continuation even without the initial option;
authorized roots replay is validated by the roots controller first. The command
and overall operation remain disabled/pending. See
`docs/audits/2026-11-16-collection-transfer-cache-preparation.md`.

`TTransferCacheInstallation` now materializes the fixed new version directories.
The prepared personal intent freezes the data-directory identity; the metadata
model rejects colliding new version paths. Each installation binds the exact
review/intent/job/inputs and snapshot digest, records attempt/file ownership before
copying, flushes and reads back every file, and commits its ready proof before
renaming the exact owned directory handle without replacement. Strict named-file
leases and complete identity/hash/membership checks follow the rename before the
published marker. A ready exit before/after rename recovers the same objects;
unready attempts are retained and a fresh attempt is used. Source/history
references remain unchanged and the operation remains pending. Evidence and
the NTFS child-handle transition are described in
`docs/audits/2026-11-16-collection-transfer-cache-installation.md`.

### Durable cache metadata cutover

Only after every fixed version is independently proved published may source and
history references change. Write both properties and a receipt in each database's
same transaction. Bind the receipt to its database key, immutable review, cache
intent, root intent and complete installation-proof set. Commit, reacquire the
same writer and check data_version; a foreign writer's intervening update must
be revalidated, never acknowledged as the transfer's own write.

Partial publication needs a shared read/validation gate under the already-owned
publication session. Reconstruct the fixed cache plan, verify all installed
directory/file proofs under leases, and authorize sources_after/history_after
only for a participant with its exact matching receipt. Other participants must
still match their roots-only sources and history_before. The prior roots
controller must accept that exact authorized source projection in its reference
callback and settings check; it must never accept arbitrary cache_version edits
or reset successfully published metadata to roots-only values. This gate must
not start nested finalization transactions. Recovery after receipts should be
able to use installed files and independent records without old baselines or
discarded work snapshots, while preserving the immutable operation review.

The native controller now implements this cutover. A personal publication intent
is committed first; each catalogue atomically switches both properties with its
receipt; the personal marker becomes published only after every participant is
verified. The roots controller uses the shared guard in its existing session and
the coordinator automatically continues an existing publication. Recovery does
not require original caches or work snapshots, and unchanged replay performs no
database writes. Missing receipts and foreign source/history edits are refused.
The installation guard validates all manifest names before opening any file.
Evidence: `docs/audits/2026-11-16-collection-transfer-cache-metadata.md`.

Startup/UI routing through that gate before ordinary source updates remains open.
After all metadata receipts are proved, normal DAO/job/Reader coordination,
old-baseline changes, complete-operation state, ownership-aware cleanup, space
accounting and final gates still remain. Verify a real full/incremental INPX with
only a new archive after cutover: saved publisher/source/review keys must preserve
old physical locators, compression history, copies and personal data. Snapshot
evidence: `docs/audits/2026-11-16-collection-transfer-cache-snapshot.md`.

### Full operation gates

The first real post-transfer INPX composition now passes on x86/x64: two
compressed bound FB2/EPUB source archives, both former roots offline, full/append
updates from a new incoming folder, exactly one new member, unchanged old archive
hashes/book and source/copy keys/personal fields, and incremental selection of
only the arrival. It also exercises preferred-source updates, personal-size
rollback and an independent final card-count check. An actual SQL column mismatch
in review-key preservation was found and fixed. This is one small native/Main
scenario, not the ordinary transfer UI or all format/profile combinations.
Evidence: `docs/audits/2026-11-16-collection-transfer-inpx.md`.

- Native planner on x86/x64: equal archive names in distinct roots, root aliases
  and overlaps, already-in-place first source, FLibrary sidecars, repeated
  locators, missing/changed files, hardlinks, cancellation and foreign files.
- Real catalogue adapter: ordinary, merged and personal rows; empty/missing
  locators; source priorities/keys, retained INPX baselines and update profiles.
- Actual same-volume and cross-volume transfers with native reading of ZIP,
  7z/FLibrary, loose/FBD and mixed compressed books; full file hashes before/after.
- Crash points around group publication, each catalogue commit, source cleanup,
  final roots and interrupted recovery. Preserve unrelated files and collections.
- After a move, apply full/incremental INPX from a new incoming archive directory,
  add one book and recompress new books only. Old lossy payloads must remain
  byte-exact; restore the same reading progress, favourites, ratings and notes.
- Ordinary visible workflow, clear estimates/conflicts and stop/resume on both
  final Main architectures. No Desktop replacement until all release gates pass.

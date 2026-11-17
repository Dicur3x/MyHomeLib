# Physical consolidation of collection sources

Status: native inventory, recoverable file/catalogue publication, guarded source
removal, final roots, source/history cache publication, Reader aliases and atomic
whole-operation completion are implemented. The local Main/Sources command now
connects preview, stop/resume, active-view reload and explicit startup continuation.
Space presentation, owned working-data cleanup, scale, remaining format/update
compositions and final production/release gates remain open. No user collection
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

The local preview now includes a per-volume planning allowance for payloads,
working metadata/cache snapshots, installed cache versions and catalogue/fork
processing. A volume identity combines roles and applies the largest reserve
once: 8 GiB on the system volume, 512 MiB elsewhere. File bytes include named
streams and exclude in-place payloads; future source deletion is never credited.
The cache plan reuses the actual source/history projection. A separate preview
review kind permits metadata-only fork planning and cannot register or prepare a
move. Its owned draft is discarded after estimation. Initial UI capture/planning
also polls the reserves, and an estimation failure disables Transfer. Growth
factors are planning allowances rather than an exact peak or reserved capacity;
runtime guards still stop insufficient-space writes. Native evidence and limits:
`docs/audits/2026-11-17-collection-transfer-space.md`.

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
uses a frozen approval index and a held read-only attachment for new short local
reviews. Membership checks execute inside SQLite with scoped SQL cancellation;
old reviews and long/UNC work paths retain their disk projection. The same fresh
reference captures still occur. The first 100,003-row synthetic catalogue timing
pair improves from 120.078 to 95.937 s; this is not archive-copy throughput or a
million-row/peak-memory gate. Evidence and limits are in
`docs/audits/2026-11-17-collection-transfer-approval-index.md`. The normal UI
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

Startup/UI routing now uses that gate before allowing conflicting source changes.
Ownership-aware cleanup, space accounting and final gates still remain.
Verify a real full/incremental INPX with
only a new archive after cutover: saved publisher/source/review keys must preserve
old physical locators, compression history, copies and personal data. Snapshot
evidence: `docs/audits/2026-11-16-collection-transfer-cache-snapshot.md`.

### Full operation gates

The coordinator must not enter final roots/cache publication while original
unlink is pending. An external reader can defer deletion even after a successful
copy and locator commit. Advancing roots then selects metadata-only continuation
and would bypass the unfinished removal phase. Keep the operation registered,
copies and dependency snapshots intact; retry the published groups after the
reader releases its handle, without copying them again.

### Reader identity before normal UI completion

The existing `ReaderHistoryName` is stable for scoped library IDs, but placeholders
and positive unscoped IDs can depend on the folder or physical path. The bound
FB2/EPUB INPX gate does not prove those histories survive a move. Do not
replace the identity algorithm globally with BookID: full imports can reuse rows.
Preserve a changed before-name through a durable alias bound to collection/book
identity, LibID and the exact reviewed after-locator. Prepare this from immutable
review data before locator publication, enforce it on partial continuation and
validate it before whole-operation completion. A later move must preserve an
existing alias rather than start a fresh history. Distinct old histories that
collide must be retained and resolved explicitly, never overwritten silently.
Compute the before-name from the exact stored root/folder/copy-root spelling;
canonical roots cannot substitute for raw roots across junctions or aliases.
Do not probe former original paths, which can already be absent or reused.

All consumers need the same lookup: Reader launch, next volume, recent reading,
notes/notebooks and duplicate detection. Use the existing personal database
connection with a prepared lookup, not a new connection or schema query per
book; invalidate its negative/table cache when Main reloads after transfer.
The bound alias lookup and transactional writer are now implemented. A pending
independent roots intent also covers recovery after a catalogue commit rolls
back its personal aliases; committed aliases cannot be silently reminted.
Native x86/x64 checks cover conflicts, changed identities/locators and missing
books. The actual initialized DAO and built-in Reader also pass on both
architectures for five FB2 identity types after original archive removal: saved
positions, bookmark context/navigation, notes, changed-title direct note binding
and the notes filter. Evidence:
`docs/audits/2026-11-16-collection-transfer-reader-history.md`. This is a small
ZIP/FB2 scenario; it does not prove every format, later reimport or second move.
The Main entry waits for active preparation/session callbacks, built-in Reader
hosts, pending saved-reader replies and conflicting jobs. It does not forcibly
close a user's reader to begin transfer. Final release checks still apply.

### Whole-operation acknowledgement

`CompleteTransfer` now provides an explicit final gate after DAO/Reader reload.
Its required application-ready callback is read-only; the Main workflow must
block new conflicting jobs before using it. The gate reuses the final roots
session and existing writer locks, requires applied roots and fully published
source/history versions, validates each original-removal binding alongside its
recovered group, and refuses any pending original. Summary and completed registry
state commit in the same personal transaction. A late cancel/busy callback or
pre-commit exit rolls both back; post-commit recovery reads the same historical
summary without rewriting databases. Totals cover the whole reviewed inventory,
including earlier runs and in-place files. A lost completion receipt is refused.

Ten native cases per architecture and the actual DAO/Reader composition pass on
x86/x64. Evidence: `docs/audits/2026-11-16-collection-transfer-completion.md`.
The ordinary Main workflow described below now calls this gate after reloading
the target view. Working-data cleanup and scale remain separate gates.

### Ordinary local workflow

`Collection → Собрать файлы в одну папку…` and the matching Sources button open
the same modal window. The user chooses existing destination and working folders,
checks a read-only plan and explicitly starts the move. Changing a path discards
the previous plan. Registered continuation locks both paths to their saved values.
The preview closes the current DAO view before capturing the catalogue; closing
the window restores it. Native work runs in a background thread, with atomic
cancellation/readiness flags and locked progress snapshots. Plan callbacks belong
to the window context and outlive the preview thread; a later phase resets
cancellation without reusing a freed worker.

Main blocks conflicting catalogue commands while the window is active or the
current collection has a pending transfer. The entry waits for catalogue loading,
compression/deletion/recovery/download work, Reader preparation, external session
callbacks, saved Reader replies and built-in Reader hosts. After a run, Main
clears DAO caches, reloads the same collection, invalidates favourites and waits
for the active view before final acknowledgement. Completion stays in the same
window, comes to the front and reports processed physical inventory and original
files removed/missing/retained. Its current-file display is a label, not an input.

The ordinary startup offers Continue or Later, defaulting to Later. It does not
resume a move without that choice. Later preserves the registered operation;
Sources or the transfer menu can resume it manually. Registration follows journal
creation even when cancellation arrives before the first group, so an early stop
remains discoverable. Dark-theme controls and 225% layout use explicit geometry
after scaling and resize. The ordinary small-catalogue evidence and its limits are
recorded in `docs/audits/2026-11-17-collection-transfer-ui.md`.

### Owned draft cleanup

If the initial journal constructor fails or is cancelled before returning, its
destructor can discard only that newly created draft. Physical IDs are recorded
for its directory, empty copies directory and three metadata files. After
releasing its ordinary leases, cleanup acquires deletion handles and validates
the complete entry set before unlinking anything. Unknown entries, replacement
IDs, reparse points, hardlinks and busy files preserve the draft. There is no
recursive removal or check-then-delete path lookup. Completed constructors and
all resumed journals are retained, including valid unregistered native reviews.
Evidence: `docs/audits/2026-11-17-collection-transfer-preparation-cleanup.md`.
Hard-exit discovery of unregistered drafts remains open; in-memory ownership of
this draft is not authority to clean arbitrary folders.

### Completed work-snapshot cleanup

After durable whole-operation completion, the journal releases its own remaining
publication leases and can remove its cache-snapshot working directories. The
completion receipt and frozen review remain as historical evidence. Installed
cache versions, original cache databases, retained indexes and books are excluded.
Ownership comes from the independent preparation intent and personal-database
directory/file claims, persisted before large writes. All directory claims are
validated against the intent, exact journal parent and allowed leaf names before
any cleanup. Each directory is then held by physical ID and every current entry
is opened by its recorded ID before the first unlink. Reparse points, hardlinks,
unknown entries, extra data streams and busy or replacement objects retain the
directory. Deletion uses the held handle. Byte totals describe logical working
data, not measured filesystem space recovered.

Cancellation or a process exit may leave some owned files already absent. A
later pass skips those missing entries and resumes the same claims. A separate
short personal transaction records cleanup attempts/done state; it cannot change
completed back to pending or rewrite the transfer summary. Repeated successful
cleanup does not rewrite an already-done marker. Failed cleanup has no authority
to move books or switch source settings.

The ordinary transfer window reports cleanup after completion and treats any
cleanup failure as deferred housekeeping, retaining the completed move. Ordinary
startup schedules a low-priority worker after 30 seconds and an idle check; review
hashing and filesystem work stay off the UI thread. The worker owns no GUI state,
can be cancelled when Main closes and handles a bounded queue of completed
operations. Inaccessible or busy operations get a later-attempt stamp. A cleanup
reader validates the immutable review and completed receipt without opening the
mutable transfer state or requiring the destination to be online. It cannot be
used to register or publish a transfer. It also skips transfer-allocation reserve
checks so that cleanup is still possible when disk space is already low.

Native and ordinary-window evidence is recorded in
`docs/audits/2026-11-17-collection-transfer-completed-cleanup.md`. Unregistered
hard-exit drafts, unknown SQLite side files in abandoned incomplete snapshots,
large-volume peak use and final production gates remain separate requirements.

### Remaining end-to-end evidence

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

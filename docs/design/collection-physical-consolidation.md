# Physical consolidation of collection sources

Status: native inventory, file/group copy journals, catalogue/fork publication,
resource verification and destination-only group recovery are implemented as
internal stages. Whole-operation control, guarded source removal, startup and
normal UI remain open. No user collection has been moved by this work.

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

## File preparation (implemented, not connected to catalogues)

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
source/destination witnesses to seal the group. This registry does not authorize
source removal, complete an operation or itself hook the normal startup/UI.

## Group publication, stop and recovery

The preparation half is implemented in `unit_CollectionTransferJournal`:
immutable externally bound review, mutable durable state, on-disk connected
components for shared sidecars, linked child journals and verified group leases.
It rechecks live locator fields without restoring older notes/progress. A ready
copy group remains pending publication and never authorizes original removal.
See `docs/audits/2026-11-16-collection-transfer-journal.md` for native crash/resume
evidence and the remaining whole-operation gates. Pending-job discovery and the
whole-operation publication/cleanup are not implemented by that journal. Its frozen
review now also inventories other registrations and their personal locators by
physical file ID, captures shared-database row conflicts, and records unknown
catalogues or unsupported path/resource aliases as retention requirements.
That inventory is an initial review snapshot, not permission to remove a file:
publication and cleanup must reconcile live references again.

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

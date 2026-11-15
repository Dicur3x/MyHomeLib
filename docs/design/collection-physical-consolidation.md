# Physical consolidation of collection sources

Status: implementation started; inventory planner only. There is no published
transfer command and no user collection has been moved by this work.

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
cleans its owned scratch store. It does not yet enumerate the catalogue, copy
payloads or publish any database changes. Missing payloads currently reject an
input; the catalogue adapter must classify missing locators before submission.
Pre-existing hardlinks and file links currently receive an explicit diagnostic.
Internal directory links which change relative layout are rejected as well;
whole-root junction aliases are supported. Discovery uses extended Windows paths
for both the book signature and FLibrary sidecars.

The review must explain destination, physically transferred bytes/files,
already-in-place files, sidecars, unavailable books, affected registered
collections and why any source archive will be retained. Display space by volume
and a peak temporary-space estimate; do not add whole-library extraction space.
Recheck the 8 GiB system reserve and destination/work-volume reserves before and
during long work. Losing the reserve stops preparation without deleting sources.

## Publication, stop and recovery (still to implement)

Process archive groups sequentially. A durable operation journal records an
immutable reviewed file mapping, expected original identities, affected catalogue
and personal bindings, and progress for each group. No pathname taken from a
mutable JSON response grants ownership of existing files.

1. Before copying, guard the source against replacement/writes and verify its
   reviewed identity. Copy to an exclusively created owned temporary file on
   the destination volume. Stream bytes and compute SHA-256 with bounded memory.
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

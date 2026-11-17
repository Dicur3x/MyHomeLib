# Ownership of disposable nested catalogue snapshots

The initial preparation claim covered only review/state/lease and an empty
copies directory. Shared-catalogue preparation can also create large private
`catalogue-snapshots` databases, so a killed constructor previously retained the
whole draft rather than deleting unproven nested content.

## Ownership before data

The exclusive lease now accepts append-only, bounded, checksummed ownership
frames after its unchanged initial claim. A frame binds the physical ID of the
new snapshot directory or a canonical GUID `.hlc2` child. Directory ownership is
flushed before file creation; file ownership is flushed while the new empty
file is still held exclusively, before any backup writes. An existing directory
must already have the same creation identity in this constructor's ownership
map. Unknown paths, duplicate claims and traversal are refused.

Each frame is at most 1 MiB, and the whole lease is limited to 16 MiB. Readers
validate every frame before deletion. The ready tail remains outside the frame
format: complete/torn ready tails and unknown or partial records preserve the
journal. The earlier strict single-record cleaner also retains an extended
lease instead of mistaking it for an eligible simple draft.

Disposable snapshot targets, like the unreturned review/state, use MEMORY
rollback during construction and restore DELETE/FULL before sealing. These
files are discarded after an interrupted construction, never resumed as valid
catalogues. User/source databases and successful publication transactions do
not use the disposable mode. A 512 KiB snapshot target cache bounds its scratch
pager; source backup includes committed WAL pages through SQLite's backup API.

## Cleanup and continuation

The cleaner validates the full present entry set and all held identities before
unlinking anything. It accepts only the initial files, empty copies directory,
and claimed snapshot directory/files. Unknown SQLite side files, other files or
directories, replaced IDs, links, streams, busy handles and malformed ownership
preserve the entire draft. Deletion never follows a path after identity checks
and never recurses.

Known disposable entries may already be missing after a previous cleanup. The
lease is retained until data files and child directories are gone, so another
process can reclaim remaining proven entries after a cleanup crash. A process
loss after the final claim unlink can still leave a small empty unproven root;
that remains conservative retention. The parent work container itself is never
deleted or stripped of metadata; its readonly display attribute and named data
streams do not prevent cleanup of a proven child. Owned objects retain strict
stream/link/reparse checks.

Normal cancellation/error cleanup also invokes the same identity-bound nested
cleaner once its database/file/directory leases are closed. Ready and older
unregistered journals remain protected. Cleanup runs on the next preparation in
the same selected work root, not through an all-volume startup scan.

## Verification scope

Targeted native checks exercise an interrupted backup with observed written
pages and remaining source pages, two independent snapshots and a process exit
after the first snapshot unlink, live cancellation, ready review retention,
foreign files/subdirectories, unknown journal files, replacement IDs, hardlinks,
streams, busy readers, torn/bad/traversing/duplicate claims, and preserved work
container metadata. Existing simple-draft, read-only sort, shared catalogue
publication/WAL/writer-conflict/crash recovery, completion and completion-crash
checks are rerun on both architectures. `G:/HL-b14-external/transfer-nested-draft-validation-r1276/summary.json`
records 661 matching repository/build inputs and successful runs r1272/r1273:
20 methods per architecture, 204 native calls, 82 deliberate process exits and
six expected safety/cancellation refusals. There are no skips or retained private
runtimes. The interrupted backups have completed 512 of 782 source pages and
written 6,602,752 / 6,569,984 bytes to the destination file; the damaged scratch
copies are reclaimed without opening them. Two-snapshot cleanup resumes after
its first snapshot unlink. The full targeted suite passes in 477.829 / 480.188 s
under concurrent testing; this is not a performance comparison.

Final driver builds: x64 r1269
`b39d7928a5d858f6e32a71a8b525df7bdb8ed9cdc6ff7a28714d60f8c1d14c66`,
x86 r1271
`6f624926ce4ac00b3fcbe7bf0343282d12d51674cf7cc0370b4ef3b9d9d490e5`.

All fixtures/outputs use private G: directories; user libraries and Desktop
binaries are unchanged. This does not prove current million-scale memory/space,
real allocation failures, every filesystem/mount behavior, ordinary final UI,
unproven side files of other cache workflows or release packages.


A ready journal's fork payloads are deliberately outside this draft cleaner.
Reclaiming those after independently confirmed whole-operation completion still
needs a separate receipt-bound path; preserving ready journals here is not
proof that all completed-operation scratch space has been reclaimed.


Production Main compiles successfully on x64 r1274 and x86 r1275 with these
sources, without transfer test hooks. PE machine/hash evidence is included in
r1276. Resources remain the current development version 3.0.0.13 /
3.0.0_pre1.13 with original filename HomeLibre.exe. This is compilation evidence,
not final beta14 versioning, ordinary UI/package validation or Desktop delivery.

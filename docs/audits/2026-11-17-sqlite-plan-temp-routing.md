# Connection-local SQLite planning temp files

The scratch planner selected `temp_store=FILE`, but its database filename did
not select a directory for SQLite's anonymous sort/temp files. The Windows VFS
normally chooses that directory separately. Test processes using G: as their
process TEMP did not establish correct routing in an ordinary application.
SQLite documents the [storage distinction](https://www.sqlite.org/tempfiles.html#temporary_file_storage_locations)
and supports [connection-selected VFS shims](https://www.sqlite.org/vfs.html#vfs_shims).

`SQLiteWrap` now accepts an optional explicit temporary directory for writable
and read-only connections. `TCompressionPlanStore` supplies its own held work
folder on create, seal/reopen and edit. A unique per-connection VFS redirects
only anonymous DELETEONCLOSE requests. Named database, journal and WAL paths are
passed unchanged to the standard locking Windows long-path VFS. The default VFS,
process TEMP/TMP and global SQLite temp directory are not changed. Other callers
retain their default connection behavior; this is not blanket routing of every
SQLite connection in the application.

The shim delegates the OS methods using the underlying VFS pointer. Generated
names use SQLite's [filename allocation API](https://www.sqlite.org/c3ref/create_filename.html)
and stay alive until the native connection closes, covering the VFS filename
lifetime contract and URI metadata access. The directory is held against delete
and rejects a reparse leaf. Opening a new anonymous file checks the system 8 GiB
and target 512 MiB reserves; a failure returns an SQLite error without falling
back to the OS temp folder. These checks are not a disk quota or a test of real
ENOSPC; named journals remain subject to the surrounding volume budget.

## Native evidence

`G:/HL-b14-external/sqlite-temp-validation-r1225/summary.json` records 656 current
source/resource/test inputs matching the build tree and 34 passing native calls:

- Six direct methods per architecture: physical spills in independent Unicode
  roots, WAL writer-lock compatibility with a default connection, reserve-query
  refusal without fallback, a long path, plan seal/edit plus read-only sort, and
  forced exit while an observed on-disk spill is live. Closed/killed connections
  remove their anonymous files; OS-temp folders remain empty and plan folders
  are cleaned. Native binaries are x64 r1207 / x86 r1209.
- The full 2,003-row transfer/cache/root/completion/replay workflow passes on
  x64 r1214 (31.734 s) and x86 r1216 (53.547 s), with unchanged user-data guards
  and byte-exact replay. Driver binaries are r1212/r1215.
- Unicode/%/# approval attachment, long-path legacy projection and SQL
  cancellation pass in r1217/r1218; interrupted source unlink recovers without
  recopying in r1219/r1220. Across both architectures these have two deliberate
  process exits and two expected SQL refusals. The direct live-spill tests add
  two further deliberate process terminations.

There are no skipped cases or remaining private runtimes. Integration snapshots
precede only the later addition of the direct live-exit Python test; all native
production source inputs are identical. Earlier four/five-method direct passes
are supporting history, not additional unique coverage.

## Remaining integration scope

The completed million-row runs in the full-scale audit use the preceding native
driver, before this routing change. The new driver still requires its large
scale point and final ordinary applications. Other SQLite connections, real
allocation failures, mounted/unavailable volumes, incomplete work-snapshot side
files and final release packages remain separate gates. All fixtures and outputs
are on G:, E: is unused, and user catalogues/archives and Desktop binaries have
not changed.

The first routed Win32 scale run r1227 was terminated by its benchmark wrapper,
not an application error: replacing the optional progress JSON collided with a
Windows reader denying delete sharing. Its failed report and removed runtime
are retained. Progress publication is now best-effort; a real held Windows
reader test proves that the preceding JSON remains valid and publication resumes
after the reader closes. The native operation and its authoritative samples and
final report are not aborted by that status-file collision. Win64 r1226 remains
on the original live wrapper; Win32 r1229 uses the corrected wrapper. The latter
has 657 input files, differing in benchmark/test code rather than production
SQLite/transfer code. Both scale outcomes remain pending.


## Transfer connections use their owned work folders

The explicit `temp_store=FILE` review connection was outside the original plan
store change. Review creation/reopening, mutable state, reference readers,
publication writers, registry mutations, catalogue forks, cache snapshots and
preparation, finalization/completion and active cleanup now select the held
operation folder. Catalogue capture first creates its disposable plan store and
uses that folder for both source readers; the readers close before that store is
removed. Snapshot readers/writers use the snapshot folder after it exists.
Connections borrowing the review inherit its canonical `TemporaryDirectory`;
the property is empty for connections without an opt-in VFS.

This does not change the named journal location or process environment. The
small operation-discovery/cleanup-queue queries, and an error-marker fallback
without an opened journal, retain their default connection behavior. SQLite
connections in unrelated application subsystems have not been audited here.

The native transfer fixture now sorts 9,000 generated 2 KiB payloads on the
actual sealed review connection, observes a live physical spill in the operation
folder and checks the sum of all IDs. It repeats on fresh-process completion
and completion replay, with database-byte and preserved-user-data guards. The
review remains query-only: an initial fixture incorrectly tried creating a TEMP
table and was rejected by that existing protection (`r1233`). The corrected
fixture performs a read-only sort and leaves query-only protection enabled.
That failed fixture is retained and is not a passing application scenario.

`G:/HL-b14-external/transfer-work-temp-validation-r1244/summary.json`
records 658 matching repository/build inputs and 16 passing methods across
x64 r1240 / x86 r1241: 44 native calls, 20 expected safety refusals, no skips or
remaining private runtimes. The three physical read-only sorts per architecture
each observed 18,503,891 bytes in the operation folder; fresh completion and
replay preserved the stored database bytes. The same run covers disposable
constructor cancellation, foreign/replaced/linked/busy entry retention, cancelled
space preview, Unicode/%/# approval attachment, long-path legacy approval,
SQL cancellation and completed-snapshot cleanup/replay with installed caches
preserved. The corrected driver binaries are x64 r1235 / x86 r1237.

The two million-row runs r1226/r1229 still exercise the preceding,
plan-store-only routing snapshot; they are not validation of this wider
connection selection. Production Main builds and ordinary UI/release outcomes
remain distinct evidence.


Production `Program/HomeLibre.dproj` also compiles successfully on x64 r1242
and x86 r1243 with these production sources, without transfer test hooks. The
new executables have the correct PE machines and `HomeLibre.exe` original file
name. Their current development resource remains `3.0.0.13` /
`3.0.0_pre1.13`; release versioning is still a final beta14 gate. SHA256 and
build stages are recorded in r1244. Compilation does not establish ordinary UI,
update-package or final-release readiness; Desktop binaries remain unchanged.


## Completed catalogue-scale runs with plan-store routing

Both pending runs are now successful; consolidated evidence is
`G:/HL-b14-external/transfer-routed-million-validation-r1247/summary.json`:

- x64 r1226: move / fresh completion / replay 1833.688 / 348.953 / 5.078 s;
  peak job commit 291,819,520 / 117,194,752 / 5,943,296 bytes.
- x86 r1229: 2005.343 / 284.094 / 4.563 s;
  peak job commit 171,786,240 / 157,040,640 / 5,148,672 bytes.

Each has 1,000,003 main/source-A cache books and three source-B cache books.
All compared non-locator user-data hashes and independently derived cache
update identities match. Six protected cache/index/neighbor inputs remain
unchanged. Both tiny carriers are moved byte-exactly and originals removed;
final roots match the frozen plan, pending operations are zero and a new replay
process leaves database bytes unchanged. All six native calls return zero, and
both private runtimes are removed.

Observed extra allocated file bytes are 4,048,721,928 / 4,049,369,096. Sampling
does not include every volume metadata cost or necessarily every short peak;
this is not an ENOSPC or quota guarantee. These partially overlapping runs,
with other builds/tests in progress, do not establish a performance improvement.
They exercise two small ZIP carriers, not a terabyte-scale archive workload.
The fixed input snapshots are 656 / 657 files, with production SQLite routing
from `6f76ac86`; the x86 wrapper includes the later status-file sharing fix.
They precede `466a11a2` and the draft-recovery changes, so they cannot establish
scale validation of those later changes or ordinary-app/release readiness.

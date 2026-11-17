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

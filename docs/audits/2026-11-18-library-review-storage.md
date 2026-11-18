# Reviewed-update SQLite working storage

The prepared index and comparison database already lived in the update work
folder, but their SQLite sorts used memory or the default temporary-file
selection. The previous transfer-only VFS integration did not cover them.

Reviewed updates now opt their auxiliary writable/read-only connections into
the held prepared-index folder and select `temp_store=FILE`. Snapshot creation,
opening, import deltas, publisher-recovery scratch catalogues and cache-building
snapshots accept the same connection-local directory. The new optional DAO and
snapshot arguments default to the preceding behavior for existing callers.
Process TEMP/TMP, the default VFS and global SQLite settings do not change.
Named catalogue/journal/WAL/backup paths do not move.

This uses the existing temporary VFS and its no-fallback space checks. The
review's existing progress/cancellation controller still checks the system
8-GiB reserve and the working/target-volume reserves. This is not a quota or a
guarantee against another process consuming space between checks. Existing
live target connections and unrelated subsystems retain their settings.

## Native evidence

On both architectures the existing reviewed-update application matrix passes
with an observer on its actual auxiliary connections. Each run observes 500
connections selecting the held work directory and FILE storage; all 59 observed
review directories disappear after their owners close.

Three real connection phases per architecture execute a read-only 9,000-row
sort with 2-KiB payloads: the target observer, comparison construction and later
application planning. Cache sizes are temporarily reduced only by the fixture
and restored afterwards. Each sort observes live physical files in the routed
folder (19,527,873 bytes), verifies descending IDs and their full sum, and does
not spill into the process OS-temp folder. The read-only source database hash
stays unchanged. These forced sorts establish routing and cleanup, not a
million-book memory or speed benchmark.

The application matrix retains its twelve business-result groups: full and
append updates, unavailable original roots with only new archives, missing
members, merged sources, source priorities, personal fields, exclusions,
cross-profile baselines, real 7z locators and saved-INPX/Metabib publisher
recovery. The fixture also checks normal rollback and closes its work files.

A separate ordinary review reaches an actual SQLite allocation refusal by
limiting only its comparison database with `max_page_count`. `SQLITE_FULL`
stops it before application; every target/personal row and schema, source ZIP
and INPX hash are preserved, and the failed review's work folder is removed.
This does not fill or disconnect an operating-system volume.

The existing twelve cancellation/error boundaries also pass on each
architecture, including paired catalogue/personal commit witnesses and late
save completion. All six private runtimes are removed.

## Build and binding receipts

All six native runs passed with 76 PASS markers including their bootstrap
checks. Their reports bind the actual fixture binaries and confirm private
runtime cleanup. The two ordinary Main projects also built successfully
without the review test callback. Their PE architectures and linked guide
marker were checked, both original projects stayed unchanged and both owned
IDE temporary folders were removed. Resource versions remain development
`3.0.0.13`, not release-ready beta-14 packages.

| Architecture | Native SHA-256 | Main SHA-256 |
| --- | --- | --- |
| Win64 | b061e3247560cc2b9b03526575752c2f56122f4c0572c11d8dbfd8424e464912 | 46dee1d54ca40483d068378b961b59334c51c298ba8335761b90ddfe46594278 |
| Win32 | 8ee2146181ef6ddc1bbc22feecc3a83a5d7f64a552b8bd93de2652594f2b9451 | 23773c3e73ab104eb5dae23566a96ca5956bf44a07d900bc1a62acf8c7d4138a |

Native modes: library-update-storage (both r1656), library-update-storage-full
(x64 r1656 / x86 r1658), library-update-cancel (both r1658).
Main build receipts: library-review-storage-main64-r1658 and
library-review-storage-main32-r1659.
The aggregate binds all six reports, both Main builds and 696 matching
repository/mirror inputs:
G:/HL-b14-external/library-review-storage-validation-r1655/summary.json.

## Limits and diagnostics

The first Main x64 build (`library-review-storage-main64-r1657`) reached its
180-second bound without a terminal compiler log. It is not a passing build
and does not identify a source/compiler error. That owned process ended before
the fresh visible retry. The retry exposed the Community Edition reminder;
normal acknowledgement allowed compilation to proceed. License checks were
not changed. A transient capture failure did not justify restarting a live
build; the same handle was observed until its authoritative result.

All fixtures and outputs are on G:, E: is unused and C: remained above the
8-GiB reserve. User catalogues/archives, Desktop and publication are unchanged.
Final release resources/packages, large reviewed-update measurements, actual
volume exhaustion/loss and remaining workspace-selection/retention controls
are separate work.

In particular, Settings.GetUpdatePath still falls back to WorkPath when an
explicit UpdateDir is unavailable, and the ordinary source-preparation worker
uses that property. A strict unavailable-workspace error needs a separate
change and test; this batch does not remove that fallback.

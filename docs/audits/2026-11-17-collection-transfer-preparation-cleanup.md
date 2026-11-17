# Cleanup of an interrupted transfer constructor

A safe stop while building the first transfer journal could leave its metadata
folder behind before the caller received a usable journal or registered it for
continuation. The journal now removes that newly owned draft when its constructor
raises. This closes the normal cancellation/error path before registration;
completed constructors and resumed journals remain durable.

The constructor records physical directory/file IDs as it creates its directory,
empty copies directory, lease, review database and state database. It marks
construction complete only after the review has been sealed and reopened. Its
destructor first closes databases and releases its normal leases, then reopens
the exact newly created objects with deletion access and compares their IDs.

Cleanup validates the entire entry list before deleting anything: every file
must have its recorded ID and a single hardlink, directories must not be reparse
points, the copies directory must be empty, and no unknown file/directory may be
present. A replaced, linked or busy object preserves the whole draft for
inspection. Deletion uses held handles rather than looking up a path again after
checking it. An object appearing concurrently cannot cause recursive deletion;
a nonempty directory refuses unlinking. Cleanup errors do not replace the
original preparation error.

No payload copying, registration or catalogue publication is possible before
this constructor returns. A successful new journal, including a deliberately
unregistered native review, is retained. A resumed journal is never eligible for
this draft cleanup, including when validation of that journal fails.

## Native checks

The new tests use private G: ZIP/catalogue fixtures and assert unchanged source
archives, catalogues and personal data after every invocation. They exercise:

- Cancellation before review construction, after the complete frozen review,
  and immediately before the constructor becomes ready. Each removes its own
  draft and leaves no destination payload.
- An unknown root file, an unknown file in copies, a replacement review file,
  an extra hardlink and an open file which denies deletion. Every entry and
  foreign content remains; cleanup never starts deleting other known files
  before rejecting that directory.
- The ordinary successful frozen review, plus prepare/resume without recopying,
  proving that valid durable journals are retained.

Licensed IDE binaries:

- Win64 r1092: `433cd39921d5d3a22c14dc2aabb6ccc610948910636134764f632a2817afa925`.
- Win32 r1095: `abbbd18fee654bd98f2029811471bbab518c2c6fbd36d30cee449d139e0113e2`.

Reports and matched source/resource/test inputs are retained in
`G:/HL-b14-external/transfer-preparation-cleanup-Win64-r1093` and
`G:/HL-b14-external/transfer-preparation-cleanup-Win32-r1096`. The first Win32
build r1094 failed to write an intermediate DCU; a new build succeeded without
changing code or licensing/settings.

Both architectures pass four methods with eleven native invocations each,
including eight expected cancellations/refusals. There are no errors, skips or
remaining private runtimes. Win64 takes 44.516 s; Win32 takes 48.234 s. All 642
recorded source/resource/test inputs match both the repository and isolated build
tree. Consolidated evidence is in
`G:/HL-b14-external/transfer-preparation-cleanup-validation-r1097/summary.json`.

## Boundaries

This is live constructor-error cleanup with ownership kept in memory. It does
not enumerate and delete abandoned folders after a hard process exit. It does
not reclaim large completed cache snapshots, remove historical completion
receipts, clean another operation's working root or measure volume-space peaks.
Those remain separate release tasks. The new checks do not claim 7z coverage;
their fixtures use ZIP and do not call the optional 7z test helper. No user
library or Desktop installation was changed; E: was not used.


The later draft-claim extension is audited in
`2026-11-17-collection-transfer-draft-recovery.md`: simple owned drafts can now
be reclaimed on the next same-root preparation after a hard exit. It preserves
ready/legacy/unknown journals and does not close the nested-fork snapshot or
unproven-remnant boundaries above.

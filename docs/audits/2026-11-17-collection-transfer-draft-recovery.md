# Abandoned transfer-preparation drafts

The previous constructor cleanup kept its ownership list only in memory. A
hard process exit could therefore leave an unregistered, never-usable review
behind. New preparations now write a bounded, checksummed ownership record to
their existing exclusive `lease` file before populating the review. It binds the
canonical directory, physical directory/copies IDs and the three file IDs.

Before returning a usable non-preview journal, the constructor appends and
flushes a ready tail. The cleanup reader requires the exact unextended claim
length: a complete ready tail, a torn tail or any other append prevents cleanup.
Old empty leases are also retained. Preview journals stay disposable because
they cannot copy/publish payloads, while live directory/file guards prevent
another instance from cleaning an active preview/preparation.

## Cleanup and transaction boundary

Before a new journal is created in the same chosen work root, abandoned drafts
are examined. Cleanup does not open possibly incomplete SQLite databases. It
accepts only the canonical GUID child, its expected physical IDs, an empty
copies directory, and exactly the known files. Every entry is validated before
unlinking anything, using held deletion handles. Reparse points, hardlinks,
extra streams, busy/replaced files, corrupt claims and unknown entries preserve
the complete draft. No recursive delete or user catalogue/payload write occurs.
Cancellation happens between draft directories or before a validated set is
unlinked.

Only the new, disposable review/state databases use MEMORY rollback journals
during construction. This avoids unclaimed named rollback files on a killed
draft, while retaining live transaction rollback. SQLite documents that
[MEMORY journaling can leave a database corrupt after a crash](https://www.sqlite.org/pragma.html#pragma_journal_mode).
Such a draft is discarded, never resumed. DELETE mode with FULL synchronous
writes is restored before the review is sealed and the ready protection is
flushed. User databases, successful/resumed journals and publication/cache
transactions retain their existing durable behavior.

## Verification

Native checks cover four hard exits before/during/after review creation, a
preview exit and cleanup on the next ordinary preparation, ready/legacy lease
retention, cancellation, foreign files/copy entries, replacements, links,
streams, busy readers and damaged claims. A separate 20,003-book fixture exits
inside the uncommitted review transaction after actual file pages have been
written, then reclaims that draft without opening/reusing its SQLite state.
Existing safe constructor cancellation, real read-only temporary sorting,
whole-operation completion/replay and interrupted completion are checked too.
`G:/HL-b14-external/transfer-draft-validation-r1264/summary.json` records
660 matching source/resource/test inputs and both final runs r1261/r1262.
Each architecture passes ten methods and 55 native calls: 110 calls total,
38 intentional process exits and eight expected safety/cancellation refusals,
without skips or remaining private runtimes. The uncommitted review files are
3,469,312 / 3,428,352 bytes and are reclaimed. The three real read-only sort
spills, whole completion/replay and interruption before the completion commit
also pass on each architecture. Runtime is 327.703 / 328.703 s under concurrent
testing, not a performance comparison. Final driver builds are x64 r1256
`7a25b402a75e1a6f1cbb28632412157d40b15378ce30a9b882b0be886d3ebfd9`
and x86 r1258
`5046432762115e6e0aecb2af4d951427f8983c6cd60a4bf9cda6dfc27d40db09`.

Earlier diagnostics r1248/r1251 exposed literal dotted filenames being treated
as JSON paths; lookup now uses literal JSON pairs. The corrected smoke r1253
passes all four initial crash points. In r1257 the application-side dirty-file
case exited at the intended point, but an incorrect 4 MiB test threshold rejected
its 2,940,928-byte file before cleanup; the test now requires a real SQLite file
of at least 1 MiB and checks its header. Failed reports/runtimes-cleaned evidence
are retained rather than counted as passing final validation.

## Remaining boundaries

Cleanup runs when the same work root is next prepared, not by searching every
user volume at startup. A process loss before a complete ownership claim is
flushed, or during final deletion after the claim itself has gone, can leave
small unproven remnants. Damaged/incomplete claims are retained conservatively.
Drafts with nested `catalogue-snapshots` are also retained: independent ownership
of those fork snapshots and their SQLite side files remains a separate task.
The rule preserves usable journals and unknown content; it does not establish
complete cleanup of every interrupted cache/fork snapshot. Volume failures,
non-NTFS/mounted filesystem behavior, current million-scale memory cost and
final ordinary-app/release verification remain separate gates. E: and user
libraries/Desktop binaries are untouched; all fixtures are private on G:.


Current production Main also compiles on both architectures (x64 r1265 /
x86 r1266), with PE machine/hash evidence recorded in r1264. Earlier r1263
was stopped by the build helper's system-volume reserve guard; after free space
returned above 8 GiB the same sources built successfully. These are development
executables, not the final beta14 packages or an ordinary UI validation of the
new cleanup path. Desktop/user data remain unchanged.

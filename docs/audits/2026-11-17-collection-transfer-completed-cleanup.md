# Completed transfer working-cache cleanup

The ordinary transfer previously kept its cache-snapshot working directories
after the independently confirmed move. Completion now releases its own remaining
publication guards and cleans these directories before showing the final report.
Cleanup failure or cancellation leaves the move completed and reports deferred
housekeeping. Logical bytes removed are labelled as working data, not a measured
increase in filesystem free space.

## Deletion authority and retry

The immutable review hash, independent completed receipt, prepared cache intent
and per-object claims in the personal database must agree. The entire directory
claim set is checked before deleting any object: job IDs, allowed filenames,
direct journal parent, GUID directory name and recorded physical IDs. Each
directory then holds deletion handles for every current entry before the first
unlink. Replacement IDs, reparse points, hardlinks, busy files, unknown entries
and extra data streams retain that directory. Directories themselves are checked
for additional data streams as well. A concurrent new entry cannot trigger
recursive removal; removing a nonempty directory fails.

Only independently claimed `cache-snapshot-*` directories inside this journal
are eligible. Source caches, original indexes, installed persistent versions,
books, review/state and the historical completion receipt are retained. No
source-setting publication, payload copying or transfer continuation occurs.

After a cancellation or process exit, already removed entries may be missing.
The same claims authorize retry of the remaining owned entries. A separate short
personal transaction records the cleanup attempt/done state. It checks the
completed operation/review/personal identity again, never changes the transfer
back to pending and never rewrites the completion summary. Successful replay
keeps an existing done marker unchanged. SQLite writer locks are not held during
filesystem cleanup.

The cleanup-only reader holds the journal lease and verifies the frozen review
and receipt without opening mutable state, probing the destination or applying
transfer-allocation reserves. This allows freeing working data after the
destination goes offline or free space falls below the transfer reserve. The
reader cannot register/publish a transfer; review hashing remains cancellable.

Ordinary Main schedules one low-priority worker after 30 seconds and an idle
check. Hashing and filesystem enumeration stay off the startup/UI thread. It can
run even when no collection is selected. The worker owns no GUI references and
is cancelled/joined before Main teardown. The completed-operation queue is bounded
to 1024 entries; retained failures get attempt timestamps so other operations
are not permanently displaced from the queue. A completed move is never resumed
automatically by this cleanup.

The held-handle stream layout and directory-empty-stream result were checked
against [FILE_STREAM_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_stream_info)
and [FindFirstStreamW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-findfirststreamw).
A private NTFS probe confirmed error 38 for a directory with no data streams and
a returned named stream after adding one; observations are retained on G:.

## Verification scope

Native fixtures use real cache databases and retained source indexes, complete
the actual registered move, then invoke cleanup in separate processes. They
compare published cache bytes, source cache/index bytes, book hashes, personal
metadata and the unchanged historical receipt. They cover:

- Completed snapshots and logical-byte totals; idempotent cleanup and completion
  replay without database rewrites.
- Pending-operation refusal and a forged directory claim rejected before any
  snapshot deletion.
- Foreign entries, replacement identities, external readers, hardlinks and
  additional file/directory data streams, followed by successful retry after
  removing only the test obstacle.
- Cancellation after the first unlink, another process exit on retry, and
  recovery of the remaining files without new book copies.
- Process exit after filesystem cleanup but before the marker; background-worker
  retry accepts missing working directories and records completion.
- A disconnected destination and cancellation while opening the cleanup reader.

Ordinary Main checks use the real Sources command and the dark 225% layout.
They check the completion report, manually accelerate the delayed background
timer, wait for its worker to finish without a modal window, refresh the Main
book list and open five actual Reader books to verify saved positions, bookmark
navigation/context and notes. These are small local fixtures; they do not prove
the large-library performance/space or final production-release gates.

The combined record is
`G:/HL-b14-external/transfer-cleanup-validation-r1149/summary.json`:

- Final Win64 native r1140: 11 methods, 44 calls, two forced exits and three
  expected refusals, PASS in 566.750 s. Binary r1139:
  `b9d7c5e976a3a11003a06d6375d5872b499197df965cad60452599bf9594b9ac`.
- Earlier Win32 native r1135: 11 methods, 43 calls, two forced exits and three
  expected refusals, PASS in 562.891 s. Binary r1133:
  `acb35ef44e908c64292429d616d032f635761ceb60a123548fad2189c93132dc`.
  This predates the added directory-stream check and is supporting evidence.
- Final Win32 native r1147: four focused methods, 21 calls, two forced exits,
  PASS in 223.469 s. It covers the added directory-stream case, ordinary
  successful/repeated cleanup, cancellation/crash recovery and the background
  worker. Binary r1144:
  `f4e2abab81e67b58a05b17886ee2090abe36e8688c5484145429e429fba3bfab`.
- Final ordinary Main Win64 r1145: PASS in 90.297 s, binary r1141
  `ad70f72cb3ab41aec5baf3c26d75e0dd7ceb0e0c47501773665a24d4841d2f11`.
- Final ordinary Main Win32 stop/retry r1148: PASS in 78.813 s, binary r1142
  `f7f80a402fd398835119b7143dc11c293e55375226cfaab47899a851cdb909e1`.

No errors/skips or private fixture runtimes remain in these passing reports.
All 646 final source/resource/test inputs match the isolated build tree and both
final native input manifests. Main was built from those same unchanged inputs.
The dark 225% scenarios are automated window checks here; no additional visual
inspection is claimed for this change. The existing screenshot/layout evidence
is recorded in the preceding UI/space audits.

Earlier failed r1130 is retained: its native-only
path guard rejected the extended Windows path emitted by directory enumeration.
The fixture now normalizes that prefix before checking its private root. The
busy-reader fixture permits other readers while withholding delete sharing, so
its independent hash check can run while cleanup is correctly refused. Initial
compile r1127 rejected capturing a local Pascal procedure; the callback is now
an owned anonymous-procedure value. None of these failed runs is a passing gate.
An r1143 command also stopped before launching Main because the test parent
directory did not exist; r1145 creates that directory explicitly and passes.

## Remaining requirements

Unregistered hard-exit drafts still need a separate durable discovery/ownership
design. Unknown SQLite side files in abandoned incomplete snapshots are retained,
not guessed to be ours. Large-cache peak measurements, real space failures,
additional volume/filesystem combinations, remaining post-transfer formats and
production/offline/update release checks remain open. E: and user collections
were not used; the Desktop copy and public release were not changed.

Later extensions are recorded separately: unreturned draft ownership and
nested constructor cleanup in `2026-11-17-collection-transfer-draft-recovery.md`
and `2026-11-17-collection-transfer-nested-drafts.md`; completed shared-catalogue
snapshots in `2026-11-17-collection-transfer-fork-cleanup.md`. The remaining-scope
paragraph above describes the earlier cache-only validation, not those later
extensions.

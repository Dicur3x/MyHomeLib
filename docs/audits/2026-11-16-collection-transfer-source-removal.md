# Receipt-bound original-file removal after transfer

## Scope and ordering

The transfer registry now has an explicit original-removal stage for a fully
prepared and published dependency group. This is a backend checkpoint tested
only in positively owned private fixtures. It does not expose the ordinary
Sources command, change final collection roots or mark an operation complete.
No user collection, Desktop application or public package was changed.

Removal requires the independently registered group proof, the exact frozen
source/target mapping, held verified destination streams, native external-image
mapping, and existing matching locator receipts in every affected database.
The proof file itself remains open without write/delete sharing through cleanup.
Neither a prepared-file receipt nor a mutable child journal authorizes removal.

The publication session acquires writer transactions on the personal store and
every ready effective catalogue. It captures current references and checks
actual locations/receipts. On that same locked connection it records
`HomeLibreTransferRemovalIntent`, binding operation, group and file IDs, group
proof digest, original file identity, target identity, exact paths and complete
stream hashes. Pre-protection source attributes are recorded once.

This intent commits before any source attribute change or unlink. Catalogue
writer transactions remain held while the personal transaction is reacquired;
references, registration, proof and locations are checked again. The entire
group is protected and verified before its first source is unlinked. Current
registration/proof checks also run at each handle-specific unlink boundary.
Per-file results commit together afterwards; an interrupted result transaction
can be reconstructed from the durable intent and surviving verified targets.

## Original guards and retained files

Each eligible source is reopened with read/delete access and no write/delete
sharing. Its parent is pinned; identity, canonical path, single-link regular-file
status and original timestamp/size must match the frozen review. Existing live
prepared-source leases are handed off to this guard without releasing targets.
An absent source is acknowledged; a replacement is retained.

The guard temporarily adds READONLY, preventing ordinary creation of a new NTFS
data stream while the existing stream set is enumerated, opened without write
sharing and fully hashed. All names, sizes and hashes must match the verified
destination. The guard checks protection, identity, streams and held targets
again before requesting deletion of the exact held file, never a later pathname
replacement. Only its owned READONLY guard is ignored for this handle-specific
deletion. Normal cancellation/failure restores the prior readonly bit. Recovery
uses the independently recorded original attributes rather than overwriting them
with a temporary protection bit left by an earlier killed process.

Files already kept in place never enter the deletion primitive. Unavailable or
unsafe references retain originals. A retained/changed archive owner transitively
retains its original picture dependencies; retaining one sidecar does not require
retaining unrelated owners. Mismatched/busy originals retain a reason. A reader
sharing DELETE can defer physical disappearance; this is recorded as pending,
then reconciled when the external reader closes. Foreign files created at an old
name after a completed removal stay untouched on replay.

The API distinguishes removed, already missing, retained and pending files. None
of these counters alone marks the whole transfer complete or supplies final
space accounting.

Windows API behavior is documented in Microsoft's
[handle information API](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle),
[stream sharing description](https://learn.microsoft.com/en-us/windows/win32/fileio/file-streams)
and [extended disposition flags](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-_file_disposition_information_ex).
Native tests below cover the installed Windows/NTFS behavior; they do not prove
other filesystems or Windows versions.

## Native evidence

Licensed IDE builds passed with staged/worktree source equality and removed IDE
temporary folders:

- Win64 r870: `98ced725ff088952ca6aa6df5a0e4ab4fd9fa22d7b756bd23f4d5d2bc5092633`.
- Win32 r872: `c9898114164285133cb9714355a9828dfb86dc56b066cfa6fcd91845a9b7ab89`.

Both architectures passed the initial 14-method matrix: Win64 r873 in 454.876 s
and Win32 r874 in 459.896 s, each with 43 native invocations and seven expected
forced process exits. Runs are under `G:/HL-b14-external/transfer-removal-*`.
Four additional boundary methods passed on each architecture in r875/r876:
an original already inside the destination, a newly added source stream with a
restored original timestamp, cancellation after one unlink, and two consecutive
crashes with an already protected source.

The final r875/r876 runs each passed seven methods in 258.224 / 258.432 s:
four removal boundary cases plus two existing receipt/lock checks and the
26-group normal publication regression. The latter still needs one reference
capture. Each final run has 15 native invocations and two expected forced exits.
Across both architectures this is 21 distinct methods per architecture, 116
native invocations, 18 expected forced exits, and no failures/errors/skips or
unexpected return codes. Every owned runtime was removed. Each run's
`summary.json` records that check and the exact native input hashes. These
diagnostic durations include setup/restarts and are not transfer throughput.

The 18 removal methods cover live publication and target-only recovery, exact
destination hashes, neighbor preservation, readonly files and named streams,
absent/replaced sources, unavailable references, owner-to-sidecar retention,
missing location receipts, changed intent binding, all database writer locks,
normal cancellation and crashes around protection, unlink and both commits.
They assert replay without recopying and preservation of reused foreign names.

Earlier failures remain recorded: r866 exposed Delphi's restriction on capturing
local named routines; r868/r869 retained originals after Windows rejected an
unaligned packed basic-information structure with error 998. The structure now
has native alignment. r871's external-reader observer tried opening an already
delete-pending original; the native operation had correctly reported pending.
The observer now releases its owned reader after recording the native result,
then verifies target hashes and disappearance. These earlier runs are not
reported as passing tests.

## Remaining integration and limits

The ordinary operation/controller, startup reconciliation and cancellation UI
still need to call these stages, release/reopen live DAO/readers and coordinate
other jobs. A killed protected source requires recovery; this stage does not
itself install a startup repair hook. Final roots, missing/future book locations,
update profiles, Reader cache, cross-volume/filesystem cases, space accounting,
owned snapshot cleanup, Sources UI and end-to-end post-transfer updates remain.

Cleanup currently captures fresh references twice per group. Correctness checks
passing on small fixtures are not evidence of acceptable large-library cleanup
throughput. The existing normal publication reference cache is a separate
regression boundary. Final production builds and release gates remain open.

Exact native build inputs, equal to staged bytes for both architectures:

- `unit_CollectionTransferCopy.pas`: `dcefe8f5f01b7e33d150f11919f0b55ac7d1942b882b101b85c32426c0791fc7`.
- `unit_CollectionTransferJournal.pas`: `092e93c9bcd126db3153a1a330724e67ca25f0b76417120af1a7b820db0a58c0`.
- `unit_CollectionTransferPublication.pas`: `bfc9658dc1ea2d7fb3d08aa5efa60ff22225ada0ba4ce1626ed1f02a7b4bc1a2`.
- `unit_CollectionTransferReferenceFence.pas`: `5cdb7c5bf6d7c2999abea53aaf75110c0a7399c80aae6eff444332aeae57d6f7`.
- `unit_CollectionTransferRegistry.pas`: `bb3199f050ba5aa6869a571264aa261edaaabe0abf18f0bebad12ce492312685`.
- `CollectionTransferJournalTest.dpr`: `4e142361d30df719479507f345e82519563ef6f0fd95c50988aa1158a1264cba`.

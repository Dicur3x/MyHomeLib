# Verified physical-file preparation and recovery

## Scope

`unit_CollectionTransferCopy` implements preparation of **one physical file**
for the planned source-consolidation operation. It does not enumerate books,
change a catalogue, delete an original or expose a transfer command. The future
parent operation must retain these prepared-file references until an entire
connected archive/sidecar group has been published to every affected catalogue.

The code copies whole file bytes without recompression. It hashes the source
with bounded buffers under read leases, uses CopyFileEx for the physical copy,
flushes the owned output and separately hashes the output under read leases.
Every enumerated NTFS data stream is included, rather than just the unnamed
book/archive stream. Output stream names, sizes and SHA-256 values must match.
Native readers can open a prepared output; ordinary writers and replacement are
denied while the returned leases are retained. Directory guards reject path
redirection. Existing or racing destination files are preserved.

## Durable file journal

Each active file has an immutable manifest, exclusive writer lease and
append-only flushed state records. Records carry a sequence, binding and payload
SHA-256. Resume requires the reviewed source/destination/identity supplied
independently by the caller; JSON paths alone do not authorize touching files.
The latest completed record must be valid; a damaged record is not silently
replaced by older state. Unknown uncommitted metadata is left untouched.

A fresh adjacent temporary is reserved with CREATE_NEW. Its file ID is recorded
before copying and checked throughout copying, verification and publication.
The verified file is published by handle without replacement. A crash after
rename but before the final journal entry can recover only the same reserved
file ID with matching complete stream checksums. Verified/ready copies resume
without recopying their payload. Read-only state is restored, including after
an interrupted publication.

A crash immediately after creating a temporary but before recording its ID can
leave an empty file whose ownership is not sufficiently proven. Resume retains
it and chooses a new attempt. Cancellation paths where CopyFileEx has already
removed the incomplete temporary can also reserve a fresh attempt, after
rechecking the source. No original is removed by either path.

## Native evidence

Licensed IDE builds preserve the checked-in project and use owned storage on G:.
Final passing evidence under `G:/HL-b14-external/`:

| Run | Tests | Failures/errors/skips | Native attempts / forced exits | Binary SHA-256 |
| --- | ---: | --- | --- | --- |
| `transfer-copy-Win64-r730` | 25 | 0/0/0 | 60 / 17 | `af852b03727df46a8d294b3dff900c98981389dc44318fdce7226d19f1160922` |
| `transfer-copy-Win32-r732` | 25 | 0/0/0 | 60 / 17 | `8bbf166cc46bb1c17bbf6521384629094536c2ceecc7ce6748635afa5a970673` |

The final binary builds are r729/r731. No code changed between those builds and
their test runs. Worktree and G: staged bytes were compared:

- Copy unit: `72fc21ea94ea0fd5f198bd871e8db67bd205b6ff453c46caf76004b2f01ff623`.
- Planner with two shared metadata wrappers:
  `16ca29f6cc452c8ef5943e89d68c76df5ac3d0f28d88f8ec2d0ab29e1c97f285`.
- Diagnostic DPR: `582f9fd1fdbfff57ac6204f1030b3f727f8f186ef7cbff64223c84006680efc5`.

The 25 cases per architecture cover ordinary copies; additional NTFS streams;
modification time and read-only preservation; empty files; keep-in-place;
different files with equal names; long Russian source/destination paths over
300 characters; existing/racing destinations; foreign partial replacements and
temporary files; journal corruption/binding mismatch; concurrent writers;
source/output/default-stream and named-stream changes; cancellation; nine crash
boundaries; and a second crash while recovering a published output.

One case performs an actual E: to G: copy, checks different volume serials,
compares all bytes and an additional stream, resumes and removes its private
E: source fixture. A test-only source marker and canonical root guard permit
only that root-level private fixture, never a C: or user-library source. All
ordinary fixture paths remain restricted to the owned G: runtime.

All final private runtimes were observed removed; the cross-volume source was
also removed. Invocation requests, journal states and outputs are preserved in
each run's `invocations.jsonl`. These small opaque ZIP fixtures prove filesystem
behaviour, not full-library throughput, real-book rendering or catalogue moves.

## Failures retained and corrected

- Initial r714-r716 builds exposed API/name and callback-signature errors; those
  builds are not passes.
- r719 failed with access denied because a CopyFileEx callback handle can be
  write-only. File-ID checks now use the separately retained metadata handle.
- r722 failed cancellation recovery when the incomplete output no longer
  existed. Recovery now creates a fresh reserved attempt from the checksum-matched
  source. Two other failures were fixture setup/path-length assertions, corrected
  without weakening ownership guards.
- r726 passed 24 cases; the copy for the final long-path case reached `ready`,
  but the diagnostic's subsequent TFileStream read omitted the extended path
  prefix. The reader/writer probes now use the existing native-path helper.
  The full final runs above include that correction.

## Remaining before physical consolidation is enabled

The catalogue adapter, bounded parent ledger and connected dependency-group
publication remain open. So do all-catalogue/personal locator transactions,
compression-history and update-profile rebind, native reading, reference-checked
source cleanup, startup conflict blocking/recovery and the ordinary UI.

The current file-level resume still requires the original. The parent receipt
must support recovery after a proven source removal. It must also revalidate
original stream sets and hashes immediately before any removal, including a new
stream arriving after the initial snapshot; retained stream leases alone are
not that final proof. No source-deletion guarantee is inferred from these tests.

Main/Reader beta 14 production binaries, Desktop replacement and release
publication are not completed by this diagnostic. Existing compression package
candidates are unchanged (`packages-r691`).

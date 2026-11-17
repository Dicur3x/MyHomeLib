# Transfer locator receipt memory

The old locator transaction retained every binding row as JSON objects, then
materialized the entire array as UTF-16 and UTF-8 to hash it. A million bindings
therefore required much more memory than their stored catalogue representation.

`TTransferBindingDigest` now hashes the same JSON array incrementally. Each
completed row is serialized once, fed through a 64 KiB buffer and freed. Array
brackets, separators, row order, escaping and optional reader-history suffixes
are unchanged. No receipt schema, writer lock, reference scan, payload check or
permission to remove originals changes. The missing-personal-row prefix is fed
too. The caller owns the current row and frees it on failure as well as success.

This bounds the JSON hashing portion to one row plus its serialization and the
64 KiB buffer. It does not make the whole transfer constant-memory: the `Seen`
dictionary, SQLite caches and other operation metadata still consume memory.

## Compatibility evidence

The native digest probe compares against the actual old Delphi expression,
`THashSHA2.GetHashString(TJSONArray.ToJSON)`, and for small values also against
Python SHA-256 of the returned exact UTF-8. It covers empty arrays, Unicode,
supplementary characters, escaping/control characters, numbers, null/boolean
values, many buffer flushes, an individual row larger than the buffer, repeated
finalization and refusal to append after finalization.

Saved pre-change binaries create genuine locator receipts. The new binaries
resume them with unchanged receipt rows and no recopying, including empty LIBID
reader aliases and a removed personal card with a scoped library identity.
Unlink interruption/recovery, shared-catalogue forks, personal cards added after
review and immutable completed-receipt replay are checked as well.

Win64 r1179 and Win32 r1180 each pass nine methods/20 native calls, one deliberate
process exit and two expected refusals, without skips or remaining private
runtimes. Their 650 source/resource/test inputs match the build tree. Builds are
r1172/r1176; their binary hashes and complete call evidence are in the run logs.

An initial test r1175 assumed that deleting an unscoped numeric personal card
after publication could be resumed by the old writer. The old -> old probe
r1178 disproved that assumption: the old receipt has a reader-alias suffix,
whereas its missing-card path hashes only the prefix. Both versions refuse with
the same receipt mismatch, keep receipts/data and do not recreate the card.
This pre-existing recovery limitation is recorded separately; successful
reconciliation of that case is not claimed. The failed report is retained.

## Million-row evidence

The benchmark uses 1,000,003 synthetic book rows and two tiny private ZIP
carriers on G:. It exercises the real operation and source-removal path, not
large-archive throughput or every real-library combination. It compares eight
primary fields of every book and independently hashes both destination carriers.

The benchmark now samples Windows process memory and reads the operating
system's peak process commit from a private Job object. Its explicit 2 GiB
process-commit limit applies only to the tested native process. This is a test
budget, not an assertion that an unrestricted 64-bit machine cannot finish.

The pre-change Win64 binary r1170 failed with `EOutOfMemory` after 464.516 s
under that budget. Peak process commit was 1,948,307,456 bytes. All checked book
rows and both original carrier hashes remained unchanged; no source-removal
intent existed. Its private runtime was removed. The failed result is retained.

Both streaming binaries from `bc20c159` passed:

| Run | Native seconds | OS peak process commit | Sampled additional file allocation |
| --- | ---: | ---: | ---: |
| Win64 r1177 | 1,005.359 | 291,057,664 bytes | 3,645,558,104 bytes |
| Win32 r1181 | 1,014.579 | 172,101,632 bytes | 3,645,820,248 bytes |

The Win64 observed commit peak is about 6.69 times lower than the old failed
run's peak. This compares a completed bounded run against a failed bounded run,
not two unrestricted runs. Timing is not a speedup comparison: the old run did
not finish, and the two new runs partly overlapped. Resident working-set peaks
were 811,229,184/224,702,464 bytes; Win64 also maps database pages, so commit and
working set must not be presented as the same memory metric.

Both runs perform five fresh reference captures, use five held approval
attachments with no approval copies, publish locators, copy both carriers and
remove their originals. All eight selected primary fields of every book match:
`25ea4f2d6c272ba1d56c0f097aa9ca59a82fb794f487ed9c36c700153168e2c1`.
The benchmark asserts the destination hashes against both original carrier
hashes before reaping each private runtime; both runtimes were removed.

`G:/HL-b14-external/transfer-binding-validation-r1182/summary.json` consolidates
the 650-input focused checks and both million-row results, retaining the old
failure separately. File-allocation peaks are sampled about every 0.5 seconds,
excluding directory/MFT overhead and possibly short-lived allocations. They are
observations, not exact volume peaks or a hard reservation guarantee.

These million-row runs deliberately omit cache preparation/publication, final
root changes and whole-operation completion acknowledgement. Their native
`roots_applied` field is false. They prove the group publication/source-removal
scale point, not the entire final application workflow. Later locator-format
changes are outside this historical pair and require their own evidence.

## Scope remaining

This change does not reduce the repeated complete live-reference captures.
Temporary SQLite routing in ordinary applications, allocation failures,
additional volume/filesystem combinations, remaining post-transfer format/update
compositions and final production/release gates remain open. The Desktop build,
user catalogues/archives and public releases have not been changed. E: is unused;
C: retains the 8 GiB reserve while test data, outputs and temp files stay on G:.

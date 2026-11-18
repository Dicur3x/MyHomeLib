# Reviewed INPX update: catalogue-scale gate and key lookup

## Data and purpose

The native fixture imports a generated full INPX, then reviews and applies a
second full index with one corrected title and one new readable book. It then
reviews the same published index again and requires zero new/changed records.
All input is generated under an isolated G: profile. There are only three
small actual FB2 payloads in two ZIPs; the other old records refer to a missing
historical archive. This measures catalogue/metadata scale, not terabyte
archive throughput, a million real files or a merged million-card catalogue.

The initial 10,000-row pilot passed, but the million-row run exposed a real
production problem. Seed import took 133.016 seconds and review took 361.625
seconds. The run was deliberately terminated after 1,560.031 seconds overall,
before the application confirmation. It did not complete application and must
not be counted as a successful scale or cancellation/recovery test.

## Reproduced problem

The prepared comparison had 1,000,001 ReviewRows, 1,000,000 ApplyLive rows and
1,000,001 completed ApplyActions. ApplyPersonal did not yet exist. The next
production statement counts old cards omitted from the incoming full index:

```sql
SELECT count(*) FROM ApplyLive l
JOIN personalSource.Books b ON b.BookID=l.BookID
WHERE coalesce(b.IsLocal,0)=0
AND NOT EXISTS(SELECT 1 FROM ReviewRows r WHERE r.Key=l.Key)
```

The actual runtime's SQLite **3.54.1** reported a correlated subquery with
`SCAN r`; ReviewRows had only its Location index. The initial host-SQLite
inspection was independently confirmed by loading the exact runtime DLL and
requesting its read-only EXPLAIN plan. This is not just a host planner guess.

The input INPX/ZIP hashes and main catalogue file bytes remained unchanged.
Only the exact owned test executable was terminated after checking its path
and isolation marker. Its wrapper removed the private runtime. The old report
is intentionally FAIL; stop-reason-r1680.json explains the controlled stop.
This checkpoint does not assert a logical WAL snapshot from a main-file hash.

Evidence:

- library-update-scale-Win64-r1671-million/report.json
- library-update-scale-Win64-r1671-million/scale-query-plan-r1679.json
- library-update-scale-Win64-r1671-million/stop-reason-r1680.json

## Production change

Analyze creates a nonunique `ReviewRowsKey` index before streaming records.
The absence test can search by key instead of scanning the incoming table for
every old card. Nonuniqueness deliberately preserves the existing treatment
of duplicate incoming keys. Only the temporary comparison schema changes;
there is no persistent-catalogue migration or relaxed validation.

The native fixture verifies the exact production statement's plan at the
application confirmation, using the actual populated ApplyLive/ReviewRows and
target catalogue. Both final 10,000-row pilots require:
`SEARCH r USING COVERING INDEX ReviewRowsKey (Key=?)` and forbid `SCAN r`.

## Result oracles

- A consistent native SQLite BackupTo snapshot includes committed WAL data.
  An earlier plain main-file copy omitted previously committed memo fields;
  that diagnostic fixture was corrected rather than changing product data.
- A retained read-only observer's data_version and complete personal-table
  contents must remain unchanged throughout each read-only review. The main
  file hash is an additional check, not the WAL content oracle.
- After application, every old BookID/LibID and unrelated book field matches
  the snapshot. Only the intended title/resolved path of card 2 may differ.
  Memos compare complete UTF-8 bytes, retaining NULL versus empty; importing
  the same annotation as TEXT instead of BLOB is not treated as data loss.
- Old author, genre and series relation rows/counts match. Personal rows and
  schema match except this catalogue's expected commit witness. Ratings,
  progress, annotations and notes are also loaded through the real DAO.
- The new book has the expected ID and reads the exact new archive body;
  SQLite quick_check passes. Work folders close and input hashes stay intact.

## Completed final-source checks

| Gate | Win64 | Win32 |
| --- | --- | --- |
| Final 10,000-row pilot | r1682-pilot, PASS | r1683-pilot, PASS |
| Native SHA-256 | 5bdc6b3989907702d124c9b2e97a3d59c1654fb824e04df4ee0413c5e37e7855 | 7a8a74dd1ac77fffc52e29cc8070b83f0fc3568109256a353f9bd1ab9972b64a |
| Ordinary Main build | r1683, PASS | r1684, PASS |
| Main SHA-256 | 3e5accbc7da69fe36d7600ca76af940f69b3d4c8140fa5107bb3fb3d9788315f | 8912bad88037bbbb3ce19631bbc07cd928276693238277f79eb3bb5a5aaf74e0 |
| Existing whole/bound update matrix | r1684, PASS | r1685, PASS |
| Fixed million-row run | r1686, PASS | r1687, PASS |

Each final pilot has six PASS markers including bootstrap, the indexed native
plan, complete application and repeat review. Ordinary Main builds verify the
linked index statement, correct PE architecture, unchanged project and removal
of owned IDE temporary directories. Their resource version remains development
3.0.0.13; these are not final beta-14 packages.

The source binding has 697 matching repository/mirror inputs:
G:/HL-b14-external/library-update-scale-validation-r1667/source-inputs-r1682.json.
checkpoint-r1685.json binds the four passing native runs (40 PASS markers
including bootstrap), the old scan and both ordinary Main receipts.
The two large runs use the same five pinned publisher files. Their sequential
controller is library-scale-fixed-pipeline-r1685; its terminal report is PASS.
Both ordinary million-card runs and both private-runtime cleanups completed.

## Completed Win64 million-row run

The final Win64 run exited successfully with six PASS markers and removed its
private runtime. Every old ID/field/relation and protected personal row passed
the checks above, the new card reads correctly, and repeat review has no new
or changed records. Both original INPX files and both ZIPs retain their hashes.

| Phase | Seconds |
| --- | ---: |
| Native initial import | 145.484 |
| First review | 398.328 |
| Apply, including preparation, cache and backup | 399.359 |
| Independent stored-data checks | 6.968 |
| Repeat read-only review | 388.907 |
| Whole fixture wall time, including setup | 1368.828 |

This is about 13 minutes 18 seconds for the first review plus application on
this host/input. The full fixture's 22 minutes 49 seconds also includes seed
import, independent verification and repeat review. The old run never finished
application, so it does not support a whole-operation before/after speedup
factor. Repeat review is not a second apply.

The two-second sampler observed at most 6,546,589,025 bytes across the whole
runtime, 1,225,256,960 bytes of private process memory and an OS peak working set
of 1,900,351,488 bytes. Runtime bytes include the extra baseline reference and
binaries; they are not physical allocation, a guaranteed peak or a storage
forecast. Observed C: free space stayed at or above 22,984,687,616 bytes.

G:/HL-b14-external/library-update-scale-validation-r1667/summary64-r1690.json
binds the native receipt, all 697 matching source inputs and the shared publisher
manifest. The subsequently completed Win32 run has its own receipt.

## Completed paired gate

Win32 also passed all six native markers: full application, unchanged old
identities/fields/relations/personal data, readable arrival, indexed query plan,
zero-delta repeat review, unchanged publisher files and removed runtime.

| Phase | Win64 seconds | Win32 seconds |
| --- | ---: | ---: |
| Native initial import | 145.484 | 177.875 |
| First review | 398.328 | 452.906 |
| Apply including preparation/cache/backup | 399.359 | 533.859 |
| Stored-data checks | 6.968 | 7.765 |
| Repeat read-only review | 388.907 | 494.407 |
| Whole fixture wall time | 1368.828 | 1695.641 |

First review plus application is about 13 minutes 18 seconds on x64 and
16 minutes 27 seconds on x86 for these inputs/host. Whole fixture time includes
setup/import and repeat review; it is not the first update's duration.

Win32's sampler observed 6,536,830,055 runtime bytes, 473,227,264 private bytes
and an OS peak working set of 590,340,096 bytes. Both observed C: reserves stayed
above 22.93 billion bytes. The earlier caveats about sampled whole-runtime size,
fixture overhead and physical allocation apply to both architectures.

summary-paired-r1695.json binds both receipts, the shared five publisher files,
the PASS pipeline and all 697 inputs. frozen-sources-r1682 preserves those
exact native sources so subsequent UI-only work does not erase the tested
baseline. This gate does not cover a million-card merged catalogue, terabyte
archive I/O, a second apply or a before/after whole-operation speedup ratio.

Earlier guard/fixture failures remain diagnostic reports, with successful
owned-runtime cleanup recorded separately where required. No E: input, real
library modification, Desktop replacement or publication belongs to this gate.

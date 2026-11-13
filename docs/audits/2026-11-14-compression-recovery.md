# Compression restart through the normal catalogue window

This is one beta-14 compression gate, not completion of beta 14. No Desktop
application or public package was replaced by this work.

## Reproduced defects and fixes

The corrected baseline `native-Win64-file-committed-r2` restarted the ordinary
catalogue after its own real compression transaction was terminated. It found
three defects: a zero-of-zero book counter during recovery, an unmeasured zero
saving in the main status, and retained preparation files after successful replay.
Content, catalogue sizes, personal reading progress and original backup checks
passed before the final defect assertion. The earlier r1 had a fixture path
mistake and is not evidence of a product defect.

Recovery now reports file operations without fabricating a book count or a
measured saving. After a job completes, cleanup uses only its exact native
`prepare-{GUID}/payload/prepared-*.bin` reference under the captured work root.
It does not scan for similarly named folders. Cleanup pins the actual directory,
rejects reparse points, validates and exclusively leases its owner marker, and
accepts only the fixed preparation filenames. Unknown files, a changed marker
or a live marker lease leave the workspace intact and explain its location.

The normal operation retains these handles until cleanup or durable handoff.
The transaction itself adopts the verified open candidate into its journal
without copying a second complete archive; this is unchanged.

## Test method

`CollectionViewsTest` uses the real compression menu, controls, packaged producer,
receipt binding, optional original backup and file/catalogue transaction. Only
this fixture project defines `MHL_COMPRESSION_TEST`. Its callback terminates its
own private process with code 73 at a selected existing durable stage. The next
process creates the ordinary main form; production startup discovers and resumes
the journal. The test does not directly invoke recovery on its behalf.

Each case independently checks the resulting shared ZIP, both selected books,
the untouched neighbour, another collection, refreshed visible book sizes,
Reader cache, personal progress of 37%, one exact original backup and completed
job acknowledgement. The wrapper checks archive members and content separately
from the native observer. Each case uses a fresh private runtime.

An earlier live-owner test wrongly used `prepared-archive.bin` as its preservation
sentinel. `TZipMemberDeletion.PrepareReplacement` legitimately renames that file
into the durable journal. The corrected test instead hashes `report.json`, which
successful application does not consume, while another process holds the owner
marker exclusively. It still requires successful application, intact retained
data, a cleanup explanation and independently verified book contents. The failed
original log is retained; it has not been relabelled as a pass.

## GUI evidence

Evidence root:
`G:/HomeLibRu-build-cache/HomeLibre-post13-compression-recovery-20261113`.

| Run | Result and scope |
| --- | --- |
| `native-Win64-file-committed-r3` | Corrected baseline scenario passed after the product fixes; private runtime removed. |
| `current-Win64-r4` | All six durable crash points passed: job-published, file-committed, catalogue-committed, personal-committed, completed-published and file-journal-forgotten. Its later foreign-file check failed a Russian literal assertion because the new include lacked a UTF-8 BOM. It is not a clean full-batch result. |
| `current-Win64-r5` | Foreign-file and foreign-marker cases passed after fixing the include encoding. The subsequent original live-owner sentinel assertion failed, as explained above. |
| `current-Win64-r6` | Corrected live-owner and ordinary-apply cases both passed; private runtimes removed. |
| `current-Win32-r7` | All ten cases passed: six durable crash points, three preservation cases and ordinary apply; every private runtime removed. |

The shared ZIP became 127,560 bytes from 1,288,077 bytes. This is a synthetic
content-preservation check, not a throughput estimate for a real collection.
One x86 restart took 94.579 seconds; it passed within its existing deadline.
No timeout was increased and no unrelated process was stopped.

Exact GUI executables:

- Win64 r5/r6: `01eea5fb493c3bb2327f01351f6a15ab19cb5080822b52707cffe2600574bb1c`.
- Win64 r4: `c00a6abfd76d951c6d6e5be67af64ee2f3c2303ad49bf94cbafe18040a7016fe`;
  product source is identical, before the fixture include's UTF-8 BOM correction.
- Win32 r7: `49fd3510df3853b9154011838bc778d0b85b7fbdf6a1ca234e47f8ffe0fc5e6e`.

The exact BookProcessing packages are unchanged from the alias-termination
milestone (`126d16cf...` Win64 and `da0fdbc8...` Win32); package manifests and all
file identities are verified before use. The reports retain their full hashes.

## Non-instrumented operation regression gate

Fresh native operation fixtures are built from production units without
`MHL_COMPRESSION_TEST`, with separate outputs/DCUs. The x64 fixture build passed
with SHA-256 `fae3b309fc951a6b9ba66aff3917219f08932cded781b1c3af76201a8ffd7672`.
`native-operation-Win64-r8.json` records all 45 operation/whole-collection tests
passing without skips, failures or errors in 176.921 seconds including setup
and cleanup. Its exact packaged private runtime was removed. It covers ordinary
application, selected/whole collections, no-gain inspection, incremental history,
backup, cancellation/process-tree containment, long paths and journal recovery.
`native-operation-Win32-r9.json` records the same 45 tests passing without skips,
failures or errors in 199.703 seconds including setup and cleanup; its private
runtime was removed. Its freshly built operation executable has SHA-256
`2f5541ae6e6e3fcc65d5c1618cb9cf3705cf6d4e50b1a4db153b38bfd7f83f7b`.
Both fixture projects omit the test-only fault symbol. These are native operation
regressions, not final catalogue/Reader distribution builds.

## Remaining scope

- Preparation interrupted before a durable job is published is a separate gate.
  This change cleans the completed job's known preparation; it does not claim
  recovery of every orphan folder or power-loss scenario.
- Finish the remaining accepted incremental/history, independent images/covers,
  INPX sizes, module-install continuation and final-package checks in the Todo.
- Build and validate the final catalogue/Reader and installation/update packages
  before Desktop replacement and publication.

Previously denied cleanup directories listed in the pause checkpoint are not
targets of this work. Completed new fixtures use their normal guarded cleanup.

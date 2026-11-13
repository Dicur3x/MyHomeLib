# Compression working path cleanup after forced termination

An active short working-directory alias no longer relies on the producer's
Python `finally` block for cleanup. This fixes one remaining compression gate;
recovery of a durable file/catalogue transaction through the normal application
window is still a separate gate. Desktop and public packages were not replaced.

## Defect and change

CreateProcess cannot use a deeply nested current directory. The compression
producer therefore creates a temporary directory junction on the same drive,
without copying the book. Previously the junction was removed only by `rmdir`
in a Python `finally` block. A real `TerminateProcess` test reproduced the leak
after a child had entered the alias and read the source sentinel.

The reparse-point handle now requests DELETE access and
FILE_FLAG_DELETE_ON_CLOSE. FILE_FLAG_OPEN_REPARSE_POINT binds deletion to the
junction itself, never its target. Read/write sharing without delete sharing
keeps the active alias from being removed or replaced. The opened identity is
checked before use. If opening the lease fails, only the unchanged empty
directory created by this call is removed. No prefix scan or recursive alias
cleanup was added.

Normal completion and cooperative cancellation close this handle after the
child exits. Windows closes it even if the producer is forcibly terminated;
the native controller's existing owned Job Object also terminates its child
tree. The test waits for the actual child to exit or verifies Windows error 87
for its absent PID; other OpenProcess failures are not accepted as proof.

This does not claim cleanup after power loss or of every incomplete preparation
folder. It verifies the active alias lease, not the small pre-lease directory
creation interval. Existing ownership checks and recovery journals remain in
place; no source archive or user database is recursively cleaned.

## Evidence

Evidence root:
`G:/HomeLibRu-build-cache/HomeLibre-post13-alias-stop-20261113`.

| Run | Result | Scope |
| --- | --- | --- |
| Corrected baseline before the product change | Failed as expected | Hard-terminated producer leaked its alias; source sentinel survived. The first draft of this test had an incorrect ctypes handle declaration and is not defect evidence. |
| `native-Win64-r1` | 7 passed, no skips; 20.672 s | Cooperative and forced termination, native process-tree containment, ordinary packaged compression and long Unicode workspace. |
| `native-Win32-r2` | 41 tests, 1 error, no assertion failures/skips; 233.953 s | 40 cases passed, including both alias tests and native forced stop. One receipt-apply invocation hit its existing 30-second timeout. Its private runtime was independently verified absent after the run. |
| `native-Win32-retry-r3` | Interrupted, not a pass | Three cases logged completion, including the earlier failing history case. Execution observation disappeared during the fourth case; no matching task process remained. The original INCOMPLETE report and an interruption sidecar are retained. |
| `native-Win32-retry-r4` | 1 passed, no skips; 9.641 s | Completed native forced-stop check with the stronger child-termination assertion. Private runtime removed. |
| `native-Win64-final-r5` | 4 passed, no skips; 9.485 s | Stronger direct/native termination checks; FB2/EPUB text, metadata, CSS, fonts, SVG and neighbour preservation; reversible payload/member/comment preservation. Private runtime removed. |
| `native-Win32-history-r6` | 1 passed, no skips; 7.734 s | Earlier timed-out history/receipt scenario repeated without changing its deadline. Private runtime removed. |

The broad x86 run remains a failed run, not a clean full-suite result.
Windows reported 100% total CPU use during it. That observation does not prove
the cause of the timeout. The targeted repeat passed; no product or test
deadline was increased and no foreign process was stopped.

The test-only worker creates a child that reads a sentinel through the alias
before it signals readiness. It then either terminates itself without running
Python cleanup, or ignores cancellation until the real native operation's
three-second forced-stop path terminates it. Assertions retain exact source,
catalogue and personal-store bytes. These synthetic fixtures do not alter
the user's collection.

## Exact local packages

The native operation binaries are unchanged from the incremental-selection
milestone. This fix is in BookProcessing's Python worker. Package extraction
verified the current worker bytes, every packaged file's size/SHA-256, component
identity and the Windows architecture before testing.

| Architecture | BookProcessing package SHA-256 | Bytes |
| --- | --- | --- |
| Win64 | `126d16cf9fec8892489914d4ba78d00f25e3dcf8ed813f013d73b48d364c7acd` | 12,443,804 |
| Win32 | `da0fdbc8d172b16d0a8982c4aeb051fc5f0bd83c74ebd9afe6168d8ca839fbdc` | 11,184,424 |

These archives supersede the earlier local beta-14 BookProcessing candidates
for future package tests; neither has been published.

## Retained interrupted runtime

Automatic approval review rejected recursive removal of exactly:

`G:\HomeLibRu-build-cache\HomeLibre-post13-alias-stop-20261113\HomeLibre-inspection-runtime-qhfmvnar`

The stated reason was only `blocked by policy`. It remains on disk. No alternate
or equivalent deletion was attempted. Before the denied action, the task's
binary hashes, resolved parent, absence of reparse points and absence of live
matching processes had been checked. The last recorded alias itself was absent.
This restriction does not turn the interrupted test into a pass.

## Remaining work

- Exercise restart/recovery through the ordinary catalogue window and final
  packages, including unfinished preparation data rather than just this alias.
- Continue the incremental-compression gates: older history, independent image
  files/covers, effective sizes after INPX and continuation after module install.
- Validate production applications and complete/minimal installation packages
  before publication or Desktop replacement.

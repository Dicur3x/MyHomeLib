# HomeLibre beta 14 historical pause checkpoint

This records the user-requested pause on 13 November. The user resumed on
14 November with the updated full beta-14 objective. Current recovery results
are recorded in `2026-11-14-compression-recovery.md`: GUI recovery and the
non-instrumented operation gates have now passed on x86/x64. Continue with
preparation interrupted before journal publication and the other accepted Todo
items; do not mistake this milestone for a finished release.

At the pause check no task process matching the recovery stage remained. The
latest complete commit then was `66f637c8`; recovery changes described below
were still uncommitted work in progress, not a release candidate.

## Current objective and order

Finish the accepted open HomeLibre beta-14 Todo, using private copies and
preserving original books and personal data. Work sequentially:

1. Finish in-place collection/selected-book compression and incremental new-book
   compression: safe restart and cleanup, old-history migration, independent
   covers/images, sizes after INPX and continuation after component installation.
2. Finish the accepted update-source interface and advice for local/network
   INPX/Metabib updates; retain compatibility with collections.ini and expose
   the existing collection update through an understandable toolbar icon.
3. Finish the other accepted beta-14 reader, covers, interface/help, executable
   naming and full/offline/minimal distribution items recorded in the Todo.
4. Verify real-format/content detection, reading/export, Explorer workflows,
   archive operations and comparable performance on the relevant x86/x64
   candidates. Distinguish missing-device checks from passed Windows checks.
5. Validate final applications, installation/update packages and documentation;
   only then replace the Desktop copy and publish the requested beta.

The existing broader audit is not narrowed to the recovery work below. Assess
new proposals critically rather than automatically accepting them. Kaspersky
and intermittent RAD Studio/GetIt failures must not hold up the release; the
user explicitly deprioritized prolonged investigation of those. Do not claim
physical Kindle/Kobo validation without those devices. Preserve the untouched
user originals and do not interfere with other applications or encoding/VMs.

## Verified recovery evidence

Stage: `G:/HomeLibRu-build-cache/HomeLibre-post13-compression-recovery-20261113`.
Authoritative repository: `C:/Users/cloud/HomeLibRu-audit`, branch
`codex/complete-app-audit`.

The new guarded test uses the real normal catalogue compression action and the
packaged producer. Only its test executable defines `MHL_COMPRESSION_TEST`; the
callback terminates that private process at an existing durable transaction
stage. The next process enters ordinary Main.FormCreate recovery, not a
test-only direct call to Recover. No original user collection was modified.

The corrected baseline `native-Win64-file-committed-r2` reproduced three actual
defects after a real restart: zero-of-zero book counts, an unmeasured zero
saving in the main status, and retained preparation data. Content, catalogue
sizes, Reader cache and personal progress assertions passed before the final
combined defect assertion. The earlier r1 stopped because the new test guessed
the neighbour catalogue path incorrectly; that is a fixture failure.

Current local fixes:

- Recovery reports file operations without inventing a book count or saving.
- Cleanup considers only the completed job's exact native prepare-GUID/payload
  path under the captured work root. It checks the directory, exact owner marker,
  allowed names and regular file types; it adds an exclusive marker lease.
- Unknown files/markers and a live marker lease retain the workspace and warn.
  There is no broad prefix deletion or recursive recovery cleanup.

`native-Win64-file-committed-r3` passed, including independent archive/content
verification and runtime removal. Current product source then passed all six
crash stages in `current-Win64-r4`: job-published, file-committed,
catalogue-committed, personal-committed, completed-published and
file-journal-forgotten. Each private runtime was removed. The shared ZIP went
from 1,288,077 to 127,560 bytes; both selected books, untouched neighbour,
reading progress, original backup, refreshed visible sizes/cache and absence
of pending jobs/preparation data were checked.

`current-Win64-r5` passed keep-foreign-file and keep-foreign-marker. The earlier
foreign-file run failed only its Russian warning-literal assertion because the
new include lacked a UTF-8 BOM; that fixture encoding was corrected.

The latest keep-live-owner case failed its sentinel assertion. Its sentinel was
`payload/prepared-archive.bin`; the real file transaction may legitimately
consume that candidate before cleanup. The UI did report sharing error 32 and
retained the workspace. Investigate that distinction first on resume; do not
remove the ownership guard or label the case passed. A preview or other known
disposable file that the transaction does not consume may be a better sentinel.
The ordinary-apply case after it was not run because the batch stopped on failure.

Current x64 GUI executable SHA-256:
`01eea5fb493c3bb2327f01351f6a15ab19cb5080822b52707cffe2600574bb1c`.
The six-stage run used the same product source with the earlier test include,
binary `c00a6abfd76d951c6d6e5be67af64ee2f3c2303ad49bf94cbafe18040a7016fe`.
The only intervening change was declaring that test include's UTF-8 encoding.
The corrected baseline binary is retained as
`CollectionViewsTest-Win64-baseline.exe` in this stage.

## Steps recorded at the pause (superseded by the current recovery audit)

1. Inspect the failed live-owner case and correct the test's sentinel if the
   candidate was consumed by the approved transaction. Keep the failing log.
2. Complete live-owner and ordinary-apply checks, then build and run the current
   GUI recovery scenarios on x86. These x86 checks have not yet been run.
3. Build fresh native operation fixtures without the test-only fault symbol and
   run appropriate operation regressions on both architectures. Earlier native
   binaries do not contain the new owner-lease/cleanup code.
4. Complete cleanup checks for preparation interrupted before a durable job is
   published. The current fix handles the completed job's known preparation;
   it does not claim to recover all orphan preparation folders or power loss.
5. Continue the remaining accepted Todo and final package gates.

The stage's `run-recovery-cases.py` runs cases sequentially with fresh guarded
private runtimes. Use a new run ID; do not overwrite old evidence. Existing
timeouts were not increased. Its last run is terminal, not a live wait.

Local project `tools/ui/tests/CompressionRecovery.local.dproj` and its generated
sidecars belong to this task and remain for the pending x86 build. Keep unrelated
untracked files. Do not edit Pascal sources while a compiler is live.

BookProcessing packages remain the exact local alias-termination candidates:

- Win64: `126d16cf9fec8892489914d4ba78d00f25e3dcf8ed813f013d73b48d364c7acd`.
- Win32: `da0fdbc8d172b16d0a8982c4aeb051fc5f0bd83c74ebd9afe6168d8ca839fbdc`.

No Desktop replacement or publication was performed by this recovery work.

## Cleanup denials to preserve

Never retry these removals through an alternate route:

- `G:\HomeLibRu-build-cache\HomeLibre-post13-alias-stop-20261113\HomeLibre-inspection-runtime-qhfmvnar`
- `G:\HomeLibRu-build-cache\HomeLibre-post13-compression-inspection-20261113\HomeLibre-inspection-runtime-d4j1jzyj`
- `G:\HomeLibRu-build-cache\HomeLibre-post13-executable-20261113\native-Win32\HomeLibRu-update-test-identity-3mtqo61f`

An earlier compiler-cache removal was also denied; its exact path is not known
in the current checkpoint. Do not guess it or repeat a compiler-cache cleanup.
The qhfmvnar denial said only `blocked by policy`; its interrupted run is not a
pass. Other freshly completed runtimes use their normal guarded cleanup.

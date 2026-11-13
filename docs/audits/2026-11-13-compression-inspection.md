# Remembering verified compression checks

This is a dependency of incremental collection compression, not the completed
automatic INPX/Metabib/import workflow. No Desktop or public package has been
replaced by this milestone.

## Behaviour and invariants

The native controller remembers successful checks even if retaining the
original file was smaller than publishing a candidate. A subsequent operation
with the same quality, grayscale choice and actual engine identity verifies
the packed source SHA-256 before skipping preparation. It does not extract,
re-encode, publish a file job or write the catalogue/personal databases on a
cache hit. This still reads requested packed sources; it is not an indexed
new-books filter or an O(1) check of a large archive.

An inspection receipt contains original payload hashes and sizes, never the
discarded candidate or its image history. The source is held read-only with
write sharing denied while its checksum is verified and inspection metadata
is committed. Current book locators are checked; personal data is read-only.

`HomeLibreCompressionChecks` records physical identity, member, quality,
grayscale, engine identity and verified source/payload checksums. A changed
same-sized source with its old timestamp restored is not a hit. Timestamp-only
changes can be verified without re-encoding. Replacing selected members
invalidates their old profile checks and advances a neighbour's witness only
when its previous full source checksum matches the verified input.

`HomeLibreCompressionOutcomes` distinguishes an unchanged original, which a
new engine should inspect again, from an already transformed book, whose
images must be preserved. It is bound to the exact profile/output checksum.
Older receipts remain replayable without manufacturing inspection evidence.
For each member and quality/grayscale choice, only the current engine check
is retained; updating a million-book collection does not add a new permanent
check row for every old engine revision.
The existing six-column book-history table retains its schema. A physical
receipt stores its actual input hash; inspection alone preserves an earlier
matching input hash so it cannot invalidate that physical receipt.

The engine identity includes the worker, the archive engine, BookProcessing
descriptor/scripts, image executable/configuration and relevant optional
component descriptors. Only the native controller adds these options to the
captured receipt; a producer cannot redirect its source/catalogue binding.

## Long working paths found during this regression

The first complete x64 run (`inspection-Win64-r1`) failed 23 cases. Its worker
diagnostic reproduced a `.NET PathTooLongException`: image processing left the
original intact instead of producing the smaller expected result. A
programmatic compatibility-switch attempt did not fix the full scenario and
was removed. Further diagnostic failures remain separate evidence, not passes.

An intermediate helper with an application configuration passed tests, but
could not be shipped safely: beta 13's installer does not accept that new
configuration filename. The final image helper uses GetFullPathNameW,
CreateFileW and SafeFileHandle-backed streams for long image paths. It adds
no configuration file, raises no Framework requirement and changes no
system setting. Short paths keep the existing managed IO. Image-processing
errors identify Images rather than the unrelated XPS reader. Packaging now
rejects image/XPS binaries whose source or executable hash is stale.

CreateProcess's current-directory restriction is separate. For deep work
folders, the producer creates a short temporary directory junction to the
same directory. It copies no book. A held reparse-point handle prevents its
replacement during the child process; normal and cooperative cancellation
remove only that junction with `rmdir`, never recursively deleting its target.
A direct Windows subprocess/cancellation test preserves the target exactly.

That cooperative-only cleanup has subsequently been replaced by a Windows
delete-on-close reparse-point lease. Forced termination and the exact newer
local packages are recorded in
[the termination audit](2026-11-13-compression-alias-termination.md).

`inspection-Win64-long-r6` passed both the full native long-Unicode-workspace
operation and the original normal packaged-pipeline case. Source content,
neighbour, catalogue/personal sizes and acknowledgement assertions stayed in
place. The private runtime was removed. Native hashes and the exact package
are recorded in that run's JSON beside its log.

The following complete run, `inspection-Win64-r7`, failed with seven errors
(no assertion failures): subprocess/capability timeouts and one cleanup error
after a timed-out archiver. An independent run of
one failing native-pipeline case on C: (15 GiB free before the run),
`inspection-Win64-native-diagnostic-ssd-r8`, terminated with its actual
30-second producer timeout. Moving the private files to SSD did not eliminate
that timeout. Its private runtime was removed by the guarded context.

At the same time, Windows performance counters reported 100% total CPU use;
the largest sampled process was another task's headless QEMU emulator
(847% in the per-process counter, whose scale sums logical CPUs). No foreign
process was stopped or reconfigured. This is evidence of a loaded environment,
not proof that every failure is caused by that load. Inspect the complete
failure traces and repeat the appropriate content checks before accepting
this change. Do not call these runs clean performance measurements or relax
product estimate/stop requirements merely to obtain a pass.

The test-only subprocess runner now assigns a gated launcher to its own
Windows Job Object before a child can start. A timeout reaps that owned tree;
it does not scan or kill unrelated processes. Tests cover UTF-8 output,
ordinary and unsigned Windows exit codes, and a real grandchild holding a
file. Test and product deadlines were not increased. The eight-case retry
`inspection-Win64-retry-errors-r9` passed. The intermediate full x64 run
`inspection-Win64-final-r11` passed 102 tests, without skips, in 222 seconds;
that run still used the intermediate configuration-based helper.

`inspection-Win64-native-io-r12` passed three native checks using the final
no-configuration helper: normal processing, long Unicode work paths, and
the ImageProcessing minimum-version gate. Image-processing choices now
request ImageProcessing 3.0.0.14; original/color packing does not request it.
The engine fingerprint also invalidates earlier checks when the actual
helper changes. A complete final x86/x64 run remains a separate gate.

## Retrying incomplete image processing

`inspection-Win64-transient-before-r13` reproduced a real cache defect:
after a simulated temporary image failure, the original survived but a
successful fast-check row was still written. Clearing the failure without
changing the source or engine would incorrectly skip the next attempt.

Payloads and book results now distinguish `checked: false` from a successful
no-gain inspection. Failure restores the exact original, clears discarded
image history and leaves `retry_original: true`. Both inspection and physical
receipts remove that choice's old fast-check proof without inserting new
proof. Other successful members can still shrink the same archive. An
ordinary operation shows a bounded warning with member names and reasons;
the next attempt can process the failed book while retaining previously
compressed neighbours byte-exactly. Legacy receipts without `checked`
remain replayable. Invalid flag types are rejected before database writes.

The first seven-case fix run, `inspection-Win64-retry-fix-r14`, passed six
cases and exposed a limitation in the new test's independent reader:
Python zipfile cannot decode valid ZIP/PPMd. That mixed-archive test now
uses the official 7-Zip decoder; the failing run is retained, not relabelled.

One earlier test accidentally used a Windows component ending in spaces. Its
cleanup failed. Automatic approval review then denied removal of this exact
private runtime, with only `blocked by policy` as the reason:
`G:\HomeLibRu-build-cache\HomeLibre-post13-compression-inspection-20261113\HomeLibre-inspection-runtime-d4j1jzyj`.
It is retained; no equivalent deletion attempt was made. Failure logs live
outside temporary runtimes and are preserved.

## Final source checks so far

`inspection-Win64-final-r15` passed all 109 then-loaded tests without skips,
errors or failures (251.185 seconds of tests). Two subsequently added tests,
`inspection-Win64-image-paths-r16`, passed independently. They compare exact
short/long-path results for export images, scan images and image pages, and
verify deletion of incomplete long-path outputs without touching existing
outputs or the input. Both isolated runtimes were removed. These are regression
suite timings on the current machine, not compression-performance claims.

The final x86 run `inspection-Win32-final-r17` passed all 111 tests,
including the two extra long-image-path cases, without skips, errors or
failures (249.340 seconds of tests). Its isolated runtime was removed.
Thus both architectures cover the current source and exact local
BookProcessing 3.0.0.14 package. Production EXEs and published installation
packages have not been substituted for these native test workers.

Evidence root: `G:/HomeLibRu-build-cache/HomeLibre-post13-compression-inspection-20261113`.
Each JSON records all input/runtime SHA-256 values, outcome and cleanup.
The exact local BookProcessing archives used by the final runs are:

| Architecture | Package SHA-256 |
| --- | --- |
| Win64 | `ea849234a1cf4429527720c1cb726b445522de8baadb84cb19ec896e05fc6930` |
| Win32 | `0373b55198f9a2a2df3f2f6f388390f59abd842a5b502ae87032e2d935247760` |

## Remaining gates

- Validate final shipped image/XPS packages without new legacy-incompatible paths.
- Active-alias forced-termination cleanup is covered by the termination audit;
  verify remaining preparation cleanup and recovery through the normal window.
- Detect/offer new and changed books after INPX, Metabib and file/folder
  imports; add the manual new-books command, migrate older history, handle
  independent covers/images and refresh effective sizes after an INPX reset.
- Final production applications, full/minimal packages, public updates and
  Desktop replacement remain separate release gates.

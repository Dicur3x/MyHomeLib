# Source-cache progress through the native form

The million-card investigation found two long PrepareCache loops without
progress notifications after the preceding backup copy had reached 100%.
Unknown-total stages also retained the previous phase's normal percentage.

The cache location loop now reports its real filtered ApplyActions count at
zero, every 1,000 rows and completion. The incoming-key loop reports the
incoming review total at the same boundaries. Both have their own captions.
Unknown-total stages explicitly use marquee; the three review/apply workers
return to normal progress only for a known denominator. No overall percentage
or ETA is invented. Checks, transactions and publication order remain intact.
The only added database statement counts filtered work for the location phase.

## Native evidence

A 10,000-row ordinary catalogue is fully updated and reviewed again on x86
and x64. A derived real TImportProgressFormEx uses its normal StartWorker event
wiring and inherited control setters. The test verifies actual ProgressBar
style/position and txtComment caption, then observes monotonic zero,
intermediate and final values in both long phases plus marquee preparation.
The form remains hidden: these are native control checks, not visual pixel or
system-DPI inspection. The existing ID/field/relation/personal and input-hash
oracles also pass, with no data writes during the read-only review.

Separate actual worker runs cancel from progress callbacks at both new phases
in ordinary and bound collections: eight cases across the two architectures.
They preserve the original cards, personal notes/annotations, favourites,
archives, previous bound-source baselines and commit-witness isolation. The
small cancellation fixtures stop on their final reported row before publication;
they do not claim interruption at a middle row of a million-card transaction.
All four private runtimes are removed.

| Architecture | Progress gate | Cancellation gate | Native SHA-256 |
| --- | --- | --- | --- |
| Win64 | library-update-progress-Win64-r1694 | library-update-progress-cancel-Win64-r1694 | 2d3ed0cf7f35b920e2e84567244434dc90ec988af2aff11a301c6a97fbb79ded |
| Win32 | library-update-progress-Win32-r1696 | library-update-progress-cancel-Win32-r1696 | 25ba3ab047f7878845937ab15fc670c8fde2a0a3621e1ce219a8fd04185c41df |

checkpoint-r1697.json binds four native processes/28 PASS markers (including
bootstrap), 697 source inputs and 27 matching VirtualTreeView source files in
G:/HL-b14-external/library-progress-validation-r1691/.

## Build and source boundaries

The separate worktree starts from 34100bb3. The main C:/G: scale inputs stayed
unchanged throughout their paired million-card runs. Their frozen source and
summary-paired-r1695.json remain the scale evidence. This subsequent change
adds progress callbacks and one read-only count, not a new matching, archive,
ID-allocation or persistence algorithm; it does not justify counting the old
million runs as fresh executions of these callbacks.

The first worktree native build lacked the untracked VirtualTreeView source;
27 files were copied with matching hashes from the existing build mirror.
Both final native builds pass. A separate ordinary Main worktree build later
timed out without a terminal log although an EXE exists; it is not a passing
build receipt. The owned IDE exited. Warm production-mirror builds remain
required before this batch is called production-build verified.

This is source-update progress only. It does not establish progress coverage
for every export/conversion worker or a final beta-14 distribution. No E:,
user-library edits, Desktop replacement or publication are part of this gate.

# Offering compression after catalogue changes

Local work after `1ed8586f`. No public or Desktop executable is replaced.
x86/x64 UI and real INPX/Metabib/Explorer event checks passed below.

## Intended behaviour

Completed INPX/Metabib updates, committed legacy update batches and file
imports enqueue a small nonmodal strip in the main catalogue. It is offered
only for local/private collections with valid collection-specific compression
preferences. Fresh collections do not inherit another collection's quality
or grayscale choice. No scan or compression starts just by showing the strip.

The user can open the saved choices with **Сжать новые…**, cancel those
choices, or choose **Позже**. The manual menu command remains available.
Repeated notifications use one strip; pending offers are bound to collection
ID and actual catalogue-file identity. Switching collections hides another
collection's offer. A replacement catalogue must not receive a stale offer.
Busy/recovery operations disable the action. Successful whole-collection
compression consumes that collection's pending offer.

The current hooks include manual INPX/Metabib update, legacy committed update
batches, selected-file/Explorer import, old FB2/FBD import and the old non-FB2
editor's successfully added books. Their complete integration scenarios still
require native proof. SQL-dump creation currently creates an online catalogue;
it must not offer to compress remote books that are not present locally.

## Evidence and failures

Stage: `G:/HomeLibRu-build-cache/HomeLibre-post13-compression-arrivals-20261113`.

- `CompressionArrivals.local-Win64-cebeeed4658c.err`: first build failed in
  the new test, which used its inline `CurrentCollection` variable before
  declaration. The early check now uses the existing `Collection` parameter.
- Build `87764a4a7403` was inadvertently started after the patch script's
  assertion failed. It was stopped after verifying both its own project
  command line and its Python build parent. No foreign IDE was stopped.
  It is an aborted build, not a successful check.
- `CompressionArrivals.local-Win64-8cc84925bf8f`: the intermediate fixture
  compiled, SHA-256
  `96709e980720a48139c29f89e5019f4079a77fddce59ce44508240b7fb77a698`.
- `gui-Win64-r1`: failed its unchanged 150-second outer deadline during theme
  and main-window scaling checks after the initial compression completed.
  It is not a passing offer scenario. Its private runtime
  `HomeLibRu-native-4blptokk` was removed; no real user books were used.
  Additional per-theme/per-scale trace points were added for diagnosis.

At the time, Windows counters showed 100% total CPU use. The largest sampled
processes included two unrelated headless QEMU instances (381% and 304% on the
per-process counter, which sums logical CPUs). They were not stopped or
changed. This is evidence of a loaded environment, not proof that the timeout
is entirely caused by that load. Product/test deadlines were not increased.

The subsequent build integrates the offer's layout with the existing final
main-form DPI layout passes and guards nested scaling. The layout test passes
without an extra manual refresh after each scale. It also captures the
original collection ID before starting a compression operation, so consuming
an offer cannot accidentally affect a newly selected collection.

## Completed x64 checks

- `gui-Win64-r2`: passed the complete compression/offer scenario in 63.813
  seconds, with the same 150-second outer deadline. The checks cover both
  themes and 96/144/192/216/288 DPI, malformed/fresh settings, a live import
  transaction, repeated notifications, Later, canceling options, explicit
  start with saved quality/grayscale, no-arrivals, neighbour bytes, progress
  and the absence of an additional backup. The private runtime was removed.
  Fixture SHA-256:
  `d6b404025fe48f2730c9000d82beb4771a2662837cb3ab4e5bc6335c5ca02b90`.
  The earlier timeout remains a failed run; this is not a controlled speed
  comparison between the builds.
- `explorer-Win64-r3`: passed in 16.000 seconds. The existing native Windows
  file-drop/Shell-list fixture now verifies that declined import shows no
  compression offer, accepted multiple-file imports show it, and Later keeps
  source files unchanged. Its existing copy/link/archive, unrelated collection,
  source-relocation and personal-data checks remain. This exercises the normal
  application import path with Windows Shell data, not a human pointer drag.
- `index-Win64-r4`: passed in 29.640 seconds. The actual normal update menu
  and its chooser/result controls ran INPX and Metabib updates. Committed
  updates offer compression; cancel, failure and Later do not start it. The
  original outcome tests still cover worker commit/cancel/rollback, partial
  batch CIDs, personal metadata, update-search choices and unchanged input.

The latter two cases use fixture SHA-256
`8b5a7bea3ba7b564c4bd7fd1269b431b3f12f17177e6605344f8b388cc11af2b`;
only their new test assertions differ from the UI build's product sources.
Both removed their fresh private runtimes. The wrapper also verifies an
unrelated shared ZIP remains byte-exact. Exact package/helper hashes are in
each JSON. These are synthetic catalogues only, without user collection data.

## Remaining gates

The legacy batch and old FB2/FBD/non-FB2 action hooks have source-level
integration but are not separately claimed as full native GUI checks. The
complete user-data incremental scenario, sidecar images/history migration,
restart after component installation and final published package path remain
other Todo gates.

## Completed x86 checks

Final fixture SHA-256:
`f58105fe88ad166a8eafcf63227b6a6ea5547c2d1181139b11f2058ffb08017d`.

- `gui-Win32-r5`: passed the same complete strip, choices, both themes,
  five DPI values, explicit start and no-arrivals assertions in 126.125
  seconds with the original 150-second deadline. It includes repeated
  whole-window scaling and the existing quality-comparison checks; this is
  not the duration of an ordinary click or a clean speed benchmark.
- `explorer-Win32-r6`: passed accepted/declined multiple-file Shell imports,
  Later, copies/links, archived members and unchanged original payloads in
  12.641 seconds.
- `index-Win32-r7`: passed the actual INPX/Metabib menu, cancellation/failure,
  completed update, last-update search and Later checks in 41.172 seconds.

All three fresh private runtimes were removed. The event wrappers verified
the unrelated shared ZIP stayed byte-exact. No user collection was operated
on. No test or product timeout was raised to obtain these passes.

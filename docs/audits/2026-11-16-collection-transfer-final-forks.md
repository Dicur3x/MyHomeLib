# Shared catalogues whose final default roots diverge

## Implementation

Two registrations can share a catalogue and the same original book root without
any present locator conflict. If only the selected registration's default root
will move, they cease to be equivalent. The catalogue fork planner now compares
the frozen final collection root with its original canonical root before deciding
whether other registrations need a separate catalogue. Equivalent retained
registrations share one fork; registrations with a different original root keep
their own fork. If the default root stays physically in place, equal aliases do
not acquire an unnecessary fork.

The fork grouping role is separate from each registration's original physical
root witness. Publication still validates the actual original root. The selected
registration keeps its existing catalogue, other registration IDs remain stable,
and an unlisted personal-only book belonging to another registration retains its
original path, bytes, progress and note through a source-free replay.

There is a related final-settings dependency: a non-INPX source stores both a
registration ID and its catalogue filename. The source opener requires that file
to match the current registration. Final-layout projection now replaces this
filename with the reviewed fork destination for that registration, after checking
the original filename against the frozen registration. Source IDs, roots' mapping,
unknown JSON fields and other source metadata survive. An inconsistent original
filename is refused. INPX references are not rebound by this rule; unchanged
equivalent aliases retain their original catalogue filename.

This extends the read-only layout projection. It does not yet apply final source
settings/default roots or mark the transfer complete.

## Evidence

All inputs and payloads are private diagnostic data on G:. No working collection,
Desktop application or published package was changed. Builds use the licensed
Delphi IDE with identical staged/worktree native inputs and removed build temps.

| Build | Binary SHA-256 |
| --- | --- |
| Win64 r897, root divergence | `4cd991a7e934d528a3684e13cd68cd15d182462cbde18df2369c03759c1089d7` |
| Win32 r898, root divergence | `28a0a75eb21269a39fb816d247c798eb2f15e04cb9c81a3909a3d93148dd3139` |
| Win64 r901, source filename projection | `9e855126345885e361560300ebdeca4396fcaa871cf534b8a8391d95c2b155ed` |
| Win32 r902, source filename projection | `75196614c88257bceee3d773159e81ab35174f1ab289797ef168283247bc7d93` |

Reports are under `G:/HL-b14-external/`:

- `transfer-final-forks-Win64-r899` / `Win32-r900`: seven methods each PASS,
  142.962 / 144.160 seconds, nine native invocations each. Four new fork methods
  cover equal old roots, the unchanged kept root, preservation of another
  registration's personal-only file, source-free replay, and distinct retained
  root groups. Three existing regressions cover late metadata on a shared fork,
  actual parent-root transfer, and one reference capture for 26 publication groups.
- `transfer-final-source-Win64-r903` / `Win32-r904`: nine methods each PASS,
  222.313 / 219.834 seconds, eleven native invocations each. Five new methods
  verify the external source filename before/after fork publication and replay,
  INPX preservation, mismatched-file refusal and unchanged kept aliases. Four
  focused regressions verify the personal-only file, source/profile unknown
  fields and unrelated incoming folders, and ordinary 26-group publication.

Across both stages, nine new methods and five distinct existing regressions pass
per architecture: 40 native invocations, including two expected rejected
projections, no unexpected return codes, forced exits or skips. Every owned
runtime was removed. Stage `summary.json` files retain exact native inputs,
counts and cleanup. Diagnostic durations are not large-library throughput.

Final modified native input SHA-256:

- `unit_CollectionTransferForks.pas`: `3e56dc7350485bdd21f24a3b01ffb14da1d6a5757d35025fc7a79ce53f1415f7`.
- `unit_CollectionTransferLayout.pas`: `5e7791ea4a93570878fb6e0573ec62e79b663201ef76ccfdc3ac250c66035b3d`.

## Remaining

Durable finalization must still bind and apply the projected source/profile
settings, future missing-book locators and registration roots with recoverable
per-database commits. Other affected catalogues' source-file references must be
coordinated as well. Retained source indices/cache, Reader/live DAO/jobs, normal
startup and Sources UI, space/cleanup, larger and cross-filesystem trials,
post-transfer updates, final production builds and release remain open.

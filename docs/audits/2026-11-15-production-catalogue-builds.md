# Production catalogue builds and isolated startup

Source revision: `52ee19b1`. Both ordinary Release main projects build as
`HomeLibre.exe`, including the corrected XML writer. This is an intermediate
post-beta-13 check: numeric/string version resources remain 3.0.0.13 /
3.0.0_pre1.13. It is not the beta-14 release or package gate.

## Build inputs and outputs

A detached source worktree at `G:/HL-b14-build-r492` keeps all new compiler
outputs, dependencies and temporary files on G:. C: retained about 20 GiB free.
The project was not edited to replace its normal production configuration.

VirtualTreeView is a documented separately supplied, ignored dependency
(`BUILDING.md`, Changes to VirtualTreeView). The fresh checkout initially lacked
it. r495 timed out while handling the IDE reminder/result, and r496 retained
the actual F2613 `VirtualTrees` missing-unit error. All 27 source files from the
prepared working dependency were then copied byte-for-byte to the build tree;
`virtual-tree-inputs.json` records each SHA-256, with sorted manifest digest
`3d10fca359a103c8dae8e9f3ff95473fc3bc483a73a5478a893d9ca7727ef38e`.
No dependency patches or licensing settings changed in this step.

The ordinary icon project was built for both architectures (r493/r494). Then
licensed IDE builds r497/r498 passed, with default Win64 built before the Win32
sibling project to retain correct application resources:

- Win64 HomeLibre.exe: `91af0b13706f986a60e67a0978d2ca93760d4e2a65bcf25215bbf44a0bfd9502`.
- Win32 HomeLibre.exe: `61edd0748bfb8ea981bd6d1c6642ff705fed882cd9226da971402e69736b77ac`.

Both executable resources report InternalName HomeLibre, OriginalFilename
HomeLibre.exe and ProductName HomeLibre. The XML error marker is linked and the
native recovery fixture's forced-termination trace is absent.

## Real application startup

`main_startup_probe.js` now copies and selects HomeLibre.exe, with the old
HomeLibRu.exe fallback retained for older runtimes. Its fixture uses private
portable profile markers and disables unrelated update/metadata network work.
SQLite, genres and the WebP decoder were staged from matching working runtimes;
help, icons and Zstandard came from the ordinary build deployment.

- r499 Win64: the first page argument 4 selected Groups, not Search; the persisted
  enum was checked in source. In the actual main app, selecting Search showed
  zero results without an indeterminate operation. Switching to dark theme
  recreated the window, which was rebound and observed with the same empty
  search and contrast-appropriate icons/controls. Some tiny fixture catalogue
  cards deliberately have no physical FB2; this did not test book reading.
- r500 Win32: saved enum 3 selected Search directly on actual startup. The search
  controls were empty, result count was zero and status was Ready.

Both exact owned application windows closed normally, both probes returned exit
0, and both private runtime folders were removed by their ownership guard.
Logs: `G:/HL-b14-external/production-startup-Win64-r499/native.log` and
`G:/HL-b14-external/production-startup-Win32-r500/native.log`.

The Win64 first startup was on Groups, so this is not a saved-search-startup
check for that architecture or a large-collection startup benchmark. Reader,
launcher/updater, module/offline distributions, final beta-14 version resources
and published-client update validation still require their release gates.
The Desktop and user collections were not changed.

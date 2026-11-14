# Legacy FBD copies and packed INPX through the main window

Local beta-14 validation following `c2fbb709`; no final distribution or Desktop
replacement. The existing native FBD/unavailable/INPX fixtures now use the actual
installed BookProcessing paths (`tools/python`, `tools/bookconvert`) instead of
historical development layouts.

The isolated wrapper installs the exact `packages-r40` BookProcessing package,
the matching native image helper and the architecture's shipped 7-Zip. It adds
a large illustrated FB2 so that the INPX path must actually optimize and open a
new book with the retained maximum-quality profile, not merely copy plain text.

The parent native test exercises thirteen required outcomes across two launches:

- A shared FBD container remains byte-identical, both native locator forms open
  the exact book/description, and retention succeeds without originals.
- A loose book never grows and remains readable after hiding its source.
- Alternate files with empty/NULL extensions survive packing and retention.
- The estimate dialog can cancel and continue; registration is separate.
- Unavailable/empty books remain in the catalogue and become packable when the
  source appears; empty input cannot replace a previously readable packed book.
- The stored INPX/profile continuation is one-shot and rejects changed inputs.
- A real packed INPX update retains old archives/IDs, updates a changed book,
  adds a new book and preserves the preceding catalogue and source book.
- The retained profile produces an optimized FB2 that the native catalogue opens.
- The last-update filter selects only new records.
- Ordinary full import refuses to replace a managed packed catalogue.
- A second application launch consumes the saved continuation through the actual
  main window, confirms the estimate/result and opens only the new records.

This is synthetic private data, not a live user-library pass. The wrapper asserts
every expected native PASS marker and removal of its own temporary installation.
The normal-parent stage and resumed-main-window stage share a preserved log.

## Results

Win64 `packed-fbd-Win64-r51` passed in 40.000 s. All thirteen required markers
were present; the temporary runtime was removed. Native fixture SHA-256:
`bf6201008703a37484e978ed994cb1bbb2222371135a6b128ecf87d31d1e09f0`.
Build log: `CompressionRecovery.local-Win64-e3ab3d56b82e.err`.
The package/image identities match the Win64 entries in the preceding
`2026-11-14-packed-catalogue-sizes.md` audit.

Win32 `packed-fbd-Win32-r52` passed the same thirteen outcomes and actual
main-window continuation in 42.078 s; the temporary runtime was removed.
Native fixture SHA-256:
`5d4699eb0dadcb0c6228f2922e78267f37044de4b73ae1779338e7b7e4a4d495`.
Build log: `CompressionRecovery.local-Win32-5a5f58ba107b.err`.

This run uses maximum illustration compression with installed tools. It does
not exercise JPEG XL codec installation, missing-component continuation, old
FLibrary sidecars or the optional real-book fixtures. Those remain separate
checks. No new production behavior was changed for this validation.

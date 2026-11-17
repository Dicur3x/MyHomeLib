# Catalogue-scale transfer after reference-capture reuse

Both current native workflows completed on G: with 1,000,003 catalogue books.
Consolidated validation: `G:/HL-b14-external/transfer-removal-scans-million-validation-r1305/summary.json`.
This closes the pending scale check in the [removal-scan audit](2026-11-17-collection-transfer-removal-scans.md).

| Architecture | Move | Confirm | Replay | Whole harness |
| --- | ---: | ---: | ---: | ---: |
| Win64 r1296 | 2912.844 s | 517.593 s | 7.157 s | 3760.984 s |
| Win32 r1297 | 3094.719 s | 480.765 s | 7.156 s | 3888.656 s |

Every native phase exited zero. The wrapper independently checked all
non-locator catalogue, personal and source-cache columns before/after the move;
the snapshots match. Two copied ZIP carriers have the original SHA256 and their
old source files are gone. The six protected original cache/index/neighbour files
are byte-identical. Published roots match the approved plan. Independent update
identities remain correct for both installed caches (1,000,003 and three books).
Confirmation leaves no pending operation; replay returns the same receipt and
does not change any catalogue/state SQLite file. Both private runtimes were
removed by fixture teardown.

The binaries are the r1288/r1290 drivers used by the small regression suite:

- Win64 SHA256 `200af8707473e448de50aacb7c6a8895b714a6a62057b34ddc4bc204307123cc`.
- Win32 SHA256 `cf63e6790b919c5fce7d34a528f7620a0d95e8975c45a68d7d1bafdb84c4feb9`.

All 663 input hashes match the r1295 validated source cohort (`1f1a69e2`).
The only later change to an already listed input is the unrelated catalogue
XPS-preview integration in `unit_BookInfoPreview.pas`; the collector checked its
historical bytes against that commit. The transfer driver does not exercise the
book-information panel. Its evidence is not relabelled as a final Main/UI build.

The largest sampled private-runtime file allocation was 4,723,645,560 bytes on
Win64 and 4,717,698,168 bytes on Win32, including fixture databases. Sampling was
every roughly half second; this is not an exact volume-wide peak or an estimate
of additional free space for arbitrary collections. Peak job commit was
292,237,312 and 172,019,712 bytes respectively. Mapped-file working sets can be
larger (the Win64 confirmation reached about 1.47 GB); commit and working set
must not be treated as the same measurement.

The two carrier archives contain only 436 bytes in total. These timings measure
catalogue planning, publication and verification, not copying a large library or
repacking real book archives. The two architectures overlapped in time, so this
is not a controlled comparison of their speed. The separate 26-carrier tests,
not this two-carrier case, establish the reduction from 53 reference captures to
one.

C: retained its 8 GiB reserve; E: was not used. Physical-volume/free-space
failures, remaining post-move format/update combinations, final ordinary UI,
production packages and release remain separate gates.

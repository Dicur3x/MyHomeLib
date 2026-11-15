# Compressed copy through the ordinary catalogue menus

## Change and scope

The copy packer existed, but no ordinary menu entry called `PackCollection(False)`:
the whole-collection command now compresses in place. A separate Collection menu
command, “Создать сжатую копию…”, restores a discoverable route to the existing
copy workflow. The profile explains retained originals, supported containers and
the distinction between packing and image quality. The original profile is now
“Упаковка без изменения книг”. Record counters explicitly include personal
locators and additional physical copies; their algorithm is unchanged.

The new `packing-copy-ui` scenario constructs the real Main form and invokes
the new menu, then its normal Update from File action. Windows destination,
profile, INPX and arrival-directory pickers and registration choices were operated
through Computer Use. A native timer validates the actual estimate and presses
its Continue button; it does not substitute a packing implementation.

The private catalogue initially contains three real copied payloads from r668:
CBZ, DOCX and ODT in one shared ZIP. A fourth ID arrives in a separate new ZIP;
its DOCX payload deliberately equals the existing DOCX, so this step proves a
new library entry/archive, not previously unseen image content. Original working
archives are only stat-checked against their retained identities. No working
catalogue or library payload is changed.

## Verified flow

1. Create an economy/grayscale copy in a separate directory; review four readable
   records (three books plus one personal locator), with zero unavailable.
2. Register/open the separate catalogue. Verify all three native streams and
   visible sizes, actual grayscale pixels and unchanged non-image content.
3. Rename the private originals directory away. With old original archives
   unavailable, use a full new INPX and an incoming directory containing only
   that INPX and the new ZIP. The saved quality profile is reused.
4. Review five readable records, process the new DOCX and reuse the ready shared
   archive. Register/open the separately generated updated catalogue.
5. Verify old payloads remain byte-exact and keep their internal IDs, new DOCX is
   smaller, measured/visible sizes agree, and DataVersion becomes 20261115.
6. Verify both registered copies retain rating 4, progress 37, the review and one
   favourite; the earlier copy still independently reads its three books.
7. Restore the private originals directory; verify its exact ZIP and book hashes,
   original book records and personal fields. Check incoming ZIP/INPX hashes too.

Normal Main view persistence may write source catalogue Settings. This test
checks source book records, streams and personal data, not byte identity of the
entire source database. The full 4.5 GB native data trial remains separate.

## Evidence

Reports are under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| `copy-ui-Win64-r703` | PASS, two estimate reviews, source/first/updated collection IDs 1/2/3, at least one reused archive, all content/pixel/personal-data checks. |
| `copy-ui-Win32-r705` | PASS, same flow and checks, including the clarified record-counter text. |

| Payload | Original bytes | Win64 bytes | Win32 bytes |
| --- | ---: | ---: | ---: |
| CBZ 101 | 3,128,863 | 2,896,607 | 2,896,607 |
| DOCX 102 | 1,048,434 | 951,302 | 951,302 |
| ODT 103 | 655,616 | 313,073 | 313,106 |
| New DOCX 104 | 1,048,434 | 951,302 | 951,302 |

The differing ODT output size across architectures is retained in the evidence;
non-image preservation and grayscale pixels pass independently on each. Old
packed bytes are compared within each architecture before/after the INPX update.
Timings (178 and 474 seconds) include interactive driver waiting and are not
compression throughput measurements. Both successful owned runtimes and their
temporary snapshots were removed.

The licensed IDE built the diagnostic catalogue with these binary SHA-256 values:

- Win64 r702: `b180e38dbe7f5d51a06d9de599bda22bcca104236371b11d1887a1a51195da33`.
- Win32 r704: `7cdd1dc848668889a1e18ae2d3409ba643b20dc6f9e27e831612340a52fb2bea`.

The Win64 passing run predates the final counter-text clarification; Win32
includes it. A subsequent wording-only edit says “supported illustrations”
rather than implying that static WebP is excluded; it awaits the final Main
build, without changing processing or options. Both use unchanged
`packages-r691` and `images-r653`, whose exact
package hashes are recorded in the reports and prior container UI audit.

Failed setup observations remain visible: r697/r698 exposed a test compilation
error (a Caption alias needed an explicit string before `Contains`); r700 was
rejected by the existing runtime-prefix guard; r701 expected three readable
records instead of the actual four including the personal locator. These were
test/setup corrections, not passing product trials. No guard was weakened.

## Remaining

This proves the ordinary compressed-copy and packed-copy INPX registration flow
using real production forms in a small isolated catalogue. It does not complete
the final Main/Reader binaries, all format/volume coverage, physical consolidation
or release packages. Desktop and public artifacts have not been replaced.
The retained 4.8 MB payload set is still useful for those final application trials.

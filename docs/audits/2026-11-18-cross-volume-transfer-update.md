# Actual cross-volume transfer followed by INPX updates

The complete native coordinator transferred generated ZIP books from C: to G:.
The fixture requires different actual volume GUIDs, not different drive-letter
spellings of one volume. It runs on x86/x64, with no E: or user-library access.
All catalogues, profiles, journals, caches, downloads, build outputs and temporary
files stay on G:. Only the tiny generated source ZIPs start on C:.

## Scenario

Each architecture runs two composed cases:

- An ordinary collection with catalogue-path INI positions/bookmarks.
- A bound INPX source with personal-path JSON notes.

The three original books have empty, zero and opaque LIBIDs. Each source archive
also has an NTFS named stream. The full transfer must preserve its primary
SHA-256 and named-stream SHA-256, publish catalogue/personal/source roots and
profiles, and release the exclusive original. The old C: source directory is
then renamed offline.

A new archive arrives only on G:. Full, repeated and append INPX updates retain
the three original IDs, payloads, personal fields, favourites and reader names.
Deleting the empty-ID card followed by full and append updates preserves that
exclusion and the remaining books. Reader INI/JSON hashes must remain unchanged.
There are five post-transfer update applications per case, twenty across the
paired gate.

The native fixture accepts C: source data only in an exact private directory
under the current user's AppData/Local/Temp, with a random 32-character token,
matching directory name and ownership marker. It must initially contain nothing
else. The driver verifies the same ownership before cleanup. The system-drive
8-GiB reserve is checked before and after; both C: source directories and G:
private runtimes were removed.

## Results

Both terminal runs passed all eight markers, including the two bootstrap
markers and six scenario-specific markers.

| Architecture | Native SHA-256 |
| --- | --- |
| Win64 | 0fa06fe1273038a5df3a13bed4d812f7e8f6a75461b9dec536793ac5dcd6f5d9 |
| Win32 | 6753e041006138b6543cf88b1c1df5c1b089deeea006c741da9966e25b411cf7 |

Reports: transfer-cross-volume-updates-Win64-r1612 and
transfer-cross-volume-updates-Win32-r1615.
Full source/architecture/cleanup binding:
G:/HL-b14-external/transfer-cross-volume-validation-r1614/summary.json.
All 693 source inputs are bound; native inputs match the build mirror. Production code and workers
remain byte-identical to the separately completed placeholder/history/cancel/
recovery gate; only its three test fixture files gained this opt-in scenario.

## Diagnostics and limits

r1606 stopped while the test helper tried to create a named stream through
TFile.WriteAllText, which rejects that path syntax. r1609 completed the transfer
but its test read used an unprefixed long named-stream path. The helper now uses
TFileStream with the existing native long-path prefix. Neither diagnostic led
to a production change or removal of the named-stream assertion. Both failed
runs removed their private C: sources and G: runtimes.

This verifies small archives on C:/G: NTFS volumes, including complete locator
cutover and subsequent INPX. It does not prove large-archive throughput,
different filesystems, disconnected/network volumes, real ENOSPC, concurrent
application jobs or final beta-14 packages. No user books or Desktop files were
modified.

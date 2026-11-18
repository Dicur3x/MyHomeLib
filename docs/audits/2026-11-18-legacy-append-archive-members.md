# Archive members in the direct INPX append command

## Reproduction

The ordinary file-update progress dialog applies an append INPX to an
existing local catalogue. It contains three indexed books and a manual loose
file. Each expected addition reads its distinguishable original payload.
After a successful dialog completion, the old x64 code left five total
cards out of the nine expected. Four new archive members shared a basename
already present elsewhere, so only the uniquely named member was added.

The verified baseline is legacy-append-archive-Win64-r1907-baseline.
The earlier fixture r1906 stopped before invoking the update because the
test tried to find a blank publisher ID by a general ID lookup. The final
fixture anchors the older cards by reading their actual catalogue records.

## Change

Checked local INPX appends compare the archive and the member name and
extension. An old reference to ZIP is treated as the same physical archive
as 7z only when the reader's existing file resolution yields the same
path. Two present archives with the same basename are separate. The
other paths retain their original choices for checking incoming records.

The fixture includes empty, zero and textual publisher IDs, both a real
split.zip and split.7z, and a legacy bridge.zip record whose body already
comes from bridge.7z. It verifies exact bodies, stable catalogue IDs,
ratings, progress and reviews, plus hashes of the publisher indexes,
source archives and manually added file. The latest-update list reports
five additions after import and zero on repeat.

Control runs cover the legacy workspace's local and HTTP paths,
cancellation and unavailable paths, reviewed ordinary and merged
updates, and the packed placeholder scenario. These are generated inputs
in isolated G: profiles. Both ordinary applications and both test hosts
built successfully. Eight runs passed with 62 markers and 705 verified
inputs. Receipts and the source list are at
G:/HL-b14-external/legacy-append-final-r1908/summary.json.

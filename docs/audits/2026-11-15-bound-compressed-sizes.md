# Keep measured sizes across reviewed bound-source updates

A native two-source FB2/EPUB fixture exposed two related failures:

- Updating a lower source changed its compressed copy's recorded size from the
  measured 143,340 bytes to the publisher's 1,230,714 bytes (r385).
- After fixing copy restoration, updating the preferred source left the
  personal card at 1,230,714 bytes although the catalogue had restored 143,340
  bytes (r395).

## Implementation

The shared index-size tracker now captures and restores physical source copies
as well as main rows. Card identities and copy source keys use distinct kinds;
each copy resolves through its own root. Both the physical archive identity and
any external-image snapshot must still match its compression witness. The same
library ID, filename or source key at another physical file cannot borrow its
old size. NULL copy extensions and roots are normalized during this comparison.

The bound update also synchronizes an existing preferred personal card's size
inside the current catalogue/personal transaction. The optional size-writer
interface uses one cached UPDATE statement: it neither creates absent cards nor
rewrites progress, ratings, notes or serialized metadata. An older provider can
use the existing full-record update path. The shared helper still supports
catalogues without a copies table.

## Native evidence

The fixture imports and merges two real source snapshots with same-named ZIPs
in distinct roots. It compresses all four physical FB2/EPUB members, updates the
lower source with corrected metadata, repeats full/append updates, adds a new
FB2 from a third downloads folder and compresses only that member. It then
updates the preferred source. Both copies, payload hashes, measured sizes,
priority, rating, progress, annotation, review and favourite membership remain
consistent. Incremental checks select 0/1/0 new members while skipping 4/4/5.
The main list and prepared reading cache refresh before job acknowledgment.

A trigger forces the size-only personal write to fail after publisher metadata
was written. Both stores and source-copy sizes roll back, then the same update
succeeds after the trigger is removed. This is a transactional failure, not a
process-death test with compressed copies.

The ordinary regression retains eleven main-row size boundaries and adds ten
copy boundaries: colliding card/copy identities, same-name archives, another
physical path under a reused source key, changes during import, stale witness,
wrong payload proof, unknown size, unchanged legacy inspection, NULL locators
and rollback. All owned temporary tracking tables are removed.

| Platform | Final run | Gate | Result | Seconds |
|---|---|---|---|---:|
| Win64 | `update-bound-size-final-Win64-r398` | compressed bound sources | PASS | 112.843 |
| Win32 | `update-bound-size-final-Win32-r401` | compressed bound sources | PASS | 99.078 |
| Win64 | `update-size-regression-Win64-r399` | ordinary + 21 boundaries | PASS | 78.282 |
| Win32 | `update-size-regression-Win32-r402` | ordinary + 21 boundaries | PASS | 73.890 |
| Win64 | `update-size-recovery-Win64-r403` | ordinary startup recovery | PASS | 20.203 |
| Win32 | `update-size-recovery-Win32-r404` | ordinary startup recovery | PASS | 21.125 |

The last two runs terminate a normal bound update after catalogue commit, then
start the normal data module/main window. They preserve a later neighbouring
collection's personal witness, verify archive members, favourites, both stores
and repeated acknowledgment. They use the earlier small plain-ZIP recovery
fixture, not the new compressed-copy fixture.

Licensed IDE builds r397/r400 and SHA-256:

- Win64: `b69e38cb5093b33f6d04c185fe97d5bef380fe59f6dc95eb9c78d7b040f944b7`.
- Win32: `491f68cb40946bc7d3f9b4c7b50411fb9a862f994376db37ea41c766363108a8`.

Aggregate: `G:/HL-b14-external/update-bound-size-validation-r405/summary.json`.
All successful private runtimes were removed. Parallel timings include setup
and are not large-collection performance measurements.

## Remaining scope

Compressed-copy process-death/power-loss composition, FLibrary/JPEG XL external
image updates, other packed/online catalogues, production-scale workspace and
memory measurements, final production packages and release remain open.
No user collection, Desktop installation or GitHub release was changed.

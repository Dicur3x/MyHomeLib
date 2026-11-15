# Publisher locators remain separate from resolved ZIP/7z paths

Follow-up: [legacy external locator recovery](2026-11-15-library-update-legacy-locators.md)
reads a verified saved input for old external paths and records its remaining
partial-input and scale limits.

Reviewed updates and source-refresh snapshots now retain the conventional ZIP
name from an INPX member (or its explicit FOLDER value). They resolve an actual
ZIP/7z when using a book. An opt-in importer flag enables this only for index
snapshots; the ordinary importer keeps its existing default behaviour.

The first location-table implementation still failed the real 7z fixture:
`update-seven-alias-Win64-r329` and the detailed `update-seven-probe-Win64-r332`
showed unchanged metadata but `books.7z` in the previous publisher-location
column versus `books.zip` in the new index. The importer had already selected
7z while building the supposedly raw snapshot. The opt-in flag fixes that
upstream loss of information. The earlier r326 failure was only a fixture
missing its required profile name; it is not a product-regression proof.

## Comparison and publication

The review records both the normalized publisher locator and physical identity.
When no incoming file is available, it retains the previous physical identity
only if the artifact key, metadata stamp, publisher locator and source root
agree. An unavailable file alone cannot prove that a conventional ZIP became
a different physical container. Available files retain normal comparison.

`LibraryUpdatePublisherLocations` persists the raw locator per cached book.
Full snapshots use their import IDs; append snapshots use the explicit
input-to-cache ID mapping. This keeps publisher names even after verified
locations are rewritten to absolute paths in other folders.

Previous source-link keys now use the resolved container instead of the raw
ZIP spelling. For an unavailable legacy raw ZIP cache, an existing live 7z
source link can establish the retained container. Older cache rows without the
new table can recover root-relative ZIP/7z aliases. A resolved absolute path
outside the original root is not reduced to an invented relative basename.

Explicit exclusion tombstones and previously excluded rows are also omitted
from new/changed counts and the needed-archive list. A deleted publication
returning after an omitted index does not request its archive again.

## Native verification

The fixture creates actual 7z archives with the installed 7-Zip tool; they are
not ZIP files with a renamed suffix. Ordinary and bound-source variants cover:

- A conventional ZIP-named INPX, real 7z source links and a metadata correction.
- An append whose input record ID differs from its cached ID, including a
  direct assertion of the saved publisher locator.
- Publication deletion, an intervening full index that omits it and a later
  return of that excluded publication.
- Moving the private original 7z aside and removing its now-empty directory,
  then reading new members from separately downloaded 7z archives.
- Retained original locators/personal fields, reconnecting and reading the
  original member, and unchanged SHA-256 of original/downloaded archives.
- The old cache layout, simulated by removing only the private cache's
  publisher-location table in the bound variant.

The previous whole/bound, rollback, missing-member, profile-switching and
offline ZIP regressions remain in the same application run.

Fresh licensed IDE receipts and native SHA-256:

- Win64: `update-seven-final-build-Win64-r336`,
  `3f41a10f217aedfcff8042a95c6c9f01a9475974b2d8b9c7c0a5830942757645`.
- Win32: `update-seven-final-build-Win32-r338`,
  `48ab8c0748a3c286d73cf7d591cc90c5cbaa8762efb7adcf4cf383d84a031605`.

| Platform | Final run | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-seven-final-Win64-r337` | PASS, application | 100.906 |
| Win32 | `update-seven-final-Win32-r339` | PASS, application | 151.641 |
| Win64 | `update-seven-regression-Win64-r340/sources` | PASS, source UI/review | 82.969 |
| Win32 | `update-seven-regression-Win32-r341/sources` | PASS, source UI/review | 88.422 |
| Win64 | `update-seven-regression-Win64-r340/legacy-menus` | PASS, original INPX/Metabib menus | 33.766 |
| Win32 | `update-seven-regression-Win32-r341/legacy-menus` | PASS, original INPX/Metabib menus | 35.375 |

The source regression includes cancellation, missing/malformed records,
individual/default local HTTP requests, collection rename and both themes at
96–288 DPI. These are control-layout assertions, not a screenshot review of
every dialog. The aggregate receipt lives in
`update-seven-validation-r342/summary.json`. Every passing runtime was removed;
parallel timings are not performance comparisons.

## Remaining limits

The follow-up [legacy locator recovery](2026-11-15-library-update-legacy-locators.md)
reconstructs old external download locators from a verified saved full input.
Partial inputs missing an older artifact and missing/ambiguous saved data still
need an explicit repair path. Additional compressed/packed history modes,
same-name content changes without index metadata changes,
network/missing-drive timing, large-collection performance and final production
packages remain open. The tests use small private fixtures and do not exercise
PPMd/solid compression performance or a physical disconnected disk. No user
library, Desktop installation or GitHub release was changed.

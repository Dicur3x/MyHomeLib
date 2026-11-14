# Sizes in a published compressed copy

Local beta-14 work following `cec09be1`. This is distinct from the full index
refresh fix in `c0f8e020`: the old full-copy publisher never wrote the measured
output sizes to its cloned catalogue, personal cards or alternate locations.
No Desktop replacement or release publication is part of this check.

## Reproduction

`packed-sizes-Win64-baseline-r39` exercised the actual
`TCollectionPackingSnapshot.Prepare/Pack/ApplyPrepared/RegisterNew` path with
large illustrated FB2 and EPUB books. Before the fix, the readable FB2 had
116,392 bytes, but its published catalogue still contained 1,230,714 bytes.
The failed native output is retained in the external build cache.

Baseline fixture SHA-256:
`fb9ff6ab6ce84b81e698710f7eedab1eef93931b6e50594533e09491c2020512`.
Build log: `CompressionRecovery.local-Win64-5734e449bba4.err`.

## Change

The prepared locations database adds a nullable `book_size` column. The Packer
uses the measured payload size for ordinary processed books and recovers that
measurement from its journal when retaining a previously published archive.
Retention still validates immutable output artifacts and exact member locators;
it does not need the original source archive.

JPEG XL records the complete book size separately from the smaller storage
surrogate. Historical JPEG XL entries without that measurement and unchanged
opaque/FBD payloads without per-book measurements return NULL. Native publication
preserves their previous size rather than substituting an archive/surrogate size
or zero. Old five-column prepared databases remain readable.

`ApplyPrepared` rejects negative and noninteger sizes before applying locations.
It writes measured sizes to the disposable catalogue, its personal snapshot and
alternate copies in their existing transactions. Source books/catalogues and
personal fields are unaffected. Registration remains a separate final step.

## Checks

Exact local BookProcessing packages are in
`G:/HomeLibRu-build-cache/HomeLibre-post13-legacy-history-20261114/packages-r40`:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 12,446,036 | `8ff00a1039587e68ff3ca4982f933c3f28292fb79ca2a03ee584b71eecdbd121` |
| Win32 | 11,186,663 | `8659919d41ffc8289c5834bb083e1fb445aa717382ae734520ca7de79a65ddd8` |

The full 53-case Packer suite passed without skips on each architecture using
its private packaged runtime: Win64 `packer-sizes-Win64-r42`, 160.703 s;
Win32 `packer-sizes-Win32-r45`, 159.078 s. Both temporary runtimes were removed.
These cases include real 7-Zip packing, retention, FBD/opaque/loose files,
illustration changes, DjVu, interruption and JPEG XL PDF reconstruction.
JPEG XL codec output in the PDF case is simulated; it does not establish real
encoder/decoder compatibility. The added assertions verify logical PDF sizes,
historical missing-size handling and measured illustrated-book sizes.

The initial suite launch `r41` captured the test module before its private
runtime environment was set. Its errors/skips are not a product regression.
The wrapper now imports synthetic fixtures lazily, after environment setup.
The first native prototype `r43` also exposed that SQLiteWrap's open-array
binding does not accept Variant parameters. The implementation now uses a
validated Int64 SQL literal for the optional size assignment. `r44/r46` stopped
on a fixture precondition: a personal card had not yet been created through
ordinary group membership. The final fixture explicitly seeds that card.
`r47` caught another fixture setup error: each compatibility copy needs a
distinct collection name. `r48` completed all native checks, but its independent
Python read needed an explicit binary collation for the numeric fixture LibIDs.
These setup/observer failures remain recorded; none is counted as a final pass.

The new native scenario also checks NULL/legacy mapping compatibility,
negative/fractional-size rejection, alternate and personal sizes, progress and
review preservation, and an actual INPX update after hiding the owned original
archive. Its external wrapper checks output book sizes/content independently.

Win64 `packed-sizes-Win64-r49` passed in 21.703 s. Both published catalogues
contain the actual 116,392-byte FB2 and 87,477-byte EPUB. The wrapper checks
their retained bytes, non-image content and alternate-copy sizes independently;
native checks also cover the personal card, review and 37% progress. The source
archive was hidden during the real INPX worker and restored afterwards. The
private runtime was removed.

Win64 fixture SHA-256:
`ab9ec75b1b6031d4917c581aec0134ff1e4271eec0acb882f0d7950f0a84accd`.
Build log: `CompressionRecovery.local-Win64-054338ac16c7.err`.

Win32 `packed-sizes-Win32-r50` passed the same complete scenario and independent
checks in 20.344 s, with identical book sizes. Its private runtime was removed.
Fixture SHA-256:
`cdf5ebd0c84504ba0a7013e1c26452f1854f408e94fc9acd876580f444d2bc65`.
Build log: `CompressionRecovery.local-Win32-bb7efb0e0800.err`.

Both fixtures include the current publisher and INPX worker; these are actual
application code paths, but this scenario invokes them directly rather than
driving the full compression/update windows. Previously passed operation and
recovery suites were not rerun or counted as part of these 53+1 checks.

## Remaining scope

This does not close the entire compression objective. Ordinary-window legacy
FB2/FBD updates, separate image/cover handling, component-install continuation,
bounded user-data copies and final application/distribution checks remain.

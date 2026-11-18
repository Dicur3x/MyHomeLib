# Repeated publisher placeholders in standalone packed collections

## Reproduction

The ordinary collection wizard imports six ZIPs containing the same member
name, with a different body in each archive. The publisher supplies two blank
IDs, two zero IDs, and two identical opaque IDs. Packing preserves all six
members. The test removes one card from the packed copy and then hides the
original directory. The incoming full index adds one book and has a correction
for a second book whose new archive will arrive later.

On Win64 the original review reported two changed titles and two needed
archives for INPX. For a real Metabib JSONL written by the application it
reported all seven records as new and requested six archives. Both runs
stopped during preview before applying anything. The receipts are
packed-placeholder-ids-Win64-r1896-inpx-baseline and
packed-placeholder-ids-Win64-r1897-metabib-baseline.

## Comparison and preservation

- A blank, zero or opaque publisher ID uses an artifact key from the
  publisher's original archive locator and member name/extension. A known
  positive numeric ID follows its existing identity rule. The packed file's
  physical path and the catalogue's local numeric BookID have separate roles.
- The saved publisher locator takes precedence over the historical mapping
  from an INPX ZIP name to its local 7z. A Metabib locator retains its literal
  archive name. A legacy packed snapshot can also use its verified source map.
- Existing cached exclusions move to the new key only when they identify one
  prior artifact. An ambiguous historical exclusion stops review. A pending
  replacement keeps the old readable body until the archive is delivered.
- A matched catalogue card keeps its prior LibID when the incoming format
  represents an unreliable ID differently. Its publisher metadata, pending
  payload flag and source cache keep the comparison consistent on repeat.

## Native evidence

The current packed-placeholder-ids tests enter through the ordinary source
window for the first application and then apply the late delivery. The cases
check the exact requested archive, stable IDs, each actual body, the excluded
card, ratings, progress and notes. Repeat review has no pending changes.
The original packed archive names and hashes are pinned before publication of
any generation. An independent logical comparison protects the original
catalogue schema and rows, with only the documented selection and filter
settings saved by the window excluded.

The old-exclusion fixtures rewrite the cache in the private test profile to
exercise both a uniquely attributable key and a key shared by two archives.
The paired controls cover positive-ID standalone INPX, Metabib with a manually
selected prior full INPX, previous INP-in-ZIP packages and bound packed updates.

Both ordinary applications and both test programs built successfully. All 16
native runs passed, with 130 markers and 704 verified build inputs.

The full receipts and source binding are in
G:/HL-b14-external/packed-placeholder-final-r1904/summary.json.
The fixtures use small generated archives and private G: profiles.

# Preserve deletion of retained cards after a missing replacement

A full update could retain an old card when its changed archive member was
unavailable, then forget a later user deletion when that member appeared.
The ordinary native fixture reproduced resurrection before the fix in
`update-retained-before-Win64-r360`.

## Implementation

Availability now distinguishes `missing` (not yet added from this source) from
`missing-retained` (the source already had a live card/copy). Removing the
latter card or source link records an exclusion even while the file is absent.
Both pending states are rechecked on subsequent full or append updates.
The cache keeps a retained copy's actual path instead of replacing it with
an unavailable raw index locator.

Source ownership is captured before matching another source's preferred card.
An unavailable new copy does not create a phantom link merely because a shared
card exists elsewhere. An unavailable existing copy keeps its metadata and
location; its changed row is not applied to another preferred copy.

## Native evidence

The full-application fixture checks:

- Ordinary full update: keep old metadata/personal fields when a replacement is
  missing; delete that retained card, update again while absent, restore the
  archive and update again. The deleted card stays excluded, while a separately
  never-added member from the same index is added and reads its correct body.
- A preferred card from another bound source: a missing new copy creates no
  phantom link; downloading it adds exactly the second copy without replacing
  the preferred path, rating or progress. After a changed copy becomes missing,
  removing only its source link remains an exclusion when the ZIP returns.
- External 7z downloads in ordinary full, bound full and bound append updates:
  retained metadata/path/personal fields, deletion while missing, restoration,
  another readable download and unchanged archive hashes.
- The existing rollback, offline-root, two-profile, omission, legacy INPX/Metabib
  locator recovery, cancellation and scratch-cleanup cases in the same run.

The added two-source fixture initially used different titles (`Preferred 208`
and `New lower copy 208`). Runs r363/r365/r367 correctly did not combine those
identities, so that failed copy-count assertion was invalid. The fixture now
uses the same title for the shared card; identity matching was not loosened.

| Platform | Licensed IDE build | Final native run | Result | Seconds |
|---|---|---|---|---:|
| Win64 | `update-retained-final-Win64-r368` | `update-retained-final-Win64-r369` | PASS | 338.266 |
| Win32 | `update-retained-final-Win32-r370` | `update-retained-final-Win32-r371` | PASS | 336.734 |

Binary SHA-256:

- Win64: `a04fa0e2cac087c19818054f765ce2be669d4e75f13fe24d60996a8cec3264e2`.
- Win32: `646c765e35b33d5a3e20a1fe5cda50be609f8bafd2b5b4d891a413a5054a0993`.

All successful private runtimes were removed. Parallel timings are not speed
comparisons. Aggregate receipt:
`G:/HL-b14-external/update-retained-validation-r372/summary.json`.

## Limits

The new distinction cannot reconstruct user deletions before an authoritative
history existed, or retroactively prove the provenance of an old ambiguous
`missing` record after its card was already removed. These small fixtures do
not prove production-scale timings or packed/online catalogue application.
Final packages, Desktop replacement and the beta 14 release remain open.

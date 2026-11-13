# Selecting new collection books for compression

Local beta 14 work, continuing `bf02664a`. No Desktop or published package
is replaced by this milestone. Automatic offers after INPX, Metabib or file
import are still a separate, incomplete step.

## Behaviour

The catalogue has a separate **Сжать новые книги…** command. It retains the
collection's quality, grayscale, review and backup preferences. Selecting a
new quality or engine can make previously checked books eligible again.
The ordinary whole-collection and selected-books commands retain their
existing behaviour.

Candidate selection removes previously checked members from the private,
disk-backed operation plan. A match requires the physical source key, member,
quality, grayscale choice, actual engine identity and current source identity.
It uses the catalogue read-only, does not change personal data and does not
depend on imported integer BookIDs. A collection without inspection history
retains all available books for its first check. New archives are eligible;
changed archives are checked again while existing per-image history protects
already processed neighbours from repeated lossy encoding.

If no books remain, the normal result explains that no new books were found.
It does not start the encoder, create a replacement job or add a backup.

This command is **metadata-based candidate selection**, not a byte-by-byte
integrity scan of every archive in a multi-terabyte collection. It can skip a
file whose bytes were changed externally while its recorded identity, size
and timestamp were deliberately preserved. The full **Сжать текущую
коллекцию** command still verifies the packed SHA-256 witness; candidates
selected for physical replacement keep the existing identity/content checks.
Do not describe the quick selection as full corruption detection.

## Scratch transactions and interruption

Editing a sealed plan temporarily opens only its owned SQLite scratch file
for a transaction and seals it read-only again. Cancellation rolls back that
transaction. The generic SQLite constructor enables WAL; this editing path
explicitly selects DELETE journaling before starting its transaction.
Recovery recognises owned rollback journals and the WAL/SHM files that can
remain if the process stops between opening SQLite and switching modes.

Cleanup still requires the exact owner marker, its GUID directory and an
allowlist of ordinary metadata files. A live lease, a foreign file or an
unmarked directory prevents deletion. It is not a recursive cleanup of
arbitrary paths or user books.

## Native checks

Stage: `G:/HomeLibRu-build-cache/HomeLibre-post13-incremental-selection-20261113`.

- `incremental-Win64-operation-r1`: 41 cases, one failure. The new-archive
  test incorrectly required personal SQLite file bytes to remain identical
  after its normal first writable open switches journal mode to WAL. The
  corrected assertion compares every personal table and value, keeps the
  old archive byte-exact and checks the new archive's result.
- `incremental-Win64-arrival-r2`: corrected new-archive case passed; personal
  values were preserved. The earlier failing report remains unchanged.
- `incremental-Win64-operation-r3`: **46 passed**, no failures, errors or
  skips; 154.125 seconds including setup. The fresh private runtime was
  removed. Current operation SHA-256:
  `c84cb7a11627b95a3b35657d6c536f838bc208700ea68c403f4928cddad8a76f`.
  Planner SHA-256:
  `531285b7259288fb3844ec84852a1315ea9ed66b69474b3400d6169eebf85429`.
- `incremental-Win32-operation-r4`: **46 passed**, no failures, errors or
  skips; 178.578 seconds including setup. The fresh private runtime was
  removed. Current operation SHA-256:
  `472749cfdb74be9ccf76c3996a113b6c362da3642d7e111b60c42c974b3e32f4`.
  Planner SHA-256:
  `81851a02fafae6ff520718010303ed81aab257047476c944104b476ebad97751`.

These cases include no history, no arrivals after completed compression,
a newly imported archive, timestamp-only changes, reimported BookIDs,
changed quality, retrying a failed member beside a successful one, and
scratch rollback/process-loss cleanup guards. Existing normal operation,
cancellation, recovery, catalogue/personal and neighbour checks remain in
the same run. Exact packages and helper identities are recorded in the JSON.

`gui-Win64/catalogue-Win64-apply.json` passed the ordinary catalogue menu
and controls on a synthetic shared ZIP: 1,288,077 to 127,560 bytes. Text,
images, the unselected neighbour, backup, current row/cache refresh and
personal reading progress remain covered by the existing assertions.
The second invocation uses the actual **Сжать новые книги…** menu item:
it reports two previously checked books, runs no producer and creates no
second backup. The archive stays byte-exact. The fixture includes five
intentionally unavailable unrelated book records; their warnings remain
visible in the result, rather than being counted as newly compressed books.
The whole two-operation GUI test took 39.609 seconds and removed its private
runtime. Catalogue fixture SHA-256:
`1678ff33022a1df3888fdec3aa844628ab415903da8e89ad5c0da46c5c976a08`.

`gui-Win32/catalogue-Win32-apply.json` passed the same complete two-command
scenario, with the same source/output sizes, no repeated producer or backup,
personal progress preserved and its private runtime removed. It took 37.594
seconds. Catalogue fixture SHA-256:
`044e2391587ee53479b57705c861446096ccb5e3855b407f67b0d6ba997af913`.

Both are ordinary menu/control checks on private synthetic books. These
fixtures do not prove an automatic import offer, production packages or
their update path; they do not operate on the user's real collection.

The first catalogue fixture build (`026a94eb4ebc`) failed in the newly added
test: Delphi's `TCaption` does not support the string helper used by its
assertion. The assertion now uses `Pos`; no product safety checks were
relaxed. This failed build is retained separately from completed runs.

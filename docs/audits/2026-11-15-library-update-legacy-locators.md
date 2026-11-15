# Recover old external download locators from the saved publisher input

Older applied snapshots can contain absolute download locations outside their
original source root without the separate publisher-location table. The current
review can reconstruct those locators from the saved input instead of guessing
an archive's relative directory from its basename.

## Implementation

The history reader exposes the saved input SHA-256 while preserving its existing
three-argument API. Recovery runs only for applied history with unmapped external
archive rows. New snapshots whose publisher-location metadata is complete do
not reimport an old input. Connected sources without applied history retain the
existing comparison path.

The input must be beside its applied cache, exist and match the recorded hash.
A read lease prevents writes while hashing and importing it. An isolated native
worker reads INPX or Metabib according to the **old file's** format, independently
of the new profile input, into a private scratch catalogue. It preserves raw
archive names and does not change the applied cache or book archives.

The compact recovery map records artifact identity, metadata stamp and publisher
locator. Conflicting duplicate mappings are marked ambiguous. An affected old
row must match a unique record and its metadata; otherwise the review fails
before applying live changes. Names are not guessed from a matching basename.

The helper uses the parent's SQL cancellation/space callback and disables it
while rolling back its private transaction. Row checks also propagate stopping
and space failures. The large scratch database is released after extracting
the map, before showing confirmation; the review destructor retries cleanup
of any owned remainder.

## Native evidence

The full application fixture adds three variants:

- An ordinary modern catalogue with an original root and earlier download root
  unavailable, with a new book arriving in a third root.
- A bound source with the old publisher table removed and a saved full INPX.
- The same legacy layout after a full Metabib update, followed by a new INPX.

It verifies exact new members, retained personal fields, exclusions after an
omitted record, a repeat update and reading old books when both private roots
are reconnected. Original and previously downloaded 7z hashes are unchanged.
Negative cases alter the saved input and inject cancellation inside the native
old-index reader; both leave the live catalogue revision unchanged.

The final fixture additionally checks immediate scratch cleanup before apply
and absence of private catalogue/comparison files after each review closes,
including failed and canceled reviews. It simulates unavailable directories
using private files on G:, not physical disks or real user libraries.

The new cleanup assertions first failed on both architectures
(`update-publisher-cleanup-Win64-r351`, `Win32-r353`): clearing the explicit
scratch and iterator references still left the catalogue file open. Import and
mapping now run in a separate procedure scope, so all of their interface
temporaries finalize before scratch-file deletion. The same cleanup also runs when import or mapping fails.

Final licensed IDE builds:

- Win64: `update-publisher-cleanup-Win64-r354`,
  `082a65e363d44026386dd626bf52485f341476b76e39a44be17daa2cabdb1dca`.
- Win32: `update-publisher-cleanup-Win32-r356`,
  `16495237f06a619c3b7edba62ff2813a71e1633518e26ff45b6fcd0c81974ad3`.

| Platform | Final application run | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-publisher-cleanup-Win64-r355` | PASS | 218.860 |
| Win32 | `update-publisher-cleanup-Win32-r357` | PASS | 217.954 |

Both runs retain the previous whole/bound, offline-root, shared-profile,
exclusion, missing-member and late-error rollback fixtures. Their owned runtimes
were removed. Timings were collected in parallel and are not performance
comparisons. Aggregate evidence is in
`G:/HL-b14-external/update-publisher-cleanup-validation-r358/summary.json`.
Earlier gates r344/r347/r349 passed before the cleanup assertions and are not
used as proof for immediate cleanup.

## Remaining scope

A saved partial package may not contain an older artifact present in its
accumulated cache. Missing, changed, ambiguous or insufficient saved input
cannot prove that old locator and causes an explicit review failure. Recovery
from earlier full inputs / retained generations and the repair UX remain open.
This is a migration path with a temporary full metadata import; production-scale
memory, workspace and timing still need measurement. It does not read or unpack
book contents for the locator map.

The follow-up [retained missing-card regression](2026-11-15-library-update-retained-missing.md)
reproduced and fixed resurrection after deleting a retained card while its
changed file was unavailable. New pending copies and retained copies now have
separate availability states; the follow-up includes both architectures.

The complete source feature and beta 14 release remain open. No Desktop
installation or GitHub release was changed.

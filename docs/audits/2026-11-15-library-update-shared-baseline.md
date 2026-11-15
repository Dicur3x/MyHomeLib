# One applied baseline per bound source

When two update profiles target the same source, switching back to the older
profile used its stale per-profile baseline. A removed book could then return;
an append update could also publish a cache missing books and exclusions learned
through the other profile.

The native pre-fix run `update-shared-baseline-before-Win64-r311` reproduced
the returned book after an intervening index omitted it. It is not a passing
gate.

## Change

Bound updates now load the latest applied history for the permanent source ID,
independently of the selected delivery profile. Existing version-1 histories
with multiple per-profile entries are read from the most recently appended
entry. A committed save consolidates that binding into one authoritative entry.
Unbound profiles retain independent histories. Rebinding a delivery profile to
another source retains the old source's applied state.

A missing authoritative cache is an explicit review failure. It cannot silently
fall back to a stale profile, an unmerged candidate or the live catalogue and
forget exclusions. Immutable older cache files are not overwritten or removed.
Profile removal does not erase the source's applied baseline.

## Verification

The extended ordinary/bound update fixture includes two profiles on one source,
an intentionally old multi-profile JSON history, deletion followed by publisher
omission, profile removal, an append through the older profile and a later full
index. It checks retained titles, personal fields, correct archive members,
exclusions from both histories, the old cache hash, refusal of a missing latest
cache and a transactional profile rebinding/rollback. Earlier update cases still
exercise priorities, missing members, repeated indexes and final-save failure.

Fresh native build receipts are `update-shared-baseline-build-Win64-r312` and
`update-shared-baseline-build-Win32-r314`:

- Win64: `5e9895674585f4d297892558e1658b2590dcc4c376ed544e185275e03ccf2b02`.
- Win32: `4967a43e2b8df2c6d2eadce9b7bbf189e470142455b3924dc97ca135edc2c546`.

Passing application gates: `update-shared-baseline-Win64-r313` and
`update-shared-baseline-Win32-r315`.

Both final binaries also pass a real bound-source process termination after the
catalogue commit and ordinary startup rollback, preserving later personal data
of another collection: `update-shared-recovery-Win64-r316` and
`update-shared-recovery-Win32-r317`. All four passing runtimes were removed.
These are small private ZIP/INPX fixtures; no production-scale timing or Desktop
replacement/release is implied.

The older unmerged-source ambiguity, unavailable original root, remaining
catalogue modes, legacy delivery and the other release requirements stay open.

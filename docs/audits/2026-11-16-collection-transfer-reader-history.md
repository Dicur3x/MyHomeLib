# Physical transfer: bound Reader history identities

This gate preserves the existing Reader identity algorithm. Scoped library IDs
already have a stable history name; empty/zero IDs and unscoped numeric IDs can
depend on a relative locator or physical path. Opaque file-derived identities can
keep the same name while still needing proof that a changed physical binding
refers to the same book.

`HomeLibreReaderHistoryAliases` is an optional personal-database table. Each row
binds collection/book IDs, exact LibID, after-location SHA and current base name
to the original history name. A mapping digest is checked on lookup. It is a
recovery/integrity receipt, not protection against an adversary who can replace
the personal database and its independent operation records.

The writer uses the existing personal transaction alongside locator receipts.
It derives before-names from reviewed raw roots, including explicit copy roots,
without opening old files. Missing, not-yet-downloaded books are included in final
root publication. An existing alias survives a later move; conflicting old names
are refused without overwriting either binding. A committed missing alias cannot
be recreated from current metadata. If a catalogue final-row commit outlives its
personal transaction, reconstruction requires the independent pending roots
intent and the same final-row digest; roots-applied replay does not grant that
exception.

The optional `IReaderHistoryIdentityProvider` uses the already-open personal DAO
connection and a reusable query. Table absence is cached, invalidated with the
collection cache, and no personal connection is opened per book. All existing
`ReaderHistoryName` consumers use this lookup. Bound-note lookup accepts a moved
physical binding only with the same LibID and verified original history identity;
title matching alone is insufficient. Reader settings, bookmarks and note files
are not renamed or rewritten by the transfer.

## Native evidence

Seven methods per architecture cover placeholders, numeric IDs, opaque file IDs,
missing payloads, catalogue/personal partial commits, independent pending-intent
recovery, missing committed aliases, rehashed conflicting names and stale
identity/location lookups. Lookup itself must leave catalogue and personal
database bytes unchanged. The checks use private G: fixtures and real SQLite
transactions/process exits.

`G:/HL-b14-external/transfer-reader-alias-final-r1039/coverage.json` selects
**36 native invocations**, four expected forced exits and four expected refusals,
with no skips and no surviving private runtimes. Binaries:

- Win64 r1032: `2121b45888b8cf7fc4da569bc8faea4a104b5002b721ea78f8d26f3a2f9a08e0`.
- Win32 r1034: `3296d7552ea8d0d1724cedf2e7983288deb42b5719d3ad175bf2943112a848e1`.

The r1033 matrix remains FAIL. Its six passed methods are selected explicitly;
the seventh was corrected and rerun in r1035. That test initially updated every
alias with a shared BookID, including personal/copy bindings, with the digest of
one row, so it reached the integrity refusal rather than the intended conflict
refusal. The corrected test first checks the original digest, changes exactly
one primary full key, expects the conflict refusal, and checks every alias row
after continuation. r1036 passes all seven on Win32.

## Actual Reader gate

`CollectionTransferReaderHistoryTests.inc` runs the actual initialized personal
DAO and built-in Reader before and after a real transfer of a ZIP containing
five FB2 books. It covers empty, zero, numeric, opaque and scoped IDs. It saves
positions, bookmarks and notes using Reader APIs, removes the original archive,
reloads the DAO, changes titles, and checks reopened content, positions,
bookmark navigation, notes, direct note resolution and the books-with-notes
filter. Source and destination archive hashes must match.

The first r1040 run is retained as FAIL: its assertion incorrectly expected the
common notes list to omit bookmarks. The final test checks both entries and
finds the original note by ID. Both actual Reader runs pass and remove their
private runtime:

- Win64 r1044: 36.469 s, binary
  `d8148e8a18ca15fd84f41a2b8ae0288d12e18face6a661b4f23d55cc6f76b0e2`.
- Win32 r1047: 37.250 s, binary
  `2386c51a39e138bc078a248cd66901085690c549e24eff1c04c2a91225f0cf2e`.

The licensed IDE builds are r1043/r1045. The consolidated actual Reader record
is `G:/HL-b14-external/transfer-reader-main-validation-r1046/summary.json`;
its `inputs.json` binds 638 exact source/resource/validator files to the build
stage. An earlier snapshot attempt r1042 detected four stale uncompiled Python
copies in that stage and was not accepted; those copies were synchronized before
the final source snapshot. The actual runtimes use the verified r691 processing
packages and r653 image helpers; the test wrapper records their hashes. The
first r1037 compile failed on a test-only unsupported hash overload; after its
correction the full Main harness compiled successfully on both architectures.

Normal transfer UI/startup routing, active Reader/job coordination,
whole-operation acknowledgement, space/ownership-aware cleanup and final release
checks remain open. No Desktop installation or user library is changed by this
gate.

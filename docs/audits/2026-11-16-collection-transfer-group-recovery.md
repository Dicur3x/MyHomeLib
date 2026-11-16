# Sealed transfer groups and destination-only recovery

The collection journal now seals a prepared group and can recover all its
verified destinations without reading the old names. This is an internal
checkpoint. Source removal, a complete transfer controller and normal UI remain
open; no user library was moved.

## Binding and recovery

`SealPreparedGroup` first validates the complete group with live source and
destination stream leases. It checks each child journal against the immutable
review and the current prepared identities. It writes a new, flushed JSON proof
without replacing an existing file, then commits its file key and SHA-256 to
the parent journal. The proof binds the operation, review digest, group ID,
child names, destination identities, main/NTFS-stream hashes and native external
picture mapping. Repeated publication accepts only the same proof bytes and
file key. Interrupted unpublished temporary proofs are retained, not guessed
owned by name for cleanup.

The caller must persist the returned digest independently before source removal.
`RecoverPreparedGroup` requires that independent digest. It checks the sealed
proof and parent receipt, opens the child journals named in that proof rather
than mutable FileState links, verifies every retained destination and reproduces
the frozen resource digest. It holds destination-only leases. Removed and
retained originals can coexist; a foreign file at an old name is not read or
changed. Files already in the destination can also be checked, but this grants
no permission to remove their only copy.

Recovery does not create destination folders, copy data, rewrite its proof or
acknowledge removal/completion. It cannot reseal a new group without live source
leases. Ordinary preparation and locator publication still require their live
source checks.

## Journal opening correction

The first native read-only recovery case exposed state.sqlite byte changes even
though recovery executed no writes. SQLiteWrap's ordinary constructor enabled
WAL before the transfer journal switched back to DELETE. An optional EnableWAL
argument now preserves the existing mode when opening this journal. Existing
callers retain the default WAL behavior. The recovery case checks the complete
state.sqlite hash, rather than accepting an equivalent set of rows.

## Validation

Final licensed IDE builds, with exact staged/worktree input equality and owned
temporary directories removed:

- Win32 r834: `0ec7d653d2a071322e33ed24c7e10a1585bb934217f2b18110ed1749fbad7cac`.
- Win64 r836: `b0e95ddfbb15b2fd3e60dc0a359333e1b875bc1551d193651db9d65d773a91d4`.

All evidence directories below are under G:/HL-b14-external:

| Platform | Group recovery | Additional regressions |
| --- | --- | --- |
| Win32 | r835: 21 PASS, 572.446 s | r840: 2 PASS, 91.486 s |
| Win64 | r837: 21 PASS, 581.833 s | r841: 2 PASS, 60.485 s |

Each main matrix covers 13 new methods and eight existing locator-publication
methods, 51 native invocations and 10 expected forced exits. Additional
regressions cover one reference capture across 26 independent archive groups
and atomic location/history rollback, with four invocations per architecture.
All 110 invocations match their expected return codes. There are no failures,
errors or skips in the final runs. All owned native runtimes were removed;
summary.json files verify counts and cleanup.

New cases include all/mixed missing originals, absent old directories, native
shared-picture mappings, kept-in-place files, foreign data at the reused old
name, wrong independent hashes, changed proofs, ignored mutable child-link
substitution, refusal to overwrite a foreign proof, four sealing commit
boundaries, two consecutive recovery interruptions and refusal to reseal
without source leases. The full state/proof hashes remain unchanged during
destination-only verification. Existing cases also retain native FBD/raw
locators, catalogue forks, new personal cards, separate registrations and
preserved notes/progress.

The 26-group fixture still has identical content, ownership and one-scan
assertions. Its per-native-invocation test deadline is now 180 seconds, up from
90 after the parallel attempts below timed out; all other location cases retain
90 seconds. The final architecture regressions ran sequentially. These totals
are diagnostic/test durations, not library-transfer throughput estimates.

Initial evidence is retained: r828/r829 reached the build deadline while a
compiler-result dialog was open; r830/r831 built but its diagnostic driver
incorrectly required group_proofs before creating it. The fixed driver built
in r832; r833 exposed the real SQLite mode change described above. These are
not passing matrices. Additional parallel regression attempts r838/r839 hit
their 90-second native-operation deadlines and are not passing evidence.

## Remaining integration

The production operation registry must durably bind the independent proof,
check every catalogue/personal publication receipt and fresh live references,
record exact source-removal intent, remove only the proven original and recover
mixed groups at startup. Reader cache, final root/source/index/update-profile
publication, missing/future books, open-DAO/job coordination, space accounting,
large-catalogue checks and normal UI remain part of the same unfinished feature.

Build input SHA-256 values (byte-identical to the staged inputs):

- Program/DAO/SQLite/Lib/SQLiteWrap.pas: `3dbbc15409c40c7d65e4ce905c6ff5be14856ed28f289314b339813c1610d27d`.
- Program/Units/unit_CollectionTransferCopy.pas: `8408dc7c34aabc8308ba39593942360c6ab2c1be00d26a28cb8214dc343bb63e`.
- Program/Units/unit_CollectionTransferJournal.pas: `e08e9a062e918b166579173d0efe72833fb42dd62fca339ab2e7ff03f977b561`.
- Program/Units/unit_CollectionTransferResources.pas: `9fffc16d33ece3e1cb36b529bb2817704bbe68b795482ed8860f446dcc40599d`.
- tools/ui/tests/CollectionTransferJournalTest.dpr: `294c400fcca8f8a5c25bcf4b1525bec464526408b832f43bccb9e8d457841a6e`.

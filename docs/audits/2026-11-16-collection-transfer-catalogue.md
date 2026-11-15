# Native catalogue inventory for physical consolidation

## Implementation

`unit_CollectionTransferCatalogue` connects the native book path resolver to the
file-transfer planner. It streams primary Books, every CatalogBookCopies row
(including an extensionless/orphan copy), and personal Books for the selected
registration into indexed owned SQLite scratch storage. It copies no catalogue
database. Original locators, IDs, copy source keys, sizes and the exact source
JSON are retained without publishing any change.

The inventory distinguishes available **physical containers**, absent files and
metadata-only personal rows. An available container is not a claim that every
catalogued member exists or renders correctly. Missing books are retained for
later publication policy, rather than invented as downloaded payloads. A
missing source directory can be recorded while available roots feed the file plan.
The fixture removes an owned directory; unplugged hardware and network-offline
error codes have not been tested. Access errors still stop the review explicitly.

Source roots come from the collection and its saved sources, explicit copy
roots and separately reviewed absolute/linked locators. Native TBookRecord
resolution handles archive members, loose/FBD books and ZIP-to-7z fallback.
Extended-path existence probes also handle a long-path-unaware diagnostic host.
Container resolutions and negative ZIP/7z witnesses use bounded 4,096-entry
caches; file/row sets remain on disk. The current implementation caps logical
roots at 4,096 with an explicit error, not silent omission. Highly fragmented
loose-file roots and million-file throughput still require scale validation.

Private read transactions capture the databases. The personal transaction is
released before the main catalogue scan; its retained connection still detects
later commits through SQLite data_version. Shared metadata leases prevent
database replacement while permitting normal SQLite writes. The existing lease
implementation is unchanged and exposed through a thin interface-returning
factory. An intervening database/registration change, changed physical identity,
newly arriving missing file or changed ZIP/7z selection rejects stale preview.
Access errors and unsupported linked/hardlinked payloads are not called missing.

The planner now separates `CheckInputsUnchanged` from the original complete
preview validation. The original validation still checks free destinations;
input validation can recheck source identities/roots and external-image sets
after owned copies have been published. It does not authorize source deletion.

## Final native evidence

Licensed IDE reports preserve the original project and report removal of their
private G: temporary directories. Final runs under `G:/HL-b14-external/`:

| Run | Tests | Failures/errors/skips | Binary SHA-256 |
| --- | ---: | --- | --- |
| `transfer-catalogue-Win64-r746` | 26 | 0/0/0 | `343dcdd7fd0ccaf431ec141692d60338520b63d269fbaa732ba00af1385868eb` |
| `transfer-catalogue-Win32-r748` | 26 | 0/0/0 | `ada983a369b793dce6345ad918221f284c2feb338508247dacedc50a0653edd1` |

Builds are r745/r747. Fixtures use the application's actual collection/system
SQL resource schemas, with its custom collation/functions registered for Python
fixture creation; alternate-copy/source-link tables match native DAO DDL.
The compiled diagnostic uses the normal application TBookRecord path/stream
implementations and a private initialized settings data module. It borrows no
UI-owned database connections or user catalogue.

Cases include primary/copy/personal rows, untouched other-registration data,
metadata-only rows, source JSON and stable keys, missing directories/all-missing sources,
legacy catalogues without source properties, FBD, linked loose archives,
extensionless orphan copies, absolute merged locators, real 7z/FLibrary sidecar
inventory, Unicode paths over 300 characters, duplicate source IDs, registration
and database changes, payload changes, path escapes, arrivals of missing files
and alternative containers, cancellation and 6,000 repeated archive rows.
Those repeated rows yield just three candidate paths; this is not a million-row
performance benchmark or a promise of arbitrary directory counts.

Two cases per architecture actually run catalogue capture -> native file plan
-> verified whole-file copies -> native book reading. Before/after book-stream
hashes match for four bindings in ordinary ZIPs and four in mixed ZIP/7z files:
eight pairs per architecture. Complete source/destination archive hashes also
match. The reader uses PreserveWebP=true and RestoreOriginalImages=false; this
does not prove external-image restoration or lossy recompression. Only private
fixture files are copied and native locators are projected **in memory**; no
catalogue locator is published. A separate case creates a sidecar after copying
and confirms the input witness rejects it, preserving the original databases
and archives. All final private runtimes were observed removed.

The large-scan concurrency probe successfully commits a personal rating through
a separate connection at row 4,096, preserving its note and progress, then sees
the intended stale-capture rejection. This proves that the personal read lock
was released before the catalogue scan; it is not a full UI responsiveness test.

The planner's existing 17-case x86/x64 suite is rerun separately after the
validation split; the corresponding final reports are r750/r752. Its inputs,
collision handling and scratch cleanup retain their original tests. These are
regression checks, not additional catalogue-publication evidence.

| Planner regression | Tests | Failures/errors/skips | Binary SHA-256 |
| --- | ---: | --- | --- |
| `transfer-plan-Win64-r750` | 17 | 0/0/0 | `cb94edebb56672b037022e98bf8a6f5858411b3ddc10e9df949714ba463ec7b5` |
| `transfer-plan-Win32-r752` | 17 | 0/0/0 | `78d2bf86e21a60967c4e9f8b4ef90fc0a56ae8f6a49eb8e34f951d5928ae99b3` |

These regressions also observed removal of all private runtimes and scratch
stores. No new payload-copy implementation change required repeating the earlier
50 single-file interruption/ownership checks.

Staged/worktree source bytes were compared before final builds:

- Catalogue unit: `a721f121160a9f622f35d8e659d4afaa18743ee028a6660a47821476189f8bd7`.
- Planner: `236d466b97256eef632a1d6ffa585709ff3ea44320dbf497a998e63851215415`.
- Receipt unit, only the new lease factory:
  `56f4baaaa8ad7975782ac3bbb10a8b590f5f52699d30ad3da76e12a32ff63239`.
- Diagnostic DPR: `9d0ffd4c9340467b30ccb581627826d706f222a5f5d4b76e784fc27c4ed7698e`.

## Earlier failures and reserve event

r734/r736 compilation failed on missing imports and the private lease type;
the final code imports the required units and uses the shared lease factory.
r738's three tests failed because the diagnostic had not initialized its private
DMUser settings module; that fixture setup is corrected. These are not passes.
The intermediate 18-case r740 run passed before cache/read-lock refinements and
the added integration cases. It does not replace the final 26-case runs.

r735 did not launch the IDE because C: was below the 8 GiB guard. A subsequent
observation showed about 5.6 GiB, then about 13.9 GiB; the cause was not established.
No other chat's files were touched. Final catalogue runs ended above 13.8 GiB
free. All new output, profiles, copied fixtures and temporary storage are on G:.

## Still open

This adapter reviews one registration. It is not the durable all-registration
inventory or group publication ledger. Still required: missing/future locator
mapping, default-root and per-source update-profile publication, shared-database
registration handling, connected sidecar groups, transactional path changes and
markers in all affected catalogues/personal data, compression-history/cache
rebind, proven source cleanup and recovery after source removal. The coarse
preview data_version guard must not substitute for publication-time row checks
which preserve concurrent notes and reading progress.

No physical transfer command is enabled. Real-library throughput, final Main/
Reader builds and visible workflows, Desktop replacement and beta 14 publication
remain open. Compression package candidates are unchanged (`packages-r691`).

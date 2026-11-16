# Independent transfer registration and transactional group proofs

`unit_CollectionTransferRegistry` registers a verified physical-transfer journal
and its sealed group digests in the personal database. This connects group
recovery to durable production storage rather than the fixture control JSON.
It remains an internal operation building block: ordinary startup/UI, source
removal, final roots/profiles/cache publication and completion are not enabled.
No user collection was changed.

## Recorded state and recovery

HomeLibreTransferOperations binds the operation ID, immutable review SHA-256,
exact journal/work/destination paths, selected collection ID and personal-file
identity. HomeLibreTransferGroupProofs stores each group's independent digest.
Existing mismatched registrations or digests are refused rather than repaired
from mutable child state. Creation and updates use FULL durability and write
transactions; source-removal authority is deliberately absent.

Read-only discovery does not create tables or probe the work/destination volume.
An unavailable work folder therefore does not erase the pending operation.
Resume obtains the saved external review digest from the personal store,
reopens the independently verified journal and checks its immutable context
against that registration. A byte-identical copied personal store has another
file identity and cannot silently adopt the original jobs.

RecoverGroup obtains its proof from this independent table and calls the bound
group verifier. It does not require the fixture control file, original archive
names or original external-picture archives. It does not recreate that file or
publish locators/remove originals/mark the operation complete.

## Atomic publication and reference cache

PublishPreparedGroup seals the source-held prepared group, then stores its
independent digest in the same personal transaction as the location receipt.
The existing publication session supplies that exact SQLite connection. The
catalogue commits retain their existing recoverable multi-database order.
Cancellation before the personal commit rolls back both personal locators and
the independent proof; after commit they survive together.

This also avoids an observed regression in the initial standalone integration:
a separate personal-store registry commit between archives invalidated the
reference snapshot on every group. No post-commit data_version acknowledgement
was added. Own transactional registry writes leave the session's existing
connection semantics intact, while external catalogue/personal commits remain
visible. Standalone RememberPreparedGroup remains available when no location
publication is requested; it grants preparation recovery only.

## Builds and tests

Final licensed IDE builds use an owned sibling test project on G: with separate
Registry output/DCU paths. It uses the same main source, search paths, checks and
production units; it avoids replacing binaries still used by the initial
matrices. Both projects remain unchanged by the IDE and their temporary
folders are removed.

- Win64 r848: `9a6732d12d597aa54ee058f2a91e7ac0650ccbc448b7719bf024511157543179`.
- Win32 r849: `f15e30d237bc9a7fe03fe1a25411751a1ace213cc13b8d6d234188bdce6834bc`.

All runs below are under G:/HL-b14-external; their summaries validate expected
return codes and the absence of successful owned runtime folders.

| Platform | Main matrix | External changes | Preparation only |
| --- | --- | --- | --- |
| Win64 | r850: 21 PASS, 728.522 s | r852: 2 PASS, 78.033 s | r854: 1 PASS, 15.321 s |
| Win32 | r851: 21 PASS, 626.582 s | r853: 2 PASS, 78.464 s | r855: 1 PASS, 15.538 s |

Each architecture has 24 distinct covered methods: the main matrix's 13
registry/session cases and eight existing locator cases, two external-write
checks and a positive standalone-preparation check. There are 52 native
invocations per architecture, including 10 expected forced exits. All 104
return codes match expectations; final runs have no failures, errors or skips.
These are diagnostic durations, not a transfer-throughput benchmark.

The main matrix verifies pending fields and exact sealed hashes; read-only empty
and populated discovery; lost control/originals with two recovery interruptions;
shared native images; copied personal-store identity refusal; changed/missing
independent proofs; mismatched operation registration; unregistered proof
refusal; canceled personal commit; both boundaries of operation/group commits;
unavailable work-directory discovery/refusal/retry; and one full reference
capture across 26 registered groups. Cancellation/boundary observers require
personal location receipts and independent proofs to survive or roll back
together. Existing notes, progress, FBD/raw locators, new personal cards,
separate registrations, forks and cross-database recovery remain covered.

The additional external-write checks prove two reference captures after real
personal-note and catalogue-title commits on other connections; the new edits
survive. Standalone preparation stores both proofs without publishing any
location receipt or changing the original book folder; destination-only
recovery then performs no copy and leaves the personal-store bytes unchanged.

The initial standalone-registration version passed 20 methods on each
architecture (r846/r847). Those results do not cover the later transactional
integration or its one-capture check. r844 retained a fixture cleanup error:
Python's sqlite3 connection context committed but did not close its handle.
The fixture now closes all connections explicitly. Automatic approval review
rejected cleanup of the remaining positively identified directory
G:/HL-b14-external/transfer-registry-Win64-r844/HomeLibRu-native-4v2xxger with only
"blocked by policy"; it was not retried through another mechanism. r842 built
the preceding driver after a failed preparation assertion and is not registry
validation evidence.

## Remaining whole-operation work

The normal controller must register before transfer work, find and reconcile
pending operations at startup, coordinate open DAO/readers and other jobs,
check every publication receipt and fresh live reference before cleanup,
persist exact source-removal intent and remove only the guarded original.
Registry proof presence by itself never grants removal permission. Final
roots, missing/future locators, update profiles, Reader cache, space accounting,
cleanup, large-library trials, UI and release gates remain part of the goal.

Exact final build input SHA-256 values, matching staged bytes:

- Program/Units/unit_CollectionTransferRegistry.pas: `e4bef20c2db6b1083a17a2efe8d7035384a759e077fa7bf33f2c86c2bf568ad0`.
- Program/Units/unit_CollectionTransferJournal.pas: `e21f82f4270db9bb1ae681027d3b9bd72075dea93875b74607c2c6a6f11b643d`.
- Program/Units/unit_CollectionTransferPublication.pas: `9f5e54470dab8e298f5ff1a1932df1e7feca562add50d8c7b98f2c1809ebdf39`.
- tools/ui/tests/CollectionTransferJournalTest.dpr: `42feef23d73a9f38e741168b713175c2f5ea639ae2ccb13cc21ec7ecc4427fad`.

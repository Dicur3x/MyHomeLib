# Durable preparation of connected transfer groups

## Scope

`unit_CollectionTransferJournal` persists the reviewed file layout and native
catalogue bindings independently of mutable progress. It prepares connected
archive/sidecar groups through the existing verified single-file copier.
It does **not** publish catalogue paths, rebind compression history, remove
originals, discover jobs at normal startup or mark a move complete.

The immutable `review.sqlite` captures the selected registration, database file
keys, raw/expanded default roots, exact source JSON, original row locators,
physical file identities, destination mappings, image sets and negative file/
ZIP-fallback witnesses. It is sealed under a read lease and SHA-256. Resume
requires that digest from an independent caller-owned record; a value read from
the mutable progress database is not sufficient. The ordinary application still
needs to save that record and provide the recovery/conflict workflow.

Mutable `state.sqlite` uses DELETE journaling and FULL synchronization. Its file
ID is bound into the frozen review. An exclusive parent lease and pinned work/
destination directories exclude a second owner and detect directory replacement.
The review is opened read-only and denies ordinary writers while in use. Unknown
files are retained; no recursive operation-directory cleanup is performed here.

## Group decisions

- File and binding sets stay in indexed SQLite storage. Connected components are
  computed with an on-disk parent table and path compression, not a whole-library
  object graph. Two book archives sharing the same covers/images archives form
  one group. The prepared result retains read leases for the current group only.
- The child journal reference is committed before child payload preparation.
  A crash after child creation but before linking may leave an unreferenced
  metadata-only child. Resume creates a fresh child instead of adopting or
  deleting unproven contents. A child's expected source/destination/identity is
  always supplied from the frozen review, never from its mutable path alone.
- Resume rechecks the original sources and ready outputs. Complete child
  receipts must agree with the parent receipt; forged hashes, escaped child
  names, a different state file or a changed review are rejected. Prepared
  payloads resume without recopying; they are still originals-retained copies.
- All expected group files must be prepared before its `prepared` state is
  durable. Original image sets and negative archive witnesses are checked again.
  Arrival of a previously absent ZIP/7z or picture archive requires a new review.
- Live primary/copy/personal locator fields, source JSON, registration and
  database identities are checked before and after preparation. Notes, ratings,
  reading progress and unrelated fields are not restored from old snapshots.
  Deletion of an optional old personal card is not undone. These read-only
  preconditions are not a substitute for checks inside future publication
  transactions or discovery of new personal rows/references.
- The group result retains source/output leases for the subsequent publisher.
  `prepared` never means published or safe to unlink. `PendingGroup` remains
  nonzero even when every copy is ready; no completion transition exists yet.

System-drive reserve (8 GiB) and work/destination margin (512 MiB) are checked
during planning/hashing/preparation. The existing copier additionally checks
space for all source streams before and during copying. The application must
still present complete per-volume estimates, including retained sources and
future publication requirements, before enabling the command.

## Native evidence

Final licensed builds are r755 (Win64) and r758 (Win32), with original projects
unchanged and private IDE temporary directories removed. All paths below are
under `G:/HL-b14-external/`:

| Run | Tests | Failures/errors/skips | Native attempts / forced exits | Binary SHA-256 |
| --- | ---: | --- | --- | --- |
| `transfer-journal-Win64-r757` | 17 | 0/0/0 | 46 / 8 | `9e913cc0ee33e055377e2fba4c018623b46b2cd1c956929a70869eadb7269bee` |
| `transfer-journal-Win32-r759` | 17 | 0/0/0 | 46 / 8 | `017dd2396ed9c19b2ff562b2928b5787ec8b3cdba4371cb59a0d5c42e432b3d5` |

The driver reuses the real collection/system SQL-schema fixture from the
catalogue-adapter tests, with native path resolution and actual ZIP/7z files.
It persists a separate control record, exits, then enters journal Resume in a
fresh native process. Input catalogue/personal/payload hashes are compared before
and after every invocation. Deliberate external fixture mutations occur before
that invocation's preservation baseline, never on user data.

Cases cover a frozen six-row review with available/missing/metadata-only rows;
whole group preparation and unchanged ready payload IDs/dates/hashes on repeat;
two real 7z-signature containers sharing covers/images (one four-file component);
separate unrelated groups; cancellation; wrong digest; changed immutable review;
foreign state replacement; escaped child path; forged parent receipt; changed
live locator; newer notes/rating/progress; foreign output; a second live owner;
and newly arriving missing/alternative archives after restart.

Eight forced-exit boundaries per architecture are group-copying, child-created,
child-linked, child-prepared, file-receipt-uncommitted, file-receipt,
group-prepared and the child's rename-before-ready point. The next process
reaches prepared groups while retaining every original. Where the first file
was already verified, only the unrelated second group produces a copy event.
This includes a parent SQLite receipt update interrupted before COMMIT. It
proves recovery of that API-level boundary, not arbitrary torn-sector/power-loss
behaviour. SQLite's journal implementation is not replaced by these tests.

All final private runtimes were observed removed; requests, control records and
native outputs remain in each run's `invocations.jsonl`. The fixture is small,
not a million-file benchmark, full-library move or ordinary Main UI workflow.
Native book-stream readback was separately verified by the preceding catalogue
integration tests; this suite compares complete physical file hashes.

Staged/worktree source bytes were compared:

- Journal: `e77257cd26758739d131d11ef8a688c9496ab83e32b2a4b8af1fbbcd13bff863`.
- Planner: `394bff9673981b4be1ea975b9051aa61ee1657117e22dabf147d11f227ae7e7a`.
- Catalogue adapter: `a90aa86a2f0e486bee1f0598d30dbea15867e409a53c00d89abafb5173073dc2`.
- Native DPR: `1d43ed7c97fe30d71fc7b3e0ff648393f2ff476b627d7c502b4b303d75c8a87f`.

Initial r753 compilation failed because an anonymous visitor cannot capture a
local nested routine in Delphi. Moving component lookup into a private method
fixed compilation. r754 compiled but predates negative-witness persistence and
the final receipt-boundary hook; its binary is not assigned the final results.
The two-case r756 smoke run passed before the full matrix. Earlier evidence is
retained rather than relabelled as a final pass.

## Remaining operation work

The frozen review currently covers one registration and may retain unmapped
missing roots. The durable all-registration reference inventory, shared-catalogue
strategy, future missing-book/root mapping, publication receipts and paired
database markers remain open. New personal rows must be reconciled during
publication; saved locator checks alone do not cover them.

Compression-history and Reader cache rebind, source/update-profile/root
publication, reference/stream checks before source removal, child receipt
acknowledgement/cleanup and recovery after source removal are still required.
Preparation still needs originals to resume. The final workflow must discover
pending operations, block conflicting changes and stop safely around metadata
commits. No transfer button, Desktop replacement or beta 14 release is enabled
by this checkpoint.

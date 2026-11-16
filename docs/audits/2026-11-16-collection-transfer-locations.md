# Archive locator transactions and compression history

`TCollectionTransferJournal.PublishGroupLocations` now publishes a prepared
group's locators in its registered catalogues and personal database. It first
uses the existing catalogue-fork mapping, groups registrations by their current
physical database, and retains database replacement leases. Every database
commits its locator changes, compression-history rebind and matching
`HomeLibreTransferLocations` receipt in one transaction with FULL sync.

The coordinator is production code; the isolated diagnostic invokes it directly.
No normal transfer command or source removal is enabled by this checkpoint.

## Locator behaviour

- Validate registration roots/types, participating database keys and the saved
  row's ID, library ID, member filename/extension, InsideNo and copy source key.
  Accept old or exactly projected new locators on replay. Reject a different
  location rather than restoring an earlier user row.
- Project native archive, raw/FB2 and FBD paths, including old linked-FBD
  locators. Preserve the reading format and prove that the new native physical
  filename resolves to the prepared destination. Raw filenames with embedded
  directories are normalized without duplicating their subdirectory.
- Update only Folder/FileName and the application's normal derived search
  fields. Keep copy source keys, registration/book IDs, copy roots, notes,
  ratings, progress and groups. Unsupported references retain their original
  locators; a shared physical row is retained if any participating reference
  has an unsupported layout.
- Within the personal transaction, indexed BookID lookups also reconcile cards
  created since the immutable review for this group. Preserve their current
  personal data. The immutable core receipt remains replayable when those
  additional cards appear.
- Per-database receipts distinguish committed catalogue changes from an
  interrupted personal commit. Preparation recognizes a matching publication
  marker; the locator transaction revalidates the old/new rows on replay.
  Original archives remain available throughout this checkpoint.

## History and cache behaviour

`unit_CollectionTransferHistory` requires the complete prepared group and an
active caller transaction. It retains original-key history while adding the
new verified file keys. It transfers transformation/output history and retry
policy, restores measured-size witnesses against the copied container, and
rebinds valid inspection checks to the destination identity.

External-image stamps and snapshots use the prepared source/destination pairs,
with current target paths/identities and verified archive checksums. A source
image-set snapshot must be internally consistent and match the prepared image
archive checksums before it can transfer a positive skip witness. A stale
container/image checksum cannot become a cache hit. Timestamp-only old checks
use the same key/size plus full container hash proof as the native planner.

The generic table copier preserves extra columns and uses the actual primary
key. An existing conflicting destination-key history row aborts the transaction;
it is not silently replaced. Repeating an already committed rebind is idempotent.

## Validation

Final native matrices r794/r795 each passed all 18 history/location methods and
four prior journal/fork regression methods, without errors or skips. Each used
67 native invocations, including 16 expected forced process exits. Both successful
private runtime sets were removed; summary.json records counts and timings.

| Platform | History/location | Regression | Final binary SHA-256 |
| --- | --- | --- | --- |
| Win64 r794 | 18 PASS, 356.445 s | 4 PASS, 148.364 s | `54fe4dfb1900d8e19619c91fcc06e04173a8bc35a4accae2d4c3458cb283a25b` |
| Win32 r795 | 18 PASS, 414.791 s | 4 PASS, 86.687 s | `0518e93fc56cca9b22576d949743dcb9ecd3a067167fa65ed780b287e2175f5f` |

The tests exercise the production publisher, native compression planner cache
hits after transfer, stale-hash rejection, rollback of paths and history together,
new personal cards, raw/FBD locators, shared-catalogue forks and all four
catalogue/personal commit boundaries. Regression cases include another process
exit during recovery. Database observers compare all pre-existing content fields
apart from reviewed locator/derived-search changes and preserve input payload
hashes. These counts describe isolated fixtures, not a large-library transfer.
Builds r792/r793 use the licensed IDE AutoBuild; staged/worktree bytes match
and IDE temporary directories were removed.

Earlier r788/r789 passed 16 history/location methods per architecture before
the final coordinator extraction and new-card reconciliation. r786 reached all
native transaction/recovery paths but its metadata observer incorrectly treated
the normal MHL_UPPER(NULL) search result as NULL instead of an empty string.
r783 timed out with the compiler-error dialog open; r784 preserved the missing
`dm_user.Settings` import error, fixed in r785. Earlier evidence is retained.

Final source hashes:

- History: `43b67b5875bf80eec788f72f900d317482aebf8b9995918d977621c9abea38be`.
- Locations: `c917ca3ad1c2a7ef1e6601335d55aa7f016aa748012af7879a2d51a5abacbcb4`.
- Journal: `c80060a786fb64cb5fe64fc7064f1ab48772112b05588191cbcc7669ad4e6157`.
- Diagnostic: `ab5940d2334d7b7c3c51cef8a2c0f1cc428a63d1602dfca8e52fcdaa82205c5e`.

## Remaining whole-operation gates

This publisher consumes the saved registered-reference review. Before enabling
source removal, the controller still needs a fresh complete reference session,
change detection/reconciliation for later catalogue edits/new registrations and
personal rows referencing earlier groups, and durable operation-level intent
and completion state. Unknown or unsupported references must retain originals.

Native book/resource validation for the complete group, Reader cache rebind,
final source/index/profile/root publication, missing future roots, full stream
and live reference checks before source unlink, child acknowledgement/cleanup,
recovery after originals are removed and normal startup discovery/UI remain
open. The source database/DAO and pending-job coordination gates in the fork
audit still apply. Small private fixtures are not a full-library move benchmark
or evidence of arbitrary power-loss safety.

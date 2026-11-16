# Unpublished source-cache projection

## Implemented behavior and boundary

`ProjectTransferCache` rewrites only a caller-owned unpublished cache clone
inside the caller's transaction. It accepts the verified frozen review and
explicit old/new roots. It neither changes source/history settings nor publishes
a cache version, removes payloads, grants file-access authority or completes a
move. The normal consolidation command stays disabled.

The projector streams physical maps and cache book rows. A uniquely indexed
working path table lives on the owned clone's volume; SQLiteWrap's in-memory
TEMP default is deliberately not used for this potentially large map. Root
aliases remain bounded by the existing reviewed-root limit. Existing prepared
queries serve per-book keys/locations. There is no whole-catalogue book list.

Mappings include reviewed files, observed whole-root aliases and reviewed
unavailable addresses. ZIP-to-7z fallback requires a captured absent ZIP name.
No old filename is probed to decide its meaning after source removal. All cache
members in a moved whole archive follow it, while unlisted cache addresses stay
at their previous absolute locations if their source root changes. Native raw
subdirectories, FBD and linked opaque archives retain their format, extension,
member names and indices. No book content is rewritten.

The projector preserves existing source-key, publisher-location and review-key
overrides. It records original generated keys when a new locator would change
them. Publisher names remain separate from physical destinations. Existing
availability, exclusion and unrelated tables are not replaced. Each successful
operation/source projection leaves a marker; projecting the same clone again
with the old root is refused. Cancellation or process death before commit rolls
the clone back. Preparation retries must start from the immutable baseline.

`TCatalogSnapshot` implements an optional saved-source-key provider. The normal
merge key path consumes it and refuses a key belonging to another source. Main
catalogues do not implement this optional interface. The source snapshot owns
its indexed lookup and frees it before its SQLite connection. Library-update
review now loads and preserves `LibraryUpdateReviewKeys` for empty/unscoped IDs.
Its existing identity/publisher algorithms were extracted unchanged to
`unit_LibraryUpdateIdentity`; update cache construction retains the incoming
review key when the retained physical address differs.

## Native evidence

Licensed IDE builds have identical worktree/staged inputs (24 relevant files;
each final stage retains `native-inputs.json`):

- Win64 r937: `01183c09875498d4cdc5b7d27575c10fd35b29c5a15272226898486391269dea`.
- Win32 r939: `a07ea270decb450be67ca1e59ea5d89fd77e1bab5b28617fefe0908b15fd71f3`.

Reports are under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| transfer-cache-complete-Win64-r938 | Nine cache methods PASS, 23 native calls, one expected forced exit and three expected refusals, 90.453 s. |
| transfer-cache-complete-Win32-r940 | Same nine methods PASS, 23 calls, one expected forced exit and three expected refusals, 87.094 s. |
| transfer-cache-read-Win64-r941 | Native cache readback and existing roots-coordinator apply/replay regression PASS, five calls, 29.009 s. |
| transfer-cache-read-Win32-r942 | Same readback and coordinator regression PASS, five calls, 29.517 s. |

Ten distinct cache methods and one earlier coordinator regression pass per
architecture: 56 native invocations, two expected forced exits and six expected
refusals, no unexpected returns or skips. Every owned runtime was removed.
The durations include fixture creation and are not large-library throughput.

The cache matrix covers moved and missing files, all members of a shared
archive, preserved unlisted addresses, old names reused by foreign bytes,
offline original roots, a crash before commit, ordinary cancellation, a key
from another source, refusal of double projection, ZIP names with actual 7z
files, raw subdirectories, FBD and linked opaque archives. It compares every
existing non-key table, all non-locator book fields, preserved seeded key/
publisher overrides and native merged source-key readback. The shared baseline
cache remains byte-identical. Fixture roots moved offline are explicit private
test mutations, not part of production projection.

The separate readback case prepares real verified ZIP copies, takes both old
source roots offline and reads three complete book streams through the normal
source-snapshot/native-book path. Their SHA-256 values match the originals.
This proves native stream access, not visible Reader rendering or position
migration. The existing roots coordinator still applies/replays its settings
and unavailable locators, with the overall operation pending.

Earlier attempts remain unsuccessful in their original reports. r929 lacked
the Classes unit for EReadError; r930 tried capturing a local procedure in an
anonymous callback. r931 then compiled. r932 lacked an initialized private
system database for snapshot readback. r934 additionally exposed blank fixture
dates and WAL header writes when opening the fixture's original personal DB.
The readback now uses a separately copied private system store and valid dates;
original-store byte preservation remains enforced. r935/r936 passed the first
six cache methods; final builds additionally use disk-backed working metadata
and cover native locator variants. No licence/IDE settings were changed.

## Remaining

Durable preparation/publication of new cache versions and retained raw inputs,
independent source-history roots, partial-commit recovery, ordinary Main/Reader
coordination, post-move full/incremental INPX, large-cache space/performance
measurements and final application/distribution checks remain open. The review
key integration is compiled on both architectures, but no complete post-move
INPX update is claimed by these projector/readback tests. Old shared caches and
the user's working books, Desktop installation and public release are untouched.

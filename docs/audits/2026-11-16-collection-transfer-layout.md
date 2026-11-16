# Final-root, source/profile and unavailable-locator projection

## Implemented scope

`TCollectionTransferLayout` computes a deterministic final layout from the
owning journal's frozen review. It does not change registrations, source or
profile settings, book records, download state or completion markers. It does
not create projected folders. This is the input for the remaining durable
finalization stage, not a completed physical-consolidation command.

Available-file planning now includes every existing declared logical root,
including roots with no directly assigned book. Previously only roots with an
available candidate were supplied to the physical planner. An existing outer
root could therefore lose its shared layout with a more specific child root.
The same native canonical-root planner now handles those parent/alias roles;
only explicitly inventoried book/resource files are copied, never entire trees.

Observed roots reuse the exact planned destinations. Unavailable roots share a
known ancestor's layout when possible; otherwise an operation-specific future
folder is derived without probing the unavailable disk. Pending roots are
ordered by path depth so nested unavailable roots share one future tree. A
missing child inside an already kept destination stays inside that destination
rather than acquiring a second speculative tree.

At this stage source JSON changed only each known source's root. Names, stable
IDs, source keys, original index/catalogue references and unknown fields remained
intact. The subsequent verified registration-fork filename projection is described
in `docs/audits/2026-11-16-collection-transfer-final-forks.md`; INPX references
remain unchanged.
Update-profile JSON is validated with the existing parser but edited directly,
so unknown fields survive. Explicit book roots inside the relocated logical
roots follow their relative paths; empty roots remain empty and unrelated
incoming directories remain unchanged. Index locations, URLs, source binding,
profile mode and enabled state are not rewritten by this projection.

Missing primary/alternate/personal bindings with a real frozen source path can
receive future locator projections. The native archive/raw/FBD kind is derived
from frozen fields without requiring a nonexistent future file. Linked legacy
FBD layout is preserved. The resulting logical filename is checked against the
expected future source. Alternate-copy source keys survive and copy roots are
projected consistently. None of this marks a missing book downloaded.

## Native evidence

Licensed IDE builds passed with exact staged/worktree input equality:

- Win64 r889: `93fa08b5cb435f5109d6fd9ed9f6f26fdcdd965c1499908f27a3990e026f1890`.
- Win32 r890: `68681866d044be525f528080058e3bf2581c7855ac9840674dba7ce121f25919`.

Reports are under `G:/HL-b14-external/`:

| Run | Scope | Outcome |
| --- | --- | --- |
| transfer-layout-Win64-r891 | Initial nine layout methods | PASS, 79.275 s. |
| transfer-layout-Win32-r892 | Twelve layout methods | PASS, 215.294 s. |
| transfer-layout-Win64-r893 | Three added layout methods and three existing regressions | PASS, 223.472 s. |
| transfer-layout-regressions-Win32-r894 | Same three existing regressions | PASS, 84.199 s. |
| transfer-layout-kept-child-Win64-r895 / Win32-r896 | Unavailable child inside an already kept destination | PASS, 12.957 / 13.050 s. |

Cases include source/profile field preservation, unrelated incoming directories,
empty and nested profile roots, native missing archive/raw/FBD locators, missing
alternate-copy source keys, unavailable and nested roots, kept first-source
aliases, an existing parent with no directly assigned files, and rejection of an
unknown profile version without source/settings writes. A complete native
transfer proves the parent layout is actually used while catalogue, personal
database, executable and unlisted neighbor survive. Layout remains identical
after original removal and a source-free coordinator replay.

The existing coordinator, divergent shared-catalogue fork and one reference
capture for 26 ordinary publication groups still pass on each architecture.
The initial r888 build failed for a missing `dm_user` dependency; r889/r890
contain the correction and the failed compiler log is retained.

In total, 13 distinct layout methods and three existing regressions passed per
architecture, with 40 native invocations, no unexpected return codes or skips.
All owned runtimes were removed. Each stage's `summary.json` records counts,
cleanup and exact build inputs. Durations include fixture setup and native
restarts; these are not large-library transfer throughput measurements.

Exact modified native build inputs, identical to staged bytes:

- `unit_CollectionTransferCatalogue.pas`: `cfece2c4293e41f461d14f74632bf4347227179327db07f4b6be5251cadb9171`.
- `unit_CollectionTransferLayout.pas`: `66bf6ca79ceedb23092ef7130c23f2cb1862b1534f6457eed777f2ed2ad2e4e9`.
- `CollectionTransferJournalTest.dpr`: `a46b865914540408007684f4ac71077770756dcaecf053fa86e520f9e42427cf`.

## Remaining integration

Next is durable application, not another source of truth for path planning:
bind exact finalization intent independently, verify existing location receipts
and fresh missing-path witnesses, apply source/profile/future locators and final
registration roots with recoverable per-database commits, then complete the
personal operation record. Recovery must recognize partially applied final
metadata instead of restarting ordinary group preparation against old roots.

Finalization must also preserve other registrations' meanings when a shared
catalogue's final default roots diverge, coordinate retained source indices and
catalogue caches, and handle late personal cards. The projection does not
implement these transactions, cache/Reader handling, live DAO/job coordination,
startup/normal Sources UI, space accounting, cross-volume/filesystem trials or
large-library validation. Desktop and public artifacts remain unchanged.

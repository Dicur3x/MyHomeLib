# Compressed book sizes after a full index refresh

This follows `44b7dd6d`. Work is local and the complete beta-14 objective remains
open. Neither Desktop replacement nor publication has happened here.

## Reproduction

The guarded ordinary-window fixture compresses two real illustrated FB2s in a
shared synthetic ZIP, with a neighbouring book and personal progress of 37%.
It then runs the actual `TManualUpdateThread` full INPX import. The index carries
the original payload sizes, as a publisher's INPX normally would.

`inpx-size-Win64-baseline-r25` failed: the unchanged compressed book had 50,843
bytes, but the refreshed catalogue showed 57,010 bytes from INPX. The physical
ZIP SHA-256 was checked unchanged after the import. This is a metadata defect,
not damage to the book. Keep this failed report as baseline evidence.

Baseline fixture SHA-256:
`35cf879f4cb253f6acb390b94a36dd9dec3ae582f94b7f8c0c48e6297333d385`.
Build log `CompressionRecovery.local-Win64-f9ca25de870b.err`.
An earlier test-only compile failed on nonexistent `Worker.Error`; the fixture
was corrected before the baseline run. No production change was needed to
reproduce the wrong size.

## Implementation and verification

At the beginning of a full rebuild, capture only native compression receipts
with a matching payload witness and the same current physical file identity.
Keep temporary book-identity/locator and source tables inside the existing
import transaction. Source identities are cached per physical path; this does
not unpack or hash every archive in the library.

After import, recheck those sources. Restore the verified payload size only
when the persistent library identity, member and actual physical source still match.
Renumbered book IDs do not matter. A changed/replaced source, reused library ID
at another path or same-named member in another archive must not borrow an old
size. Standalone files use their empty-member proof plus physical file key.
The known old size narrows standalone candidates; it is not itself the proof.

The shared collection tracking hook also covers full Metabib rebuilds. Partial
INPX imports retain their existing path and must not start this full scan.
No book file, compression history or user field is rewritten by reconciliation.
Temporary tables are removed after success and roll back with cancellation.

The first proposed correction still failed in `inpx-size-Win64-r26`. Comparing
folder strings was too restrictive: an index can spell the same archive with
different slashes or a ZIP/7z alias. The final reconciliation resolves each
candidate row's real source and checks its physical identity, with a per-path
cache, instead of requiring identical folder spelling. This still refuses a
different physical archive with the same member name.

The expanded ordinary-window case also exercises nine native boundaries:
standalone/archived members with renumbering, changes before/during import,
reused IDs, another archive, another spelling of the same source, mismatched
payload evidence and transaction rollback.

Win64 `inpx-size-Win64-r27` passed in 23.265 s: ordinary compression, the actual
full `TManualUpdateThread` refresh, both real payload sizes, personal progress,
all nine boundaries and independent content/backup/neighbor checks. The temporary
runtime was removed. The native log records two snapshots and two restorations
for the actual INPX update. Fixture SHA-256:
`ead7717ba206b6df7a1d2bb4e20ae21c0589713376b2725de188476422b86485`.
Build log `CompressionRecovery.local-Win64-8383c06e2606.err`.

Win32 `inpx-size-Win32-r28` also passed in 23.765 s, with the full INPX and all
nine boundary pass markers required by the wrapper. The report records
`refresh_index: true` and removal of its private runtime. Fixture SHA-256:
`55788ca6716d9216b5097132aad0f3b4439937a2d93a92f1463723e1007bc10b`.
Build log `CompressionRecovery.local-Win32-e98940d75e04.err`.

These are private synthetic catalogues, not final distribution packages or
tests on the user's live collection. The Python wrapper now also records the
refresh flag and refuses an older fixture that omits either INPX/boundary pass
marker. The Win64 native log independently contains both required markers.

Evidence root:
`G:/HomeLibRu-build-cache/HomeLibre-post13-legacy-history-20261114`.

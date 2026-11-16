# Fresh registered-reference fence before archive-locator publication

## Production change

`PublishGroupLocations` opens the personal database and all distinct reviewed
ready catalogue databases with FULL-sync `BEGIN IMMEDIATE` transactions before
any locator is changed. Database replacement leases remain held. A fresh
`CaptureTransferReferences` scan then reads the currently committed personal and
catalogue rows into an owned disk-backed scratch store. Ready catalogue writers
and registration/personal writers are excluded until their respective commits.
The existing catalogue-fork mapping is used and verified.

The scan recognizes the source file IDs and the current complete prepared
group's verified destination IDs, so rows already committed before an
interruption can be checked again. Registered roots/types, current effective
catalogue identities, source JSON and ready/unknown state must still agree.
New registrations or newly uninspectable catalogue state stop publication.
Current references to this group are compared with indexed approved keys;
new main/copy references, unrelated personal archive references, new resource
retention requirements and disappeared non-personal references require a new
review. Existing personal cards may be removed. New personal cards belonging
to a reviewed main book are accepted and reconciled by the locator transaction.
Notes/progress and unrelated new books do not invalidate the reference fence.

No user source is removed, no normal transfer command is enabled and no final
root/profile update is performed. A renewed-plan diagnostic preserves the
original archives and prepared copy journals. It does not yet construct a new
review automatically or integrate newly discovered references into a move.

The shared scanner now accepts an optional extra-target callback. Ordinary
initial review callers keep their prior behaviour. The publication caller adds
only file IDs from its complete, leased prepared group. Scratch data uses the
existing marked planning-store lifecycle and bounded caches, rather than an
in-memory copy of all catalogue rows.

## Native evidence

Final builds use licensed IDE AutoBuild, with matching staged/worktree source
bytes and removed IDE temporary directories:

- Win64 r799: `599aa645118940a1efcaffb18f7c4ddaef47026850b50608effc46fb9d2a958e`.
- Win32 r801: `9241f3c5be4c7520711b74c0e91b9646b4130dff4308a6637404a8ef4e7f0351`.

Final verification passed without errors or skips:

| Platform | Main matrix | Detached images / atomic history rollback |
| --- | --- | --- |
| Win64 | r800: 16 methods, 349.760 s | r803: 2 methods, 56.792 s |
| Win32 | r802: 16 methods, 375.123 s | r804: 2 methods, 29.553 s |

Each architecture has 36 JSON-recorded native invocations plus one separately
observed native writer-exclusion process. Four expected process exits exercise
both sides of catalogue and personal commits. Seven expected refusals cover
new references/registrations, cancellation and the atomic-history rollback.
All successful private runtime directories were removed. Per-run summary.json
files record methods, timings and process results.

The writer-exclusion test observes the live native fence marker and verifies
that independent SQLite connections cannot acquire BEGIN IMMEDIATE on either
the catalogue or personal store. Releasing the marker lets the same native
operation complete. Other cases prove that a committed WAL reference is found,
new references are refused without locator changes, approved new personal cards
and unrelated books are accepted, repeated publication preserves new notes,
shared-database forks remain correct, and detached FLibrary images publish and
replay without recopying. The history regression independently checks that
cancellation rolls back locators and history together.
The first r797 fixture exposed the copied Context `reference_rows` collision;
the fresh scratch now removes that old scan counter before its own scan. That
unsuccessful early run is retained and is not passing validation evidence.
Automatic review rejected cleanup of its positively identified private runtime
`G:/HL-b14-external/transfer-fence-Win64-r797/HomeLibRu-native-r49zm49s`, stating
only that it was blocked by policy. No cleanup ran and the fixture remains on
G:. It is not an active process; this does not block later isolated runs.

Source hashes:

- Fence: `320037377861dac79a2b695bfea4ed7ccdc5ccea16f8355279cbbb5f1f8d9a05`.
- Journal: `1a7760698a6d104cfe1b730b4f9f2bc03dbb31ac97a6526e78c62d4540179bc5`.
- References: `913fc5cb6f799a3f49645ac1257624d9477d19c5df6a453b9e7bd0048774edce`.
- Diagnostic: `d35b0f3d13165f5a44dbc9c716afe8039bd925a1c38871d2534d2d518b3e8653`.

## Remaining gates

This fence covers the period before this group's locator publication. A new
writer can act on a catalogue after its own commit; consequently these checks
are not source-unlink authorization. Cleanup needs a fresh coordinated live
reference session, verified file streams/native resources and durable removal
intent, with recovery after sources disappear. Pending-job/DAO coordination,
future/missing locators, cache/index/profile/root publication and startup/UI
integration remain open.

The current publisher scans registered catalogues per group. A whole-operation
session must avoid repeating full-library scans for every archive, retain or
revalidate appropriate connection witnesses, and be measured at real scale
before enabling the normal command. Current small fixtures prove reference and
transaction behaviour, not full-library move performance or arbitrary hardware
power-loss safety.

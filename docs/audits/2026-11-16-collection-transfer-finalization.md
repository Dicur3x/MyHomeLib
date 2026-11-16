# Durable collection roots/settings phase

## Implemented behavior

The production coordinator can now run a durable roots/settings phase after the
available-file transfer. Its independent intent is committed to the personal
database before changing any catalogue's final settings. It binds the verified
review, all participating database keys/paths, registrations, group proof hashes,
original/projected source settings, update profiles and final default root.
Validation derives the allowed results from the frozen review/layout; even a
rehashed intent cannot redirect the operation to an unreviewed root.

One shared publication session holds writer transactions and file leases on all
ready catalogues and the personal store. Fresh reference capture accepts only
the original source JSON/root or the exact authorized final values, including on
partial-commit recovery. Each group is recovered and hashed from its independent
proof, resources are verified and existing location receipts/current locators
are checked. Late personal cards are reconciled under the same personal writer
transaction. No source unlink is performed or authorized by this phase.

The phase also checks current primary/copy counts, metadata-only bindings,
missing paths and independently recorded source-removal outcomes. Retained and
already missing originals do not need a protection witness that was never
required for deleting them. A newly arriving missing archive prevents completion
under the old review and remains untouched.

Catalogue commits atomically include their final source/profile settings,
reviewed missing-book/copy-root changes and a settings receipt bound to the
intent/database. Source IDs, source keys, priorities, original INPX locations,
unrelated incoming directories and unknown JSON fields are preserved. External
source filenames follow their registration's reviewed catalogue fork in every
affected catalogue; only the selected catalogue's book roots/profile roots move.
Other aliases keep their default roots and personal-only files. Unchanged source
JSON is no longer needlessly reserialized.

After each catalogue commit its writer lock is reacquired. The same connection's
data_version must be unchanged across that gap; an intervening writer forces
fresh continuation without restoring an old title. On resume matching receipts
are verified, not overwritten. A dedicated final-aware location check permits
only the reviewed selected copy roots/default root, preserving the original
location receipt's binding digest.

The selected personal root is committed atomically with its missing locators,
late personal-address changes and independent `roots-applied` phase marker.
Known late missing cards follow the reviewed main future locator. A personal-only
file added after review keeps its original absolute native address and notes.
Unpublished primary relative addresses cannot be silently redirected. Required
default-root directories are created only along pinned canonical components
inside the reviewed destination; an otherwise unused default root becomes real.

Once intent exists the coordinator routes continuation directly to this phase,
even when its initial roots flag is false. It never restarts ordinary source
preparation against already changed settings. Target-only recovery keeps group
handles bounded; after a group's verification the result is point-in-time
evidence, not a future permission to remove any file.

## Deliberate completion boundary

The operation remains `pending` after `roots-applied`. Retained source-cache/index
coordination, Reader/live DAO/jobs, normal startup and Sources UI, final cleanup
and the complete move controller remain required. The ordinary move command is
still disabled. This is a completed internal roots/settings phase, not a claim
that the user-facing physical-consolidation feature or beta 14 is finished.

## Native evidence

Licensed IDE builds use identical staged/worktree native inputs:

- Win64 r918: `95604157d9a389c7c4c518d2e94c47b03d1dd6d1f7f0937c1d3ab207161577a8`.
- Win32 r923: `ac651253aec66376808da07ee22c6fabd323bf80240683a14daf09360e139f65`.

All runs are under `G:/HL-b14-external/` on private generated catalogues/payloads.
No working user collection, Desktop installation or public package was changed.

| Run | Result |
| --- | --- |
| transfer-finalization-first-Win64-r919 | Full apply/replay method PASS, two native calls, 16.711 s. |
| transfer-finalization-Win64-r921 | Nine methods PASS, 18 calls, before the tenth fixture failed setup; whole report remains FAIL, 160.285 s. |
| transfer-finalization-remaining-Win64-r924 | Four remaining methods PASS, six calls, 73.116 s. |
| transfer-finalization-Win32-r925 | All fourteen initial methods PASS, 26 calls, 353.342 s. |
| transfer-finalization-regressions-Win64-r926 | Four earlier methods PASS, seven calls, 176.639 s. |
| transfer-finalization-formats-Win64-r927 | Raw/FBD and FLibrary sidecar methods PASS, four calls, 89.576 s. |
| transfer-finalization-formats-regressions-Win32-r928 | Same two format methods plus four regressions PASS, eleven calls, 177.211 s. |

Sixteen new methods and four earlier regressions pass per architecture: 74 native
calls belonging to passing methods, sixteen expected forced process exits and
ten expected refusals, no unexpected returns or skips. Every owned runtime was
removed. Each stage summary records actual status/counts, cleanup and the exact
seventeen native input hashes. Durations include setup/restarts and do not
measure large-library throughput.

Cases cover the actual coordinator's source/profile/root/missing-row writes,
replay selected by independent intent, crashes after intent, after a catalogue
commit, before and after the personal commit, ordinary cancellation, a writer in
the catalogue commit gap, a kept first source, late personal-only and missing
cards, a newly arriving missing archive, retained equal aliases with rebound
source filenames, an unused default root, and rehashed-intent refusal. Raw
subdirectories, legacy linked FBD and native FLibrary sidecar groups survive
metadata publication and source-free replay. Existing ordinary source operation,
new-registration refusal, one reference capture for 26 ordinary publication
groups and the row-only primitive's apply/readonly verification still pass.
Existing tables/fields are compared with explicit allowed mutations; the two
known JSON settings are compared as objects so every unknown field remains
checked without treating serialization order as user data.

Earlier unsuccessful attempts are retained. r917 used a reserved Pascal word
as a local variable; r918 corrects it. r920 could not create a cached Win32 DCU,
then the old wrapper waited for IDE shutdown; a fresh task-owned DCU directory
on G: produced r923 without changing RAD Studio settings. The build helper now
recognizes complete Success/Failed reports before checking the fresh binary;
actual r918/r920/r923 logs and incomplete/nonterminal observations validate that
recognition. r921's tenth fixture reused a unique Bases name; it failed before
any native invocation. Distinct fixture names fixed setup, and the remaining
methods passed in r924. None of these reports is relabeled as a passing matrix.

Key final input SHA-256:

- Finalization: `224e36a75ee4b740e4d35df2ef9910a746f3999e3cc6dd7328d74eae4db5085c`.
- Journal: `36cb2e0b41288ae9daf50eb2a097d9b7e73e6426d5878b4b7677522f1b4b6a8b`.
- Layout: `9270ca6031f45e3aa0567f1852a34db79749055aff36e562329148a4b2a8d8b7`.
- Locations: `18aca2068edbf5e1a85546a15fb7d2e70e013f6adb65d2cf80ab3350bc383718`.
- Operation: `f8b4f4d45a43f4419a5040d1cd277a27220077468980e5e21feb64906093bbd6`.
- Publication: `ed49d90be3602deb280d6d0285e411e32ec01817f09c6c38ef08804a1b2f4eb3`.
- Reference fence: `0998e2b5e99b33eb5b4c2ed16d2d8a5a13f0de19f194e78c9bf2b246e4b2f05c`.
- Driver: `219eeff2439fab193778f392f0fdcb2d552837e3b99e868b7bd60d3460fd764a`.

## Remaining integration

Source snapshots/caches must retain correct native locations and baseline/index
semantics, including shared caches with different roots and without exhausting
the system-volume reserve. Their durable stage must route recovery after the
roots phase rather than restart it against legitimately changed cache metadata.
Reader identity/cache migration, closed/reopened DAO/source handles and conflicting
jobs, startup/normal Sources UI, accurate space/cleanup summaries and clear
source-free error wording remain required. Source cleanup still captures full
references twice per group; the normal 26-group publication regression is not
evidence of scalable cleanup. Whole-operation cross-volume/filesystem and
large-catalogue measurements, post-move INPX updates, final production/release
checks, Desktop replacement and publication remain open.

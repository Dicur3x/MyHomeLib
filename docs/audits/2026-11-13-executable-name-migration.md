# Catalogue executable-name migration after beta 13

This is local work for beta 14. No Desktop installation or public release was changed. Production binaries and fixtures still carry the current beta 13 identity until the complete beta 14 release is prepared.

## Implementation

The catalogue source is now `Program/HomeLibre.dpr`; `MyhomeLib.dproj` produces `HomeLibre.exe` with matching InternalName and OriginalFilename. The application/profile identities remain stable (`myhomelib2.ini`, `user.dbs2`, the instance key and existing user paths). Full native compilation exposed missing source directories for new compression and font-manager units; the production search path now includes the owned Program directories explicitly.

`HomeLibRu.exe` is a separate compatibility launcher, not another catalogue implementation. It forwards the untouched argument tail and current directory to the adjacent `HomeLibre.exe` and exits. A manually extracted compatibility archive first moves its one canonical binary from the fixed transport path into the installation root, without creating a second full executable copy. It never opens a collection itself.

The updater accepts the canonical and legacy catalogue names and the unchanged standalone Reader name. Parent-process identity is checked against the original request before restart-name resolution. Restart prefers the installed canonical catalogue; failed transitions can fall back to a restored old executable. Related-instance capture includes both catalogue names and remains scoped to the exact installation. Component removal recognizes and protects the canonical core executable.

## Why a bridge archive remains necessary

The published beta 13 installer rejects unknown EXE names at the ZIP root before it can run a new helper. A compatible old-name launcher alone would not fix that rejection. The packager therefore produces:

- `HomeLibre[_x64]_portable.zip`: the canonical binary is already at the root, for fresh extraction and new update clients.
- `HomeLibre[_x64].zip`: the older recognized asset name, transporting the same canonical binary as `tools/updates/catalogue/HomeLibre.exe`, alongside the legacy-name launcher and matching updater.

New release parsing prefers the portable asset, then the bridge, then the older HomeLibRu asset. Old clients continue selecting the recognized bridge. Installation maps only the fixed transport name to the canonical destination, retaining its original source path for digest validation. The installation journal records `HomeLibre.exe`. Early and late interrupted installations restore the old files. Two transport names targeting the same installed EXE are rejected. Completed installations remain protected against accidental rollback.

All three production executables (catalogue, launcher, updater) are checked against the same release identity. The archive manifest retains its legacy name for old clients. Module identities, Reader executable and profile filenames are not renamed.

## Verification completed

Both production catalogue builds succeeded through the licensed IDE. Their Windows resource/architecture/common-controls/PerMonitorV2 checks passed:

| Platform | Catalogue SHA-256 |
|---|---|
| x86 | `dd2265dedd2448d091235ac015e30892019f19e0379f32dc6c88608612c15f7b` |
| x64 | `cdaf29844bcd54017ee42c5e74130b781cb0c6dbbdf71720700c9869e17a6274` |

`ExecutableIdentityTest` and `executable_identity_smoke.py` passed 13 case groups per architecture: asset selection/order/architecture; old and new requests; verbatim restart parameters compared with native Delphi parsing; manual extraction of both layouts; real launcher forwarding; early failure and failure after replacing the canonical EXE; rollback route to the old name; committed-state protection; canonical-only installed targets; ambiguous-destination rejection; preservation of fixture personal files; and a real updater helper waiting for an old caller, installing and restarting the canonical native fixture.

The archive validator from tag `3.0.0_pre1.13` was separately compiled and accepted the bridge while rejecting the canonical root package as expected. Its dependencies and test host use the current worktree: this is evidence for the frozen installer parser, not an unchanged published GUI-client run. Frozen installer source SHA-256: `5671315d554ad7a285d8c07369ee43d45893cff60ae6c921655f7fe0a58f4a08`.

Both real minimal production packages, in both layouts and architectures, were then CRC/hash checked, prepared by the current validator, tested against the frozen beta 13 validator, and installed over private extracted copies of the cached published beta 13 packages. Every installed payload file matched its manifest, transport EXEs were not left installed, and fixture settings/personal files remained unchanged. This did not launch the production catalogue or open a real user collection.

| Platform | Candidate archive | Managed files | SHA-256 |
|---|---|---:|---|
| Win32 | `HomeLibre_portable.zip` | 241 | `ff553678feed59cd516a80e7741f3f92841ad8ca9486d3279d0605f35d77641c` |
| Win32 | `HomeLibre.zip` | 241 | `f55f312f3f881b829ddb18c7240a70935b923941c98306d43b7b8e0e6be2e7f3` |
| Win64 | `HomeLibre_x64_portable.zip` | 241 | `bb7b1450de63f72090fdd566db1170e93efd6bcaffdea9269f62ce3f55b456a5` |
| Win64 | `HomeLibre_x64.zip` | 241 | `75a0ca08de8bfe36d100331b68a98b179a9fefdd8a9f978158825130df76ba30` |

The packaging run also found a separate defect: `RELEASE_NOTES_NEXT.md` was parsed as a numeric release and aborted packaging. The history reader now skips this explicit working draft, while continuing to reject other malformed release tags. Both real packages built successfully and excluded the draft from shipped history.

Reports: `G:/HomeLibRu-build-cache/HomeLibre-post13-executable-20261113/native-final-Win32/identity-Win32.json`, corresponding Win64 report, and `real-packages.json`. Successful private runtime folders were removed. Compiler caches, packages and validation reports remain for release work.

## Published-client GUI checks

The exact published beta 12 ZIPs were independently downloaded and checked against GitHub asset SHA-256 metadata. Both unchanged catalogue clients restored a privately prepared candidate package, chose the matching new helper, wrote their own original-process update request, exited normally, and restarted the real canonical `HomeLibre.exe`. The candidate still has beta 13 identity; this deliberately tests a genuinely newer release without falsifying version resources. It is not the final beta 13-to-beta 14 gate, nor a network/download-frontend test.

On x64 the full GUI run passed: the reopened One collection displayed the same publisher-series selection and `Alpha ru`, then all 241 installed payloads, all seven fixture book rows, the personal sentinel and settings passed validation after normal close. Report: `gui-beta12-Win64.json` in the stage directory above.

On x86 installation, canonical restart, payload hashes and fixture preservation passed, but the initial complete tests are **FAIL** on a seeded maximized-state assertion: they save `WindowState=0`, bounds `808 x 831` at `0,0`. Removing the startup override did not remove that observation. Reports `gui-beta12-Win32.json`, `gui-beta12-Win32-r2.json`, `gui-beta12-Win32-layout-trace.json` and `gui-beta12-Win32-settings-stage.json` are retained without changing their recorded failure status.

That observation was subsequently traced to **test input**, not the updater: before any installation, the untouched published client was visibly maximized and its INI still contained the seeded state `2`. One Computer Use click on the release-notes tab restored the owner catalogue to normal size, while staying in the same old process with the package still waiting for installation. The later save therefore correctly reflects the normal window produced by input activation. These runs do not prove preservation of maximized state, and no product workaround was added on their basis.

The actual main form's maximized shutdown was separately checked natively on x86 and x64. Both ordinary destruction and the production order that detaches the theme engine before form destruction preserve in-memory and on-disk state `2`. Each uses fresh private fixtures and removes them. Source: `CataloguePlacementTests.inc`. Reports are under `G:/HomeLibRu-build-cache/HomeLibre-post13-placement-20261113/before-fix-<architecture>-<order>.json`; the `before-fix` label means unmodified production code, not an outstanding confirmed product defect. This native check does not replace the final-package coordinated-restart gate.

The original x86 shortcut attempt also exposed an observer hazard: the old catalogue displayed a settings-write sharing error and did not finish shutdown; after 120 seconds the helper correctly refused to install anything. Its terminal installer log and request are retained in `gui-beta12-Win32-shortcut-installer-failure.json`; the original run remains FAIL as `gui-beta12-Win32-shortcut.json`. Only this exact private hung catalogue was then terminated after the error was preserved. The live INI observer used ordinary Python file opens, which do not grant delete sharing and can prevent the application's atomic settings replacement. It now opens the INI with read, write and delete sharing. No product workaround for that diagnostic interference was added.

With the corrected observer, the unchanged published client completed the normal-window update on **both architectures**, then an actual Windows `.lnk` created before installation reopened the new canonical catalogue. The link still targets `HomeLibRu.exe`, its own SHA-256 remains unchanged, and the compatibility launcher exits while `HomeLibre.exe` opens the same One collection and publisher-series selection. Following the second normal close, all 241 payloads, seven book rows, personal sentinel and settings passed again. Saved normal placement exactly equals the seeded state, dimensions and coordinates (`1000 x 740`, `80,60`). Reports: `gui-beta12-Win32-shortcut-r2.json` and `gui-beta12-Win64-shortcut.json`. The x64 shortcut run is independent of the earlier x64 run without a link.

The smoke runner now understands canonical and bridge payload names, watches only exact owned executable paths, and refuses to launch while the production catalogue's global single-instance mapping is occupied. It can seed a known normal/maximized private layout, record actual saved geometry and verify a pre-existing Windows shortcut. All private GUI runtime directories and the temporary placement build-project files were removed; binaries and evidence remain for release work. No user installation was launched or modified.

## Remaining release gates

The Todo item remains open. Before claiming the full transition: exercise the unchanged published update UI against the final beta 14 package; check coordinated catalogue/Reader restart; prepare the final beta 14 identities and repeat the relevant final-package checks; update all four README languages and explain the portable/bridge assets on the release page. The old Windows shortcut is now proven with the current real candidate on both architectures, but must still remain compatible in the final release. No publication has happened in this task.

## Retained failed-run folder

The first fixture attempt incorrectly compared Delphi argument interpretation directly with Python's C-runtime quoting and attempted cleanup before its child finished. The runner now compares against a direct native baseline and waits for its exact child PID. The first cleanup encountered Windows error 5. A later guarded PowerShell deletion of `G:/HomeLibRu-build-cache/HomeLibre-post13-executable-20261113/native-Win32/HomeLibRu-update-test-identity-3mtqo61f` was rejected by automatic policy without a detailed reason. It was not retried through another mechanism and remains on disk. No user data was involved.

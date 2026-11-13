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

## Remaining release gates

The Todo item remains open. Before claiming the full transition: exercise the unchanged published update UI against the final beta 14 package; check coordinated catalogue/Reader restart and the visible old shortcut; prepare the final beta 14 identities and repeat the relevant final-package checks; update all four README languages and explain the portable/bridge assets on the release page. No publication has happened in this task.

## Retained failed-run folder

The first fixture attempt incorrectly compared Delphi argument interpretation directly with Python's C-runtime quoting and attempted cleanup before its child finished. The runner now compares against a direct native baseline and waits for its exact child PID. The first cleanup encountered Windows error 5. A later guarded PowerShell deletion of `G:/HomeLibRu-build-cache/HomeLibre-post13-executable-20261113/native-Win32/HomeLibRu-update-test-identity-3mtqo61f` was rejected by automatic policy without a detailed reason. It was not retried through another mechanism and remains on disk. No user data was involved.

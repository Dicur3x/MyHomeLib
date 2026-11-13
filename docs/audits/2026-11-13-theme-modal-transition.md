# Theme transitions and modal window ownership

Local beta 14 work. Published packages, the Desktop installation and the user's catalogue have not been changed.

## Faults and corrections

VCL 13 posts `CM_CUSTOMSTYLECHANGED` to visible forms when the active style changes. Opening Settings before those messages are dispatched disables the owner's old HWND. A subsequent style rebuild replaces that HWND, leaving the main window enabled and active behind the modal dialog. The original failing native run is retained under `scripts-settings-Win64/immediate-theme-modal-failure.*` in the evidence directory below.

`SetMHLTheme` now dispatches only its pending style-change messages before returning to a modal caller. The bounded drain does not run the general application message loop or `CheckSynchronize`. It leaves unrelated posted work for the normal loop and preserves a pending `WM_QUIT`. There is no application sleep or timeout workaround.

The broader keyboard regression then reproduced `EInvalidPointer` in the framework's deferred `TStyleEngine.FreeControlHooks`. A captured native stack followed `FreeControlHooks -> TScrollingStyleHook.Destroy -> TScrollWindow` destruction, `DoRemoveControl -> TStyleHook.Destroy -> FreeMem`. The framework iterates its hook dictionary without first extracting the hook being freed; destroying a scrolling hook destroys child windows whose hooks can already have been freed by that iteration. A delayed custom-to-system release can also arrive after the next custom style is enabled.

The application now uses a small `TStyleEngine` subclass for that release notification. Its deferred release acts only while the system style is still active. It removes each form's hooks through the framework's normal control-destruction notification, which extracts parent and child hooks before freeing them. Normal control destruction and other notifications keep the inherited behaviour. This avoids changing the installed VCL sources, maintaining a second per-control registry or pumping arbitrary queued jobs.

The diagnostic-only stack observer was removed from the native test project after locating the fault. The captured failure and the observer source are retained as evidence, not linked into production.

## Validation

Both architectures passed the following native modes, sequentially and at below-normal CPU priority:

| Mode | Scope per architecture |
| --- | --- |
| `settings-script-immediate` | 18 scale/theme cases, 36 real Settings menu/dialog visits; light-dark-light sequence; 96, 144, 192, 216, 240 and 288 DPI |
| `update-keyboard-accessibility` | Six light/dark cases at 96, 144 and 192 DPI; native focus and MSAA state; Tab, Enter and Space; reload, text zoom, history paging and scale roundtrip |
| `catalogue-palettes` | Palette save/cancel/reset and per-release inline-help preferences, retaining unrelated settings |
| `favorite-ui` | Real search-checkbox painting, checked states and input spacing at 100–300%, including 225%; preservation of book rows and personal data |

The immediate-entry mode checks that Settings receives native activation, the main window stays disabled during the dialog and is re-enabled afterward. An unrelated queued message must remain unprocessed during `SetMHLTheme` and be processed exactly once by the subsequent modal loop. Pending shutdown remains available to the ordinary application loop. Script commands and unrelated INI values remain unchanged.

The keyboard mode also tests deletion of the focused control during a theme callback, deletion after restoration is queued, a callback intentionally opening a new input form, and rapid opposite theme changes retaining the newest focus target. The actual native and accessibility focus assertions remain enabled. The temporary keyboard host is independently selectable in the taskbar; Windows foreground-lock failures are retained separately from successful runs. Desktop automation activated only the explicitly named private test hosts.

Final native binaries:

| Architecture | SHA256 |
| --- | --- |
| x64 | `a2b36acfe283dba240071cbc84dc31308032fa20ab0914bd204f214c0a9032fe` |
| x86 | `615c831161d2892e94b139e728549b1d491a24c4bb7baf334aa89e8b84b11176` |

Evidence root: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`. Each `<mode>-Win32` and `<mode>-Win64` directory contains its output and result JSON with the actual binary hash. Successful final results contain respectively 39, 18, 5 and 9 PASS records, including common fixture setup where applicable. All eight report zero exit status and removal of their private runtime. The original style-hook failure is retained in `update-keyboard-accessibility-Win64/style-engine-failure.json` and `.log`. Later attempts are archived under each mode's `history` directory before its current report is replaced.

Both builds used the licensed IDE's documented AutoBuild interface and retained the original project bytes. These are VCL layout-scale checks on the available Windows installation, not a separate physical 4K-monitor test. Other pending Reader changes are present in the linked test binaries; they are not final release packages.

# Script settings and contextual first-use explanation

Local beta 14 work. The published packages and the user's Desktop installation were not changed.

## Behaviour

The external-tools command selects the Scripts page before opening Settings. The Settings OnShow handler now retains an existing selection instead of always returning to the first page. Theme and handle-affecting setup finishes in DoCreate, before the OnShow transition that previously raised `Cannot change Visible in OnShow or OnHide`.

The Scripts page explains what external commands are, how to add one, and why its list may be empty. Opening this page does not run a command. The empty table no longer draws spreadsheet grid lines. A question-mark button reopens the explanation; More links to the existing Scripts help topic, not the general help index. Acknowledgement is remembered per release. Automatic expansion can be disabled; an explicit question-mark request remains available. The helper writes through the atomic INI writer and preserves unrelated sections.

First-use explanation layout now recalculates after inherited-font changes and tracks its target DPI during ChangeScale. Text measurement uses the label's font DPI. The initial modal test found clipped explanation text at 150%; the fixed version passes measured text bounds without dropping text or reducing the test's minimum table height.

The shared explanation component is currently connected to Scripts. Extending it to other non-obvious tools remains a separate open requirement.

## Native validation

`SettingsScriptEntryTests.inc` invokes the actual `miExternalToolsSetup` menu item on the real catalogue main form. It inspects the resulting modal Settings window, selected navigation node, Scripts page, native window activation, explanation visibility, measured text height, table space and retained configured commands. Every case opens the page twice: first to acknowledge the explanation, then to verify it stays collapsed and can be opened explicitly.

Both x86 and x64 passed 12 combinations of 96, 144, 192, 216, 240 and 288 DPI and light/dark themes: 24 actual menu/dialog visits per architecture. These are native VCL layout-scale checks on the current Windows installation, not a separate physical 4K-monitor test. Generated client images were inspected at normal and increased scale; they are not evidence of complete native non-client/header painting.

The existing `catalogue-palettes` regression additionally exercises per-release acknowledgement, opt-out, manual reopening, unrelated-setting preservation, Settings page selection across repeated Show/Hide, and colour editor save/cancel/reset. Its result is recorded separately from the menu-entry run.

Reports and generated client images: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112\scripts-settings-Win32` and `scripts-settings-Win64`. Native binaries: Win32 SHA256 `b2338f7c5694022283d6111c578bd35dc57e055d693998a6bd635c49239dfcde`; Win64 `56a7e8dbf5fa2025658b4caecfd59b79dfb03b206697efa297d1e47f3dd6e7f3`. Both were built with the licensed IDE's documented AutoBuild interface. Private test profiles were removed. These binaries also include other pending UI work and do not represent a clean production release cohort.

## Separate theme-transition finding

An early test invoked Menu.Click synchronously immediately after SetMHLTheme, before VCL's queued style-window rebuilds were processed. In that sequence the Settings modal window remained visible but the main window kept native activation. The failed output is retained as `scripts-settings-Win64/immediate-theme-modal-failure.json` and `.log`.

The passing menu regression processes the theme transition before sending the next independent menu input, matching the normal message-loop boundary between those user actions. It still asserts native activation of every settings dialog. This does not claim to fix the synchronous theme/modal race. Reproduction through ordinary input and a correction of that transition remain open; no arbitrary sleep was added to the application.

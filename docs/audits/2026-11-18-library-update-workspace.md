# Unavailable reviewed-update workspace

The ordinary source window used `Settings.UpdatePath`, which silently returned
the general work folder when a configured update folder was unavailable.
On an installation whose general data lives on C:, this could move a large
index review there without an explicit folder choice.

Reviewed-index preparation now uses `LibraryUpdateWorkPath`. An empty setting
still explicitly selects the general work folder. A nonempty setting is kept;
an unavailable directory raises an error naming the path and the existing
Settings → Папки/Устройства → Папка с обновлениями control. The source window
shows the error before fetching the index or creating a review and leaves
Apply disabled. Restoring the folder permits retry in that same window.

The legacy UpdatePath getter is unchanged so an unavailable update disk does
not make settings loading or catalogue startup fail. Other legacy callers
still need their own write-time path audit during the accepted migration work.
No new INI key or settings migration is introduced.

Russian local help now explains the existing folder control, temporary data
size versus compressed INPX, the empty-field behavior and retry. It separates
the book folder and permanent source states/backups from temporary preparation.
All 55 help topics passed the standard help checker after the paragraph edit.

## Reproduction and native UI checks

The old code reproduced the problem through the actual Main source menu: the
fixture first selected an existing private folder, removed it, then clicked
Check. A ready review appeared through the fallback directory. The expected
refusal assertion failed with `Unavailable workspace produced a review through
the fallback directory`.

Old native SHA-256:
`0c1ae3b4e54a87cf22b25d943dd8675d8a681706fd033675119989e359f2b747`.
The report is library-update-workspace-Win64-r1661-old/report.json, with removed
private runtime and its separate reproduction-source-inputs.json binding.

On x86 and x64 the corrected real-window flow verifies both a missing configured
directory and a file occupying its path. It checks the named error/recovery
setting, disabled Apply and absence of a review; the configured choice and INI
bytes, every catalogue/personal row and schema, and the fallback's staged-index
directory set stay unchanged. The occupying file retains its marker text.
After the fixture restores the folder, Check succeeds and exactly one prepared
index directory appears there. Closing releases and empties the work folder.

The same menu/toolbar flow then declines or accepts the real prepared update,
checks missing-member reports, refreshed visible books and the incremental
compression offer. The ordinary default-folder flow also passes independently
on both architectures. Original INPX and book-ZIP hashes are unchanged. All four
passing private runtimes, and the old-code failure runtime, are removed.

These are missing-directory/file-path cases on G:, not an actual disconnected
disk, SMB timeout or general cleanup test for other services.

## Final build evidence

The four passing native runs have twenty PASS markers including bootstrap.
Both ordinary Main projects also compiled successfully without the regression
driver; the actual PE architecture, new error text, linked guide marker and
fresh binary hashes were verified. Projects remained unchanged and owned IDE
temporary folders were removed. Resource version is still development
`3.0.0.13`; these are not final beta-14 packages.

| Architecture | Native SHA-256 | Main SHA-256 |
| --- | --- | --- |
| Win64 | 52c21d8e77d84e4079bb5e921b0ff32755d7bf273a769371501ffbd04c4d3dca | 4c297e871887ab354c5aee6a23ca80bb4c7bdc3b88e44ddafe7128d84a68867b |
| Win32 | e1fc140db29084681b1f560120ca77505bac2fd7e94f1e5074951e6e495b2508 | 9e8b4b1d9ff3ad6d4d7fea24bc04a0a47dcd9e447035e0ee756d16b6b9bbee90 |

Workspace UI reports: library-update-workspace-Win64-r1662 and
library-update-workspace-Win32-r1663. Normal/default-path reports:
library-update-window-Win64-r1663 and library-update-window-Win32-r1664.
Ordinary Main receipts: library-workspace-main64-r1664 and
library-workspace-main32-r1665.
The aggregate binds these reports, the old failure, help HTML and 696 matching
repository/mirror source inputs:
G:/HL-b14-external/library-workspace-validation-r1661/summary.json.

No E: paths, user-library writes, Desktop replacement or publication are part
of this batch. The full beta-14 goal and the remaining scale/storage/release
gates stay open.

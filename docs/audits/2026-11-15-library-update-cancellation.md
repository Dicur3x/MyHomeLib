# Reviewed library update: cancellation and main-window integration

This local beta-14 checkpoint extends `c914a875`; it is not a completed release.
Original user collections were not modified. Builds and private runtime data
were placed on G:, with the 8 GiB system-volume reserve checked.

## Saving and cancellation

The ordinary catalogue update and the bound-source merge now make a final
cancellation check before saving. Once saving begins, SQLite cancellation is
disabled until commit, or the rollback/restoration following a failure, has
finished. A late Stop therefore finishes that save instead of interrupting a
COMMIT or the SQL needed to undo an incomplete merge. The original callback is
restored afterwards.

The merge plan exposes the durable catalogue outcome separately from complete
success of both stores and subsequent reporting. If restoration fails after
the catalogue committed, the catalogue outcome remains committed. The update
controller then retains the source-cache generation already referenced by that
catalogue. A reporting error after both stores committed no longer enters the
partial-commit rollback branch. Bound-source progress is connected to the
normal progress window.

Guarded fault callbacks exist only under `MHL_COMPRESSION_TEST`; they are not
production hooks. Twelve private cases cover ordinary and bound-source updates
at row writes, the last pre-commit check, commit start, first-store commit and
both-store completion. The additional error cases force an always-cancel SQL
callback while undoing a partial merge, and an error after an ordinary update
already committed. Each case checks the actual outcome, literal rating,
progress, review and annotation, favourites, book count, published baseline,
previous source-cache hash and source book-archive hash.

| Platform | Cancellation run | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-cancel-Win64-r259` | PASS, all 12 cases | 143.703 |
| Win32 | `update-cancel-Win32-r267` | PASS, all 12 cases | 68.125 |

The x64 cancellation run used binary
`7ac7084de3ce516423fcd99a91f130928f76039a7176dcb08a855c669db78b79`.
The later x64 rebuild changes the toolbar glyph binding and the UI diagnostic,
not this cancellation implementation. The x86 cancellation binary is the same
`e00ad7fc305dff7d32a5c9d6c731e886d861b1f90e065fa8f4489b830e9c81cc`
as its window run. Both successful cancellation runs removed their private
runtimes; earlier failing attempts were not counted as passing.

## Library update toolbar and actual window flow

The main toolbar now has a separate `Обновить библиотеку` action, with a menu
for update-source settings and the existing INPX/Metabib file update. It opens
the reviewed source workflow; it does not silently apply every saved profile.
The action is unavailable while the main form is busy or loading books.

Toolbar slot 24 reuses the installed light/dark menu sync resources. Its image
is bound directly to the toolbar image list, since the action list has a
different image-name/index mapping. The first native run caught the missing
glyph after theme switching; both themes pass after this correction.

The integration fixture invokes the actual collection menu to decline an
update, then the toolbar action to accept it. It uses the real source-window
review/apply buttons and nested progress window. The prepared worker's
confirmation text and default-No flag are checked, with its answer supplied
programmatically. This is not visual validation of the native confirmation
message box. Main-window availability is checked through `IsWindowEnabled`,
because native modal disabling does not change the VCL `Enabled` property.
The timer waits for the actual visible modal source window rather than
intervening during its constructor.

The declined view retains the original title and has no compression offer.
After acceptance, the actual main book tree shows the changed and added
titles, the report no longer asks to apply an already completed update, and
the incremental-compression offer appears and can be postponed. The original
INPX and ZIP hashes remain unchanged.

| Platform | Window run | Result | Seconds | Native binary SHA-256 |
|---|---|---|---:|---|
| Win64 | `update-window-Win64-r264` | PASS | 28.047 | `d63a43e47845c6d86053fe529e341d6f69f2c2730aea5eec70792d1f41d745af` |
| Win32 | `update-window-Win32-r266` | PASS | 27.578 | `e00ad7fc305dff7d32a5c9d6c731e886d861b1f90e065fa8f4489b830e9c81cc` |

Fresh IDE build receipts are in `update-window-build-Win64-r263` and
`update-window-build-Win32-r265`. All successful window runs removed their
private runtimes. These are small functional fixtures, not startup or
large-library performance measurements. Earlier failed builds and diagnostic
attempts remain evidence, not passing gates.

## Generic source-window durable outcome

The ordinary source/merge window previously used only `Worker.Success` to
signal a changed catalogue to its caller. An error after both stores committed
could therefore leave the main view stale and report only an unfinished
operation. It now captures the worker/plan's durable catalogue flag before
disposing either object, including the exception path. A committed error has
the distinct state `Каталог изменён; требуется внимание`, with a direction to
inspect the report and backups. A rolled-back failure does not set the change
flag. The merge worker publishes that flag in `finally`, including failure
while reporting its result.

The added diagnostic uses the actual source-window check/apply buttons and
nested worker. Its four cases cover normal success, a pre-commit error, an
error after the catalogue commit with successful restoration, and an error
after both stores committed. It checks the window's change flag, warning text,
invalidated apply plan, actual target rows and untouched source ZIP. The
existing main handler uses that change flag to refresh the collection; this
fixture checks that signal, not another rendering of the refreshed main tree.

| Platform | Outcome run | Result | Seconds | Native binary SHA-256 |
|---|---|---|---:|---|
| Win64 | `merge-outcome-Win64-r269` | PASS | 29.125 | `654c5b3ce4952f21320f0fe49aa875ee7c5fdb3255d8e3954f06dcf6be7a9456` |
| Win32 | `merge-outcome-Win32-r271` | PASS | 21.312 | `f597163f4fa8c9683f3ba9b70a852dcfe05bdb63d2a296ce4eacd61213a35b66` |

Both outcome runs removed their private runtimes. The fresh IDE receipts are
in `merge-outcome-build-Win64-r268` and `merge-outcome-build-Win32-r270`.

## Still open

Cancellation/error recovery does not prove recovery from process death or
power loss. The new update controller still needs that recovery journal,
abandoned-stage handling, bounded backup/cache retention, workspace choice,
the remaining catalogue/legacy modes and scale checks. Final production
packages, visual inspection, Desktop replacement
and publication have not been performed.

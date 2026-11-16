# Ordinary collection transfer workflow

The local Main/Sources interface now connects the previously verified transfer
engine to a reviewed user operation. `Collection → Собрать файлы в одну папку…`
and the matching Sources button open the same window. The operation moves the
current collection's referenced physical containers, with source subfolders and
unchanged archive bytes; it does not import or recompress the Sources list.

## Behaviour

The user selects destination and working folders, checks a plan, then explicitly
starts. Editing either path invalidates that plan. A registered continuation
keeps its reviewed paths locked. A worker performs inventory, file movement and
final acknowledgement; the window reads locked progress and exchanges atomic
cancel/readiness flags. Current filenames are labels. Stop and Close request a
safe stop and wait for the worker rather than terminating it.

Before releasing the current view, Main checks catalogue/startup loading,
compression/deletion/recovery/download jobs, Reader preparations and sessions,
pending saved-reader replies and built-in Reader hosts. Conflicting catalogue
commands are blocked during the modal operation and while the current collection
has a registered incomplete move. A completed run clears DAO caches, reloads the
same collection and invalidates favourites; acknowledgement waits for the view
to finish loading. The cumulative result is shown in the same window, on top,
with processed physical files/bytes and removed/missing/retained originals.

Ordinary startup reads the independent registry and offers Continue or Later,
defaulting to Later. It does not move files without the explicit choice. Later
keeps the operation discoverable through Sources/the transfer menu. A journal is
registered even when Stop arrives before the first group. A busy Reader is not
closed automatically to make the operation available.

## Defects found during the ordinary checks

At 225%, automatic anchoring shrank the working-folder edit and clipped its
companion label. The form now recalculates both edit widths, labels, report and
footer from the scaled client size on resize and DPI changes. Computer Use
inspected the actual dark 225% window in the private Win64 fixture; labels,
equal folder fields and footer controls fit. This observation was r1075 before
the later callback-only fix. Its successful 324.203 s includes an intentional
human-observation pause; it is not a transfer benchmark. The preceding r1072
observation timed out while paused and remains a failed report.

An early-stop/retry exposed a callback lifetime error: the preview's capture and
plan outlived their worker, but still referenced that worker's cancellation
callback. Win32 r1077 stopped again; Win64 r1082 exposed an access violation
after an incomplete first correction. Both timed-out reports remain failures,
with original fixtures unchanged. Cancellation/progress state now belongs to
the window context; retained callbacks explicitly capture that stable context
rather than evaluating `FContext` through a disposed worker. Each new phase
resets cancellation and progress. The final retry checks use both architectures.

## Final evidence

`G:/HL-b14-external/transfer-ui-validation-r1091/inputs.json` records 641 matched
source/resource/validator inputs between the repository and isolated build tree.
Licensed IDE builds:

- Win32 r1085: `af1cac14b5d7a4996177a866a5bfc2a08b26bca08ed26f00198d1206f45b66d2`.
- Win64 r1086: `8f503b33e1b0a952c224058782192d1d76dd10bc1173f84b4834c3c703611311`.

The private ordinary workflow goes through Sources and the transfer button,
previews, changes a path to prove invalidation, previews again, stops the first
run, resumes, verifies the actual five-title Main list, and reopens all five
FB2 books in the actual Reader. Empty, zero, numeric, opaque and scoped LIBID
identities preserve positions, bookmark context/navigation and notes, including
direct note lookup after a changed title and the books-with-notes filter.

- Win32 r1087: PASS, 55.203 s; dark theme and 225%, including equal-width fields
  and Sources footer bounds.
- Win64 r1088: PASS, 51.407 s.

The restart fixture uses a separate producer process to register an untouched
pending move and save genuine Reader data, then a new process initializes the
ordinary user module/Main. Its startup prompt and eventual completed operation
are exercised separately from the already-initialized workflow:

- Win32 r1089: PASS, 48.922 s; Later retains the original hash and registered
  move, then the ordinary Sources command resumes it manually.
- Win64 r1090: PASS, 41.203 s; explicit Continue selects the saved collection
  and opens its immutable continuation.

All four final scenarios pass, with their private runtimes removed. Exact final
reports, runtime removal and source bindings are consolidated in
`G:/HL-b14-external/transfer-ui-validation-r1091/summary.json`.

## Remaining release gates

These are small private G: ZIP/FB2 catalogues. The UI fixture observes idle job
guards in the normal workflow; it does not separately force every possible busy
callback or competing external process. Work-volume space presentation and owned
cleanup, large-catalogue reference-scan cost, post-transfer FLibrary/other-format
updates, independent profiles/empty-LIBID reimports, cross-volume/filesystem
coverage and final production packages remain open. E: was not used. No Desktop
installation, user library or published release was changed.

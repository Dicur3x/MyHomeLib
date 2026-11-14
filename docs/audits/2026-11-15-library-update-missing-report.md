# Missing books in reviewed library updates

This local beta-14 change makes the existing archive/member validation result
visible. It does not change which books qualify for update or claim to validate
all archive payloads. Source book archives and INPX inputs remain read-only.

Each failed verification records the actual checked file, requested book name
and reason in the review's existing private SQLite action table. Reasons are
not accumulated in an unbounded in-memory list. Intentionally excluded records
do not enter this report. The inventory now returns its actual checked path,
including the selected download-root candidate, alongside the failure reason.

After either accepting or declining the prepared update, the source window
shows the first five failures and the remaining count. `Копировать отчёт`
copies that displayed preview. `Сохранить пропуски…` streams every failure to
a UTF-8 text file, with total and completion counts. Export checks both the
system-volume reserve and space on the destination volume. A fresh index check
invalidates the old report and disables export until member verification runs.

The native window fixture now has two available books, eight absent members
and two equally named nested members requested by their ambiguous basename.
It checks the bounded preview, all nine exported names and their missing/
ambiguous reasons, absence of the available books from the report, invalidation
after recheck, decline/application outcomes, main-tree refresh and compression
offer. The original ZIP and INPX hashes are unchanged. Export uses the actual
writer and checks the save button's enabled state/handler; the native save-file
picker itself is not automated. Worker confirmation answers remain programmed.

| Platform | Run | Scenario | Result | Seconds |
|---|---|---|---|---:|
| Win64 | `missing-report-Win64-r273` | Actual window and report | PASS | 31.391 |
| Win32 | `missing-report-Win32-r276` | Actual window and report | PASS | 45.531 |
| Win64 | `missing-report-apply-Win64-r275` | Ordinary/bound-source regression | PASS | 68.453 |
| Win32 | `missing-report-apply-Win32-r277` | Ordinary/bound-source regression | PASS | 76.265 |

The regression covers metadata and personal fields, favourites, priorities,
excluded/omitted/reappearing records, separate download roots, missing members,
same-index continuation and rollback on a late SQL error. These private small
fixtures do not prove production-scale performance, packed/online catalogue
application or recovery after killing the update process.
All four passing runs removed their private runtimes. The x86 window and
regression fixtures ran concurrently in separate private profiles; their
elapsed times are not comparative performance measurements.

Fresh IDE build receipts: `missing-report-build-Win64-r272` and
`missing-report-build-Win32-r274`. Native SHA-256 identities:

- Win64: `12eec0fe31ca52cf6eb7350413b6e19c6af90c2404151947728e0a3f05825ed3`.
- Win32: `17fe3b628d788c377f8e15904fa52ffed942d1ee34f80faf64f8a2a113b5553f`.

Final production packages, visual inspection, Desktop replacement and
publication remain separate release gates.

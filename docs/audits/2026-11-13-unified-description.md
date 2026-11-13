# One book description editor

Local beta 14 work; not a published package or a Desktop replacement.

Both `Information about book → Description` and `Edit description` now initialize the same editor. A stored HomeLibre description takes precedence; otherwise the embedded annotation is displayed without silently persisting that preview. FB2/FBD already read for the information card is reused. Package metadata, including EPUB, is read asynchronously with the existing cancellable metadata reader. A queued review request is not lost while this initial file preview runs.

Editable book information uses explicit **Save** and **Cancel** in both entry points. Cancel and closing the window discard description and review edits. Saving uses the existing field-specific personal-data writer: viewing a file annotation or saving only a review does not turn the preview into a description override. A parallel review change remains intact when only the description is saved. Files containing the actual books are not edited.

The status identifies stored HomeLibre text, file text, site text, or a manual draft, and states that the book file is unchanged. After reopening, an existing database description is labelled as stored in HomeLibre; its original provenance is not guessed. `From file` and `From site` explicitly replace the draft. `Undo edits` restores the description with which the window opened without undoing review edits. Failed and empty site responses preserve the current description. Buttons are anchored together at the lower right, including resize and modeled 225% DPI.

Native tests on both architectures:

- `description-unified`: both actual Main commands, initial file preview with no database write, Save, Cancel, window close after editing, restore, explicit file copy, unchanged keywords and source SHA-256; editable/read-only EPUB preview; owned loopback HTTP request for queued reviews and explicit site description; HTTP 403 and empty response preservation; light/dark layouts at 96 and 216 DPI.
- `catalogue-description`: existing missing-file, lean-row, lower-card refresh, concurrent review preservation, catalog/file/manual annotation priority and EPUB source tests.
- `review-formatting`: existing parser, paragraph boundaries, large review list and native memo edit tracking tests.

All six final runs exited 0. Unified mode reported nine check groups per architecture; each existing regression mode reported seven including its bootstrap checks. All three modes used the same final EXE for each architecture:

| Architecture | Native EXE SHA-256 |
|---|---|
| x64 | `299c8144a397455bf272bec163ac669f6143ddb293f10b4c771445befd63f4d2` |
| x86 | `aebb5fbd9a108610c5db933b26d12e95537f7017c3604533ae20cbbc9016ecbc` |

Reports and screenshots: `G:\HomeLibRu-build-cache\HomeLibre-post13-description-20261113`, with a checked `verified-summary.json`. The earlier failed DPI layout run is retained in its history; its button spacing used monitor DPI instead of the scaled form's DPI and was corrected before the final runs. DPI is modeled through VCL scaling, not a claim of testing a physical 4K monitor. Final light/dark screenshots were inspected. Disposable profiles, generated books and test catalogues have been removed. Build/test binaries and reports remain for the ongoing beta 14 release audit.

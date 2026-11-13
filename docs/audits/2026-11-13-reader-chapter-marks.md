# Real chapter progress marks — 13 November 2026

## Change

The progress strip previously reserved at least 24 pixels (or 1/32 of its
width) for each chapter mark. A real chapter could therefore disappear even
when its own pixel was distinguishable. This reproduced the reported gaps
between chapters 13–16 in *Преступление победителя* and between subchapters in
*Укрытие. Книга 1. Иллюзия*.

The strip now retains each distinct pixel position. Major sections take
precedence only when two positions occupy the same physical pixel. One level
of subchapters remains visible. Closely spaced marks become narrower and
shorter, rather than discarding chapters. Read and unread portions retain their
contrasting mark colors. The existing option to hide chapter marks is unchanged.

The working array is bounded by the strip width, one signed byte per pixel.
Painting visits the chapters and the strip once; adjacent-gap lookups together
span at most one additional strip width. It does not paginate the whole book.

## Native checks

`tools/ui/tests/ReaderChapterMarksTest.dproj` uses the real Reader form and
the normal importer. The test runs only in a guarded private runtime. The
copyrighted book files are not included in the repository.

Fixtures retained privately from the user's earlier examples:

| File | Relevant structure | SHA-256 |
| --- | --- | --- |
| `750572.fb2` | 48 main chapters | `a4d71e48b6423b85975f8f4dfcbb3bded4b7534de161a8c1a7e6f22db6600feb` |
| `777922.fb2` | 82 subchapters at depth 1 | `fe8ebb15e989888f347a3557e252e155ecd37322053fd385b064c2b8310340b7` |

Both architectures passed 32 rendered cases: two books, two widths (actual
624/1024 pixels), paged/continuous reading, paper/dark themes and beginning/75%
positions. Each eligible heading's pixel was checked against the rendered
track. The first book retained 48 distinguishable positions; the second
retained 84 positions including major sections and notes. Real pixel collisions
merge; these totals are not a limit on the table of contents.

Additional checks cover nearby subchapters, precedence at an exact pixel
collision, exclusion of the third heading level, invalid/end positions and
the height of subordinate marks. Book hashes remained unchanged. Private
runtime folders were removed after each run.

| Architecture | Executable SHA-256 | Native result |
| --- | --- | --- |
| x64 | `cee541e0dbf184aa9de51d5bb2dfabed39d321538a2ec94b120eb1bfbd49d087` | 32/32, exit 0 |
| x86 | `58cdf8329d316f82c323b472ca97fa13f14097afb4e4c03204afb4d845879691` | 32/32, exit 0 |

Evidence is under
`G:\HomeLibRu-build-cache\HomeLibre-post13-chapter-marks-20261111`, in
`native-Win32/result.json`, `native-Win64/result.json` and their `marks-*.png`
files. Licensed IDE build receipts are in `build/`.

The first draft of the broad, older BuiltinReaderTest target did not compile
because of existing obsolete color-selector and queued-callback test calls.
It is not counted as a successful regression run. A separate focused target
was used, without changing those unrelated tests. Early focused captures that
used a bitmap canvas's shared DC produced an empty strip; the final test uses
an independent compatible DC with the bitmap explicitly selected. Earlier
failed receipts remain in the evidence history.

## Visual inspection and scope

Computer Use successfully captured the standalone Reader after the reported
graphics-device capture error. It also displayed the updated Reader on
*Преступление победителя*, chapter 14 (x64), and *Укрытие*, subchapter 12 (x86).
The latter window closed normally with Alt+F4, exit 0. Captures and native
painting agree on the visible marks. These were ordinary windows at the
current desktop scale, not a physical 4K/DPI-switch test.

This is a local change for beta 14. Published archives and the user's Desktop
installation have not been replaced by this check.

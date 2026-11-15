# Selected compression on full working-catalogue copies

## Scope

Both architectures completed reviewed native compression against isolated full
copies of the actual Desktop catalogue and personal database. The originals
were opened read-only and their SHA-256 values matched before/after each trial
and between architectures. The original files are 4,521,861,120 and 49,152 bytes.

The three real payloads from r668 were reused: book IDs 757989 (CBZ), 848368
(DOCX) and 773527 (ODT). Only their bindings in the cloned stores were redirected
to one positively identified private ZIP on G:. Their titles, IDs, source keys,
priorities and other metadata were retained. This intentional setup precedes
the baseline comparison; it does not modify the working stores or archives.

The compression operation uses the existing production code and `packages-r665`
with `images-r653`. Only the diagnostic driver and tests changed in this step.

## Explicit source guard

Before handling the full copies, the console driver gained an optional
`allowed_source` check. It requires selected reviewed compression, rejects
whole-collection/estimate/automatic-apply modes, and checks the normalized
source path before every approval. A mismatch raises an error before publishing
the prepared archive or changing store sizes.

On both architectures two native cases prove the guard: the allowed source is
checked and committed; an unexpected source is refused, leaving the source and
both stores byte-identical and removing unapproved preparation. This is a
diagnostic boundary, not a new user approval dialog or application setting.

The driver was rebuilt through the licensed Delphi IDE:

- `source-guard-build-Win64-r677`: binary SHA-256
  `f50a7b4ca564d591c604eee69c2e10bf73891ad8a766e54bd8dcbc38b3897f7d`.
- `source-guard-build-Win32-r678`: binary SHA-256
  `f79f25b84ddcd008baefb5abe1050f76bbfd73f2adb4c1f7058e16f57a85ba54`.

## Full-data verification

`test_full_catalogue_compression.py` makes immutable read-only SQLite backups
only while the source WALs are empty and source identities remain unchanged.
All copies, profiles, logs, backups and book processing stay on G:; the system
drive keeps at least 8 GiB free. Every connection and native process is closed
before the owned full-copy workspace is removed.

Path setup registers the application's exact `CompareStringW` collations on
the owned clones only. The clone-setup triggers are explicitly disabled; only
the redirected ASCII paths/search keys are changed, without approximating
Delphi's Unicode uppercasing for actual titles or annotations.

The baseline and post-compression comparisons hash every row of all existing
content tables, retaining raw SQLite text/blob types. Only `BookSize` of the
three selected IDs is exempted; its new value is independently checked in the
primary row and both physical-copy rows per book. Every unrelated size and all
other existing fields remain part of the comparison. New compression-history
tables are intentionally outside that old-content comparison.

The catalogue contains 1,271,673 book records, including soft-deleted entries.
Across its 16 existing tables, all 12,183,005 rows were compared: authors,
series, genres, publisher-series data, physical copies, source links,
preferences, settings and SQLite internal rows. The five rows of the actual
personal store also matched. That personal store has no book cards for the
active collection; preservation/update of populated personal cards remains
covered by the separate synthetic-store tests.

Both native operations checked the allowed private source, committed one
archive, updated all matching selected sizes and acknowledged their journal.
The saved original ZIP contains the exact three input books. Independent
extraction verifies the smaller results, all non-image content and grayscale
pixels. The original working catalogue/personal hashes and source-archive
metadata are checked again at the end.

| Selected format | Original bytes | Win64 | Win32 |
| --- | ---: | ---: | ---: |
| CBZ | 3,128,863 | 2,896,607 | 2,896,607 |
| DOCX | 1,048,434 | 951,302 | 951,302 |
| ODT | 655,616 | 313,073 | 313,106 |

## Evidence

All runs are under `G:/HL-b14-external/`:

| Run | Outcome |
| --- | --- |
| `source-guard-Win64-r679` / `source-guard-Win32-r680` | Two guard cases each PASS; no failures, errors or skips; private runtimes removed. |
| `full-catalogue-Win64-r681` | Full catalogue/personal trial PASS; 174.578 s including preparation, complete data comparisons and cleanup. |
| `full-catalogue-Win32-r682` | Same full-data trial PASS; 157.109 s including preparation, complete data comparisons and cleanup. |

Full reports have zero failures, errors or skips and confirm both the full-copy
workspace and private packaged runtime were removed. `full-evidence.json`
contains the source hashes, per-table row counts/hashes, selected sizes and
phase timings; `full-evidence.progress.json` records bounded progress.

The native operation itself took 21.141 s on Win64 and 20.140 s on Win32. The
rest is source hashing, full store copying and row comparison. These diagnostic
totals are not throughput estimates for compressing the whole library.

## Remaining gates

This closes the native selected-write trial on a full copy of the real stores.
It does not prove the final Main/Reader GUI or final distribution. Existing
GUI/Reader checks retain their recorded scope; the rebuilt final applications,
normal UI/copy registration, other outstanding formats and release gates still
need completion. The Desktop installation and public release remain unchanged.
The 4.8 MB isolated payload set is retained for the next ordinary-UI
check; the two large full-store copies have been deleted.

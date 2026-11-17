# Million-book transfer space forecast

The latest complete million-book transfer reports already contain sampled
allocated-file peaks. The remaining-task text had left those measurements as
pending. This check reconciles that evidence and compares it with the real
current read-only space preview instead of repeating a completed file move.

## Same-shape evidence

The original runs are transfer-removal-scans-million-Win64-r1296 and Win32-r1297,
previously consolidated in r1305. Their report hashes still match that summary.
All 38 recorded transfer/SQLite/plan-store producer source inputs match current
source bytes. Subsequent changed inputs concern cover/export/UI and their tests;
the measured transfer algorithm has not changed.

The new fixtures use the same seed procedure: 1,000,003 main book records, the
same full source-A baseline, an independent small source-B baseline, personal
ratings/progress/notes/reviews/groups, two retained cache/index sets and two tiny
ZIP carriers. The streamed non-locator book columns match the old million-row
SHA-256 exactly. Paths/operation GUIDs are new; this is the same data shape, not
byte-identical replay of the previous runtime directory. It measures catalogue
metadata rather than large-archive throughput.

The native driver now also reports actual frozen-preview binding/reference/file
counts and review bytes. No production forecasting formula changed.

## Results

| Platform | Forecast additional bytes, excluding reserve | Previously observed transfer additional allocated bytes | Forecast margin | Preview additional allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| Win64 | 5,636,433,440 | 4,089,305,624 | 1,547,127,816 | 734,815,032 |
| Win32 | 5,636,433,440 | 4,088,134,168 | 1,548,299,272 | 736,338,640 |

For this fixture, the forecast is about 5.25 GiB versus the previous sampled
transfer peak of about 3.81 GiB. A further 512 MiB is retained on G:; the separate
C: row retains 8 GiB. Both previews contain 1,000,005 bindings, 1,000,004 registered
references and two physical carriers. The sealed review is 676,200,448 bytes.
The budget includes all 436 carrier bytes, working metadata, projected caches
and catalogue processing; future original deletion is not credited.

Win64 native preview takes 132.500 seconds, Win32 125.797 seconds, during partly
overlapping runs. Those are preview times, not movement or archive-copy speeds.
The private-commit job bounds remain 2 GiB; measured job peaks are recorded in
the JSON summary. A 2,003-book x64 observer smoke passed before the large runs.

Both native calls return zero. All protected catalogue/personal/cache/index/
source/neighbor file hashes remain unchanged. The preview cannot register as a
move, prepare payloads or reopen as a normal transfer. No destination output or
pending operation is created; its own review/plan scratch is removed and both
private runtimes are deleted. System free space stays above the 8 GiB guard
(the minimum recorded native sample is about 27.57 GiB).

## Reproduction and bounds

- Driver: tools/collectionpack/benchmark_native_transfer_space_preview.py
- Native builds: transfer-space-counters-native-build-{Win64,Win32}-r1551
- Observer smoke: transfer-space-preview-smoke-Win64-r1552
- Final reports: transfer-space-preview-million-{Win64,Win32}-r1553/report.json
- Consolidation: G:/HL-b14-external/transfer-space-preview-validation-r1554/summary.json

The script binds old report/source hashes and the same book-row digest, monitors
only the owned native process with a private job limit, and checks preservation
before removing its owned runtime. The build projects stay unchanged and both
owned IDE temporary directories are removed. 7-Zip 26.06 is copied from the local
installation to an owned G: dependency folder; no E: input/output is used.

Allocation samples are taken about every half-second and exclude directory/MFT
costs, unrelated volume activity and potentially shorter or unenumerated temporary
peaks. The forecast exceeding these samples is useful evidence for this fixture,
not a universal reservation, exact physical-volume peak, disk-full/quota test or
proof for every filesystem. Live free-space checks remain authoritative. Real
low-volume/offline-volume failures and final production/UI/package checks remain
separate gates. No Desktop executable or user library is changed.

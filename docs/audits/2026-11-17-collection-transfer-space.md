# Transfer space planning by volume

The ordinary preview now includes a volume budget for payloads, working metadata,
new cache versions, catalogue processing and a retained reserve. It groups paths
by the resolved Windows volume identity, so destination/work/data folders on one
volume share a single reserve. The system volume retains 8 GiB; other involved
volumes retain at least 512 MiB. An over-budget row warns the user; the estimate
does not allocate space or replace the existing live copy/cache/journal checks.

Payload bytes include every reported named data stream and exclude files already
in place. The estimate never credits future original deletion, filesystem
compression or deduplication. Existing files and directories are resolved before
volume probing; new payloads are charged to the reviewed destination rather
than probing every not-yet-created path. Repeated volume probes for the same
role/path are cached within one estimate.

## Planning allowances

These are additional-space allowances, not a proof of the exact future peak:

- Working metadata: 64 MiB, 1 KiB per book/registered-reference row, and twice
  the actual frozen review size; plus shared-catalogue snapshots, three times
  each projected source-cache database's SQLite page size total, and retained
  raw input bytes.
- Persistent cache publication: twice each new cache database's current SQLite
  page total, plus its retained raw inputs. The same source/history projection
  shares one job; different roots/namespaces may require distinct versions.
- Catalogue processing: twice each ready physical catalogue and personal
  database's SQLite page total, plus twice each required fork's page total at
  its destination.

The cache jobs and raw inputs come from `TTransferCacheSettingsPlan`, the same
projection used by actual publication. SQLite page counts include the current
read snapshot; budget growth factors remain estimates. Unexpected later growth
or external disk use can require more space. Runtime checks remain authoritative.

## Preview authority and cleanup

A space preview has a distinct frozen-review kind. It captures references and
fork metadata without copying catalogue snapshots or book payloads. Registration
and payload preparation reject it; the ordinary resume validator also rejects
its kind. An active preview additionally keeps an exclusive operation lease.
Only read-only layout/reference projection accepts the preview kind.

Its temporary review/state/lease use the initial-constructor ownership IDs and
are discarded on disposal, including cancellation and estimation failure.
Unknown or busy entries retain the draft under the existing cleanup rules.
No source setting, personal row, new cache version or pending move is published.
The normal transfer still creates its full independently registered journal.

The UI's stable context now checks the system/work/destination reserves during
initial capture and planning, throttled to once per second. An estimation error
keeps Transfer disabled until a successful new preview. Preview cancellation says
that books were not moved. The final report starts at its first line; Computer
Use found and corrected an automatic scroll-to-bottom after appending paths.

## Verified native evidence

Private G: fixtures contain real cache databases, bound/unbound retained history,
a shared catalogue alias, an extra NTFS data stream and an already-in-place
destination. They independently check payload/cache sums, a single reserve per
volume, unchanged original/cache/index bytes, disposal of scratch, diagnosed
missing cache and cancellation at the actual estimate. The successful ordinary
prepare/resume case also confirms that the transfer journal remains usable.

- Win64 r1115: five methods, six native calls, two expected refusals, PASS
  in 49.860 s; binary r1114
  `392c3af7dd64975fee2d120e59c880917ed5ae02a713c0a771b5bc64fae097c8`.
- Win32 r1117: the same five methods/six calls/two expected refusals, PASS
  in 50.188 s; binary r1116
  `01f56bd5c298b8f4ccbbb596d0a02a8c515060f110243054b7b9ef3c38bcf137`.

No errors, skips or private runtimes remain in those final reports. Earlier
r1102/r1111 failures are retained: a projection rejected the new review kind,
then a test assumed a kind error while an active preview correctly rejected
reopening with sharing violation 32. Negative cases now assert their actual
cancellation/cache error after entering estimation rather than accepting any
failed constructor. The held-preview reopen check accepts only its kind error
or sharing violation, not an arbitrary error.

## Remaining evidence

The final ordinary Main runs also pass and remove their private runtime:

- Win64 r1123, binary r1122
  `d9567d0ad0c628d064f5ff63ddc06d98eee22dbdb31e78ab588ef5debab3053d`:
  actual dark 225% window starts at the report's first line, the budget is
  present, an edited path invalidates the plan, transfer completes and five
  actual Reader histories/positions/bookmarks/notes survive. Its 188.359 s
  includes a deliberate visual-observation pause and is not a speed benchmark.
- Win32 r1125, binary r1124
  `050923ff448582c3942e173436b0b292414c6d48524416f4e1a56eabc6c42546`:
  dark 225%, budget/top-line assertions, explicit stop/retry, refreshed Main
  titles and the same actual Reader checks pass in 59.328 s.

`G:/HL-b14-external/transfer-space-validation-r1126/summary.json` consolidates
both native architectures and both ordinary runs. All 644 final Main
source/resource/test inputs match repository/build. The native budget fixtures
retain 642 unchanged inputs: the later transfer-form scroll/cancel wording and
its workflow probe are excluded, and both native maps confirm those binaries do
not link Main or the transfer form. Earlier pre-scroll ordinary r1119 is retained
as supporting visual evidence rather than substituted for the corrected run.

These are small local ZIP/cache fixtures. A 225% dark ordinary window was viewed
in r1119 and the corrected position was observed in r1123. Network/mount aliases, real low-volume failures,
large-library peak measurements, hard-exit orphan cleanup, completed large cache
snapshot cleanup and final production/release gates remain open. E: was not used;
user libraries and the Desktop installation were not changed.

# Transfer availability and background job lifetimes

## Problem and correction

After a successful download, Main keeps its `TDownloadManagerThread` object for
the next queue restart. The transfer readiness check treated any allocated
manager as an active download, so transfer remained unavailable after the
download and its thread had finished. Duplicate consolidation used the same
object-presence condition.

`DownloadManagerBusy` now checks the actual worker's thread handle with a
zero-timeout wait. A running worker, its cleanup, or an unavailable handle
continues to block the operation. An exited worker retained for restart does
not. The predicate does not stop, destroy, wait for or replace a worker. Both
transfer readiness and the duplicate-application guard use it.

## Reproduction

An isolated native Main fixture starts a genuine queued HTTP download from its
own loopback server. The server holds the response until the test releases it.
The active collection is a separate local collection, so a network-library
restriction cannot substitute for the job guard.

On the previous production code, x64 allowed transfer before the download and
refused it during the held response. The queue then successfully published the
downloaded book, whose full text matched the served response. Nevertheless the
ordinary transfer command still refused. The observed final failure was
`expect window=1 opened=0 refused=1`.

- Old-code native SHA-256:
  `995acf2f31bd2b03fc13c4a43b43a3d0335d2222ac0cfa04a6ab3edad7467496`
- Exact report: transfer-download-lifetime-Win64-r1648-old/report.json
- Source binding: reproduction-source-inputs-r1648.json in the aggregate folder.

The same three-stage download test passes with the correction on x86 and x64.

## Scope of the native gates

Each architecture has three real Main workflows:

1. Download: transfer opens before download, refuses while the loopback response
   is held, then opens after successful publication and thread completion.
   The original worker is retained and is not canceled by the transfer attempt.
2. Deletion: transfer opens before a real shared-ZIP deletion, refuses while its
   review is pending, and opens after the approved deletion completes. The
   selected archive member/card is removed; its unselected neighbor and the
   separate loose input remain intact.
3. Compression: the existing ordinary selected-book compression workflow now
   also attempts transfer while its prepared result awaits approval, and after
   normal completion. Refusal uses the original compression status message.
   The workflow still checks actual reduction, selected-book sizes, reader
   cache refresh, original-book backup and the retained neighboring book.

Across these workflows, eight availability checks per architecture compare all
rows/schema of the active catalogue and personal database, a protected input
hash, and the transfer registry before/after the command. Merely refusing or
opening/closing the transfer window must not start an operation or change those
data. The deletion target itself is deliberately held by its real worker;
while that lease is active the hash witness is the unrelated loose input.
The completed deletion's archive contents are checked separately.

These are bounded review/response interleavings, not a claim about every byte
write, filesystem or possible background tool. Duplicate application shares
the corrected predicate; this batch's completed-download end-to-end command is
transfer, not an independent full duplicate-consolidation workflow.

## Final evidence

All six native workflow processes passed: three per architecture, containing
sixteen availability checks. Each child report confirms removal of its private
runtime, including the successful real download, selected compression and
physical deletion. The four earlier diagnostic runtimes were also removed.

| Architecture | Final native SHA-256 |
| --- | --- |
| Win64 | 740c5fa7ef28b0c205e1fec974e552e20859f08e000daad54acb16e1cc1b9def |
| Win32 | 3e6c1320c9bb28bbb53b137bab009c6979875b6b2404ccb52ec7ba65760eded4 |

Paired gate reports: transfer-jobs-gates-Win64-r1651/report.json and
transfer-jobs-gates-Win32-r1651/report.json. The compression cases use the
existing validated BookProcessing 3.0.0.14 packages and actual image helper;
their native reports retain the package/helper hashes.

Both ordinary Main projects built successfully with these inputs. Linked guide
markers, PE architecture, project immutability and owned IDE temporary-folder
removal were checked. The binaries retain beta-13 development resources
(`3.0.0.13`); final beta-14 release builds/packages are still required.

| Architecture | Ordinary Main SHA-256 |
| --- | --- |
| Win64 | df1a0bc2e051c1d17aa66f3e91e150bb703a7b8f1070235826909aa05974a1d7 |
| Win32 | 895bdd4fa8cc57b3ec1b62a5ba93d795eb60027e92184540cb1d96387f6bd193 |

Build receipts: transfer-jobs-main64-r1652 and transfer-jobs-main32-r1652.
The aggregate binds 695 repository/mirror inputs, both native hashes, all child
reports, the old-code reproduction, cleanup and both Main builds:
G:/HL-b14-external/transfer-jobs-validation-r1647/summary.json.

## Test diagnostics and boundaries

The first fixture run used a collection-menu list that this native bootstrap
does not populate. It failed before any download; the fixture now invokes the
ordinary collection-selection handler with its actual collection ID.

The first deletion guard fixture tried opening the actively leased ZIP for a
hash and was correctly refused by the file lease. It now verifies the unrelated
loose input during refusal and the archive's exact retained member after the
authorized deletion. No production file-sharing or deletion protection was
relaxed. Earlier failures are retained as diagnostics, not passing evidence.

All jobs, catalogue fixtures, loopback responses and runtime copies belong to
private G: profiles. No E: input, user-library change, Desktop replacement or
publication is part of this batch. Release resources/packages, unexpected
volume loss, real disk exhaustion and other competing tools remain separate.

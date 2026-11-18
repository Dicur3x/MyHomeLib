# Legacy library-update input ownership and workspace

The real TLibUpdateThread batch worker used a download path captured during
settings loading, then separately resolved the soft Settings.UpdatePath during
import and cleanup. An unavailable configured folder could select different
download/import destinations. It also deleted selected local inputs on error
or cancellation and every configured matching filename after success, including
unselected inputs. A new native fixture reproduced deletion of selected.inpx
after a successful local update on the unchanged production implementation:
legacy-update-workspace-Win64-r1706-baseline/report.json fails at that oracle.
The input and all application data were isolated copies on G:.

The worker now captures strict LibraryUpdateWorkPath once at write time and
uses the existing TStagedLibraryIndex for both local and HTTP inputs. Local
files are copied read-only into an owned, leased staging directory; downloads
stream there with the shared HTTP status, index-size, space and cancellation
checks. Only this staging object cleans its owned input; unexpected sibling
files are not recursively deleted. The selected original and unselected local
packages remain. Errors name the configured folder and recovery setting in the
actual worker log. No global in-memory path is temporarily changed.

The old whole-memory downloader and its stale path field/property/assignment
were removed; there are no remaining callers. The soft getter used while
loading settings remains unchanged so an unavailable folder does not prevent
program startup. Import transactions, commit notifications and remapping remain
the existing implementations.

## Paired native evidence

LegacyUpdateWorkspaceTests.inc runs the actual worker without overriding its
WorkFunction, initialization, HTTP callback, import or cleanup. For each x86/x64
binary it covers seven cases: local success/cancel/invalid archive and HTTP
success/404/invalid archive/cancel. Each verifies success/commit flags, expected
card count, original seed identity, rating, progress, note/annotation and exact
publisher/local/unselected input bytes, unchanged INI/configured path and no
remaining owned index directory.

Two more cases remove the explicit root or replace it with a file after the
availability check. They require zero download requests, identical catalogue
and personal rows/schema, unchanged settings and fallback index-directory list,
named recovery guidance and preservation of the occupying file. Restoring the
same folder allows the actual worker to retry successfully. These are 11 worker
executions and nine result markers per architecture, 22 worker executions total.
The server uses loopback; payloads and catalogues are generated and small.

| Architecture | Legacy gate | Existing outcomes regression | Native SHA-256 |
| --- | --- | --- | --- |
| Win64 | legacy-update-workspace-Win64-r1708-fixed | update-outcomes-Win64-r1715-regression | 7cefb550ea1ac9937334946c290f7413d8ea382d123a8c59ec54a9c78082234f |
| Win32 | legacy-update-workspace-Win32-r1710-fixed | update-outcomes-Win32-r1716-regression | 6acb8784f449ce867fb1b1b030a87cfb62e1778bf62fa1d7a9d7b6386bbbe762 |

The existing outcome/menu suite also passes on both architectures: rollback,
postcommit failure notification, affected IDs, full/repeated INPX, Metabib,
partial FB2 and FBD phases, last-arrivals search and post-update compression
offers. Its batch test overrides WorkFunction; it is supplementary regression
evidence, not the proof for the real legacy downloader above. All four passing
private runtimes are removed; the runs have 34 PASS markers including bootstrap.

An initial fixture run r1704 stopped on isolated in-memory default entries;
clearing those defaults corrected the fixture. The first supplementary run
r1712 lacked its required conversion-fixtures/source.fb2; the corrected driver
provides a generated valid FB2. Neither preparation failure is a product pass
or an additional discovered application defect. The genuine r1706 input-deletion
failure remains separately recorded, with its runtime also removed.

## Ordinary builds and limits

| Architecture | Main build folder | Main SHA-256 |
| --- | --- | --- |
| Win64 | legacy-workspace-main64-r1711 | 5ac293222a7f7e15f6906e7d49f581ff883045594f05dc724d726952e5154818 |
| Win32 | legacy-workspace-main32-r1713 | 0ad90f777c54aa50c48149a88acda2dd06617080b20d7bfe90f7639ef1875fb8 |

Both ordinary builds and both native builds have successful licensed IDE
receipts, correct fresh architectures, unchanged projects and removed owned
build temporary directories. 698 input hashes match the primary source and
production mirror. legacy-workspace-validation-r1712/summary-r1717.json binds
the sources, four passing runs, reproduction and four builds. Artifacts live
under G:/HL-b14-external/. Main resources remain beta 13.

This does not complete migration of packed/online catalogue updates, physical
volume-loss/OS-ENOSPC testing, abrupt-process recovery of the older path or final
release installation. Reused staging has a 1 GiB index limit and the existing
8 GiB system/512 MiB output reserve checks. No E:, user-library edits, Desktop
replacement or publication occurred. This is not new proof for million-card
updates, all fallback files or every personal field in the small non-refusal
cases; those cases use the specifically listed oracles above.

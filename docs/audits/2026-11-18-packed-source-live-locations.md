# Packed source review with an existing publisher history

The source-profile window must compare the publisher's original artifact with
its present packed payload without treating the two physical paths as two
editions. A delivery containing an unchanged old archive reproduced another
false change on production commit 4fe911ca: both old books were reported changed,
although their publisher metadata and packed bodies were unchanged.

The old-code native build is packed-map-baseline-build64-r1753; the actual failed
oracle is packed-source-review-Win64-r1754-baseline/report.json. It preserves the
native binary hash and removed private runtime. The 700-input baseline manifest
and retained executable are under packed-map-validation-r1755. The source
manifest records the then-current test; later fixture preparation changes are
not represented as production failures.

## Implementation

ReviewPackedLocations now associates a publisher key with the live stable
BookID, packed root/folder/name/extension, member index, measured size, physical
identity, container and pending-payload state. It is streamed from the current
packed catalogue using HomeLibrePackingPublishers, with cancellation, space
checks and progress. It does not use a numeric ID from an older source cache as
a live catalogue ID.

The previous applied source cache stays authoritative for original metadata,
keys, availability and exclusions. Its contents are not rewritten. Projection
of packed publisher fields is used only when the previous catalogue is the
actual packed target. When a mapped artifact has the same publisher stamp and
original locator, finding another original archive does not count as a change
solely because its physical path differs from the packed payload. A real
publisher title/date/size change still appears in the review.

A publisher row whose live packed card was removed records an exclusion even
when the same key already exists in the saved raw cache. Pending payload state
is carried through the logical-key map. Ordinary merged targets containing
packed sources and packed targets without publisher metadata keep their
existing behavior in this batch.

## Native scenario scope

The fixture creates real TXT books in ZIP, imports INPX, packs a separate
generation, registers it, then hides the original archive folder. It reviews
through the actual source-profile window in twelve scenarios per architecture:
with/without a pre-packing applied history, before/after deleting one card,
with/without delivery of the unchanged old ZIP, and with a genuine publisher
metadata change. The history scenario deliberately moves live IDs by 100 in the
isolated setup; the actual full update then saves raw cache IDs differing from
those stable live IDs.

Each review compares all catalogue and personal rows/schema, the INI hash and
(where present) saved baseline bytes. It checks the exact new.zip download list,
zero false changes, detection of a real changed artifact, the absent deleted
card, readable packed body, original nominal size, rating, progress and note.
No user collection is used. These are small generated TXT/ZIP fixtures with
nonempty stable IDs, not all formats, identities or a scale benchmark.

Intermediate setup runs r1757/r1759/r1761/r1763 did not pass: respectively the
fixture reused a collection display name, used wrong relationship-table names,
overrode its confirmation observer through the outcome helper, and appended an
already retained profile. Those were corrected in the fixture; the production
change was unchanged. They are excluded from the final passing runs.

## Remaining operation

This supplies the physical map for applying a reviewed update to a disposable
packed generation. The new profile window still refuses packed application;
its final generation worker, registration/new active collection ID, frozen-input
ownership and missing-module restart are not complete here. Existing histories
are covered for review of the unbound packed target, not all bound or multiple
packed sources. Older packed copies without publisher data, original catalogues
already transformed before capture, changed original names/extensions,
empty/zero IDs, initially missing payloads and large packed catalogues still
need their corresponding provenance and operation checks.

No E:, Desktop replacement, final package or publication occurred. Development
Main resources remain beta 13. The main release goal and the source-profile Todo
remain open.

## Final paired evidence

| Architecture | Profile review | Packing/pending regression | Ordinary/bound regression |
| --- | --- | --- | --- |
| Win64 | packed-source-review-Win64-r1765-fixed | packing-inpx-metadata-Win64-r1771-metadata | library-update-apply-Win64-r1766-ordinary |
| Win32 | packed-source-review-Win32-r1770-fixed | packing-inpx-metadata-Win32-r1772-metadata | library-update-apply-Win32-r1773-ordinary |

All six final native processes passed, with 72 PASS markers including bootstrap.
Both source-profile runs completed all twelve review scenarios. The previous
packing/update/repeat checks preserve nominal sizes and pending download lists;
the ordinary/bound matrix covers full/append, unavailable roots, exclusions,
source priorities, immutable history and saved INPX/Metabib publisher recovery.
Every successful private runtime was removed.

| Architecture | Native SHA-256 | Ordinary Main SHA-256 |
| --- | --- | --- |
| Win64 | f502b22a6d2d67c87d870bff7b0a3847e8179696b3624332b017eb646ffebec5 | d02ac133f3dbde69eed3664fa58107e1fd7b6578c3900b5768f97eac3ac07550 |
| Win32 | d193da5e9ffacbdeeeb939b5639b26470d1a29087c8e9c13376592ca7261376e | c4185a659a78449691563e4d23620342e21c5d17e41ea6368ab860e788d377ca |

Licensed IDE receipts are packed-map-fixed-build64-r1764,
packed-map-fixed-build32-r1767, packed-map-main64-r1768 and
packed-map-main32-r1769. They validate fresh PE architecture, required linked
markers, unchanged projects and cleanup of owned build temp directories. No
licence setting or activation was changed; the existing Community reminder was
acknowledged once while building Main.

700 source inputs match the primary checkout and build mirror. The final
packed-map-validation-r1755/summary-r1774.json binds those inputs, baseline
production commit 4fe911ca, the actual old-code failure, current binaries, six
passing runs and sealed BookProcessing module hashes. All evidence paths in
this section are relative to G:/HL-b14-external/.

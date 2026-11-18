# Publisher metadata for packed source review

A real packed target was reviewed through the source-profile window using a
new full INPX, with its original ZIP folder unavailable. On unchanged production
commit d5e34645, the native fixture reported one genuinely new book **and two
unchanged old books as changed**, requesting both books.zip and new.zip. Packing
had replaced their nominal index sizes and physical locations. The original
metadata was no longer available to that comparison.

The reproduction uses a separate worktree with only the new test/include and
dispatch added, 27 matching existing VirtualTreeView source files, and the same
sealed BookProcessing candidate. Its successful build is r1734; runtime
packed-source-review-Win64-r1735-baseline/report.json records the genuine failed
oracle, and that private runtime is removed. The worktree/699-input manifest
retain the old production source for comparison. Initial test preparation r1732
failed to compile a reserved Pascal variable name; that is not product evidence.

## Current implementation

HomeLibrePackingPublishers preserves the catalogue's publisher fields before
packing replaces physical names/locations/sizes. It stores original name/ext,
folder, nominal size, date, title/language/deletion flag, raw library ID and an
absolute publisher root only when needed. The initial capture is transactional,
streamed and cancellable, with progress every 1,000 rows and system/output
reserve checks. Existing legacy packed rows without this data are not guessed
from their already packed physical fields.

The real packed INPX worker records incoming publisher metadata inside the same
private catalogue transaction via IPackingPublisherWriter. A missing new or
changed payload remains pending across repeated indexes; a successfully located
payload clears that state. Old nominal fields remain independent of compressed
display sizes. No module or payload compression policy changed.

Source review can project these saved logical fields while retaining the actual
physical packed locator. A stored row whose raw ID no longer matches its live
card is refused. Publisher rows whose live card was deleted supply exclusions;
they do not become new books again. Pending payloads continue to request their
archive even after metadata has been retained. The report explains its baseline
and distinguishes deletions after that snapshot from earlier unknown deletions.

This projection currently applies to packed targets without authoritative saved
review keys. Ordinary merged targets containing packed sources still need their
physical-name/ext/size mapping; that existing path is deliberately unchanged.
Applying to a packed target through the new profile window is **still refused**:
this batch supplies comparison/persistence, not its final generation operation.

## Paired native evidence

| Architecture | Profile window | Packing/update/repeat | Ordinary update matrix | Native SHA-256 |
| --- | --- | --- | --- | --- |
| Win64 | packed-source-review-Win64-r1743-fixed | packing-inpx-metadata-Win64-r1742-metadata | library-update-apply-Win64-r1744-ordinary | ddb1abcfa55e5c551e65fc059f46d5fa96cca82139994dbe84525dc7372a92f9 |
| Win32 | packed-source-review-Win32-r1747-fixed | packing-inpx-metadata-Win32-r1748-metadata | library-update-apply-Win32-r1749-ordinary | 498a84debd61adb62116e77b8fc9a280f562f8605388d19fd24da849c7db37bc |

The actual window's CheckSource operation now reports one new book, zero false
changes, and only new.zip needed. Repeating after a catalogue deletion preserves
that result and the missing card stays absent. Every catalogue/personal row and
schema, plus the INI hash, is compared before/after each review; packed text and
personal rating/progress/note remain readable with originals offline. Nominal
size 123 survives independently of the small real text bodies.

The real packing/update/repeat fixture retains all four nominal sizes, keeps
completed bodies out of the pending queue and leaves unfinished payloads in the
exact books.zip/absent.zip download list. Previous ID/personal/data/generation,
estimate cancellation, continuation and retained-only reuse checks also pass.
The unchanged ordinary/bound update matrix covers full/append, offline roots,
excluded returns, immutable history and previous INPX/Metabib publisher recovery.
The six processes have 52 PASS markers including bootstrap; all private runtimes
are removed. One new-unit compile preparation needed its explicit System.Classes
import (r1736); only later successful builds count as evidence.

## Production builds and remaining scope

| Architecture | Ordinary Main receipt | Main SHA-256 |
| --- | --- | --- |
| Win64 | packed-review-main64-r1746 | b9e100dfaa12654338994a5c1a2ad27cc488d2eb082265f2bfad29bf841c6fc0 |
| Win32 | packed-review-main32-r1750 | 303f806f6f8b4ec2c07338055d3e0b75eb821d7d7588df65cb5d56e8378add85 |

Both native and ordinary Main projects have fresh successful licensed IDE
receipts with the requested architecture, unchanged project and cleaned owned
build temporary folder. 700 inputs match primary source and production mirror;
packed-source-validation-r1745/summary-r1751.json binds the builds, six passing
runs, module hashes and old-code reproduction under G:/HL-b14-external/.

These are small generated TXT/ZIP fixtures with stable nonempty IDs, not scale,
all formats/identities or all pre-existing compressed-catalogue states. The
captured baseline reflects its source catalogue; earlier compression without a
saved nominal index requires separate provenance/migration handling. Packed
copies already carrying older source-history caches, older copies without this
table, packed sources in ordinary merged targets, profile-window application,
restart/publication and missing-module continuation remain open. Source archives
with unchanged metadata still require independent payload checks at application.
Main resources remain beta 13. No E:, user-library changes, Desktop replacement,
final packages or publication occurred.

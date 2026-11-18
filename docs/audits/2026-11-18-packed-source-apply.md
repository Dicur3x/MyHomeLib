# Apply a publisher update to a packed collection

The source window now applies full and incremental indexes to a standalone
packed catalogue. It creates a separate registered collection and opens it
when the source window closes. The window displays the missing file report
before closing.

The worker uses the reviewed, staged index. It matches publisher keys to
stable live IDs, checks each required archive member and reserves IDs already
used in the personal database. It edits private copies of both databases
before packing. A usable earlier payload stays in the copy if its replacement
has not arrived, and the publisher record remains pending. Previously deleted
cards stay excluded. A full publisher omission is recorded separately from a
user deletion. The first incremental delivery also preserves raw publisher
locations and keys for books outside that delivery.

Packing uses the profile saved in the collection folder. The packer can
reuse earlier verified payloads, reads incoming archives, and validates the
new catalogue and personal snapshot. Registration comes last. The old
collection remains registered, with its original control database and
archives. The new publisher baseline is published with the new collection.

## Evidence

The native TXT/ZIP fixture executes the main toolbar action, opens the actual
source window, checks an INPX and applies it. It answers the confirmation
programmatically. A full delivery starts with earlier applied history whose
numeric IDs differ from the live catalogue. An incremental delivery starts
without saved history. It covers confirmation declined, cancellation just
before registration, registration with a pending replacement, and retry after
delivery. The assertions check activation of the new collection, stable IDs,
readable exact text, rating, progress, note, deleted card, publisher history
and the original catalogue hash. The cancellation test injects an abort at
the registration boundary. It does not simulate a power loss.

Final run logs, architecture-specific binaries, ordinary window regression
and build receipts are linked in
G:/HL-b14-external/packed-apply-validation-r1784/summary.json.

## Remaining work

The packed apply route currently requires a standalone packed target with
stored publisher metadata. A publisher bound to one source in a packed
merged catalogue needs per-copy provenance and its own application checks.
Legacy packed targets without these records still use the existing INPX
route. If a packing module is absent, this path identifies what needs to be
installed. Automatic installation and resuming the staged operation through
restart remain open. The new apply fixture covers INPX with TXT payloads,
not all formats, transformed locator families, large packed collections, or
the release update and installation paths.

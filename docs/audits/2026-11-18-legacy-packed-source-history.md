# Recover publisher history for a legacy packed collection

Older packed standalone catalogues can retain original file provenance while
lacking the publisher metadata table introduced later. The normal source
review now uses the saved publisher baseline for such a catalogue. For each
live publisher card it requires a unique match against the recorded original
file path and name, format, library ID and index date. Numeric IDs in
the saved baseline can differ from those in the packed catalogue.

The comparison uses the saved nominal size and date, which remain independent
of the measured packed size. Deleted cards stay excluded. When applying an
incremental index, the new packed generation records publisher metadata for
books outside the delivery as well. The saved baseline and live collection are
read-only during review. The published generation is prepared separately.

If the provenance or saved baseline is missing or ambiguous, the source
window reports the specific problem. This recovery requires an existing
applied publisher history. The older packed INPX command remains available
when the original index is no longer recorded.

## Verification

The native fixture packs a small TXT/ZIP collection with a saved publisher
baseline whose numeric IDs differ from the live IDs. It removes the publisher
metadata table from the private copy and hides the original archives. It checks
preview counts with and without a delivered old archive, unchanged and changed
publisher metadata, and a user-deleted book. The real update window then applies
an incremental INPX, retaining an untouched old archive and its original index
size. It completes a pending replacement after the archive arrives and checks
both readable contents and the original packed catalogue hash.

The legacy fixture and the existing standalone and bound packed scenarios
pass on x86 and x64. The aggregate record binds all six native processes,
both ordinary application builds and 700 matching source files. Test profiles
were removed. The record is at
`G:/HL-b14-external/packed-legacy-validation-r1808/summary.json`.

The fixture emulates the legacy schema by removing the metadata table from a
current synthetic packed catalogue. Authentic legacy program versions and
release distribution tests are separate checks.

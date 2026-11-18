# Standalone packed updates from Metabib and legacy ZIP

The native fixture starts from an INPX catalogue with TXT books in ZIP
archives. It creates a separate compressed copy, makes the old source
folder unavailable, and checks and applies the new index through the
ordinary library update window. The Metabib snapshots are written with
HomeLibre's existing export writer.

The current packing schema is exercised with and without saved publisher
history. A legacy layout is reproduced by removing the new publisher
metadata table from an isolated packed catalogue while retaining the
original locator table. The latter scenario selects a previous full INPX
through the source editor, checks version and archive mismatches and
continues after that external previous INPX is withdrawn.

These checks verify the archive list, declined confirmation, cancellation
before publication and an unchanged original catalogue. Once the user
approves the plan, the new copy keeps the old body readable until the
replacement archive arrives. The selected book keeps its stable ID.
A separate read-only query checks the original and both published
generations after the legacy Metabib scenario for the same ID, rating,
progress and exact UTF-8 review. The deleted book stays excluded. A repeat
review finds zero changes after the missing archive arrives.

The modern and legacy Metabib runs also cover a publisher omission. The
unlisted book remains in the original collection and is absent from the
new full copy. The equivalent INP-in-ZIP update is checked as both a full
snapshot and an incremental package. The latter retains the unlisted
book with its original stable ID.

The current and legacy Metabib cases and both ZIP modes pass on Win32 and
Win64. The independent verifier follows the three registered catalogue paths
and reads each database separately. Two earlier verifier runs looked for
these fields in the system database and were excluded from the evidence.
The final record binds eight native runs, 124 pass markers, two fresh test
builds and 703 matching inputs. The prior Main binaries still match the
current production sources. All isolated runtime folders were removed.
See `G:/HL-b14-external/packed-standalone-final-r1885/summary.json`.

The legacy test models the previous packed schema. Large packed catalogues,
archives containing other book formats and other publisher package variants
have separate release checks.

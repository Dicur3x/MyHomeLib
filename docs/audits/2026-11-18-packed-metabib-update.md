# Metabib updates for packed sources

The sources window describes Metabib as a full catalogue snapshot. Its
reviewed apply path previously kept the profile's append setting. An
empty Metabib fixture using that setting failed the expected full-index
rejection check. The probe was configured to decline any confirmation.
The driver removed its private profile. Its receipt is
`G:/HL-b14-external/packed-bound-metabib-empty-Win64-r1860-append-baseline/report.json`.

The review now detects the format of the staged input once. A Metabib index
uses full-snapshot rules and the preview states the mode. The existing empty
full-index check rejects an empty dataset before confirmation. An INPX
input continues to use the profile's setting.

The positive fixture starts with two INPX sources and packs the merged
catalogue. HomeLibre's actual Metabib writer produces the new snapshot. The
fixture runs the first Metabib update from the main library command with
both original source folders unavailable. It checks that the preview asks
only for `shared.zip` and that the first apply keeps the old copy readable
while its replacement is pending. Once that ZIP arrives, the next worker
replaces only the selected copy. A repeat check finds zero
changes. The preferred payload, metadata-only payload, book IDs, rating,
progress, review, favourites and original catalogue hash are checked.

The Zstandard input uses the decoder DLL from the verified optional
component. The fixture begins with that decoder present.

On Win32 and Win64, the positive scenario passes with plain JSONL,
GZip, Zstandard and ZIP. The empty-index guard passes with plain JSONL on
Win64 and ZIP on Win32. The existing packed standalone, packed bound
and ordinary source regressions passed on both architectures. The report
binds 16 runs, 112 pass markers, four successful builds and 703 matching
inputs. All isolated profiles were removed. Updated help anchors and
the README section link were also checked.

See `G:/HL-b14-external/packed-metabib-final-r1865/summary.json`.
The bound fixture uses small TXT/ZIP archives. Standalone packed Metabib
application, installation of a missing Zstandard decoder from the source
window, scale and final release packages need their own verification.

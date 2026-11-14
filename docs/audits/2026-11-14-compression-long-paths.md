# Long compression workspaces and useful missing-archive names

Local beta-14 change following the observations in
`2026-11-14-flibrary-inplace-sizes.md`. User collections, Desktop binaries and
published packages were not changed.

## Reproduction and changes

The native whole-collection operation failed to open its temporary plan when
the Unicode working path exceeded 260 characters. `G:/HL-b14-size/r112-plan-red`
reproduces the failure against the previous operation executable. A host-Python
probe alone did not reproduce it and is not used as proof of native behavior.

`TCompressionPlanStore` now passes the extended Windows filename to SQLite at
creation, read-only reopening and reopening for filtering. Its owned directory,
lease, marker, DELETE journal policy and cleanup rules are unchanged. There is
no global SQLite wrapper or catalogue schema change.

The prepared-original ZIP failure observed in the preceding audit came from
the diagnostic's unprefixed file open, not the production backup publisher.
The diagnostic now opens source hashes, preparation reports and the intentional
backup-corruption handle through the existing Windows path helper. Actual
production publication and validation of a long-path backup are tested below.

The deeper-root regression also exposed truncated warnings: keeping the first
160 characters of a source path could hide `missing.zip` entirely. The planner
now bounds each example path to 320 characters by shortening its middle. It
retains the beginning and last 287 characters, preserving the complete Windows
filename. The existing eight-example and 200-character reason limits remain.

## Validation

Initial prefix-only focused runs `r113-plan-prefix` / `r114-plan-prefix-32`
passed all three new native operation cases on x64/x86: whole-plan reopen and
skip, exact selected-original backup/manifest, and rejection of a damaged
prepared original before source replacement.

The deeper-root attempts `long-path-Win64-r115` / `long-path-Win32-r116` each
ran 44 cases: all 14 selected-plan tests, 17 collection tests and 13 selected
operation regressions. Forty-two passed, including alias/case-sensitive source
identity, rollback, scratch recovery, new-book selection and all long-workspace
operations. The two failures were the missing-name warning assertions above.
Those reports correctly remain FAIL.

After the warning fix, the focused final runs include eight cases per
architecture:

- Empty unavailable plans and unavailable/invalid catalogue rows.
- A complete 202-character archive filename in a bounded warning, with source
  and authoritative database bytes unchanged by planning.
- A live long-path scratch lease; canceled edit rollback and resealing;
  actual process loss with DELETE and WAL journals; owned cleanup and retention
  of a foreign FB2 until the diagnostic explicitly removes its own test file.
- A whole-collection plan whose journal path exceeds 300 characters, followed
  by another new-books operation that skips the verified books without encoding.
- A long Unicode preparation and backup destination, containing the exact
  selected original and manifest with the original source hash.
- Intentional prepared-original corruption in both the long Unicode workspace
  and the deeper ordinary workspace: no source/catalogue/personal mutation,
  published backup or pending compression job.

| Architecture | Final run | Cases | Seconds | Result |
| --- | --- | ---: | ---: | --- |
| Win64 | long-path-Win64-r119 | 8 | 38.344 | PASS |
| Win32 | long-path-Win32-r120 | 8 | 38.391 | PASS |

Both final reports have zero failures, errors and skips, and confirm removal of
their private runtimes. Reports/logs are retained in
`G:/HomeLibRu-build-cache/HomeLibre-post13-legacy-history-20261114`.
The intermediate `r117` / `r118` attempts passed the product warning assertion
but found one test setup mistake: their read-only hash baseline predated the
test's own catalogue edits. The baseline now follows setup; no further product
change was made for that assertion. The final eight cases were rerun above.

Final licensed IDE builds, with unchanged project files:

| Binary | Architecture | SHA-256 |
| --- | --- | --- |
| BookCompressionOperationTest | Win64 | a90f40bc3cdd43e6c9ae35907904c0276eab8503787c670b065f3b5811cce743 |
| BookCompressionOperationTest | Win32 | 7bf44be25706b3f598a7cb7163435713c5f3e3c2f143e45f20e6cb5f004e46fe |
| BookCompressionApplicationTest | Win64 | 2ce7923ccab55c3c3402658e9831b577aacd2ecb22a96c6c2982febbb664ec5d |
| BookCompressionApplicationTest | Win32 | 9aa82f033b453ba014ec8615e7045221882ca4d150499d5721c69a13ff417e4e |

Logs are in `G:/HL-b14-size/build-long-path`, with final suffixes
`54c6a72d5543` / `ab9d2976c9ca` for the operation worker and
`62c20961c265` / `139dd2ce650b` for the application resolver.
BookProcessing remains the verified `packages-r78` candidate. Its source,
receipt implementation and image processor are unchanged; their broad suites
were not rerun.

## Scope and retained diagnostic files

These are native class/operation checks on generated local NTFS data. They do
not establish every menu, UNC share, filesystem or final application package.
External FLibrary image quality/dependencies, bounded user-data copies and
final application/distribution gates remain open.

Automatic approval review rejected recursive deletion of the owned probe data
under `G:/HL-b14-size/sqlite-long-path-probe-r111` with “blocked by policy”.
That probe, including its report and two small SQLite files, was retained.
No alternative deletion was attempted. It is separate from the private
validation runtimes that were removed normally.

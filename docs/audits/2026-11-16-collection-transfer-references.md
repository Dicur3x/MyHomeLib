# Registered references in the transfer review

The connected-group preparation journal now captures references in every
registered local catalogue and the personal rows for those registrations.
`unit_CollectionTransferReferences` writes only the transfer's unsealed private
review. The source catalogue, registration and personal databases remain
read-only, and the existing preparation path still never removes originals or
publishes catalogue paths.

## Implemented behaviour

- Resolve main books, all physical copies (including extensionless orphan
  copies), and personal locators through the native book-path rules. Match
  reviewed payloads by Windows volume/file ID, rather than basename or content
  similarity. Preserve original row locators, registration IDs, copy source
  keys, catalogue identity, raw registration paths and source JSON.
- Discover when the same catalogue file is registered with multiple roots.
  Capture variants for its main/copy rows; a row that resolves to distinct
  physical files is an explicit conflict. An unconditional absolute-folder
  rewrite would redirect another registration, so these rows require an
  independently verified per-registration publication strategy.
- Whole-root directory junctions that preserve relative layout resolve to the
  same payload. File links and internal aliases that change source layout
  require retention. A genuine 7z archive outside the plan can share a planned
  FLibrary image archive: its dependency is captured and retains that image
  original. A planned owner referenced with a different external image set
  also requires retention.
- Missing/unreadable/non-local catalogues, malformed source lists and ordinary
  reference inspection failures are recorded as uncertainty. They do not
  authorize deletion; all originals require retention while uncertainty
  remains. Harmless copy preparation can proceed. Cancellation and fatal
  exceptions propagate instead of becoming an uncertainty warning.
- File/container/resource caches are bounded at 4096 entries; larger metadata
  sets and shared-row variants live in indexed SQLite tables. Read connections
  retain data-version witnesses and catalogue replacement leases during the
  scan. A foreign database changed after scanning invalidates the review.

## Validation

The licensed IDE AutoBuild compiled the unchanged staged source for both
architectures (r765 x64, r767 x86); its private G: temporary directories were
observed removed. Staged/worktree bytes match. Final diagnostic binaries:

| Platform | SHA-256 |
| --- | --- |
| x64 | `faba4454208e6413464fe750c826fe715797a3924b3f328b67a118615f785ee9` |
| x86 | `58a27d5fe9c91590cfdee5f4cd124cd6d7fa2626907ea114af4287821e7408db` |

`G:/HL-b14-external/transfer-references-Win64-r766` and
`transfer-references-Win32-r768` each passed 30 methods without failures or
skips: the existing 17 group-journal regressions plus 13 registered-reference
cases. Each run includes eight forced process exits at the existing journal
boundaries and successful recovery. Runtime was 482.802 / 507.857 seconds.

The reference cases cover separate catalogues, all registered personal rows,
stable copy keys, extensionless orphan copies, physically different archives
with identical names/bytes, the same database under equal/different roots,
missing/corrupt foreign catalogues, malformed source JSON, foreign database
changes during scanning, cancellation, actual whole-root/internal junctions,
and an outside 7z owner's shared image archive. Detection of a shared-row
conflict is tested; its future resolution is not claimed.

The 13 reference cases were then repeated against the same native binaries
with stronger observers (r769 x64, r770 x86), all passing without skips in
133.751 / 111.716 seconds. These compare hashes of foreign catalogue files and
outside payloads as well as the primary/personal databases and source payloads.
The intentional concurrent-change case instead compares every foreign table
and the schema against precisely the expected one-field fixture edit.

The four successful runs contain 142 logged native invocations, including 16
forced exits; the owner-lock cases additionally start one first-owner process
per architecture and verify its successful exit. All owned fixture runtimes
were observed removed. Requests/native outputs and per-run summaries remain in
the named G: directories. C: stayed above the mandatory 8 GiB reserve, with
about 14.2 GiB free during the final runs.

Source fingerprints: reference scanner
`ca12661713f2bc39a421860e0f26f17f99f50dae7489d0a645505a697a5bc098`,
journal `0404cc20262a20c918689a3b227dca24b41f97e4a018bfb06920d3675cdf8d40`,
planner `ff8b792fdd2a626359be89ea1f87046228583ef11368ee7b07fa3f396007da1c`,
diagnostic DPR `9227c2e34f51d339472b81c828e589abc28944149eb088009e3037e1c3c79688`.

Earlier evidence is retained: r760 failed because the diagnostic imported a
unit twice; r762 exposed a Python module/fixture-method name collision; r763
passed 11/12 cases and exposed the diagnostic writer's missing trigger helper.
The helper was registered before the final matrix. The final observer-only
strengthening did not change native production code or binary hashes.

This remains copy preparation and an initial reference snapshot, not an
enabled transfer command, real-library move or completed path publication.

## Remaining operation gates

The captured snapshot alone does not establish that no new references have
appeared. Before source removal, the publisher must reconcile current
registrations, locators, personal rows and dependent resources; resolve shared
catalogue/root conflicts; commit paired publication receipts; verify native
book reads and all streams; and acknowledge prepared copies for recovery that
no longer requires originals. Unavailable catalogues must be rechecked or
their retention and space cost explained to the user.

Future missing-root mappings, compression history/Reader cache/update-profile
rebind, startup recovery, the normal UI and a large-catalogue performance run
are still open. These small fixtures do not prove offline hardware/network
error behaviour or million-row performance.

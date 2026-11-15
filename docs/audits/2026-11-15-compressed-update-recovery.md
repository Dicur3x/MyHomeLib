# Actual reviewed-update crashes with previously compressed copies

This step adds diagnostic composition coverage; it does not modify production
compression, source updates or recovery. Existing production fixes are tested
together through real operations, forced process termination and ordinary startup.

## Fixture and operations

`validate_catalogue_compression.py --scenario library-update-recovery` accepts
`--update-recovery-compressed`. The native fixture first compresses its original
FB2 through `TBookCompressionOperation` and `BuildCollectionCompressionPlan`,
using the installed `packages-r195` processing package and current image helper.
It requires actual size reduction. The bound variant creates two source roots,
both with `books.zip`, a shared catalogue card and one physical copy per source.
Both copies are compressed. The ordinary variant has one copy.

The new INPX corrects the original title and adds a second book. That member
already exists, still unprocessed, in the preferred archive; it has no original
catalogue card. This tests continuation within an already processed archive,
without counting every member of that archive as processed.

The background reviewed-update worker is actually terminated with exit code 73
at its requested durable stage. Another process enters normal data-module and
main-window startup, checks recovery and repeats acknowledgment. A newer commit
witness for a different collection is written between the two processes and
must remain unchanged.

After recovery, the fixture checks:

- The expected original or committed metadata and the correct visible book list.
- Both physical compressed payload hashes, original archive hashes, measured
  catalogue/copy sizes and the measured existing personal-card size.
- Unchanged compression-history rows before incremental continuation.
- Rate, progress, literal review/annotation and favorite membership.
- Actual matching FB2 paragraphs through the production book-stream reader,
  which supports the resulting PPMd ZIP entries.
- The prepared Reader file's measured size, untouched update input and neighboring
  catalogue, a WITHOUT ROWID probe with embedded NUL data and idempotent recovery.
- Actual new-only compression after recovery: an incomplete update selects zero
  books, while a committed update selects exactly the new book and skips the old
  physical copies. A second new-only operation selects zero and skips every
  processed physical member. The original compressed payloads and sizes are
  checked again after continuation.

The Reader assertion checks its prepared file size; it is not a visual Reader
window or byte-for-byte prepared-cache test.

## Exact coverage

| Variant on each architecture | Actual process termination stages | Cases per architecture |
|---|---|---:|
| Two bound compressed copies | journal-published, rows-written, before-commit, commit-start, catalogue-committed, stores-committed | 6 |
| Ordinary compressed catalogue | catalogue-committed, stores-committed | 2 |

All sixteen compressed cases passed. The final Win64 stores-committed pilot is
reused in this coverage total instead of being rerun just to complete a matrix.
Two additional unchanged plain-ZIP bound recovery cases also passed.

| Platform | Evidence | Native seconds | Native binary SHA-256 |
|---|---|---:|---|
| Win64 | matrix `r434` plus final pilot `r432` | 228.093 | `8788b63ca93ca2121f4501adae99ca309de86424ab217494d6b422f07431b9b4` |
| Win32 | matrix `r435` | 241.874 | `fffabbb30b58098d56d3737b6020eec24f503d547116900f9aa66dacb6a572a8` |
| Win64 plain regression | `update-compressed-legacy-Win64-r437` | 25.843 | same Win64 binary |
| Win32 plain regression | `update-compressed-legacy-Win32-r438` | 27.141 | same Win32 binary |

Licensed IDE build logs are `update-compressed-recovery-build-Win64-r431` and
`update-compressed-recovery-build-Win32-r433`. Original local project files were
unchanged. Exact reports, linked package/helper hashes, crash/startup logs and
coverage are retained under `G:/HL-b14-external`; the verified aggregate is
`update-compressed-recovery-validation-r439/summary.json`. All eighteen passing
private runtimes were removed, confirmed both by each validator and independently
by the aggregate check. The system drive retained about 20 GiB free; new heavy
outputs and temporary profiles stayed on G:.

## Test corrections and remaining scope

The first pilot `r424` used the old standalone Delphi ZIP reader, which cannot
read PPMd; the fixture now uses the actual production book-stream API. The next
pilot `r427` expected literal unprefixed paragraph markup even though compression
validly emits namespace prefixes. The first semantic assertion (`r430`) then
accessed the simple-text property on a mixed-content paragraph; it now searches
for the exact text-only identifying paragraph without discarding inline markup.
These were diagnostic fixture errors, not product recovery failures.

This proves actual reviewed-update process recovery for these small compressed
FB2/ZIP catalogues and incremental continuation. Crashes involving separate
FLibrary/JPEG XL image archives, interruption inside recovery/cleanup, production
scale and final distribution/visual gates remain separate work. No user's library,
Desktop executable or published release was changed.

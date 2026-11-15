# FLibrary compression followed by reviewed INPX updates

## Fixed behavior

A normal compression operation could stop with Python exit code 2 before replacing
an FLibrary archive. `ValidateRestored` derived the measurement helper directory
using Windows `ExtractFileDir` on the module worker path, whose suffix uses `/`.
That resolved the helper outside `tools/bookconvert`. The operation now resolves
`bookconvert\restored_book_validation.py` against its canonical `ToolsRoot`,
matching the existing estimate-worker resolution. No processing-package change is
needed.

The new native `reviewed-flibrary-compression` scenario uses the installed
BookProcessing packages from `packages-r195`, the verified official libjxl 0.13.0
archives and the normal runtime tool resolver. The first run (`r407`) reproduced
the product failure. The corrected path lets the actual operation complete.

## Scope of the new composition check

Four generated books occupy three real outer 7z archives. They include FB2,
ordinary ZIP EPUB, EPUB stored as nested 7z, separate cover/image ZIP and 7z
archives, an image-zero cover, JPEG XL covers, a Cyrillic resource path and two
EPUB paths sharing a cover. This variant adds a deterministic large color JPEG
so grayscale balanced compression must actually save external-image bytes.
The old retention fixture keeps its existing small images.

The native test:

1. Decodes the original covers and reconstructs all original resources.
2. Runs `TBookCompressionOperation` with `BuildCollectionCompressionPlan`, actual
   installed tools, grayscale balanced quality and no backup request. It requires
   image changes and positive physical savings.
3. Invalidates catalogue/Reader caches, acknowledges completed jobs, and then
   reopens all four complete books. The seven-zip operation lease correctly
   prevents opening them before that acknowledgment.
4. Applies an actual reviewed full INPX twice, corrects titles through another
   full INPX, then applies an append INPX. Publisher ZIP names must continue to
   resolve the physically present FLibrary 7z archives.
5. Runs new-only compression after the repeated full update, after the metadata
   correction and after append. Each selects zero books and recognizes all four
   as previously processed.

Every post-compression phase checks complete reconstructed Reader file size
against the catalogue, exact FB2 body XML, all EPUB non-image resources, captured
post-compression image hashes, decoded preview-cover dimensions, every native
Reader image, progress and notes. Raw compressed member hashes, all outer and
side archive hashes and all four compression-history tables must stay unchanged
through updates and no-op compression. Each unselected `neighbor.bin` is also
checked against its original SHA-256 after compression and updates.

The first draft incorrectly required the initially compressed raw container to
keep its pre-compression hash (`r410`); normal container repacking may change it.
The fixture now captures the actual result while still checking exact text and
non-image resources against the originals. Another draft read a seven-zip book
before releasing its completed-operation lease (`r412`/`r415`); the fixture now
uses the main form's invalidate/acknowledge/read order. These are test corrections,
not additional product defects.

## Evidence

| Platform | Native run | Seconds | Native binary SHA-256 |
|---|---|---:|---|
| Win64 | `update-flibrary-Win64-r417` | 47.234 | `2fb91165ae502b31b7737338dc024cc61211d1bef217abb1e2defaf46ff688da` |
| Win32 | `update-flibrary-Win32-r419` | 56.281 | `dab1784ac116a3aeb51693828e9649b9645612d8530ea39cee4919384c4c75a5` |

Fresh licensed IDE builds are `update-flibrary-build-Win64-r416` and
`update-flibrary-build-Win32-r418`. Both verified the linked fixture and unchanged
local project files. Reports, native logs and aggregate
`G:/HL-b14-external/update-flibrary-validation-r422/summary.json` retain exact
package/codec/helper hashes. Both private runtimes were removed. The existing packed-copy retention scenario
also passed with these same binaries and packages on Win64 (`r420`, 15.063 s)
and Win32 (`r421`, 25.156 s): twelve original/published/reused per-book outcomes
on each architecture, with its own original-source folder unavailable after
publication. Those two additional private runtimes were also removed.

## Remaining work

This adds composed compression/update evidence for one unbound generated FLibrary
catalogue. It does not prove new external-image downloads, merged FLibrary copies,
process-death recovery during this composed update, a user's complete collection,
or visually reopened Reader windows. Those remain separate gates. Desktop files
and published releases were not changed.

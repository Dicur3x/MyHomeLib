# Native FLibrary sidecars through packed-copy retention

Local beta-14 validation following `423aeeba`. This change adds fixture coverage
and modernizes that fixture's installed runtime paths; it does not change the
production packing or reading algorithm. No user-library mutation, Desktop
replacement or publication is included.

## Inputs and native operations

`packing_flibrary_fixtures.py` generates four books in three real outer 7z
archives with five sibling image/cover archives. Its layouts cover:

- An EPUB ZIP with separate `covers/*.zip` and `images/*.zip` archives.
- An EPUB stored as nested 7z while retaining its `.epub` member name, plus
  an FB2 in the same outer archive; their side archives are actual 7z.
- An EPUB ZIP with its cover at `images/<archive>.zip` member `<book>/0`,
  without a separate cover archive.

Each EPUB has eleven ordinary resources: mimetype, container, OPF, text with
inline markup, CSS, NCX, auxiliary bytes and three image paths. Two image paths
refer to the same stored cover; another path has Cyrillic characters and a
space. The fixture uses the repository's synthetic JPEG/JPEG XL reconstruction
pair for covers and deterministic generated JPEG bytes for illustrations.
The encoded cover SHA-256 is
`7841bc07233dc875030c245c49a8bd2d6c55d3249e3dba753811991b263f2e04`.
Each outer archive also contains an unselected neighboring member.

The native scenario creates an isolated catalogue and personal cards with 37%
progress and a distinct note. It installs the verified official libjxl 0.13.0
reading and encoding components separately under `HomeLibre.exe`. It verifies
the original collection, creates a packed copy through
`TCollectionPackingSnapshot`, hides the entire original folder, then reads the
copy and publishes/reads a retained generation. The three outer sources must
be reused, and total stored bytes must not grow.

At each of those three stages, all four books must pass:

- Exact raw book member SHA-256 and complete outer/side archive SHA-256 values,
  including the unselected neighboring books.
- Actual `GetBookPreviewCoverStream` decoding with the expected 32 × 24 cover.
- Preserved declared catalogue size, personal progress and note.
- Complete reconstructed EPUB resource hashes, first/uncompressed mimetype,
  absence of the private image index and successful native reading of all three
  pictures, including the alias.
- For FB2, complete body XML equality, exact recovered JPEG hashes for both
  `cover` and `1`, and successful native text/cover/illustration reading.

Original archive hashes are also checked after restoring the hidden folder.
The preview check exercises the catalogue's cover stream and decoder; it does
not inspect a rendered information panel.

## Exact gates

The installed BookProcessing candidates are unchanged `packages-r78`, recorded
with their full sizes and hashes in the preceding PDF/EPUB export audit.

| Platform | Run | Seconds | Native fixture SHA-256 |
|---|---|---:|---|
| Win64 | `flibrary-sidecars-Win64-r87` | 19.156 | `e40bb640675c1806aadc45bff4eded9a6dddf1bdb21a9d48e7bc17608e4d4b4b` |
| Win32 | `flibrary-sidecars-Win32-r88` | 18.812 | `ad8f6872dee1eb5b66ab6997fd0e7da396a0c2b1b6726b1fc5fe638259352c20` |

Both passed the final outcome, separate component-installation outcome and all
twelve per-book outcomes (four books checked three times). Both private
runtimes were removed; the saved report/log remain under each run folder in
`G:/HomeLibRu-build-cache/HomeLibre-post13-legacy-history-20261114`.

Fresh licensed IDE build logs are
`CompressionRecovery.local-Win64-4b8f0027c1c1.err` and
`CompressionRecovery.local-Win32-e34a2ef126ed.err`. Both builds verified the
linked `packed-flibrary-sidecars` scenario and unchanged project files.

The first Win64 attempt `r85` stopped on a test setup error: it queried a personal
card that had not been created. The fixture now explicitly creates favorite
cards as the preceding native JPEG XL fixture does. No product change was
made for that assertion, and its private runtime was removed. A pre-run review
also changed dynamic filename lookups to literal JSON member lookups, so dots
in archive names cannot be interpreted as JSON paths.

## Remaining scope

This proves retention and reading of the generated legacy sidecar layouts in
a published packed copy. It does not prove recompression of external images
in place, every FLibrary release, the full catalogue UI or a user's complete
collection. Automatic missing-component download/continuation, bounded copies
of user data and final application/distribution gates remain separate work.
Previously passing broad Packer and native recovery suites were not rerun:
this step changes only diagnostic fixture code and documentation.

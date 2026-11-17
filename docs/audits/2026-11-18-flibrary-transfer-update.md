# FLibrary compression, physical transfer and subsequent INPX

The opt-in native gate composes the existing compression, source-refresh and
reviewed full/append INPX workers with the complete transfer coordinator. It uses
private generated data on G:, not the user's collection or Desktop.

## Defect found and fixed

The current packaged producer failed before transfer with the message
`Внешние картинки изменили содержимое книги другого формата.` An independent
fixture reproduced `detect_input(201.epub) == '.html'` for a genuine FLibrary
7z-encoded EPUB. Stored 7z resources contain visible HTML; generic signature
inspection interpreted that internal markup as the enclosing book format.

Selected compression now recognizes the bounded EPUB resource root inside a
7z stream before generic sniffing, only for declared EPUB inside an actual outer
7z container. The listing keeps the existing 20,000-file/64-MiB resource bounds.
Ordinary wrong-suffix input still uses actual format detection. Complete native
restoration and text/structure/resource validation remain required before
publication. Retained legacy nested streams avoid the ordinary ZIP-only image
hash collector. Unsupported full-book diagnostics include member and format.

Two real 7-Zip/image-helper regressions verify stored nested EPUB optimization
with text/styles/fonts/SVG and neighbour preservation, and an unrelated archive
containing HTML that must retain its payload and not enter EPUB optimization.
Eleven existing checks cover ordinary wrong-suffix EPUB, two-format preservation,
image reuse, source changes, cancellation and full-restoration rejection/cleanup.
All thirteen passed, and their private runtimes were removed.

## Composed native scenario

- Four FB2/EPUB identities have two independent physical source copies with
  equally named book, cover and image archives (sixteen files total). Layouts
  include ZIP EPUB resources, nested 7z resources, JPEG XL covers and the zero
  cover shortcut. The separately registered original fixture is preserved.
- Actual balanced grayscale compression measures complete restored books and
  checks readable text, all resources/covers, progress, notes and favourites.
- Transfer publishes files, catalogue roots, two source caches and two saved
  update profiles. All sixteen archive hashes must match, exclusive originals
  are released, old roots renamed offline, source/copy IDs retained.
- Compression witnesses are compared for the current physical files. Historical
  original-key rows intentionally remain in the database and are not counted
  as duplicate active witnesses.
- Full, repeated, append and either-source INPX updates must work without old
  archives. A new archive and two image sidecars arrive in another folder.
  New-only compression skips the eight retained members and processes only the
  arrival; a following pass skips all nine. Prepared resources, covers, measured
  sizes, history and personal data remain valid throughout.

Both r1563 native runs passed, with eight PASS markers per architecture.
Private runtimes were removed.

| Architecture | Seconds | Native binary SHA-256 |
| --- | ---: | --- |
| Win64 | 163.25 | `90748ae191dc68f7a6d12eb446439611762f0c887064b54147be3ecb92c93bdd` |
| Win32 | 167.641 | `0b3e75e9cffbdde0aba3dc0739e48e8f015d70afb347f81cf1072b5271db4b0b` |

Full source/package/report bindings are recorded in
`G:/HL-b14-external/transfer-flibrary-update-validation-r1565/summary.json`.
Reports: `transfer-flibrary-update-{Win64,Win32}-r1563`.
The thirteen Python checks are bound in r1561/r1564.

Licensed IDE builds r1562 bind 685 identical C:/G: native inputs. Main/Reader
Pascal code is unchanged by this producer fix; final release apps and packages
remain a separate gate. The current BookProcessing packages were built by the
ordinary package script in r1559; all six packing workers are checked byte for
byte against current source before each native run.

## Earlier diagnostics and limits

r1557 is the real pre-transfer format-classification failure. r1558 independently
reproduced the wrong `.html` classification and removed its fixture. r1560 passed
compression and transfer but a new test incorrectly compared all historical and
current compression rows together; transfer deliberately copies witnesses to
new physical keys while retaining old keys. r1562 corrects that test to compare
only the respective current physical files. These failed runs are not PASS
reports; their owned runtimes were removed by the validator.

This is a small generated FLibrary FB2/EPUB gate on one NTFS volume, not a new
large-library benchmark or ordinary visible transfer-menu test. It does not
cover every format, empty-LIBID post-transfer updates, real ENOSPC/offline-volume
failure, different filesystems, final beta-14 packages or a user-library move.
No OCR, user-data compression, Desktop replacement or publication was performed.

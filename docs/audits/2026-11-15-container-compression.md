# ODT, DOCX and CBZ image compression in their original formats

## Change

The working-collection inventory confirmed useful image containers beyond
FB2/EPUB. Collection compression now dispatches detected ODT, DOCX and CBZ
payloads to a same-format image handler instead of treating them as packing-only.
This connects to selection/incremental preparation and the existing copy packer;
the native tests below exercise selected publication, estimation and reuse.

The handler changes declared JPEG/PNG resources only. It retains their encoding
and exact member names, preserving references and MIME declarations. Other
document parts, embedded attachments, SVG, styles and text stay byte-identical.
If ODT explicitly records an image's byte count, only that manifest attribute
is updated; the rest of its XML tree, comments and processing instructions are
preserved. ZIP order, comments, compression methods and entry attributes are
retained, including zero Office attributes that Python otherwise replaces with
Unix permissions. `mimetype` stays first and uncompressed in accepted ODTs.

Digitally signed or encrypted packages are not silently rewritten. Ambiguous
names and malformed or oversized containers are rejected. Existing preparation
handles the error by retaining the original. Unsupported resource types remain
untouched. A candidate which does not reduce the book or final archive size is
not published by the existing preparation/publication gates.

`HomeLibImages` advertises `same-format` and accepts `--keep-format` for PNG/JPEG
export. This option does not alter its existing FB2/EPUB image commands. A
grayscale original-quality JPEG stays JPEG; color maximum-quality output is
also checked. Converter `PACKING_IMAGE_API` is now 4. The new handler is required
in BookProcessing packaging and included in the native engine fingerprint.
JPEG XL separation remains explicitly restricted to its existing FB2/EPUB path;
the broader image-format set must not route Office/comic ZIPs into EPUB logic.

Estimation and comparison support the new containers. Their comparison witness
contains the actual before/after image bytes, not resized thumbnails.

## Verification

Images and operation fixtures were isolated, with all preparation on G: and
more than 8 GiB free on C:. No working catalogue, personal database or original
collection archive was changed. Native operation binaries were rebuilt through
the licensed Delphi IDE for both architectures (`container-native-build-Win64-r655`
and `container-native-build-Win32-r656`). Fresh image helpers are `images-r653`.

Each of the three native container cases checks:

- Estimation without source/database/backup/job writes, followed by reviewed
  native compression and publication of a smaller book.
- Original-format decoded images and grayscale pixels; unchanged text,
  relationships, SVG, styles, XML/container resources and unselected PNG
  attachments. ODT's explicit image sizes match the new payload lengths.
- Actual comparison pairs by SHA-256, exact backup original, unchanged neighbor
  book and non-size catalogue/personal fields, and correct measured sizes in
  all three stores.
- Native `GetBookStream` readback, a repeat without writes, and a new worker
  identity which reuses prior image results with zero newly processed images.

Additional cases cover signed documents, selected-resource boundaries,
cancellation remaining cancellation, grayscale original/color maximum PNG/JPEG
encoding, and rejection of deliberately changed PNG attachments by the separate
preservation gate. Existing wrong-suffix FB2/EPUB native cases check the shared
image-helper regression boundary.

| Evidence under `G:/HL-b14-external/` | Outcome |
| --- | --- |
| `container-native-Win64-r657` | Initial three native containers PASS, 26.156 s. |
| `container-complete-Win64-r660` / `container-complete-Win32-r661` | Nine cases each PASS, including estimation/comparison and explicit ODT sizes, 47.907 / 49.204 s. |
| `container-final-Win64-r663` / `container-final-Win32-r664` | Nine cases each PASS after retaining zero Office attributes, 47.766 / 49.109 s. |
| `container-guarded-Win64-r666` / `container-guarded-Win32-r667` | Final ten cases each PASS with the stronger declared-resource preservation gate, 51.328 / 52.172 s. |

Final reports contain zero failures, errors or skips. All private native
runtimes were removed. The synthetic native book fixtures are not evidence
that arbitrary Office/comic documents have been visually rendered in their
external viewers. Actual working-catalogue write trials and final application
UI/distribution checks remain separate work.

## Final local module candidates

Use `G:/HL-b14-external/packages-r665`, not r647/r654/r659/r662, for the next
minimal/full distribution assembly. These 3.0.0.14 ZIPs are unpublished:

| Module | Win32 SHA-256 | Win64 SHA-256 |
| --- | --- | --- |
| BookProcessing | `4719234ee3d31bc3271341de7141e830c473fc9c44eef2141ea4882b4e9e341f` | `6b4a0bd36c1a832b6026263dd42a73224b291a191964f34562833ab9f2d0758a` |
| ImageProcessing | `6f7f01b023a94e1fca65c9c44b3c03fac431df62f03dfe92343a3d32c470c0d3` | `2544efb5d075074a998d052a1dbf4479762b7de6449206fff828c7a0a1cadb2d` |

## Remaining format scope

The existing 64 MiB book and 16 MiB individual raster processing limits remain;
larger payloads retain their original contents. This does not complete arbitrary-format compression. Other Office/comic
containers, other image encodings in these three formats, remaining ambiguous
catalogue names and broader PDF/DjVu quality processing remain open. Existing
WebP handling for FB2/EPUB is unchanged; this handler does not claim WebP
re-encoding in Office/comic containers. The copy-packer integration still needs
its own end-to-end check. Desktop replacement and publication await the full
beta 14 completion gates.

Package structure was checked against the primary
[ODF package specification](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part2-packages.html)
and [Microsoft's Open XML overview](https://learn.microsoft.com/en-us/office/open-xml/about-the-open-xml-sdk).

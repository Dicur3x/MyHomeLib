# Static GIF export: implementation and pending checks

The user chose one static frame for beta 14 conversion, retaining original
files. After beta 14, measure GIF and animated-GIF frequency in the actual
collection before deciding about animation or frame-by-frame export controls.
No such frequency measurement or UI choice has been implemented now.

## Code added

- The Windows image helper accepts `--gif-first-frame`. It validates bounded
  GIF canvas/frame dimensions and sub-block boundaries, constructs a complete
  single-frame GIF, then renders that frame into a PNG on its logical canvas.
  Later animation frames are not decoded. Output must be new and incomplete
  output owned by the helper is removed on failure.
- `gif_static.py` uses the private export directory, a cancellable 30-second
  helper call, dimension/output checks and a runtime capability marker.
  An older image module requests an update rather than receiving an unsupported
  command. Repeated identical GIFs share a decoded result within the book.
- Normal format conversion prepares GIFs in the generated FB2/EPUB before
  downstream image-quality processing. Advanced writers and MOBI/AZW3 also
  apply the policy to an existing intermediate format. Reading and ordinary
  copies in their original format retain their existing preservation behavior;
  same-format collection compression does not acquire this export policy.
- FB2 keeps binary IDs and references. EPUB preparation updates manifest MIME
  types/paths, links, CSS URLs, `srcset`, SVG references and NCX references.
  Inline base64 GIFs use a shared static resource. GIF-only preparation retains
  SVG content and unrelated scripts instead of invoking the KFX SVG rasterizer.
  Signed EPUBs requiring changes are rejected before replacing the private book.
- New image/XPS builds include `gif_static_api: 1`; their packaging checks and
  the BookProcessing required-file list include this dependency change.

## Evidence available

`G:/HL-b14-external/gif-static-boundaries-r1450/pure-capability.log` passes ten
lightweight tests: module availability/version capability, input/output bounds,
cancellation and cleanup, and source-set URL handling including data-URL commas.
They do not execute the native decoder or process ZIP archives. Python source
syntax and the repository whitespace check pass.

## Still required

System free space remained below the workspace's 8 GiB reserve; production
builds and archive-based checks have not resumed. The user identified an active
Windows installation assistant and is freeing space separately.

- Build current images-only and XPS helpers on x86/x64. Test six-frame GIFs,
  partial first-frame offsets, logical-canvas background/transparency, occupied
  outputs and malformed inputs against an independent decoder.
- Run the FB2/EPUB policy tests and KFX preparation tests, plus relevant existing
  conversion/writer regression suites. These integration tests are written but
  have not run in this low-reserve step.
- Rebuild the patched KfxExport 3.0.0.6 and its versioned corresponding source.
  Re-run real CHM/LIT/DOCX exports with independent text, first-frame pixels,
  image-link and position-map checks. The old six-frame resource assertion in
  the unexecuted private probe must be replaced with the user's static policy;
  retaining an animation is no longer the acceptance criterion.
- Verify EPUB books with multiple package documents: the shared preparation
  currently requires one package. Do not claim universal coverage of this case.
- Produce coherent fresh components, native GUI/update checks and final packages.
  No Desktop replacement or release follows from the lightweight tests alone.

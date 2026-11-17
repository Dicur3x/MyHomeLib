# Static GIF export: implementation and sealed checks

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

The initial low-reserve checkpoint passed ten lightweight boundary/URL tests
without native decoding or ZIP processing (`gif-static-boundaries-r1450`).
After the reserve recovered, validation continued:

- Fresh images-only helpers built from current source pass 30 methods each for
  Win64 and Win32 in `G:/HL-b14-external/gif-static-native-r1452/`. Four methods
  execute each real helper and compare complete RGBA pixels with independent
  Pillow decoding: six frames become one, partial-frame offsets retain their
  logical canvas, transparency survives, and an occupied output is preserved.
  These use host Python with separate x86/x64 executables; they do not establish
  the final embedded-Python or GUI package path.
- The same cohort exercises FB2/EPUB policy, signed packages, inline GIFs,
  references, reading/original preservation and the existing KFX image tests.
- Two additional native methods pass on each architecture: interlaced first
  frames match every independent RGBA pixel; malformed/truncated headers,
  oversized canvases, out-of-bounds frames and bad sub-blocks leave no partial
  output and preserve their inputs. Logs: `Win64-additional-native.log` and
  `Win32-additional-native.log` in the same evidence directory.
- Four in-memory package-graph checks pass for shared/inline images in two
  package documents, no-GIF books and signature rejection (`gif-package-model-r1451`).
  A separate real-ZIP test passes shared and inline variants, checking every
  CRC, both package manifests, text/links and the untouched original file:
  `gif-static-native-r1452/multiple-package-zip.log`.
- Writer regression: 27 methods pass, with three explicit installed-writer
  skips, in `gif-static-native-r1452/writer-regression.log`.
- The actual six-frame 88 x 31 GIF from CHM 776538 becomes a one-frame PNG with
  byte-for-byte equal decoded RGBA pixels on both helpers. Alpha and appearance
  on black/white backgrounds also match; the source CHM hash is unchanged.
  Evidence: `G:/HL-b14-external/real-gif-first-frame-r1455/report.json`.

Fresh sealed components additionally pass all 18 real CHM/LIT/DOCX exports to
PDF/KFX/AZW8 on both embedded Python architectures. There are no source
overlays; every installed manifest file is verified. Independent readers check
text/order and decoded pixels; CHM KFX/AZW8 retain both image links and one
static frame. Consolidation:
`G:/HL-b14-external/sealed-writer-validation-r1467/summary.json`.
The versioned corresponding KFX source archive is built and verified too.
These results remain separate from final native GUI/update/release evidence.

## Still required

Earlier builds stopped below the workspace's 8 GiB reserve while the user's
Windows upgrade used system space. The reserve later recovered. A subsequent
KFX build was intentionally stopped by the user's explicit goal pause
(`kfx-module-build-r1453/user-pause.json`). These are intentional stops, not
successful builds or newly diagnosed compiler defects. Work resumed afterward.

- Current images-only and XPS helpers are built on x86/x64. Broader image/XPS
  regressions and fresh sealed components through the native application
  remain separate from the completed helper malformed-input checks.
- Patched KfxExport 3.0.0.6, corresponding source and real CHM/LIT/DOCX readback
  are complete. Full actual-format coverage and final application/update
  checks still remain; the 18 successful outputs do not establish those gates.
- GIF-only preparation now keeps multiple package documents and their shared
  resources. This does not expand the separate KFX writer's one-package limit
  or establish multi-rendition behavior on physical reading devices.
- Produce coherent fresh components, native GUI/update checks and final packages.
  No Desktop replacement or release follows from the lightweight tests alone.

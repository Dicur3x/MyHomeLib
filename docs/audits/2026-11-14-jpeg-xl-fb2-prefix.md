# JPEG XL packing and reading of namespace-prefixed FB2

Local beta-14 follow-up to `36da6861`. No Desktop replacement or public package
update is included. The Packer and reader changes must be shipped together.

## Findings

The byte-preserving FB2 separator used a namespace-aware XML parser, but then
required literal unprefixed `<binary>` and `</FictionBook>` tags. A valid FB2
using an XML prefix was silently left unchanged. A new isolated regression
failed (`{}` instead of the expected separated image) before the correction.
It now verifies exact preservation of namespaces, comments, CDATA, text and all
unrelated source bytes while removing only the selected binary element.

The first native codec runs `packed-jxl-Win64-r53/r55` used 258 distinct tiny
96x80 noisy JPEGs. The official codec saved only 186 bytes on a 7,092-byte image;
sidecar/container costs erased the benefit. `r55` diagnostics show identical
1,780,061-byte input/output totals and no optimized books. Keeping the original
was correct; the fixture's demand for optimization was not. This is separate
from the confirmed prefix defect. The bounded codec probe is retained in
`jxl-codec-probe-r57`; Python's ZIP reader initially could not decode the PPMd
official archive, so its selected tools were extracted with the shipped 7-Zip.

For the positive reconstruction case the fixture now uses 258 distinct 256x192
JPEGs. The measured first JPEG shrinks from 43,399 to 40,083 bytes. Inputs are
generated synthetic data, not user books/images. The full native run `r58`
then confirmed a second product defect: packing succeeded, but native reading
returned zero of 258 images. Its old closing-tag search also assumed an
unprefixed root; injected unqualified binaries would additionally lack the FB2
namespace under a prefixed-only root.

## Correction

The Packer uses the parser-confirmed qualified tag boundaries and copies all
other bytes unchanged. Existing cover/duplicate-ID exclusions and gain checks
remain in effect. The native reader locates the final qualified closing tag,
ignores trailing XML comments/processing instructions and adds an explicit FB2
namespace to reconstructed binary nodes. Image bytes are still restored by the
real JPEG XL decoder; no image-quality conversion is added.

The native fixture uses official release metadata rather than a synthesized
hardcoded 0.12.0 version. It verifies the cached archive's size/SHA-256, installs
the decoder and encoder separately into an owned installation containing
`HomeLibre.exe`, checks that installing the encoder preserves the decoder,
then packs and reads the prefixed FB2. Every recovered image must have its
original SHA-256, all 258 must be present and the book text must match. The
saved INPX continuation is also consumed through the actual main window.

## Artifacts and checks

Official libjxl 0.13.0 ZIPs were checked against their cached GitHub release
asset metadata before copying them into the private installation:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 40,648,942 | `e394519c05ea9e5b83947f89b40afbf1ea7c631a608406c5de945a4c5bdcdcb7` |
| Win32 | 33,978,294 | `2d3683fe2ac7b4cd08f4a6436e199631837ae61fea701c9277af918c2af67940` |

Local BookProcessing candidates in `packages-r54`:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 12,446,196 | `468386fb90eedb0ae223b8b0f5f984abf88520d245ec0cdefead6aebe643e99c` |
| Win32 | 11,186,821 | `6e7393abbb60c4a6dee1dc591629b4c9afc86771ccbbcbc940b6a891deb9ebb7` |

The expanded 54-case Packer suite passed without skips on both architectures:
Win64 `packer-jxl-Win64-r56`, 191.547 s; Win32 `packer-jxl-Win32-r59`, 178.094 s.
Their own temporary runtimes were removed. These include the new prefix case,
ordinary FB2/JPEG separation, original-byte guards, retention and earlier size
checks. The mock codec tests are not counted as real codec compatibility.

Win64 `packed-jxl-Win64-r61` passed the complete fifteen-marker codec/FBD/INPX
scenario in 105.422 s. All 258 recovered JPEG hashes and the complete body XML
matched; the resumed main window opened only the new records. Its temporary
runtime was removed. Fixture SHA-256:
`44cff3a881592cbf4b7ca6560e28e79f294045c10b2db14556a1343721757e72`.
Build log: `CompressionRecovery.local-Win64-82298f2c0d38.err`.

Win32 `packed-jxl-Win32-r62` passed the same complete fifteen-marker scenario
in 109.031 s, including all 258 original JPEG hashes, unchanged body XML and
the resumed main window. Its temporary runtime was removed. Fixture SHA-256:
`3d5cfe8deeed5ee775ac69da4ed0ba5d5c741889298380f528b0ae2c68bb5026`.
Build log: `CompressionRecovery.local-Win32-e8e1871e6eb5.err`.

The preceding native prototype `r60` stopped in the newly added observer: the
XML binding's `.Text` property requires a single text node and cannot read a
complex body element. The final assertion compares `.XML` for the whole body
subtree, preserving its text, inline structure and image references. This was a
test correction, not a second reader change.

## Scope still open

This does not establish automatic network download and restart from a missing
component prompt. Component installation is invoked directly before the packed
INPX operation; the main-window restart tests INPX continuation. Whole-file FB2
serialization is not claimed byte-identical: the lossless promise here is exact
JPEG restoration and preservation of text/content. Native PDF/EPUB JPEG XL,
existing FLibrary sidecars, user-data copies and final distributions still need
their respective remaining checks.
The final component feed must keep the new Packer paired with the beta-14
reader; publishing this Python module alone to an older host is not validated.

Follow-up: `2026-11-14-jpeg-xl-host-capability.md` adds and verifies an explicit
reader capability. Its guarded `packages-r63` candidates supersede `r54`; an
old-style job now keeps the complete prefixed book even with a new Python module.

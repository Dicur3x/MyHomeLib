`transparent-ink.jxl` is the 3,478-byte image `440380/1` from the supplemental
image archive for Aksakov's *Том 5. Записки ружейного охотника*, the book in the
reported black-illustration failure. No catalog or complete book is included.

SHA-256: `a36b190b6ac7e992119714bcfd2d87f1ffccecc03bd49a083f172d12d30d8fb8`.
Independent decoding produces a 354 × 378 RGBA image: all RGB channels are zero,
but alpha varies from 0 to 255. Pixel (0, 0) is transparent; (187, 0) is opaque.
The native regression tests those pixels after the actual archive extraction,
JPEG XL conversion, FB2 reconstruction and reader rendering. Converting this
input to JPEG discards its alpha and produces the reported black rectangle.

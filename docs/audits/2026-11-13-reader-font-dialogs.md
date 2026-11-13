# Reader font dialogs

Local beta 14 changes. Published packages and the Desktop installation have not been replaced.

The font-library table now paints its native column header, including the unused area after the last column, with the Reader's current background and text colours. This is scoped to the Reader font list rather than changing Windows list headers globally.

The Windows font picker is resizable. Its search field and font list follow the window size, and the list has a measured horizontal extent for long family names. Both dialogs put the sample inside its own scrolling area. Sample height is measured with the selected font rather than clipped to a fixed label height; selecting another family returns the sample to its beginning. Whole-dialog auto-scrolling is disabled so it does not compete with the font list and sample.

If a font is unavailable or a search finds nothing, the explanatory text uses the ordinary interface font. It no longer inherits the previous decorative or oversized sample typeface. The default reading font remains protected, and other listed fonts can still be hidden and restored.

## Native validation

`tools/ui/tests/ReaderFontManagerTest.dpr` opens the actual `ManageReaderFonts` dialog and its Windows picker. Both x86 and x64 passed ten cases: paper and dark colours at 96, 144, 192, 216 and 288 DPI. This is twenty manager/picker pairs across the two architectures.

The checks cover native header background and text pixels, the unused header strip, search results and empty-search behaviour, measured extent of the longest installed family name, window resizing, and reaching the last measured sample line at a deliberately large 48-point size. The reported `GungsuhChe` Windows family was present and was used for every final case. It was added, hidden and restored through the real dialog controls in a private Reader profile. Restoring it needed no download. The default font's Remove button stayed disabled, and an unrelated Unicode INI value was retained.

These are VCL layout-scale checks on the available monitor. The harness supplies the resized outer window that normally accompanies a DPI transition, preserving the child bounds already scaled by VCL. It does not change Windows display settings or claim a separate physical 4K-monitor run. An early attempt read outside the unresized native window and returned `CLR_INVALID`; this was a harness failure, not evidence of a white painted header. That result is retained separately. Client-image snapshots do not include the native header captions reliably; the caption assertions read the live header DC instead.

Evidence: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112\font-ui-Win32` and `font-ui-Win64`, each with result JSON, output and generated client images. Previous attempts are retained under `history`; the initial unresized-window result is `font-ui-Win64/scaled-header-failure.json`. Both final runs exited with status zero, completed ten cases and removed their private runtime. Font downloads were not requested, and the user's Reader profile was not used.

Final native SHA256:

| Architecture | SHA256 |
| --- | --- |
| x64 | `7be14e018430fa1c98e2f08ab46bd71052ed29db1f281aff3eb7d7a7999625b4` |
| x86 | `7a21e3264c19c8ac63a2f50f2b89ab10ef43b1fc1387c33df7f77436cd123607` |

Both were built with the licensed IDE's documented AutoBuild interface, retaining the original project bytes. The focused test links the actual font manager and font-library units; it is not a release package or a complete Reader regression run.

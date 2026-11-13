# Initial scale for image documents

Local beta 14 change, not a published release or Desktop replacement.

`View pages` now separates the current image scale from the initial scale of a new image document. The latter offers fit to width, source pixels (100%), and the previous image book's scale. Existing fit-to-width behavior remains the default until explicitly changed. Saved per-book scale always wins, including older profiles containing only `Zoom`. Ordinary text and temporary inspection zoom do not replace the previous continuous image scale. The rule uses the decoded raster document, not a manga title or genre; PDF, DjVu and multipage TIFF keep their existing page behavior.

`ReaderInitialScaleTest.dpr` exercises the real reader, modal appearance dialog, persistence, decoder and continuous strip dimensions on PNG, JPEG, CBZ and an image-only ZIP prepared by the ordinary reader pipeline. Each format covers all three choices, both original and enlarged previous scale, cancellation, unchanged current-book scale, reopening prior books, and migration from an old per-book zoom. A separate text book confirms that opening text leaves the previous image scale untouched. Sources retain their SHA-256. Private profiles and generated books are removed by the runner.

Both native runs exited 0 with four format groups plus the text isolation check:

| Architecture | Test EXE SHA-256 |
|---|---|
| x64 | `51157a7581966f6ce13c30ca67c1831d3a5d616659e2bea08c21252cbec5d426` |
| x86 | `a3f9fccc841b72d8fe07f56afdde1ba8bea3ddc1947dd935f5aaade7fbf60b0d` |

Reports and the disposable runner: `G:\HomeLibRu-build-cache\HomeLibre-post13-raster-initial-20261113\native-Win64\result.json` and the corresponding `native-Win32` folder. Builds use the licensed IDE's ordinary AutoBuild interface. Failed earlier test attempts are retained separately: one omitted test-unit imports; another incorrectly bypassed ZIP preparation and passed a raw ZIP directly to `OpenBook`. The final test uses the real `PrepareReaderFile` path for that case.

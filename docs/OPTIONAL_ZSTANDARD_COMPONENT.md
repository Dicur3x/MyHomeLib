# Optional Zstandard catalogue decoder

Zstandard is required only for importing or updating Metabib catalogues in
`.jsonl.zst`. Ordinary INPX catalogues and reading FB2/EPUB do not require it.
Minimal catalogue packages omit `libzstd.dll`; full developer distributions keep it.

The import wizard and manual catalogue update request the named component before
starting their workers. The compact prompt shows its download size. A verified
download installs the previously unloaded decoder and continues the selected
operation without restarting. Cancellation leaves the selected catalogue intact.
This path is restricted to Zstandard; executable updates and loaded DLLs retain
the normal restart transaction. A separately prepared application update is not
replaced by this operation.

`scripts/package-zstd-component.py` packages the exact official facebook/zstd
1.5.7 Windows DLLs, the full BSD licence and a descriptor identifying the official
source archive and both checksums. Packaging is offline and refuses other DLLs.
The installer allows only those three payload files, verifies platform and
checksums, and preserves the existing exact official legacy DLLs without a
descriptor. Component discovery does not load executable code.

The permanent component release hosts the packages once. They are hidden until
needed and do not generate default update notifications. Standalone Reader does
not list this catalogue decoder.

## Compatibility and release gate

Reader 1103 and older installers require `libzstd.dll` inside their Reader bundle.
Their existing packages remain compatible. Removing the DLL from new minimal
Reader bundles requires a compatible package/feed transition; this change alone
does not remove it from the legacy Reader feed.

The current source and local packages have passed native Win32 and Win64 checks:
real compact download, cancellation, corrupt archive rejection, installation,
legacy binary recognition and actual Metabib header/book/EOF decoding. They also
preserve the selected catalogue and a separately pending update. The current
updater changes passed MCP, existing published Reader/converter/PDFium package
installation and minimal Save As regressions on both architectures. Minimal
catalogue packaging excludes both Zstandard and MCP.

Reports and the packages awaiting publication are under
`tools/ui/tests/Out/post536-optional-zstd-20261028-r1/`. Fresh product builds,
publication of the merged component feed and final packaged application checks
remain required before the next application release.

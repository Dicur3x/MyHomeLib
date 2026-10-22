# Additional converter dependencies

Markdown uses **Mistune 3.3.4**, distributed unmodified in `vendor/mistune` under
BSD-3-Clause. Copyright (c) 2014, Hsiaoming Yang. The complete license is in
[vendor/MISTUNE_LICENSE.txt](vendor/MISTUNE_LICENSE.txt).

Source: https://github.com/lepture/mistune

Distribution: `mistune-3.3.4-py3-none-any.whl` from the official PyPI project.
SHA-256: `ee015381e955e370962968befe1d729ab60fafb6a715ac6751763fbce38c8d4a`.
Only production Python modules, the typing marker and license are included.
The compressed upstream wheel is approximately 67 KB; no additional interpreter
or package installation is required. Internal dependency updates are delivered
with HomeLib Ru.

Kindle inputs reuse the **KindleUnpack** distribution already shipped under
`tools/kindle`; its original license accompanies that component.
Old DOC inputs reuse the already shipped **DocSharp** component and licenses.
Neither path downloads code or runs macros while converting a book.

Binary PPT/XLS inputs share the same AnyCPU **HomeLibDoc** helper with
**DocSharp.Binary.Ppt/Xls/Common/Doc 0.21.0** (MIT/BSD-3-Clause). Their pinned
net462 assemblies and licenses are under `tools/doc`; all four compatible
versions are checked together against the official NuGet feeds. Office legacy
images use Windows GDI+, with dimension and output limits.

WPS/WPD use separate, compact **libwps 0.4.14**, **libwpd 0.10.3** and
**librevenge 0.0.6** command-line readers (MPL-2.0) on 64-bit Windows.
`Installer/OFFICE_LEGACY_RUNTIME.json` pins official MSYS2 clang64 packages,
production files, licenses and corresponding source archives. The complete
runtime notice and those source packages ship under `tools/office`.
The clang64 build uses libc++/libunwind (Apache-2.0 with LLVM exception) and
zlib; it does not require a separately installed Office suite or MSYS2.


Saved web pages (MHTML/CHM) use **html5lib 1.1** (MIT), **six 1.17.0** (MIT)
and **webencodings 0.5.1** (BSD-3-Clause), from their official PyPI wheels.
Production Python modules are in `vendor`; the complete original licenses are
`HTML5LIB_LICENSE.txt`, `SIX_LICENSE.txt`, and `WEBENCODINGS_LICENSE.txt` there.
No browser engine, network loader or package installation is used at runtime.
Together these sources add about 0.55 MB before compression.

Sources: https://github.com/html5lib/html5lib-python,
https://github.com/benjaminp/six, https://github.com/gsnedders/python-webencodings.

PDF text/rendering uses the bundled **PDFium** and DjVu uses the bundled
**DjVuLibre** command-line tools. Their licenses accompany those components.
The local layout analysis does not perform OCR. PalmDoc and TCR decoding are
independent implementations based on their documented binary formats; no
complete Calibre application is installed. LIT/LRF/Rocket eBook preparation uses the
separate GPLv3 helper described below.

Pinned wheel SHA-256 values:

- `html5lib-1.1-py2.py3-none-any.whl`: `0d78f8fde1c230e99fe37986a60526d7049ed4bf8a9fadbad5f00e22e58e041d`.
- `six-1.17.0-py2.py3-none-any.whl`: `4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274`.
- `webencodings-0.5.1-py2.py3-none-any.whl`: `a0af1213f3c2226497a97e2b3aa01a7e4bee4f403f95be16fc9acd2947514a78`.


Legacy LIT/LRF/Rocket eBook decoding runs in a separate **GPL-3.0-only**
process, using a small read-only subset of **calibre**, pinned to
`1c1b407d76e23d4a1294d61bf73d915f247e3b83`. XML adaptation, bounded reads,
decompression and file-based IPC are local modifications. The complete
corresponding helper sources and reproducible native build script are in
this repository (`tools/bookconvert/legacy_helper.py`,
`tools/bookconvert/vendor/calibre_legacy`, `scripts/prepare-legacy-runtime.py`).
The exact source origins and checksums are recorded in `SOURCE.json`.

The helper also prepares old Mobipocket files with container/default keys,
using PC1 and format logic adapted from **DeDRM_tools**, GPLv3, pinned to
`7379b453199ed1ba91bf3a4ce4875d5ed3c309a9`. It does not read account or device
credentials. Copyright notices remain in the sources. Native LZX is
**libmspack**, LGPL-2.1; the D3DES core is public domain and its LIT-specific
substitution tables are **OpenCLit**, GPL-2.0-or-later (Dan A. Jackson, 2002).
They are combined into the GPLv3 helper. Full GPLv3
and LGPL-2.1 license texts ship beside the helper. No external application
or package manager is installed when a book is opened.

Sources: https://github.com/kovidgoyal/calibre,
https://github.com/noDRM/DeDRM_tools, https://github.com/kyz/libmspack.

## HA CPY/ASC decoder

`ha_input.py` is an Apache-2.0 Python adaptation of Mike Krueger's
**unarc-rs** HA reader and arithmetic/ASC decoder, pinned to
`b017fed390a8021faa198d0c842c95d13ecbaf6d`. It adds input/output bounds,
CRC32 validation, isolated conversion and the HA escape-weight cutoff fix.
The full license and exact source checksums are in `vendor/ha`.
Source: https://github.com/mkrueger/unarc-rs.

`HomeLibXps.exe` is original MIT code in `Utils/HomeLibXps`, using the XPS
and image decoders supplied by Windows/.NET Framework. It contains no
third-party rendering engine. Its source and binary hashes ship in
`tools/xps/RUNTIME.json`.

# HomeLibDjvu

Private persistent DjVu renderer for HomeLibre, GPL-2.0-or-later.
Build `HomeLibDjvu.dproj` in RAD Studio, Release / Windows 32-bit. The same
helper runs beside either Win32 or Win64 HomeLibre; the official 32-bit
DjVuLibre library is never loaded into the main application.

One document stays open per reader. Three decoded page handles and a 32 MiB
DjVuLibre cache are retained; output is bounded to 4000 pixels on the longest
side and 16 million pixels. A private named buffer carries top-down BGRA
pixels. The parent owns a Windows job so cancellation and closing the reader
terminate the helper. There is no OCR or intermediate TIFF page cache.

The recovery command prepares a temporary index for a truncated bundled DjVu
when intact component boundaries still match the original directory. The
index keeps the original page numbers. Missing or unreadable components cause
normal page errors. The reader and exporter remove their temporary files.

Source paths in the repository include `Utils/HomeLibDjvu/HomeLibDjvu.dpr`,
`Utils/HomeLibDjvu/unit_DjvuRecovery.pas` and
`Program/Units/unit_DjvuProtocol.pas`. The distributed source copy retains
the original project: restore these relative paths before building, or change
its `uses` path to the adjacent `unit_DjvuProtocol.pas`. The matching official
DjVuLibre source archive, licences and dependency notices are in `tools/djvu`.

`Installer/RASTER_RUNTIME.json` pins the release binary separately from
official third-party files. Rebuild through the IDE, update this pin deliberately,
then prepare and validate both runtimes before packaging.

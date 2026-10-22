# HomeLibXps

Small MIT worker for Windows XPS fixed pages and complete multi-frame image
decoding, used by local ebook conversion. It uses .NET Framework 4.5+ WPF;
no viewer, printer, Office installation or additional rendering library is used.

Build each platform with `scripts/prepare-xps-runtime.ps1 -Platform Win32`
or `-Platform Win64`. The script uses the Windows .NET C# compiler and writes
the executable, source/binary identity manifest and MIT notice into the
matching runtime. Delphi application builds remain in the IDE.

The XPS worker validates package/markup bounds, rejects external resources,
DTD and arbitrary XAML, and renders standard 2005/06 XPS pages to PNG with
a maximum side of 1600 pixels. OpenXPS extensions are not claimed supported.
`--image-pages` decodes every frame of BMP/TIFF through the Windows image
codecs, retaining original pixel dimensions (up to 16 megapixels per frame).

The output is a new ZIP of sequential PNG pages. Original files are read-only;
partial output is removed on failure. The parent job handles cancellation,
memory limits and cleanup of the entire private operation folder.

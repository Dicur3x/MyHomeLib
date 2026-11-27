HomeLibDoc reads Word 97–2003 DOC, binary PowerPoint PPT and Excel XLS with
DocSharp.Binary 0.21.0. It produces temporary DOCX/PPTX/XLSX for the shared
reading/export parser. --image-to-png converts embedded BMP/TIFF/EMF/WMF
pictures through Windows GDI+. Recognized VML plots anchored to adjacent
paragraphs are rasterized as a single illustration, keeping the plot in the
text flow. Standard horizontal rules with a direct RGB fill can be restored
from the binary document when their picture placeholders are identifiable.
This includes rules that follow the original paragraph because Word omitted
an explicit alignment. Export preserves dimensions and color, and
approximates the shaded edge when present. Thin, solid inline rectangles with
a direct RGB fill and no outline keep their original scaled dimensions and
position in the paragraph. Unambiguous, text-anchored lines in otherwise
empty paragraphs retain their stroke width and can extend into the left
margin. Plain VML rules that
lie wholly in the spacing before a paragraph keep their position in that
space, width and stroke coverage in a transparent illustration. This
includes binary-verified anchors in explicitly set paragraph spacing up to
72 points. The illustration stays before the corresponding paragraph during
reflow. A verified foreground line under a short, indented heading stays
below that heading when Word stores its anchor in the next paragraph.
Horizontal lines anchored to the page margin are grouped by their paragraph
anchor. Each group keeps its geometry in a single transparent picture, and
the exporter reports the change from page-relative to flowing placement.
Vertical lines in a two-column gutter or outer margin retain their
original anchor and geometry as floating drawings in the temporary DOCX.
The outer margin also supports foreground lines in single-column sections.
The reader draws them in its text margins without adding space to the
text. EPUB preserves the geometry in XHTML and draws the strokes with CSS.
FB2 carries the geometry in a named style that HomeLibre Reader displays.
Export warns about placement changes and the FB2 reader limitation.
Remaining horizontal and vertical strokes with matching binary paragraph
anchors keep their lengths and relative positions in a transparent image
beside the linked paragraph. Simple page-anchored connectors at an explicit
section break keep their locations on a page-sized image. Export reports
the change to the original page layout. A DOC page-opening rule verified
against an explicit page break is kept above that page's opening text.
The ebook can change its distance from the edge of the printed page.
Transparent, standalone DrawingML text boxes that resize to fit their labels
keep their fonts, line wrapping and spacing in a compact reading image.
The label text stays available for search in HomeLibre Reader. Export
warns when the old floating position becomes part of the reading flow.
Supported floating VML shapes can form one diagram across several Word
paragraphs. The helper checks their binary anchors and uses paragraph
spacing, stacking order and label fonts to render them together. Supported
legend symbols stay next to the corresponding text in the reading order.
Scenes with open arrows, an inline caption and a PNG with top/bottom
wrapping keep the bitmap and captions together in one illustration. Caption
text is also carried in its description and used in text-only conversion.
Export reports the change from floating to flowing placement.
Other unsupported drawings stay in the temporary DOCX for the normal
formatting fallback.
Original files are read only. Word and LibreOffice are not used. The helper is AnyCPU;
Windows .NET Framework 4.6.2+ is checked quietly by the calling application.

Build HomeLibDoc.cs, DocVmlFigures.cs and DrawingMlFigures.cs with the Windows .NET Framework C#
compiler, /target:exe /platform:anycpu /optimize+, and references to
System.Drawing.dll, System.IO.Compression.dll, System.Xml.Linq.dll, and the
four pinned net462 DLLs (Doc, Common, Ppt, Xls).
Place the tested executable in Out/HomeLibDoc.exe. Installer/DOC_RUNTIME.json
pins the source, helper, packages and DLLs. Update the pin after an intentional
source change and rerun the black-box and native reader checks before packaging.
scripts/prepare-doc-runtime.ps1 -Platform Win64 -Copy obtains hash-checked
dependencies and copies the helper and all licences into the build runtime.

Limits: 64 MiB source/output, 16 Mi UTF-16 main-text positions, 384 MiB child
process memory and 30 seconds in the caller. Cancellation terminates the child.
Output is create-new and removed on failure. VBA is neither copied nor executed.
Word 95 and password-protected DOC get explicit messages, no office installer.
Image input is limited to 16 MiB, 16384 pixels per side and 16 Mi pixels total.
Complete EMF and EMF+ figures that exceed the raster limits are drawn
directly at a smaller size with their aspect ratio preserved.
The caller bounds each image decode to 15 seconds. `--image-to-png-stream`
reuses the same GDI+ conversion in a single child process for each book.
The caller supplies a private working directory and sends one request byte
after staging each input. EOF ends the process. `--image-to-png` remains
available for existing callers. --version loads all four
assemblies to reject incompatible partial component updates before installation.

--drawingml-to-png reads an isolated Word shape or group from an XML request
with a figure root. The request can include document styles, theme and color
mapping. --drawingml-to-png-stream handles multiple drawings with the same
private workspace and response protocol as the embedded image decoder.
--drawingml-to-png-batch takes a figures root with shared styles and theme and
an ordered list of figure elements. Its ZIP contains a numbered PNG for each
supported figure. Missing numbers let the reader keep the original fallback.
Each figure can supply embedded PNG or JPEG bytes as base64 in an asset
element whose id matches the picture relationship. Rectangular pictures can
be cropped or converted to grayscale within the drawing.
Supported text boxes retain table borders, shading, merged cells and text.
They can also retain an inline PNG or JPEG beside the text, including the
position of the picture relative to the baseline.
Standalone shapes and cells support right-angle rotations. The calling code
retains selectable text and structured tables alongside the image.
Unsupported geometry, table styling and
embedded objects use the existing fallback. The helper opens no linked resources.

Licences shipped alongside the executable:
HomeLibDoc: MIT (repository LICENSE).
DocSharp: MIT, https://github.com/manfromarce/DocSharp.
Original b2xtranslator: BSD-3-Clause, DIaLOGIKa / Evolution Recruitment Solutions.

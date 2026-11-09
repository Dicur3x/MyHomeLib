# HomeLibre

[Русский](README.md) · [Українська](README.uk.md) · **English** · [Български](README.bg.md)

HomeLibre is a Windows application for organising, finding and reading ebooks.
It catalogues your own files and works with online library catalogues based on
the LibRusEc engine, including Flibusta.

This is a Russian-language fork of [MyHomeLib](https://github.com/OleksiyPenkov/MyHomeLib),
originally created by **Олексій Пеньков (Oleksiy Penkov)**.

[Download](https://github.com/Dicur3x/MyHomeLib/releases) ·
[Help](Program/Help/en/index.html) ·
[Report a bug](https://github.com/Dicur3x/MyHomeLib/issues) · [MIT](LICENSE)

## Download and run

[HomeLibre releases for Windows](https://github.com/Dicur3x/MyHomeLib/releases) · [Release history](docs/releases/README.md)

In the selected release, choose `HomeLibre_x64.zip` for 64-bit Windows or
`HomeLibre.zip` for 32-bit Windows. The same page has `SHA256SUMS.txt`
for checking the archives.

Requires **Windows 10 or later**. The archive contains the catalogue app.
Books are obtained separately.

1. Extract the archive to a folder you can write to.
2. Run **HomeLibRu.exe**.
3. Use the **Collection** menu to create an empty collection, import INPX or
   open an existing `.hlc2` catalogue.
4. Choose your books folder. Use **Collection → Import → Add file…** or drag
   files in from File Explorer. For a local collection, you can leave the files
   where they are and let HomeLibre store links to them.
5. Find a book by author, series, genre or search and open it.

**F1** opens help for the current window.
[Create a collection](Program/Help/en/new_collection.html) ·
[Add books](Program/Help/en/add_books.html).

## HomeLibre Reader

[Download HomeLibre Reader and components](https://github.com/Dicur3x/MyHomeLib/releases/tag/optional-alreader-2.5.1009.25)
Choose the HomeLibre Reader archive for Windows x86 or x64 from the list of assets.

To read files without the catalogue app, extract the Reader archive, run
**HomeLibReader.exe** and press **Ctrl+O**. If you open a book from the catalogue,
HomeLibre offers to install the reader the first time you need it.

### Supported reading formats

| File type | Formats | Additional module |
| --- | --- | --- |
| E-books | FB2, FB3, EPUB | Very large FB2 files may require BookProcessing |
| Text and markup | TXT, FAQ, WRI, RTF, MD, MARKDOWN, HTML, HTM, SHTML, XHTML, MHT, MHTML | Very large RTF files may require BookProcessing |
| Text documents | DOCX, ODT | Built in |
| Word and OpenDocument templates | DOC, DOT, DOCM, DOTX, DOTM, OTT | DocSharp for DOC and DOT. BookProcessing for the others |
| Presentations | PPT, PPS, POT, PPTX, PPTM, PPSX, PPSM, POTX, POTM, ODP, OTP | BookProcessing. PPT, PPS and POT also require DocSharp |
| Spreadsheets | XLS, XLT, XLSX, XLSM, XLTX, XLTM, ODS, OTS | BookProcessing. XLS and XLT also require DocSharp |
| Works and WordPerfect | WPS, WPD | BookProcessing and libwps/libwpd. Requires 64-bit Windows |
| Fixed-layout documents | PDF, DJVU, DJV, DJU, DJM, DJVM, XPS, OXPS | PDFium for PDF, DjVuLibre for DjVu, HomeLibXps and BookProcessing for XPS and OXPS |
| Kindle books | MOBI, AZW, AZW3, PRC | KindleUnpack and BookProcessing. Some older variants also require calibre codecs |
| Interactive books | SM | BookProcessing. You can save the route you played |
| Less common books and documents | CHM, LIT, LRF, RB, ABW, SXW, TCR, PDB, RGO, IBK, JUTOH, PAGES, CR3, B1, HA | BookProcessing. CHM requires 7-Zip, LIT and LRF require calibre codecs, and IBK requires ICE Book Reader data. Support depends on the file variant |
| Images and comics | JPG, JPEG, PNG, GIF, BMP, WEBP, TIF, TIFF, CBZ, CBR, CB7 | WebP requires libwebp. Some TIFF files require BookProcessing, and some comics require 7-Zip. JPEG XL illustrations in books require a JPEG XL decoder |

The reader can open supported books inside ZIP, FBZ, 7Z, 7ZIP, RAR, TAR, GZ,
GZIP, TGZ, BZ2, XZ, CAB and APK files. If a container has several books, you
can choose one. Some compression methods require 7-Zip.

The reader checks the file contents and can recognise a book with an incorrect
extension. It offers to install additional modules when needed. Presentations
and spreadsheets open without Microsoft Office installed.

Adjust colours, fonts, two-page spreads and smooth scrolling. The reader has
text search, a table of contents, bookmarks, notes and saved reading positions.
Use **File → Save as…** to save or convert the open book. Complex Office or EPUB
layouts may be simplified when preparing the book. [Reading help](Program/Help/en/reading.html).

## Features

### Catalogue and search

- Multiple local and online collections, with catalogues stored in SQLite.
- Import FB2, FBD, other files, INPX and metabib; books may be stored in ZIP
  and 7z. Connect existing MyHomeLib catalogues.
- Browse by author, book series, publisher series, genre and group.
  One book can belong to several series without duplicating its file.
- Search by author, translator, title, publisher, publication city/year, ISBN,
  series, genre, keywords, annotation,
  filename, date, language and rating; use expressions and saved search presets.
- Import and export presets as editable XML; legacy cxml/cxml2 files are supported.
  Import preserves existing presets and your current input.
- Combine column filters. **No duplicates by series** collapses repeated
  search results belonging to several series.
  An optional Publisher column has its own filter.
- Favourites, custom groups, ratings, reading progress, reviews and editable
  descriptions. Export personal information and favourite authors separately from the catalogue.
- Favourite authors: a saved list and new books after collection updates.
  Compact search and author-filter conditions; new books are marked seen explicitly.
- INPX updates, multiple sources with separate folders and priorities,
  folder synchronisation, database maintenance and collection merging with a preview.
- **Fill metadata from books…** fills selected empty publisher, publication city/year,
  ISBN and translator fields from local FB2/FBD, FB3, EPUB, DOCX and ODT, including
  supported books in archives. 7-Zip is offered on demand for PPMd ZIP and 7z.
  Open it from **Collection**, Sources, or the last page of a successfully completed
  local-collection wizard. Comparison and filling are separate actions; existing
  values stay unchanged. Annotation is off by default and can be enabled after
  seeing its approximate text size. Fields are taken only when the book contains
  them; the report explains read errors.
- Download selected books from an online library, including a download queue.
- Covers, annotations, an illustration gallery, author information and reviews
  when available from the source.

[Search](Program/Help/en/search.html) · [Groups](Program/Help/en/groups.html) ·
[Update a collection](Program/Help/en/update.html) ·
[Personal information](Program/Help/en/user_data.html) ·
[FB2/INPX metadata and review sources](docs/METADATA_AND_REVIEWS_RESEARCH_2026-10-15.md) (in Russian).

### External readers

The catalogue app can also open books in **AlReader** or **SumatraPDF**.
Choose an external reader from the book's context menu or assign one to a
file type in settings. [Reader settings](Program/Help/en/set_readers.html).

### Export and sharing

- **Save as…** keeps the original format or converts to FB2, FB2.ZIP, EPUB,
  TXT, MOBI or AZW3. For several books, keep each format or choose a common one.
  **More formats** shows EPUB 2, EPUB 3, KEPUB for Kobo, KFX and AZW8 for Kindle,
  PDF and Markdown when available for the selected books. Modules are offered
  when needed. Exporting EPUB to PDF uses Microsoft WebView2 Runtime.
- **Grayscale** removes colour from illustrations and scans in the saved copy.
  This can reduce its file size when colour is optional. Use it with any
  available compression setting, including **Maximum savings**. Select
  **Estimate size** to compare the results. Run the estimate again after
  changing the checkbox.
- When a PDF or DjVu has a text layer, conversion can carry over its text.
  Scanned pages are kept as images. For large scanned PDFs, the estimate
  samples pages and shows a range of likely file sizes.
- Originals stay unchanged. If a name already exists, replace the file, keep
  both or cancel. The destination and filename/subfolder templates are shared
  with Folder/Device settings. Custom export scripts remain separate commands.
  [Conversion limitations](tools/bookconvert/README.md) (in Russian).
- Export a catalogue to INPX, a book list to HTML, or personal information to a separate file.
- Export one group or all groups to metabib, including books from several
  collections. The portable folder contains `catalog.jsonl` and book archives;
  personal ratings, reviews, groups and progress are not included.
- A local **OPDS catalogue** lets another OPDS reader find and download your
  books. Start it manually for a selected local collection; access from another
  device is enabled separately.
- The **MCP server**, `MHLMcpServer.exe`, gives AI assistants access to search,
  metadata, a book's table of contents and text. It is read-only and does not
  require the main application to be running.

[Send to a device](Program/Help/en/export_device.html) ·
[INPX export](Program/Help/en/export_inpx.html) ·
[Connect MCP](Program/Help/en/mcp_server.html).

### Compact FLibrary and LightLib collections

HomeLibre supports ordinary INPX/ZIP collections and their compact variants:

| Collection | Supported features |
| --- | --- |
| [FLibrary](https://github.com/heimdallr/books) | 7z, separate `covers`/`images`, FB2/EPUB reconstruction, JPEG XL to JPEG/PNG |
| LightLib | Combined local LibRusEc/Flibusta INPX, ZIP/PPMd, multiple series, embedded WebP to PNG |

Choose the INPX file and the **root folder of the entire collection** in the
wizard. For FLibrary, keep the image folders beside the archives. Text can open
without missing images, but those images cannot be reconstructed.
WebP is converted by default when reading or exporting for compatibility;
you can choose to preserve the original in settings.

INPX contains the catalogue, not the books. Changing an archive path does not
add entries from a new release: update the collection from the corresponding INPX.
A combined LightLib INPX must be connected as a local collection.
[Format details and differences](FEATURES_RESEARCH_2026-10-05.md) (in Russian).

## Updates and your data

Update checking is available in the **Help** menu. A new profile checks
automatically every three days; your saved interval and **Never** choice are respected.
Background notifications appear only for a new version. A manual check also
reports that your version is current or that checking failed.

You start downloads and installation from the update window.
The application displays changes, prepares the files and restarts.
SQLite, SumatraPDF, DjVuLibre, 7-Zip and DocSharp are checked using
their authors' official resources. If a compatible release cannot be confirmed,
the window reports this. AlReader is available from one permanent verified archive.
Component archives are not duplicated with each HomeLibre release.

Before migrating from MyHomeLib or updating manually, close the application
and back up your profile and `.hlc2` collection files. Extract the new ZIP to
a separate folder so an old `MyHomeLib.exe` is not left beside the new application.

Archive installations are **portable by default**: settings stay beside the EXE,
and personal data is in `Data`. No `uselocaldata` marker is required. Collection
files and books may be kept in separately chosen folders.

When moving the application, retain its entire folder, including `myhomelib2.ini`,
`Data` and `presets.cxml2`, then check book and collection paths.

Release archives contain no personal databases, books, notes or history.
When rolling back the application, retain your current personal data; do not
automatically replace newer records with an old backup.
[Portable mode](Program/Help/en/portable.html) ·
[Application updates](Program/Help/en/upgrade.html).

## Languages and help

Russian is the primary language. Ukrainian, English and Bulgarian are available
from **View → Interface language**, taking effect after a restart.
The Bulgarian translation is automatic and has not been reviewed by a native
speaker. Help follows the selected interface language.

[Help contents](Program/Help/en/index.html) ·
[Keyboard shortcuts](Program/Help/en/hotkeys.html) · [FAQ](Program/Help/en/faq.html).

## For developers

Build with **Delphi 13 / RAD Studio 37.0**, VirtualTreeView and dependencies
of the matching architecture. Projects, the component patch, build order,
runtime preparation and checks are documented in [BUILDING.md](BUILDING.md) (in Russian).
The main project is `Program/HomeLibRu.dpr`; utilities are in `Utils/`,
and native tests are in `Program/Tests` and `tools/ui/tests`.

[Release history](https://github.com/Dicur3x/MyHomeLib/releases) ·
[Previous README history](docs/README_HISTORY_2026-10-14.md) · [Roadmap](ROADMAP.md).
The [Russian README](README.md) is the primary reference for current details.

## Credits and licence

Original project: **Олексій Пеньков (Oleksiy Penkov)**.
Programming: Oleksiy Penkov, Nikolay Rymanov, eg.
Development of HomeLibre: **Dicur3x**.
Testing: eg, Evgeniy_V, albert, AlbanSpy, kaznelson, Olega.

HomeLibre source code is licensed under [MIT](LICENSE), © 2008–2026 Oleksiy Penkov.
The licence covers the code, not the project's name; naming rules and bundled
component licences are described in [NOTICE](NOTICE).
Report bugs and suggestions through [Issues](https://github.com/Dicur3x/MyHomeLib/issues).

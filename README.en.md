# HomeLib Ru

[Русский](README.md) · [Українська](README.uk.md) · **English** · [Български](README.bg.md)

HomeLib Ru is a Windows application for organising, finding and reading ebooks.
It catalogues your own files and works with online library catalogues based on
the LibRusEc engine, including Flibusta.

This is a Russian-language fork of [MyHomeLib](https://github.com/OleksiyPenkov/MyHomeLib),
originally created by **Олексій Пеньков (Oleksiy Penkov)**.

[Download](https://github.com/Dicur3x/MyHomeLib/releases) ·
[Help](Program/Help/en/index.html) ·
[Report a bug](https://github.com/Dicur3x/MyHomeLib/issues) · [MIT](LICENSE)

## Download and run

The current published release is **pre5.17 / 2.7.0.1085**.
[Release notes](RELEASE_NOTES_2.7.0_pre5.17.md) ·
[Validation and limitations](docs/RELEASE_VALIDATION_2.7.0_pre5.17.md) (in Russian).

| Archive | System |
| --- | --- |
| [HomeLibRu_x64.zip](https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.17/HomeLibRu_x64.zip) | 64-bit Windows |
| [HomeLibRu.zip](https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.17/HomeLibRu.zip) | 32-bit Windows; also runs on 64-bit Windows |
| [SHA256.txt](https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.17/SHA256.txt) | Archive checksums |

Requires **Windows 10 or later**. Books are obtained separately and are not bundled.
Reading components are included: you do not need to install Delphi, Python
or a separate SQLite library to use the release.

1. Extract the entire archive to a folder you can write to.
2. Run **HomeLibRu.exe**.
3. Open the collection creation wizard from the **Collection** menu. Create
   an empty collection, import INPX, or connect an existing `.hlc2` catalogue.
4. Choose your books folder. For an ordinary local collection, add files
   through the **Book** menu.
5. Find a book in the author, series, genre or search tabs and open it.

**F1** opens help for the current window.
[Create a collection](Program/Help/en/new_collection.html) ·
[Add books](Program/Help/en/add_books.html) ·
[Read books](Program/Help/en/reading.html).

## Features

### Catalogue and search

- Multiple local and online collections, with catalogues stored in SQLite.
- Import FB2, FBD, other files, INPX and metabib; books may be stored in ZIP
  and 7z. Connect existing MyHomeLib catalogues.
- Browse by author, book series, publisher series, genre and group.
  One book can belong to several series without duplicating its file.
- Search by author, title, series, genre, keywords, annotation, filename,
  date, language and rating; use expressions and saved search presets.
- Combine column filters. **No duplicates by series** collapses repeated
  search results belonging to several series.
- Favourites, custom groups, ratings, reading progress, reviews and editable
  descriptions. Export personal information separately from the catalogue.
- INPX updates, multiple sources with separate folders and priorities,
  folder synchronisation, database maintenance and collection merging with a preview.
- Download selected books from an online library, including a download queue.
- Covers, annotations, an illustration gallery, author information and reviews
  when available from the source.

[Search](Program/Help/en/search.html) · [Groups](Program/Help/en/groups.html) ·
[Update a collection](Program/Help/en/update.html) ·
[Personal information](Program/Help/en/user_data.html).

### Reading

The built-in reader is enabled by default. It opens FB2, FB3, EPUB, TXT, RTF,
HTML/MHTML, Markdown, DOC/DOCX, ODT, PDF, DjVu, CBZ/CBR/CB7 comics and images.
Unencrypted MOBI/AZW/AZW3/PRC books are prepared before reading.
Some other office formats require an installed copy of LibreOffice.

- Light and dark themes; adjustable fonts, text width, colours and appearance.
- A tree table of contents, in-book search, footnotes, bookmarks and saved reading position.
- Select and copy FB2/EPUB/TXT text, and text from PDFs with a text layer.
- Navigate with the progress bar; zoom PDFs and images by holding the mouse
  button or clicking again, with an adjustable zoom level.
- Notes with quotations and positions; export notes for one book or all books
  to TXT, HTML or DOCX, with a choice of styles.
- A cache of prepared books: choose its folder and size limit, reuse files,
  clear it manually or on exit.
- Four bundled font families: PT Serif, PT Sans, Noto Serif and Noto Sans.
  Missing fonts for other scripts are offered with a download size and
  downloaded only when you choose to do so.

The `Readers` folder also includes **AlReader** and **SumatraPDF**.
Choose an external reader from a book's context menu and configure it per file
type. Existing reader assignments are preserved.

The built-in reader remains experimental: complex EPUB/CSS layouts may differ
from the original. Protected books are not decrypted; scans do not receive OCR.
[Reader settings](Program/Help/en/set_readers.html).

### Export and sharing

- Save books or send them to a device using filename and folder templates,
  external converters and custom scripts.
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

HomeLib Ru supports ordinary INPX/ZIP collections and their compact variants:

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
SQLite, AlReader, SumatraPDF, DjVuLibre, 7-Zip and DocSharp are checked using
their authors' official resources. If a compatible release cannot be confirmed,
the window reports this. Separate component packages are not published in HomeLib Ru Releases.

Before migrating from MyHomeLib or updating manually, close the application
and back up your profile and `.hlc2` collection files. Extract the new ZIP to
a separate folder so an old `MyHomeLib.exe` is not left beside the new application.

| Mode | Settings and data location |
| --- | --- |
| Normal | `%APPDATA%\MyHomeLib`; collection files may be in folders you chose |
| Portable | Beside the EXE, when an empty extensionless `uselocaldata` file is present or the same launch parameter is used |

When migrating a portable installation, transfer your own `uselocaldata`,
`myhomelib2.ini`, `Data` and `presets.cxml2`, then check book and collection paths.
An INI beside the EXE alone does not enable portable mode.

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
Development of HomeLib Ru: **Dicur3x**.
Testing: eg, Evgeniy_V, albert, AlbanSpy, kaznelson, Olega.

HomeLib Ru source code is licensed under [MIT](LICENSE), © 2008–2026 Oleksiy Penkov.
The licence covers the code, not the project's name; naming rules and bundled
component licences are described in [NOTICE](NOTICE).
Report bugs and suggestions through [Issues](https://github.com/Dicur3x/MyHomeLib/issues).

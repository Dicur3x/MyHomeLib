# HomeLib Ru

[Русский](README.md) · [Українська](README.uk.md) · **English** · [Български](README.bg.md)

Manage your home e-book library: catalogue your own collection of book files, and work as a client for Librusec-engine online libraries.

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.7.0-blue.svg)](https://github.com/Dicur3x/MyHomeLib/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20x86-lightgrey.svg)](#installation)
[![Built with Delphi](https://img.shields.io/badge/built%20with-Delphi%2013-red.svg)](#building-from-source)

## Current Release

The owner has approved **HomeLib Ru** as the name of this fork of
[MyHomeLib by Oleksiy Penkov](https://github.com/OleksiyPenkov/MyHomeLib).
The repository remains [Dicur3x/MyHomeLib](https://github.com/Dicur3x/MyHomeLib).
[**HomeLib Ru 2.7.0_pre5.01**](https://github.com/Dicur3x/MyHomeLib/releases/tag/2.7.0_pre5.01)
was published on 21 September 2026: executable `HomeLibRu.exe` version
`2.7.0.1068`, with `HomeLibRu.zip` (x86) and `HomeLibRu_x64.zip` (x64).
The release tag points to merge commit
[`400df2f`](https://github.com/Dicur3x/MyHomeLib/commit/400df2f10aa26e8494f132c8fdb78412485a2bd5)
on `master`. Both builds, interface tests and final MCP regressions passed;
the published ZIP contents and SHA-256 hashes were verified. See
[`BUILDING.md`](BUILDING.md) for detailed results and the first-launch
verification limitation, and [`ROADMAP.md`](ROADMAP.md) for project history.

## What it is

HomeLib Ru is a Windows desktop application for cataloguing a collection of e-book files. Books are organised by author, series and genre, searchable by an arbitrary set of conditions, and open in whichever reader application you configure.

Beyond your own collections, HomeLib Ru works as a client for libraries running the Librusec engine — Flibusta and similar sites. Such a library's catalogue is attached from an INPX file, after which you browse and search it locally and download from the server only the books you actually want.

Books are stored as FB2 (loose files or zip archives), FBD, or any other format; collection metadata lives in a SQLite database.

> **Note on interface language:** Russian is the source language. Ukrainian, English and Bulgarian (machine-translated) use embedded catalogues. The bundled help is available in all four languages and follows the interface language.

## Features

**Collections**

- Multiple collections at once, with instant switching between them.
- Collection types: local or network, your own or an attached external library, FB2 or non-FB2.
- New Collection wizard: an empty collection, one built from an INPX file, or an existing `.hlc2` file attached.
- Collection updates from the network and by hand, folder/file synchronisation, database maintenance.
- Copying books between FB2 collections, exporting a collection to INPX.

**Books**

- Import of FB2 (files and archives), FBD and other formats; bulk import from INPX.
- Browsing trees by author, series and genre, with Cyrillic and Latin alphabet filters.
- Search by author, title, series, genre, keywords, annotation, file name, date added, language and library rating — with `%text%`, `="exact value"`, `<`, `>`, `<>` and `OR` conditions — and named presets for reusable condition sets.
- Groups and favourites, ratings, reading progress and reviews; this user data exports and imports separately from the catalogue (matched by LibID).
- Downloading books from the online library, reading them in external applications chosen per file type.
- Sending books to a device with conversion: fb2mobi, fb2epub, fb2lrf, fb2pdf; file name and subfolder templates.
- Custom scripts run after a send-to-device, with `%DEST%`, `%TMP%`, `%FILENAME%` and other substitutions.
- Editing book and author details, exporting a book list to HTML.

**AI assistants**

- An MCP server (`MHLMcpServer.exe`) installs alongside the application and exposes the collection to assistants such as Claude: search books, browse authors, series and genres, read a book's table of contents and text, search inside a book. Read-only, and it does not need HomeLib Ru to be running. Setup is covered in the help under “MCP server for AI assistants”.

## Interface language

Russian is the source UI language. Ukrainian, English and Bulgarian are provided through embedded catalogues. Switch the language under **View → Interface language**; the change applies after a restart. The bundled help is available in all four languages and follows the interface language.

The genre tree follows the interface language too. Existing collections update themselves — genre names are stored inside the collection database, so they used to stay in whatever language the collection was created in.

**The Bulgarian translation is machine-made** and has not been reviewed by a native speaker; the language menu says so. If a string reads wrong, please open an [issue](https://github.com/Dicur3x/MyHomeLib/issues) quoting it with a suggested replacement.

Additional languages load from translation catalogues placed next to the application (`Lang\<code>.json`). These external files require a signature; unsigned files are ignored and do not appear in the menu. This requirement does not apply to the fork's bundled resources. Translation proposals are welcome in [Issues](https://github.com/Dicur3x/MyHomeLib/issues).

## Installation

Portable builds for 64- and 32-bit Windows are published on the [Releases](https://github.com/Dicur3x/MyHomeLib/releases) page. You can also build an installer with `Installer/build_installer.cmd` (requires [Inno Setup](https://jrsoftware.org/isinfo.php)).

Requirements: Windows 10 or newer. Disk space is driven mostly by the size of your book collections rather than by the application itself.

For portable mode, place an empty file named `uselocaldata` without an extension
next to the executable, or launch with the `uselocaldata` argument. Settings
and `Data` are then read beside the EXE instead of `%APPDATA%\MyHomeLib`.
A `myhomelib2.ini` beside the EXE alone does not select portable mode.

When upgrading from MyHomeLib, close it and back up `%APPDATA%\MyHomeLib`
and any separately stored `.hlc2` collections. Extract the new ZIP into a
clean folder and run `HomeLibRu.exe`; it reuses the existing normal profile.
For portable mode, copy `uselocaldata`, your backed-up `myhomelib2.ini`,
`Data` and `presets.cxml2`, then check the collection paths. Keep the old folder until you have
verified the new version. Do not extract over it: that leaves an obsolete
`MyHomeLib.exe` which can be launched accidentally.

## Quick start

1. Install and launch the application.
2. **Collection → Create** — the wizard asks for the collection type, the book folder and the file format.
3. Fill the collection: import existing book files from disk, or build the catalogue from an online library's INPX file.
4. Browse the author, series and genre trees, search on the Search tab, and open books in your reader or send them to your device.

The bundled help covers all of this in detail.

## Help

The full help (55 pages, in Russian, Ukrainian, English and Bulgarian) ships with the application. **F1** is context-sensitive — it opens the page matching the active window or tab in your browser. The Russian source lives in [`Program/Help/`](Program/Help/); [`index.html`](Program/Help/index.html) is the table of contents and entry point.

## Building from source

See [`BUILDING.md`](BUILDING.md) for current instructions. Delphi 13 (Studio
37.0), VCL, VirtualTreeView and the matching SQLite DLL are required.
Konopka/Raize components are no longer required. Node.js is used for
translation resources and test runners.

With Delphi Trial, build the icon DLL, `Program\MyhomeLib.dproj` and
`Utils\MHLMcpServer\MHLMcpServer.dproj` separately in the IDE, first in
Release/Win64 and then Release/Win32. Trial does not support command-line
compilation. A full licence can use the separate MSBuild commands in
`BUILDING.md`.

The new application executable is `HomeLibRu.exe`; `MyhomeLib.dproj` now
uses `HomeLibRu.dpr` as its main source. Prepare the complete `Program\Out\Bin64` and
`Program\Out\Bin` folders using the documented scripts, including readers,
archive/image tools and their licences. Include unchanged `LICENSE` and
`NOTICE` in each package.

Russian is compiled into the source. Bundled translation resources do not
require a private signing key in this fork; signature checks still apply to
additional catalogues loaded from files.

## Repository layout

```
Program/
  HomeLibRu.dpr        main project
  MHL.groupproj        group project (components + icons + app + MCP server)
  Forms/               VCL forms (frm_*.pas); Forms/Editors/ holds the editor dialogs
  DataModules/         dm_user.pas — global data module (settings, system DB)
  Units/               core: global types, settings, interfaces, helpers
  DAO/                 data access layer (abstract classes); DAO/SQLite/ is the implementation
  ImportImpl/          book import threads (FB2, FBD, INPX) and progress forms
  DwnldImpl/           book download threads
  UtilsImpl/           sync, export-to-device, collection update threads
  Wizards/             New Collection wizard
  Help/                Russian help; Help/uk, Help/en and Help/bg contain translations
  Resources/           icons, images
Components/
  MHLComponents/       design-time component package (BookTreeView, FB2 parsing, archives)
Utils/                 helper utilities (see below)
Installer/             Inno Setup scripts
tools/                 development helper scripts (help, translation catalogues)
```

## Utilities

- **`Utils/MHLMcpServer`** — a read-only MCP (Model Context Protocol) server that exposes a HomeLib Ru collection to clients such as Claude: search books, browse authors, series and genres, read a book's table of contents and text, search inside a book. It links the same DAO layer as the application, so it sees exactly the same collections. Unlike the other utilities it ships in the installer, next to `HomeLibRu.exe`. The user-facing description is in the help ([`mcp_server.html`](Program/Help/mcp_server.html)); the technical one is in [`Utils/MHLMcpServer/README.md`](Utils/MHLMcpServer/README.md).
- **`Utils/MHLSQLiteConsole`** — a standalone SQLite console for working with collection databases directly.
- **`Utils/MHLSQLiteExt`** — a C++ SQLite extension providing the custom functions the application uses.

## License

MIT — see [LICENSE](LICENSE). © 2008–2026 Oleksiy Penkov.

The licence covers the code, not the name. A fork that distributes binaries must release them under its own name — see [NOTICE](NOTICE).

## Credits

Programming: Oleksiy Penkov, Nikolay Rymanov, eg.

Development of HomeLib Ru: Dicur3x.

Testing: eg, Evgeniy_V, albert, AlbanSpy, kaznelson, Olega.

## Feedback

Report bugs and suggest features on the [Issues](https://github.com/Dicur3x/MyHomeLib/issues) page.

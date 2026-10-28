# pre5.37: updater helper identity and FB2 image types

The published pre5.36 archives contain a 1104/pre5.36 application and a
1103/pre5.35 updater helper. Native preparation succeeds, but the separate
`PreparedProgramUpdateHelper` gate correctly rejects the older helper. This was
reproduced with the exact published archive digests on Win32 and Win64.
The previous final-archive check did not exercise this helper selection step.

The application and helper project declarations now both target 1105/pre5.37.
Runtime preparation and packaging check both executable identities, numerical
versions, product release tags and architectures. The minimal archive probe
checks these identities again inside the actual ZIP. The console-only
`verify_update_archive.py` additionally exercises production preparation and
helper selection; it can reproduce the published failure without starting any
graphical app or modifying an installation.

FB2 to EPUB now accepts the JPEG MIME aliases `image/jpg` and `image/pjpeg`,
normalizes case/parameters and recognizes JPEG/PNG/GIF/WebP signatures when the
declaration is wrong. Canonical EPUB media types are emitted with unchanged
image bytes. Unknown types remain explicit errors. The full 38-test conversion
suite passed with the actual Win32 and Win64 embedded Python runtimes.

Before publication: rebuild both product executables for both architectures;
verify exact final archives through preparation and helper selection; perform
the old-version installation and restart checks. GUI work is currently deferred
at the user's request while a game is running. No pre5.37 release is published.

The separately verified optional MCP/Zstandard work is preserved on
`codex/complete-app-audit`. The new report about monolithic BookConverter
downloads is confirmed: its current archive also carries Kindle, Office and XPS.
Splitting genuine format dependencies, Reader profile/icon/metadata cleanup and
retiring superseded component assets remain required work; they are not claimed
fixed by this checkpoint.

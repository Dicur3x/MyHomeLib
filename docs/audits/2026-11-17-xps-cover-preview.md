# First-page XPS preview in the catalogue

XPS books now use the optional XPS helper to render only page zero for the
book-information panel. The caller retains the raw-book/cache lease; later pages
are validated but never rendered for this request. Full conversion keeps its
existing two-argument protocol and page order. OXPS is not included in this change.

`ReadXpsBookCover` runs the helper in a contained process with a 384 MiB commit
limit, a 30-second deadline and selection cancellation. It accepts exactly one
CRC-checked `00001.png` part, bounds decompressed bytes to 2 MiB, limits helper
stdout to 64 KiB and removes only its own output/directory. The renderer bounds
the longest edge to 600 pixels. The ordinary panel reports a first-page preview,
not a declared cover. Missing optional components are explained without opening
an installer on selection. The system-drive 8 GiB reserve and temporary-volume
space are checked before rendering and during the helper call.

The first actual panel run r1308 found a sharing failure hidden by standalone
helper tests. `Package.Open` without an explicit sharing argument defaults to
exclusive access; the catalogue already holds a read lease. Both validation and
the XPS document now use an explicitly shared-read package. The lease remains
held, protecting the original from writes/deletion. The focused native driver
also holds a real source stream to prevent this regression. See the
[Package.Open contract](https://learn.microsoft.com/en-us/dotnet/api/system.io.packaging.package.open).

Final evidence is `G:/HL-b14-external/xps-cover-validation-r1316/summary.json`:

- Win64/Win32 each passed nine focused preview tests and two existing full
  conversion tests (22 methods total). The first-page pixels and dimensions are
  independently decoded. Original SHA256 is preserved. Tests cover missing
  components, a truncated source, active markup on a later page, extra output
  pages, oversized output, wrong CRC and cancellation after a helper starts.
  The canceled helper is checked to have exited. Every private fixture is removed.
- Actual panel runs r1319/r1320 each pass four checks: standalone XPS, XPS in an
  outer ZIP, latest damaged selection without a stale cover, and the missing
  optional module. Source fixtures are byte-identical and private runtimes removed.
- Focused drivers were built in r1313/r1314. Their digests and matching helper
  source/runtime hashes are in the consolidated report. The panel drivers are
  r1307/r1309, compiled before a whitespace-only reindent of the shared unit;
  the report explicitly retains this distinction.

The C# test decoder substitute is `tools/bookconvert/tests/xps_cover_fixture.cs`.
Compile it to an owned G: folder and provide its path as `HL_XPS_COVER_FAKE`;
the native test also requires `HL_XPS_COVER_BINARY`, `HL_XPS_COVER_HELPER` and
`HL_XPS_COVER_STAGE`. For full conversion tests, set `HOMELIB_TEST_TOOLS` to the
matching tools folder. Run `python -B -m unittest discover -s
tools/bookconvert/tests -p 'test_xps*.py' -v`. Actual panel coverage uses
`test_package_covers.py --modes xps-preview --xps-dir <matching module>`, with its
ordinary native/SQLite/icon/genre/result arguments. All tests here set TEMP/TMP
to G:; E: was not used.

The initial r1300 compile failed on a nested-function capture and was corrected
before the passing builds. The first CRC fixture in r1303 exposed an untranslated
ZIP exception, not acceptance of damaged data; the production wrapper now reports
that failure in Russian. These failed attempts are not passing gates.
The optional combined-tools attempt r1317 did not start the app because its
supplied 7-Zip folder was absent. The final runs use a private copy of the
previously validated full 7-Zip under the runner's expected `7za.exe` filename;
no installed/user executable was renamed.

The shared C# source also builds the separate image processor; both architectures
were recompiled with `HOMELIB_IMAGES_ONLY`. Its algorithms were not changed, but
final package manifests must use the new matching source/runtime hashes. The XPS
component must receive a new version/package rather than reusing the published
3.0.0.5 asset. Final Main binaries, release packages, real XPS variants, OXPS,
Kindle covers and pure vector SVG remain separate work. Desktop and public assets
were not changed.

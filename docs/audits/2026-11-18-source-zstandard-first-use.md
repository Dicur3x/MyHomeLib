# Zstandard first use in library update sources

The reviewed source window now checks for the catalogue decoder after it
has staged a Zstandard index. It uses the same optional component prompt
as direct Metabib import. A successful installation continues reading the
staged file. Applying the review still requires its own confirmation.
Cancellation or a reader error releases the staged index and disables Apply.

The old Win64 build failed with a missing `libzstd.dll` message and skipped
the component prompt. The isolated reproduction is
`G:/HL-b14-external/source-window-zstd-Win64-r1871-baseline/report.json`.
An earlier diagnostic stopped while hashing the open test database on
Windows. The final fixture uses the logical catalogue digest.

The native source-window fixture starts without the decoder. It drives the
actual Check button, stages the publisher's index, then cancels one prompt,
rejects a corrupt package and installs a valid package. Package bytes are
served over loopback using the verified Zstandard release artifact. The
fixture takes the publisher file offline during successful installation
so that the subsequent review must use the staged index.

The prompt is tested against the verified package size. Both current
packages are displayed in kilobytes. An earlier test assumed megabytes.
The completed checks verify zero downloads on decline, no new library
after a damaged download, preserved separately prepared application update,
an unchanged live catalogue digest and cleanup of the private index.
The successful preview restores the book identity and title and enables
Apply. The source catalogue remains unmodified until Apply is requested.

The first-use source scenario, the direct optional Zstandard check and
the ordinary source-window regression passed on Win32 and Win64. Both
production Main executables built. The final record binds six native runs,
44 pass markers, four builds and 703 matching inputs. All isolated runtime
folders were removed. See
`G:/HL-b14-external/sources-zstd-final-r1878/summary.json`.

The optional package was supplied by a local test server. The full
public release, installation on another machine and standalone packed
Metabib application have separate release checks.

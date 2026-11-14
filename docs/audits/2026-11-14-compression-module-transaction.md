# Compression component download through actual installer and successor

Local beta-14 validation of the continuation introduced in `8d266b5b`.
No user-library mutation, Desktop replacement or publication is included.

## Complete transaction

The private portable fixture initially has the catalogue's native dependencies,
7-Zip and the existing real updater executable. BookProcessing and
ImageProcessing are absent. Its source ZIP contains an illustrated synthetic
FB2 and an unselected neighboring member. The selected book has a personal
card with 37% progress and a note.

The native diagnostic captures the selected request and invokes the public
compact component-request API with its continuation callback. Only HTTP
transport is redirected to the owned loopback servers; release identities,
package manifests and hashes, combined preparation, external installation and
the application's normal main-window successor remain real.

The first download is held at the server long enough to cancel it while active.
Cancellation must leave both modules absent, the source archive unchanged,
no pending installation and no saved compression continuation. A new explicit
request retries and downloads exactly the two required components. The test
requires three HTTP requests in total: one canceled download and two completed
downloads. It verifies that preparation has not invoked the continuation or
changed books. The explicit installation launches exactly one updater and
stores exactly one continuation.

The real helper restarts **HomeLibre.exe**. The successor verifies installed
versions and absence of unrelated format modules, then starts the ordinary
main window. Its restored options must retain maximum quality, grayscale,
selected-book scope, disabled per-archive review, no estimate-first and the
chosen work/backup folders. The source is checked unchanged before the
diagnostic approves the real Start button. Compression then runs through the
normal catalogue operation, publishes an original-book backup and updates
the catalogue while retaining progress and the personal note. The request
cannot be consumed again. The application executable itself stays byte-exact.

The Python observer independently extracts the published book with 7-Zip,
compares its complete non-image XML structure/content, checks the neighboring
member, compares the backup with every original FB2 byte, verifies the measured
catalogue size and verifies installed component identities.

## Exact local artifacts and results

BookProcessing is unchanged `packages-r78` from the preceding export audit.
Fresh ImageProcessing `packages-images-r93` uses the already verified current
native image helpers. `package-format-components.py` now accepts
`--image-processing-root` so these explicit Win32/Win64 candidates can be
packaged without replacing an older runtime under Program/Out. The existing
image-only mode, source hash, executable hash and platform checks still run.

| Platform | ImageProcessing bytes | ImageProcessing SHA-256 |
|---|---:|---|
| Win64 | 12,951 | `cebfbb97c19a7f58c4f5879d08c890ea1f155b9495f555d2ad2ac5c4608ae40c` |
| Win32 | 13,025 | `11586471890e289200ee0a6ffad929b261b30511b43a47620ceb4d5b6a5dd1aa` |

| Platform | Run | Seconds | Native fixture SHA-256 |
|---|---|---:|---|
| Win64 | `compression-modules-Win64-r96` | 28.109 | `5abde46fbe7b86b1814931a6816253d4edaf4200835001e3d114c0ef5ff6594d` |
| Win32 | `compression-modules-Win32-r97` | 28.906 | `86ea453d73ecfbde16ac78c4bcd64cd073dd9fd1ad0644d95c311f604a6ec6c6` |

Both complete transactions and independent observers passed. The original
logical book is 57,010 bytes; the result is 50,843 bytes on both architectures.
Original SHA-256:
`0c8e34f97c19c7eb279482fa73939b2d0618091b607cc3bc5b7fdb14d5af8a2e`;
result SHA-256:
`8646a328fd930e72d1039af1385cb9ff757364b8d56582329d084dbcd6023a6b`.
This synthetic integrity result is not a collection-wide savings estimate.

The actual helper hashes are Win64
`ca03f0673b13256ae74d5d7a31d8f30943163b4e1f30302bb0eee506a0f5d385`
and Win32
`ace05a18ded8d1f6796b5f2c696dd879b56304cad16477329ef5fc0da19f48d2`.
Fresh fixture build logs are
`CompressionRecovery.local-Win64-dcf3ba8f34f1.err` and
`CompressionRecovery.local-Win32-f6fec1801049.err`. Both private runtimes were
removed; each run retains report.json, native.log and the successor report.

The earlier `r94` native transaction also completed, but its independent Python
query omitted the application's custom SQLite collation. The observer now
uses explicit binary equality for the fixture's exact LibID; no production
database/collation change was made. `r94` is retained as an observer failure,
not counted as a complete passing gate.

## Scope

The first request is assembled through the same public component/continuation
APIs, while the successor uses the normal startup handler and compression UI.
The preceding audit separately covers actual startup review/cancel for all
three scopes and ordinary menu compression. This transaction covers the
selected scope, two processing modules and an already available 7-Zip; it
does not claim every missing-module combination or a first-click GUI check of
each menu. It changes diagnostics and a packaging input option, not production
installation/compression behavior.

Current compression with older external image storage, bounded user-data
copies, final application/packages, complete/minimal distributions, Desktop
replacement and publication remain separate work. Broad Packer/native
recovery suites were not rerun in this diagnostic-only step.

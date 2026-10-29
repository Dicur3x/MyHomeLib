# pre5.37 / 2.7.0.1105 validation

Builds were made with Delphi 13 Community Edition through the IDE, Release
Win32 and Win64. No command-line Delphi compiler was used.

## Release archives

| Archive | Bytes | SHA-256 |
| --- | ---: | --- |
| HomeLibRu.zip | 7248911 | dec494fc800e130850a4ceb820662f9fcab93de580fad65df9546b34a71a5231 |
| HomeLibRu_x64.zip | 9099175 | ee2739035d410cd8bbf334972e61e2a97ddc45d22a07bb73e749d073103d786f |

Both exact ZIPs passed CRC, every manifest member size/hash, architecture,
minimal-delivery exclusions, and native preparation plus the prepared-helper
identity gate. Both application and helper have numeric version 2.7.0.1105
and ProductVersion 2.7.0_pre5.37. The mismatched previous release was reproduced
before the correction; its helper was correctly rejected.

Native update-repair scenarios passed for each final archive: matching staged
helper selection, missing installed helper, corrupt helper/source rejection,
independent component failures, postponed update restoration, and light/dark
layout at 96/144/192 DPI. Test fixtures were corrected to distinguish the
classic installed repair inventory from absent optional formats, and to sample
only rows present in a native list's viewport.

## Independent format components

Actual ZIPs for BookProcessing, ImageProcessing, Kindle, LegacyBooks,
LegacyOffice and XPS passed native preparation, verification and installation
on both architectures. Changed staged bytes are rejected. Payload ownership is
disjoint; all 455 payload files matched the current verified packaging sources.

Fresh FB2-to-EPUB processing uses the common processing runtime without
Kindle, Office, XPS, PDFium or DjVu. Image compression requests its separate
worker. PDF input requests PDFium; the image worker is additionally needed
only for image processing. Ordinary FB2/EPUB copies and native ZIP copies do
not require the processing runtime or 7-Zip.

The native format-components, minimum-save, reader-components, save-planning
and save-module-restart suites passed on Win32 and Win64. Mixed FB2, EPUB,
PDF, DjVu and scanned inputs cover original copies, preferred output formats,
four image policies and estimates, cancellation, source preservation, and the
actual helper/restart/restored-review path. Restart checks include both Reader
filename cases, lowercase catalogue filename and a legacy request without an
application field. Python conversion regression suites passed 80 cases per
architecture; modular-runtime tests also exercised actual extracted packages.

## Reader and optional catalogue modules

The new Reader 2.7.0.1105 packages passed native installation with existing
PDFium and legacy converter packages while preserving catalogue and personal
files. Actual production Reader EXEs from both final ZIPs opened an FB2 ZIP,
turned pages, and saved their settings, history and cache beside the program
without a portable marker. Previous AppData and source bytes were unchanged.
The owned 33,323,851-byte smoke runtime was removed after normal window close.

MCP and Zstandard packages passed their separate native first-use tests on
both architectures. Minimal catalogue ZIPs contain neither module. Reader
bundles retain the small root Zstandard DLL and its licence for compatibility
with older clients that require it in Reader packages. The old BookConverter
feed remains for older clients; the new catalogue and Reader request the
independent processing components instead.

## Scope and remaining work

This is a critical updater and dependency-delivery hotfix. It does not claim
completion of collection compression, SQL dump import, maximum-economy/grayscale
image modes, export overwrite policy, or Reader profile consolidation. Those
remain separate goal work. Timings under the user's VM/video workload are not
reported as new performance improvements.

All generated test profiles used owned directories. Real collections were not
changed. Previously denied cleanup locations were not retried.

## Publication and cleanup outcome

Published pre5.37 with exactly the two verified catalogue archives and SHA256SUMS.
GitHub asset sizes/digests match all 18 new component archives. The published
feed SHA-256 is bdbcf8b3789c73b44340b1a7db3a65e5860fbf02ffc7cdf342bb6e42429a1a6c.
Native release parsing selected pre5.37 and the correct architecture-specific
archive on both architectures. Six superseded component archives were removed
from GitHub, and permanent-release Reader download links now point to 1105.

Automatic approval review rejected cleanup of the owned Reader installation
fixture (52,483,693 bytes) and 16 duplicate component-package ZIPs
(37,829,028 bytes), with the reason `blocked by policy`. These remain in
Out/pre537-final-20261029-r1/reader-install-fixture and the packages subdirectories
of post536-format-components-20261028-r1, post536-optional-mcp-20261028-r1 and
post536-optional-zstd-20261028-r1. No alternate deletion was attempted against
those paths after rejection. The separate actual-Reader smoke runtime and
normal native/probe temporary profiles were successfully removed.

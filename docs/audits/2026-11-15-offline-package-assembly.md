# Offline distribution assembly, development candidates

This is local beta 14 preparation. The catalogue and Reader candidates still
carry numeric version 3.0.0.13; conversion/image workers use development 14.
None of these test packages replaces an existing published asset or Desktop
installation. This audit does not establish a complete clean-Windows offline
release.

## Changes

The former full packager omitted the Reader executable and several independently
installed format modules, copied untracked runtime directories, and included
only a subset of the pinned fonts. Full packaging now requires an explicit plan
of all 25 current optional components, each with a fixed archive SHA-256, version
and architecture. Native production package validation precedes copying each
manifest member; conflicting shared payloads are rejected. The old monolithic
BookConverter is excluded because it overwrites current BookProcessing workers;
its current functions are supplied by the separate modules.

The assembler checks the combined runtime's module descriptors and versions.
Preparation now preserves the original bytes of a verified bundle manifest,
including JSON formatting and BOM: the subsequent authenticity check binds those
exact bytes to the source ZIP. Reserializing it previously made legitimate full
ZIPs fail with "manifest changed". The Reader ownership scope now covers the
four pinned font directories and their explicit font/license file types, so
full-distribution fonts can participate in component ownership receipts.
It maps the compatible Reader transport to HomeLibreReader.exe and checks all
109 pinned font/license files. Public OFFLINE.json contains module identities
without private source paths. Full manifests carry the module bundle; minimal
and beta-13-compatible catalogue ZIPs remain separate. New disk-heavy work uses
G: with system/work-volume reserves and owned staging cleanup.

A shared 32-component bound replaces the former 9-job/12-bundle restrictions.
The recovery journal uses the same bound. Unknown component IDs, unsafe paths,
per-file/archive limits and package hash verification remain in force.

## Evidence already completed

- Both native test hosts built with the expanded limits (r539/r540).
- Real selected Reader/BookProcessing/ImageProcessing composition and missing-ID
  and changed-archive guards passed on x86/x64 (offline-selected-native-r542).
- Thirteen real modules were composed, installed and checked with receipts and
  a personal sentinel on both architectures (offline-large-bundle-r544).
- All 25 components staged together and passed runtime checks on x86/x64
  (offline-complete-stage-r554), before refreshing the latest Reader payload.
- Real package-release.ps1 produced both full ZIPs after refreshing Reader and
  production updater binaries (package-name-full-Win64-r564 and Win32-r565).
  Both contain 25 modules and all pinned font files. The x64 full ZIP is
  206,541,942 bytes. Exact archive hashes are recorded beside the ZIPs.
- Minimal and compatibility ZIPs were produced on x64 (r561) and x86 (r567).
- Production updater builds passed with the expanded limits on both
  architectures (updater-full-bundle-Win64-r559 and Win32-r560).

All evidence paths above are under G:/HL-b14-external. Source input plans r563
pin current Reader packages r562, development workers, exact published modules,
and the native-prepared matching JPEG XL decoder/encoder 0.13 and IBK 9.6.5
packages r549. Downloaded release inputs r548 were matched to the recorded
published asset sizes and SHA-256 values.

The first actual-distribution observer (offline-distribution-Win64-r566) failed
because it required an installation receipt immediately after manual extraction.
Manual extraction intentionally has no receipt: removal reads the supplied root
manifest instead. The corrected host reports that manifest inventory separately;
actual receipt checks still apply after native installation. The failed report
is retained. The next observer also incorrectly tried to run an updater against
an empty directory (r570/r571). The updater correctly requires an existing
application; clean installation is covered by manual extraction. The fixture
now starts with the real catalogue EXE and private data. Corrected
actual-distribution results will be recorded separately. r572/r573 also exposed
a fixture omission: the original ZIP must remain at prepared/release.zip for
bundle verification. The harness now follows the real downloader layout. These
unsuccessful observer runs are retained and are not release evidence.

The corrected fixtures r574/r575 exposed a real production defect: JSON
reserialization changed the prepared bundle manifest's bytes, so installation
rejected an otherwise verified archive. A retained diagnostic r576 confirmed
the exact error. Original verified manifest bytes are now preserved atomically.
The test explicitly checks this equality before installation; font receipt
coverage is also required, rather than merely reported.

## Final native distribution checks

The unchanged x86 full and portable cases passed in r580 with all 25 module
receipts, all pinned fonts owned, exact prepared bundle bytes and personal
sentinels preserved. The report remains FAIL overall: its last compatibility
case wrongly looked for the transport path after installation. The actual
updater correctly maps that file to HomeLibre.exe. That final observer assertion
was corrected, and the x86 compatibility ZIP alone passed in r581. The already
passing full/portable cases were not repeated without a new application change.

All three x64 cases passed together in r582 with the corrected observer.
Their owned temporary profiles were removed. Native hosts are the production
installer code compiled into the guarded test adapters, hashes
`6961c9018cacbb6add62645567a45321b846ddd2e8856bea10ad98e34503e10c` (x86)
and `abbf247d6e8284290d4b068f5daa5667b6a5b8dfa7ef16897b4b145ca92d49dd`
(x64). These are not claims that the older helper binaries inside the input
ZIPs already contain the final fixes. Updated production builds remain required.

| Platform | ZIP | Files | Modules | Evidence |
|---|---|---:|---:|---|
| Win32 | HomeLibre_full.zip | 1618 | 25 | offline-distribution-Win32-r580 |
| Win32 | HomeLibre_portable.zip | 241 | 0 | offline-distribution-Win32-r580 |
| Win32 | HomeLibre.zip | 241 | 0 | offline-distribution-bridge-Win32-r581 |
| Win64 | HomeLibre_x64_full.zip | 1619 | 25 | offline-distribution-Win64-r582 |
| Win64 | HomeLibre_x64_portable.zip | 241 | 0 | offline-distribution-Win64-r582 |
| Win64 | HomeLibre_x64.zip | 241 | 0 | offline-distribution-Win64-r582 |

Manual extraction was checked through the root manifest inventory; update
installation was checked through the generated ownership receipts. Personal
fixtures include catalogue/Reader settings, a data sentinel and a changed
AlReader configuration. The native transport mapping is verified separately
from source member paths.

## Open release gates

The native full/minimal ZIP installation, manual-extraction inventory and
personal-file checks above have passed. The clean Windows system prerequisites
(notably WebView2 for EPUB-to-PDF), no-network GUI functions, module removal and
subsequent updates still need verification. The font ownership extension and
exact-manifest preparation fix require updated production catalogue/Reader/helper
builds and fresh final packages, followed by relevant release checks. Final beta 14 identities, relevant
published beta 13 migration checks, licenses/source completeness and publication
remain open. No full-offline Todo checkbox is closed by assembly alone.

Microsoft documents the Evergreen Standalone Installer for fully offline
WebView2 deployment, with no bootstrapper download on the target machine:
https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution#offline-deployment
The current application still offers the online bootstrapper; that missing
offline path is a remaining implementation gate, not a completed feature.

Automatic review rejected recursive cleanup of the task-owned diagnostic root
G:/HL-b14-external/offline-install-diagnosis-Win64-r576/HomeLibRu-update-test-diagnosis,
without a stated reason. No cleanup ran; that diagnostic fixture remains on G:.
All ordinary distribution-probe temporary profiles were removed normally.

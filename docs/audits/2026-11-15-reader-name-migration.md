# Reader executable and project naming for beta 14

The development Reader is now `HomeLibreReader.exe`, built from
`Utils/HomeLibreReader/HomeLibreReader.dproj` and `HomeLibreReader.dpr`.
Its Windows InternalName and OriginalFilename use the new name. The catalogue
launches that executable; the module/update UI displays **HomeLibre Reader**
without the former technical component ID. All four README languages and the
current build instructions use the canonical application names.

This is local release preparation. Production candidates still carry numeric
version 3.0.0.13; final beta 14 identity, published-client migration and Desktop
replacement remain separate release gates.

## Compatibility

`HomeLibReader.ini`, reader history, existing profile locations, session protocol
and the published component ID stay readable. Runtime detection, repair,
inventory/adoption, module management, removal planning, related-instance
coordination and updater restart recognize both executable names and prefer the
canonical one when both exist.

The beta 13 component parser rejects an unfamiliar root EXE. Its compatible
component ZIP therefore retains the old asset and payload spelling. The new
installer maps that verified payload to `HomeLibreReader.exe`. If an old EXE
already exists, both names receive the identical payload in the same journaled
transaction, preserving old shortcuts and catalogue clients. Fresh installs
create only the canonical EXE. Receipts record actual destination names.

The manifest carries `reader_application: HomeLibreReader.exe`. Old combined-job
writers can discard that optional field, so a Reader component version at least
3.0.0.14 also identifies the renamed payload. Unmarked older payloads keep their
old self-update identity. A separate standalone
`HomeLibreReader-VERSION-PLATFORM.zip` contains the canonical EXE directly.
Publication planning verifies its exact content against the component ZIP and
includes it as a separate asset. The old updater/manifest/license transport
names, historical audit text and upstream MyHomeLib attribution are deliberate
compatibility/history references, not current public application names.

## Native and package checks

`reader_identity_smoke.py` passed 13 case groups per architecture with production
installer code: fresh/old/both-name targets, standalone and compatible transport,
old-client-style single/batch metadata, all eight injected copy failures,
unmarked beta 13, ambiguous/invalid names, preservation of a newer installed
Reader, actual ownership receipts and removal plans. Personal fixtures remain
byte-identical. Native metadata also asserts the exact display title. One owned
fixture's Windows version resource is edited to simulate later payload versions;
this is not a claim about a released beta 14 binary.

Final native reports, both PASS with removed owned profiles:

- `G:/HL-b14-external/reader-identity-removal-Win32-r526/reader-identity-report.json`
- `G:/HL-b14-external/reader-identity-removal-Win64-r528/reader-identity-report.json`

`reader_package_identity_smoke.py` built four real Reader ZIPs, checked every
manifest/payload, ran native preparation and installation for both layouts on
both architectures, checked both installed EXEs, restart resolution, repair
state, ownership hashes and removal plans, and preserved private settings/history
sentinels. Its owned runtime was removed. Report:
`G:/HL-b14-external/reader-real-packages-r534/verification-report.json` (PASS).
Five publication contract tests also passed, including rejection of an altered
standalone payload. These tests do not contact GitHub or install on the Desktop.

All production builds succeeded through the licensed IDE:

| Architecture | Reader SHA-256 | Catalogue SHA-256 |
|---|---|---|
| x86 | `b39e4f916ddebaba88a51dec69a4d173e5c54bea1c958ae224a420398806ccbb` | `2db7f1eb92f90a6e35cac0d3a0bceb97925f3a96c257bdf369b2aeb84f4dc5ff` |
| x64 | `0797c027a69c64860cb94ace8db48b20394976fae283fc12461307acc0992ae9` | `2ece2d73e76644c53dac636639fe3751b13c9d108d663a5b7b3743d52cd3725c` |

Build reports: `reader-final-rename-Win64-r529`, `reader-final-rename-Win32-r530`,
`main-final-reader-rename-Win64-r531`, `main-final-reader-rename-Win32-r532` under
`G:/HL-b14-external`. The updated production helper builds also passed on both
architectures (`updater-reader-rename-Win64-r520`, `Win32-r521`).

## Observed GUI and remaining gates

On the preceding x64 candidate, real Main opened compressed FLibrary EPUB 101
and FB2 301 using the actual `HomeLibreReader.exe` process. Both showed their
text and external-image fixture. Each was paged once, closed normally and
reopened without navigation: EPUB stayed at 23%, character 384; FB2 at 28%,
character 464. All four Reader processes and Main exited normally.

The surrounding experimental compression inspection report r523 is **FAIL**:
its observer incorrectly required an optional progress field in an initial
displaying reply. The captured sessions prove the exact reopened positions and
new process name, but that failure prevented its final catalogue/archive
assertions. Do not relabel it as a passing end-to-end compression run. Its
observer was corrected separately; complete reruns with the final x86/x64
development builds passed in r535/r536, including the final assertions. See
[the compression/Reader inspection audit](2026-11-15-compressed-reader-inspection.md)
for the exact scope and remaining limitations.

Before publication, repeat relevant checks with final beta 14 identities and an
unchanged published beta 13 GUI client, including coordinated Reader/catalogue
restart and the final offline/minimal distributions. No rename-related check
closes the other open beta 14 work.

## Catalogue source project, resources and bundled help

The catalogue project and group now use `Program/HomeLibre.dproj` and
`Program/HomeLibre.groupproj`. Its tracked resource inputs are `HomeLibre.res`,
`HomeLibre.dres`, `HomeLibreManifest.rc` and `HomeLibre.manifest`; both catalogue
and Reader link the renamed manifest resource. The Windows assembly identity
and the catalogue ProgramID now use HomeLibre. The release preflight checks
canonical project, source and executable resource names, and the executable
check rejects an obsolete embedded assembly name.

Current build entry points, README and all four languages of bundled help now
refer to HomeLibre.exe and the canonical portable archives. Optional Inno source
scripts and their output names use Setup_HomeLibre; their build-script links were
updated together. The icon resource library's product description/name also use
HomeLibre, while its stable DLL filename stays unchanged. Historical build logs,
upstream credits, repository URLs and compatibility protocols remain accurate.

Both production catalogue and Reader builds passed again through the licensed
IDE after the resource/project changes. The catalogue PE/resource checks passed
on both architectures, including the canonical embedded assembly, common
controls and PerMonitorV2. These candidates still carry numeric version 13:
final beta 14 packages and published-client migration remain release gates.

| Application | Architecture | SHA-256 |
|---|---|---|
| Catalogue | x64 | `dfd5091c76f17defda9e76fb1c8f59c85a5c9de0ce226409c91855b87239ff9f` |
| Catalogue | x86 | `69f9f6b93f0e328aba726eb57b04e2e4212e7b514c0e76995a53569af74148a4` |
| Reader | x64 | `d44ccf0fcd36773ceb9b7ba4c16760b8592ad7ceb7c893769fb23d8f609a970a` |
| Reader | x86 | `c66e8c9f3fe9dd95d1597f2b2e6b975f37db8716429f686ac7862e9906acd105` |

Evidence directories under `G:/HL-b14-external`: catalogue-project-rename-Win64-r551,
catalogue-project-rename-Win32-r553, reader-resource-rename-Win64-r555 and
reader-resource-rename-Win32-r556. Icon library builds passed in
icons-brand-Win32-r557 and icons-brand-Win64-r558. Source release preflight passed.
The optional Inno installer itself was not rebuilt in this check. No Desktop
installation or public release was changed.

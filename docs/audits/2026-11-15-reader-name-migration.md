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
observer is corrected separately and must be rerun. The later final builds
include additional legacy-name module-management checks; their build/native
tests passed, without another claim of a final GUI compression run.

Before publication, repeat relevant checks with final beta 14 identities and an
unchanged published beta 13 GUI client, including coordinated Reader/catalogue
restart and the final offline/minimal distributions. No rename-related check
closes the other open beta 14 work.

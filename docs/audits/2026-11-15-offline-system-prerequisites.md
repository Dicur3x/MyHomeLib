# Complete offline Windows prerequisites, beta 14 preparation

The full distribution now stages the complete original Microsoft WebView2
installers for x86/x64 and the .NET Framework 4.8 offline installer. The pinned
immutable URLs, exact sizes, SHA-256 hashes and PE file versions are in
`Installer/OfflinePrerequisites.json`. A WebView2 installer's PE version is the
Edge Update setup version (1.3.315.17), not the browser Runtime version.

`prepare-offline-prerequisites.py` provisions those explicit inputs on a
non-system volume. It reuses matching files, rejects changed inputs and validates
all three with the native Microsoft-publisher verifier without executing an
installer. `stage-offline-prerequisites.py` includes only those verified inputs,
metadata and a short local README in the owned full-package stage. Full packaging
requires these inputs; the minimal distribution keeps its existing online path.

When WebView2 is absent, HomeLibre finds the full kit and offers **Install from
the kit**, selecting the native Windows architecture. The worker validates size,
SHA-256, PE version and the Microsoft signature before launching the installer,
with a read lock covering verification and process creation. No bootstrapper
HTTP request or extra installer copy is needed for this branch. Cancellation
before installation prevents process creation; installation retains the existing
safe wait/close behavior. If the Runtime is already present, no installation is
started. .NET's original installer and local instructions are supplied for
Windows installations where that dependency is missing.

Microsoft's documented offline deployment uses the Evergreen Standalone
Installer, unlike the online bootstrapper:
https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution#offline-deployment
The official .NET page separately identifies its complete offline installer:
https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48
Original installer license terms remain inside the unmodified Microsoft files.
Their OS requirements still apply; the architecture label AnyWindows in the
metadata means a shared x86/x64 input, not support for every Windows version.

## Bounded package handling

Complete installers grow the development full ZIPs to approximately 693/700 MiB.
Larger local ZIPs are accepted only for a full catalogue manifest with a module
bundle, up to 1 GiB. Ordinary archives retain the 256 MiB preparation limit;
network download limits are unchanged. Ordinary members retain the 128 MiB
limit. Only the two exact WebView2 installer paths in a full distribution can
reach 384 MiB. The existing 1 GiB total payload limit is unchanged. Unknown files
under tools/prerequisites are rejected. A declared complete kit requires all
three installers, its metadata and README; native preparation and installation
verify all Microsoft inputs. The prepared bundle manifest still preserves its
exact original bytes.

The ZIP builder stores the already compressed Microsoft installers without
another compression pass. It continues compressing the application/modules and
checks system/working-volume reserves between members.

## Evidence

No Microsoft installer was executed, and no shared Windows Runtime or system
registry configuration was installed/removed during these checks.

- Vendor downloads and Authenticode inspection: offline-prerequisite-inputs-r583.
- Nine native signature/metadata cases passed per architecture in r585/r587:
  absent kit, three genuine inputs, changed hash, foreign path, duplicate
  architecture, unsupported architecture, and an unsigned PE whose declared
  size/hash/version match. Owned profiles were removed.
- The provisioning script reused and verified all three pinned inputs through
  the native x64 checker; verification-report.json remains beside the inputs.
- Production Main builds passed with the local-kit UI path on x64 (r588) and
  x86 (r589). This is compile/link evidence; the installation prompt itself was
  not visually exercised and no setup was run.
- Native hosts with large-full-archive handling built on x86 (r590) and x64
  (r591). The earlier Main builds predate that final parser change.
- Actual full ZIP generation passed with all 25 modules, all pinned fonts and
  the three complete installers on x86 (r592) and x64 (r593).
- Actual preparation, installation over an owned catalogue fixture, module and
  font inventory, private fixture preservation and post-copy Microsoft checks
  passed on x86 (r594) and x64 (r596). Their owned profiles were removed.
- Ordinary archive/member limit regressions passed on both architectures in
  r595, with no payload extraction for the rejected cases.

All rNNN evidence directories above are under G:/HL-b14-external with the
corresponding offline-prerequisite/full-prerequisite prefixes. Exact package
proofs:

| Architecture | Package bytes | SHA-256 | Native verifier SHA-256 |
|---|---:|---|---|
| Win32 | 726172946 | `903190e9f7a61da1853a903d4685108490fcbf4671615844b33c39ad22d256f6` | `411d73e0ee826df1192d04310bcc769a038b4835f47cecdbeeba7997a535b9b4` |
| Win64 | 733999479 | `f3eca694a193c6fde24030001681434c924488dcfd1c2066f918a56898282323` | `84134f2a2ab79aa8ff906295cba43b736323b278f0d50edc5ed99516756d1dc8` |

## Remaining gates

The candidates still use numeric catalogue/Reader version 13 and include older
Reader/updater payloads from the explicit component inputs. All production
executables and final ZIPs must be rebuilt with the final beta 14 identity and
latest parser changes before publication. The MS inputs have been verified as
original complete installers; clean-Windows installation and no-network GUI
function coverage are not claimed by the signature/native tests. The app prompt
needs a visual cancellation check. Module removal/update checks, final license
review, remaining beta 14 Todo items, Desktop replacement and publication remain
open. This does not close the full-offline checkbox.
